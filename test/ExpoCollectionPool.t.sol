// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoCollectionPool, ICollectionAdmission} from "../src/ExpoCollectionPool.sol";
import {ExpoCollectionRegistry} from "../src/ExpoCollectionRegistry.sol";
import {ExpoLegacyVault} from "../src/ExpoLegacyVault.sol";
import {IRandomness} from "../src/ExpoPool.sol";
import {MockUSDC, MockNFT, MockRandomness} from "../src/MockAssets.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
}

/// @dev Reports the vault as owner forever: transferFrom is a no-op. Delivery must fail.
contract LyingNFT {
    address public holder;

    function setHolder(address h) external {
        holder = h;
    }

    function ownerOf(uint256) external view returns (address) {
        return holder;
    }

    function transferFrom(address, address, uint256) external {}

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC721).interfaceId || id == 0x01ffc9a7;
    }
}

/// @dev Tries to re-enter the pool while the vault is transferring it.
contract ReentrantNFT is ERC721 {
    ExpoCollectionPool public pool;
    uint256 public target;
    bool public reentryBlocked;

    constructor() ERC721("Reentrant", "RE") {}

    function arm(ExpoCollectionPool p, uint256 openingId) external {
        pool = p;
        target = openingId;
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (address(pool) != address(0)) {
            try pool.compensate(target) {} catch {
                reentryBlocked = true;
            }
        }
        super.transferFrom(from, to, id);
    }
}

/// @dev Smart-contract wallet without onERC721Received: must still receive via transferFrom.
contract PlainWallet {
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory out) = target.call(data);
        require(ok, "call failed");
        return out;
    }
}

contract CollectionPoolBase {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant NFT_ART = bytes32("nft-art");

    MockUSDC token;
    MockNFT nft;
    MockRandomness rng;
    ExpoLegacyVault vault;
    ExpoCollectionRegistry registry;
    ExpoCollectionPool pool;
    address buyer = address(0xBEEF);
    address operator = address(0xCAFE);
    uint256 requests;

    function _deploy() internal {
        token = new MockUSDC();
        nft = new MockNFT();
        rng = new MockRandomness();
        vault = new ExpoLegacyVault(address(this));
        registry = new ExpoCollectionRegistry(address(this), address(vault));
        pool = new ExpoCollectionPool(
            token, IRandomness(address(rng)), vault, ICollectionAdmission(address(registry)), operator, address(this)
        );
        vault.bindPool(address(pool));
        token.mint(address(this), 1_000_000e6);
        token.approve(address(pool), type(uint256).max);
        pool.fund(100_000e6);
        token.mint(buyer, 10_000e6);
        vm.prank(buyer);
        token.approve(address(pool), type(uint256).max);
    }

    function _admit(address[] memory list) internal {
        for (uint256 i; i < list.length; ++i) {
            registry.reviewCompatibility(list[i], keccak256(abi.encode("fork evidence", list[i])), uint64(block.timestamp + 30 days));
        }
        registry.setCollections(NFT_ART, list);
    }

    function _one(address c) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = c;
    }

    /// @dev Every tier awards the same entitlement so tests are independent of the random tier.
    function _config(address collection, uint256 lo, uint256 hi, uint128 ref, uint128 budget) internal returns (uint64) {
        uint16[4] memory odds = [uint16(7500), 2000, 400, 100];
        ExpoCollectionPool.Entitlement[][4] memory items;
        for (uint8 t; t < 4; t++) {
            items[t] = new ExpoCollectionPool.Entitlement[](1);
            items[t][0] = ExpoCollectionPool.Entitlement(collection, lo, hi, ref, budget);
        }
        return pool.createConfig(NFT_ART, 50e6, odds, 9000, 1 days, keccak256("v2-config"), items);
    }

    function _open(uint64 configId) internal returns (uint256 id) {
        vm.prank(buyer);
        id = pool.open(configId);
        requests++;
    }

    function _reveal(uint64 configId, uint256 word) internal returns (uint256 id) {
        id = _open(configId);
        rng.fulfill(requests, word);
        pool.finalize(id);
    }

    function _claimed(uint64 configId) internal returns (uint256 id) {
        id = _reveal(configId, 42);
        vm.prank(buyer);
        pool.claimNFT(id);
    }

    function _state(uint256 id) internal view returns (ExpoCollectionPool.State s) {
        (, , s, , , , , , ) = pool.openings(id);
    }

    function _liability(uint256 id) internal view returns (uint128 l) {
        (, , , , l, , , , ) = pool.openings(id);
    }
}

