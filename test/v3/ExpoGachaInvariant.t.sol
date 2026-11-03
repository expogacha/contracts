// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoGachaPool, IAdmission} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoAdmissionRegistry} from "../../src/v3/ExpoAdmissionRegistry.sol";
import {ExpoLaunchpad} from "../../src/v3/ExpoLaunchpad.sol";
import {ExpoVault} from "../../src/ExpoVault.sol";
import {deployTestVault} from "./VaultTestDeploy.sol";
import {IRandomness} from "../../src/ExpoPool.sol";
import {MockUSDC, MockNFT, MockRandomness} from "../../src/MockAssets.sol";

interface HandlerVm {
    function warp(uint256) external;
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function addr(uint256) external returns (address);
}

/// @dev Plays every role (owner, operator, buyer, launchpad creator) and drives random transitions across an ETF
/// and launchpad configurations, including revocation, launchpad cap changes, disabling and withdrawals.
contract GachaHandler {
    HandlerVm constant vm = HandlerVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant SIGNER_KEY = 0x5157;

    MockUSDC public token;
    MockNFT public nftA;
    MockNFT public nftB;
    MockRandomness public rng;
    ExpoVault public vault;
    ExpoAdmissionRegistry public registry;
    ExpoGachaPool public pool;
    ExpoLaunchpad public launchpad;
    uint256 nextToken = 1;
    uint256 nonce;

    constructor() {
        token = new MockUSDC();
        nftA = new MockNFT();
        nftB = new MockNFT();
        rng = new MockRandomness();
        vault = deployTestVault(address(this));
        registry = new ExpoAdmissionRegistry(address(this), address(vault));
        pool = new ExpoGachaPool(
            token,
            IRandomness(address(rng)),
            vault,
            IAdmission(address(registry)),
            address(this),
            address(this),
            5_000e6
        );
        vault.bindPool(address(pool));
        launchpad = new ExpoLaunchpad(pool, address(this), vm.addr(SIGNER_KEY), 25e6);
        pool.setConfigurator(address(launchpad));
        _admit();
        token.mint(address(this), 1e15);
        token.approve(address(pool), type(uint256).max);
        token.approve(address(launchpad), type(uint256).max);
        pool.fund(20_000e6);
        pool.createConfig(_input(), ExpoGachaPool.Kind.Etf, 40);
    }

    function _items() internal view returns (ExpoGachaPool.Entitlement[][4] memory items) {
        items[0] = new ExpoGachaPool.Entitlement[](2);
        items[0][0] = ExpoGachaPool.Entitlement(address(nftA), 0, type(uint256).max, bytes32(0), 40e6, 30e6, 1);
        items[0][1] = ExpoGachaPool.Entitlement(address(nftB), 0, type(uint256).max, bytes32(0), 35e6, 45e6, 1);
        items[1] = new ExpoGachaPool.Entitlement[](1);
        items[1][0] = ExpoGachaPool.Entitlement(address(nftA), 1, 1_000_000, bytes32(0), 55e6, 70e6, 1);
        items[2] = new ExpoGachaPool.Entitlement[](1);
        items[2][0] = ExpoGachaPool.Entitlement(address(nftB), 0, type(uint256).max, bytes32(0), 150e6, 160e6, 1);
        items[3] = new ExpoGachaPool.Entitlement[](1);
        items[3][0] = ExpoGachaPool.Entitlement(address(nftA), 0, type(uint256).max, bytes32(0), 300e6, 300e6, 1);
    }

    function _input() internal view returns (ExpoGachaPool.ConfigInput memory) {
        return ExpoGachaPool.ConfigInput(
            bytes32("etf"), 50e6, [uint16(7500), 2000, 400, 100], 9000, 1 days, keccak256("invariant-v3"), _items()
        );
    }

    function _admit() private {
        address[] memory list = new address[](2);
        list[0] = address(nftA);
        list[1] = address(nftB);
        bytes32[] memory evidence = new bytes32[](2);
        evidence[0] = keccak256("a");
        evidence[1] = keccak256("b");
        registry.admit(list, evidence, uint64(block.timestamp + 365 days));
    }

    function launch(uint16 fee, uint32 maxOpen) external {
        if (pool.configCount() >= 6) return;
        ExpoGachaPool.Entitlement[][4] memory items = _items();
        ExpoLaunchpad.Quote memory q = ExpoLaunchpad.Quote(
            address(this),
            bytes32("lp"),
            50e6,
            [uint16(7500), 2000, 400, 100],
            keccak256(abi.encode(items)),
            9000,
            1 days,
            fee % 301,
            maxOpen % 20 + 1,
            keccak256("lp-payload"),
            ++nonce,
            uint64(block.timestamp + 30 minutes)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, launchpad.quoteDigest(q));
        try launchpad.launch(q, items, abi.encodePacked(r, s, v)) {} catch {}
    }

    function open(uint256 seed) external {
        uint64 count = pool.configCount();
        if (pool.openingCount() >= 150 || count == 0) return;
        try pool.open(uint64(seed % count) + 1, 0) {} catch {}
    }

    function draw(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (,, ExpoGachaPool.State s,,,,,,,) = pool.openings(id);
        if (s == ExpoGachaPool.State.Pending) rng.fulfill(id, uint256(keccak256(abi.encode(seed))));
        else if (s == ExpoGachaPool.State.RandomReady) pool.finalize(id);
    }

    function settle(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (,, ExpoGachaPool.State s,,, uint64 deadline,,,,) = pool.openings(id);
        if (s == ExpoGachaPool.State.Revealed) {
            if (block.timestamp >= deadline) pool.compensate(id);
            else if (seed % 3 == 0) pool.quickSell(id);
            else pool.claimNFT(id);
        } else if (s == ExpoGachaPool.State.ClaimRequested) {
            if (block.timestamp >= deadline) return pool.compensate(id);
            ExpoGachaPool.Entitlement memory e = pool.awarded(id);
            uint256 tokenId = 1 + (nextToken++ % 1_000_000);
            MockNFT(e.collection).mint(address(vault), tokenId);
            pool.fulfill(id, tokenId, new bytes32[](0));
        }
    }

    function govern(uint256 seed) external {
        uint256 action = seed % 6;
        if (action == 0) {
            registry.revoke(seed % 2 == 0 ? address(nftA) : address(nftB));
        } else if (action == 1) {
            _admit();
        } else if (action == 2) {
            pool.setLaunchpadCapBps(uint16(seed % 2501));
        } else if (action == 3 && pool.configCount() > 0) {
            pool.setEnabled(uint64(seed % pool.configCount()) + 1, seed % 4 != 0);
        } else if (action == 4) {
            uint256 free = pool.freeReserve();
            if (free > 0) try pool.withdraw(address(this), seed % (free + 1)) {} catch {}
        } else if (pool.creatorBalance(address(this)) > 0) {
            pool.withdrawCreatorFees();
        }
    }

    function elapse(uint32 seconds_) external {
        vm.warp(block.timestamp + seconds_ % 2 days);
    }
}

