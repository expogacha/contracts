// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoVault} from "../../src/ExpoVault.sol";
import {ExpoVaultDeployment} from "../../script/ExpoVaultDeployment.sol";

/// @dev Stand-in for the ProxyAdmin owner Safe in tests (docs/48).
address constant TEST_PROXY_ADMIN_OWNER = address(0x5afe5afE5afE5afE5afE5aFe5aFe5Afe5Afe5AfE);

/// @dev The vault as deployed: implementation behind a Transparent proxy, initialized atomically.
function deployTestVault(address owner) returns (ExpoVault) {
    return ExpoVaultDeployment.deploy(owner, TEST_PROXY_ADMIN_OWNER).vault;
}
