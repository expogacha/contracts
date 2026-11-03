// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev The Foundry cheatcodes the vault scripts use (this workspace has no forge-std).
interface ScriptVm {
    function startBroadcast() external;
    function stopBroadcast() external;
    function prank(address) external;
    function load(address, bytes32) external view returns (bytes32);
    function envOr(string calldata, address) external view returns (address);
    function envOr(string calldata, bytes calldata) external view returns (bytes memory);
    function envOr(string calldata, string calldata, address[] calldata) external view returns (address[] memory);
    function envOr(string calldata, string calldata, uint256[] calldata) external view returns (uint256[] memory);
    function envAddress(string calldata) external view returns (address);
    function envBytes32(string calldata) external view returns (bytes32);
}

abstract contract VaultScriptBase {
    ScriptVm internal constant vm = ScriptVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    // OpenZeppelin Initializable's ERC-7201 slot (initialized version in its low 64 bits).
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function _slotAddress(address target, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }

    function _ownerCount(address safe) internal view returns (uint256) {
        (bool ok, bytes memory out) = safe.staticcall(abi.encodeWithSignature("getOwners()"));
        return ok ? abi.decode(out, (address[])).length : 0;
    }

    /// @dev A Safe answers getThreshold(); the vault's ProxyAdmin owner must need at least two signatures (docs/48).
    function _threshold(address safe) internal view returns (uint256) {
        (bool ok, bytes memory out) = safe.staticcall(abi.encodeWithSignature("getThreshold()"));
        return ok && out.length == 32 ? abi.decode(out, (uint256)) : 0;
    }
}
