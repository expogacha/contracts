// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Collections for the transfer check test (apps/backend/internal/transfercheck): one ordinary ERC-721 and
/// three with restrictions seen on mainnet that break vault custody.
contract CheckOpenNFT is ERC721 {
    constructor() ERC721("Open", "OPEN") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// Refuses transfers initiated by a contract caller (tx.origin checks, as some creator-royalty guards do).
contract CheckNoContractCallerNFT is CheckOpenNFT {
    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (auth != address(0) && msg.sender != tx.origin) revert("caller must be an EOA");
        return super._update(to, id, auth);
    }
}

/// Refuses any recipient that has code.
contract CheckNoContractReceiverNFT is CheckOpenNFT {
    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (auth != address(0) && to.code.length > 0) revert("recipient must be an EOA");
        return super._update(to, id, auth);
    }
}

/// Soulbound: minted tokens never move.
contract CheckSoulboundNFT is CheckOpenNFT {
    error Soulbound();

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (auth != address(0)) revert Soulbound();
        return super._update(to, id, auth);
    }
}
