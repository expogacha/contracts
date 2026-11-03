// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ExpoGachaPool, IAdmission} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoAdmissionRegistry} from "../../src/v3/ExpoAdmissionRegistry.sol";
import {ExpoLaunchpad} from "../../src/v3/ExpoLaunchpad.sol";
import {ExpoVault} from "../../src/ExpoVault.sol";
import {deployTestVault} from "./VaultTestDeploy.sol";
import {IRandomness} from "../../src/ExpoPool.sol";
import {MockNFT, MockRandomness, MockWETH} from "../../src/MockAssets.sol";
import {V3Base} from "./ExpoGachaV3.t.sol";
import {AdvVm, FeeOnTransferToken, ScriptedRandomness, LockedNFTImpl, TokenSets} from "./V3TestMocks.sol";

/// @dev Adversarial gaps of docs/16, docs/31 and docs/33 (audit follow-up, docs/40). Every test here passes on the
/// current contracts. Tests named `test_KnownIssue_*` pin a CURRENT, UNWANTED behaviour described in
/// docs/40-v3-hardening-spec.md; they are expected to fail, and must then be inverted, when the fix lands.
abstract contract AdvBase is V3Base {
    AdvVm constant hv = AdvVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _opening(uint256 id)
        internal
        view
        returns (ExpoGachaPool.State s, uint64 deadline, uint128 liability, uint256 word, uint256 tokenId)
    {
        (,, s,,, deadline, liability,, word, tokenId) = pool.openings(id);
    }

    function _deadline(uint256 id) internal view returns (uint64 d) {
        (, d,,,) = _opening(id);
    }

    function _revealed(uint64 configId) internal returns (uint256 id) {
        id = _open(configId);
        _reveal(id);
    }

    function _one(address collection, uint256 lo, uint256 hi, bytes32 root, uint128 ref, uint128 budget)
        internal
        pure
        returns (ExpoGachaPool.Entitlement[][4] memory items)
    {
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = ExpoGachaPool.Entitlement(collection, lo, hi, root, ref, budget, 1);
    }

    function _raiseCap(uint256 cap) internal {
        pool.proposeWithdrawCap(cap);
        hv.warp(block.timestamp + 48 hours);
        pool.applyWithdrawCap();
    }
}

// ==================================================================== randomness (docs/16)

contract ExpoGachaRandomnessTest is AdvBase {
    ScriptedRandomness srng;
    ExpoGachaPool spool;
    uint64 cfg;

    function setUp() public override {
        super.setUp();
        srng = new ScriptedRandomness();
        ExpoVault v = deployTestVault(address(this));
        ExpoAdmissionRegistry r = new ExpoAdmissionRegistry(address(this), address(v));
        spool = new ExpoGachaPool(
            usdc, IRandomness(address(srng)), v, IAdmission(address(r)), OPERATOR, address(this), 1_000_000e6
        );
        v.bindPool(address(spool));
        address[] memory list = new address[](1);
        list[0] = address(nftA);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("a");
        r.admit(list, evidence, uint64(block.timestamp + 30 days));
        usdc.approve(address(spool), type(uint256).max);
        spool.fund(100_000e6);
        hv.prank(BUYER);
        usdc.approve(address(spool), type(uint256).max);
        cfg = spool.createConfig(_input(_items(address(nftA), bytes32(0))), ExpoGachaPool.Kind.Etf, 10);
    }

    function _sopen() internal returns (uint256 id) {
        hv.prank(BUYER);
        id = spool.open(cfg, 0);
    }

    function _sstate(uint256 id) internal view returns (ExpoGachaPool.State s, uint256 word) {
        (,, s,,,,,, word,) = spool.openings(id);
    }

    function test_CallbackOnlyFromProvider() public {
        uint256 o = _sopen();
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        spool.fulfillRandomness(1, 7);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        spool.fulfillRandomness(1, 7);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        spool.fulfillRandomness(1, 7); // even the owner
        (ExpoGachaPool.State s,) = _sstate(o);
        require(s == ExpoGachaPool.State.Pending, "still pending");
    }

    function test_UnknownRequestIdIsIgnored() public {
        uint256 o = _sopen();
        srng.push(address(spool), 999, 5);
        srng.push(address(spool), 0, 5);
        (ExpoGachaPool.State s, uint256 word) = _sstate(o);
        require(s == ExpoGachaPool.State.Pending && word == 0, "unknown request changes nothing");
        require(spool.requestOpening(999) == 0, "no binding created");
    }

    function test_DuplicateCallbackIsIgnored() public {
        uint256 o = _sopen();
        srng.push(address(spool), 1, 111);
        srng.push(address(spool), 1, 222);
        (ExpoGachaPool.State s, uint256 word) = _sstate(o);
        require(s == ExpoGachaPool.State.RandomReady && word == 111, "first word kept");
        spool.finalize(o);
        srng.push(address(spool), 1, 333);
        (s, word) = _sstate(o);
        require(s == ExpoGachaPool.State.Revealed && word == 111, "late duplicate ignored");
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        spool.finalize(o);
    }

    function test_OutOfOrderCallbacksBindToTheirOwnOpening() public {
        uint256 a = _sopen();
        uint256 b = _sopen();
        uint256 c = _sopen();
        srng.push(address(spool), 3, 30);
        srng.push(address(spool), 1, 10);
        (ExpoGachaPool.State sb,) = _sstate(b);
        require(sb == ExpoGachaPool.State.Pending, "b still waiting");
        srng.push(address(spool), 2, 20);
        (, uint256 wa) = _sstate(a);
        (, uint256 wb) = _sstate(b);
        (, uint256 wc) = _sstate(c);
        require(wa == 10 && wb == 20 && wc == 30, "each request binds its own opening");
    }

    function test_ZeroOrReusedRequestIdIsRejected() public {
        srng.force(0);
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        spool.open(cfg, 0);
        srng.force(1); // the reverted call left the forced zero in place; replace it
        _sopen(); // request 1
        srng.force(1);
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        spool.open(cfg, 0);
        require(spool.openingCount() == 1 && spool.reserved() == 50e6, "rejected openings left no trace");
    }

    function test_CallbackAfterSettlementIsIgnored() public {
        uint256 o = _sopen();
        srng.push(address(spool), 1, 42);
        spool.finalize(o);
        hv.prank(BUYER);
        spool.quickSell(o);
        srng.push(address(spool), 1, 43);
        (ExpoGachaPool.State s, uint256 word) = _sstate(o);
        require(s == ExpoGachaPool.State.QuickSold && word == 42, "terminal state untouched");
    }
}

