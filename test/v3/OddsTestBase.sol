// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExpoGachaPool, IAdmission} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoVault} from "../../src/ExpoVault.sol";
import {IRandomness} from "../../src/ExpoPool.sol";
import {MockNFT} from "../../src/MockAssets.sol";
import {V3Base} from "./ExpoGachaV3.t.sol";
import {AdvVm} from "./V3TestMocks.sol";

/// @dev Exposes the pool's internal item search so tests can drive it with chosen `r` values (docs/46 5.4).
contract ExpoGachaPoolHarness is ExpoGachaPool {
    constructor(
        IERC20 token,
        IRandomness provider,
        ExpoVault vault_,
        IAdmission registry_,
        address fulfiller,
        address admin,
        uint256 cap
    ) ExpoGachaPool(token, provider, vault_, registry_, fulfiller, admin, cap) {}

    function exposedPick(uint64 configId, uint8 tier, uint256 m, uint256 r) external view returns (uint256) {
        return _pick(configId, tier, m, r);
    }

    /// @dev Runs finalize's mapping `_draw` over the words keccak256(0..n-1) and counts the drawn tier-0 indices.
    function drawHistogram(uint64 configId, uint256 cover, uint256 n, uint256 size)
        external
        view
        returns (uint256[] memory hits)
    {
        hits = new uint256[](size);
        uint256 fmp;
        assembly ("memory-safe") {
            fmp := mload(0x40)
        }
        for (uint256 i; i < n; ++i) {
            (, uint256 index) = _draw(configId, cover, 1, uint256(keccak256(abi.encode(i))));
            hits[index]++;
            assembly ("memory-safe") {
                mstore(0x40, fmp) // drop the iteration's scratch allocations
            }
        }
    }
}

