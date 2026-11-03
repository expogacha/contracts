// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ExpoCollectionRegistry} from "../src/ExpoCollectionRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockNFT} from "../src/MockAssets.sol";
interface RegistryVm {function prank(address)external;function expectRevert()external;function warp(uint256)external;function expectEmit(bool,bool,bool,bool)external;function etch(address,bytes calldata)external;}
contract ExpoCollectionRegistryTest {
 RegistryVm constant vm=RegistryVm(address(uint160(uint256(keccak256("hevm cheat code")))));
 ExpoCollectionRegistry registry;MockNFT nft;
 event CollectionsChanged(bytes32 indexed machineId,address[] collections);
 function setUp()public{nft=new MockNFT();registry=new ExpoCollectionRegistry(address(this),address(nft));}
 function list()internal view returns(address[] memory a){a=new address[](1);a[0]=address(nft);}
 function approve()internal{registry.reviewCompatibility(address(nft),keccak256("TEST-ONLY-FIXTURE-REVIEW"),uint64(block.timestamp+1 days));}
 function testMissingReviewFails()public{vm.expectRevert();registry.setCollections(bytes32("nft-art"),list());}
 function testSnapshotEventAndEmptyRemoval()public{approve();address[] memory a=list();vm.expectEmit(true,false,false,true);emit CollectionsChanged(bytes32("nft-art"),a);registry.setCollections(bytes32("nft-art"),a);require(registry.collections(bytes32("nft-art")).length==1);a=new address[](0);vm.expectEmit(true,false,false,true);emit CollectionsChanged(bytes32("nft-art"),a);registry.setCollections(bytes32("nft-art"),a);require(registry.collections(bytes32("nft-art")).length==0);}
 function testUnauthorizedCannotSetOrReview()public{vm.prank(address(0xBEEF));vm.expectRevert();registry.reviewCompatibility(address(nft),bytes32(uint256(1)),uint64(block.timestamp+1 days));approve();vm.prank(address(0xBEEF));vm.expectRevert();registry.setCollections(bytes32("nft-art"),list());}
 function testExpiredAndRevokedReviewFails()public{approve();vm.warp(block.timestamp+1 days);vm.expectRevert();registry.setCollections(bytes32("nft-art"),list());approve();registry.revokeCompatibility(address(nft));vm.expectRevert();registry.setCollections(bytes32("nft-art"),list());}
 function testChangedCodeAndNonERC721Fail()public{approve();vm.etch(address(nft),hex"00");vm.expectRevert();registry.setCollections(bytes32("nft-art"),list());}
 function testNonERC721ReviewCannotEnable()public{address c=address(new NonNFT());registry.reviewCompatibility(c,bytes32(uint256(1)),uint64(block.timestamp+1 days));address[] memory a=new address[](1);a[0]=c;vm.expectRevert();registry.setCollections(bytes32("nft-art"),a);}
 function testDuplicateUnknownMachineAndZeroFail()public{approve();address[] memory a=new address[](2);a[0]=address(nft);a[1]=address(nft);vm.expectRevert();registry.setCollections(bytes32("nft-art"),a);vm.expectRevert();registry.setCollections(bytes32("unknown"),list());a=new address[](1);vm.expectRevert();registry.setCollections(bytes32("nft-art"),a);}
}

contract NonNFT { function supportsInterface(bytes4)external pure returns(bool){return false;} }

/// @dev Local smoke fixture only, never a production custody implementation.
contract RegistryFixtureVault {
 address immutable owner=msg.sender;
 function deliver(address collection,address recipient,uint256 tokenId)external {require(msg.sender==owner);IERC721(collection).transferFrom(address(this),recipient,tokenId);require(IERC721(collection).ownerOf(tokenId)==recipient);}
}
