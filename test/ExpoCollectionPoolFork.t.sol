// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoCollectionPool, ICollectionAdmission} from "../src/ExpoCollectionPool.sol";
import {ExpoCollectionRegistry} from "../src/ExpoCollectionRegistry.sol";
import {ExpoLegacyVault} from "../src/ExpoLegacyVault.sol";
import {IRandomness} from "../src/ExpoPool.sol";
import {MockUSDC, MockRandomness} from "../src/MockAssets.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ForkVm {
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function createSelectFork(string calldata url) external returns (uint256);
    function createSelectFork(string calldata url, uint256 blockNumber) external returns (uint256);
    function skip(bool) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes4) external;
    function label(address, string calldata) external;
}

/// @dev Smart-contract wallet without onERC721Received.
contract ForkPlainWallet {
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory out) = target.call(data);
        require(ok, "call failed");
        return out;
    }
}

/// @notice docs/23 + docs/28 on a pinned Ethereum mainnet fork, against the real collection contracts.
/// Run with EXPO_FORK_RPC_URL (and EXPO_FORK_BLOCK to pin); skipped otherwise.
/// Acquisition is simulated by moving the token from its current holder into the vault: the marketplace
/// leg (Seaport order fulfillment into the vault) is NOT exercised here.
contract ExpoCollectionPoolForkTest {
    ForkVm constant vm = ForkVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant NFT_ART = bytes32("nft-art");

    address constant MILADY = 0x5Af0D9827E0c53E4799BB226655A1de152A425a5;
    address constant BAYC = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address constant PUDGY = 0xBd3531dA5CF5857e7CfAA92426877b022e612cf8;
    address constant AZUKI = 0xED5AF388653567Af2F388E6224dC7C4b3241C544;
    address constant ART_BLOCKS = 0xa7d8d9ef8D8Ce8992Df33D8b8CF4Aebabd5bD270;

    MockUSDC token;
    MockRandomness rng;
    ExpoLegacyVault vault;
    ExpoCollectionRegistry registry;
    ExpoCollectionPool pool;
    address operator = address(0x0FE7A70);
    uint256 requests;
    bool active;

    function setUp() public {
        string memory url = vm.envOr("EXPO_FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 blockNumber = vm.envOr("EXPO_FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNumber);
        active = true;

        token = new MockUSDC();
        rng = new MockRandomness();
        vault = new ExpoLegacyVault(address(this));
        registry = new ExpoCollectionRegistry(address(this), address(vault));
        pool = new ExpoCollectionPool(
            token, IRandomness(address(rng)), vault, ICollectionAdmission(address(registry)), operator, address(this)
        );
        vault.bindPool(address(pool));
        address[] memory list = new address[](5);
        (list[0], list[1], list[2], list[3], list[4]) = (MILADY, BAYC, PUDGY, AZUKI, ART_BLOCKS);
        for (uint256 i; i < list.length; ++i) {
            registry.reviewCompatibility(list[i], keccak256(abi.encode("docs/28 fork run", list[i])), uint64(block.timestamp + 7 days));
        }
        registry.setCollections(NFT_ART, list);
        token.mint(address(this), 1_000_000e6);
        token.approve(address(pool), type(uint256).max);
        pool.fund(500_000e6);
    }

    function _skipIfOffline() private returns (bool) {
        if (!active) vm.skip(true);
        return !active;
    }

    function _config(address collection, uint256 lo, uint256 hi) private returns (uint64) {
        uint16[4] memory odds = [uint16(10000), 0, 0, 0];
        ExpoCollectionPool.Entitlement[][4] memory items;
        items[0] = new ExpoCollectionPool.Entitlement[](1);
        items[0][0] = ExpoCollectionPool.Entitlement(collection, lo, hi, 5_000e6, 4_000e6);
        return pool.createConfig(NFT_ART, 50e6, odds, 9000, 1 days, keccak256(abi.encode("fork", collection, lo)), items);
    }

    /// @dev Opens, reveals and claims as `buyer`; works for EOAs and the plain contract wallet.
    function _claimAs(address buyer, uint64 cfg) private returns (uint256 id) {
        token.mint(buyer, 100e6);
        if (buyer.code.length == 0) {
            vm.startPrank(buyer);
            token.approve(address(pool), type(uint256).max);
            id = pool.open(cfg);
            vm.stopPrank();
        } else {
            ForkPlainWallet w = ForkPlainWallet(buyer);
            w.call(address(token), abi.encodeCall(token.approve, (address(pool), type(uint256).max)));
            id = abi.decode(w.call(address(pool), abi.encodeCall(pool.open, (cfg))), (uint256));
        }
        rng.fulfill(++requests, 12345);
        pool.finalize(id);
        if (buyer.code.length == 0) {
            vm.prank(buyer);
            pool.claimNFT(id);
        } else {
            ForkPlainWallet(buyer).call(address(pool), abi.encodeCall(pool.claimNFT, (id)));
        }
    }

    /// @dev Stand-in for the marketplace purchase: the current holder transfers the token into the vault.
    function _acquire(address collection, uint256 tokenId) private {
        address holder = IERC721(collection).ownerOf(tokenId);
        require(holder != address(vault), "already in vault");
        vm.prank(holder);
        IERC721(collection).transferFrom(holder, address(vault), tokenId);
        require(IERC721(collection).ownerOf(tokenId) == address(vault), "vault owns after acquisition");
    }

    function _deliverTo(address buyer, address collection, uint256 lo, uint256 hi, uint256 tokenId) private {
        uint64 cfg = _config(collection, lo, hi);
        uint256 id = _claimAs(buyer, cfg);
        _acquire(collection, tokenId);
        vm.prank(operator);
        pool.fulfill(id, tokenId);
        require(IERC721(collection).ownerOf(tokenId) == buyer, "recipient owns after delivery");
        (,, ExpoCollectionPool.State s,,,,,,) = pool.openings(id);
        require(s == ExpoCollectionPool.State.Delivered, "delivered");
    }

    function testMiladyToEOA() public {
        if (_skipIfOffline()) return;
        _deliverTo(address(0xA11CE), MILADY, 0, type(uint256).max, 1);
    }

    function testMiladyToContractWallet() public {
        if (_skipIfOffline()) return;
        _deliverTo(address(new ForkPlainWallet()), MILADY, 0, type(uint256).max, 2);
    }

    function testBaycToEOA() public {
        if (_skipIfOffline()) return;
        _deliverTo(address(0xB0B), BAYC, 0, type(uint256).max, 1);
    }

    function testBaycToContractWallet() public {
        if (_skipIfOffline()) return;
        _deliverTo(address(new ForkPlainWallet()), BAYC, 0, type(uint256).max, 2);
    }

    function testPudgyPenguinsToEOA() public {
        if (_skipIfOffline()) return;
        _deliverTo(address(0xC0C0A), PUDGY, 0, type(uint256).max, 1);
    }

    function testAzukiToEOA() public {
        if (_skipIfOffline()) return;
        _deliverTo(address(0xD0D0), AZUKI, 0, type(uint256).max, 1);
    }

    /// @notice Fidenza is project 78 on the shared Art Blocks contract: only its token range is eligible.
    function testFidenzaRangeOnSharedArtBlocksContract() public {
        if (_skipIfOffline()) return;
        uint256 lo = 78_000_000;
        uint256 hi = 78_999_999;
        uint64 cfg = _config(ART_BLOCKS, lo, hi);
        uint256 id = _claimAs(address(0xF1DE), cfg);
        _acquire(ART_BLOCKS, 13_000_109); // Ringers #109: same contract, project 13, outside the range
        vm.prank(operator);
        vm.expectRevert(ExpoCollectionPool.Invalid.selector);
        pool.fulfill(id, 13_000_109);
        _acquire(ART_BLOCKS, 78_000_457); // Fidenza #457
        vm.prank(operator);
        pool.fulfill(id, 78_000_457);
        require(IERC721(ART_BLOCKS).ownerOf(78_000_457) == address(0xF1DE), "Fidenza delivered");
        vault.recover(ART_BLOCKS, 13_000_109, address(this));
    }
}