/// @dev Shared fixtures for the v3.2 suites (docs/46-machine-relative-odds-spec.md): machine-relative bands,
/// value-weighted draws, locked prizes and the opening snapshot. Written before the v3.2 implementation.
abstract contract OddsBase is V3Base {
    AdvVm constant ov = AdvVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint128 constant P = 100e6;
    MockNFT nftC;
    MockNFT nftD;

    function setUp() public virtual override {
        super.setUp();
        nftC = new MockNFT();
        nftD = new MockNFT();
        _admit(address(nftC));
        _admit(address(nftD));
        pool.proposeWithdrawCap(type(uint256).max);
        ov.warp(block.timestamp + 48 hours);
        pool.applyWithdrawCap();
        _admit(address(nftA)); // re-admit with a fresh expiry after the warp
        _admit(address(nftB));
    }

    // ------------------------------------------------------------ builders

    function _e(address col, uint128 ref, uint128 budget, uint128 weight)
        internal
        pure
        returns (ExpoGachaPool.Entitlement memory)
    {
        return ExpoGachaPool.Entitlement(col, 0, 1000, bytes32(0), ref, budget, weight);
    }

    function _input(ExpoGachaPool.Entitlement[][4] memory items, uint128 price, uint16[4] memory odds)
        internal
        pure
        returns (ExpoGachaPool.ConfigInput memory)
    {
        return ExpoGachaPool.ConfigInput(bytes32("odds"), price, odds, 9000, 1 days, keccak256("odds"), items);
    }

    /// @dev The reference machine of these suites, P = 100 (USDC, 6 decimals), four collections, budget = 1.25 × ref.
    /// Liabilities: Common 65 / 76.25 / 87.5 / 97.5, Uncommon 137.5 / 168.75, Rare 300 / 387.5, Epic 562.5 / 3,125.
    function _machineItems() internal view returns (ExpoGachaPool.Entitlement[][4] memory items) {
        items[0] = new ExpoGachaPool.Entitlement[](4);
        items[0][0] = _e(address(nftA), 52e6, 65e6, 1000);
        items[0][1] = _e(address(nftB), 61e6, 76.25e6, 600);
        items[0][2] = _e(address(nftA), 70e6, 87.5e6, 400);
        items[0][3] = _e(address(nftB), 78e6, 97.5e6, 250);
        items[1] = new ExpoGachaPool.Entitlement[](2);
        items[1][0] = _e(address(nftC), 110e6, 137.5e6, 100);
        items[1][1] = _e(address(nftC), 135e6, 168.75e6, 50);
        items[2] = new ExpoGachaPool.Entitlement[](2);
        items[2][0] = _e(address(nftD), 240e6, 300e6, 10);
        items[2][1] = _e(address(nftD), 310e6, 387.5e6, 5);
        items[3] = new ExpoGachaPool.Entitlement[](2);
        items[3][0] = _e(address(nftA), 450e6, 562.5e6, 100);
        items[3][1] = _e(address(nftC), 2500e6, 3125e6, 1);
    }

    function _defaultOdds() internal pure returns (uint16[4] memory) {
        return [uint16(7500), 2000, 400, 100];
    }

    function _machine() internal returns (uint64) {
        return pool.createConfig(_input(_machineItems(), P, _defaultOdds()), ExpoGachaPool.Kind.Etf, 1000);
    }

    /// @dev A machine with `perTier[t]` items per tier in band, spread over `nCols` admitted collections, weights
    /// 2^(127 - j) (steep enough that the expected value stays under the price at any size).
    function _grid(uint256[4] memory perTier, uint256 nCols) internal returns (uint64) {
        address[] memory cols = _collections(nCols);
        ExpoGachaPool.Entitlement[][4] memory items;
        uint256 k;
        uint16[4] memory odds = _defaultOdds();
        for (uint256 t; t < 4; ++t) {
            items[t] = new ExpoGachaPool.Entitlement[](perTier[t]);
            uint256 lo = t == 0 ? P / 2 : uint256(P) << (t - 1);
            uint256 step = t == 3 ? P : (lo / 129);
            for (uint256 j; j < perTier[t]; ++j) {
                uint128 ref = uint128(lo + j * step);
                items[t][j] = _e(cols[k++ % nCols], ref, ref * 5 / 4, uint128(1) << (127 - j));
            }
        }
        // Empty tiers give their odds to the next tier down (publish-time cascade, docs/46 3.2).
        for (uint256 t = 3; t > 0; --t) {
            if (perTier[t] == 0) {
                odds[t - 1] += odds[t];
                odds[t] = 0;
            }
        }
        return pool.createConfig(_input(items, P, odds), ExpoGachaPool.Kind.Etf, 1000);
    }

    MockNFT[] extra;

    function _collections(uint256 n) internal returns (address[] memory cols) {
        cols = new address[](n);
        for (uint256 i; i < n; ++i) {
            if (i >= extra.length) {
                MockNFT c = new MockNFT();
                _admit(address(c));
                extra.push(c);
            }
            cols[i] = address(extra[i]);
        }
    }

    // ------------------------------------------------------------ state helpers

    /// @dev Sets the free reserve to exactly `x` before the next opening (whose net price then adds to the cover).
    function _setFree(uint256 x) internal {
        uint256 free = pool.freeReserve();
        if (free > x) pool.withdraw(address(this), free - x);
        else if (free < x) pool.fund(x - free);
    }

    function _openWith(uint64 id, uint256 minCover) internal returns (uint256 o) {
        ov.prank(BUYER);
        o = pool.open(id, minCover);
    }

    function _drawWith(uint256 o, uint256 word) internal {
        rng.fulfill(rng.count(), word);
        pool.finalize(o);
    }

    function _op(uint256 id)
        internal
        view
        returns (ExpoGachaPool.State s, uint8 tier, uint16 index, uint96 liability, uint96 cover)
    {
        (,, s, tier, index,, liability, cover,,) = pool.openings(id);
    }

    function _liab(uint64 id, uint8 t, uint256 j) internal view returns (uint256) {
        ExpoGachaPool.Entitlement memory e = pool.entitlement(id, t, j);
        return e.referenceUsdc > e.budgetUsdc ? e.referenceUsdc : e.budgetUsdc;
    }

    function _sum(uint16[4] memory odds) internal pure returns (uint256) {
        return uint256(odds[0]) + odds[1] + odds[2] + odds[3];
    }
}