contract ExpoGachaInvariantTest {
    GachaHandler handler;

    function setUp() public {
        handler = new GachaHandler();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    /// @dev The handler swallows failures with try/catch; prove its launch and launchpad openings really happen.
    function testHandlerReachesLaunchpadPaths() public {
        handler.launch(150, 4);
        ExpoGachaPool pool = handler.pool();
        require(pool.configCount() == 2, "launch went through");
        handler.open(1);
        require(
            pool.launchpadReserved() > 0 && pool.creatorBalance(address(handler)) == 7.5e5,
            "launchpad opening with 1.5% fee"
        );
    }

    /// @notice Invariants 1 to 4 and 7 of docs/33, with invariant 3 as restated by docs/41 (I-C1, I-C2).
    function invariantSolvencyCapsFeesAndDelivery() public view {
        ExpoGachaPool pool = handler.pool();
        require(handler.token().balanceOf(address(pool)) >= pool.reserved() + pool.creatorFeesOwed(), "solvent");
        require(pool.creatorFeesOwed() == pool.creatorBalance(address(handler)), "fees reconcile");
        uint256 total;
        uint256 launchpadTotal;
        uint32[16] memory undrawn;
        for (uint256 i = 1; i <= pool.openingCount(); i++) {
            (address buyer, uint64 configId, ExpoGachaPool.State state,,,, uint128 liability,,, uint256 tokenId) =
                pool.openings(i);
            (ExpoGachaPool.Kind kind,,,,,,,,,,,) = pool.configs(configId);
            total += liability;
            if (kind == ExpoGachaPool.Kind.Launchpad) launchpadTotal += liability;
            if (uint8(state) >= uint8(ExpoGachaPool.State.QuickSold)) {
                require(liability == 0, "terminal has no liability");
            } else if (uint8(state) <= uint8(ExpoGachaPool.State.RandomReady)) {
                undrawn[configId]++;
            }
            if (state == ExpoGachaPool.State.Delivered) {
                ExpoGachaPool.Entitlement memory e = pool.awarded(i);
                require(tokenId >= e.minTokenId && tokenId <= e.maxTokenId, "in committed range");
                require(MockNFT(e.collection).ownerOf(tokenId) == buyer, "buyer owns delivered token");
            }
        }
        require(total == pool.reserved(), "liabilities reconcile");
        require(launchpadTotal == pool.launchpadReserved() && launchpadTotal <= total, "launchpad share reconciles");
        for (uint64 c = 1; c <= pool.configCount(); c++) {
            (,,,,,,,, uint32 maxOpen, uint32 openNow,,) = pool.configs(c);
            require(openNow == undrawn[c] && openNow <= maxOpen, "per-configuration undrawn openings (docs/41)");
        }
    }
}
