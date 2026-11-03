// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoCollectionPool, ICollectionAdmission} from "../src/ExpoCollectionPool.sol";
import {ExpoCollectionRegistry} from "../src/ExpoCollectionRegistry.sol";
import {ExpoLegacyVault} from "../src/ExpoLegacyVault.sol";
import {IRandomness} from "../src/ExpoPool.sol";
import {MockUSDC, MockNFT, MockRandomness} from "../src/MockAssets.sol";

interface HandlerVm {
    function warp(uint256) external;
}

/// @dev Plays every role (buyer, operator, owner) and drives random transitions, including revocation.
contract CollectionHandler {
    HandlerVm constant vm = HandlerVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant NFT_ART = bytes32("nft-art");

    MockUSDC public token;
    MockNFT public nftA;
    MockNFT public nftB;
    MockRandomness public rng;
    ExpoLegacyVault public vault;
    ExpoCollectionRegistry public registry;
    ExpoCollectionPool public pool;
    uint256 nextToken = 1;

    constructor() {
        token = new MockUSDC();
        nftA = new MockNFT();
        nftB = new MockNFT();
        rng = new MockRandomness();
        vault = new ExpoLegacyVault(address(this));
        registry = new ExpoCollectionRegistry(address(this), address(vault));
        pool = new ExpoCollectionPool(
            token, IRandomness(address(rng)), vault, ICollectionAdmission(address(registry)), address(this), address(this)
        );
        vault.bindPool(address(pool));
        _admit();
        // Mixed tiers: reference above budget, budget above reference, and a bounded token range.
        uint16[4] memory odds = [uint16(6000), 3000, 900, 100];
        ExpoCollectionPool.Entitlement[][4] memory items;
        items[0] = new ExpoCollectionPool.Entitlement[](2);
        items[0][0] = ExpoCollectionPool.Entitlement(address(nftA), 0, type(uint256).max, 40e6, 30e6);
        items[0][1] = ExpoCollectionPool.Entitlement(address(nftB), 0, type(uint256).max, 35e6, 45e6);
        items[1] = new ExpoCollectionPool.Entitlement[](1);
        items[1][0] = ExpoCollectionPool.Entitlement(address(nftA), 1, 1_000_000, 90e6, 70e6);
        items[2] = new ExpoCollectionPool.Entitlement[](1);
        items[2][0] = ExpoCollectionPool.Entitlement(address(nftB), 0, type(uint256).max, 300e6, 320e6);
        items[3] = new ExpoCollectionPool.Entitlement[](1);
        items[3][0] = ExpoCollectionPool.Entitlement(address(nftA), 0, type(uint256).max, 900e6, 800e6);
        pool.createConfig(NFT_ART, 50e6, odds, 9000, 1 days, keccak256("invariant-v2"), items);
        token.mint(address(this), 1e15);
        token.approve(address(pool), type(uint256).max);
        pool.fund(20_000e6);
    }

    function _admit() private {
        address[] memory list = new address[](2);
        list[0] = address(nftA);
        list[1] = address(nftB);
        for (uint256 i; i < 2; ++i) registry.reviewCompatibility(list[i], keccak256(abi.encode(i)), uint64(block.timestamp + 365 days));
        registry.setCollections(NFT_ART, list);
    }

    function open() external {
        if (pool.openingCount() >= 120) return;
        try pool.open(1) {} catch {}
    }

    function draw(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (,, ExpoCollectionPool.State s,,,,,,) = pool.openings(id);
        if (s == ExpoCollectionPool.State.Pending) rng.fulfill(id, uint256(keccak256(abi.encode(seed))));
        else if (s == ExpoCollectionPool.State.RandomReady) pool.finalize(id);
    }

    function settle(uint256 seed) external {
        uint256 n = pool.openingCount();
        if (n == 0) return;
        uint256 id = seed % n + 1;
        (,, ExpoCollectionPool.State s, uint64 deadline,,,,,) = pool.openings(id);
        if (s == ExpoCollectionPool.State.Revealed) {
            if (block.timestamp >= deadline) pool.compensate(id);
            else if (seed % 3 == 0) pool.quickSell(id);
            else pool.claimNFT(id);
        } else if (s == ExpoCollectionPool.State.ClaimRequested) {
            if (block.timestamp >= deadline) return pool.compensate(id);
            ExpoCollectionPool.Entitlement memory e = pool.awarded(id);
            // Fresh, never-minted token inside the committed range (ranges here all contain 1..1,000,000).
            uint256 tokenId = 1 + (nextToken++ % 1_000_000);
            MockNFT(e.collection).mint(address(vault), tokenId); // acquisition into the vault
            pool.fulfill(id, tokenId);
        }
    }

    function revokeOrRestore(uint256 seed) external {
        address c = seed % 2 == 0 ? address(nftA) : address(nftB);
        if (seed % 5 == 0) registry.revokeCompatibility(c);
        else if (seed % 5 == 1) _admit();
    }

    function elapse(uint32 seconds_) external {
        vm.warp(block.timestamp + seconds_ % 2 days);
    }

    function withdraw(uint256 seed) external {
        uint256 free = pool.freeReserve();
        if (free > 0) pool.withdraw(address(this), seed % (free + 1));
    }
}

contract ExpoCollectionPoolInvariantTest {
    CollectionHandler handler;

    function setUp() public {
        handler = new CollectionHandler();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    /// @notice Invariants 1, 2, 3 and 4 of docs/28.
    function invariantSolvencyReconciliationAndDelivery() public view {
        ExpoCollectionPool pool = handler.pool();
        require(handler.token().balanceOf(address(pool)) >= pool.reserved(), "solvent");
        uint256 total;
        for (uint256 i = 1; i <= pool.openingCount(); i++) {
            (address buyer,, ExpoCollectionPool.State state,, uint128 liability,,,, uint256 tokenId) = pool.openings(i);
            total += liability;
            if (uint8(state) >= uint8(ExpoCollectionPool.State.QuickSold)) require(liability == 0, "terminal has no liability");
            if (state == ExpoCollectionPool.State.Delivered) {
                ExpoCollectionPool.Entitlement memory e = pool.awarded(i);
                require(tokenId >= e.minTokenId && tokenId <= e.maxTokenId, "in committed range");
                require(MockNFT(e.collection).ownerOf(tokenId) == buyer, "buyer owns delivered token");
            }
        }
        require(total == pool.reserved(), "liabilities reconcile");
    }
}