// ==================================================================== settlement (docs/16, docs/33)

contract ExpoGachaSettlementTest is AdvBase {
    function test_DoubleSettlementAfterQuickSellReverts() public {
        uint64 id = _etf(10);
        uint256 o = _revealed(id);
        hv.prank(BUYER);
        pool.quickSell(o);
        uint256 balance = usdc.balanceOf(address(pool));
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.quickSell(o);
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.claimNFT(o);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.finalize(o);
        hv.warp(block.timestamp + 2 days);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.compensate(o);
        nftA.mint(address(vault), 1);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.fulfill(o, 1, new bytes32[](0));
        require(usdc.balanceOf(address(pool)) == balance && pool.reserved() == 0, "nothing paid twice");
    }

    function test_DoubleSettlementAfterDeliveryReverts() public {
        uint64 id = _etf(10);
        uint256 o = _claimed(id);
        nftA.mint(address(vault), 1);
        nftA.mint(address(vault), 2);
        hv.prank(OPERATOR);
        pool.fulfill(o, 1, new bytes32[](0));
        uint256 balance = usdc.balanceOf(address(pool));
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.fulfill(o, 2, new bytes32[](0));
        hv.warp(block.timestamp + 2 days);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.compensate(o);
        require(usdc.balanceOf(address(pool)) == balance && nftA.ownerOf(2) == address(vault), "one delivery");
    }

    function test_DoubleSettlementAfterCompensationReverts() public {
        uint64 id = _etf(10);
        uint256 o = _claimed(id);
        hv.warp(_deadline(o));
        pool.compensate(o);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.compensate(o);
        nftA.mint(address(vault), 1);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.fulfill(o, 1, new bytes32[](0));
    }

    function test_NoQuickSellClaimOrDeliveryAtOrAfterDeadline() public {
        uint64 id = _etf(10);
        uint256 a = _revealed(id);
        uint256 b = _claimed(id);
        nftA.mint(address(vault), 1);
        hv.warp(_deadline(a)); // exactly at the deadline counts as expired
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.Expired.selector);
        pool.quickSell(a);
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.Expired.selector);
        pool.claimNFT(a);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Expired.selector);
        pool.fulfill(b, 1, new bytes32[](0));
    }

    function test_CompensationBeforeDeadlineReverts() public {
        uint64 id = _etf(10);
        uint256 a = _revealed(id);
        uint256 b = _claimed(id);
        hv.warp(_deadline(a) - 1);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.compensate(a);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.compensate(b);
    }

    function test_CompensationAfterClaimRequestedPaysReferenceToBuyer() public {
        uint64 id = _etf(10);
        uint256 o = _claimed(id);
        hv.warp(_deadline(o));
        uint256 buyerBefore = usdc.balanceOf(BUYER);
        uint256 operatorBefore = usdc.balanceOf(OPERATOR);
        hv.prank(address(0xDEAD)); // permissionless trigger, buyer is paid
        pool.compensate(o);
        (ExpoGachaPool.State s,, uint128 liability,,) = _opening(o);
        require(s == ExpoGachaPool.State.Compensated && liability == 0, "compensated");
        require(usdc.balanceOf(BUYER) - buyerBefore == 40e6, "full reference, not budget");
        require(usdc.balanceOf(OPERATOR) == operatorBefore, "operator not reimbursed");
        require(pool.reserved() == 0 && _openNow(id) == 0, "reservation and slot released");
    }

    /// @dev docs/41 change 1: an opening the buyer never claimed compensates at the Quick Sell rate (90% of 40).
    function test_CompensationFromRevealed() public {
        uint64 id = _etf(10);
        uint256 o = _revealed(id);
        hv.warp(_deadline(o) + 1 days);
        uint256 before = usdc.balanceOf(BUYER);
        pool.compensate(o);
        require(usdc.balanceOf(BUYER) - before == 36e6 && _state(o) == ExpoGachaPool.State.Compensated, "paid");
        require(pool.reserved() == 0, "whole reservation released");
    }

    function test_UnauthorizedExits() public {
        uint64 id = _etf(10);
        uint256 o = _revealed(id);
        hv.prank(address(0xBAD));
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.quickSell(o);
        hv.prank(address(0xBAD));
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.claimNFT(o);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.quickSell(o);
        hv.prank(BUYER);
        pool.claimNFT(o);
        nftA.mint(address(vault), 1);
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.fulfill(o, 1, new bytes32[](0));
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.fulfill(o, 1, new bytes32[](0)); // the owner is not the operator
    }

    function test_FinalizeAndAwardedRequireRandomness() public {
        uint64 id = _etf(10);
        uint256 o = _open(id);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.finalize(o);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.awarded(o);
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.finalize(999);
    }

    function test_DeliveryOfMaxUint256TokenId() public {
        uint256 max = type(uint256).max;
        uint64 id = pool.createConfig(
            _input(_one(address(nftA), max - 1, max, bytes32(0), 40e6, 50e6)), ExpoGachaPool.Kind.Etf, 10
        );
        uint256 o = _claimed(id);
        nftA.mint(address(vault), max);
        uint256 before = usdc.balanceOf(OPERATOR);
        hv.prank(OPERATOR);
        pool.fulfill(o, max, new bytes32[](0));
        (,,,, uint256 tokenId) = _opening(o);
        require(nftA.ownerOf(max) == BUYER && tokenId == max, "uint256 max delivered and recorded");
        require(usdc.balanceOf(OPERATOR) - before == 50e6, "exact budget reimbursed");
    }

    function test_DeliveryRejectsTokenOutsideVaultOrRange() public {
        uint64 id = _etf(10);
        uint256 o = _claimed(id);
        nftA.mint(BUYER, 3);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 3, new bytes32[](0)); // not in the vault
        nftA.mint(address(vault), 1001);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 1001, new bytes32[](0)); // outside 0..1000
        hv.prank(OPERATOR);
        hv.expectRevert();
        pool.fulfill(o, 4, new bytes32[](0)); // never minted
        require(_state(o) == ExpoGachaPool.State.ClaimRequested, "claim still open");
    }

    function test_ZeroFreeWithdrawalUnderFullReservation() public {
        pool.withdraw(address(this), pool.freeReserve()); // the whole initial cap
        require(usdc.balanceOf(address(pool)) == 0, "emptied");
        pool.fund(50e6);
        uint64 id = _etf(10);
        uint256 o = _open(id);
        hv.warp(block.timestamp + 24 hours);
        require(pool.freeReserve() == 50e6, "only the price is free");
        pool.withdraw(address(this), 50e6);
        hv.expectRevert(ExpoGachaPool.Insolvent.selector);
        pool.withdraw(address(this), 1);
        require(usdc.balanceOf(address(pool)) == pool.reserved(), "fully reserved");
        _reveal(o);
        hv.prank(BUYER);
        pool.quickSell(o);
        require(pool.reserved() == 0, "settles from the reservation");
    }

    function test_OwnerDisableAfterPaymentStillDelivers() public {
        uint64 id = _etf(10);
        uint256 o = _open(id);
        pool.setEnabled(id, false);
        _reveal(o);
        hv.prank(BUYER);
        pool.claimNFT(o);
        nftA.mint(address(vault), 8);
        hv.prank(OPERATOR);
        pool.fulfill(o, 8, new bytes32[](0));
        require(nftA.ownerOf(8) == BUYER, "delivered after disable");
    }

    function test_PriceAndCapsCannotBeZeroOrOverflowBps() public {
        ExpoGachaPool.ConfigInput memory input = _input(_items(address(nftA), bytes32(0)));
        input.priceUsdc = 0;
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        input = _input(_items(address(nftA), bytes32(0)));
        input.quickSellBps = 10001;
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        input = _input(_items(address(nftA), bytes32(0)));
        input.odds = [uint16(9999), 0, 0, 0];
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        input = _input(_items(address(nftA), bytes32(0)));
        input.odds = [uint16(5000), 5000, 0, 0]; // tier 1 has odds but no entitlement
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
    }

    // ---------------------------------------------------------- tier boundaries

    function _fourTiers() internal returns (uint64) {
        ExpoGachaPool.Entitlement[][4] memory items;
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](1);
            // One item per band of the 50 price: 30 / 50 / 100 / 200 (EV 44).
            uint128 value = [uint128(30e6), 50e6, 100e6, 200e6][t];
            items[t][0] = ExpoGachaPool.Entitlement(address(nftA), 0, 1000, bytes32(0), value, value, 1);
        }
        ExpoGachaPool.ConfigInput memory input = _input(items);
        input.odds = [uint16(6000), 3000, 900, 100];
        return pool.createConfig(input, ExpoGachaPool.Kind.Etf, 1000);
    }

    function _tierFor(uint64 id, uint256 word) internal returns (uint256) {
        uint256 o = _open(id);
        rng.fulfill(rng.count(), word);
        pool.finalize(o);
        uint128 value = pool.awarded(o).referenceUsdc;
        return value == 30e6 ? 0 : value == 50e6 ? 1 : value == 100e6 ? 2 : 3;
    }

    function _expectedTier(uint256 word) internal pure returns (uint256) {
        uint256 roll = word % 10000;
        return roll < 6000 ? 0 : roll < 9000 ? 1 : roll < 9900 ? 2 : 3;
    }

    function test_ExactTierBoundaries() public {
        uint64 id = _fourTiers();
        uint256[8] memory words = [uint256(0), 5999, 6000, 8999, 9000, 9899, 9900, 9999];
        uint256[8] memory tiers = [uint256(0), 0, 1, 1, 2, 2, 3, 3];
        for (uint256 i; i < 8; ++i) {
            require(_tierFor(id, words[i]) == tiers[i], "boundary");
        }
        require(_tierFor(id, type(uint256).max) == _expectedTier(type(uint256).max), "max word");
    }

    function testFuzz_TierFollowsWord(uint256 word) public {
        uint64 id = _fourTiers();
        require(_tierFor(id, word) == _expectedTier(word), "tier from word % 10000");
    }
}