contract ExpoCollectionPoolTest is CollectionPoolBase {
    uint64 configId;

    function setUp() public {
        _deploy();
        _admit(_one(address(nft)));
        configId = _config(address(nft), 0, type(uint256).max, 300e6, 250e6);
    }

    function testDeliversTokenFromVaultAndReimbursesBudget() public {
        uint256 id = _claimed(configId);
        nft.mint(address(vault), 7); // stands in for the operator's marketplace purchase into the vault
        uint256 opBefore = token.balanceOf(operator);
        vm.prank(operator);
        pool.fulfill(id, 7);
        require(nft.ownerOf(7) == buyer, "buyer owns token");
        require(token.balanceOf(operator) - opBefore == 250e6, "budget reimbursed");
        require(_state(id) == ExpoCollectionPool.State.Delivered, "delivered");
        require(pool.reserved() == 0, "no reservation left");
    }

    function testRevealReservesMaxOfReferenceAndBudget() public {
        uint256 id = _reveal(configId, 7);
        require(_liability(id) == 300e6, "liability is max(ref, budget)");
        require(pool.reserved() == 300e6, "aggregate matches");
    }

    function testQuickSellPaysDiscountedReference() public {
        uint256 id = _reveal(configId, 1);
        uint256 before = token.balanceOf(buyer);
        vm.prank(buyer);
        pool.quickSell(id);
        require(token.balanceOf(buyer) - before == 270e6, "300 * 90%");
        require(pool.reserved() == 0, "released");
    }

    function testCompensationAfterDeadlinePaysFullReference() public {
        uint256 id = _claimed(configId);
        vm.warp(block.timestamp + 1 days);
        nft.mint(address(vault), 9);
        vm.prank(operator);
        vm.expectRevert(ExpoCollectionPool.Expired.selector);
        pool.fulfill(id, 9);
        uint256 before = token.balanceOf(buyer);
        pool.compensate(id);
        require(token.balanceOf(buyer) - before == 300e6, "full reference");
        require(pool.reserved() == 0, "released");
    }

    function testCompensationBeforeDeadlineReverts() public {
        uint256 id = _claimed(configId);
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.compensate(id);
    }

    function testOnlyOperatorFulfills() public {
        uint256 id = _claimed(configId);
        nft.mint(address(vault), 1);
        vm.prank(buyer);
        vm.expectRevert(ExpoCollectionPool.Unauthorized.selector);
        pool.fulfill(id, 1);
    }

    function testFulfillRequiresTokenInVault() public {
        uint256 id = _claimed(configId);
        nft.mint(address(0xD00D), 3);
        vm.prank(operator);
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.fulfill(id, 3);
    }

    function testCannotFulfillTwice() public {
        uint256 id = _claimed(configId);
        nft.mint(address(vault), 4);
        nft.mint(address(vault), 5);
        vm.startPrank(operator);
        pool.fulfill(id, 4);
        vm.expectRevert(ExpoCollectionPool.WrongState.selector);
        pool.fulfill(id, 5);
        vm.stopPrank();
    }

    function testFulfillRequiresClaim() public {
        uint256 id = _reveal(configId, 3);
        nft.mint(address(vault), 6);
        vm.prank(operator);
        vm.expectRevert(ExpoCollectionPool.WrongState.selector);
        pool.fulfill(id, 6);
    }

    function testOnlyBuyerChoosesExit() public {
        uint256 id = _reveal(configId, 3);
        vm.prank(operator);
        vm.expectRevert(ExpoCollectionPool.Unauthorized.selector);
        pool.quickSell(id);
        vm.prank(operator);
        vm.expectRevert(ExpoCollectionPool.Unauthorized.selector);
        pool.claimNFT(id);
    }

    function testNoQuickSellAfterClaim() public {
        uint256 id = _claimed(configId);
        vm.prank(buyer);
        vm.expectRevert(ExpoCollectionPool.WrongState.selector);
        pool.quickSell(id);
    }

    function testHugeTokenIdsAreSupported() public {
        uint256 id = _claimed(configId);
        uint256 big = 2 ** 255 + 12345;
        nft.mint(address(vault), big);
        vm.prank(operator);
        pool.fulfill(id, big);
        require(nft.ownerOf(big) == buyer, "uint256 token delivered");
    }

    function testDeliveryToContractWalletWithoutReceiverHook() public {
        PlainWallet wallet = new PlainWallet();
        token.mint(address(wallet), 100e6);
        wallet.call(address(token), abi.encodeCall(token.approve, (address(pool), type(uint256).max)));
        bytes memory out = wallet.call(address(pool), abi.encodeCall(pool.open, (configId)));
        uint256 id = abi.decode(out, (uint256));
        rng.fulfill(++requests, 11);
        pool.finalize(id);
        wallet.call(address(pool), abi.encodeCall(pool.claimNFT, (id)));
        nft.mint(address(vault), 21);
        vm.prank(operator);
        pool.fulfill(id, 21);
        require(nft.ownerOf(21) == address(wallet), "contract wallet received");
    }

    function testWithdrawCannotTouchReservations() public {
        _reveal(configId, 5);
        uint256 free = pool.freeReserve();
        vm.expectRevert(ExpoCollectionPool.Insolvent.selector);
        pool.withdraw(address(this), free + 1);
        pool.withdraw(address(this), free);
        require(token.balanceOf(address(pool)) == pool.reserved(), "only reservations remain");
    }

    function testOpenFailsWhenReserveCannotCover() public {
        pool.withdraw(address(this), pool.freeReserve());
        vm.prank(buyer);
        vm.expectRevert(ExpoCollectionPool.Insolvent.selector);
        pool.open(configId);
    }

    function testUnknownAndDuplicateRandomnessIgnored() public {
        uint256 id = _open(configId);
        rng.fulfill(requests, 111);
        (, , , , , , , uint256 word, ) = pool.openings(id);
        // A second callback for the same request cannot change the stored word.
        vm.prank(address(rng));
        pool.fulfillRandomness(requests, 999);
        (, , , , , , , uint256 again, ) = pool.openings(id);
        require(word == again, "word immutable");
        vm.prank(address(rng));
        pool.fulfillRandomness(424242, 1); // unknown request: no-op
    }

    function testRandomnessOnlyFromProvider() public {
        _open(configId);
        vm.expectRevert(ExpoCollectionPool.Unauthorized.selector);
        pool.fulfillRandomness(requests, 1);
    }

    function testDisabledConfigStillSettles() public {
        uint256 id = _reveal(configId, 8);
        pool.setEnabled(configId, false);
        vm.prank(buyer);
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.open(configId);
        vm.prank(buyer);
        pool.quickSell(id);
    }
}

