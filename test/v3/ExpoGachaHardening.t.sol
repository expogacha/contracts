// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoGachaPool} from "../../src/v3/ExpoGachaPool.sol";
import {AdvBase} from "./ExpoGachaAdversarial.t.sol";

/// @dev Adversarial tests of the v3.1 changes (docs/41-v3-pool-hardening.md): compensation rate, capacity freed at
/// reveal and the disable-only guardian. Written before the implementation; they fail on v3.0.
abstract contract HardeningBase is AdvBase {
    address constant GUARDIAN = address(0x6A2D);
    address constant ATTACKER = address(0xA77);

    function _cfg(uint64 id) internal view returns (uint32 maxOpen, uint32 openNow, bool enabled) {
        (,,,,,,,, maxOpen, openNow,, enabled) = pool.configs(id);
    }

    function _enabled(uint64 id) internal view returns (bool on) {
        (,, on) = _cfg(id);
    }

    /// @dev Reveals opening `id` through its own VRF request (request IDs follow opening IDs in these fixtures).
    function _revealOwn(uint256 id) internal {
        rng.fulfill(id, uint256(keccak256(abi.encode(id))));
        pool.finalize(id);
    }

    function _fundWallet(address who) internal {
        usdc.mint(who, 10_000e6);
        hv.prank(who);
        usdc.approve(address(pool), type(uint256).max);
    }
}

// ==================================================================== 1. compensation rate

contract ExpoGachaCompensationRateTest is HardeningBase {
    function test_UnclaimedCompensationEqualsQuickSell() public {
        uint64 id = _etf(10);
        uint256 sold = _revealed(id);
        uint256 waited = _revealed(id);
        uint256 before = usdc.balanceOf(BUYER);
        hv.prank(BUYER);
        pool.quickSell(sold);
        uint256 quick = usdc.balanceOf(BUYER) - before;
        hv.warp(_deadline(waited));
        before = usdc.balanceOf(BUYER);
        hv.prank(address(0xDEAD)); // still permissionless
        pool.compensate(waited);
        uint256 compensation = usdc.balanceOf(BUYER) - before;
        require(quick == 36e6 && compensation == quick, "waiting pays exactly the Quick Sell amount");
        require(_state(waited) == ExpoGachaPool.State.Compensated && pool.reserved() == 0, "reservation released");
    }

    function test_ClaimedCompensationPaysFullReference() public {
        uint64 id = _etf(10);
        uint256 unclaimed = _revealed(id);
        uint256 claimed = _claimed(id);
        hv.warp(_deadline(claimed));
        uint256 buyer = usdc.balanceOf(BUYER);
        uint256 operator = usdc.balanceOf(OPERATOR);
        pool.compensate(claimed);
        require(usdc.balanceOf(BUYER) - buyer == 40e6, "Expo failed to deliver: full reference");
        require(usdc.balanceOf(OPERATOR) == operator, "operator not reimbursed");
        buyer = usdc.balanceOf(BUYER);
        pool.compensate(unclaimed);
        require(usdc.balanceOf(BUYER) - buyer == 36e6, "never claimed: Quick Sell rate");
        require(pool.reserved() == 0, "both reservations released");
    }

    function test_ZeroQuickSellUnclaimedCompensatesZero() public {
        ExpoGachaPool.ConfigInput memory input = _input(_items(address(nftA), bytes32(0)));
        input.quickSellBps = 0;
        uint64 id = pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        uint256 o = _revealed(id);
        hv.warp(_deadline(o));
        uint256 before = usdc.balanceOf(BUYER);
        uint256 free = pool.freeReserve();
        pool.compensate(o);
        require(usdc.balanceOf(BUYER) == before, "zero payout");
        require(_state(o) == ExpoGachaPool.State.Compensated && pool.reserved() == 0, "still settles");
        require(pool.freeReserve() == free + 50e6, "the whole reservation returns to free reserve");
    }

    function test_CompensationRoundsLikeQuickSell() public {
        ExpoGachaPool.Entitlement[][4] memory items = _one(address(nftA), 0, 10, bytes32(0), 33, 40);
        ExpoGachaPool.ConfigInput memory input = _input(items);
        input.priceUsdc = 66; // band: 33 is a Common at 66
        input.quickSellBps = 3333; // 33 × 3333 / 10000 = 10.9989 → 10
        uint64 id = pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        uint256 o = _revealed(id);
        hv.warp(_deadline(o));
        uint256 before = usdc.balanceOf(BUYER);
        pool.compensate(o);
        require(usdc.balanceOf(BUYER) - before == 10, "integer division, like quickSell");
    }
}

