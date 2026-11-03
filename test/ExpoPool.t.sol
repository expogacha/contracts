// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ExpoPool, IRandomness} from "../src/ExpoPool.sol";
import {MockUSDC, MockNFT, MockRandomness} from "../src/MockAssets.sol";
import {ChainlinkRandomness, IVRFCoordinatorV2Plus} from "../src/ChainlinkRandomness.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
}

contract ExpoPoolTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    MockUSDC token;
    MockNFT nft;
    MockRandomness rng;
    ExpoPool pool;
    address buyer = address(0xBEEF);
    address operator = address(0xCAFE);

    function setUp() public {
        token = new MockUSDC();
        nft = new MockNFT();
        rng = new MockRandomness();
        pool = new ExpoPool(token, IRandomness(address(rng)), operator, address(this));
        uint16[4] memory odds = [uint16(7500), 2000, 400, 100];
        ExpoPool.Outcome[][4] memory items;
        for (uint8 t; t < 4; t++) {
            items[t] = new ExpoPool.Outcome[](1);
            items[t][0] = ExpoPool.Outcome(
                address(nft), t == 3 ? type(uint256).max : t, uint128((uint256(t) + 1) * 100e6)
            );
        }
        pool.createConfig(50e6, odds, 9000, 1 days, keccak256("config"), items);
        token.mint(address(this), 10000e6);
        token.approve(address(pool), type(uint256).max);
        pool.fund(1000e6);
        token.mint(buyer, 10000e6);
        vm.prank(buyer);
        token.approve(address(pool), type(uint256).max);
    }

    function openAndReveal(uint256 word) internal returns (uint256 id) {
        vm.prank(buyer);
        id = pool.open(1);
        rng.fulfill(id, word);
        pool.finalize(id);
    }

    function testQuickSellExactAndNoDoubleSettlement() public {
        uint256 id = openAndReveal(9999);
        uint256 beforeBalance = token.balanceOf(buyer);
        vm.prank(buyer);
        pool.quickSell(id);
        require(token.balanceOf(buyer) == beforeBalance + 360e6);
        require(pool.reserved() == 0);
        vm.expectRevert();
        vm.prank(buyer);
        pool.quickSell(id);
        vm.expectRevert();
        vm.prank(buyer);
        pool.claimNFT(id);
    }

    function testExactDeliveryAndUint256TokenId() public {
        uint256 id = openAndReveal(9999);
        vm.prank(buyer);
        pool.claimNFT(id);
        nft.mint(operator, type(uint256).max);
        vm.prank(operator);
        nft.approve(address(pool), type(uint256).max);
        uint256 beforeBalance = token.balanceOf(operator);
        vm.prank(operator);
        pool.deliver(id);
        require(nft.ownerOf(type(uint256).max) == buyer);
        require(token.balanceOf(operator) == beforeBalance + 400e6);
        require(pool.reserved() == 0);
        vm.expectRevert();
        vm.prank(operator);
        pool.deliver(id);
    }

    function testUnauthorizedAndMissingNFT() public {
        uint256 id = openAndReveal(0);
        vm.expectRevert();
        pool.quickSell(id);
        vm.expectRevert();
        pool.fulfillRandomness(1, 2);
        vm.prank(buyer);
        pool.claimNFT(id);
        vm.expectRevert();
        pool.deliver(id);
        vm.expectRevert();
        vm.prank(operator);
        pool.deliver(id);
        require(pool.reserved() == 100e6);
    }

    function testCompensationFullValueAfterDeadline() public {
        uint256 id = openAndReveal(9600);
        vm.prank(buyer);
        pool.claimNFT(id);
        vm.expectRevert();
        pool.compensate(id);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert();
        vm.prank(buyer);
        pool.quickSell(id);
        vm.expectRevert();
        vm.prank(operator);
        pool.deliver(id);
        uint256 beforeBalance = token.balanceOf(buyer);
        pool.compensate(id);
        require(token.balanceOf(buyer) == beforeBalance + 300e6);
        require(pool.reserved() == 0);
    }

    function testCompensationWithoutChoice() public {
        uint256 id = openAndReveal(0);
        vm.warp(block.timestamp + 1 days);
        pool.compensate(id);
        require(pool.reserved() == 0);
    }

    function testPausedConfigCannotBlockExistingDraw() public {
        vm.prank(buyer);
        uint256 id = pool.open(1);
        pool.setEnabled(1, false);
        vm.expectRevert();
        vm.prank(buyer);
        pool.open(1);
        rng.fulfill(id, 0);
        pool.finalize(id);
        vm.prank(buyer);
        pool.quickSell(id);
    }

    function testReserveBlocksWithdrawAndUnfundedOpening() public {
        pool.withdraw(address(this), pool.freeReserve());
        vm.expectRevert();
        vm.prank(buyer);
        pool.open(1);
        pool.fund(400e6);
        vm.prank(buyer);
        pool.open(1);
        vm.expectRevert();
        pool.withdraw(address(this), 51e6);
        require(pool.reserved() == 400e6);
    }

    function testOutOfOrderAndDuplicateCallbacks() public {
        vm.prank(buyer);
        pool.open(1);
        vm.prank(buyer);
        pool.open(1);
        rng.fulfill(2, 9999);
        rng.fulfill(1, 0);
        rng.fulfill(1, 9999);
        pool.finalize(1);
        pool.finalize(2);
        (,,,,, uint8 tier1,,) = pool.openings(1);
        (,,,,, uint8 tier2,,) = pool.openings(2);
        require(tier1 == 0 && tier2 == 3);
    }

    function testUnknownAuthenticatedCallbackIsIgnored() public {
        vm.prank(address(rng));
        pool.fulfillRandomness(999, 42);
        require(pool.openingCount() == 0);
    }

    function testInvalidConfiguration() public {
        uint16[4] memory odds = [uint16(7500), 2000, 400, 99];
        ExpoPool.Outcome[][4] memory items;
        for (uint8 t; t < 4; t++) {
            items[t] = new ExpoPool.Outcome[](1);
            items[t][0] = ExpoPool.Outcome(address(nft), t, 100e6);
        }
        vm.expectRevert();
        pool.createConfig(50e6, odds, 9000, 1 days, keccak256("x"), items);
        odds[3] = 100;
        vm.expectRevert();
        pool.createConfig(50e6, odds, 10001, 1 days, keccak256("x"), items);
    }

    function testTierBoundaries() public {
        pool.fund(4000e6);
        uint256[8] memory words = [uint256(0), 7499, 7500, 9499, 9500, 9899, 9900, 9999];
        for (uint256 i; i < 8; i++) {
            uint256 id = openAndReveal(words[i]);
            (,,,,, uint8 tier,,) = pool.openings(id);
            require(tier == i / 2);
            vm.prank(buyer);
            pool.quickSell(id);
        }
    }

    function testFuzzTierMapping(uint256 word) public {
        uint256 id = openAndReveal(word);
        (,,,,, uint8 tier,,) = pool.openings(id);
        uint256 r = word % 10000;
        require(tier == (r < 7500 ? 0 : r < 9500 ? 1 : r < 9900 ? 2 : 3));
        require(token.balanceOf(address(pool)) >= pool.reserved());
    }
}

