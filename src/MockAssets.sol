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
 *       MockAssets
 *       Test tokens and randomness for local runs. They have no monetary value.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IExpoRandomConsumer} from "./ChainlinkRandomness.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Expo Test USDC - NO VALUE", "testUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice WETH9 behaviour for local tests: wrap with deposit (or a plain transfer), unwrap with withdraw.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {
        deposit();
    }
}

contract MockNFT is ERC721 {
    constructor() ERC721("Expo Test Art - NO VALUE", "EXPO-TEST") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Operator-chosen test randomness, NOT VRF. Never use with real assets.
contract MockRandomness is Ownable {
    uint256 public count;
    mapping(uint256 => address) public consumers;
    constructor() Ownable(msg.sender) {}

    function request() external returns (uint256 id) {
        id = ++count;
        consumers[id] = msg.sender;
    }

    function fulfill(uint256 id, uint256 word) external onlyOwner {
        IExpoRandomConsumer(consumers[id]).fulfillRandomness(id, word);
    }
}