// ==================================================================== 2. capacity freed at reveal (M-A)

contract ExpoGachaCapacityTest is HardeningBase {
    /// @dev Regression for finding M-A (PoC "slot capture locks the configuration for the whole window"): an
    /// attacker fills every slot, reveals and walks away. Before docs/41 the configuration stayed full for the whole
    /// settlement window; now other buyers open at once, and the attacker's liabilities stay reserved.
    function test_Regression_MA_SlotCaptureNoLongerLocksConfig() public {
        _fundWallet(ATTACKER);
        uint64 id = _etf(2);
        uint256[2] memory captured;
        for (uint256 i; i < 2; ++i) {
            hv.prank(ATTACKER);
            captured[i] = pool.open(id, 0);
        }
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.CapReached.selector);
        pool.open(id, 0); // full while the draws are pending
        _revealOwn(captured[0]);
        _revealOwn(captured[1]);
        (, uint32 openNow,) = _cfg(id);
        require(openNow == 0 && pool.reserved() == 100e6, "slots free, both liabilities still reserved");
        uint256 a = _open(id);
        uint256 b = _open(id);
        require(pool.reserved() == 200e6, "two new openings next to the two revealed ones");
        hv.prank(BUYER);
        hv.expectRevert(ExpoGachaPool.CapReached.selector);
        pool.open(id, 0); // the cap still holds for undrawn openings
        _revealOwn(a);
        _revealOwn(b);
        hv.warp(_deadline(captured[1]));
        uint256 before = usdc.balanceOf(ATTACKER);
        pool.compensate(captured[0]);
        pool.compensate(captured[1]);
        require(usdc.balanceOf(ATTACKER) - before == 72e6, "walking away pays the Quick Sell rate");
        require(pool.reserved() == 100e6, "only the two new, still unsettled openings remain reserved");
    }

    function test_OpenNowCountsOnlyUndrawnOpenings() public {
        uint64 id = _etf(3);
        uint256 o = _open(id);
        (, uint32 n,) = _cfg(id);
        require(n == 1, "pending counts");
        rng.fulfill(rng.count(), 5);
        (, n,) = _cfg(id);
        require(n == 1 && _state(o) == ExpoGachaPool.State.RandomReady, "random ready counts");
        pool.finalize(o);
        (, n,) = _cfg(id);
        require(n == 0 && pool.reserved() == 50e6, "revealed does not count; liability reserved");
        hv.prank(BUYER);
        pool.claimNFT(o);
        nftA.mint(address(vault), 3);
        hv.prank(OPERATOR);
        pool.fulfill(o, 3, new bytes32[](0));
        (, n,) = _cfg(id);
        require(n == 0 && pool.reserved() == 0, "settlement leaves the count, releases the liability");
    }

    function test_RevealedLiabilityStillBlocksWithdrawal() public {
        _raiseCap(10_000_000e6);
        uint64 id = _etf(1);
        uint256 o = _revealed(id);
        uint256 balance = usdc.balanceOf(address(pool));
        require(pool.freeReserve() == balance - 50e6, "revealed liability is not free");
        hv.expectRevert(ExpoGachaPool.Insolvent.selector);
        pool.withdraw(address(this), balance - 50e6 + 1);
        pool.withdraw(address(this), balance - 50e6);
        hv.prank(BUYER);
        pool.quickSell(o);
        require(usdc.balanceOf(address(pool)) == 50e6 - 36e6, "settled from the reservation");
    }

    function test_RevealedLaunchStillCountsAgainstLaunchpadCap() public {
        uint64 lp = _launch(0, 1);
        pool.setLaunchpadCapBps(1); // ~100 USDC of ~1,000,125 USDC of assets
        uint256 first = _open(lp);
        _reveal(first);
        require(pool.launchpadReserved() == 50e6, "revealed launch liability stays in the launchpad share");
        uint256 second = _open(lp); // the slot is free again
        _reveal(second);
        require(pool.launchpadReserved() == 100e6, "both revealed");
        hv.prank(BUYER);
        // The launchpad cap, not maxOpen, refuses it: the cap room is the cover (docs/46 5.3), and no Common prize
        // fits in it.
        hv.expectRevert(ExpoGachaPool.NothingDrawable.selector);
        pool.open(lp, 0);
        hv.prank(BUYER);
        pool.quickSell(first);
        require(pool.launchpadReserved() == 50e6, "released at settlement");
        _open(lp);
    }
}

