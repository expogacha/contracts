// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoGachaPool} from "../../src/v3/ExpoGachaPool.sol";
import {OddsBase} from "./OddsTestBase.sol";

/// @dev Expo's own gachas on v3.2 (docs/46 section 17): the price bands bind launches only, and the owner's rarity and
/// ETF tiers are exempt from them and from nothing else. Written before the implementation: the acceptance tests fail on
/// a pool that applies the bands to every kind.
contract ExpoGachaRarityTest is OddsBase {
    bytes32 constant ROOT = bytes32(uint256(1));
    address constant CONFIGURATOR = address(0xC0F);

    function _tier(uint128 ref, uint128 budget) internal view returns (ExpoGachaPool.Entitlement[] memory t) {
        t = new ExpoGachaPool.Entitlement[](1);
        t[0] = ExpoGachaPool.Entitlement(address(nftA), 0, type(uint256).max, ROOT, ref, budget, 1);
    }

    function _rarity(uint128 price, uint16[4] memory odds, uint128[4] memory refs, uint128[4] memory budgets)
        internal
        view
        returns (ExpoGachaPool.ConfigInput memory)
    {
        ExpoGachaPool.Entitlement[][4] memory items;
        for (uint256 t; t < 4; ++t) {
            items[t] = _tier(refs[t], budgets[t]);
        }
        return _input(items, price, odds);
    }

    function _accept(uint128 price, uint16[4] memory odds, uint128[4] memory refs, uint128[4] memory budgets)
        internal
        returns (uint64)
    {
        return pool.createConfig(_rarity(price, odds, refs, budgets), ExpoGachaPool.Kind.Collection, 10);
    }

    /// @dev Price 100; Common dearer than Uncommon, Rare cheaper than Uncommon: the shape a rarity cut can really have.
    /// Liabilities 60, 50, 55, 800. Expected reference 0.5*48 + 0.3*40 + 0.15*44 + 0.05*640 = 74.6.
    function _unsorted() internal returns (uint64) {
        return _accept(
            P,
            [uint16(5000), 3000, 1500, 500],
            [uint128(48e6), 40e6, 44e6, 640e6],
            [uint128(60e6), 50e6, 55e6, 800e6]
        );
    }

    // ------------------------------------------------------------ the exemption

    function test_AcceptsTheFiveLaunchGachas() public {
        // Invisible Friends, from packages/catalog/mainnet/gachas.json
        _accept(505620000000000000, [uint16(5504), 2846, 1423, 227], [uint128(206900000000000000), 400000000000000000, 800000000000000000, 5000000000000000000], [uint128(258625000000000000), 500000000000000000, 1000000000000000000, 6250000000000000000]);
        // Jirasan, from packages/catalog/mainnet/gachas.json
        _accept(19980000000000000, [uint16(5418), 3262, 810, 510], [uint128(8300000000000000), 13780000000000000, 55500000000000000, 88000000000000000], [uint128(10375000000000000), 17225000000000000, 69375000000000000, 110000000000000000]);
        // Imaginary Ones, from packages/catalog/mainnet/gachas.json
        _accept(36850000000000000, [uint16(4763), 4498, 729, 10], [uint128(16999000000000000), 17998000000000000, 111000000000000000, 8880000000000000000], [uint128(21248750000000000), 22497500000000000, 138750000000000000, 11100000000000000000]);
        // Genuine Undead, from packages/catalog/mainnet/gachas.json
        _accept(149840000000000000, [uint16(3182), 3180, 2443, 1195], [uint128(105995000000000000), 106000000000000000, 138000000000000000, 282000000000000000], [uint128(132493750000000000), 132500000000000000, 172500000000000000, 352500000000000000]);
        // BRAINROT by Nuclear Samurai, from packages/catalog/mainnet/gachas.json
        _accept(19340000000000000, [uint16(4144), 4348, 1208, 300], [uint128(10500000000000000), 10003000000000000, 36000000000000000, 145000000000000000], [uint128(13125000000000000), 12503750000000000, 45000000000000000, 181250000000000000]);
    }

    /// @dev Bluechip's reviewed tiers at its inverse-value price: Uncommon holds a prize below the price.
    function test_AcceptsAnEtfOutsideTheBands() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = _e(address(nftA), 30e6, 37.5e6, 4);
        items[1] = new ExpoGachaPool.Entitlement[](2);
        items[1][0] = _e(address(nftB), 92e6, 115e6, 3); // below the price of 100: Common by the bands
        items[1][1] = _e(address(nftC), 97e6, 121.25e6, 2);
        pool.createConfig(_input(items, P, [uint16(7500), 2500, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
    }

    function test_EtfKeepsEveryOtherCheck() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = _e(address(nftA), 120e6, 120e6, 1); // above the expected-value ceiling
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        items[0][0] = _e(address(nftA), 40e6, 60e6 + 1, 1); // budget above 1.5 x reference
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = _e(address(nftA), 40e6, 50e6, 1);
        items[0][1] = _e(address(nftB), 41e6, 51e6, 2); // the dearer prize likelier
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
    }

    function test_BandsStillApplyToLaunches() public {
        pool.setConfigurator(CONFIGURATOR);
        ExpoGachaPool.ConfigInput memory input =
            _rarity(P, [uint16(5000), 3000, 1500, 500], [uint128(48e6), 40e6, 44e6, 640e6], [uint128(60e6), 50e6, 55e6, 800e6]);
        ov.prank(CONFIGURATOR);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createLaunchpadConfig(input, BUYER, 0, 10);
    }

    function test_OnlyTheOwnerCreatesAnExemptGacha() public {
        ExpoGachaPool.ConfigInput memory input =
            _rarity(P, [uint16(5000), 3000, 1500, 500], [uint128(48e6), 40e6, 44e6, 640e6], [uint128(60e6), 50e6, 55e6, 800e6]);
        ov.prank(BUYER);
        ov.expectRevert();
        pool.createConfig(input, ExpoGachaPool.Kind.Collection, 10);
    }

    // ------------------------------------------------------------ everything else still holds

    function test_EvCeilingStillApplies() public {
        // Expected reference 0.9*120 + 0.1*40 = 112, above the price of 100.
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = _tier(120e6, 120e6);
        items[1] = _tier(40e6, 40e6);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(9000), 1000, 0, 0]), ExpoGachaPool.Kind.Collection, 10);
    }

    function test_EvExactlyThePriceIsAccepted() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = _tier(100e6, 100e6);
        pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Collection, 10);
    }

    function test_BudgetCapStillApplies() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = _tier(40e6, 60e6 + 1); // above 1.5 x reference
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Collection, 10);
    }

    function test_TokenRootStillRequired() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = _tier(40e6, 50e6);
        items[0][0].tokenRoot = bytes32(0);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Collection, 10);
    }

    function test_OneCollectionStillRequired() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = _tier(40e6, 50e6);
        items[1] = _tier(40e6, 50e6);
        items[1][0].collection = address(nftB);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(5000), 5000, 0, 0]), ExpoGachaPool.Kind.Collection, 10);
    }

    function test_OrderInsideATierStillApplies() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = ExpoGachaPool.Entitlement(address(nftA), 0, type(uint256).max, ROOT, 40e6, 50e6, 1);
        items[0][1] = ExpoGachaPool.Entitlement(address(nftA), 0, type(uint256).max, ROOT, 30e6, 40e6, 1);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Collection, 10);
    }

    // ------------------------------------------------------------ opening with tiers out of value order

    /// @dev Common must be covered even when a rarer tier is cheaper: the opening reverts, so the buyer pays nothing.
    function test_CommonUncoveredRevertsWithoutPayment() public {
        uint64 id = _unsorted();
        _setFree(0); // cover = the price (100)... made smaller through a dearer Common below
        uint64 dear = _accept(
            P,
            [uint16(5000), 3000, 1500, 500],
            [uint128(90e6), 20e6, 20e6, 400e6],
            [uint128(135e6), 25e6, 25e6, 500e6]
        );
        uint256 balance = usdc.balanceOf(BUYER);
        ov.prank(BUYER);
        ov.expectRevert(ExpoGachaPool.NothingDrawable.selector);
        pool.open(dear, 0);
        require(usdc.balanceOf(BUYER) == balance, "no payment on a refused opening");
        (,uint16[4] memory drawable,, uint128 reservation) = _preview(dear);
        require(drawable[0] == 0 && reservation == 0, "the preview says the same");
        id; // the cheaper machine stays openable
        _openWith(id, 0);
    }

    function _preview(uint64 id) internal view returns (uint256 cover, uint16[4] memory d, uint16[4] memory o, uint128 r) {
        return pool.previewOpen(id);
    }

    /// @dev Every drawn prize fits its reservation and the cover, whatever the tier order, reserve and word.
    function testFuzz_DrawnPrizeAlwaysFitsItsReservation(uint256 free, uint256 word) public {
        uint64 id = _unsorted();
        _setFree(free % 1000e6);
        uint256 o = _openWith(id, 0);
        (,,,, uint96 reservation, uint96 cover) = _full(o);
        require(reservation <= cover, "reservation within the cover");
        uint256 reservedBefore = pool.reserved();
        _drawWith(o, word);
        (,,, uint96 liability,) = _op(o);
        require(liability <= reservation, "the prize fits what open reserved");
        require(pool.reserved() == reservedBefore - reservation + liability, "the difference is released");
        require(usdc.balanceOf(address(pool)) >= pool.reserved(), "solvent");
    }

    function _full(uint256 o)
        internal
        view
        returns (ExpoGachaPool.State s, uint8 t, uint16 i, uint64 d, uint96 reservation, uint96 cover)
    {
        (,, s, t, i, d, reservation, cover,,) = pool.openings(o);
    }

    /// @dev Uncommon (50) is dearer than the cover allows only when Rare (55)... the locked tier in the middle: its
    /// odds go to the tier below, a cheaper rarer tier stays open and keeps its own odds.
    function test_LockedMiddleTierKeepsACheaperRarerTierOpen() public {
        uint64 id = _accept(
            P,
            [uint16(5000), 3000, 1500, 500],
            [uint128(48e6), 96e6, 44e6, 60e6],
            [uint128(60e6), 120e6, 55e6, 75e6]
        );
        // The price (100) is the cover: Common 60, Rare 55 and Epic 75 are covered, Uncommon 120 is locked.
        _setFree(0);
        (uint256 cover, uint16[4] memory drawable, uint16[4] memory odds, uint128 reservation) = pool.previewOpen(id);
        require(cover == P, "cover is the price");
        require(drawable[0] == 1 && drawable[1] == 0 && drawable[2] == 1 && drawable[3] == 1, "only Uncommon locked");
        require(odds[0] == 8000 && odds[1] == 0 && odds[2] == 1500 && odds[3] == 500, "its odds move down one tier");
        require(reservation == P, "max(largest covered, net price)");
        uint256 o = _openWith(id, 0);
        _drawWith(o, 5000 + 2999); // the former Uncommon roll now lands in Common
        (, uint8 tier,, uint96 liability,) = _op(o);
        require(tier == 0 && liability == 60e6, "drawn in Common");
    }

    /// @dev Locking the jackpot cannot raise what the machine pays on average beyond the ceiling of 100% for a sane
    /// budget: a locked prize is dearer than every drawable one.
    function testFuzz_LockedSnapshotNeverPaysAboveThePriceAtBudget125(uint256 free) public {
        uint64 id = _unsorted();
        _setFree(free % 1000e6);
        (, uint16[4] memory d, uint16[4] memory odds,) = pool.previewOpen(id);
        if (d[0] == 0) return;
        uint256 ev;
        for (uint8 t; t < 4; ++t) {
            if (d[t] > 0) ev += uint256(odds[t]) * pool.entitlement(id, t, 0).referenceUsdc;
        }
        require(ev / 10000 <= P, "expected payout within the price");
    }

    // ------------------------------------------------------------ full lifecycle

    function test_QuickSellAndCompensatePayTheDrawnTier() public {
        uint64 id = _unsorted();
        _setFree(1000e6);
        uint256 o = _openWith(id, 0);
        _drawWith(o, 5000); // Uncommon, the cheapest tier here
        (, uint8 tier,,,) = _op(o);
        require(tier == 1, "Uncommon");
        uint256 before = usdc.balanceOf(BUYER);
        ov.prank(BUYER);
        pool.quickSell(o);
        require(usdc.balanceOf(BUYER) - before == 40e6 * 9000 / 10000, "Quick Sell at the tier's reference");
        require(pool.reserved() == 0, "nothing stays reserved");
    }
}
