// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExpoGachaPool, IAdmission} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoAdmissionRegistry} from "../../src/v3/ExpoAdmissionRegistry.sol";
import {ExpoLaunchpad} from "../../src/v3/ExpoLaunchpad.sol";
import {ExpoVault} from "../../src/ExpoVault.sol";
import {deployTestVault} from "./VaultTestDeploy.sol";
import {IRandomness} from "../../src/ExpoPool.sol";
import {MockNFT, MockRandomness, MockWETH} from "../../src/MockAssets.sol";
import {AdvVm, TokenSets} from "./V3TestMocks.sol";

/// @dev Model-checking handler for the live V3 shape (docs/36): a MockWETH reserve in wei, an ETF on range
/// entitlements, an intra-collection gacha whose four tiers are frozen Merkle sets, and launchpad gachas on the same
/// sets, with three buyers.
///
/// Every action first predicts, from the specification (docs/33), whether the pool must accept it. Predicted-valid
/// calls are made directly, so an unexpected revert fails the run (`fail_on_revert = true` for this suite).
/// Predicted-invalid calls are wrapped in try/catch and raise a flag if they succeed. Payouts are recomputed from the
/// rules and compared with the actual transfer, and a ghost ledger reconciles the reserve.
///
/// v3.1 (docs/41): a guardian actor disables configurations that the owner may re-enable, `openNow` counts only
/// undrawn openings, and compensation of an unclaimed opening pays the Quick Sell rate.
///
/// v3.2 (docs/46): configurations are banded and weighted, the reserve starts small so prizes lock and unlock, buyers
/// open with a fuzzed `minCover`, the VRF may stall and anyone refunds a stale opening after `VRF_TIMEOUT`. The model
/// predicts every snapshot (cover, reservation) from the entitlements independently of the pool's search code, and
/// the invariant checks I-S1, I-S2, I-L1, I-O1, I-W1, I-B1, I-E1 and I-M1 of docs/46 section 10 on every opening and
/// configuration. `finalize` of a `RandomReady` opening is called directly, so I-S3 (never reverts) fails the run.
///
/// Known exception (docs/40 H-1, H-2): the handler never builds an owner configuration designed to extract the
/// reserve, nor an unsigned configurator. Those routes bypass the withdrawal cap today and are pinned by
/// `test_KnownIssue_H1_*` and `test_KnownIssue_H2_*` instead.
contract WethGachaHandler {
    AdvVm constant hv = AdvVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant SIGNER_KEY = 0x5158;
    uint256 constant MAX_OPENINGS = 120;
    address public constant GUARDIAN = address(0x6A2D);

    MockWETH public weth;
    MockNFT public nftA;
    MockNFT public nftC;
    MockRandomness public rng;
    ExpoVault public vault;
    ExpoAdmissionRegistry public registry;
    ExpoGachaPool public pool;
    ExpoLaunchpad public launchpad;
    address[3] public buyers = [address(0xB001), address(0xB002), address(0xB003)];

    uint256[4][4] internal sets;
    bytes32[4] public roots;
    uint256 nextToken = 1;
    uint256 nonce;
    mapping(address => mapping(uint256 => bool)) minted;

    // Ghost ledger and flags.
    uint256 public ghostIn;
    uint256 public ghostOut;
    uint256 public ghostWindowStart;
    uint256 public ghostWindowUsed;
    bool public modelMismatch;
    bool public payoutMismatch;
    bool public resettled;
    bool public wordChanged;
    bool public windowViolated;
    bool public deliveryViolated;
    bool public guardianViolated;
    mapping(uint256 => uint8) public terminalState;
    mapping(uint256 => uint256) public settledWord;

    // Coverage counters.
    uint256 public opened;
    uint256 public merkleDeliveries;
    uint256 public maxIdDeliveries;
    uint256 public quickSells;
    uint256 public compensations;
    uint256 public launches;
    uint256 public withdrawals;
    uint256 public guardianDisables;
    uint256 public refunds;
    uint256 public lockedOpens;
    uint256 public guardRejections;
    uint256 public stalls;

    // v3.2 model: the snapshot each opening must keep (I-M1) and the reservation the model predicted (I-S2).
    mapping(uint256 => bytes32) public snapshotHash;
    mapping(uint256 => uint256) public predictedReservation;

    constructor() {
        weth = new MockWETH();
        nftA = new MockNFT();
        nftC = new MockNFT();
        rng = new MockRandomness();
        vault = deployTestVault(address(this));
        registry = new ExpoAdmissionRegistry(address(this), address(vault));
        pool = new ExpoGachaPool(
            IERC20(address(weth)),
            IRandomness(address(rng)),
            vault,
            IAdmission(address(registry)),
            address(this),
            address(this),
            2 ether
        );
        vault.bindPool(address(pool));
        launchpad = new ExpoLaunchpad(pool, address(this), hv.addr(SIGNER_KEY), 0.001 ether);
        pool.setConfigurator(address(launchpad));
        pool.setGuardian(GUARDIAN);
        for (uint256 t; t < 4; ++t) {
            for (uint256 i; i < 4; ++i) {
                sets[t][i] = t * 10 + i + 1;
            }
            roots[t] = TokenSets.root4(address(nftC), sets[t]);
        }
        _admit(address(nftA));
        _admit(address(nftC));
        hv.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        weth.approve(address(pool), type(uint256).max);
        weth.approve(address(launchpad), type(uint256).max);
        _fund(1.5 ether); // small: the 0.9 and 1.0 ether top prizes lock and unlock as openings come and go
        for (uint256 i; i < 3; ++i) {
            hv.deal(buyers[i], 1_000 ether);
            hv.startPrank(buyers[i]);
            weth.deposit{value: 1_000 ether}();
            weth.approve(address(pool), type(uint256).max);
            hv.stopPrank();
        }
        pool.createConfig(_etfInput(), ExpoGachaPool.Kind.Etf, 30);
        pool.createConfig(_setInput(bytes32("set")), ExpoGachaPool.Kind.Collection, 30);
    }

    receive() external payable {}

    // ------------------------------------------------------------ configuration fixtures

    function _w(address c, uint256 lo, uint256 hi, uint128 ref, uint128 budget, uint128 weight)
        internal
        pure
        returns (ExpoGachaPool.Entitlement memory)
    {
        return ExpoGachaPool.Entitlement(c, lo, hi, bytes32(0), ref, budget, weight);
    }

    /// @dev Banded ETF at 0.05 ether, two weighted items per tier on range entitlements (EV about 0.0403).
    function _etfInput() internal view returns (ExpoGachaPool.ConfigInput memory input) {
        ExpoGachaPool.Entitlement[][4] memory items;
        uint256 max = type(uint256).max;
        address a = address(nftA);
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](2);
        }
        items[0][0] = _w(a, 0, max, 0.026 ether, 0.026 ether, 3);
        items[0][1] = _w(a, 0, max, 0.04 ether, 0.03 ether, 1);
        items[1][0] = _w(a, 1, 1_000_000, 0.05 ether, 0.055 ether, 4);
        items[1][1] = _w(a, 1, 1_000_000, 0.09 ether, 0.07 ether, 1);
        items[2][0] = _w(a, 0, max, 0.1 ether, 0.12 ether, 3);
        items[2][1] = _w(a, 0, max, 0.15 ether, 0.15 ether, 1);
        items[3][0] = _w(a, 0, max, 0.2 ether, 0.25 ether, 100);
        items[3][1] = _w(a, 0, max, 0.9 ether, 0.8 ether, 1);
        input = ExpoGachaPool.ConfigInput(
            bytes32("etf"), 0.05 ether, [uint16(7500), 2000, 400, 100], 9000, 1 days, keccak256("weth-etf"), items
        );
    }

    /// @dev One frozen Merkle set per tier of nftC, banded at 0.06 ether (EV about 0.0565).
    function _setItems() internal view returns (ExpoGachaPool.Entitlement[][4] memory items) {
        uint128[4] memory ref = [uint128(0.03 ether), 0.08 ether, 0.2 ether, 1 ether];
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](1);
            items[t][0] = ExpoGachaPool.Entitlement(address(nftC), 0, 1000, roots[t], ref[t], ref[t] + 0.005 ether, 1);
        }
    }

    function _setInput(bytes32 gachaId) internal view returns (ExpoGachaPool.ConfigInput memory) {
        return ExpoGachaPool.ConfigInput(
            gachaId, 0.06 ether, [uint16(7500), 2000, 400, 100], 8000, 2 days, keccak256("weth-set"), _setItems()
        );
    }

    function _admit(address c) internal {
        address[] memory list = new address[](1);
        list[0] = c;
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256(abi.encode("evidence", c));
        registry.admit(list, evidence, uint64(block.timestamp + 365 days));
    }

    function _fund(uint256 amount) internal {
        pool.fund(amount);
        ghostIn += amount;
    }

    // ------------------------------------------------------------ actions

    function fund(uint256 amount) external {
        amount = amount % 5 ether + 1;
        if (weth.balanceOf(address(this)) < amount) return;
        _fund(amount);
    }

    function launch(uint16 fee, uint32 maxOpen) external {
        if (pool.configCount() >= 6 || weth.balanceOf(address(this)) < 0.001 ether) return;
        ExpoGachaPool.Entitlement[][4] memory items = _setItems();
        ExpoLaunchpad.Quote memory q = ExpoLaunchpad.Quote(
            address(this),
            bytes32("lp"),
            0.06 ether,
            [uint16(7500), 2000, 400, 100],
            keccak256(abi.encode(items)),
            9000,
            1 days,
            fee % 301,
            maxOpen % 12 + 1,
            keccak256("weth-lp"),
            ++nonce,
            uint64(block.timestamp + 30 minutes)
        );
        (uint8 v, bytes32 r, bytes32 s) = hv.sign(SIGNER_KEY, launchpad.quoteDigest(q));
        bytes memory sig = abi.encodePacked(r, s, v);
        if (registry.isAdmitted(address(nftC))) {
            launchpad.launch(q, items, sig);
            ghostIn += 0.001 ether;
            launches++;
        } else {
            try launchpad.launch(q, items, sig) {
                modelMismatch = true;
            } catch {}
        }
    }

    /// @dev The guardian disables a configuration; nothing else may change, and every other power is refused.
    function guard(uint256 seed) external {
        uint64 id = uint64(seed % pool.configCount()) + 1;
        uint256 balance = weth.balanceOf(address(pool));
        uint256 reserved = pool.reserved();
        uint256 launchpadReserved = pool.launchpadReserved();
        uint256 cap = pool.withdrawCap();
        (,,,,,,,, uint32 maxOpen, uint32 openNow,,) = pool.configs(id);
        hv.prank(GUARDIAN);
        pool.guardianDisable(id);
        guardianDisables++;
        (,,,,,,,, uint32 maxOpen2, uint32 openNow2,, bool on) = pool.configs(id);
        if (on || maxOpen2 != maxOpen || openNow2 != openNow) guardianViolated = true;
        if (weth.balanceOf(address(pool)) != balance || pool.reserved() != reserved) guardianViolated = true;
        if (pool.launchpadReserved() != launchpadReserved || pool.withdrawCap() != cap) guardianViolated = true;
        hv.prank(GUARDIAN);
        try pool.setEnabled(id, true) {
            guardianViolated = true;
        } catch {}
        hv.prank(GUARDIAN);
        try pool.withdraw(GUARDIAN, 1) {
            guardianViolated = true;
        } catch {}
        hv.prank(GUARDIAN);
        try pool.setGuardian(address(0)) {
            guardianViolated = true;
        } catch {}
    }

    struct Prediction {
        bool ok;
        uint256 price;
        uint256 cover;
        uint256 reservation;
    }

    function _liab(ExpoGachaPool.Entitlement memory e) internal pure returns (uint256) {
        return e.referenceUsdc > e.budgetUsdc ? e.referenceUsdc : e.budgetUsdc;
    }

    /// @dev Predicts `open` from the specification (docs/46 5.3) by scanning every entitlement: enabled, a free
    /// undrawn slot, admitted collections, the cover after the price (launchpad: capped by the cap room), a covered
    /// Common item, and the reservation max(largest covered liability, net price) within the cover.
    function _openable(uint64 id) internal view returns (Prediction memory p) {
        (ExpoGachaPool.Kind kind,,, uint128 price_,,,, uint16 feeBps, uint32 maxOpen, uint32 openNow,, bool on) =
            pool.configs(id);
        p.price = price_;
        p.ok = on && openNow < maxOpen;
        address[] memory cols = pool.collectionsOf(id);
        for (uint256 i; i < cols.length; ++i) {
            p.ok = p.ok && registry.isAdmitted(cols[i]);
        }
        uint256 fee = p.price * feeBps / 10000;
        uint256 balance = weth.balanceOf(address(pool)) + p.price;
        uint256 owed = pool.creatorFeesOwed() + fee;
        p.cover = balance - pool.reserved() - owed;
        if (kind == ExpoGachaPool.Kind.Launchpad) {
            uint256 cap = (balance - owed) * pool.launchpadCapBps() / 10000;
            uint256 room = cap > pool.launchpadReserved() ? cap - pool.launchpadReserved() : 0;
            if (room < p.cover) p.cover = room;
        }
        (uint256 largest, bool common) = _scan(id, p.cover);
        p.reservation = largest > p.price - fee ? largest : p.price - fee;
        p.ok = p.ok && common && p.reservation <= p.cover;
    }

    /// @dev Largest liability within `cover` over every entitlement, and whether a Common item is covered.
    function _scan(uint64 id, uint256 cover) internal view returns (uint256 largest, bool common) {
        for (uint8 t; t < 4; ++t) {
            uint256 n = pool.entitlementCount(id, t);
            for (uint256 j; j < n; ++j) {
                uint256 l = _liab(pool.entitlement(id, t, j));
                if (l <= cover) {
                    if (l > largest) largest = l;
                    if (t == 0) common = true;
                }
            }
        }
    }

    function _snapshotHash(uint256 id) internal view returns (bytes32) {
        (uint128 cover, uint16[4] memory drawable, uint16[4] memory odds) = pool.openingSnapshot(id);
        return keccak256(abi.encode(cover, drawable, odds));
    }

    /// @dev Buyers open with a fuzzed guard: none, exactly the predicted cover, or one more (must revert, unpaid).
    function open(uint256 seed) external {
        uint64 count = pool.configCount();
        if (pool.openingCount() >= MAX_OPENINGS) return;
        uint64 id = uint64(seed % count) + 1;
        address buyer = buyers[(seed >> 8) % 3];
        Prediction memory p = _openable(id);
        uint256 guardMode = (seed >> 16) % 3;
        uint256 minCover = guardMode == 0 ? 0 : guardMode == 1 ? p.cover : p.cover + 1;
        bool ok = p.ok && guardMode != 2;
        uint256 reservedBefore = pool.reserved();
        hv.prank(buyer);
        if (ok) {
            uint256 o = pool.open(id, minCover);
            ghostIn += p.price;
            opened++;
            (uint128 cover,,) = pool.openingSnapshot(o);
            (,,,, uint128 maxL,,,,,,,) = pool.configs(id);
            if (cover != p.cover || pool.reserved() - reservedBefore != p.reservation) modelMismatch = true;
            if (cover < maxL) lockedOpens++;
            snapshotHash[o] = _snapshotHash(o);
            predictedReservation[o] = p.reservation;
        } else {
            uint256 balance = weth.balanceOf(buyer);
            try pool.open(id, minCover) {
                modelMismatch = true;
            } catch {
                if (p.ok) guardRejections++;
            }
            if (weth.balanceOf(buyer) != balance) modelMismatch = true;
        }
    }

    function _refundAmount(uint64 configId, uint256 held) internal view returns (uint256) {
        (,,, uint128 price,,,, uint16 feeBps,,,,) = pool.configs(configId);
        uint256 fee = uint256(price) * feeBps / 10000;
        uint256 owed = pool.creatorBalance(address(this));
        uint256 free = pool.freeReserve() + held + (fee < owed ? fee : owed);
        return price < free ? price : free;
    }

    /// @dev Anyone refunds a `Pending` opening after VRF_TIMEOUT: the price (bounded by the free reserve after the
    /// release), the creator fee reversed as far as it is still owed. Refused in every other case.
    function refund(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (address buyer, uint64 configId, ExpoGachaPool.State s,,, uint64 deadline, uint96 held,,,) = pool.openings(id);
        if (s != ExpoGachaPool.State.Pending || block.timestamp < deadline) {
            try pool.refundStale(id) {
                modelMismatch = true;
            } catch {}
            return;
        }
        uint256 expected = _refundAmount(configId, held);
        uint256 before = weth.balanceOf(buyer);
        pool.refundStale(id);
        if (weth.balanceOf(buyer) - before != expected) payoutMismatch = true;
        ghostOut += expected;
        refunds++;
        (,, ExpoGachaPool.State finalState,,,,,, uint256 word,) = pool.openings(id);
        terminalState[id] = uint8(finalState);
        settledWord[id] = word;
    }

    function draw(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (,, ExpoGachaPool.State s,,,,,, uint256 word,) = pool.openings(id);
        if (s == ExpoGachaPool.State.Pending) {
            if (seed % 7 == 0) {
                stalls++; // the VRF stalls on this one; it may later be refunded
                return;
            }
            rng.fulfill(id, uint256(keccak256(abi.encode(seed))));
        } else if (s == ExpoGachaPool.State.RandomReady) {
            pool.finalize(id); // I-S3: a revert fails the run
        } else {
            // A duplicate or late VRF answer must never change the drawn word.
            rng.fulfill(id, seed ^ 1);
            (,,,,,,,, uint256 after_,) = pool.openings(id);
            if (after_ != word) wordChanged = true;
        }
    }

    function settle(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (address buyer, uint64 configId, ExpoGachaPool.State s,,, uint64 deadline,,,,) = pool.openings(id);
        if (s != ExpoGachaPool.State.Revealed && s != ExpoGachaPool.State.ClaimRequested) return;
        ExpoGachaPool.Entitlement memory e = pool.awarded(id);
        uint256 before = weth.balanceOf(address(pool));
        uint256 expected;
        (,,,,,, uint16 qs,,,,,) = pool.configs(configId);
        if (block.timestamp >= deadline) {
            // docs/41: an unclaimed opening compensates at the Quick Sell rate, a failed delivery in full.
            expected = s == ExpoGachaPool.State.Revealed ? uint256(e.referenceUsdc) * qs / 10000 : e.referenceUsdc;
            pool.compensate(id);
            compensations++;
        } else if (s == ExpoGachaPool.State.Revealed && seed % 3 == 0) {
            expected = uint256(e.referenceUsdc) * qs / 10000;
            hv.prank(buyer);
            pool.quickSell(id);
            quickSells++;
        } else if (s == ExpoGachaPool.State.Revealed) {
            hv.prank(buyer);
            pool.claimNFT(id);
            return;
        } else if (!registry.isDeliverable(e.collection)) {
            // docs/48: a revoked (or re-coded) collection is never delivered; the claim waits for re-admission or
            // compensation at its deadline.
            try pool.fulfill(id, 0, new bytes32[](0)) {
                modelMismatch = true;
            } catch {}
            return;
        } else {
            expected = e.budgetUsdc;
            _deliver(id, buyer, e, seed);
        }
        if (before - weth.balanceOf(address(pool)) != expected) payoutMismatch = true;
        ghostOut += expected;
        (,, ExpoGachaPool.State finalState,,,,,, uint256 word,) = pool.openings(id);
        terminalState[id] = uint8(finalState);
        settledWord[id] = word;
    }

    function _deliver(uint256 id, address buyer, ExpoGachaPool.Entitlement memory e, uint256 seed) internal {
        uint256 tokenId;
        bytes32[] memory proof;
        if (e.tokenRoot != bytes32(0)) {
            (,,, uint8 tier,,,,,,) = pool.openings(id);
            uint256 index = seed % 4;
            tokenId = sets[tier][index];
            proof = TokenSets.proof4(address(nftC), sets[tier], index);
            merkleDeliveries++;
        } else if (seed % 5 == 0 && e.maxTokenId == type(uint256).max && !minted[e.collection][type(uint256).max]) {
            tokenId = type(uint256).max;
            maxIdDeliveries++;
        } else {
            tokenId = nextToken++;
        }
        _intoVault(e.collection, tokenId);
        pool.fulfill(id, tokenId, proof);
        if (MockNFT(e.collection).ownerOf(tokenId) != buyer) deliveryViolated = true;
        if (tokenId < e.minTokenId || tokenId > e.maxTokenId) deliveryViolated = true;
        if (e.tokenRoot != bytes32(0) && e.collection != address(nftC)) deliveryViolated = true;
    }

    /// @dev The operator's acquisition: mint a fresh token, or buy a set token back from the buyer holding it.
    function _intoVault(address collection, uint256 tokenId) internal {
        if (!minted[collection][tokenId]) {
            minted[collection][tokenId] = true;
            MockNFT(collection).mint(address(vault), tokenId);
            return;
        }
        address holder = MockNFT(collection).ownerOf(tokenId);
        if (holder != address(vault)) {
            hv.prank(holder);
            MockNFT(collection).transferFrom(holder, address(vault), tokenId);
        }
    }

    /// @dev Tries every exit again on a settled opening; any success is a double settlement.
    function resettle(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (address buyer,, ExpoGachaPool.State s,,,,,,,) = pool.openings(id);
        if (uint8(s) < uint8(ExpoGachaPool.State.QuickSold)) return;
        hv.prank(buyer);
        try pool.quickSell(id) {
            resettled = true;
        } catch {}
        hv.prank(buyer);
        try pool.claimNFT(id) {
            resettled = true;
        } catch {}
        try pool.compensate(id) {
            resettled = true;
        } catch {}
        try pool.finalize(id) {
            resettled = true;
        } catch {}
        try pool.fulfill(id, 1, new bytes32[](0)) {
            resettled = true;
        } catch {}
        try pool.refundStale(id) {
            resettled = true;
        } catch {}
    }

    function withdraw(uint256 amount) external {
        uint256 free = pool.freeReserve();
        amount = amount % (free + 2 ether) + 1;
        uint256 start = ghostWindowStart;
        uint256 used = ghostWindowUsed;
        if (block.timestamp >= start + 24 hours) {
            start = block.timestamp;
            used = 0;
        }
        bool ok = amount <= free && used + amount <= pool.withdrawCap();
        if (ok) {
            pool.withdraw(address(this), amount);
            ghostWindowStart = start;
            ghostWindowUsed = used + amount;
            ghostOut += amount;
            withdrawals++;
            if (pool.withdrawnInWindow() != ghostWindowUsed || ghostWindowUsed > pool.withdrawCap()) {
                windowViolated = true;
            }
        } else {
            try pool.withdraw(address(this), amount) {
                windowViolated = true;
            } catch {}
        }
    }

    function govern(uint256 seed) external {
        uint256 action = seed % 7;
        if (action == 0) {
            registry.revoke(seed % 2 == 0 ? address(nftA) : address(nftC));
        } else if (action == 1) {
            _admit(seed % 2 == 0 ? address(nftA) : address(nftC));
        } else if (action == 2) {
            pool.setLaunchpadCapBps(uint16(seed % 2501));
        } else if (action == 3) {
            pool.setEnabled(uint64(seed % pool.configCount()) + 1, seed % 4 != 0);
        } else if (action == 4) {
            uint256 cap = pool.withdrawCap();
            uint256 next = (seed >> 8) % 10 ether;
            pool.proposeWithdrawCap(next);
            if (next > cap && pool.withdrawCap() != cap) windowViolated = true; // increases must wait 48 h
        } else if (action == 5) {
            uint256 at = pool.pendingWithdrawCapAt();
            if (at != 0 && block.timestamp >= at) pool.applyWithdrawCap();
        } else {
            uint256 owed = pool.creatorBalance(address(this));
            if (owed > 0) {
                pool.withdrawCreatorFees();
                ghostOut += owed;
            }
        }
    }

    function elapse(uint32 seconds_) external {
        hv.warp(block.timestamp + seconds_ % 2 days); // reaches VRF_TIMEOUT and settlement deadlines
    }
}

