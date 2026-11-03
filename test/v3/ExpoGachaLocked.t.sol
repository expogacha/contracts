// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoGachaPool} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoLaunchpad} from "../../src/v3/ExpoLaunchpad.sol";
import {MockNFT} from "../../src/MockAssets.sol";
import {OddsBase} from "./OddsTestBase.sol";

/// @dev Locked prizes, the opening snapshot and stale refunds (docs/46 sections 5 and 11). Written before the v3.2
/// implementation. The reference machine (OddsTestBase) has P = 100, so an opening's cover is the free reserve
/// before it plus 100 (no creator fee).
contract ExpoGachaLockedTest is OddsBase {
    address constant OTHER = address(0x0B2);

    function _eq(uint16[4] memory a, uint16[4] memory b) internal pure returns (bool) {
        return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
    }

    function _wallet(address who) internal {
        usdc.mint(who, 100_000e6);
        ov.prank(who);
        usdc.approve(address(pool), type(uint256).max);
    }

    // ------------------------------------------------------------ locks and cascades

    function test_LockedItemNeverDrawn(uint256 free, uint256 word) public {
        uint64 id = _machine();
        _setFree(free % 600e6); // cover < 700: the 3,125 Epic is always locked, other prizes depending on `free`
        uint256 o = _openWith(id, 0);
        (uint128 cover, uint16[4] memory drawable, uint16[4] memory odds) = pool.openingSnapshot(o);
        require(_sum(odds) == 10000, "snapshot odds sum to 10,000");
        _drawWith(o, word);
        (, uint8 tier, uint16 index, uint96 liability,) = _op(o);
        require(liability <= cover && index < drawable[tier], "drawn inside the covered prefix");
        require(!(tier == 3 && index == 1), "the uncovered jackpot is never drawn");
    }

    function test_LockedTierCascadesDown() public {
        uint64 id = _machine();
        _setFree(300e6); // cover 400: both Epics locked, Rare (300, 387.5) covered
        (uint256 cover, uint16[4] memory drawable, uint16[4] memory odds, uint128 reservation) = pool.previewOpen(id);
        require(cover == 400e6 && _eq(drawable, [uint16(4), 2, 2, 0]), "Epic locked");
        require(_eq(odds, [uint16(7500), 2000, 500, 0]) && reservation == 387.5e6, "Epic odds move to Rare");
        uint256 o = _openWith(id, 0);
        (, uint16[4] memory d2, uint16[4] memory o2) = pool.openingSnapshot(o);
        require(_eq(d2, drawable) && _eq(o2, odds) && pool.reserved() == 387.5e6, "open takes the previewed snapshot");
        _drawWith(o, 9999); // the Epic roll now lands in Rare
        (, uint8 tier,,,) = _op(o);
        require(tier == 2, "Epic roll lands in Rare");
    }

    function test_MultipleLockedTiersCascade() public {
        uint64 id = _machine();
        _setFree(100e6); // cover 200: Rare and Epic locked
        (, uint16[4] memory drawable, uint16[4] memory odds, uint128 reservation) = pool.previewOpen(id);
        require(_eq(drawable, [uint16(4), 2, 0, 0]) && _eq(odds, [uint16(7500), 2500, 0, 0]), "two tiers cascade");
        require(reservation == 168.75e6, "largest drawable liability");
        _setFree(20e6); // cover 120: only Commons
        (, drawable, odds, reservation) = pool.previewOpen(id);
        require(_eq(drawable, [uint16(4), 0, 0, 0]) && _eq(odds, [uint16(10000), 0, 0, 0]), "everything to Common");
        require(reservation == 100e6, "the reservation also covers a refund of the price (max(L, N))");
    }

    /// @dev Liabilities may overlap across tiers (budget up to 1.5 x reference): an Uncommon can be locked while a
    /// Rare is drawable. Each locked tier passes its odds to the next tier down, and L is the largest covered liability
    /// over all tiers.
    function test_NonAdjacentLocksCascadeDownward() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = _e(address(nftA), 60e6, 60e6, 1);
        items[1] = new ExpoGachaPool.Entitlement[](1);
        items[1][0] = _e(address(nftB), 190e6, 285e6, 1); // liability 285
        items[2] = new ExpoGachaPool.Entitlement[](1);
        items[2][0] = _e(address(nftC), 200e6, 200e6, 1); // liability 200
        items[3] = new ExpoGachaPool.Entitlement[](1);
        items[3][0] = _e(address(nftD), 400e6, 400e6, 1);
        uint64 id = pool.createConfig(_input(items, P, _defaultOdds()), ExpoGachaPool.Kind.Etf, 10);
        _setFree(150e6); // cover 250
        uint256 o = _openWith(id, 0);
        (uint128 cover, uint16[4] memory drawable, uint16[4] memory odds) = pool.openingSnapshot(o);
        require(cover == 250e6 && _eq(drawable, [uint16(1), 0, 1, 0]), "Uncommon and Epic locked, Rare drawable");
        require(_eq(odds, [uint16(9500), 0, 500, 0]), "Epic to Rare, Uncommon to Common");
        require(pool.reserved() == 200e6, "L is the Rare's 200, not the locked Uncommon's 285");
    }

    /// @dev A partly locked tier draws over its covered prefix only, through finalize and for many words: half the
    /// words would land on the locked item if the whole tier were drawn.
    function test_PartiallyLockedTierDrawsOnlyThePrefix() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = _e(address(nftA), 60e6, 60e6, 1);
        items[0][1] = _e(address(nftB), 90e6, 135e6, 1); // liability 135 > cover 100
        uint64 id = pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 100);
        _setFree(0);
        for (uint256 i; i < 16; ++i) {
            uint256 o = _openWith(id, 0);
            (uint128 cover, uint16[4] memory drawable,) = pool.openingSnapshot(o);
            require(cover == 100e6 && drawable[0] == 1, "one of two Commons drawable");
            _drawWith(o, uint256(keccak256(abi.encode("partial", i))));
            (, uint8 tier, uint16 index,,) = _op(o);
            require(tier == 0 && index == 0, "never the locked Common");
            ov.prank(BUYER);
            pool.quickSell(o); // settle so the next opening sees the same free reserve
            _setFree(0);
        }
        uint64 m = _machine();
        for (uint256 i; i < 64; ++i) {
            // cover 350: Rare 300 drawable, Rare 387.5 locked, both Epics locked; a Rare roll.
            (uint8 tier, uint32 index) =
                pool.previewDraw(m, 350e6, i + 1, uint256(keccak256(abi.encode(i))) / 10000 * 10000 + 9600);
            require(tier == 2 && index == 0, "Rare prefix only");
        }
    }

    function test_CommonLockedRevertsNothingDrawable() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = _e(address(nftA), 90e6, 130e6, 1); // liability 130 > cover 100
        uint64 id = pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        _setFree(0);
        uint256 balance = usdc.balanceOf(BUYER);
        ov.prank(BUYER);
        ov.expectRevert(ExpoGachaPool.NothingDrawable.selector);
        pool.open(id, 0);
        require(usdc.balanceOf(BUYER) == balance && pool.openingCount() == 0, "no payment taken");
        _setFree(30e6);
        _openWith(id, 0); // cover 130: the Common unlocks
        require(pool.reserved() == 130e6, "reserved its liability");
    }

    // ------------------------------------------------------------ snapshot immutability (I-M1)

    function test_SnapshotFixedAgainstWithdraw() public {
        uint64 id = _machine();
        _setFree(3025e6);
        uint256 o = _openWith(id, 0);
        (uint128 cover, uint16[4] memory drawable, uint16[4] memory odds) = pool.openingSnapshot(o);
        require(cover == 3125e6 && _eq(drawable, [uint16(4), 2, 2, 2]) && pool.reserved() == 3125e6, "all drawable");
        pool.withdraw(address(this), pool.freeReserve()); // the owner empties the free reserve
        (uint128 c2, uint16[4] memory d2, uint16[4] memory o2) = pool.openingSnapshot(o);
        require(c2 == cover && _eq(d2, drawable) && _eq(o2, odds), "snapshot unchanged");
        _drawWith(o, 9999);
        (ExpoGachaPool.State s, uint8 tier,,,) = _op(o);
        require(s == ExpoGachaPool.State.Revealed && tier == 3, "finalize never reverts for lack of funds");
    }

    function test_SnapshotFixedAgainstReserveDrop() public {
        uint64 id = _machine();
        _wallet(OTHER);
        _setFree(3025e6);
        uint256 o = _openWith(id, 0);
        ov.prank(OTHER);
        uint256 o2 = pool.open(id, 0); // a second opening reserves against the remaining free reserve
        (uint128 cover,, uint16[4] memory odds) = pool.openingSnapshot(o);
        require(cover == 3125e6 && _eq(odds, _defaultOdds()), "first snapshot unchanged");
        (uint128 cover2,, uint16[4] memory odds2) = pool.openingSnapshot(o2);
        require(cover2 == 100e6 && _eq(odds2, [uint16(10000), 0, 0, 0]), "second sees the lower reserve");
    }

    /// @dev A later top-up does not unlock prizes for a pending opening.
    function test_SnapshotFixedAgainstFund() public {
        uint64 id = _machine();
        _setFree(0);
        uint256 o = _openWith(id, 0);
        pool.fund(100_000e6);
        (uint128 cover, uint16[4] memory drawable, uint16[4] memory odds) = pool.openingSnapshot(o);
        require(cover == 100e6 && _eq(drawable, [uint16(4), 0, 0, 0]), "still Commons only");
        require(_eq(odds, [uint16(10000), 0, 0, 0]), "odds unchanged");
        _drawWith(o, 9999); // an Epic roll
        (, uint8 tier,,,) = _op(o);
        require(tier == 0, "drawn from the snapshot, not the topped-up reserve");
    }

    // ------------------------------------------------------------ buyer guard and concurrency

    /// @dev Front-run by an owner withdrawal: the buyer's minCover makes the open revert and no price is taken.
    function test_MinCoverReverts() public {
        uint64 id = _machine();
        _setFree(3025e6);
        (uint256 cover,,,) = pool.previewOpen(id);
        require(cover == 3125e6, "previewed cover");
        pool.withdraw(address(this), 100e6); // lands first
        uint256 balance = usdc.balanceOf(BUYER);
        ov.prank(BUYER);
        ov.expectRevert(abi.encodeWithSelector(ExpoGachaPool.CoverTooLow.selector, uint256(3025e6)));
        pool.open(id, cover);
        require(usdc.balanceOf(BUYER) == balance && pool.openingCount() == 0, "price not taken");
        _openWith(id, 3025e6); // a buyer who accepts the new snapshot
        _openWith(id, 0); // minCover = 0 accepts any snapshot
    }

    function test_ConcurrentOpensReserveSequentially() public {
        uint64 id = _machine();
        _wallet(OTHER);
        _setFree(3025e6);
        uint256 a = _openWith(id, 0);
        ov.prank(OTHER);
        uint256 b = pool.open(id, 0); // same block
        (uint96 la, uint96 ca) = _lc(a);
        (uint96 lb, uint96 cb) = _lc(b);
        require(ca == 3125e6 && la == 3125e6, "first reserves the jackpot");
        require(cb == ca - la + 100e6 && lb == 100e6, "second cover is lower by the first reservation");
        require(pool.reserved() == la + lb && pool.freeReserve() == 0, "both reserved, solvent");
    }

    function _lc(uint256 o) internal view returns (uint96 liability, uint96 cover) {
        (,,, liability, cover) = _op(o);
    }

    function test_LaunchpadCoverUsesCap() public {
        ExpoGachaPool.Entitlement[][4] memory items = _machineItems();
        ExpoLaunchpad.Quote memory q = _quote(items, 0, 10);
        q.priceUsdc = P;
        q.odds = _defaultOdds();
        bytes memory sig = _sign(q, SIGNER_KEY);
        ov.prank(CREATOR);
        uint64 id = launchpad.launch(q, items, sig);
        _setFree(1900e6); // assets after the open: 2,000; 25% cap: 500
        uint256 o = _openWith(id, 0);
        (uint128 cover, uint16[4] memory drawable, uint16[4] memory odds) = pool.openingSnapshot(o);
        require(cover == 500e6 && _eq(drawable, [uint16(4), 2, 2, 0]), "cover is the launchpad cap room");
        require(_eq(odds, [uint16(7500), 2000, 500, 0]), "Epic locked by the cap");
        require(pool.launchpadReserved() == 387.5e6 && pool.reserved() == 387.5e6, "launchpad share");
    }

    // ------------------------------------------------------------ preview

    function test_PreviewOpenEqualsOpenSnapshot(uint256 free) public {
        uint64 id = _machine();
        _setFree(free % 4000e6);
        (uint256 cover, uint16[4] memory drawable, uint16[4] memory odds, uint128 reservation) = pool.previewOpen(id);
        uint256 reserved = pool.reserved();
        uint256 o = _openWith(id, 0);
        (uint128 c2, uint16[4] memory d2, uint16[4] memory o2) = pool.openingSnapshot(o);
        require(c2 == cover && _eq(d2, drawable) && _eq(o2, odds), "same snapshot");
        require(pool.reserved() - reserved == reservation, "same reservation");
        (,,, uint96 l,) = _op(o);
        require(l == reservation, "opening liability");
    }

    // ------------------------------------------------------------ stale refunds (docs/40 M-2 option A)

    function test_RefundStaleAfterTimeout() public {
        uint64 id = _machine();
        _setFree(3025e6);
        uint256 o = _openWith(id, 0);
        uint256 balance = usdc.balanceOf(BUYER);
        ov.warp(block.timestamp + pool.VRF_TIMEOUT());
        ov.prank(OTHER); // permissionless
        pool.refundStale(o);
        (ExpoGachaPool.State s,,, uint96 liability,) = _op(o);
        require(s == ExpoGachaPool.State.Refunded && liability == 0, "terminal, no liability");
        require(usdc.balanceOf(BUYER) - balance == P, "full price refunded to the buyer");
        require(pool.reserved() == 0 && _openNow(id) == 0, "reservation and slot released");
        ov.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.refundStale(o); // not twice
    }

    function test_RefundStaleNotBefore() public {
        uint64 id = _machine();
        uint256 o = _openWith(id, 0);
        ov.warp(block.timestamp + pool.VRF_TIMEOUT() - 1);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.refundStale(o);
        rng.fulfill(rng.count(), 5);
        ov.warp(block.timestamp + 1 days);
        ov.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.refundStale(o); // RandomReady: the word is known, no refund
    }

    function test_LateWordIgnoredAfterRefund() public {
        uint64 id = _machine();
        uint256 o = _openWith(id, 0);
        ov.warp(block.timestamp + pool.VRF_TIMEOUT());
        pool.refundStale(o);
        rng.fulfill(rng.count(), 42);
        (,,,,,,,, uint256 word,) = pool.openings(o);
        (ExpoGachaPool.State s,,,,) = _op(o);
        require(s == ExpoGachaPool.State.Refunded && word == 0, "late word ignored");
        ov.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.finalize(o);
    }

    /// @dev A refund pays the price even when the drawable prizes are worth less than the price and the owner has
    /// withdrawn everything free: the reservation is max(L, net price).
    function test_RefundCoveredWhenPrizesBelowPrice() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = _e(address(nftA), 52e6, 52e6, 1);
        uint64 id = pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        uint256 o = _openWith(id, 0);
        require(pool.reserved() == P, "reserved the refundable price, not only the 52 prize");
        pool.withdraw(address(this), pool.freeReserve());
        ov.warp(block.timestamp + pool.VRF_TIMEOUT());
        uint256 balance = usdc.balanceOf(BUYER);
        pool.refundStale(o);
        require(usdc.balanceOf(BUYER) - balance == P, "refunded");
        require(usdc.balanceOf(address(pool)) >= pool.reserved() + pool.creatorFeesOwed(), "I-S1");
    }

    function _launchWithFee(uint16 fee) internal returns (uint64 id) {
        ExpoGachaPool.Entitlement[][4] memory items = _machineItems();
        ExpoLaunchpad.Quote memory q = _quote(items, fee, 10);
        q.priceUsdc = P;
        q.odds = _defaultOdds();
        bytes memory sig = _sign(q, SIGNER_KEY);
        ov.prank(CREATOR);
        id = launchpad.launch(q, items, sig);
    }

    function test_RefundStaleReversesCreatorFee() public {
        uint64 id = _launchWithFee(300);
        uint256 o = _openWith(id, 0);
        require(pool.creatorBalance(CREATOR) == 3e6 && pool.creatorFeesOwed() == 3e6, "fee booked");
        ov.warp(block.timestamp + pool.VRF_TIMEOUT());
        uint256 balance = usdc.balanceOf(BUYER);
        pool.refundStale(o);
        require(usdc.balanceOf(BUYER) - balance == P, "full price");
        require(pool.creatorBalance(CREATOR) == 0 && pool.creatorFeesOwed() == 0, "fee reversed");
        require(pool.reserved() == 0 && pool.launchpadReserved() == 0, "released");
    }

    function test_RefundStaleAfterCreatorWithdrewFee() public {
        uint64 id = _launchWithFee(300);
        uint256 o = _openWith(id, 0);
        ov.prank(CREATOR);
        pool.withdrawCreatorFees();
        ov.warp(block.timestamp + pool.VRF_TIMEOUT());
        uint256 balance = usdc.balanceOf(BUYER);
        uint256 free = pool.freeReserve();
        (,,, uint96 reservation,) = _op(o);
        pool.refundStale(o);
        require(usdc.balanceOf(BUYER) - balance == P, "the reserve absorbs the withdrawn fee");
        require(pool.freeReserve() == free + reservation - P, "paid from the reservation and free reserve");
        require(pool.creatorFeesOwed() == 0 && pool.creatorBalance(CREATOR) == 0, "fees reconcile");
    }

    // ------------------------------------------------------------ several collections across tiers

    /// @dev Four collections spread across the tiers, some prizes locked by a low cover: every draw stays in the
    /// snapshot, and delivery, Quick Sell and both compensation routes settle the awarded collection.
    function test_MultiCollectionDrawFulfillCompensate() public {
        uint64 id = _machine();
        uint256[12] memory words = [uint256(0), 7400, 7600, 9450, 9600, 9950, 1, 7520, 9480, 9700, 9999, 3];
        uint256[12] memory frees =
            [uint256(100e6), 100e6, 100e6, 100e6, 100e6, 100e6, 3025e6, 3025e6, 3025e6, 3025e6, 3025e6, 0];
        address[4] memory cols = [address(nftA), address(nftB), address(nftC), address(nftD)];
        uint256[4] memory seen;
        uint256 token = 1;
        for (uint256 i; i < 12; ++i) {
            _setFree(frees[i]);
            uint256 o = _openWith(id, 0);
            (uint128 cover, uint16[4] memory drawable,) = pool.openingSnapshot(o);
            _drawWith(o, uint256(keccak256(abi.encode(i))) / 10000 * 10000 + words[i]);
            (, uint8 tier, uint16 index, uint96 liability,) = _op(o);
            require(index < drawable[tier] && liability <= cover, "inside the snapshot");
            ExpoGachaPool.Entitlement memory e = pool.awarded(o);
            for (uint256 k; k < 4; ++k) {
                if (e.collection == cols[k]) seen[k]++;
            }
            uint256 balance = usdc.balanceOf(BUYER);
            if (i % 3 == 0) {
                ov.prank(BUYER);
                pool.quickSell(o);
                require(usdc.balanceOf(BUYER) - balance == uint256(e.referenceUsdc) * 9000 / 10000, "Quick Sell");
            } else if (i % 3 == 1) {
                ov.prank(BUYER);
                pool.claimNFT(o);
                MockNFT(e.collection).mint(address(vault), token);
                uint256 op = usdc.balanceOf(OPERATOR);
                ov.prank(OPERATOR);
                pool.fulfill(o, token, new bytes32[](0));
                require(MockNFT(e.collection).ownerOf(token) == BUYER, "delivered from its own collection");
                require(usdc.balanceOf(OPERATOR) - op == e.budgetUsdc, "operator reimbursed the budget");
                token++;
            } else {
                bool claim = i % 2 == 0;
                if (claim) {
                    ov.prank(BUYER);
                    pool.claimNFT(o);
                }
                (,,,,, uint64 deadline,,,,) = pool.openings(o);
                ov.warp(deadline);
                pool.compensate(o);
                uint256 expected = claim ? e.referenceUsdc : uint256(e.referenceUsdc) * 9000 / 10000;
                require(usdc.balanceOf(BUYER) - balance == expected, "compensation by route");
                _admit(address(nftA));
                _admit(address(nftB));
                _admit(address(nftC));
                _admit(address(nftD));
            }
        }
        require(seen[0] > 0 && seen[1] > 0 && seen[2] > 0 && seen[3] > 0, "every collection awarded at least once");
        require(pool.reserved() == 0, "all settled");
        require(pool.pendingClaims(address(nftA)) + pool.pendingClaims(address(nftC)) == 0, "no waiting claims");
    }

    // ------------------------------------------------------------ reservation lifecycle (docs/46 5.3-5.5, docs/41)

    function _solvent() internal view {
        require(usdc.balanceOf(address(pool)) >= pool.reserved() + pool.creatorFeesOwed(), "I-S1");
    }

    /// @dev open reserves max(L, N) (L = largest drawable liability); finalize releases everything above the awarded
    /// liability (v3.1 behaviour kept); the settlement (Quick Sell, delivery, compensation) releases the rest.
    function test_ReservationLifecycle() public {
        uint64 id = _machine();
        _setFree(3025e6);
        uint256 free0 = pool.freeReserve();
        uint256 o = _openWith(id, 0);
        _solvent();
        require(pool.reserved() == 3125e6, "open: reserved += L (the 3,125 jackpot is drawable)");
        require(pool.freeReserve() == free0 + P - 3125e6, "free reserve: + price - L");
        _drawWith(o, 0); // a Common roll
        _solvent();
        (, uint8 tier, uint16 index, uint96 liability,) = _op(o);
        require(tier == 0 && liability == _liab(id, 0, index), "awarded liability");
        require(pool.reserved() == liability, "finalize: L - awarded released, awarded stays reserved");
        require(pool.freeReserve() == free0 + P - liability, "the surplus is free again at reveal");
        ExpoGachaPool.Entitlement memory e = pool.awarded(o);
        uint256 before = usdc.balanceOf(address(pool));
        ov.prank(BUYER);
        pool.quickSell(o);
        _solvent();
        require(pool.reserved() == 0, "settlement releases the rest");
        require(before - usdc.balanceOf(address(pool)) == uint256(e.referenceUsdc) * 9000 / 10000, "paid Quick Sell");
        // Same lifecycle with a pending second opening: each keeps its own reservation.
        _setFree(3025e6);
        uint256 a = _openWith(id, 0);
        uint256 b = _openWith(id, 0);
        _solvent();
        (,,, uint96 la,) = _op(a);
        (,,, uint96 lb,) = _op(b);
        require(pool.reserved() == uint256(la) + lb, "two reservations");
        rng.fulfill(a, 9999);
        pool.finalize(a);
        _solvent();
        (,,, uint96 aw,) = _op(a);
        require(pool.reserved() == uint256(aw) + lb, "only a's surplus released");
        ov.prank(BUYER);
        pool.claimNFT(a);
        (,,,,, uint64 deadline,,,,) = pool.openings(a);
        ov.warp(deadline);
        pool.compensate(a);
        _solvent();
        require(pool.reserved() == lb, "compensation releases a's awarded liability");
    }
}
