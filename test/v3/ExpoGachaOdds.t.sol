// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoGachaPool, IAdmission} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoLaunchpad} from "../../src/v3/ExpoLaunchpad.sol";
import {IRandomness} from "../../src/ExpoPool.sol";
import {OddsBase, ExpoGachaPoolHarness} from "./OddsTestBase.sol";

/// @dev Configuration and draw tests of docs/46 section 11 (v3.2: machine-relative bands, value-weighted draws).
/// Written before the implementation: against v3.1 they do not compile (no `weight`, no `open(id, minCover)`, no
/// snapshot views).

// ==================================================================== configuration (docs/46 7.3)

contract ExpoGachaOddsConfigTest is OddsBase {
    address constant ATTACKER = address(0xA77);

    function _common(uint128 ref, uint128 budget, uint128 weight)
        internal
        view
        returns (ExpoGachaPool.Entitlement[][4] memory items)
    {
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = _e(address(nftA), ref, budget, weight);
    }

    /// @dev A Common item at 60 plus one item of `tier` at `ref` (budget = ref), the tier at 1 bps so the EV ceiling
    /// never decides.
    function _withTier(uint8 tier, uint128 ref) internal view returns (ExpoGachaPool.ConfigInput memory input) {
        ExpoGachaPool.Entitlement[][4] memory items = _common(60e6, 60e6, 1);
        uint16[4] memory odds;
        odds[0] = 9999;
        if (tier == 0) {
            items[0] = new ExpoGachaPool.Entitlement[](1);
            items[0][0] = _e(address(nftA), ref, ref, 1);
            odds[0] = 10000;
        } else {
            items[tier] = new ExpoGachaPool.Entitlement[](1);
            items[tier][0] = _e(address(nftB), ref, ref, 1);
            odds[tier] = 1;
        }
        input = _input(items, P, odds);
    }

    /// @dev Through the launch path: the bands bind launches only (docs/46 section 17).
    function _accepts(ExpoGachaPool.ConfigInput memory input) internal returns (bool) {
        pool.setConfigurator(address(this));
        try pool.createLaunchpadConfig(input, ATTACKER, 0, 10) returns (uint64) {
            return true;
        } catch {
            return false;
        }
    }

    function _rejects(ExpoGachaPool.ConfigInput memory input) internal {
        pool.setConfigurator(address(this));
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createLaunchpadConfig(input, ATTACKER, 0, 10);
    }

    function test_ReferenceMachineStoresWeightsAndExpectedReference() public {
        uint64 id = _machine();
        ExpoGachaPool.Entitlement[][4] memory items = _machineItems();
        uint16[4] memory odds = _defaultOdds();
        uint256 ev;
        for (uint8 t; t < 4; ++t) {
            uint256 cum;
            for (uint256 j; j < items[t].length; ++j) {
                cum += items[t][j].weight;
                require(pool.cumulativeWeight(id, t, j) == cum, "cumulative weight");
                ExpoGachaPool.Entitlement memory e = pool.entitlement(id, t, j);
                require(e.weight == items[t][j].weight && e.referenceUsdc == items[t][j].referenceUsdc, "entitlement");
            }
            require(pool.tierWeight(id, t) == cum, "tier weight");
            uint256 s;
            for (uint256 j; j < items[t].length; ++j) {
                s += uint256(items[t][j].weight) * items[t][j].referenceUsdc / cum;
            }
            ev += odds[t] * s;
        }
        ev /= 10000;
        uint128 expected = pool.expectedReference(id);
        require(expected == ev && ev == 84_269_635, "on-chain EV with full weights, floor");
        (,,,, uint128 maxL,,,,,,,) = pool.configs(id);
        require(maxL == 3125e6, "maxLiability keeps its meaning");
    }

    /// @dev Two Commons and one Uncommon with fuzzed price, references, budgets, weights and odds: the pool accepts
    /// exactly the configurations that satisfy docs/46 7.3.
    function testFuzz_CreateConfig_AcceptsIffValid(
        uint128 price,
        uint128[3] memory ref,
        uint128[3] memory budget,
        uint128[3] memory weight,
        uint16 o0
    ) public {
        price = uint128(_bound(price, 2, 1e12));
        for (uint256 i; i < 3; ++i) {
            ref[i] = uint128(_bound(ref[i], price / 4 + 1, uint256(price) * 5 / 2));
            budget[i] = uint128(_bound(budget[i], 1, uint256(ref[i]) * 2));
            weight[i] = uint128(_bound(weight[i], 0, 1000));
        }
        o0 = uint16(_bound(o0, 0, 10000));
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = _e(address(nftA), ref[0], budget[0], weight[0]);
        items[0][1] = _e(address(nftB), ref[1], budget[1], weight[1]);
        items[1] = new ExpoGachaPool.Entitlement[](1);
        items[1][0] = _e(address(nftC), ref[2], budget[2], weight[2]);
        uint16 o1 = 10000 - o0;
        bool valid = o0 > 0 && o1 > 0;
        uint256[3] memory l;
        for (uint256 i; i < 3; ++i) {
            l[i] = ref[i] > budget[i] ? ref[i] : budget[i];
            valid = valid && weight[i] > 0 && uint256(budget[i]) <= uint256(ref[i]) * 15000 / 10000;
        }
        valid = valid && l[1] >= l[0] && weight[1] <= weight[0];
        for (uint256 i; i < 2; ++i) {
            valid = valid && 2 * uint256(ref[i]) >= price && ref[i] < price;
        }
        valid = valid && ref[2] >= price && ref[2] < 2 * uint256(price);
        if (valid) {
            uint256 w0 = uint256(weight[0]) + weight[1];
            uint256 s0 = uint256(weight[0]) * ref[0] / w0 + uint256(weight[1]) * ref[1] / w0;
            uint256 ev = (o0 * s0 + uint256(o1) * ref[2]) / 10000;
            valid = ev <= price;
        }
        require(_accepts(_input(items, price, [o0, o1, 0, 0])) == valid, "accepted iff docs/46 7.3 holds");
    }

    function test_RejectsZeroWeight() public {
        _rejects(_input(_common(60e6, 60e6, 0), P, [uint16(10000), 0, 0, 0]));
    }

    function test_RejectsIncreasingWeight() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = _e(address(nftA), 60e6, 60e6, 5);
        items[0][1] = _e(address(nftA), 70e6, 70e6, 6); // the dearer item may not be likelier
        _rejects(_input(items, P, [uint16(10000), 0, 0, 0]));
        items[0][1].weight = 5; // equal is allowed
        require(_accepts(_input(items, P, [uint16(10000), 0, 0, 0])), "equal weights accepted");
    }

    function test_RejectsUnsortedLiability() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = _e(address(nftA), 70e6, 70e6, 5);
        items[0][1] = _e(address(nftA), 60e6, 60e6, 5);
        _rejects(_input(items, P, [uint16(10000), 0, 0, 0]));
        // Sorted by reference but not by liability (the budget decides): still rejected.
        items[0][0] = _e(address(nftA), 60e6, 80e6, 5);
        items[0][1] = _e(address(nftA), 70e6, 70e6, 5);
        _rejects(_input(items, P, [uint16(10000), 0, 0, 0]));
        items[0][1] = _e(address(nftA), 70e6, 80e6, 5); // equal liabilities are sorted
        require(_accepts(_input(items, P, [uint16(10000), 0, 0, 0])), "ties accepted");
    }

    function test_RejectsTierWeightOverflow() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = _e(address(nftA), 60e6, 60e6, uint128(1) << 127);
        items[0][1] = _e(address(nftA), 70e6, 70e6, uint128(1) << 127); // sum = 2^128
        _rejects(_input(items, P, [uint16(10000), 0, 0, 0]));
        items[0][1].weight = (uint128(1) << 127) - 1; // sum = 2^128 - 1 = MAX_TIER_WEIGHT
        uint64 id = pool.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        require(pool.tierWeight(id, 0) == type(uint128).max, "maximum tier weight");
    }

    function test_RejectsOutOfBand_Common() public {
        _rejects(_withTier(0, P / 2 - 1)); // below half the price: excluded
        _rejects(_withTier(0, P)); // the price itself is Uncommon
        require(_accepts(_withTier(0, P / 2)) && _accepts(_withTier(0, P - 1)), "Common band [0.5P, P)");
    }

    function test_RejectsOutOfBand_Uncommon() public {
        _rejects(_withTier(1, P - 1));
        _rejects(_withTier(1, 2 * P));
        require(_accepts(_withTier(1, P)) && _accepts(_withTier(1, 2 * P - 1)), "Uncommon band [P, 2P)");
    }

    function test_RejectsOutOfBand_Rare() public {
        _rejects(_withTier(2, 2 * P - 1));
        _rejects(_withTier(2, 4 * P));
        require(_accepts(_withTier(2, 2 * P)) && _accepts(_withTier(2, 4 * P - 1)), "Rare band [2P, 4P)");
    }

    function test_RejectsOutOfBand_Epic() public {
        _rejects(_withTier(3, 4 * P - 1));
        require(_accepts(_withTier(3, 4 * P)) && _accepts(_withTier(3, 1000 * P)), "Epic band [4P, inf)");
    }

    /// @dev v = P is Uncommon, 2v = P is Common, and the integer tests need no division (odd prices included).
    function test_BandBoundaries() public {
        require(_accepts(_withTier(1, P)), "v = P is Uncommon");
        _rejects(_withTier(0, P));
        require(_accepts(_withTier(0, P / 2)), "2v = P is Common");
        ExpoGachaPool.ConfigInput memory odd = _withTier(0, 50);
        odd.priceUsdc = 101;
        _rejects(odd); // 2 × 50 = 100 < 101
        odd.items[0][0] = _e(address(nftA), 51, 51, 1);
        require(_accepts(odd), "2 x 51 >= 101");
    }

    /// @dev EV ceiling: expected reference payout at most 100% of the price (H-1 option C).
    function test_RejectsEvAboveMaxReturn() public {
        ExpoGachaPool.Entitlement[][4] memory items = _common(99e6, 99e6, 1);
        items[1] = new ExpoGachaPool.Entitlement[](1);
        items[1][0] = _e(address(nftB), 199e6, 199e6, 1);
        _rejects(_input(items, P, [uint16(9000), 1000, 0, 0])); // 89.1 + 19.9 = 109
        uint64 id = pool.createConfig(_input(items, P, [uint16(9900), 100, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        uint128 expected = pool.expectedReference(id);
        require(expected == P, "exactly 100% is accepted");
    }

    function test_RejectsBudgetAboveMargin() public {
        _rejects(_input(_common(60e6, 90e6 + 1, 1), P, [uint16(10000), 0, 0, 0]));
        require(_accepts(_input(_common(60e6, 90e6, 1), P, [uint16(10000), 0, 0, 0])), "1.5 x reference accepted");
    }

    function test_RejectsMoreThan128Entries() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](129);
        for (uint256 j; j < 129; ++j) {
            items[0][j] = _e(address(nftA), 60e6, 60e6, 1);
        }
        _rejects(_input(items, P, [uint16(10000), 0, 0, 0])); // MAX_PER_TIER
        items[0] = new ExpoGachaPool.Entitlement[](65);
        items[1] = new ExpoGachaPool.Entitlement[](64);
        for (uint256 j; j < 65; ++j) {
            items[0][j] = _e(address(nftA), 60e6, 60e6, 1);
            if (j < 64) items[1][j] = _e(address(nftA), 110e6, 110e6, 1);
        }
        _rejects(_input(items, P, [uint16(9000), 1000, 0, 0])); // MAX_ENTRIES = 128 per configuration
        items[0] = new ExpoGachaPool.Entitlement[](64);
        for (uint256 j; j < 64; ++j) {
            items[0][j] = _e(address(nftA), 60e6, 60e6, 1);
        }
        require(_accepts(_input(items, P, [uint16(9000), 1000, 0, 0])), "128 entries accepted");
    }

    /// @dev docs/40 L-3 inverted: the largest allowed configuration (128 entries, 64 collections) fits in 25M gas.
    function test_CreateConfigGasAtMaximum() public {
        address[] memory cols = _collections(64);
        ExpoGachaPool.Entitlement[][4] memory items;
        uint256 k;
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](32);
            uint256 lo = t == 0 ? P / 2 : uint256(P) << (t - 1);
            for (uint256 j; j < 32; ++j) {
                uint128 ref = uint128(lo + j * (lo / 64));
                items[t][j] = _e(cols[k++ % 64], ref, ref * 5 / 4, uint128(1) << (127 - j));
            }
        }
        ExpoGachaPool.ConfigInput memory input = _input(items, P, _defaultOdds());
        uint256 g = gasleft();
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        uint256 used = g - gasleft();
        emit log_named_uint("createConfig 128 entries, 64 collections", used);
        require(used < 25_000_000, "under 25M gas");
        require(pool.MAX_PER_TIER() == 128 && pool.MAX_ENTRIES() == 128, "bounds");
    }

    /// @dev The ETF that script/deploy-v3.mjs creates on the v3.2 pool (TIERS, PRICE, ODDS there) passes 7.3.
    function test_DeployScriptConfigurationIsValid() public {
        uint128[4] memory value = [uint128(0.0013 ether), 0.0025 ether, 0.005 ether, 0.01 ether];
        ExpoGachaPool.Entitlement[][4] memory items;
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](1);
            items[t][0] = ExpoGachaPool.Entitlement(
                address(nftA), 1000 * (t + 1), 1000 * (t + 1) + 999, bytes32(0), value[t], value[t], 1
            );
        }
        uint64 id = pool.createConfig(_input(items, 0.002 ether, _defaultOdds()), ExpoGachaPool.Kind.Etf, 25);
        require(pool.expectedReference(id) == 0.001775 ether, "88.75% return");
    }

    /// @dev H-1: a 1-wei configuration with a reserve-sized item is rejected by the bands, and a reserve-sized jackpot
    /// at even 1 bps is rejected by the EV ceiling.
    function test_H1_ExtractionConfigRejected() public {
        ExpoGachaPool.Entitlement[][4] memory items = _common(1_000_000e6, 1_000_000e6, 1);
        _rejects(_input(items, 1, [uint16(10000), 0, 0, 0]));
        items = _common(60e6, 60e6, 1);
        items[3] = new ExpoGachaPool.Entitlement[](1);
        items[3][0] = _e(address(nftB), 1_000_000e6, 1_000_000e6, 1);
        _rejects(_input(items, P, [uint16(9999), 0, 0, 1]));
    }

    /// @dev H-2: a configurator EOA (or a stolen quote key) is bounded by the same on-chain checks.
    function test_H2_ConfiguratorEoaBoundedByOnchainChecks() public {
        pool.setConfigurator(ATTACKER);
        ExpoGachaPool.Entitlement[][4] memory items = _common(60e6, 60e6, 1);
        items[3] = new ExpoGachaPool.Entitlement[](1);
        items[3][0] = _e(address(nftB), 1_000_000e6, 1_000_000e6, 1);
        ov.prank(ATTACKER);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createLaunchpadConfig(_input(items, P, [uint16(9999), 0, 0, 1]), ATTACKER, 0, 10);
        ov.prank(ATTACKER);
        ov.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createLaunchpadConfig(_input(_common(1_000e6, 1_000e6, 1), 1, [uint16(10000), 0, 0, 0]), ATTACKER, 0, 10);
        ov.prank(ATTACKER);
        pool.createLaunchpadConfig(_input(_machineItems(), P, _defaultOdds()), ATTACKER, 0, 10); // bounded: accepted
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + x % (hi - lo + 1);
    }

    event log_named_uint(string key, uint256 val);
}

