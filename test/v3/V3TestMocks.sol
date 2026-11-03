// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Cheatcodes used by the V3 adversarial and invariant suites (no forge-std in this workspace).
interface AdvVm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function deal(address, uint256) external;
    function chainId(uint256) external;
    function store(address, bytes32, bytes32) external;
    function load(address, bytes32) external view returns (bytes32);
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
    function expectEmit(address) external;
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function addr(uint256) external returns (address);
    function etch(address, bytes calldata) external;
}

/// @dev ERC-20 that can switch on a 1% transfer fee (burned), to prove the pool refuses short receipts.
contract FeeOnTransferToken is ERC20 {
    bool public feeOn;

    constructor() ERC20("Fee Token - NO VALUE", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(bool on) external {
        feeOn = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOn && from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

interface IRandomConsumer {
    function fulfillRandomness(uint256 id, uint256 word) external;
}

/// @dev Randomness provider whose request IDs and callbacks are fully scripted by the test: it can answer unknown,
/// duplicate or out-of-order IDs, and can be told to return a zero or an already used request ID.
contract ScriptedRandomness {
    uint256 public count;
    bool public forceNext;
    uint256 public forcedId;

    function force(uint256 id) external {
        forceNext = true;
        forcedId = id;
    }

    function request() external returns (uint256) {
        if (forceNext) {
            forceNext = false;
            return forcedId;
        }
        return ++count;
    }

    function push(address consumer, uint256 id, uint256 word) external {
        IRandomConsumer(consumer).fulfillRandomness(id, word);
    }
}

/// @dev Upgrade target for proxy tests: an ERC-721 with the same storage layout as MockNFT that refuses every
/// transfer after minting (as a soulbound or transfer-validator upgrade would).
contract LockedNFTImpl is ERC721 {
    constructor() ERC721("Locked", "LOCK") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (_ownerOf(id) != address(0)) revert("transfers locked");
        return super._update(to, id, auth);
    }
}

/// @dev OpenZeppelin-style sorted-pair Merkle helpers over the pool's double-hashed (collection, tokenId) leaves.
library TokenSets {
    function leaf(address collection, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(collection, tokenId))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Root of a four-leaf tree over `ids` of `collection`.
    function root4(address collection, uint256[4] memory ids) internal pure returns (bytes32) {
        bytes32[4] memory l = _leaves(collection, ids);
        return pair(pair(l[0], l[1]), pair(l[2], l[3]));
    }

    /// @dev Proof for `ids[index]` in the four-leaf tree of `root4`.
    function proof4(address collection, uint256[4] memory ids, uint256 index)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        bytes32[4] memory l = _leaves(collection, ids);
        proof = new bytes32[](2);
        proof[0] = l[index ^ 1];
        proof[1] = index < 2 ? pair(l[2], l[3]) : pair(l[0], l[1]);
    }

    function _leaves(address collection, uint256[4] memory ids) private pure returns (bytes32[4] memory l) {
        for (uint256 i; i < 4; ++i) {
            l[i] = leaf(collection, ids[i]);
        }
    }
}
