// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoGachaPool, IAdmission} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoAdmissionRegistry} from "../../src/v3/ExpoAdmissionRegistry.sol";
import {ExpoLaunchpad} from "../../src/v3/ExpoLaunchpad.sol";
import {ExpoVault} from "../../src/ExpoVault.sol";
import {deployTestVault} from "./VaultTestDeploy.sol";
import {IRandomness} from "../../src/ExpoPool.sol";
import {MockUSDC, MockNFT, MockRandomness} from "../../src/MockAssets.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function addr(uint256) external returns (address);
    function etch(address, bytes calldata) external;
}

/// @dev Tries to re-enter the pool while the vault transfers it.
contract ReentrantNFT is ERC721 {
    ExpoGachaPool public pool;
    uint256 public target;
    bool public reentryBlocked;

    constructor() ERC721("Reentrant", "RE") {}

    function arm(ExpoGachaPool p, uint256 openingId) external {
        pool = p;
        target = openingId;
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (address(pool) != address(0)) {
            try pool.compensate(target) {}
            catch {
                reentryBlocked = true;
            }
        }
        super.transferFrom(from, to, id);
    }
}

/// @dev Smart-contract wallet without onERC721Received.
contract PlainWallet {
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory out) = target.call(data);
        require(ok, "call failed");
        return out;
    }
}