// ==================================================================== frozen token sets (docs/32, docs/33)

contract ExpoGachaMerkleTest is AdvBase {
    function test_ProofFromAnotherTierFails() public {
        uint256[4] memory set0 = [uint256(1), 2, 3, 4];
        uint256[4] memory set1 = [uint256(11), 12, 13, 14];
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = ExpoGachaPool.Entitlement(
            address(nftA), 0, 1000, TokenSets.root4(address(nftA), set0), 40e6, 50e6, 1
        );
        items[1] = new ExpoGachaPool.Entitlement[](1);
        items[1][0] = ExpoGachaPool.Entitlement(
            address(nftA), 0, 1000, TokenSets.root4(address(nftA), set1), 80e6, 90e6, 1
        );
        ExpoGachaPool.ConfigInput memory input = _input(items);
        input.odds = [uint16(8000), 2000, 0, 0]; // EV 48 at the 50 price
        uint64 id = pool.createConfig(input, ExpoGachaPool.Kind.Collection, 10);
        uint256 o = _open(id);
        rng.fulfill(rng.count(), 1); // roll 1: tier 0
        pool.finalize(o);
        hv.prank(BUYER);
        pool.claimNFT(o);
        nftA.mint(address(vault), 12);
        nftA.mint(address(vault), 2);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 12, TokenSets.proof4(address(nftA), set1, 1)); // a valid tier-1 proof
        hv.prank(OPERATOR);
        pool.fulfill(o, 2, TokenSets.proof4(address(nftA), set0, 1));
        require(nftA.ownerOf(2) == BUYER, "tier-0 token delivered");
    }

    function test_TokenInSetButOutsideRangeFails() public {
        uint256[4] memory set = [uint256(1), 2, 3, 2000];
        bytes32 root = TokenSets.root4(address(nftA), set);
        uint64 id = pool.createConfig(
            _input(_one(address(nftA), 0, 1000, root, 40e6, 50e6)), ExpoGachaPool.Kind.Collection, 10
        );
        uint256 o = _claimed(id);
        nftA.mint(address(vault), 2000);
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 2000, TokenSets.proof4(address(nftA), set, 3));
    }

    function test_MaxUint256TokenIdInMerkleSet() public {
        uint256 max = type(uint256).max;
        uint256[4] memory set = [uint256(1), 2, max - 1, max];
        bytes32 root = TokenSets.root4(address(nftA), set);
        uint64 id = pool.createConfig(
            _input(_one(address(nftA), 0, max, root, 40e6, 50e6)), ExpoGachaPool.Kind.Collection, 10
        );
        uint256 o = _claimed(id);
        nftA.mint(address(vault), max);
        hv.prank(OPERATOR);
        pool.fulfill(o, max, TokenSets.proof4(address(nftA), set, 3));
        require(nftA.ownerOf(max) == BUYER, "max token in a frozen set");
    }

    function test_InnerNodeCannotBeDeliveredAsLeaf() public {
        uint256[4] memory set = [uint256(1), 2, 3, 4];
        bytes32 root = TokenSets.root4(address(nftA), set);
        uint64 id = pool.createConfig(
            _input(_one(address(nftA), 0, type(uint256).max, root, 40e6, 50e6)), ExpoGachaPool.Kind.Collection, 10
        );
        uint256 o = _claimed(id);
        // Interpret the inner node pair(leaf1, leaf2) as a token ID and prove it with the sibling subtree.
        uint256 fake = uint256(TokenSets.pair(TokenSets.leaf(address(nftA), 1), TokenSets.leaf(address(nftA), 2)));
        nftA.mint(address(vault), fake);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = TokenSets.pair(TokenSets.leaf(address(nftA), 3), TokenSets.leaf(address(nftA), 4));
        hv.prank(OPERATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, fake, proof);
    }
}