// ==================================================================== draw (docs/46 5.4)

contract ExpoGachaOddsDrawTest is OddsBase {
    /// @dev For any reserve and word, the awarded index is inside the drawable prefix and its liability is covered.
    function testFuzz_DrawWithinPrefix(uint256 free, uint256 word) public {
        uint64 id = _machine();
        _setFree(free % 4000e6);
        uint256 o = _openWith(id, 0);
        (uint128 cover, uint16[4] memory drawable,) = pool.openingSnapshot(o);
        (uint8 pt, uint32 pi) = pool.previewDraw(id, cover, o, word);
        _drawWith(o, word);
        (ExpoGachaPool.State s, uint8 tier, uint16 index, uint96 liability,) = _op(o);
        require(s == ExpoGachaPool.State.Revealed, "revealed");
        require(index < drawable[tier] && liability <= cover, "inside the drawable prefix and covered");
        require(liability == _liab(id, tier, index), "awarded liability");
        require(pt == tier && pi == index, "previewDraw is the finalize mapping");
    }

    /// @dev 2^16 scripted words over a 6/3/1 tier: frequencies match w / W within five standard deviations.
    function test_DrawDistributionMatchesWeights() public {
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](3);
        items[0][0] = _e(address(nftA), 60e6, 60e6, 6);
        items[0][1] = _e(address(nftA), 70e6, 70e6, 3);
        items[0][2] = _e(address(nftA), 80e6, 80e6, 1);
        ExpoGachaPoolHarness h = new ExpoGachaPoolHarness(
            usdc, IRandomness(address(rng)), vault, IAdmission(address(registry)), OPERATOR, address(this), 0
        );
        uint64 id = h.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        uint256 n = 1 << 16;
        uint256[] memory hits = h.drawHistogram(id, 80e6, n, 3); // the pool's own _draw, as finalize runs it
        uint256[3] memory w = [uint256(6), 3, 1];
        for (uint256 k; k < 3; ++k) {
            uint256 mean = n * w[k] / 10;
            uint256 sd = _sqrt(n * w[k] * (10 - w[k]) / 100);
            uint256 diff = hits[k] > mean ? hits[k] - mean : mean - hits[k];
            require(diff <= 5 * sd, "frequency within 5 sigma of w / W");
        }
    }

    function test_SmallestWeightReachable() public {
        ExpoGachaPoolHarness h = new ExpoGachaPoolHarness(
            usdc, IRandomness(address(rng)), vault, IAdmission(address(registry)), OPERATOR, address(this), 0
        );
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = _e(address(nftA), 60e6, 60e6, (uint128(1) << 100) - 1);
        items[0][1] = _e(address(nftA), 70e6, 70e6, 1); // 1 in 2^100
        uint64 id = h.createConfig(_input(items, P, [uint16(10000), 0, 0, 0]), ExpoGachaPool.Kind.Etf, 10);
        uint256 w = uint256(1) << 100;
        require(h.exposedPick(id, 0, 2, 0) == 0, "r = 0 selects index 0");
        require(h.exposedPick(id, 0, 2, w - 2) == 0, "r below the last cumulative stays on index 0");
        require(h.exposedPick(id, 0, 2, w - 1) == 1, "the weight-1 item is selected exactly by its r");
        uint64 m = h.createConfig(_input(_machineItems(), P, _defaultOdds()), ExpoGachaPool.Kind.Etf, 10);
        require(h.exposedPick(m, 0, 4, 0) == 0 && h.exposedPick(m, 0, 4, 2249) == 3, "r = W - 1 selects the last");
        require(h.exposedPick(m, 0, 4, 999) == 0 && h.exposedPick(m, 0, 4, 1000) == 1, "cumulative boundary");
        require(h.exposedPick(m, 0, 2, 1599) == 1, "the prefix's last item at r = cum[m - 1] - 1");
        require(h.exposedPick(m, 3, 2, 100) == 1 && h.exposedPick(m, 3, 1, 99) == 0, "Epic");
    }

    /// @dev The item draw spans the full 256-bit hash: the modulo bias is at most W_t / 2^256 <= 2^-128.
    function test_ModuloBiasBound() public view {
        require(pool.MAX_TIER_WEIGHT() == type(uint128).max, "tier weights fit uint128");
        uint256 w = pool.MAX_TIER_WEIGHT();
        // The excess residues of 2^256 modulo W (the biased outcomes) number fewer than W, out of 2^256 draws.
        uint256 excess = (type(uint256).max % w + 1) % w;
        require(excess < w && w <= uint256(1) << 128, "bias <= W / 2^256 <= 2^-128");
    }

    /// @dev Tier roll boundaries of v3.1 at 7500 / 2000 / 400 / 100 with every tier drawable.
    function test_TierRollUnchanged() public {
        uint64 id = _machine();
        uint256[8] memory words = [uint256(0), 7499, 7500, 9499, 9500, 9899, 9900, 9999];
        uint8[8] memory tiers = [0, 0, 1, 1, 2, 2, 3, 3];
        for (uint256 i; i < 8; ++i) {
            (uint8 tier,) = pool.previewDraw(id, 3125e6, 1, words[i] + 10000 * 77);
            require(tier == tiers[i], "tier boundary");
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

// ==================================================================== gas (docs/46 7.7)

interface GasVm {
    function cool(address) external;
}

contract ExpoGachaOddsGasTest is OddsBase {
    GasVm constant gv = GasVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_uint(string key, uint256 val);

    function _cool() internal {
        gv.cool(address(pool));
        gv.cool(address(registry));
        gv.cool(address(rng));
        gv.cool(address(usdc));
        gv.cool(address(vault));
        gv.cool(address(nftA));
        gv.cool(address(nftB));
        for (uint256 i; i < extra.length; ++i) {
            gv.cool(address(extra[i]));
        }
    }

    /// @dev Cold-storage gas of open and finalize (execution only, without the 21k base and calldata) after one
    /// warm-up opening, so counters are already non-zero as on a live pool.
    function _measure(string memory label, uint256[4] memory perTier, uint256 nCols, uint256 free)
        internal
        returns (uint256 openGas, uint256 finalizeGas)
    {
        uint64 id = _grid(perTier, nCols);
        _setFree(1_000_000e6);
        _drawWith(_openWith(id, 0), 1);
        _setFree(free);
        _cool();
        ov.prank(BUYER);
        uint256 g = gasleft();
        uint256 o = pool.open(id, 0);
        openGas = g - gasleft();
        rng.fulfill(rng.count(), uint256(keccak256(abi.encode(label))) / 10000 * 10000 + 9950); // an Epic roll
        _cool();
        g = gasleft();
        pool.finalize(o);
        finalizeGas = g - gasleft();
        emit log_named_uint(string.concat(label, " open"), openGas);
        emit log_named_uint(string.concat(label, " finalize"), finalizeGas);
        require(finalizeGas < 150_000, "finalize under 150k");
    }

    function test_OpenGas() public {
        (uint256 a,) = _measure("4x10, 1 collection, all drawable", [uint256(10), 10, 10, 10], 1, 1_000_000e6);
        (uint256 b,) = _measure("4x10, 1 collection, Epic partly locked", [uint256(10), 10, 10, 10], 1, 600e6);
        (uint256 c,) = _measure("4x10, 10 collections, all drawable", [uint256(10), 10, 10, 10], 10, 1_000_000e6);
        (uint256 d,) = _measure("4x10, 10 collections, Epic partly locked", [uint256(10), 10, 10, 10], 10, 600e6);
        (uint256 e,) = _measure("125+1+1+1, 1 collection, Common partly locked", [uint256(125), 1, 1, 1], 1, 0);
        require(a < 400_000 && b < 400_000 && c < 400_000 && d < 400_000 && e < 400_000, "open under 400k");
    }

    /// @dev Worst case allowed by the bounds: 128 entries over 64 collections. `open` checks the admission of every
    /// distinct collection (v3.1 behaviour), which dominates: reported, not bounded by 400k.
    function test_OpenGasAt64Collections() public {
        _measure("4x32, 64 collections, all drawable", [uint256(32), 32, 32, 32], 64, 1_000_000e6);
        _measure("4x32, 64 collections, Epic partly locked", [uint256(32), 32, 32, 32], 64, 1_000e6);
    }

    function test_FinalizeGas() public {
        _measure("finalize: 125-item Common, prefix search", [uint256(125), 1, 1, 1], 1, 0);
        _measure("finalize: 4x32, Epic partly locked", [uint256(32), 32, 32, 32], 1, 1_000e6);
    }

    /// @dev createConfig gas (every repricing republishes a configuration): `total` whole-collection entries spread
    /// evenly over the four tiers and `nCols` collections, measured cold.
    function _createGas(uint256 total, uint256 nCols) internal returns (uint256 used) {
        address[] memory cols = _collections(nCols);
        ExpoGachaPool.Entitlement[][4] memory items;
        uint256[4] memory per = [total / 4, total / 4, total / 4, total - 3 * (total / 4)];
        uint256 k;
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](per[t]);
            uint256 lo = t == 0 ? P / 2 : uint256(P) << (t - 1);
            for (uint256 j; j < per[t]; ++j) {
                uint128 ref = uint128(lo + j * (lo / 64));
                items[t][j] = ExpoGachaPool.Entitlement(
                    cols[k++ % nCols], 0, type(uint256).max, bytes32(0), ref, ref * 5 / 4, uint128(1) << (127 - j)
                );
            }
        }
        ExpoGachaPool.ConfigInput memory input = _input(items, P, _defaultOdds());
        _cool();
        uint256 g = gasleft();
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        used = g - gasleft();
        emit log_named_uint(
            string.concat("createConfig ", _str(total), " entries, ", _str(nCols), " collections"), used
        );
    }

    function test_CreateConfigGas() public {
        _createGas(10, 10);
        _createGas(10, 1);
        _createGas(40, 1);
        _createGas(40, 40);
        _createGas(128, 1);
        require(_createGas(128, 64) < 25_000_000, "maximum under 25M");
    }

    function _str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v > 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }

    function test_PreviewOpenGas() public {
        uint64 id = _grid([uint256(32), 32, 32, 32], 1);
        _setFree(1_000e6);
        _cool();
        uint256 g = gasleft();
        pool.previewOpen(id);
        uint256 used = g - gasleft();
        emit log_named_uint("previewOpen 4x32, every tier searched", used);
        require(used < 120_000, "previewOpen under 120k");
    }
}

