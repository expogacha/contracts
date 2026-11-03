// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoVault} from "../src/ExpoVault.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {VaultScriptBase} from "./ScriptVm.sol";

/// @notice Prepares a vault upgrade for the Safe (docs/48). It never broadcasts and holds no key: it simulates
/// ProxyAdmin.upgradeAndCall as the Safe on the current state, checks what must not change, and returns the
/// transaction the Safe signers must create (to = ProxyAdmin, value = 0, data = upgradeCalldata).
/// Environment (never arguments): VAULT_PROXY, NEW_VAULT_IMPLEMENTATION, EXPECTED_NEW_IMPLEMENTATION_CODEHASH (the
/// code hash of the reviewed build), EXPECTED_PROXY_ADMIN_OWNER, optional VAULT_UPGRADE_CALLDATA (a reviewed
/// reinitializer call, default empty), VAULT_UPGRADE_COLLECTIONS and VAULT_UPGRADE_TOKEN_IDS (comma-separated, tokens
/// the vault holds and must still hold). The RPC is a foundry.toml alias resolved from the environment (docs/48):
///   forge script script/VaultUpgrade.s.sol --rpc-url sepolia      (SEPOLIA_RPC_URL exported; no --broadcast, no key)
contract VaultUpgrade is VaultScriptBase {
    struct Prepared {
        address proxyAdmin;
        address safe;
        uint256 safeThreshold;
        address currentImplementation;
        address newImplementation;
        bytes32 newImplementationCodehash;
        bytes upgradeCalldata;
    }

    function run() external returns (Prepared memory p) {
        address proxy = vm.envAddress("VAULT_PROXY");
        p.newImplementation = vm.envAddress("NEW_VAULT_IMPLEMENTATION");
        address expectedSafe = vm.envAddress("EXPECTED_PROXY_ADMIN_OWNER");
        bytes32 expectedCodehash = vm.envBytes32("EXPECTED_NEW_IMPLEMENTATION_CODEHASH");
        bytes memory data = vm.envOr("VAULT_UPGRADE_CALLDATA", bytes(""));
        address[] memory collections = vm.envOr("VAULT_UPGRADE_COLLECTIONS", ",", new address[](0));
        uint256[] memory tokenIds = vm.envOr("VAULT_UPGRADE_TOKEN_IDS", ",", new uint256[](0));
        require(collections.length == tokenIds.length, "collections and token IDs differ in length");

        ExpoVault vault = ExpoVault(proxy);
        p.proxyAdmin = _slotAddress(proxy, ADMIN_SLOT);
        p.safe = ProxyAdmin(p.proxyAdmin).owner();
        p.safeThreshold = _threshold(p.safe);
        p.currentImplementation = _slotAddress(proxy, IMPLEMENTATION_SLOT);
        require(p.safe == expectedSafe, "ProxyAdmin owner is not the expected Safe");
        require(p.safeThreshold >= 2, "ProxyAdmin owner is not a Safe with threshold >= 2");
        require(p.newImplementation.code.length > 0, "new implementation has no code");
        require(p.newImplementation.codehash == expectedCodehash, "new implementation is not the reviewed build");
        require(_ownerCount(p.safe) >= p.safeThreshold, "Safe has fewer owners than its threshold");
        require(p.newImplementation != p.currentImplementation, "already the implementation");
        require(vault.implementation() == p.currentImplementation, "vault reports another implementation");
        require(
            ExpoVault(p.newImplementation).VAULT_STORAGE_LOCATION() == vault.VAULT_STORAGE_LOCATION(),
            "storage namespace changed"
        );
        // The new implementation must have run _disableInitializers(): its own Initializable slot holds the maximum
        // version. (Calling initialize() alone would also "fail" on an implementation that lacks the function.)
        require(uint256(vm.load(p.newImplementation, INITIALIZABLE_SLOT)) == type(uint64).max, "initializers not disabled");
        (bool initialized,) = p.newImplementation.call(abi.encodeCall(ExpoVault.initialize, (address(0xdead))));
        require(!initialized, "new implementation can be initialized");

        address owner = vault.owner();
        address pendingOwner = vault.pendingOwner();
        address pool = vault.pool();
        for (uint256 i; i < collections.length; ++i) {
            require(IERC721(collections[i]).ownerOf(tokenIds[i]) == proxy, "listed token not held before");
        }

        p.upgradeCalldata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), p.newImplementation, data)
        );
        vm.prank(p.safe);
        (bool ok,) = p.proxyAdmin.call(p.upgradeCalldata);
        require(ok, "simulated upgrade reverted");

        require(_slotAddress(proxy, IMPLEMENTATION_SLOT) == p.newImplementation, "implementation slot");
        require(vault.implementation() == p.newImplementation, "vault reports the new implementation");
        require(_slotAddress(proxy, ADMIN_SLOT) == p.proxyAdmin, "ProxyAdmin unchanged");
        require(vault.owner() == owner && vault.pendingOwner() == pendingOwner && vault.pool() == pool, "state kept");
        for (uint256 i; i < collections.length; ++i) {
            require(IERC721(collections[i]).ownerOf(tokenIds[i]) == proxy, "listed token lost");
        }
        p.newImplementationCodehash = p.newImplementation.codehash;
    }
}