contract FakeCoordinator is IVRFCoordinatorV2Plus {
    uint256 next;

    function requestRandomWords(RandomWordsRequest calldata r) external returns (uint256) {
        require(r.numWords == 1 && r.extraArgs.length == 36);
        require(r.requestConfirmations == 3 && r.callbackGasLimit == 200000);
        require(keccak256(r.extraArgs) == keccak256(abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)));
        return ++next;
    }

    function send(ChainlinkRandomness adapter, uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        adapter.rawFulfillRandomWords(id, words);
    }
}

contract AdapterTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public result;

    function fulfillRandomness(uint256, uint256 word) external {
        result = word;
    }

    function testOnlyBoundPoolCanRequestAndBind() public {
        FakeCoordinator c = new FakeCoordinator();
        ChainlinkRandomness a = new ChainlinkRandomness(address(c),1,bytes32(uint256(1)));
        vm.expectRevert(); vm.prank(address(0xBAD)); a.bindPool(address(this));
        a.bindPool(address(this));
        vm.expectRevert(); vm.prank(address(0xBAD)); a.request();
    }
    function testUnknownCoordinatorCallbackDoesNotAssignOutcome() public {
        FakeCoordinator c = new FakeCoordinator();
        ChainlinkRandomness a = new ChainlinkRandomness(address(c),1,bytes32(uint256(1)));
        a.bindPool(address(this));
        c.send(a,999,42); require(result == 0);
        uint256 id = a.request(); c.send(a,id,7); require(result == 7);
    }
    function testCoordinatorAuthenticationAndReplay() public {
        FakeCoordinator c = new FakeCoordinator();
        ChainlinkRandomness a = new ChainlinkRandomness(address(c), 1, bytes32(uint256(1)));
        a.bindPool(address(this));
        uint256 id = a.request();
        uint256[] memory words = new uint256[](1);
        vm.expectRevert();
        a.rawFulfillRandomWords(id, words);
        c.send(a, id, 42);
        require(result == 42);
        c.send(a, id, 13);
        require(result == 42);
        vm.expectRevert();
        a.bindPool(address(this));
    }
}