contract V3Base {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant SIGNER_KEY = 0xA11CE;
    address constant OPERATOR = address(0xBEEF);
    address constant BUYER = address(0xB0B);
    address constant CREATOR = address(0xC0FFEE);

    MockUSDC usdc;
    MockRandomness rng;
    ExpoVault vault;
    ExpoAdmissionRegistry registry;
    ExpoGachaPool pool;
    ExpoLaunchpad launchpad;
    MockNFT nftA;
    MockNFT nftB;
    uint256 nonce;

    function setUp() public virtual {
        usdc = new MockUSDC();
        rng = new MockRandomness();
        vault = deployTestVault(address(this));
        registry = new ExpoAdmissionRegistry(address(this), address(vault));
        pool = new ExpoGachaPool(
            usdc, IRandomness(address(rng)), vault, IAdmission(address(registry)), OPERATOR, address(this), 1_000_000e6
        );
        vault.bindPool(address(pool));
        launchpad = new ExpoLaunchpad(pool, address(this), vm.addr(SIGNER_KEY), 25e6);
        pool.setConfigurator(address(launchpad));
        nftA = new MockNFT();
        nftB = new MockNFT();
        _admit(address(nftA));
        _admit(address(nftB));
        usdc.mint(address(this), 10_000_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.fund(1_000_000e6);
        usdc.mint(BUYER, 1_000_000e6);
        vm.prank(BUYER);
        usdc.approve(address(pool), type(uint256).max);
        usdc.mint(CREATOR, 1_000e6);
        vm.prank(CREATOR);
        usdc.approve(address(launchpad), type(uint256).max);
    }

    function _admit(address c) internal {
        address[] memory list = new address[](1);
        list[0] = c;
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256(abi.encode("evidence", c));
        registry.admit(list, evidence, uint64(block.timestamp + 30 days));
    }

    /// @dev One Common tier on `collection`, reference 40, budget 50 (liability 50).
    function _items(address collection, bytes32 root)
        internal
        pure
        returns (ExpoGachaPool.Entitlement[][4] memory items)
    {
        items[0] = new ExpoGachaPool.Entitlement[](1);
        items[0][0] = ExpoGachaPool.Entitlement(collection, 0, 1000, root, 40e6, 50e6, 1);
    }

    function _input(ExpoGachaPool.Entitlement[][4] memory items)
        internal
        pure
        returns (ExpoGachaPool.ConfigInput memory)
    {
        return ExpoGachaPool.ConfigInput(
            bytes32("gacha"), 50e6, [uint16(10000), 0, 0, 0], 9000, 1 days, keccak256("payload"), items
        );
    }

    function _etf(uint32 maxOpen) internal returns (uint64) {
        return pool.createConfig(_input(_items(address(nftA), bytes32(0))), ExpoGachaPool.Kind.Etf, maxOpen);
    }

    function _quote(ExpoGachaPool.Entitlement[][4] memory items, uint16 feeBps, uint32 maxOpen)
        internal
        returns (ExpoLaunchpad.Quote memory q)
    {
        q = ExpoLaunchpad.Quote(
            CREATOR,
            bytes32("launch"),
            50e6,
            [uint16(10000), 0, 0, 0],
            keccak256(abi.encode(items)),
            9000,
            1 days,
            feeBps,
            maxOpen,
            keccak256("launch-payload"),
            ++nonce,
            uint64(block.timestamp + 30 minutes)
        );
    }

    function _sign(ExpoLaunchpad.Quote memory q, uint256 key) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, launchpad.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _launch(uint16 feeBps, uint32 maxOpen) internal returns (uint64 id) {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory q = _quote(items, feeBps, maxOpen);
        bytes memory sig = _sign(q, SIGNER_KEY);
        vm.prank(CREATOR);
        id = launchpad.launch(q, items, sig);
    }

    function _open(uint64 configId) internal returns (uint256 id) {
        vm.prank(BUYER);
        id = pool.open(configId, 0);
    }

    function _reveal(uint256 id) internal {
        rng.fulfill(rng.count(), uint256(keccak256(abi.encode(id))));
        pool.finalize(id);
    }

    function _claimed(uint64 configId) internal returns (uint256 id) {
        id = _open(configId);
        _reveal(id);
        vm.prank(BUYER);
        pool.claimNFT(id);
    }

    function _state(uint256 id) internal view returns (ExpoGachaPool.State s) {
        (,, s,,,,,,,) = pool.openings(id);
    }

    function _openNow(uint64 id) internal view returns (uint32 n) {
        (,,,,,,,,, n,,) = pool.configs(id);
    }
}

contract ExpoAdmissionRegistryTest is V3Base {
    function testAdmissionExpiryRevocationAndCodeBinding() public {
        require(registry.isAdmitted(address(nftA)), "admitted");
        vm.warp(block.timestamp + 31 days);
        require(!registry.isAdmitted(address(nftA)), "expired");
        _admit(address(nftA));
        registry.revoke(address(nftA));
        require(!registry.isAdmitted(address(nftA)), "revoked");
        _admit(address(nftA));
        vm.etch(address(nftA), hex"00");
        require(!registry.isAdmitted(address(nftA)), "collection code changed");
    }

    function testVaultCodeChangeRevokesEveryAdmission() public {
        vm.etch(address(vault), hex"00");
        require(!registry.isAdmitted(address(nftB)), "vault code changed");
    }

    function testRejectsBadInputs() public {
        address[] memory list = new address[](1);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = bytes32(uint256(1));
        list[0] = address(usdc);
        vm.expectRevert(abi.encodeWithSelector(ExpoAdmissionRegistry.InvalidCollection.selector, address(usdc)));
        registry.admit(list, evidence, uint64(block.timestamp + 1 days));
        list[0] = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(ExpoAdmissionRegistry.InvalidCollection.selector, address(0x1234)));
        registry.admit(list, evidence, uint64(block.timestamp + 1 days));
        list[0] = address(nftA);
        evidence[0] = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(ExpoAdmissionRegistry.InvalidCollection.selector, address(nftA)));
        registry.admit(list, evidence, uint64(block.timestamp + 1 days));
        address[] memory many = new address[](65);
        bytes32[] memory manyEvidence = new bytes32[](65);
        vm.expectRevert(ExpoAdmissionRegistry.InvalidBatch.selector);
        registry.admit(many, manyEvidence, uint64(block.timestamp + 1 days));
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", BUYER));
        registry.revoke(address(nftA));
    }
}

