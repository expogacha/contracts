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
 *       ExpoCollectionPool
 *       The V2 pool: a pull awards a collection, the operator delivers a token.
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
import {IRandomness} from "./ExpoPool.sol";
import {ExpoLegacyVault} from "./ExpoLegacyVault.sol";

interface ICollectionAdmission {
    function isAdmitted(bytes32 machineId, address collection) external view returns (bool);
}

/// @notice Unaudited collection-entitlement settlement (docs/28). A pull awards a collection and token range;
/// the exact token is fixed only when the operator delivers it from the Expo vault. USDC amounts use 6 decimals.
contract ExpoCollectionPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

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

    struct Entitlement {
        address collection;
        uint256 minTokenId;
        uint256 maxTokenId;
        uint128 referenceUsdc;
        uint128 budgetUsdc;
    }

    struct Config {
        bytes32 machineId;
        uint128 priceUsdc;
        uint128 maxLiability;
        uint32 settlementWindow;
        uint16 quickSellBps;
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

    IERC20 public immutable usdc;
    IRandomness public immutable randomness;
    ExpoLegacyVault public immutable vault;
    ICollectionAdmission public immutable registry;
    address public immutable operator;

    uint256 public reserved;
    uint64 public configCount;
    uint256 public openingCount;
    mapping(uint64 => Config) public configs;
    mapping(uint64 => mapping(uint8 => Entitlement[])) private entitlements;
    mapping(uint64 => address[]) private configCollections;
    mapping(uint256 => Opening) public openings;
    mapping(uint256 => uint256) public requestOpening;

    error Invalid();
    error Unauthorized();
    error WrongState();
    error Insolvent();
    error Expired();
    error NotAdmitted(address collection);

    event Configured(uint64 indexed configId, bytes32 indexed machineId, bytes32 metadataHash);
    event Opened(uint256 indexed openingId, uint256 indexed requestId, address indexed buyer, uint64 configId);
    event RandomReady(uint256 indexed openingId);
    event Revealed(uint256 indexed openingId, uint8 tier, uint32 index, address collection, uint64 deadline);
    event ClaimRequested(uint256 indexed openingId);
    event Delivered(uint256 indexed openingId, address indexed collection, uint256 tokenId, uint256 reimbursedUsdc);
    event Settled(uint256 indexed openingId, State state, uint256 amountUsdc);

    constructor(IERC20 token, IRandomness provider, ExpoLegacyVault vault_, ICollectionAdmission registry_, address fulfiller, address admin)
        Ownable(admin)
    {
        if (
            address(token).code.length == 0 || address(provider).code.length == 0 || address(vault_).code.length == 0
                || address(registry_).code.length == 0 || fulfiller == address(0)
        ) revert Invalid();
        usdc = token;
        randomness = provider;
        vault = vault_;
        registry = registry_;
        operator = fulfiller;
    }

    // ---------------------------------------------------------------- configuration

    function createConfig(
        bytes32 machineId,
        uint128 price,
        uint16[4] calldata odds,
        uint16 sellBps,
        uint32 window,
        bytes32 metadataHash,
        Entitlement[][4] calldata items
    ) external onlyOwner returns (uint64 id) {
        if (price == 0 || sellBps > 10000 || window < 1 hours || window > 30 days || metadataHash == bytes32(0)) revert Invalid();
        id = ++configCount;
        uint256 sum;
        uint128 maximum;
        address[] storage distinct = configCollections[id];
        for (uint8 t; t < 4; ++t) {
            sum += odds[t];
            if ((odds[t] == 0) != (items[t].length == 0) || items[t].length > MAX_PER_TIER) revert Invalid();
            for (uint256 j; j < items[t].length; ++j) {
                Entitlement calldata e = items[t][j];
                if (e.minTokenId > e.maxTokenId || e.referenceUsdc == 0 || e.budgetUsdc == 0) revert Invalid();
                if (!registry.isAdmitted(machineId, e.collection)) revert NotAdmitted(e.collection);
                uint128 liability = _liability(e);
                if (liability > maximum) maximum = liability;
                if (!_contains(distinct, e.collection)) {
                    if (distinct.length == MAX_COLLECTIONS) revert Invalid();
                    distinct.push(e.collection);
                }
                entitlements[id][t].push(e);
            }
        }
        if (sum != 10000) revert Invalid();
        configs[id] = Config(machineId, price, maximum, window, sellBps, odds, metadataHash, true);
        emit Configured(id, machineId, metadataHash);
    }

    function setEnabled(uint64 id, bool enabled) external onlyOwner {
        if (configs[id].priceUsdc == 0) revert Invalid();
        configs[id].enabled = enabled;
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

    function freeReserve() public view returns (uint256) {
        return usdc.balanceOf(address(this)) - reserved;
    }

    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || amount > freeReserve()) revert Insolvent();
        usdc.safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------- lifecycle

    function open(uint64 configId) external nonReentrant returns (uint256 id) {
        Config storage c = configs[configId];
        if (!c.enabled) revert Invalid();
        // Revocation blocks new commitments on-chain (docs/23, docs/28).
        address[] storage distinct = configCollections[configId];
        for (uint256 i; i < distinct.length; ++i) {
            if (!registry.isAdmitted(c.machineId, distinct[i])) revert NotAdmitted(distinct[i]);
        }
        _receive(msg.sender, c.priceUsdc);
        if (freeReserve() < c.maxLiability) revert Insolvent();
        reserved += c.maxLiability;
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
        reserved -= o.liability - value;
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
        emit ClaimRequested(id);
    }

    /// @notice Operator delivers an acquired token from the vault. The token is chosen here, never before the draw.
    function fulfill(uint256 id, uint256 tokenId) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        Opening storage o = openings[id];
        if (o.state != State.ClaimRequested) revert WrongState();
        if (block.timestamp >= o.deadline) revert Expired();
        Entitlement storage e = _awarded(o);
        if (tokenId < e.minTokenId || tokenId > e.maxTokenId) revert Invalid();
        if (IERC721(e.collection).ownerOf(tokenId) != address(vault)) revert Invalid();
        // Checks-effects-interactions: any failed transfer or ownership check reverts the whole settlement.
        uint256 budget = e.budgetUsdc;
        reserved -= o.liability;
        o.liability = 0;
        o.state = State.Delivered;
        o.tokenId = tokenId;
        vault.release(e.collection, tokenId, o.buyer);
        if (IERC721(e.collection).ownerOf(tokenId) != o.buyer) revert Invalid();
        usdc.safeTransfer(operator, budget);
        emit Delivered(id, e.collection, tokenId, budget);
        emit Settled(id, State.Delivered, budget);
    }

    function compensate(uint256 id) external nonReentrant {
        Opening storage o = openings[id];
        if (o.state != State.Revealed && o.state != State.ClaimRequested) revert WrongState();
        if (block.timestamp < o.deadline) revert Invalid();
        _settle(id, o, State.Compensated, _awarded(o).referenceUsdc);
    }

    function awarded(uint256 id) external view returns (Entitlement memory) {
        Opening storage o = openings[id];
        if (uint8(o.state) < uint8(State.Revealed)) revert WrongState();
        return _awarded(o);
    }

    // ---------------------------------------------------------------- internals

    function _settle(uint256 id, Opening storage o, State terminal, uint256 amount) private {
        reserved -= o.liability;
        o.liability = 0;
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
        for (uint256 i; i < list.length; ++i) if (list[i] == value) return true;
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