contract ExpoGachaWethInvariantTest {
    WethGachaHandler handler;

    function setUp() public {
        handler = new WethGachaHandler();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    /// @dev The run reaches the paths the invariants are about: WETH openings, Merkle deliveries, a uint256-max
    /// token, Quick Sell, compensation, launches and withdrawals.
    /// @dev Seed that makes the handler pick opening `id` (seed % n + 1) with seed % 3 == r.
    function _seed(uint256 id, uint256 n, uint256 r) internal pure returns (uint256 s) {
        s = id - 1;
        while (s % 3 != r) s += n;
    }

    function testHandlerReachesWethMerkleAndLaunchPaths() public {
        handler.launch(150, 3);
        for (uint256 i; i < 40; ++i) {
            handler.open(i * 7 + (i << 8)); // guard mode 0: no minCover
            if (i % 8 == 0) handler.fund(5 ether - 1); // the reserve grows: top prizes unlock for later openings
        }
        handler.open(1 << 16 | 1); // minCover = the predicted cover: accepted
        handler.open(2 << 16 | 1); // minCover above the cover: CoverTooLow, unpaid
        uint256 n = handler.pool().openingCount();
        for (uint256 id = 1; id <= n; ++id) {
            handler.draw(id - 1); // randomness (every seventh stalls)
            handler.draw(id - 1); // finalize
        }
        // Even openings Quick Sell, odd ones claim; then half the claims are delivered, the rest expire.
        for (uint256 id = 1; id <= n; ++id) {
            handler.settle(_seed(id, n, id % 2 == 0 ? 0 : 1));
        }
        for (uint256 id = 1; id <= n; id += 4) {
            handler.settle(_seed(id, n, 0));
        }
        handler.refund(0); // stalled but not yet stale: refused
        handler.elapse(1 days + 1);
        handler.elapse(1 days + 1);
        for (uint256 id = 1; id <= n; ++id) {
            handler.settle(_seed(id, n, 2));
            handler.refund(id - 1); // stalled openings are now refundable
            handler.resettle(id - 1);
            handler.draw(id - 1); // late duplicate randomness
        }
        handler.withdraw(1 ether);
        // docs/41: the guardian disables, the owner re-enables.
        handler.guard(0);
        handler.govern(3); // owner setEnabled(1, true)
        ExpoGachaPool pool = handler.pool();
        require(handler.guardianDisables() == 1 && !handler.guardianViolated(), "guardian path");
        require(handler.opened() >= 25 && handler.launches() == 1, "openings and launch");
        require(handler.merkleDeliveries() > 0 && handler.quickSells() > 0, "Merkle delivery and Quick Sell");
        require(handler.compensations() > 0, "compensation");
        require(handler.withdrawals() == 1, "withdrawal");
        require(handler.refunds() > 0 && handler.stalls() > 0, "stalled VRF and stale refunds");
        require(handler.lockedOpens() > 0 && handler.guardRejections() > 0, "locked snapshots and the buyer guard");
        require(pool.reserved() == 0 && pool.creatorFeesOwed() == pool.creatorBalance(address(handler)), "all settled");
        require(!handler.modelMismatch() && !handler.payoutMismatch() && !handler.resettled(), "model holds");
        require(!handler.wordChanged() && !handler.deliveryViolated() && !handler.windowViolated(), "flags clear");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_WethReserveSettlementAndCaps() public view {
        ExpoGachaPool pool = handler.pool();
        MockWETH weth = handler.weth();
        uint256 balance = weth.balanceOf(address(pool));
        // I-S1: the reserve covers liabilities plus creator fees; freeReserve() never underflows.
        require(balance >= pool.reserved() + pool.creatorFeesOwed(), "solvent");
        require(pool.freeReserve() == balance - pool.reserved() - pool.creatorFeesOwed(), "free reserve");
        // Ghost ledger: every wei in and out is explained by a rule.
        require(balance == handler.ghostIn() - handler.ghostOut(), "ledger reconciles");
        require(address(weth).balance == weth.totalSupply(), "WETH backed");
        require(pool.creatorFeesOwed() == pool.creatorBalance(address(handler)), "fees reconcile");
        require(
            !handler.modelMismatch(), "pool accepted a call the spec refuses, or a snapshot the model did not predict"
        );
        require(!handler.payoutMismatch(), "payout differs from the rule");
        require(!handler.resettled(), "settled opening re-settled");
        require(!handler.wordChanged(), "duplicate VRF changed a word");
        require(!handler.windowViolated(), "withdrawal outside the window cap");
        require(!handler.deliveryViolated(), "delivery outside the awarded entitlement");
        require(!handler.guardianViolated(), "guardian changed more than one enabled flag");

        uint256[4] memory totals; // reserved, launchpad, claims on nftA, claims on nftC
        uint32[8] memory undrawn;
        for (uint256 i = 1; i <= pool.openingCount(); i++) {
            _checkOpening(pool, i, totals, undrawn);
        }
        // I-C2: revealed and claim-requested openings stay reserved until they settle.
        require(totals[0] == pool.reserved(), "liabilities reconcile");
        require(totals[1] == pool.launchpadReserved(), "launchpad share reconciles");
        // docs/48 V-6: the vault's recovery ledger counts exactly the waiting claims per collection.
        require(pool.pendingClaims(address(handler.nftA())) == totals[2], "pending claims A");
        require(pool.pendingClaims(address(handler.nftC())) == totals[3], "pending claims C");
        for (uint64 c = 1; c <= pool.configCount(); c++) {
            (,,,,,,,, uint32 maxOpen, uint32 openNow,,) = pool.configs(c);
            // I-C1: only undrawn openings hold a slot.
            require(openNow == undrawn[c] && openNow <= maxOpen, "per-configuration undrawn openings");
            _checkConfig(pool, c);
        }
    }

    function _checkOpening(ExpoGachaPool pool, uint256 i, uint256[4] memory totals, uint32[8] memory undrawn)
        internal
        view
    {
        (
            ,
            uint64 configId,
            ExpoGachaPool.State state,
            uint8 tier,
            uint16 index,,
            uint96 liability,
            uint96 cover,
            uint256 word,
        ) = pool.openings(i);
        (ExpoGachaPool.Kind kind,,,,,,,,,,,) = pool.configs(configId);
        _checkSnapshot(pool, i, configId, state, tier, index);
        if (state == ExpoGachaPool.State.ClaimRequested) {
            if (pool.awarded(i).collection == address(handler.nftA())) totals[2]++;
            else totals[3]++;
        }
        totals[0] += liability;
        if (kind == ExpoGachaPool.Kind.Launchpad) totals[1] += liability;
        if (uint8(state) <= uint8(ExpoGachaPool.State.RandomReady)) {
            undrawn[configId]++;
            // I-S2: an undrawn opening holds exactly the predicted reservation, within its cover.
            require(liability == handler.predictedReservation(i) && liability <= cover, "undrawn reservation");
        } else if (state != ExpoGachaPool.State.Refunded) {
            // I-L1: the awarded item's liability is covered.
            ExpoGachaPool.Entitlement memory e = pool.awarded(i);
            uint256 l = e.referenceUsdc > e.budgetUsdc ? e.referenceUsdc : e.budgetUsdc;
            require(l <= cover, "awarded liability covered");
        }
        if (uint8(state) >= uint8(ExpoGachaPool.State.QuickSold)) {
            require(liability == 0, "terminal has no liability");
            require(uint8(state) == handler.terminalState(i) && word == handler.settledWord(i), "terminal frozen");
        }
    }

    /// @dev I-M1, I-O1, I-E1 on the opening's snapshot, and I-L1's index bound once drawn.
    function _checkSnapshot(
        ExpoGachaPool pool,
        uint256 i,
        uint64 configId,
        ExpoGachaPool.State state,
        uint8 tier,
        uint16 index
    ) internal view {
        (uint128 c2, uint16[4] memory drawable, uint16[4] memory odds) = pool.openingSnapshot(i);
        // I-M1: the snapshot never changes after open.
        require(keccak256(abi.encode(c2, drawable, odds)) == handler.snapshotHash(i), "snapshot changed");
        // I-O1: snapshot odds sum to 10,000, a tier with odds has drawable items, Common is drawable.
        require(uint256(odds[0]) + odds[1] + odds[2] + odds[3] == 10000 && drawable[0] > 0, "snapshot odds");
        for (uint256 t; t < 4; ++t) {
            require(odds[t] == 0 || drawable[t] > 0, "odds only on drawable tiers");
        }
        // I-E1: the snapshot's EV is at most the published one (floor rounding: at most one unit per item).
        uint256 ev = _snapshotEv(pool, configId, drawable, odds);
        require(ev <= uint256(pool.expectedReference(configId)) + 128, "snapshot EV");
        if (uint8(state) >= uint8(ExpoGachaPool.State.Revealed) && state != ExpoGachaPool.State.Refunded) {
            require(index < drawable[tier] && odds[tier] > 0, "I-L1: awarded inside the drawable prefix");
        }
    }

    function _snapshotEv(ExpoGachaPool pool, uint64 id, uint16[4] memory drawable, uint16[4] memory odds)
        internal
        view
        returns (uint256 ev)
    {
        for (uint8 t; t < 4; ++t) {
            if (drawable[t] == 0) continue;
            uint256 w = pool.cumulativeWeight(id, t, drawable[t] - 1);
            uint256 s;
            for (uint256 j; j < drawable[t]; ++j) {
                ExpoGachaPool.Entitlement memory e = pool.entitlement(id, t, j);
                s += uint256(e.weight) * e.referenceUsdc / w;
            }
            ev += odds[t] * s;
        }
        ev /= 10000;
    }

    /// @dev I-W1, I-B1, I-E1 on every stored configuration.
    function _checkConfig(ExpoGachaPool pool, uint64 id) internal view {
        (,,, uint128 price,,,,,,,,) = pool.configs(id);
        uint16[4] memory odds = pool.oddsOf(id);
        uint256 ev;
        for (uint8 t; t < 4; ++t) {
            require((odds[t] == 0) == (pool.entitlementCount(id, t) == 0), "odds iff items");
            ev += odds[t] * _checkTier(pool, id, t, price);
        }
        uint128 expectedReference = pool.expectedReference(id);
        require(ev / 10000 == expectedReference && expectedReference <= price, "I-E1 EV ceiling");
    }

    function _inBand(uint8 t, uint256 v, uint256 price) internal pure returns (bool) {
        if (t == 0) return 2 * v >= price && v < price;
        if (t == 1) return v >= price && v < 2 * price;
        if (t == 2) return v >= 2 * price && v < 4 * price;
        return v >= 4 * price;
    }

    /// @dev Weights positive and non-increasing, liabilities non-decreasing, cumulative weights consistent, bands; returns
    /// the tier's weighted reference sum (floor per item, as the pool computes it).
    function _checkTier(ExpoGachaPool pool, uint64 id, uint8 t, uint256 price) internal view returns (uint256 sum) {
        uint256 n = pool.entitlementCount(id, t);
        uint256 w = pool.tierWeight(id, t);
        uint256[3] memory run = [uint256(0), 0, type(uint256).max]; // cumulative, previous liability, previous weight
        for (uint256 j; j < n; ++j) {
            ExpoGachaPool.Entitlement memory e = pool.entitlement(id, t, j);
            uint256 l = e.referenceUsdc > e.budgetUsdc ? e.referenceUsdc : e.budgetUsdc;
            require(e.weight > 0 && e.weight <= run[2] && l >= run[1], "I-W1 order");
            run[0] += e.weight;
            require(pool.cumulativeWeight(id, t, j) == run[0], "cumulative weights");
            require(_inBand(t, e.referenceUsdc, price), "I-B1 band");
            sum += uint256(e.weight) * e.referenceUsdc / w;
            run[1] = l;
            run[2] = e.weight;
        }
        require(run[0] == w && w <= type(uint128).max, "I-W1 tier weight");
    }
}