// ==================================================================== launchpad quotes (docs/31, docs/33)

contract ExpoLaunchpadAdversarialTest is AdvBase {
    function _copy(ExpoLaunchpad.Quote memory b) internal pure returns (ExpoLaunchpad.Quote memory) {
        return ExpoLaunchpad.Quote(
            b.creator,
            b.gachaId,
            b.priceUsdc,
            [b.odds[0], b.odds[1], b.odds[2], b.odds[3]],
            b.entitlementsHash,
            b.quickSellBps,
            b.settlementWindow,
            b.creatorFeeBps,
            b.maxOpen,
            b.metadataHash,
            b.nonce,
            b.expiresAt
        );
    }

    /// @dev Every one of the 12 quote fields is covered by the signature, not only the price.
    function test_EveryQuoteFieldIsSigned() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory base = _quote(items, 100, 10);
        bytes memory sig = _sign(base, SIGNER_KEY);
        address other = address(0xA77AC);
        usdc.mint(other, 1_000e6);
        hv.prank(other);
        usdc.approve(address(launchpad), type(uint256).max);
        for (uint256 field; field < 12; ++field) {
            ExpoLaunchpad.Quote memory q = _copy(base);
            if (field == 0) q.creator = other;
            else if (field == 1) q.gachaId = bytes32("other");
            else if (field == 2) q.priceUsdc = base.priceUsdc - 1;
            else if (field == 3) q.odds = [uint16(9999), 1, 0, 0];
            else if (field == 4) q.entitlementsHash = keccak256("other items");
            else if (field == 5) q.quickSellBps = 10000;
            else if (field == 6) q.settlementWindow = 30 days;
            else if (field == 7) q.creatorFeeBps = 300;
            else if (field == 8) q.maxOpen = 1000;
            else if (field == 9) q.metadataHash = keccak256("other payload");
            else if (field == 10) q.nonce = base.nonce + 1;
            else q.expiresAt = base.expiresAt + 1 days;
            hv.prank(q.creator);
            hv.expectRevert(ExpoLaunchpad.BadSignature.selector);
            launchpad.launch(q, items, sig);
        }
        hv.prank(CREATOR);
        launchpad.launch(base, items, sig); // the untouched quote is still valid
    }

    function test_CrossChainReplayFails() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory q = _quote(items, 100, 10);
        bytes memory sig = _sign(q, SIGNER_KEY);
        hv.chainId(1);
        hv.prank(CREATOR);
        hv.expectRevert(ExpoLaunchpad.BadSignature.selector);
        launchpad.launch(q, items, sig);
    }

    function test_CrossContractReplayFails() public {
        ExpoLaunchpad twin = new ExpoLaunchpad(pool, address(this), vm.addr(SIGNER_KEY), 25e6);
        pool.setConfigurator(address(twin));
        hv.prank(CREATOR);
        usdc.approve(address(twin), type(uint256).max);
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory q = _quote(items, 100, 10);
        bytes memory sig = _sign(q, SIGNER_KEY); // domain: the original launchpad
        hv.prank(CREATOR);
        hv.expectRevert(ExpoLaunchpad.BadSignature.selector);
        twin.launch(q, items, sig);
    }

    function test_HighSMalleableSignatureRejected() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory q = _quote(items, 100, 10);
        (uint8 v, bytes32 r, bytes32 s) = hv.sign(SIGNER_KEY, launchpad.quoteDigest(q));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory flipped = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        hv.prank(CREATOR);
        hv.expectRevert();
        launchpad.launch(q, items, flipped);
        hv.prank(CREATOR);
        launchpad.launch(q, items, abi.encodePacked(r, s, v));
    }

    function test_PoolRevalidatesSignedEconomics() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory q = _quote(items, 100, 10);
        q.odds = [uint16(9000), 0, 0, 0]; // signed, but the odds do not sum to 10,000
        bytes memory sig = _sign(q, SIGNER_KEY);
        hv.prank(CREATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        launchpad.launch(q, items, sig);
        q = _quote(items, 100, 10);
        q.quickSellBps = 10001;
        sig = _sign(q, SIGNER_KEY);
        hv.prank(CREATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        launchpad.launch(q, items, sig);
        q = _quote(items, 100, 0);
        sig = _sign(q, SIGNER_KEY);
        hv.prank(CREATOR);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        launchpad.launch(q, items, sig);
        require(usdc.balanceOf(CREATOR) == 1_000e6, "no creation fee taken on a refused launch");
    }
}

