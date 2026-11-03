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
 *       ExpoAdmissionRegistry
 *       Which collections the vault is proven able to deliver.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice The vault reports the EIP-1967 implementation it runs behind (ExpoVault.implementation, docs/48).
interface IProxiedVault {
    function implementation() external view returns (address);
}

/// @title Expo Gacha collection admission
/// @author Expo Gacha
/// @custom:website https://expogacha.com
/// @notice Unaudited V3 admission list (docs/33): one review per collection, shared by every gacha line. A review is
/// the digest of fork evidence (docs/23) bound to the collection's code and to the vault implementation's code at
/// admission time. The vault is an upgradeable proxy (docs/48): an upgrade to different code voids every review.
contract ExpoAdmissionRegistry is Ownable {
    struct Review {
        bytes32 evidence;
        bytes32 collectionCode;
        bytes32 vaultCode;
        uint64 expiresAt;
    }

    uint256 private constant MAX_BATCH = 64;
    /// @notice Hard ceiling on a review's life (docs/47-hostile-nft-audit HN-5); tooling uses shorter expiries.
    uint256 public constant MAX_REVIEW_PERIOD = 365 days;

    address public immutable vault;
    mapping(address => Review) public reviews;

    event Admitted(address indexed collection, bytes32 evidence, uint64 expiresAt);
    event Revoked(address indexed collection);

    error InvalidCollection(address collection);
    error InvalidBatch();

    constructor(address owner_, address vault_) Ownable(owner_) {
        if (vault_.code.length == 0) revert InvalidBatch();
        vault = vault_;
        // Fail closed: evidence must bind an implementation, so the vault must be a proxy that reports one.
        if (vaultCodehash() == bytes32(0)) revert InvalidBatch();
    }

    function admit(address[] calldata collections, bytes32[] calldata evidence, uint64 expiresAt) external onlyOwner {
        if (
            collections.length == 0 || collections.length > MAX_BATCH || collections.length != evidence.length
                || expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_REVIEW_PERIOD
        ) {
            revert InvalidBatch();
        }
        bytes32 vaultCode = vaultCodehash();
        if (vaultCode == bytes32(0)) revert InvalidBatch();
        for (uint256 i; i < collections.length; ++i) {
            address c = collections[i];
            if (c.code.length == 0 || evidence[i] == bytes32(0) || _isDelegatedEoa(c) || !_isERC721(c)) {
                revert InvalidCollection(c);
            }
            reviews[c] = Review(evidence[i], c.codehash, vaultCode, expiresAt);
            emit Admitted(c, evidence[i], expiresAt);
        }
    }

    function revoke(address collection) external onlyOwner {
        delete reviews[collection];
        emit Revoked(collection);
    }

    /// @notice True while the review exists, has not expired and the collection code and the vault implementation's
    /// code are unchanged. Gates new configurations and openings.
    function isAdmitted(address collection) external view returns (bool) {
        Review memory r = reviews[collection];
        return r.expiresAt > block.timestamp && _current(collection, r);
    }

    /// @notice Delivery-time check (ExpoGachaPool.fulfill): the review exists and the collection code and the vault
    /// implementation's code are unchanged. Expiry is ignored: it sets the re-review cadence for new commitments.
    function isDeliverable(address collection) external view returns (bool) {
        return _current(collection, reviews[collection]);
    }

    /// @notice keccak256 of the runtime code in the vault's EIP-1967 implementation slot; zero when the vault does not
    /// answer with a contract (unproxied or broken vault), which matches no review.
    function vaultCodehash() public view returns (bytes32) {
        (bool ok, bytes memory out) = vault.staticcall(abi.encodeCall(IProxiedVault.implementation, ()));
        if (!ok || out.length != 32) return bytes32(0);
        address implementation = abi.decode(out, (address));
        if (implementation.code.length == 0) return bytes32(0);
        return implementation.codehash;
    }

    function _current(address collection, Review memory r) private view returns (bool) {
        return r.evidence != bytes32(0) && r.collectionCode == collection.codehash && r.vaultCode == vaultCodehash()
            && r.vaultCode != bytes32(0);
    }

    /// @dev EIP-7702 delegation designator (0xef0100 ‖ address): an EOA whose key can re-delegate (docs/47-hostile-nft-audit HN-8).
    function _isDelegatedEoa(address c) private view returns (bool delegated) {
        if (c.code.length != 23) return false;
        bytes3 prefix;
        assembly {
            let p := mload(0x40)
            extcodecopy(c, p, 0, 3)
            prefix := mload(p)
        }
        return prefix == 0xef0100;
    }

    function _isERC721(address c) private view returns (bool) {
        try IERC165(c).supportsInterface(type(IERC721).interfaceId) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
