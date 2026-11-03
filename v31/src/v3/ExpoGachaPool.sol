// SPDX-License-Identifier: MIT
/*
 *        .-------------.
 *       /  o   O   o    \        _____ __  __ ____   ___
 *      |   O   o   O   o |      | ____|\ \/ /|  _ \ / _ \
 *      |   o   O   o   O |      |  _|   \  / | |_) | | | |
 *       \    o   O   o  /       | |___  /  \ |  __/| |_| |
 *        '-------------'        |_____|/_/\_\|_|    \___/
 *       |   [ E X P O ]  |         ____    _    ____ _   _    _
 *       |                |        / ___|  / \  / ___| | | |  / \
 *       |   (+)     ___  |       | |  _  / _ \| |   | |_| | / _ \
 *       |          | o | |       | |_| |/ ___ \ |___|  _  |/ ___ \
 *       |__________|___|_|        \____/_/   \_\____|_| |_/_/   \_\
 *
 *       ExpoGachaPool
 *       The reserve and every opening: draw, reveal, sell back, delivery.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IRandomness} from "../ExpoPool.sol";
import {ExpoVault} from "../ExpoVault.sol";

interface IAdmission {
    function isAdmitted(address collection) external view returns (bool);
    function isDeliverable(address collection) external view returns (bool);
}

/// @title Expo Gacha reserve and settlement
/// @author Expo Gacha
/// @custom:website https://expogacha.com
/// @notice Unaudited V3 reserve and settlement for every gacha line (docs/33): ETF baskets and intra-collection
/// gachas created by the owner, launchpad gachas created by the configurator from signed quotes. One USDC reserve,
/// split by per-configuration and launchpad caps. USDC amounts use 6 decimals.
/// v3.1 (docs/41): unclaimed openings compensate at the Quick Sell rate, `maxOpen` caps undrawn openings only, and a
/// guardian can only disable.
/// Upgradeable vault (docs/48): `fulfill` delivers only while the collection's review still matches the collection's
/// and the vault implementation's code, and `pendingClaims` tells the vault which collections it must not recover.
contract ExpoGachaPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Kind {
        Etf,
        Launchpad,
        Collection
    }

    enum State {
        None,
        Pending,
        RandomReady,
        Revealed,
        ClaimRequested,
        QuickSold,
        Delivered,
        Compensated
    }

    /// @dev A token range, optionally narrowed to a frozen Merkle set of token IDs (intra-collection tiers).
    struct Entitlement {
        address collection;
        uint256 minTokenId;
        uint256 maxTokenId;
        bytes32 tokenRoot;
        uint128 referenceUsdc;
        uint128 budgetUsdc;
    }

    struct ConfigInput {
        bytes32 gachaId;
        uint128 priceUsdc;
        uint16[4] odds;
        uint16 quickSellBps;
        uint32 settlementWindow;
        bytes32 metadataHash;
        Entitlement[][4] items;
    }

    struct Config {
        Kind kind;
        address creator;
        bytes32 gachaId;
        uint128 priceUsdc;
        uint128 maxLiability;
        uint32 settlementWindow;
        uint16 quickSellBps;
        uint16 creatorFeeBps;
        uint32 maxOpen;
        uint32 openNow;
        uint16[4] odds;
        bytes32 metadataHash;
        bool enabled;
    }

    struct Opening {
        address buyer;
        uint64 configId;
        State state;
        uint64 deadline;
        uint128 liability;
        uint8 tier;
        uint32 index;
        uint256 word;
        uint256 tokenId;
    }

    uint256 private constant MAX_PER_TIER = 256;
    uint256 private constant MAX_COLLECTIONS = 64;
    uint16 public constant MAX_CREATOR_FEE_BPS = 300;
    uint16 public constant MAX_LAUNCHPAD_CAP_BPS = 2500;
    uint256 public constant CAP_INCREASE_DELAY = 48 hours;
    uint256 public constant WITHDRAW_WINDOW = 24 hours;

    IERC20 public immutable usdc;
    IRandomness public immutable randomness;
    ExpoVault public immutable vault;
    IAdmission public immutable registry;
    address public immutable operator;

    address public configurator;
    /// @notice May only disable configurations (docs/41); zero means no guardian.
    address public guardian;
    uint16 public launchpadCapBps = MAX_LAUNCHPAD_CAP_BPS;

    uint256 public reserved;
    uint256 public launchpadReserved;
    uint256 public creatorFeesOwed;
    mapping(address => uint256) public creatorBalance;

    uint256 public withdrawCap;
    uint256 public pendingWithdrawCap;
    uint256 public pendingWithdrawCapAt;
    uint256 public withdrawWindowStart;
    uint256 public withdrawnInWindow;

    uint64 public configCount;
    uint256 public openingCount;
    mapping(uint64 => Config) public configs;
    mapping(uint64 => mapping(uint8 => Entitlement[])) private entitlements;
    mapping(uint64 => address[]) private configCollections;
    mapping(uint256 => Opening) public openings;
    mapping(uint256 => uint256) public requestOpening;
    /// @notice Openings in `ClaimRequested` per awarded collection; the vault refuses owner recovery while non-zero.
    mapping(address => uint256) public pendingClaims;

    error Invalid();
    error Unauthorized();
    error WrongState();
    error Insolvent();
    error Expired();
    error CapReached();
    error NotAdmitted(address collection);

    event Configured(
        uint64 indexed configId, bytes32 indexed gachaId, Kind kind, address indexed creator, bytes32 metadataHash
    );
    event EnabledChanged(uint64 indexed configId, bool enabled);
    event ConfiguratorSet(address configurator);
    event GuardianSet(address guardian);
    event GuardianDisabled(uint64 indexed configId);
    event LaunchpadCapSet(uint16 bps);
    event WithdrawCapProposed(uint256 cap, uint256 effectiveAt);
    event WithdrawCapSet(uint256 cap);
    event Withdrawn(address indexed to, uint256 amount);
    event CreatorFeesWithdrawn(address indexed creator, uint256 amount);
    event Opened(uint256 indexed openingId, uint256 indexed requestId, address indexed buyer, uint64 configId);
    event RandomReady(uint256 indexed openingId);
    event Revealed(uint256 indexed openingId, uint8 tier, uint32 index, address collection, uint64 deadline);
    event ClaimRequested(uint256 indexed openingId);
    event Delivered(uint256 indexed openingId, address indexed collection, uint256 tokenId, uint256 reimbursedUsdc);
    event Settled(uint256 indexed openingId, State state, uint256 amountUsdc);

    constructor(
        IERC20 token,
        IRandomness provider,
        ExpoVault vault_,
        IAdmission registry_,
        address fulfiller,
        address admin,
        uint256 initialWithdrawCap
    ) Ownable(admin) {
        if (
            address(token).code.length == 0 || address(provider).code.length == 0 || address(vault_).code.length == 0
                || address(registry_).code.length == 0 || fulfiller == address(0)
        ) revert Invalid();
        usdc = token;
        randomness = provider;
        vault = vault_;
        registry = registry_;
        operator = fulfiller;
        withdrawCap = initialWithdrawCap;
    }

    // ---------------------------------------------------------------- configuration

    /// @notice Owner path for ETF baskets and intra-collection gachas; creator fee is zero.
    function createConfig(ConfigInput calldata input, Kind kind, uint32 maxOpen) external onlyOwner returns (uint64) {
        if (kind == Kind.Launchpad) revert Invalid();
        return _create(input, kind, msg.sender, 0, maxOpen);
    }

    /// @notice Configurator path (ExpoLaunchpad): the launch's economics were checked against a signed quote there.
    function createLaunchpadConfig(ConfigInput calldata input, address creator, uint16 creatorFeeBps, uint32 maxOpen)
        external
        returns (uint64)
    {
        if (msg.sender != configurator || configurator == address(0)) revert Unauthorized();
        if (creator == address(0) || creatorFeeBps > MAX_CREATOR_FEE_BPS) revert Invalid();
        return _create(input, Kind.Launchpad, creator, creatorFeeBps, maxOpen);
    }

    /// @notice The owner enables or disables any configuration, including re-enabling one the guardian disabled; a
    /// launchpad creator can only disable its own.
    function setEnabled(uint64 id, bool enabled) external {
        Config storage c = configs[id];
        if (c.priceUsdc == 0) revert Invalid();
        bool creator = c.kind == Kind.Launchpad && msg.sender == c.creator;
        if (msg.sender != owner() && !(creator && !enabled)) revert Unauthorized();
        c.enabled = enabled;
        emit EnabledChanged(id, enabled);
    }

    /// @notice The guardian's only power: disable a configuration. It cannot enable, create, withdraw or set roles.
    function guardianDisable(uint64 id) external {
        if (msg.sender != guardian || guardian == address(0)) revert Unauthorized();
        Config storage c = configs[id];
        if (c.priceUsdc == 0) revert Invalid();
        c.enabled = false;
        emit EnabledChanged(id, false);
        emit GuardianDisabled(id);
    }

    function setGuardian(address value) external onlyOwner {
        guardian = value;
        emit GuardianSet(value);
    }

    function setConfigurator(address value) external onlyOwner {
        configurator = value;
        emit ConfiguratorSet(value);
    }

    function setLaunchpadCapBps(uint16 bps) external onlyOwner {
        if (bps > MAX_LAUNCHPAD_CAP_BPS) revert Invalid();
        launchpadCapBps = bps;
        emit LaunchpadCapSet(bps);
    }

    function oddsOf(uint64 id) external view returns (uint16[4] memory) {
        return configs[id].odds;
    }

    function entitlement(uint64 id, uint8 tier, uint256 index) external view returns (Entitlement memory) {
        return entitlements[id][tier][index];
    }

    function entitlementCount(uint64 id, uint8 tier) external view returns (uint256) {
        return entitlements[id][tier].length;
    }

    function collectionsOf(uint64 id) external view returns (address[] memory) {
        return configCollections[id];
    }

    // ---------------------------------------------------------------- treasury

    function fund(uint256 amount) external nonReentrant {
        _receive(msg.sender, amount);
    }

    /// @notice USDC not backing an opening and not owed to creators.
    function freeReserve() public view returns (uint256) {
        return usdc.balanceOf(address(this)) - reserved - creatorFeesOwed;
    }

    /// @notice Owner withdrawal, limited to free reserve and to `withdrawCap` per 24-hour window.
    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || amount > freeReserve()) revert Insolvent();
        if (block.timestamp >= withdrawWindowStart + WITHDRAW_WINDOW) {
            withdrawWindowStart = block.timestamp;
            withdrawnInWindow = 0;
        }
        if (withdrawnInWindow + amount > withdrawCap) revert CapReached();
        withdrawnInWindow += amount;
        usdc.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice Lowering the withdrawal cap applies now; raising it applies only after CAP_INCREASE_DELAY.
    function proposeWithdrawCap(uint256 cap) external onlyOwner {
        if (cap <= withdrawCap) {
            withdrawCap = cap;
            pendingWithdrawCapAt = 0;
            emit WithdrawCapSet(cap);
        } else {
            pendingWithdrawCap = cap;
            pendingWithdrawCapAt = block.timestamp + CAP_INCREASE_DELAY;
            emit WithdrawCapProposed(cap, pendingWithdrawCapAt);
        }
    }

    function applyWithdrawCap() external onlyOwner {
        if (pendingWithdrawCapAt == 0 || block.timestamp < pendingWithdrawCapAt) revert WrongState();
        withdrawCap = pendingWithdrawCap;
        pendingWithdrawCapAt = 0;
        emit WithdrawCapSet(withdrawCap);
    }

    function withdrawCreatorFees() external nonReentrant {
        uint256 amount = creatorBalance[msg.sender];
        if (amount == 0) revert Invalid();
        creatorBalance[msg.sender] = 0;
        creatorFeesOwed -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit CreatorFeesWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------- lifecycle

    function open(uint64 configId) external nonReentrant returns (uint256 id) {
        Config storage c = configs[configId];
        if (!c.enabled) revert Invalid();
        address[] storage distinct = configCollections[configId];
        for (uint256 i; i < distinct.length; ++i) {
            if (!registry.isAdmitted(distinct[i])) revert NotAdmitted(distinct[i]);
        }
        if (c.openNow >= c.maxOpen) revert CapReached();
        _receive(msg.sender, c.priceUsdc);
        uint256 fee = uint256(c.priceUsdc) * c.creatorFeeBps / 10000;
        if (fee > 0) {
            creatorBalance[c.creator] += fee;
            creatorFeesOwed += fee;
        }
        if (freeReserve() < c.maxLiability) revert Insolvent();
        if (c.kind == Kind.Launchpad) {
            uint256 assets = usdc.balanceOf(address(this)) - creatorFeesOwed;
            if (launchpadReserved + c.maxLiability > assets * launchpadCapBps / 10000) revert CapReached();
            launchpadReserved += c.maxLiability;
        }
        reserved += c.maxLiability;
        c.openNow += 1;
        id = ++openingCount;
        openings[id] = Opening(msg.sender, configId, State.Pending, 0, c.maxLiability, 0, 0, 0, 0);
        uint256 requestId = randomness.request();
        if (requestId == 0 || requestOpening[requestId] != 0) revert Invalid();
        requestOpening[requestId] = id;
        emit Opened(id, requestId, msg.sender, configId);
    }

    /// @dev Asynchronous callback deliberately performs no transfers or selection loops.
    function fulfillRandomness(uint256 requestId, uint256 word) external {
        if (msg.sender != address(randomness)) revert Unauthorized();
        uint256 id = requestOpening[requestId];
        if (id == 0 || openings[id].state != State.Pending) return;
        openings[id].word = word;
        openings[id].state = State.RandomReady;
        emit RandomReady(id);
    }

    function finalize(uint256 id) external {
        Opening storage o = openings[id];
        if (o.state != State.RandomReady) revert WrongState();
        Config storage c = configs[o.configId];
        uint256 roll = o.word % 10000;
        uint256 boundary;
        uint8 tier;
        for (; tier < 4; ++tier) {
            boundary += c.odds[tier];
            if (roll < boundary) break;
        }
        uint256 count = entitlements[o.configId][tier].length;
        // count <= MAX_PER_TIER (256), so the modulo always fits in uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 index = uint32(uint256(keccak256(abi.encode("EXPO_ENTITLEMENT", id, o.word))) % count);
        Entitlement storage e = entitlements[o.configId][tier][index];
        uint128 value = _liability(e);
        uint256 released = o.liability - value;
        reserved -= released;
        if (c.kind == Kind.Launchpad) launchpadReserved -= released;
        // The outcome is known: the slot under maxOpen frees now; the awarded liability stays reserved until settlement.
        c.openNow -= 1;
        o.liability = value;
        o.tier = tier;
        o.index = index;
        o.deadline = uint64(block.timestamp + c.settlementWindow);
        o.state = State.Revealed;
        emit Revealed(id, tier, index, e.collection, o.deadline);
    }

    function quickSell(uint256 id) external nonReentrant {
        Opening storage o = openings[id];
        _buyer(o);
        if (o.state != State.Revealed) revert WrongState();
        if (block.timestamp >= o.deadline) revert Expired();
        uint256 amount = uint256(_awarded(o).referenceUsdc) * configs[o.configId].quickSellBps / 10000;
        _settle(id, o, State.QuickSold, amount);
    }

    function claimNFT(uint256 id) external {
        Opening storage o = openings[id];
        _buyer(o);
        if (o.state != State.Revealed) revert WrongState();
        if (block.timestamp >= o.deadline) revert Expired();
        o.state = State.ClaimRequested;
        pendingClaims[_awarded(o).collection] += 1;
        emit ClaimRequested(id);
    }

    /// @notice Operator delivers an acquired token from the vault. When the awarded entitlement is a frozen token set,
    /// `proof` must show (collection, tokenId) belongs to it.
    function fulfill(uint256 id, uint256 tokenId, bytes32[] calldata proof) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        Opening storage o = openings[id];
        if (o.state != State.ClaimRequested) revert WrongState();
        if (block.timestamp >= o.deadline) revert Expired();
        Entitlement storage e = _awarded(o);
        if (tokenId < e.minTokenId || tokenId > e.maxTokenId) revert Invalid();
        if (
            e.tokenRoot != bytes32(0)
                && !MerkleProof.verifyCalldata(proof, e.tokenRoot, tokenLeaf(e.collection, tokenId))
        ) {
            revert Invalid();
        }
        // Never deliver under stale evidence: an upgraded vault, changed collection code or a revocation (docs/48).
        if (!registry.isDeliverable(e.collection)) revert NotAdmitted(e.collection);
        if (IERC721(e.collection).ownerOf(tokenId) != address(vault)) revert Invalid();
        uint256 budget = e.budgetUsdc;
        _release(o);
        o.state = State.Delivered;
        pendingClaims[e.collection] -= 1;
        o.tokenId = tokenId;
        vault.release(e.collection, tokenId, o.buyer);
        if (IERC721(e.collection).ownerOf(tokenId) != o.buyer) revert Invalid();
        usdc.safeTransfer(operator, budget);
        emit Delivered(id, e.collection, tokenId, budget);
        emit Settled(id, State.Delivered, budget);
    }

    /// @notice After the deadline: an opening the buyer never claimed pays the Quick Sell amount; one whose claim Expo
    /// failed to deliver pays the full reference.
    function compensate(uint256 id) external nonReentrant {
        Opening storage o = openings[id];
        if (o.state != State.Revealed && o.state != State.ClaimRequested) revert WrongState();
        if (block.timestamp < o.deadline) revert Invalid();
        Entitlement storage e = _awarded(o);
        uint256 amount = e.referenceUsdc;
        if (o.state == State.Revealed) amount = amount * configs[o.configId].quickSellBps / 10000;
        else pendingClaims[e.collection] -= 1;
        _settle(id, o, State.Compensated, amount);
    }

    function awarded(uint256 id) external view returns (Entitlement memory) {
        Opening storage o = openings[id];
        if (uint8(o.state) < uint8(State.Revealed)) revert WrongState();
        return _awarded(o);
    }

    /// @notice OpenZeppelin double-hashed leaf, so a leaf can never be read as an inner node.
    function tokenLeaf(address collection, uint256 tokenId) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(collection, tokenId))));
    }

    // ---------------------------------------------------------------- internals

    function _create(ConfigInput calldata input, Kind kind, address creator, uint16 feeBps, uint32 maxOpen)
        private
        returns (uint64 id)
    {
        if (
            input.priceUsdc == 0 || input.quickSellBps > 10000 || input.settlementWindow < 1 hours
                || input.settlementWindow > 30 days || input.metadataHash == bytes32(0) || maxOpen == 0
        ) revert Invalid();
        id = ++configCount;
        uint256 sum;
        uint128 maximum;
        address[] storage distinct = configCollections[id];
        for (uint8 t; t < 4; ++t) {
            sum += input.odds[t];
            Entitlement[] calldata tier = input.items[t];
            if ((input.odds[t] == 0) != (tier.length == 0) || tier.length > MAX_PER_TIER) revert Invalid();
            for (uint256 j; j < tier.length; ++j) {
                Entitlement calldata e = tier[j];
                if (e.minTokenId > e.maxTokenId || e.referenceUsdc == 0 || e.budgetUsdc == 0) revert Invalid();
                if (kind == Kind.Collection && e.tokenRoot == bytes32(0)) revert Invalid();
                if (!registry.isAdmitted(e.collection)) revert NotAdmitted(e.collection);
                uint128 liability = _liability(e);
                if (liability > maximum) maximum = liability;
                if (!_contains(distinct, e.collection)) {
                    if (distinct.length == MAX_COLLECTIONS) revert Invalid();
                    distinct.push(e.collection);
                }
                entitlements[id][t].push(e);
            }
        }
        if (sum != 10000 || (kind == Kind.Collection && distinct.length != 1)) revert Invalid();
        configs[id] = Config(
            kind,
            creator,
            input.gachaId,
            input.priceUsdc,
            maximum,
            input.settlementWindow,
            input.quickSellBps,
            feeBps,
            maxOpen,
            0,
            input.odds,
            input.metadataHash,
            true
        );
        emit Configured(id, input.gachaId, kind, creator, input.metadataHash);
    }

    /// @dev Frees a revealed opening's reservation at settlement; its slot under maxOpen was freed at finalize.
    function _release(Opening storage o) private {
        reserved -= o.liability;
        if (configs[o.configId].kind == Kind.Launchpad) launchpadReserved -= o.liability;
        o.liability = 0;
    }

    function _settle(uint256 id, Opening storage o, State terminal, uint256 amount) private {
        _release(o);
        o.state = terminal;
        usdc.safeTransfer(o.buyer, amount);
        emit Settled(id, terminal, amount);
    }

    function _awarded(Opening storage o) private view returns (Entitlement storage) {
        return entitlements[o.configId][o.tier][o.index];
    }

    function _liability(Entitlement memory e) private pure returns (uint128) {
        return e.referenceUsdc > e.budgetUsdc ? e.referenceUsdc : e.budgetUsdc;
    }

    function _contains(address[] storage list, address value) private view returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }

    function _buyer(Opening storage o) private view {
        if (msg.sender != o.buyer) revert Unauthorized();
    }

    function _receive(address from, uint256 amount) private {
        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(from, address(this), amount);
        if (usdc.balanceOf(address(this)) - beforeBalance != amount) revert Invalid();
    }
}
