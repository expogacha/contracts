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
 *       ChainlinkRandomness
 *       The Chainlink VRF v2.5 adapter behind every draw.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

interface IExpoRandomConsumer {
    function fulfillRandomness(uint256 id, uint256 word) external;
}

interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }
    function requestRandomWords(RandomWordsRequest calldata request) external returns (uint256);
}

/// @title Expo Gacha Chainlink VRF v2.5 adapter
/// @author Expo Gacha
/// @custom:website https://expogacha.com
/// @notice Single-pool Chainlink VRF v2.5 subscription adapter. Fund and register it separately.
contract ChainlinkRandomness {
    IVRFCoordinatorV2Plus public immutable coordinator;
    address public immutable installer;
    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;
    address public pool;
    mapping(uint256 => bool) public pending;
    error Unauthorized();

    constructor(address coordinator_, uint256 subId_, bytes32 keyHash_) {
        require(coordinator_.code.length != 0 && keyHash_ != bytes32(0));
        coordinator = IVRFCoordinatorV2Plus(coordinator_);
        subscriptionId = subId_;
        keyHash = keyHash_;
        installer = msg.sender;
    }

    function bindPool(address pool_) external {
        if (msg.sender != installer || pool != address(0) || pool_.code.length == 0) revert Unauthorized();
        pool = pool_;
    }

    function request() external returns (uint256 id) {
        if (msg.sender != pool) revert Unauthorized();
        id = coordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: 3,
                callbackGasLimit: 200000,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)
            })
        );
        require(id != 0 && !pending[id]);
        pending[id] = true;
    }

    function rawFulfillRandomWords(uint256 id, uint256[] calldata words) external {
        if (msg.sender != address(coordinator)) revert Unauthorized();
        if (!pending[id] || words.length != 1) return;
        delete pending[id];
        IExpoRandomConsumer(pool).fulfillRandomness(id, words[0]);
    }
}
