// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ExpoVault} from "../src/ExpoVault.sol";

/// @notice The one way Expo deploys its vault (docs/48): the implementation, then a Transparent proxy initialized in
/// its own constructor, so no uninitialized proxy ever exists. The proxy creates its ProxyAdmin, owned by
/// `proxyAdminOwner` (a Safe outside tests). Used by the Foundry scripts and the tests; deploy-v3.mjs mirrors it.
library ExpoVaultDeployment {
    struct Deployed {
        ExpoVault vault; // the proxy: the address every other contract and collection sees
        address implementation;
        address proxyAdmin;
    }

    error InvalidParameter();

    function deploy(address owner, address proxyAdminOwner) internal returns (Deployed memory d) {
        if (owner == address(0) || proxyAdminOwner == address(0)) revert InvalidParameter();
        d.implementation = address(new ExpoVault());
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            d.implementation, proxyAdminOwner, abi.encodeCall(ExpoVault.initialize, (owner))
        );
        d.vault = ExpoVault(address(proxy));
        d.proxyAdmin = proxyAdminOf(address(proxy));
    }

    /// @notice The ProxyAdmin is the first contract the proxy creates (nonce 1): its CREATE address.
    function proxyAdminOf(address proxy) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))))));
    }
}
