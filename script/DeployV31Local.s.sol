// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoVault} from "../src/ExpoVault.sol";
import {ExpoAdmissionRegistry} from "../src/v3/ExpoAdmissionRegistry.sol";
import {ExpoGachaPool, IAdmission} from "../src/v3/ExpoGachaPool.sol";
import {ExpoLaunchpad} from "../src/v3/ExpoLaunchpad.sol";
import {IRandomness} from "../src/ExpoPool.sol";
import {MockWETH, MockNFT, MockRandomness} from "../src/MockAssets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ExpoVaultDeployment} from "./ExpoVaultDeployment.sol";
import {LocalMultisig} from "./LocalMultisig.sol";
import {VaultScriptBase} from "./ScriptVm.sol";

/// @notice Dry run of the deployment with the upgradeable vault (docs/48) on a LOCAL anvil only (chain 31337). It builds
/// contracts/src, so since docs/46 it deploys the v3.2 pool; the name is kept for the evidence that cites it:
/// the same order as deploy-v3.mjs, with mocks for WETH, VRF and the test collection, and a 2-of-3 LocalMultisig
/// standing in for the Safe. Every binding is checked after broadcasting. Run with an unlocked anvil account:
///   forge script script/DeployV31Local.s.sol --rpc-url http://127.0.0.1:<port> --unlocked --sender <anvil account 0> --broadcast
contract DeployV31Local is VaultScriptBase {
    struct Result {
        address safe;
        address vault;
        address vaultImplementation;
        address vaultProxyAdmin;
        address registry;
        address pool;
        address launchpad;
        address randomness;
        address weth;
        address nft;
        bytes32 vaultCodehash;
    }

    function run() external returns (Result memory r) {
        require(block.chainid == 31337, "local anvil only");
        vm.startBroadcast();
        address deployer = msg.sender;
        address[] memory signers = new address[](3);
        signers[0] = deployer;
        signers[1] = address(0x5161E2);
        signers[2] = address(0x5161E3);
        r.safe = address(new LocalMultisig(signers, 2));
        r.weth = address(new MockWETH());
        r.randomness = address(new MockRandomness());
        r.nft = address(new MockNFT());
        ExpoVaultDeployment.Deployed memory d = ExpoVaultDeployment.deploy(deployer, r.safe);
        r.vault = address(d.vault);
        r.vaultImplementation = d.implementation;
        r.vaultProxyAdmin = d.proxyAdmin;
        ExpoAdmissionRegistry registry = new ExpoAdmissionRegistry(deployer, r.vault);
        r.registry = address(registry);
        ExpoGachaPool pool = new ExpoGachaPool(
            IERC20(r.weth),
            IRandomness(r.randomness),
            d.vault,
            IAdmission(r.registry),
            address(0x0E7A70),
            deployer,
            2 ether
        );
        r.pool = address(pool);
        r.launchpad = address(new ExpoLaunchpad(pool, deployer, address(0x0001A0), 0.001 ether));
        d.vault.bindPool(r.pool);
        pool.setConfigurator(r.launchpad);
        address[] memory list = new address[](1);
        list[0] = r.nft;
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256(abi.encode("local dry run", r.nft, registry.vaultCodehash()));
        registry.admit(list, evidence, uint64(block.timestamp + 90 days));
        vm.stopBroadcast();

        r.vaultCodehash = registry.vaultCodehash();
        ExpoVault vault = d.vault;
        require(_slotAddress(r.vault, IMPLEMENTATION_SLOT) == r.vaultImplementation, "implementation slot");
        require(_slotAddress(r.vault, ADMIN_SLOT) == r.vaultProxyAdmin, "admin slot");
        require(ProxyAdmin(r.vaultProxyAdmin).owner() == r.safe && _threshold(r.safe) >= 2 && _ownerCount(r.safe) >= _threshold(r.safe), "ProxyAdmin owned by a 2-of-n");
        require(vault.owner() == deployer && vault.pool() == r.pool && vault.implementation() == r.vaultImplementation, "vault");
        require(ExpoVault(r.vaultImplementation).owner() == address(0), "implementation not initialized");
        require(r.vaultCodehash == r.vaultImplementation.codehash, "registry binds the implementation");
        require(address(pool.vault()) == r.vault && address(pool.registry()) == r.registry, "pool wiring");
        require(registry.vault() == r.vault && registry.isAdmitted(r.nft) && registry.isDeliverable(r.nft), "admission");
        require(pool.configurator() == r.launchpad && address(ExpoLaunchpad(r.launchpad).pool()) == r.pool, "launchpad");
    }
}
