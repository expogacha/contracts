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
 *       IExpoPool
 *       The interface of the first pool.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

/// @notice Design vocabulary only. No implementation or audit is supplied.
interface IExpoPool {
    enum DrawState { None, Requested, RandomnessReady, Allocated, Claimed }

    struct InventoryItem {
        address collection;
        uint256 tokenId;
    }

    event DrawRequested(uint256 indexed drawId, address indexed buyer, uint256 inventoryVersion, address recipient);
    event RandomnessStored(uint256 indexed drawId, uint256 indexed providerRequestId);
    event DrawAllocated(uint256 indexed drawId, address indexed collection, uint256 tokenId);
    event PrizeClaimed(uint256 indexed drawId, address indexed recipient);

    function purchase(uint256 expectedVersion, uint256 expectedPriceWei, address recipient, bytes calldata eligibility) external payable returns (uint256 drawId);
    function allocate(uint256 drawId) external;
    function claim(uint256 drawId) external;
    function drawState(uint256 drawId) external view returns (DrawState);
    function inventoryVersion() external view returns (uint256);
    function remainingCount() external view returns (uint256);
}