contract ExpoCollectionPoolAdversarialTest is CollectionPoolBase {
    function setUp() public {
        _deploy();
    }

    function testConfigRequiresAdmittedCollection() public {
        _admit(_one(address(nft)));
        MockNFT other = new MockNFT();
        vm.expectRevert(abi.encodeWithSelector(ExpoCollectionPool.NotAdmitted.selector, address(other)));
        _config(address(other), 0, type(uint256).max, 100e6, 100e6);
    }

    function testRevocationBlocksNewOpeningsButKeepsExistingLiabilities() public {
        _admit(_one(address(nft)));
        uint64 cfg = _config(address(nft), 0, type(uint256).max, 100e6, 80e6);
        uint256 id = _claimed(cfg);
        registry.revokeCompatibility(address(nft));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ExpoCollectionPool.NotAdmitted.selector, address(nft)));
        pool.open(cfg);
        require(_liability(id) == 100e6, "liability preserved");
        vm.warp(block.timestamp + 1 days);
        pool.compensate(id);
        require(pool.reserved() == 0, "settled after revocation");
    }

    function testExpiredReviewBlocksNewOpenings() public {
        _admit(_one(address(nft)));
        uint64 cfg = _config(address(nft), 0, type(uint256).max, 100e6, 80e6);
        vm.warp(block.timestamp + 31 days);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ExpoCollectionPool.NotAdmitted.selector, address(nft)));
        pool.open(cfg);
    }

    function testRangeRejectsTokensOutsideProject() public {
        _admit(_one(address(nft)));
        // Art Blocks style: project 78 owns token IDs 78,000,000 .. 78,999,999 on a shared contract.
        uint64 cfg = _config(address(nft), 78_000_000, 78_999_999, 100e6, 80e6);
        uint256 id = _claimed(cfg);
        nft.mint(address(vault), 77_999_999);
        nft.mint(address(vault), 79_000_000);
        nft.mint(address(vault), 78_000_005);
        vm.startPrank(operator);
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.fulfill(id, 77_999_999);
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.fulfill(id, 79_000_000);
        pool.fulfill(id, 78_000_005);
        vm.stopPrank();
        require(nft.ownerOf(78_000_005) == buyer, "in-range token delivered");
    }

    function testLyingCollectionCannotBeSettled() public {
        LyingNFT liar = new LyingNFT();
        liar.setHolder(address(vault));
        _admit(_one(address(liar)));
        uint64 cfg = _config(address(liar), 0, type(uint256).max, 100e6, 80e6);
        uint256 id = _claimed(cfg);
        uint256 reservedBefore = pool.reserved();
        vm.prank(operator);
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.fulfill(id, 1);
        require(pool.reserved() == reservedBefore, "liability not consumed");
        require(_state(id) == ExpoCollectionPool.State.ClaimRequested, "still claimable or compensable");
    }

    function testReentrantCollectionCannotDoubleSettle() public {
        ReentrantNFT re = new ReentrantNFT();
        _admit(_one(address(re)));
        uint64 cfg = _config(address(re), 0, type(uint256).max, 100e6, 80e6);
        uint256 id = _claimed(cfg);
        re.mint(address(vault), 1);
        re.arm(pool, id);
        uint256 buyerBefore = token.balanceOf(buyer);
        vm.prank(operator);
        pool.fulfill(id, 1);
        require(re.reentryBlocked(), "reentry rejected");
        require(re.ownerOf(1) == buyer, "delivered once");
        require(token.balanceOf(buyer) == buyerBefore, "no compensation paid");
        require(pool.reserved() == 0, "single settlement");
    }

    function testVaultOnlyReleasesForPool() public {
        nft.mint(address(vault), 1);
        vm.prank(operator);
        vm.expectRevert(ExpoLegacyVault.Unauthorized.selector);
        vault.release(address(nft), 1, operator);
        vm.prank(buyer);
        vm.expectRevert();
        vault.recover(address(nft), 1, buyer);
        vault.recover(address(nft), 1, address(this));
        require(nft.ownerOf(1) == address(this), "owner recovered undelivered token");
    }

    function testVaultBindsPoolOnce() public {
        vm.expectRevert(ExpoLegacyVault.Invalid.selector);
        vault.bindPool(address(pool));
    }

    function testNonOwnerCannotConfigure() public {
        _admit(_one(address(nft)));
        uint16[4] memory odds = [uint16(10000), 0, 0, 0];
        ExpoCollectionPool.Entitlement[][4] memory items;
        items[0] = new ExpoCollectionPool.Entitlement[](1);
        items[0][0] = ExpoCollectionPool.Entitlement(address(nft), 0, 1, 1e6, 1e6);
        vm.prank(buyer);
        vm.expectRevert();
        pool.createConfig(NFT_ART, 1e6, odds, 0, 1 hours, keccak256("x"), items);
    }

    function testRejectsInvalidConfigs() public {
        _admit(_one(address(nft)));
        ExpoCollectionPool.Entitlement[][4] memory items;
        items[0] = new ExpoCollectionPool.Entitlement[](1);
        items[0][0] = ExpoCollectionPool.Entitlement(address(nft), 5, 1, 1e6, 1e6); // min > max
        uint16[4] memory odds = [uint16(10000), 0, 0, 0];
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.createConfig(NFT_ART, 1e6, odds, 0, 1 hours, keccak256("x"), items);
        items[0][0] = ExpoCollectionPool.Entitlement(address(nft), 0, 1, 1e6, 1e6);
        uint16[4] memory badOdds = [uint16(9999), 0, 0, 0];
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.createConfig(NFT_ART, 1e6, badOdds, 0, 1 hours, keccak256("x"), items);
    }
}