// ==================================================================== launchpad (docs/46 7.6)

contract ExpoLaunchpadOddsTest is OddsBase {
    function _machineQuote(ExpoGachaPool.Entitlement[][4] memory items)
        internal
        returns (ExpoLaunchpad.Quote memory q)
    {
        q = _quote(items, 0, 10);
        q.priceUsdc = P;
        q.odds = _defaultOdds();
    }

    function test_EntitlementsHashBindsWeights() public {
        ExpoGachaPool.Entitlement[][4] memory items = _machineItems();
        ExpoLaunchpad.Quote memory q = _machineQuote(items);
        bytes memory sig = _sign(q, SIGNER_KEY);
        items[3][0].weight = 99; // still a valid configuration, but not the signed one
        ov.prank(CREATOR);
        ov.expectRevert(ExpoLaunchpad.BadSignature.selector);
        launchpad.launch(q, items, sig);
        items[3][0].weight = 100;
        ov.prank(CREATOR);
        uint64 id = launchpad.launch(q, items, sig);
        require(pool.tierWeight(id, 3) == 101, "signed weights stored");
    }

    function test_DomainVersion2() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = launchpad.eip712Domain();
        require(keccak256(bytes(name)) == keccak256("ExpoLaunchpad"), "name");
        require(keccak256(bytes(version)) == keccak256("2"), "EIP-712 domain version 2");
        require(chainId == block.chainid && verifying == address(launchpad), "domain");
        require(
            launchpad.QUOTE_TYPEHASH()
                == keccak256(
                    "Quote(address creator,bytes32 gachaId,uint128 priceUsdc,uint16[4] odds,bytes32 entitlementsHash,uint16 quickSellBps,uint32 settlementWindow,uint16 creatorFeeBps,uint32 maxOpen,bytes32 metadataHash,uint256 nonce,uint64 expiresAt)"
                ),
            "QUOTE_TYPEHASH unchanged"
        );
    }
}
