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
 *       ExpoVault
 *       Holds each NFT between its purchase and its delivery.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @notice The pool's view of waiting claims (ExpoGachaPool.pendingClaims).
interface IClaimLedger {
    function pendingClaims(address collection) external view returns (uint256);
}

/// @title Expo Gacha NFT vault
/// @author Expo Gacha
/// @custom:website https://expogacha.com
/// @notice Unaudited V3 NFT custody (docs/48), the implementation behind a Transparent upgradeable proxy whose
/// ProxyAdmin a Safe owns. Holds acquired tokens; only the bound pool can deliver them; the owner can recover a token
/// only while no claim of its collection is waiting. Executes no arbitrary calls. All state is ERC-7201 namespaced.
contract ExpoVault is Initializable, Ownable2StepUpgradeable, IERC721Receiver {
    /// @custom:storage-location erc7201:expogacha.storage.ExpoVault
    struct VaultStorage {
        address pool;
    }

    // keccak256(abi.encode(uint256(keccak256("expogacha.storage.ExpoVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant VAULT_STORAGE_LOCATION =
        0x07fa0e9dc988e566c07c843345abb578409fbf7c9666713e84229b081d2d3600;

    error Invalid();
    error Unauthorized();
    error TokenOwed(address collection);

    event PoolBound(address indexed pool);
    event Released(address indexed collection, uint256 indexed tokenId, address indexed to);
    event Recovered(address indexed collection, uint256 indexed tokenId, address indexed to);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Runs once, inside the proxy's deployment transaction (docs/48: no front-runnable initialization).
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert Invalid();
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    function pool() public view returns (address) {
        return _vault().pool;
    }

    /// @notice The EIP-1967 implementation slot of the proxy this code runs behind (zero when called directly). The
    /// admission registry binds evidence to this contract's code hash.
    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /// @dev One-time binding breaks the vault/pool constructor cycle.
    function bindPool(address pool_) external onlyOwner {
        VaultStorage storage $ = _vault();
        if ($.pool != address(0) || pool_.code.length == 0) revert Invalid();
        $.pool = pool_;
        emit PoolBound(pool_);
    }

    function release(address collection, uint256 tokenId, address to) external {
        if (msg.sender != _vault().pool) revert Unauthorized();
        _send(collection, tokenId, to);
        emit Released(collection, tokenId, to);
    }

    /// @notice Owner recovery of a token no buyer is waiting for: blocked while any claim awarded in `collection`
    /// waits for delivery, because the token the operator bought for it is not named until `fulfill` (docs/48).
    function recover(address collection, uint256 tokenId, address to) external onlyOwner {
        _notOwed(collection);
        _send(collection, tokenId, to);
        emit Recovered(collection, tokenId, to);
    }

    /// @notice Same rule as `recover`, through `safeTransferFrom` for collections that refuse `transferFrom` from the
    /// vault (docs/47-hostile-nft-audit HN-4). Still owner-only, still no arbitrary call: `to` is a recovery address, never a buyer path.
    function recoverSafe(address collection, uint256 tokenId, address to) external onlyOwner {
        _notOwed(collection);
        if (to == address(0) || to == address(this)) revert Invalid();
        IERC721(collection).safeTransferFrom(address(this), to, tokenId);
        emit Recovered(collection, tokenId, to);
    }

    /// @notice Disabled: without an owner, recovery would be lost for good.
    function renounceOwnership() public pure override {
        revert Invalid();
    }

    function _notOwed(address collection) private view {
        address p = _vault().pool;
        if (p != address(0) && IClaimLedger(p).pendingClaims(collection) != 0) revert TokenOwed(collection);
    }

    /// @dev transferFrom avoids receiver callbacks so plain smart-contract wallets can receive.
    function _send(address collection, uint256 tokenId, address to) private {
        if (to == address(0) || to == address(this)) revert Invalid();
        IERC721(collection).transferFrom(address(this), to, tokenId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _vault() private pure returns (VaultStorage storage $) {
        bytes32 slot = VAULT_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }
}
