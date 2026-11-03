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
 *       ExpoLegacyVault
 *       Holds each NFT between its purchase and its delivery.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Unaudited NFT custody for collection settlement V2 (docs/28), kept for the deployed V2 pool; V3 uses the
/// upgradeable ExpoVault (docs/48). Holds acquired tokens; only the bound
/// pool can deliver them, only the owner can recover undelivered ones. Executes no arbitrary calls.
contract ExpoLegacyVault is Ownable, IERC721Receiver {
    address public pool;

    error Invalid();
    error Unauthorized();

    event PoolBound(address indexed pool);
    event Released(address indexed collection, uint256 indexed tokenId, address indexed to);
    event Recovered(address indexed collection, uint256 indexed tokenId, address indexed to);

    constructor(address admin) Ownable(admin) {}

    /// @dev One-time binding breaks the vault/pool constructor cycle without an upgradeable pointer.
    function bindPool(address pool_) external onlyOwner {
        if (pool != address(0) || pool_.code.length == 0) revert Invalid();
        pool = pool_;
        emit PoolBound(pool_);
    }

    function release(address collection, uint256 tokenId, address to) external {
        if (msg.sender != pool) revert Unauthorized();
        _send(collection, tokenId, to);
        emit Released(collection, tokenId, to);
    }

    function recover(address collection, uint256 tokenId, address to) external onlyOwner {
        _send(collection, tokenId, to);
        emit Recovered(collection, tokenId, to);
    }

    /// @dev transferFrom avoids receiver callbacks so plain smart-contract wallets can receive.
    function _send(address collection, uint256 tokenId, address to) private {
        if (to == address(0) || to == address(this)) revert Invalid();
        IERC721(collection).transferFrom(address(this), to, tokenId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