contract ExpoGachaPoolTest is V3Base {
    function testConfigurationPaths() public {
        ExpoGachaPool.ConfigInput memory input = _input(_items(address(nftA), bytes32(0)));
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Launchpad, 10);
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", BUYER));
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
        vm.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.createLaunchpadConfig(input, CREATOR, 100, 10);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 0);
        // Intra-collection: every entitlement needs a token root, and only one collection.
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(input, ExpoGachaPool.Kind.Collection, 10);
        ExpoGachaPool.Entitlement[][4] memory two;
        two[0] = new ExpoGachaPool.Entitlement[](2);
        two[0][0] = ExpoGachaPool.Entitlement(address(nftA), 0, 9, bytes32(uint256(1)), 40e6, 50e6, 1);
        two[0][1] = ExpoGachaPool.Entitlement(address(nftB), 0, 9, bytes32(uint256(2)), 40e6, 50e6, 1);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.createConfig(_input(two), ExpoGachaPool.Kind.Collection, 10);
        registry.revoke(address(nftA));
        vm.expectRevert(abi.encodeWithSelector(ExpoGachaPool.NotAdmitted.selector, address(nftA)));
        pool.createConfig(input, ExpoGachaPool.Kind.Etf, 10);
    }

    /// @dev docs/41 change 2: `maxOpen` caps openings waiting for their draw; the slot frees at the reveal, while the
    /// revealed opening's liability stays reserved until it settles.
    function testPerConfigurationCapFreesOnReveal() public {
        uint64 id = _etf(1);
        uint256 first = _open(id);
        vm.prank(BUYER);
        vm.expectRevert(ExpoGachaPool.CapReached.selector);
        pool.open(id, 0);
        _reveal(first);
        require(_openNow(id) == 0 && pool.reserved() == 50e6, "slot released at reveal, liability still reserved");
        uint256 second = _open(id);
        require(_openNow(id) == 1 && pool.reserved() == 100e6, "second opening alongside the revealed one");
        vm.prank(BUYER);
        pool.quickSell(first);
        require(_openNow(id) == 1 && pool.reserved() == 50e6, "settlement does not touch the slot count");
        _reveal(second);
        require(_openNow(id) == 0, "slot released");
    }

    function testLaunchpadCapBlocksLaunchesWhileEtfContinues() public {
        uint64 etf = _etf(100);
        uint64 lp = _launch(0, 100);
        // 0.01% of ~1,000,000 USDC is ~100 USDC: two launchpad openings of 50 fit, the third does not.
        pool.setLaunchpadCapBps(1);
        _open(lp);
        _open(lp);
        vm.prank(BUYER);
        vm.expectRevert(ExpoGachaPool.NothingDrawable.selector); // the cap room is the cover: no Common fits
        pool.open(lp, 0);
        _open(etf);
        require(pool.launchpadReserved() == 100e6 && pool.reserved() == 150e6, "launchpad share tracked");
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.setLaunchpadCapBps(2501);
    }

    function testCreatorFeesAccrueAndAreNeverOwnerFunds() public {
        uint64 lp = _launch(300, 100);
        _open(lp);
        _open(lp);
        require(pool.creatorBalance(CREATOR) == 3e6 && pool.creatorFeesOwed() == 3e6, "3% of two 50 USDC openings");
        pool.proposeWithdrawCap(10_000_000e6);
        vm.warp(block.timestamp + 48 hours);
        pool.applyWithdrawCap();
        uint256 free = pool.freeReserve();
        pool.withdraw(address(this), free);
        require(pool.freeReserve() == 0, "owner took only free reserve");
        uint256 before = usdc.balanceOf(CREATOR);
        vm.prank(CREATOR);
        pool.withdrawCreatorFees();
        require(usdc.balanceOf(CREATOR) - before == 3e6 && pool.creatorFeesOwed() == 0, "creator paid");
        vm.prank(CREATOR);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.withdrawCreatorFees();
        vm.prank(BUYER);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.withdrawCreatorFees();
    }

    function testCreatorDisablesOnlyItsOwnLaunch() public {
        uint64 lp = _launch(0, 100);
        uint64 etf = _etf(10);
        uint256 opened = _open(lp);
        vm.prank(BUYER);
        vm.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.setEnabled(lp, false);
        vm.prank(CREATOR);
        vm.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.setEnabled(etf, false);
        vm.prank(CREATOR);
        pool.setEnabled(lp, false);
        vm.prank(CREATOR);
        vm.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.setEnabled(lp, true);
        vm.prank(BUYER);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.open(lp, 0);
        // An opening made before the launch was disabled still settles.
        _reveal(opened);
        vm.prank(BUYER);
        pool.quickSell(opened);
        require(_state(opened) == ExpoGachaPool.State.QuickSold, "settled after disable");
    }

    function testWithdrawalWindowAndDelayedCapIncrease() public {
        pool.proposeWithdrawCap(100e6);
        pool.withdraw(address(this), 60e6);
        vm.expectRevert(ExpoGachaPool.CapReached.selector);
        pool.withdraw(address(this), 50e6);
        vm.warp(block.timestamp + 24 hours);
        pool.withdraw(address(this), 50e6);
        pool.proposeWithdrawCap(500e6);
        require(pool.withdrawCap() == 100e6, "increase is not immediate");
        vm.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.applyWithdrawCap();
        vm.warp(block.timestamp + 48 hours);
        pool.applyWithdrawCap();
        require(pool.withdrawCap() == 500e6, "increase applied after delay");
    }

    function testRevocationBlocksNewOpenings() public {
        uint64 id = _etf(10);
        registry.revoke(address(nftA));
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(ExpoGachaPool.NotAdmitted.selector, address(nftA)));
        pool.open(id, 0);
    }

    // ------------------------------------------------------------ frozen token sets (intra-collection)

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Four-leaf tree over tokens 1..4 of `collection`; returns the root and the proof for token 2.
    function _tree(address collection) internal view returns (bytes32 root, bytes32[] memory proof2) {
        bytes32[4] memory l;
        for (uint256 i; i < 4; ++i) {
            l[i] = pool.tokenLeaf(collection, i + 1);
        }
        bytes32 n34 = _pair(l[2], l[3]);
        root = _pair(_pair(l[0], l[1]), n34);
        proof2 = new bytes32[](2);
        proof2[0] = l[0];
        proof2[1] = n34;
    }

    function testMerkleDeliveryAcceptsOnlyTheFrozenSet() public {
        (bytes32 root, bytes32[] memory proof) = _tree(address(nftA));
        uint64 id = pool.createConfig(_input(_items(address(nftA), root)), ExpoGachaPool.Kind.Collection, 10);
        uint256 o = _claimed(id);
        nftA.mint(address(vault), 2);
        nftA.mint(address(vault), 7);
        bytes32[] memory empty = new bytes32[](0);
        vm.prank(OPERATOR);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 7, proof);
        vm.prank(OPERATOR);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 2, empty);
        bytes32[] memory forged = new bytes32[](2);
        forged[0] = keccak256("forged");
        forged[1] = proof[1];
        vm.prank(OPERATOR);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 2, forged);
        vm.prank(OPERATOR);
        pool.fulfill(o, 2, proof);
        require(nftA.ownerOf(2) == BUYER && _state(o) == ExpoGachaPool.State.Delivered, "delivered from the set");
    }

    function testProofForAnotherCollectionFails() public {
        (bytes32 rootA, bytes32[] memory proofA) = _tree(address(nftA));
        // A gacha on nftB whose root was built from nftA's leaves: the same token ID must not pass.
        uint64 id = pool.createConfig(_input(_items(address(nftB), rootA)), ExpoGachaPool.Kind.Collection, 10);
        uint256 o = _claimed(id);
        nftB.mint(address(vault), 2);
        vm.prank(OPERATOR);
        vm.expectRevert(ExpoGachaPool.Invalid.selector);
        pool.fulfill(o, 2, proofA);
    }

    function testReentrantCollectionAndPlainWalletDelivery() public {
        ReentrantNFT bad = new ReentrantNFT();
        _admit(address(bad));
        uint64 id = pool.createConfig(_input(_items(address(bad), bytes32(0))), ExpoGachaPool.Kind.Etf, 10);
        uint256 o = _claimed(id);
        bad.mint(address(vault), 5);
        bad.arm(pool, o);
        vm.prank(OPERATOR);
        pool.fulfill(o, 5, new bytes32[](0));
        require(bad.reentryBlocked() && bad.ownerOf(5) == BUYER, "reentry blocked, delivered");

        PlainWallet wallet = new PlainWallet();
        usdc.mint(address(wallet), 1_000e6);
        wallet.call(
            address(usdc), abi.encodeWithSignature("approve(address,uint256)", address(pool), type(uint256).max)
        );
        uint64 etf = _etf(10);
        uint256 w = abi.decode(
            wallet.call(address(pool), abi.encodeWithSelector(ExpoGachaPool.open.selector, etf, 0)), (uint256)
        );
        _reveal(w);
        wallet.call(address(pool), abi.encodeWithSelector(ExpoGachaPool.claimNFT.selector, w));
        nftA.mint(address(vault), 9);
        vm.prank(OPERATOR);
        pool.fulfill(w, 9, new bytes32[](0));
        require(nftA.ownerOf(9) == address(wallet), "contract wallet without hook received");
    }
}