// ==================================================================== fee-on-transfer token (docs/16)

contract ExpoGachaFeeTokenTest {
    AdvVm constant hv = AdvVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function test_FeeOnTransferFundingAndPaymentRejected() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        MockRandomness rng = new MockRandomness();
        ExpoVault vault = deployTestVault(address(this));
        ExpoAdmissionRegistry registry = new ExpoAdmissionRegistry(address(this), address(vault));
        ExpoGachaPool pool = new ExpoGachaPool(
            IERC20(address(token)), IRandomness(address(rng)), vault, IAdmission(address(registry)), address(0xBEEF),
            address(this), 1e30
        );
        vault.bindPool(address(pool));
        MockNFT nft = new MockNFT();
        address[] memory list = new address[](1);
        list[0] = address(nft);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("e");
        registry.admit(list, evidence, uint64(block.timestamp + 1 days));
        token.mint(address(this), 1e30);
        token.approve(address(pool), type(uint256).max);

        token.setFee(true);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fund(1_000e18);
        token.setFee(false);
        pool.fund(1_000e18);

        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = ExpoGachaPool.Entitlement(address(nft), 0, 10, bytes32(0), 1e18, 1e18, 1);
        uint64 id = pool.createConfig(
            ExpoGachaPool.ConfigInput(bytes32("g"), 2e18, [uint16(10000), 0, 0, 0], 9000, 1 days, keccak256("m"), items),
            ExpoGachaPool.Kind.Etf,
            10
        );
        token.setFee(true);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.open(id, 0);
        require(pool.openingCount() == 0 && pool.reserved() == 0, "short payment opens nothing");
    }
}

// ==================================================================== WETH pool, wei amounts (docs/36)

