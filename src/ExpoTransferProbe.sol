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
 *       ExpoTransferProbe
 *       Simulates a vault delivery to check that a collection can transfer.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ExpoVault} from "./ExpoVault.sol";

/// @notice Simulation-only helper for the collection transfer check (docs/30); never deployed. The backend places this
/// code at a scratch address with an eth_call state override, gives the current holder of a real token the exact
/// ExpoVault runtime code with `pool` set to this probe, and calls `check`. The collection then sees the same
/// vault bytecode and call path as a real delivery: ExpoVault.release → IERC721.transferFrom(vault, to, tokenId).
contract ExpoTransferProbe {
    /// @return delivered True when the release did not revert and `to` owns the token afterwards.
    function check(address vault, address collection, uint256 tokenId, address to) external returns (bool delivered) {
        ExpoVault(vault).release(collection, tokenId, to);
        return IERC721(collection).ownerOf(tokenId) == to;
    }
}
