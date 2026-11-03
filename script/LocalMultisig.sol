// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice LOCAL DRY RUN ONLY: a minimal 2-of-n stand-in for the Safe that owns the vault's ProxyAdmin, with the
/// Safe's getThreshold/getOwners views. Never deploy it on a public network; use a real Safe (docs/48).
contract LocalMultisig {
    address[] private owners;
    uint256 public immutable threshold;
    mapping(address => bool) public isOwner;
    mapping(bytes32 => mapping(address => bool)) public approved;
    mapping(bytes32 => uint256) public approvals;
    mapping(bytes32 => bool) public executed;

    constructor(address[] memory owners_, uint256 threshold_) {
        require(threshold_ >= 2 && threshold_ <= owners_.length, "threshold");
        for (uint256 i; i < owners_.length; ++i) {
            require(owners_[i] != address(0) && !isOwner[owners_[i]], "owner");
            isOwner[owners_[i]] = true;
        }
        owners = owners_;
        threshold = threshold_;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function approve(address target, bytes calldata data, uint256 nonce) external {
        require(isOwner[msg.sender], "not an owner");
        bytes32 h = keccak256(abi.encode(target, data, nonce));
        require(!approved[h][msg.sender], "approved");
        approved[h][msg.sender] = true;
        approvals[h] += 1;
    }

    function execute(address target, bytes calldata data, uint256 nonce) external returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(target, data, nonce));
        require(isOwner[msg.sender] && approvals[h] >= threshold && !executed[h], "not approved");
        executed[h] = true;
        (bool ok, bytes memory out) = target.call(data);
        require(ok, "call failed");
        return out;
    }
}