contract ExpoGachaWethTest {
    AdvVm constant hv = AdvVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant SIGNER_KEY = 0xA11CE;
    address constant OPERATOR = address(0xBEEF);
    address constant BUYER = address(0xB0B);
    address constant CREATOR = address(0xC0FFEE);

    MockWETH weth;
    MockRandomness rng;
    ExpoVault vault;
    ExpoAdmissionRegistry registry;
    ExpoGachaPool pool;
    ExpoLaunchpad launchpad;
    MockNFT nft;

    function setUp() public {
        weth = new MockWETH();
        rng = new MockRandomness();
        vault = deployTestVault(address(this));
        registry = new ExpoAdmissionRegistry(address(this), address(vault));
        pool = new ExpoGachaPool(
            IERC20(address(weth)), IRandomness(address(rng)), vault, IAdmission(address(registry)), OPERATOR,
            address(this), 2 ether
        );
        vault.bindPool(address(pool));
        launchpad = new ExpoLaunchpad(pool, address(this), hv.addr(SIGNER_KEY), 0.001 ether);
        pool.setConfigurator(address(launchpad));
        nft = new MockNFT();
        address[] memory list = new address[](1);
        list[0] = address(nft);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("weth");
        registry.admit(list, evidence, uint64(block.timestamp + 30 days));
        hv.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.approve(address(pool), type(uint256).max);
        pool.fund(10 ether);
        _wallet(BUYER, address(pool));
        _wallet(CREATOR, address(launchpad));
    }

    receive() external payable {}

    function _wallet(address who, address spender) internal {
        hv.deal(who, 1 ether);
        hv.startPrank(who);
        weth.deposit{value: 0.5 ether}();
        weth.approve(spender, type(uint256).max);
        hv.stopPrank();
    }

    function _items() internal view returns (ExpoGachaPool.Entitlement[][4] memory items) {
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = ExpoGachaPool.Entitlement(address(nft), 0, 1000, bytes32(0), 0.001 ether, 0.0012 ether, 1);
    }

    function _config() internal returns (uint64) {
        return pool.createConfig(
            ExpoGachaPool.ConfigInput(
                bytes32("nft-art"), 0.002 ether, [uint16(10000), 0, 0, 0], 9000, 1 days, keccak256("w"), _items()
            ),
            ExpoGachaPool.Kind.Etf,
            25
        );
    }

    function _revealed(uint64 id) internal returns (uint256 o) {
        hv.prank(BUYER);
        o = pool.open(id, 0);
        rng.fulfill(rng.count(), 7);
        pool.finalize(o);
    }

    function _accounts() internal view {
        require(weth.balanceOf(address(pool)) == pool.freeReserve() + pool.reserved() + pool.creatorFeesOwed(), "acct");
        require(address(weth).balance == weth.totalSupply(), "WETH fully backed");
    }

    function test_WethQuickSellAndUnwrap() public {
        uint64 id = _config();
        uint256 o = _revealed(id);
        require(pool.reserved() == 0.0012 ether, "reserved in wei");
        uint256 before = weth.balanceOf(BUYER);
        hv.prank(BUYER);
        pool.quickSell(o);
        require(weth.balanceOf(BUYER) - before == 0.0009 ether, "90% of the reference, in wei");
        uint256 eth = BUYER.balance;
        hv.prank(BUYER);
        weth.withdraw(0.0009 ether);
        require(BUYER.balance - eth == 0.0009 ether, "winnings unwrap to ETH");
        _accounts();
    }

    function test_WethDeliveryReimbursesOperatorAndCompensationPaysBuyer() public {
        uint64 id = _config();
        uint256 a = _revealed(id);
        hv.prank(BUYER);
        pool.claimNFT(a);
        nft.mint(address(vault), 5);
        hv.prank(OPERATOR);
        pool.fulfill(a, 5, new bytes32[](0));
        require(nft.ownerOf(5) == BUYER && weth.balanceOf(OPERATOR) == 0.0012 ether, "budget reimbursed in WETH");
        uint256 b = _revealed(id);
        hv.prank(BUYER);
        pool.claimNFT(b);
        (,,,,, uint64 deadline,,,,) = pool.openings(b);
        hv.warp(deadline);
        uint256 before = weth.balanceOf(BUYER);
        pool.compensate(b);
        require(weth.balanceOf(BUYER) - before == 0.001 ether, "reference compensation in WETH");
        // Never claimed: compensation at the Quick Sell rate, in wei (docs/41).
        uint256 c = _revealed(id);
        (,,,,, uint64 late,,,,) = pool.openings(c);
        hv.warp(late);
        before = weth.balanceOf(BUYER);
        pool.compensate(c);
        require(weth.balanceOf(BUYER) - before == 0.0009 ether, "unclaimed compensation at 90% in WETH");
        _accounts();
    }

    function test_WethLaunchFeesAndCreatorWithdrawal() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items();
        ExpoLaunchpad.Quote memory q = ExpoLaunchpad.Quote(
            CREATOR, bytes32("lp"), 0.002 ether, [uint16(10000), 0, 0, 0], keccak256(abi.encode(items)), 9000, 1 days,
            300, 5, keccak256("lp"), 1, uint64(block.timestamp + 30 minutes)
        );
        (uint8 v, bytes32 r, bytes32 s) = hv.sign(SIGNER_KEY, launchpad.quoteDigest(q));
        uint256 poolBefore = weth.balanceOf(address(pool));
        hv.prank(CREATOR);
        uint64 id = launchpad.launch(q, items, abi.encodePacked(r, s, v));
        require(weth.balanceOf(address(pool)) - poolBefore == 0.001 ether, "creation fee in wei");
        _revealed(id);
        require(pool.creatorBalance(CREATOR) == 0.00006 ether, "3% of 0.002 ETH");
        uint256 eth = CREATOR.balance;
        hv.startPrank(CREATOR);
        pool.withdrawCreatorFees();
        weth.withdraw(0.00006 ether);
        hv.stopPrank();
        require(CREATOR.balance - eth == 0.00006 ether && pool.creatorFeesOwed() == 0, "creator fee unwrapped");
        _accounts();
    }

    function test_PlainEthToPoolIsRefused() public {
        hv.deal(BUYER, 1 ether);
        hv.prank(BUYER);
        (bool ok,) = address(pool).call{value: 1 wei}("");
        require(!ok, "the pool only takes WETH");
    }
}