// ==================================================================== launchpad quote (docs/41)

contract ExpoLaunchpadQuoteTypeTest is HardeningBase {
    /// @dev v3.1 keeps the v3.0 quote type (per-gacha expiry was rejected, docs/41), so one Go signer serves both pools.
    function test_QuoteTypehashUnchangedFromV30() public view {
        require(
            launchpad.QUOTE_TYPEHASH()
                == keccak256(
                    "Quote(address creator,bytes32 gachaId,uint128 priceUsdc,uint16[4] odds,bytes32 entitlementsHash,uint16 quickSellBps,uint32 settlementWindow,uint16 creatorFeeBps,uint32 maxOpen,bytes32 metadataHash,uint256 nonce,uint64 expiresAt)"
                ),
            "typehash"
        );
    }
}

// ==================================================================== 3. guardian

contract ExpoGachaGuardianTest is HardeningBase {
    function setUp() public override {
        super.setUp();
        hv.expectEmit(address(pool));
        emit ExpoGachaPool.GuardianSet(GUARDIAN);
        pool.setGuardian(GUARDIAN);
    }

    function _collection() internal returns (uint64) {
        return pool.createConfig(_input(_items(address(nftA), bytes32(uint256(1)))), ExpoGachaPool.Kind.Collection, 10);
    }

    function test_GuardianDisablesAnyConfiguration() public {
        require(pool.guardian() == GUARDIAN, "guardian set");
        uint64[3] memory ids = [_etf(10), _collection(), _launch(100, 10)];
        for (uint256 i; i < 3; ++i) {
            hv.expectEmit(address(pool));
            emit ExpoGachaPool.EnabledChanged(ids[i], false);
            hv.expectEmit(address(pool));
            emit ExpoGachaPool.GuardianDisabled(ids[i]);
            hv.prank(GUARDIAN);
            pool.guardianDisable(ids[i]);
            require(!_enabled(ids[i]), "disabled");
            hv.prank(BUYER);
            hv.expectRevert(ExpoGachaPool.Invalid.selector);
            pool.open(ids[i], 0);
        }
        hv.prank(GUARDIAN);
        pool.guardianDisable(ids[0]); // idempotent
        require(!_enabled(ids[0]), "still disabled");
    }

    function test_GuardianCannotEnableOrTouchAnythingElse() public {
        uint64 etf = _etf(10);
        uint64 lp = _launch(0, 10);
        hv.prank(GUARDIAN);
        pool.guardianDisable(etf);
        bytes memory notOwner = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", GUARDIAN);
        hv.prank(GUARDIAN);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.setEnabled(etf, true);
        hv.prank(GUARDIAN);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.setEnabled(lp, false); // not through the owner's or the creator's path
        hv.prank(GUARDIAN);
        hv.expectRevert(notOwner);
        pool.withdraw(GUARDIAN, 1);
        ExpoGachaPool.ConfigInput memory input = _input(_items(address(nftA), bytes32(0)));
        hv.prank(GUARDIAN);
        hv.expectRevert(notOwner);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        hv.prank(GUARDIAN);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.createLaunchpadConfig(input, GUARDIAN, 0, 10);
        hv.prank(GUARDIAN);
        hv.expectRevert(notOwner);
        pool.setGuardian(address(0xBAD));
        hv.prank(GUARDIAN);
        hv.expectRevert(notOwner);
        pool.setConfigurator(GUARDIAN);
        hv.prank(GUARDIAN);
        hv.expectRevert(notOwner);
        pool.setLaunchpadCapBps(0);
        hv.prank(GUARDIAN);
        hv.expectRevert(notOwner);
        pool.proposeWithdrawCap(0);
        require(!_enabled(etf) && _enabled(lp) && pool.guardian() == GUARDIAN, "only the disable took effect");
    }

    function test_GuardianDisableChangesNothingElse() public {
        uint64 lp = _launch(300, 10);
        uint256 o = _open(lp);
        uint256 balance = usdc.balanceOf(address(pool));
        uint256 reserved = pool.reserved();
        uint256 launchpadReserved = pool.launchpadReserved();
        uint256 fees = pool.creatorFeesOwed();
        (uint32 maxOpen, uint32 openNow,) = _cfg(lp);
        hv.prank(GUARDIAN);
        pool.guardianDisable(lp);
        (uint32 maxOpen2, uint32 openNow2, bool on) = _cfg(lp);
        require(!on && maxOpen2 == maxOpen && openNow2 == openNow, "only the flag changed");
        require(
            usdc.balanceOf(address(pool)) == balance && pool.reserved() == reserved
                && pool.launchpadReserved() == launchpadReserved && pool.creatorFeesOwed() == fees,
            "no money moved"
        );
        _reveal(o);
        hv.prank(BUYER);
        pool.quickSell(o); // an opening made before the disable settles
        require(_state(o) == ExpoGachaPool.State.QuickSold, "settled");
    }

    function test_OnlyTheGuardianCanGuardianDisable() public {
        uint64 id = _etf(10);
        address[3] memory others = [BUYER, CREATOR, OPERATOR];
        for (uint256 i; i < 3; ++i) {
            hv.prank(others[i]);
            hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
            pool.guardianDisable(id);
        }
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.guardianDisable(id); // the owner uses setEnabled
        hv.prank(GUARDIAN);
        hv.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.guardianDisable(999);
        hv.prank(BUYER);
        hv.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", BUYER));
        pool.setGuardian(BUYER);
        pool.setGuardian(address(0)); // role removed
        hv.prank(GUARDIAN);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.guardianDisable(id);
        hv.prank(address(0));
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.guardianDisable(id); // no guardian means nobody, not the zero address
        require(_enabled(id), "never disabled");
    }

    function test_OwnerReenablesGuardianDisabledConfiguration() public {
        uint64 id = _etf(10);
        hv.prank(GUARDIAN);
        pool.guardianDisable(id);
        pool.setEnabled(id, true); // explicit owner decision (docs/41)
        _open(id);
        hv.prank(GUARDIAN);
        pool.guardianDisable(id); // the guardian can brake again
        require(!_enabled(id), "disabled again");
    }

    function test_CreatorStillDisablesItsOwnLaunch() public {
        uint64 lp = _launch(0, 10);
        hv.prank(CREATOR);
        pool.setEnabled(lp, false);
        require(!_enabled(lp), "creator disable");
        hv.prank(CREATOR);
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.setEnabled(lp, true);
    }
}
