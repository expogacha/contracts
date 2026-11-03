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
 *       ExpoCollectionRegistry
 *       The V2 list of collections per machine, with reviewed evidence.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
/// @notice Collection membership only; does not change immutable V1 prize commitments.
contract ExpoCollectionRegistry is Ownable {
    struct Review { bytes32 evidence; bytes32 collectionCode; bytes32 vaultCode; uint64 expiresAt; }
    address public immutable vault;
    mapping(address => Review) public reviews;
    mapping(bytes32 => address[]) private lists;
    event CollectionsChanged(bytes32 indexed machineId, address[] collections);
    event CompatibilityReviewed(address indexed collection, bytes32 evidence, uint64 expiresAt);
    error InvalidCollection();
    constructor(address owner_, address vault_) Ownable(owner_) {
        if (vault_.code.length == 0) revert InvalidCollection();
        vault = vault_;
    }
    /// @dev Owner attests reviewed fork evidence per docs/23; never call from browser draft metadata.
    function reviewCompatibility(address collection, bytes32 evidence, uint64 expiresAt) external onlyOwner {
        if (collection.code.length == 0 || evidence == bytes32(0) || expiresAt <= block.timestamp) revert InvalidCollection();
        reviews[collection] = Review(evidence, collection.codehash, vault.codehash, expiresAt);
        emit CompatibilityReviewed(collection, evidence, expiresAt);
    }
    function revokeCompatibility(address collection) external onlyOwner {
        delete reviews[collection];
        emit CompatibilityReviewed(collection, bytes32(0), 0);
    }
    function setCollections(bytes32 machineId, address[] calldata values) external onlyOwner {
        if (machineId != bytes32("nft-art") && machineId != bytes32("physical-art") && machineId != bytes32("physical-assets")) revert InvalidCollection();
        if (values.length > 64) revert InvalidCollection();
        for (uint256 i; i < values.length; ++i) {
            address c = values[i]; Review memory r = reviews[c];
            if (c.code.length == 0 || r.evidence == bytes32(0) || r.expiresAt <= block.timestamp || r.collectionCode != c.codehash || r.vaultCode != vault.codehash) revert InvalidCollection();
            if (!IERC165(c).supportsInterface(type(IERC721).interfaceId)) revert InvalidCollection();
            for (uint256 j; j < i; ++j) if (values[j] == c) revert InvalidCollection();
        }
        lists[machineId] = values;
        emit CollectionsChanged(machineId, values);
    }
    function collections(bytes32 machineId) external view returns(address[] memory) { return lists[machineId]; }
    /// @notice True while `collection` is listed for `machineId` and its review is present, unexpired and still
    /// bound to the current collection and vault code. Used by V2 pools to block new commitments after revocation.
    function isAdmitted(bytes32 machineId, address collection) external view returns (bool) {
        Review memory r = reviews[collection];
        if (r.evidence == bytes32(0) || r.expiresAt <= block.timestamp) return false;
        if (r.collectionCode != collection.codehash || r.vaultCode != vault.codehash) return false;
        address[] storage list = lists[machineId];
        for (uint256 i; i < list.length; ++i) if (list[i] == collection) return true;
        return false;
    }
}