// ==================================================================== known issues (docs/40)

/// @dev Each `test_KnownIssue_*` documents CURRENT behaviour that docs/40-v3-hardening-spec.md proposes to change.
/// When the fix lands the test must fail; invert it into the regression test listed in docs/40 for that finding.
/// `test_Regression_*` tests are known issues already inverted by docs/41 or docs/46 (v3.2: H-1, H-2, M-2, L-3).
contract ExpoGachaKnownIssuesTest is AdvBase {
    /// @dev docs/40 H-1, inverted by docs/46 (v3.2): the 1-wei configuration whose only entitlement references the
    /// whole free reserve is refused by the bands (a Common is worth less than the price) and by the EV ceiling.
    function test_Regression_H1_ReserveSizedConfigRejected() public {
        uint256 free = pool.freeReserve();
        ExpoGachaPool.ConfigInput memory input = _input(_one(address(nftA), 0, 0, bytes32(0), uint128(free), 1));
        input.priceUsdc = 1;
        input.quickSellBps = 10000;
        input.settlementWindow = 1 hours;
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 1);
        input.items[0][0].budgetUsdc = uint128(free); // no budget trick either
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 1);
    }

    /// @dev Regression for docs/41 change 1: with Quick Sell at 0%, waiting out the window on an unclaimed opening
    /// pays the Quick Sell amount, zero.
    function test_Regression_H1_UnclaimedCompensationPaysQuickSellRate() public {
        ExpoGachaPool.ConfigInput memory input = _input(_items(address(nftA), bytes32(0)));
        input.quickSellBps = 0;
        input.settlementWindow = 1 hours;
        uint64 id = pool.createConfig(input, ExpoGachaPool.Kind.Etf, 1);
        uint256 free = pool.freeReserve();
        uint256 before = usdc.balanceOf(address(this));
        uint256 o = pool.open(id, 0);
        rng.fulfill(rng.count(), 1);
        pool.finalize(o);
        hv.warp(block.timestamp + 1 hours);
        pool.compensate(o);
        require(before - usdc.balanceOf(address(this)) == 50e6, "only the price left the owner; nothing paid out");
        require(_state(o) == ExpoGachaPool.State.Compensated && pool.reserved() == 0, "settled, reservation released");
        require(pool.freeReserve() == free + 50e6, "reserve intact");
    }

    /// @dev docs/40 H-1, claimed-compensation route, bounded by docs/46: the full reference is still paid after a
    /// lapsed claim, but a Common is worth less than its price and the EV is at most the price, so the owner's
    /// best single-item configuration loses on every cycle.
    function test_Regression_H1_ClaimedCompensationUnprofitable() public {
        pool.proposeWithdrawCap(0);
        ExpoGachaPool.ConfigInput memory input = _input(_one(address(nftA), 0, 0, bytes32(0), 50e6 - 1, 50e6 - 1));
        input.quickSellBps = 0;
        input.settlementWindow = 1 hours;
        uint64 id = pool.createConfig(input, ExpoGachaPool.Kind.Etf, 1);
        uint256 before = usdc.balanceOf(address(this));
        uint256 o = pool.open(id, 0);
        rng.fulfill(rng.count(), 1);
        pool.finalize(o);
        pool.claimNFT(o);
        hv.warp(block.timestamp + 1 hours);
        pool.compensate(o);
        require(usdc.balanceOf(address(this)) < before, "a cycle costs the owner money");
    }

    /// @dev docs/40 H-2, bounded by docs/46: an EOA configurator without a signed quote is held to the same on-chain
    /// checks, so the reserve-sized 1-wei launch is refused.
    function test_Regression_H2_ConfiguratorEoaBoundedByChecks() public {
        address eoa = address(0xE0A);
        pool.setConfigurator(eoa);
        uint256 share = (usdc.balanceOf(address(pool)) - pool.creatorFeesOwed()) * 2500 / 10000 - 1;
        ExpoGachaPool.ConfigInput memory input = _input(_one(address(nftA), 0, 0, bytes32(0), uint128(share), 1));
        input.priceUsdc = 1;
        input.quickSellBps = 10000;
        hv.prank(eoa);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createLaunchpadConfig(input, eoa, 0, 1);
    }

    /// @dev docs/40 M-1. Admission binds the proxy's code hash only; an EIP-1967 implementation upgrade to a
    /// transfer-locked token keeps the collection admitted, and delivery then fails.
    function test_KnownIssue_M1_Erc1967UpgradeKeepsAdmission() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new MockNFT()), "");
        MockNFT token = MockNFT(address(proxy));
        _admit(address(token));
        uint64 id = pool.createConfig(_input(_items(address(token), bytes32(0))), ExpoGachaPool.Kind.Etf, 10);
        token.mint(address(vault), 1);
        uint256 o = _claimed(id);
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        hv.store(address(proxy), slot, bytes32(uint256(uint160(address(new LockedNFTImpl())))));
        require(registry.isAdmitted(address(token)), "still admitted after the implementation changed");
        _open(id); // new commitments are still accepted
        hv.prank(OPERATOR);
        hv.expectRevert(bytes("transfers locked"));
        pool.fulfill(o, 1, new bytes32[](0));
    }

    /// @dev docs/40 M-1, beacon variant.
    function test_KnownIssue_M1_BeaconUpgradeKeepsAdmission() public {
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new MockNFT()), address(this));
        MockNFT token = MockNFT(address(new BeaconProxy(address(beacon), "")));
        _admit(address(token));
        beacon.upgradeTo(address(new LockedNFTImpl()));
        require(registry.isAdmitted(address(token)), "still admitted after the beacon changed");
    }

    /// @dev docs/40 M-2, inverted by docs/46 (option A): after VRF_TIMEOUT anyone refunds a pending opening, which
    /// frees its reservation and its `openNow` slot.
    function test_Regression_M2_StaleOpeningRefunded() public {
        uint64 id = _etf(1);
        uint256 o = _open(id);
        hv.warp(block.timestamp + 365 days);
        _admit(address(nftA)); // keep the collection admitted so only the stuck slot blocks
        require(pool.reserved() == 50e6 && _openNow(id) == 1, "reservation and slot held while pending");
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.CapReached.selector);
        pool.open(id, 0);
        uint256 balance = usdc.balanceOf(BUYER);
        pool.refundStale(o);
        require(_state(o) == ExpoGachaPool.State.Refunded && usdc.balanceOf(BUYER) - balance == 50e6, "refunded");
        require(pool.reserved() == 0 && _openNow(id) == 0, "released");
        _open(id); // the slot is usable again
    }

    /// @dev docs/40 L-1. The pool accepts a registry whose evidence is bound to another vault.
    function test_KnownIssue_L1_PoolAcceptsRegistryOfAnotherVault() public {
        ExpoVault otherVault = deployTestVault(address(this));
        ExpoVault poolVault = deployTestVault(address(this));
        ExpoAdmissionRegistry other = new ExpoAdmissionRegistry(address(this), address(otherVault));
        ExpoGachaPool mismatched = new ExpoGachaPool(
            usdc, IRandomness(address(rng)), poolVault, IAdmission(address(other)), OPERATOR, address(this), 0
        );
        require(other.vault() != address(mismatched.vault()), "constructed with mismatched vaults");
    }

    /// @dev docs/40 L-2. Nonces are global across creators and a single outstanding quote cannot be revoked: the
    /// only cancellation is rotating the signer, which also kills every other outstanding quote.
    function test_KnownIssue_L2_GlobalNoncesAndNoPerQuoteRevocation() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory mine = _quote(items, 100, 10);
        address other = address(0xA77AC);
        usdc.mint(other, 1_000e6);
        hv.prank(other);
        usdc.approve(address(launchpad), type(uint256).max);
        ExpoLaunchpad.Quote memory theirs = _quote(items, 100, 10);
        theirs.creator = other;
        theirs.nonce = mine.nonce; // same nonce, different creator
        bytes memory theirSig = _sign(theirs, SIGNER_KEY);
        bytes memory mySig = _sign(mine, SIGNER_KEY);
        hv.prank(CREATOR);
        launchpad.launch(mine, items, mySig);
        hv.prank(other);
        hv.expectRevert(ExpoLaunchpad.Used.selector);
        launchpad.launch(theirs, items, theirSig);
        (bool ok,) = address(launchpad).call(abi.encodeWithSignature("cancelQuote(uint256)", uint256(99)));
        require(!ok, "no per-quote cancellation exists");
    }

    /// @dev docs/40 L-3, inverted by docs/46: the old maxima (4 tiers x 256) are refused; the new bounds (128 per
    /// configuration) fit in 25M gas (test_CreateConfigGasAtMaximum).
    function test_Regression_L3_OldMaximaRejected() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](256);
            uint128 ref = t == 0 ? 40e6 : uint128(50e6 << (t - 1));
            for (uint256 j; j < 256; ++j) {
                items[t][j] = ExpoGachaPool.Entitlement(address(nftA), j, j + 1, bytes32(0), ref, ref, 1);
            }
        }
        ExpoGachaPool.ConfigInput memory input = _input(items);
        input.odds = [uint16(9700), 100, 100, 100];
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 1);
        require(pool.MAX_PER_TIER() == 128 && pool.MAX_ENTRIES() == 128, "bounds");
    }

    /// @dev docs/40 L-4. A creator's disable is final for the creator but the owner can re-enable the launch.
    function test_KnownIssue_L4_OwnerReenablesCreatorDisabledLaunch() public {
        uint64 lp = _launch(0, 10);
        hv.prank(CREATOR);
        pool.setEnabled(lp, false);
        pool.setEnabled(lp, true);
        _open(lp);
        require(_openNow(lp) == 1, "opened against the creator's decision");
    }
}