contract ReserveHandler {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    MockUSDC public token;
    MockNFT public nft;
    MockRandomness public rng;
    ExpoPool public pool;

    constructor() {
        token = new MockUSDC();
        nft = new MockNFT();
        rng = new MockRandomness();
        pool = new ExpoPool(token, IRandomness(address(rng)), address(this), address(this));
        ExpoPool.Outcome[][4] memory items;
        items[0] = new ExpoPool.Outcome[](1);
        items[0][0] = ExpoPool.Outcome(address(nft), 1, 100e6);
        pool.createConfig(50e6, [uint16(10000), 0, 0, 0], 9000, 1 days, keccak256("invariant"), items);
        token.mint(address(this), 1e15);
        token.approve(address(pool), type(uint256).max);
        pool.fund(10000e6);
    }

    function open() external {
        if (pool.freeReserve() + 50e6 >= 100e6 && pool.openingCount() < 100) pool.open(1);
    }

    function draw(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (,, ExpoPool.State s,,,,,) = pool.openings(id);
        if (s == ExpoPool.State.Pending) rng.fulfill(id, seed);
        if (s == ExpoPool.State.RandomReady) pool.finalize(id);
    }

    function settle(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (,, ExpoPool.State s, uint64 deadline,,,,) = pool.openings(id);
        if (s == ExpoPool.State.Revealed) {
            if (block.timestamp >= deadline) pool.compensate(id);
            else if (seed % 2 == 0) pool.quickSell(id);
            else pool.claimNFT(id);
        }
        if (s == ExpoPool.State.ClaimRequested) {
            if (block.timestamp >= deadline) {
                pool.compensate(id);
            } else {
                if (nft.balanceOf(address(this)) == 0) {
                    try nft.ownerOf(1) returns (address holder) {
                        if (holder != address(this)) return;
                    }
                        catch {
                        nft.mint(address(this), 1);
                    }
                }
                nft.approve(address(pool), 1);
                pool.deliver(id);
            }
        }
    }

    function elapse(uint32 seconds_) external {
        vm.warp(block.timestamp + seconds_ % 2 days);
    }

    function withdraw(uint256 seed) external {
        uint256 free = pool.freeReserve();
        if (free > 0) pool.withdraw(address(this), seed % (free + 1));
    }
}

contract ReserveInvariantTest {
    ReserveHandler handler;

    function setUp() public {
        handler = new ReserveHandler();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariantSolvencyAndLiabilityReconciliation() public view {
        ExpoPool pool = handler.pool();
        require(handler.token().balanceOf(address(pool)) >= pool.reserved());
        uint256 total;
        for (uint256 i = 1; i <= pool.openingCount(); i++) {
            (,, ExpoPool.State state,, uint128 liability,,,) = pool.openings(i);
            total += liability;
            if (uint8(state) >= uint8(ExpoPool.State.QuickSold)) require(liability == 0);
        }
        require(total == pool.reserved());
    }
}
