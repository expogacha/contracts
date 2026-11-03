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
 *       ExpoPool
 *       The first pool: its randomness interface is still used by every line.
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

interface IRandomness {
    function request() external returns (uint256);
}

/// @notice Unaudited post-draw acquisition protocol. USDC amounts use 6 decimals.
contract ExpoPool is Ownable, ReentrancyGuard {
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

    struct Outcome {
        address collection;
        uint256 tokenId;
        uint128 valueUsdc;
    }

    struct Config {
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
        uint32 outcomeIndex;
        uint256 word;
    }
    IERC20 public immutable usdc;
    IRandomness public immutable randomness;
    address public immutable operator;
    uint256 public reserved;
    uint64 public configCount;
    uint256 public openingCount;
    mapping(uint64 => Config) public configs;
    mapping(uint64 => mapping(uint8 => Outcome[])) private prizes;
    mapping(uint256 => Opening) public openings;
    mapping(uint256 => uint256) public requestOpening;

    error Invalid();
    error Unauthorized();
    error WrongState();
    error Insolvent();
    error Expired();
    event Configured(uint64 indexed configId, bytes32 metadataHash);
    event Opened(uint256 indexed openingId, uint256 indexed requestId, address indexed buyer, uint64 configId);
    event RandomReady(uint256 indexed openingId);
    event Revealed(uint256 indexed openingId, uint8 tier, uint32 outcomeIndex, uint64 deadline);
    event ClaimRequested(uint256 indexed openingId);
    event Settled(uint256 indexed openingId, State state, uint256 amountUsdc);

    constructor(IERC20 token, IRandomness provider, address fulfiller, address admin) Ownable(admin) {
        if (address(token).code.length == 0 || address(provider).code.length == 0 || fulfiller == address(0)) {
            revert Invalid();
        }
        usdc = token;
        randomness = provider;
        operator = fulfiller;
    }

    function createConfig(
        uint128 price,
        uint16[4] calldata odds,
        uint16 sellBps,
        uint32 window,
        bytes32 metadataHash,
        Outcome[][4] calldata items
    ) external onlyOwner returns (uint64 id) {
        if (price == 0 || sellBps > 10000 || window < 1 hours || window > 30 days || metadataHash == bytes32(0)) revert Invalid();
        uint256 sum;
        uint128 maximum;
        id = ++configCount;
        for (uint8 t; t < 4; ++t) {
            sum += odds[t];
            if ((odds[t] == 0) != (items[t].length == 0) || items[t].length > 1024) revert Invalid();
            for (uint256 j; j < items[t].length; ++j) {
                Outcome calldata o = items[t][j];
                if (o.collection.code.length == 0 || o.valueUsdc == 0) revert Invalid();
                if (o.valueUsdc > maximum) maximum = o.valueUsdc;
                prizes[id][t].push(o);
            }
        }
        if (sum != 10000) revert Invalid();
        configs[id] = Config(price, maximum, window, sellBps, odds, metadataHash, true);
        emit Configured(id, metadataHash);
    }

    function setEnabled(uint64 id, bool enabled) external onlyOwner {
        if (configs[id].priceUsdc == 0) revert Invalid();
        configs[id].enabled = enabled;
    }

    function outcome(uint64 id, uint8 tier, uint256 index) external view returns (Outcome memory) {
        return prizes[id][tier][index];
    }

    function outcomeCount(uint64 id, uint8 tier) external view returns (uint256) {
        return prizes[id][tier].length;
    }

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

    function open(uint64 configId) external nonReentrant returns (uint256 id) {
        Config storage c = configs[configId];
        if (!c.enabled) revert Invalid();
        _receive(msg.sender, c.priceUsdc);
        if (freeReserve() < c.maxLiability) revert Insolvent();
        reserved += c.maxLiability;
        id = ++openingCount;
        openings[id] = Opening(msg.sender, configId, State.Pending, 0, c.maxLiability, 0, 0, 0);
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
        uint256 roll = o.word % 10000;
        uint256 boundary;
        uint8 tier;
        Config storage c = configs[o.configId];
        for (; tier < 4; ++tier) {
            boundary += c.odds[tier];
            if (roll < boundary) break;
        }
        o.tier = tier;
        o.outcomeIndex =
            uint32(uint256(keccak256(abi.encode("EXPO_OUTCOME", id, o.word))) % prizes[o.configId][tier].length);
        uint128 value = prizes[o.configId][tier][o.outcomeIndex].valueUsdc;
        reserved -= o.liability - value;
        o.liability = value;
        o.deadline = uint64(block.timestamp + c.settlementWindow);
        o.state = State.Revealed;
        emit Revealed(id, tier, o.outcomeIndex, o.deadline);
    }

    function quickSell(uint256 id) external nonReentrant {
        Opening storage o = openings[id];
        _buyer(o);
        if (o.state != State.Revealed) revert WrongState();
        if (block.timestamp >= o.deadline) revert Expired();
        uint256 amount = uint256(o.liability) * configs[o.configId].quickSellBps / 10000;
        _settle(id, o, State.QuickSold, amount, o.buyer);
    }

    function claimNFT(uint256 id) external {
        Opening storage o = openings[id];
        _buyer(o);
        if (o.state != State.Revealed) revert WrongState();
        if (block.timestamp >= o.deadline) revert Expired();
        o.state = State.ClaimRequested;
        emit ClaimRequested(id);
    }

    function deliver(uint256 id) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        Opening storage o = openings[id];
        if (o.state != State.ClaimRequested) revert WrongState();
        if (block.timestamp >= o.deadline) revert Expired();
        Outcome storage asset = prizes[o.configId][o.tier][o.outcomeIndex];
        if (IERC721(asset.collection).ownerOf(asset.tokenId) != operator) revert Invalid();
        // Checks-effects-interactions; failed ownership or transfer reverts the entire settlement.
        uint256 budget = o.liability;
        o.state = State.Delivered;
        reserved -= budget;
        o.liability = 0;
        IERC721(asset.collection).transferFrom(operator, o.buyer, asset.tokenId);
        if (IERC721(asset.collection).ownerOf(asset.tokenId) != o.buyer) revert Invalid();
        usdc.safeTransfer(operator, budget);
        emit Settled(id, State.Delivered, budget);
    }

    function compensate(uint256 id) external nonReentrant {
        Opening storage o = openings[id];
        if (o.state != State.Revealed && o.state != State.ClaimRequested) revert WrongState();
        if (block.timestamp < o.deadline) revert Invalid();
        _settle(id, o, State.Compensated, o.liability, o.buyer);
    }

    function _settle(uint256 id, Opening storage o, State terminal, uint256 amount, address to) private {
        reserved -= o.liability;
        o.liability = 0;
        o.state = terminal;
        usdc.safeTransfer(to, amount);
        emit Settled(id, terminal, amount);
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
