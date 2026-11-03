// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoTestCollection} from "../src/ExpoTestCollection.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
}

contract ExpoTestCollectionTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    ExpoTestCollection c;
    address constant OPERATOR = address(0xBEEF);
    address constant STRANGER = address(0xBAD);

    function setUp() public {
        c = new ExpoTestCollection("Expo Test Apes", "XAPE", 100, "https://api.example/apes/", "https://api.example/apes", address(this));
        c.setMinter(OPERATOR, true);
    }

    function testOnlyOwnerAndMintersMintInsideTheSupply() public {
        c.mint(address(1), 0);
        vm.prank(OPERATOR);
        c.mint(address(2), 99);
        require(c.totalSupply() == 2 && c.ownerOf(99) == address(2), "minted");
        vm.prank(STRANGER);
        vm.expectRevert(ExpoTestCollection.NotMinter.selector);
        c.mint(STRANGER, 5);
        vm.expectRevert(ExpoTestCollection.OutOfRange.selector);
        c.mint(address(1), 100);
    }

    function testMetadataAndInterfaces() public {
        c.mint(address(1), 7);
        require(keccak256(bytes(c.tokenURI(7))) == keccak256("https://api.example/apes/7"), "token URI");
        require(keccak256(bytes(c.contractURI())) == keccak256("https://api.example/apes"), "contract URI");
        require(c.supportsInterface(0x80ac58cd) && c.supportsInterface(0x5b5e139f), "ERC-721 and metadata");
    }
}
