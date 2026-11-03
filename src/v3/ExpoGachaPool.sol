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
/// gachas created by the owner, launchpad gachas created by the configurator from signed quotes. One reserve in the
/// pool token (USDC or WETH; names keep the historical `Usdc` suffix), split by per-configuration and launchpad caps.
/// v3.1 (docs/41): unclaimed openings compensate at the Quick Sell rate, `maxOpen` caps undrawn openings only, and a
/// guardian can only disable.
/// Upgradeable vault (docs/48): `fulfill` delivers only while the collection's review still matches the collection's
/// and the vault implementation's code, and `pendingClaims` tells the vault which collections it must not recover.
/// v3.2 (docs/46): tiers are bands of the machine price, items are drawn by value-decreasing weights, and prizes the
/// reserve cannot pay are locked: each opening fixes its cover before randomness is requested and can only draw items
/// whose liability that cover pays. A pending opening the VRF never answers is refunded after `VRF_TIMEOUT`.
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
        Compensated,
        Refunded
    }

    /// @dev A token range, optionally narrowed to a frozen Merkle set of token IDs (intra-collection tiers), with its
    /// draw weight inside the tier.
    struct Entitlement {
        address collection;
        uint256 minTokenId;
        uint256 maxTokenId;
        bytes32 tokenRoot;
        uint128 referenceUsdc;
        uint128 budgetUsdc;
        uint128 weight;
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

    /// @dev `tierCounts[t]`: the number of entitlements of tier t (arrays stay out of the generated getter).
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
        uint8[4] tierCounts;
        bytes32 metadataHash;
        bool enabled;
    }

    /// @dev Storage form of an entitlement: two packed slots always written, three written only when they differ
    /// from the whole-collection defaults (minTokenId 0, maxTokenId type(uint256).max, no Merkle root).
    struct StoredEntitlement {
        address collection;
        uint96 referenceUsdc;
        uint128 cumulativeWeight;
        uint96 budgetUsdc;
        bool boundedMax;
        uint256 minTokenId;
        uint256 maxTokenId;
        bytes32 tokenRoot;
    }

    /// @dev Two packed slots written at open. While `Pending`, `deadline` is the time after which `refundStale` is
    /// allowed; from `Revealed` it is the settlement deadline. `liability` is the reservation (max of the largest
    /// drawable liability and the refundable net price) until finalize, then the awarded liability. `cover` is the
    /// snapshot: with the configuration's immutable entitlements it fixes the drawable items and effective odds.
    struct Opening {
        address buyer;
        uint64 configId;
        State state;
        uint8 tier;
        uint16 index;
        uint64 deadline;
        uint96 liability;
        uint96 cover;
        uint256 word;
        uint256 tokenId;
    }

    uint256 public constant MAX_PER_TIER = 128;
    uint256 public constant MAX_ENTRIES = 128;
    uint256 public constant MAX_TIER_WEIGHT = type(uint128).max;
    uint256 public constant MAX_RETURN_BPS = 10000;
    uint256 public constant MAX_BUDGET_MARGIN_BPS = 5000;
    /// @notice Bound on every liability (and so on reference and budget): 2^96 - 1 base units, so a pending opening's
    /// reservation and cover pack into one slot.
    uint256 public constant MAX_LIABILITY = type(uint96).max;
    uint256 public constant VRF_TIMEOUT = 24 hours;
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
    /// @notice On-chain EV per opening with full weights (docs/46 7.3 check 6, floor); at most the price.
    mapping(uint64 => uint128) public expectedReference;
    /// @dev configId => tier << 7 | index => entitlement; per tier sorted by liability ascending.
    mapping(uint64 => mapping(uint256 => StoredEntitlement)) private entries;
    /// @dev configId => every liability of the configuration sorted ascending, two uint128 lanes per slot.
    mapping(uint64 => mapping(uint256 => uint256)) private sortedLiabilities;
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
    error CoverTooLow(uint256 cover);
    error NothingDrawable();

    event Configured(
        uint64 indexed configId, bytes32 indexed gachaId, Kind kind, address indexed creator, bytes32 metadataHash
    );
    event ConfigWeights(uint64 indexed configId, uint128[4] tierWeight, uint128 expectedReference);
    event EnabledChanged(uint64 indexed configId, bool enabled);
    event ConfiguratorSet(address configurator);
    event GuardianSet(address guardian);
    event GuardianDisabled(uint64 indexed configId);
    event LaunchpadCapSet(uint16 bps);
    event WithdrawCapProposed(uint256 cap, uint256 effectiveAt);
    event WithdrawCapSet(uint256 cap);
    event Withdrawn(address indexed to, uint256 amount);
    event CreatorFeesWithdrawn(address indexed creator, uint256 amount);
    /// @dev `cover` is the snapshot; `openingSnapshot(openingId)` expands it into drawable counts and effective odds.
    event Opened(
        uint256 indexed openingId,
        uint256 indexed requestId,
        address indexed buyer,
        uint64 configId,
        uint256 cover,
        uint256 reservation
    );
    event RandomReady(uint256 indexed openingId);
    event Revealed(uint256 indexed openingId, uint8 tier, uint32 index, address collection, uint64 deadline);
    event ClaimRequested(uint256 indexed openingId);
    event Delivered(uint256 indexed openingId, address indexed collection, uint256 tokenId, uint256 reimbursedUsdc);
    event Settled(uint256 indexed openingId, State state, uint256 amountUsdc);
    event StaleRefunded(uint256 indexed openingId, uint256 amount);

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
        return _expand(id, tier, _index(id, tier, index));
    }

    function entitlementCount(uint64 id, uint8 tier) external view returns (uint256) {
        return _count(configs[id], tier);
    }

    /// @notice Sum of the draw weights of items 0..index of the tier.
    function cumulativeWeight(uint64 id, uint8 tier, uint256 index) external view returns (uint128) {
        return entries[id][_index(id, tier, index)].cumulativeWeight;
    }

    /// @notice W_t: the sum of the tier's draw weights (zero for an empty tier).
    function tierWeight(uint64 id, uint8 tier) public view returns (uint128) {
        uint256 n = _count(configs[id], tier);
        return n == 0 ? 0 : entries[id][_key(tier, n - 1)].cumulativeWeight;
    }

    function collectionsOf(uint64 id) external view returns (address[] memory) {
        return configCollections[id];
    }

    // ---------------------------------------------------------------- treasury

    function fund(uint256 amount) external nonReentrant {
        _receive(msg.sender, amount);
    }

    /// @notice Pool tokens not backing an opening and not owed to creators.
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

    /// @notice Pays the price and fixes the opening's snapshot before randomness is requested (docs/46 5.3): the cover
    /// T (free reserve after the price, for a launch also the launchpad cap room) decides which items are drawable.
    /// Reverts `CoverTooLow` when T < `minCover` (the buyer's guard against a reserve change) and `NothingDrawable`
    /// when no Common item is covered.
    function open(uint64 configId, uint256 minCover) external nonReentrant returns (uint256 id) {
        Config storage c = configs[configId];
        if (!c.enabled) revert Invalid();
        address[] storage distinct = configCollections[configId];
        for (uint256 i; i < distinct.length; ++i) {
            if (!registry.isAdmitted(distinct[i])) revert NotAdmitted(distinct[i]);
        }
        if (c.openNow >= c.maxOpen) revert CapReached();
        uint256 price = c.priceUsdc;
        _receive(msg.sender, price);
        uint256 fee = price * c.creatorFeeBps / 10000;
        if (fee > 0) {
            creatorBalance[c.creator] += fee;
            creatorFeesOwed += fee;
        }
        uint256 cover = _cover(c.kind, usdc.balanceOf(address(this)), creatorFeesOwed);
        if (cover < minCover) revert CoverTooLow(cover);
        uint256 largest;
        if (cover >= c.maxLiability) {
            largest = c.maxLiability;
        } else {
            if (cover < _liability(entries[configId][0])) revert NothingDrawable();
            uint8[4] storage n = c.tierCounts;
            largest = _largestCovered(configId, uint256(n[0]) + n[1] + n[2] + n[3], cover);
        }
        uint256 reservation = _reservation(largest, price - fee, cover);
        reserved += reservation;
        if (c.kind == Kind.Launchpad) launchpadReserved += reservation;
        c.openNow += 1;
        id = ++openingCount;
        Opening storage o = openings[id];
        o.buyer = msg.sender;
        o.configId = configId;
        o.state = State.Pending;
        o.deadline = uint64(block.timestamp + VRF_TIMEOUT);
        // Both fit: reservation <= cover, every liability <= MAX_LIABILITY and the cover is capped there.
        // forge-lint: disable-next-line(unsafe-typecast)
        o.liability = uint96(reservation);
        // forge-lint: disable-next-line(unsafe-typecast)
        o.cover = uint96(cover > MAX_LIABILITY ? MAX_LIABILITY : cover);
        uint256 requestId = randomness.request();
        if (requestId == 0 || requestOpening[requestId] != 0) revert Invalid();
        requestOpening[requestId] = id;
        emit Opened(id, requestId, msg.sender, configId, cover, reservation);
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

    /// @notice Draws over the opening's snapshot (docs/46 5.4). Makes no transfer and never needs funds: the awarded
    /// liability was reserved at open; the rest of the reservation is released.
    function finalize(uint256 id) external {
        Opening storage o = openings[id];
        if (o.state != State.RandomReady) revert WrongState();
        uint64 configId = o.configId;
        Config storage c = configs[configId];
        (uint8 tier, uint256 index) = _draw(configId, o.cover, id, o.word);
        StoredEntitlement storage e = entries[configId][_key(tier, index)];
        uint256 value = _liability(e);
        uint256 released = o.liability - value;
        reserved -= released;
        if (c.kind == Kind.Launchpad) launchpadReserved -= released;
        // The outcome is known: the slot under maxOpen frees now; the awarded liability stays reserved until settlement.
        c.openNow -= 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        o.liability = uint96(value);
        o.tier = tier;
        // index < MAX_PER_TIER
        // forge-lint: disable-next-line(unsafe-typecast)
        o.index = uint16(index);
        o.deadline = uint64(block.timestamp + c.settlementWindow);
        o.state = State.Revealed;
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Revealed(id, tier, uint32(index), e.collection, o.deadline);
    }

    /// @notice docs/40 M-2 option A: anyone closes an opening the VRF has not answered within `VRF_TIMEOUT`. The buyer
    /// gets the price back, the creator fee is reversed (what the creator has not withdrawn; the reserve absorbs the
    /// rest when it can), the reservation and the slot are released. Later randomness is ignored.
    function refundStale(uint256 id) external nonReentrant {
        Opening storage o = openings[id];
        if (o.state != State.Pending) revert WrongState();
        if (block.timestamp < o.deadline) revert Invalid();
        Config storage c = configs[o.configId];
        uint256 price = c.priceUsdc;
        uint256 fee = price * c.creatorFeeBps / 10000;
        if (fee > 0) {
            uint256 unpaid = creatorBalance[c.creator];
            if (fee > unpaid) fee = unpaid;
            creatorBalance[c.creator] = unpaid - fee;
            creatorFeesOwed -= fee;
        }
        uint256 held = o.liability;
        reserved -= held;
        if (c.kind == Kind.Launchpad) launchpadReserved -= held;
        c.openNow -= 1;
        o.liability = 0;
        o.state = State.Refunded;
        // The reservation covers at least the net price; the free reserve now includes it and the reversed fee.
        uint256 free = freeReserve();
        uint256 amount = price > free ? free : price;
        usdc.safeTransfer(o.buyer, amount);
        emit StaleRefunded(id, amount);
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
        StoredEntitlement storage e = _awarded(o);
        address collection = e.collection;
        if (tokenId < e.minTokenId || (e.boundedMax && tokenId > e.maxTokenId)) revert Invalid();
        bytes32 root = e.tokenRoot;
        if (root != bytes32(0) && !MerkleProof.verifyCalldata(proof, root, tokenLeaf(collection, tokenId))) {
            revert Invalid();
        }
        // Never deliver under stale evidence: an upgraded vault, changed collection code or a revocation (docs/48).
        if (!registry.isDeliverable(collection)) revert NotAdmitted(collection);
        if (IERC721(collection).ownerOf(tokenId) != address(vault)) revert Invalid();
        uint256 budget = e.budgetUsdc;
        _release(o);
        o.state = State.Delivered;
        pendingClaims[collection] -= 1;
        o.tokenId = tokenId;
        vault.release(collection, tokenId, o.buyer);
        if (IERC721(collection).ownerOf(tokenId) != o.buyer) revert Invalid();
        usdc.safeTransfer(operator, budget);
        emit Delivered(id, collection, tokenId, budget);
        emit Settled(id, State.Delivered, budget);
    }

    /// @notice After the deadline: an opening the buyer never claimed pays the Quick Sell amount; one whose claim Expo
    /// failed to deliver pays the full reference.
    function compensate(uint256 id) external nonReentrant {
        Opening storage o = openings[id];
        if (o.state != State.Revealed && o.state != State.ClaimRequested) revert WrongState();
        if (block.timestamp < o.deadline) revert Invalid();
        StoredEntitlement storage e = _awarded(o);
        uint256 amount = e.referenceUsdc;
        if (o.state == State.Revealed) amount = amount * configs[o.configId].quickSellBps / 10000;
        else pendingClaims[e.collection] -= 1;
        _settle(id, o, State.Compensated, amount);
    }

    function awarded(uint256 id) external view returns (Entitlement memory) {
        Opening storage o = openings[id];
        State s = o.state;
        if (uint8(s) < uint8(State.Revealed) || s == State.Refunded) revert WrongState();
        return _expand(o.configId, o.tier, o.index);
    }

    /// @notice The snapshot `open` would take now, from the same functions: the cover after this price, the drawable
    /// count and effective odds per tier, and the reservation. `drawable[0] == 0` means `open` reverts
    /// `NothingDrawable`; a reservation above the cover (launchpad cap) means it reverts `CapReached`.
    function previewOpen(uint64 configId)
        external
        view
        returns (uint256 cover, uint16[4] memory drawable, uint16[4] memory odds, uint128 reservation)
    {
        Config storage c = configs[configId];
        uint256 price = c.priceUsdc;
        uint256 fee = price * c.creatorFeeBps / 10000;
        cover = _cover(c.kind, usdc.balanceOf(address(this)) + price, creatorFeesOwed + fee);
        uint256 largest;
        (drawable, odds, largest) = _snapshot(configId, cover);
        if (drawable[0] > 0) {
            uint256 r = largest > price - fee ? largest : price - fee;
            // forge-lint: disable-next-line(unsafe-typecast)
            reservation = uint128(r);
        }
    }

    /// @notice An opening's snapshot: its cover, and the drawable count and effective odds per tier derived from it.
    function openingSnapshot(uint256 id)
        external
        view
        returns (uint128 cover, uint16[4] memory drawable, uint16[4] memory odds)
    {
        Opening storage o = openings[id];
        cover = o.cover;
        (drawable, odds,) = _snapshot(o.configId, cover);
    }

    /// @notice The deterministic map `finalize` applies: (configuration, cover, opening ID, word) to (tier, index).
    function previewDraw(uint64 configId, uint256 cover, uint256 openingId, uint256 word)
        external
        view
        returns (uint8 tier, uint32 index)
    {
        if (_count(configs[configId], 0) == 0 || cover < _liability(entries[configId][0])) {
            revert NothingDrawable();
        }
        uint256 i;
        (tier, i) = _draw(configId, cover, openingId, word);
        // forge-lint: disable-next-line(unsafe-typecast)
        index = uint32(i);
    }

    /// @notice OpenZeppelin double-hashed leaf, so a leaf can never be read as an inner node.
    function tokenLeaf(address collection, uint256 tokenId) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(collection, tokenId))));
    }

    // ---------------------------------------------------------------- configuration internals

    /// @dev Running totals of `_create`, kept in memory to stay within the stack.
    struct Build {
        uint256 price;
        uint256 maximum;
        uint256 evNumerator;
        uint256 total;
        uint256 distinctCount;
        uint256 counts;
        uint256 ev;
        address[] distinct;
        uint256[] liabilities;
        uint256[5] runStart;
        uint128[4] tierWeight;
    }

    function _create(ConfigInput calldata input, Kind kind, address creator, uint16 feeBps, uint32 maxOpen)
        private
        returns (uint64 id)
    {
        if (
            input.priceUsdc == 0 || input.quickSellBps > 10000 || input.settlementWindow < 1 hours
                || input.settlementWindow > 30 days || input.metadataHash == bytes32(0) || maxOpen == 0
        ) revert Invalid();
        id = ++configCount;
        Build memory b;
        b.price = input.priceUsdc;
        uint256 total;
        uint256 sum;
        for (uint256 t; t < 4; ++t) {
            uint256 n = input.items[t].length;
            if ((input.odds[t] == 0) != (n == 0) || n > MAX_PER_TIER) revert Invalid();
            total += n;
            b.counts |= n << (8 * t);
            sum += input.odds[t];
        }
        if (total > MAX_ENTRIES || sum != 10000) revert Invalid();
        b.distinct = new address[](MAX_COLLECTIONS);
        b.liabilities = new uint256[](total);
        for (uint8 t; t < 4; ++t) {
            b.runStart[t] = b.total;
            _createTier(id, t, input.items[t], input.odds[t], kind, b);
        }
        b.runStart[4] = total;
        if (kind == Kind.Collection && b.distinctCount != 1) revert Invalid();
        // EV ceiling (docs/46 7.3 check 6): expected reference payout with full weights, floor, at most the price.
        b.ev = b.evNumerator / 10000;
        if (b.ev > b.price * MAX_RETURN_BPS / 10000) revert Invalid();
        _storeSorted(id, b);
        address[] memory distinct = b.distinct;
        uint256 dc = b.distinctCount;
        assembly ("memory-safe") {
            mstore(distinct, dc)
        }
        configCollections[id] = distinct;
        _storeConfig(id, input, kind, creator, feeBps, maxOpen, b);
    }

    function _storeConfig(
        uint64 id,
        ConfigInput calldata input,
        Kind kind,
        address creator,
        uint16 feeBps,
        uint32 maxOpen,
        Build memory b
    ) private {
        Config storage c = configs[id];
        c.kind = kind;
        c.creator = creator;
        c.gachaId = input.gachaId;
        c.priceUsdc = input.priceUsdc;
        // maximum <= MAX_LIABILITY, counts < 2^32 and ev <= price: the casts are exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.maxLiability = uint128(b.maximum);
        c.settlementWindow = input.settlementWindow;
        c.quickSellBps = input.quickSellBps;
        c.creatorFeeBps = feeBps;
        c.maxOpen = maxOpen;
        for (uint256 t; t < 4; ++t) {
            // counts are at most MAX_PER_TIER
            // forge-lint: disable-next-line(unsafe-typecast)
            c.tierCounts[t] = uint8(b.counts >> (8 * t));
        }
        c.odds = input.odds;
        c.metadataHash = input.metadataHash;
        c.enabled = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        expectedReference[id] = uint128(b.ev);
        emit Configured(id, input.gachaId, kind, creator, input.metadataHash);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit ConfigWeights(id, b.tierWeight, uint128(b.ev));
    }

    /// @dev Validates and stores one tier (docs/46 7.3 checks 2 to 5): positive weights summing to at most
    /// MAX_TIER_WEIGHT, liabilities non-decreasing and weights non-increasing, every reference in the tier's band of
    /// the price (launches only), budget at most 1.5 x reference, liability at most MAX_LIABILITY; plus the v3.1 entry
    /// checks.
    function _createTier(uint64 id, uint8 t, Entitlement[] calldata tier, uint16 odds, Kind kind, Build memory b)
        private
    {
        // [cumulative weight, previous liability, previous weight]
        uint256[3] memory run = [uint256(0), 0, type(uint256).max];
        for (uint256 j; j < tier.length; ++j) {
            _createEntry(id, t, j, tier[j], kind, b, run);
        }
        uint256 cum = run[0];
        if (cum == 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        b.tierWeight[t] = uint128(cum);
        uint256 mean;
        for (uint256 j; j < tier.length; ++j) {
            // weight < 2^128 and reference < 2^96: no overflow.
            mean += uint256(tier[j].weight) * tier[j].referenceUsdc / cum;
        }
        b.evNumerator += uint256(odds) * mean;
    }

    function _createEntry(
        uint64 id,
        uint8 t,
        uint256 j,
        Entitlement calldata e,
        Kind kind,
        Build memory b,
        uint256[3] memory run
    ) private {
        uint256 liability = _checkEntry(e, kind, t, b.price);
        uint256 weight = e.weight;
        if (liability < run[1] || weight == 0 || weight > run[2]) revert Invalid();
        uint256 cum = run[0] + weight;
        if (cum > MAX_TIER_WEIGHT) revert Invalid();
        run[0] = cum;
        run[1] = liability;
        run[2] = weight;
        if (liability > b.maximum) b.maximum = liability;
        _noteCollection(b, e.collection);
        _storeEntry(entries[id][_key(t, j)], e, cum);
        b.liabilities[b.total++] = liability;
    }

    function _storeEntry(StoredEntitlement storage s, Entitlement calldata e, uint256 cum) private {
        s.collection = e.collection;
        // reference and budget <= liability <= MAX_LIABILITY; cum <= MAX_TIER_WEIGHT.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.referenceUsdc = uint96(e.referenceUsdc);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.cumulativeWeight = uint128(cum);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.budgetUsdc = uint96(e.budgetUsdc);
        if (e.maxTokenId != type(uint256).max) {
            s.boundedMax = true;
            s.maxTokenId = e.maxTokenId;
        }
        if (e.minTokenId != 0) s.minTokenId = e.minTokenId;
        if (e.tokenRoot != bytes32(0)) s.tokenRoot = e.tokenRoot;
    }

    function _checkEntry(Entitlement calldata e, Kind kind, uint8 t, uint256 price) private pure returns (uint256 l) {
        uint256 v = e.referenceUsdc;
        uint256 budget = e.budgetUsdc;
        if (e.minTokenId > e.maxTokenId || v == 0 || budget == 0) revert Invalid();
        if (kind == Kind.Collection && e.tokenRoot == bytes32(0)) revert Invalid();
        // Bands of the gross price (docs/46 2.1), integer tests; a boundary value belongs to the higher tier. They bind
        // launches: the owner's rarity and ETF tiers are reviewed as published (docs/46 section 17).
        bool inBand = kind != Kind.Launchpad;
        if (!inBand) {
            if (t == 0) inBand = 2 * v >= price && v < price;
            else if (t == 1) inBand = v >= price && v < 2 * price;
            else if (t == 2) inBand = v >= 2 * price && v < 4 * price;
            else inBand = v >= 4 * price;
        }
        if (!inBand || budget > v * (10000 + MAX_BUDGET_MARGIN_BPS) / 10000) revert Invalid();
        l = v > budget ? v : budget;
        if (l > MAX_LIABILITY) revert Invalid();
    }

    /// @dev Admission is checked once per distinct collection.
    function _noteCollection(Build memory b, address collection) private view {
        address[] memory list = b.distinct;
        uint256 n = b.distinctCount;
        for (uint256 i; i < n; ++i) {
            if (list[i] == collection) return;
        }
        if (n == MAX_COLLECTIONS) revert Invalid();
        if (!registry.isAdmitted(collection)) revert NotAdmitted(collection);
        list[n] = collection;
        b.distinctCount = n + 1;
    }

    /// @dev Merges the four per-tier sorted runs into one ascending list, two uint128 lanes per slot.
    function _storeSorted(uint64 id, Build memory b) private {
        uint256 n = b.total;
        uint256[] memory l = b.liabilities;
        uint256[4] memory pos = [b.runStart[0], b.runStart[1], b.runStart[2], b.runStart[3]];
        uint256 lane;
        for (uint256 k; k < n; ++k) {
            uint256 best = type(uint256).max;
            uint256 from;
            for (uint256 t; t < 4; ++t) {
                uint256 p = pos[t];
                if (p < b.runStart[t + 1] && l[p] < best) {
                    best = l[p];
                    from = t;
                }
            }
            pos[from] += 1;
            if (k & 1 == 0) {
                lane = best;
            } else {
                sortedLiabilities[id][k >> 1] = lane | (best << 128);
            }
        }
        if (n & 1 == 1) sortedLiabilities[id][n >> 1] = lane;
    }

    // ---------------------------------------------------------------- draw internals

    /// @dev The cover: free reserve given `balance` and `owed` creator fees; for a launch, at most the launchpad cap room.
    function _cover(Kind kind, uint256 balance, uint256 owed) private view returns (uint256 cover) {
        cover = balance - reserved - owed;
        if (kind == Kind.Launchpad) {
            uint256 cap = (balance - owed) * launchpadCapBps / 10000;
            uint256 room = cap > launchpadReserved ? cap - launchpadReserved : 0;
            if (room < cover) cover = room;
        }
    }

    /// @dev A pending opening holds max(L, net price) so a stale refund is always payable; at most the cover.
    function _reservation(uint256 largest, uint256 net, uint256 cover) private pure returns (uint256 r) {
        r = largest > net ? largest : net;
        if (r > cover) revert CapReached(); // only through the launchpad cap
    }

    /// @dev Drawable count per tier, effective odds after the locked-tier cascade, and the largest drawable liability.
    function _snapshot(uint64 id, uint256 cover)
        internal
        view
        returns (uint16[4] memory drawable, uint16[4] memory odds, uint256 largest)
    {
        Config storage c = configs[id];
        odds = c.odds;
        bool all = cover >= c.maxLiability;
        for (uint8 t; t < 4; ++t) {
            uint256 n = _count(c, t);
            uint256 m = all ? n : _prefix(id, t, n, cover);
            // forge-lint: disable-next-line(unsafe-typecast)
            drawable[t] = uint16(m);
            if (m > 0) {
                uint256 l = _liability(entries[id][_key(t, m - 1)]);
                if (l > largest) largest = l;
            }
        }
        _cascade(odds, drawable);
    }

    /// @dev Locked-tier cascade (docs/46 3.3): a tier with odds and nothing drawable gives its odds to the next tier down.
    function _cascade(uint16[4] memory odds, uint16[4] memory drawable) private pure {
        for (uint256 t = 3; t > 0; --t) {
            if (drawable[t] == 0 && odds[t] > 0) {
                odds[t - 1] += odds[t];
                odds[t] = 0;
            }
        }
    }

    /// @dev The tier from the word's low digits over the effective odds, then the item over the tier's drawable prefix
    /// by cumulative weight. Requires a covered Common item.
    function _draw(uint64 id, uint256 cover, uint256 openingId, uint256 word)
        internal
        view
        returns (uint8 tier, uint256 index)
    {
        Config storage c = configs[id];
        bool all = cover >= c.maxLiability;
        tier = _drawTier(id, c, all, cover, word % 10000);
        uint256 count = _count(c, tier);
        uint256 m = all ? count : _prefix(id, tier, count, cover);
        uint256 total = entries[id][_key(tier, m - 1)].cumulativeWeight;
        index = _pick(id, tier, m, uint256(keccak256(abi.encode("EXPO_WEIGHTED_ITEM", openingId, word))) % total);
    }

    /// @dev The tier of `roll` over the effective odds. Only whether a tier is locked matters for the cascade: its
    /// first (cheapest) item is covered or not; Common is covered (checked at open).
    function _drawTier(uint64 id, Config storage c, bool all, uint256 cover, uint256 roll)
        private
        view
        returns (uint8 tier)
    {
        uint16[4] memory odds = c.odds;
        uint16[4] memory unlocked;
        for (uint8 t; t < 4; ++t) {
            if (_count(c, t) > 0 && (all || t == 0 || cover >= _liability(entries[id][_key(t, 0)]))) unlocked[t] = 1;
        }
        _cascade(odds, unlocked);
        uint256 boundary;
        for (; tier < 3; ++tier) {
            boundary += odds[tier];
            if (roll < boundary) break;
        }
    }

    /// @dev Number of items of the tier whose liability is at most `cover` (a prefix: the tier is sorted).
    function _prefix(uint64 id, uint8 tier, uint256 n, uint256 cover) internal view returns (uint256) {
        if (n == 0) return 0;
        if (_liability(entries[id][_key(tier, n - 1)]) <= cover) return n;
        uint256 lo;
        uint256 hi = n - 1; // liability[hi] > cover
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_liability(entries[id][_key(tier, mid)]) > cover) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    /// @dev First index j < m with cumulative[j] > r, for r < cumulative[m - 1].
    function _pick(uint64 id, uint8 tier, uint256 m, uint256 r) internal view returns (uint256) {
        uint256 lo;
        uint256 hi = m - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (entries[id][_key(tier, mid)].cumulativeWeight > r) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    /// @dev Largest liability of the configuration at most `cover`; the smallest one is known to be covered.
    function _largestCovered(uint64 id, uint256 n, uint256 cover) private view returns (uint256) {
        uint256 lo;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) >> 1;
            if (_sortedAt(id, mid) <= cover) lo = mid;
            else hi = mid - 1;
        }
        return _sortedAt(id, lo);
    }

    function _sortedAt(uint64 id, uint256 i) private view returns (uint256) {
        return (sortedLiabilities[id][i >> 1] >> ((i & 1) << 7)) & type(uint128).max;
    }

    // ---------------------------------------------------------------- internals

    function _key(uint256 tier, uint256 index) private pure returns (uint256) {
        return (tier << 7) | index;
    }

    function _count(Config storage c, uint256 tier) private view returns (uint256) {
        return c.tierCounts[tier];
    }

    function _index(uint64 id, uint8 tier, uint256 index) private view returns (uint256) {
        if (tier > 3 || index >= _count(configs[id], tier)) revert Invalid();
        return _key(tier, index);
    }

    function _expand(uint64 id, uint8 tier, uint256 index) private view returns (Entitlement memory e) {
        StoredEntitlement storage s = entries[id][_key(tier, index)];
        uint256 previous = index == 0 ? 0 : entries[id][_key(tier, index - 1)].cumulativeWeight;
        e = Entitlement(
            s.collection,
            s.minTokenId,
            s.boundedMax ? s.maxTokenId : type(uint256).max,
            s.tokenRoot,
            s.referenceUsdc,
            s.budgetUsdc,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(s.cumulativeWeight - previous)
        );
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

    function _awarded(Opening storage o) private view returns (StoredEntitlement storage) {
        return entries[o.configId][_key(o.tier, o.index)];
    }

    function _liability(StoredEntitlement storage e) private view returns (uint256) {
        uint256 v = e.referenceUsdc;
        uint256 b = e.budgetUsdc;
        return v > b ? v : b;
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
