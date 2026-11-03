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
 *       ExpoTestCollection
 *       Test NFTs for Sepolia only. They have no monetary value.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Expo's own test collections on Sepolia (docs/39): original artwork and traits served by the Expo API, no
/// monetary value. Only the owner and appointed minters (the settlement operator) mint, so a token reaches the vault
/// only through Expo's delivery path; token IDs run from 0 to maxSupply − 1.
contract ExpoTestCollection is ERC721, Ownable {
    uint256 public immutable maxSupply;
    uint256 public totalSupply;
    string private baseURI;
    string private collectionURI;
    mapping(address => bool) public minter;

    error NotMinter();
    error OutOfRange();

    event MinterSet(address indexed account, bool allowed);

    constructor(string memory name_, string memory symbol_, uint256 maxSupply_, string memory baseURI_, string memory contractURI_, address owner_)
        ERC721(name_, symbol_)
        Ownable(owner_)
    {
        if (maxSupply_ == 0) revert OutOfRange();
        maxSupply = maxSupply_;
        baseURI = baseURI_;
        collectionURI = contractURI_;
    }

    function setMinter(address account, bool allowed) external onlyOwner {
        minter[account] = allowed;
        emit MinterSet(account, allowed);
    }

    function mint(address to, uint256 tokenId) external {
        if (msg.sender != owner() && !minter[msg.sender]) revert NotMinter();
        if (tokenId >= maxSupply) revert OutOfRange();
        ++totalSupply;
        _mint(to, tokenId);
    }

    function contractURI() external view returns (string memory) {
        return collectionURI;
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }
}