contract ExpoLaunchpadTest is V3Base {
    function testLaunchChargesFeeAndRecordsCreator() public {
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint64 id = _launch(250, 7);
        (ExpoGachaPool.Kind kind, address creator,,,,,, uint16 fee, uint32 maxOpen,,, bool enabled) = pool.configs(id);
        require(
            kind == ExpoGachaPool.Kind.Launchpad && creator == CREATOR && fee == 250 && maxOpen == 7 && enabled,
            "launch config"
        );
        require(
            usdc.balanceOf(address(pool)) - poolBefore == 25e6 && usdc.balanceOf(CREATOR) == 975e6,
            "25 USDC creation fee"
        );
    }

    function testCreationFeeIsSetAtDeploymentAndNeverZero() public {
        ExpoLaunchpad other = new ExpoLaunchpad(pool, address(this), vm.addr(SIGNER_KEY), 1e15);
        require(other.CREATION_FEE() == 1e15 && launchpad.CREATION_FEE() == 25e6, "fee per deployment");
        vm.expectRevert(ExpoLaunchpad.Invalid.selector);
        new ExpoLaunchpad(pool, address(this), vm.addr(SIGNER_KEY), 0);
    }

    function testQuoteChecks() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory q = _quote(items, 100, 10);
        bytes memory sig = _sign(q, SIGNER_KEY);
        // Wrong submitter.
        vm.prank(BUYER);
        vm.expectRevert(ExpoLaunchpad.Unauthorized.selector);
        launchpad.launch(q, items, sig);
        // Any altered field breaks the signature.
        q.priceUsdc = 1e6;
        vm.prank(CREATOR);
        vm.expectRevert(ExpoLaunchpad.BadSignature.selector);
        launchpad.launch(q, items, sig);
        q.priceUsdc = 50e6;
        // Entitlements altered after signing.
        ExpoGachaPool.Entitlement[][4] memory other = _items(address(nftB), bytes32(0));
        vm.prank(CREATOR);
        vm.expectRevert(ExpoLaunchpad.BadSignature.selector);
        launchpad.launch(q, other, sig);
        // The valid launch, then its replay.
        vm.prank(CREATOR);
        launchpad.launch(q, items, sig);
        vm.prank(CREATOR);
        vm.expectRevert(ExpoLaunchpad.Used.selector);
        launchpad.launch(q, items, sig);
    }

    function testExpiryRotationFeeCapAndAdmission() public {
        ExpoGachaPool.Entitlement[][4] memory items = _items(address(nftA), bytes32(0));
        ExpoLaunchpad.Quote memory q = _quote(items, 100, 10);
        bytes memory sig = _sign(q, SIGNER_KEY);
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(CREATOR);
        vm.expectRevert(ExpoLaunchpad.Expired.selector);
        launchpad.launch(q, items, sig);

        q = _quote(items, 100, 10);
        sig = _sign(q, SIGNER_KEY);
        launchpad.setQuoteSigner(vm.addr(0xB0B0));
        vm.prank(CREATOR);
        vm.expectRevert(ExpoLaunchpad.BadSignature.selector);
        launchpad.launch(q, items, sig);
        launchpad.setQuoteSigner(vm.addr(SIGNER_KEY));

        q = _quote(items, 301, 10);
        sig = _sign(q, SIGNER_KEY);
        vm.prank(CREATOR);
        vm.expectRevert(ExpoLaunchpad.Invalid.selector);
        launchpad.launch(q, items, sig);

        registry.revoke(address(nftA));
        q = _quote(items, 100, 10);
        sig = _sign(q, SIGNER_KEY);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ExpoGachaPool.NotAdmitted.selector, address(nftA)));
        launchpad.launch(q, items, sig);
    }
}
