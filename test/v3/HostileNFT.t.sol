// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ExpoGachaPool} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoAdmissionRegistry} from "../../src/v3/ExpoAdmissionRegistry.sol";
import {ExpoVault} from "../../src/ExpoVault.sol";
import {MockNFT} from "../../src/MockAssets.sol";
import {AdvBase} from "./ExpoGachaAdversarial.t.sol";
import {PlainWallet} from "./ExpoGachaV3.t.sol";
import {
    LiarNFT,
    SwapNFT,
    ReentrantHostileNFT,
    BombNFT,
    InterfaceLiar,
    PunksLike,
    Mock1155,
    Hybrid721And1155,
    RestrictedNFT,
    SoulboundNFT,
    CreatorValidatorMock,
    CreatorTokenNFT,
    OperatorFilterNFT,
    SolmateStyleNFT,
    LazyBatchNFT,
    RejectingWallet,
    SafeLikeWallet,
    DelegateAccount
} from "./HostileNFTMocks.sol";

/// @dev Hostile-collection audit (docs/47). Every test passes on the current contracts.
/// - `test_KnownIssue_*` pins a CURRENT, UNWANTED behaviour (a live finding of docs/47). It must fail, and be
///   inverted into a regression test, when the fix lands.
/// - `test_Hostile_*` proves a defence holds against a hostile collection.
/// - `test_Compat_*` proves a legitimate ERC-721 shape works end to end, or fails safe (no delivery, buyer
///   compensated, no other opening affected).
abstract contract HostileBase is AdvBase {
    uint128 constant REF = 40e6;
    uint128 constant BUDGET = 50e6;
    uint256 constant QUICK = 36e6; // REF * 9000 / 10000

    function _cfg(address c) internal returns (uint64) {
        _admit(c);
        return
            pool.createConfig(
                _input(_one(c, 0, type(uint256).max, bytes32(0), REF, BUDGET)), ExpoGachaPool.Kind.Etf, 100
            );
    }

    function _claimedBy(uint64 cfg, address buyer) internal returns (uint256 o) {
        usdc.mint(buyer, 100e6);
        hv.prank(buyer);
        usdc.approve(address(pool), type(uint256).max);
        hv.prank(buyer);
        o = pool.open(cfg, 0);
        _reveal(o);
        hv.prank(buyer);
        pool.claimNFT(o);
    }

    error UnexpectedRevert(bytes got, bytes want);

    function _tryFulfill(uint256 o, uint256 tokenId) internal returns (bool ok) {
        (ok,) = _fulfillResult(o, tokenId);
    }

    /// @dev Delivery outcome and, on failure, the exact revert data the operator's transaction would see.
    function _fulfillResult(uint256 o, uint256 tokenId) internal returns (bool ok, bytes memory err) {
        bytes32[] memory none = new bytes32[](0);
        hv.prank(OPERATOR);
        try pool.fulfill{gas: 5_000_000}(o, tokenId, none) {
            ok = true;
        } catch (bytes memory data) {
            err = data;
        }
    }

    /// @dev Delivery must fail with exactly `want` (a collection's own refusal is bubbled up unchanged).
    function _expectFulfillRevert(uint256 o, uint256 tokenId, bytes memory want) internal {
        (bool ok, bytes memory got) = _fulfillResult(o, tokenId);
        require(!ok, "delivery must fail");
        if (keccak256(got) != keccak256(want)) revert UnexpectedRevert(got, want);
    }

    function _reason(string memory message) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }

    function _compensateAfterDeadline(uint256 o, address buyer) internal returns (uint256 paid) {
        hv.warp(_deadline(o));
        uint256 before = usdc.balanceOf(buyer);
        pool.compensate(o);
        paid = usdc.balanceOf(buyer) - before;
    }

    /// @dev Delivery is refused with exactly `want`, the claim stays open, nobody is reimbursed, and after the
    /// deadline the buyer is compensated with the full reference. Returns the compensation.
    function _failsSafe(uint256 o, address buyer, uint256 tokenId, bytes memory want) internal returns (uint256 paid) {
        uint256 opBefore = usdc.balanceOf(OPERATOR);
        _expectFulfillRevert(o, tokenId, want);
        require(_state(o) == ExpoGachaPool.State.ClaimRequested, "claim still open");
        require(usdc.balanceOf(OPERATOR) == opBefore, "operator not reimbursed");
        paid = _compensateAfterDeadline(o, buyer);
        require(paid == REF, "buyer compensated with the full reference");
    }

    function _delivers(uint256 o, address buyer, address collection, uint256 tokenId) internal {
        uint256 opBefore = usdc.balanceOf(OPERATOR);
        require(_tryFulfill(o, tokenId), "delivery must succeed");
        require(_state(o) == ExpoGachaPool.State.Delivered, "delivered");
        require(MockNFT(collection).ownerOf(tokenId) == buyer, "buyer owns the token");
        require(usdc.balanceOf(OPERATOR) - opBefore == BUDGET, "operator reimbursed the budget");
    }

    /// @dev An EOA with an EIP-7702 delegation designator (0xef0100 || implementation).
    function _delegatedEoa(address eoa) internal returns (address) {
        hv.etch(eoa, abi.encodePacked(hex"ef0100", address(new DelegateAccount())));
        require(eoa.code.length == 23, "delegated EOA has 23 bytes of code");
        return eoa;
    }
}

// ==================================================================== live findings

contract HostileNFTKnownIssuesTest is HostileBase {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev docs/47 HN-1 (High, escalates docs/40 M-1). A proxy collection upgraded after admission to a lying
    /// implementation makes `fulfill` mark the opening Delivered and reimburse the operator while nothing moves:
    /// both `ownerOf` checks are answered by the collection itself. The buyer gets neither the NFT nor compensation.
    function test_KnownIssue_HN1_LyingUpgradeMarksDeliveredWithoutTransfer() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new MockNFT()), "");
        MockNFT token = MockNFT(address(proxy));
        uint64 cfg = _cfg(address(token));
        token.mint(address(vault), 1);
        uint256 o = _claimedBy(cfg, BUYER);
        hv.store(address(proxy), IMPL_SLOT, bytes32(uint256(uint160(address(new LiarNFT())))));
        require(registry.isAdmitted(address(token)), "still admitted");

        _delivers(o, BUYER, address(token), 1); // pool's view: delivered, buyer owns it
        require(LiarNFT(address(token)).realOwnerOf(1) == address(vault), "the token never left the vault");
        require(token.balanceOf(BUYER) == 0, "buyer holds nothing");
        hv.expectRevert(ExpoGachaPool.WrongState.selector);
        pool.compensate(o); // terminal: no compensation route remains
    }

    /// @dev docs/47 HN-1, without an upgrade: the same result from a malicious collection admitted directly
    /// (admission trusts ERC-165 plus an off-chain evidence digest).
    function test_KnownIssue_HN1_AdmittedLiarMarksDeliveredWithoutTransfer() public {
        LiarNFT liar = new LiarNFT();
        uint64 cfg = _cfg(address(liar));
        liar.mint(address(vault), 9);
        uint256 o = _claimedBy(cfg, BUYER);
        _delivers(o, BUYER, address(liar), 9);
        require(liar.realOwnerOf(9) == address(vault), "nothing moved");
    }

    /// @dev docs/47 HN-2 (Medium). Admission binds only the runtime code hash, not the transfer policy. An ERC721-C
    /// owner raising the security level, whitelisting, or swapping the validator after admission keeps the
    /// collection admitted; new openings are accepted and their deliveries fail into full-reference compensation.
    function test_KnownIssue_HN2_TransferPolicyChangeKeepsAdmission() public {
        CreatorValidatorMock validator = new CreatorValidatorMock();
        CreatorTokenNFT token = new CreatorTokenNFT(address(validator));
        uint64 cfg = _cfg(address(token));
        token.mint(address(vault), 1);
        uint256 o = _claimedBy(cfg, BUYER);
        bytes32 hashBefore = address(token).codehash;

        validator.setLevel(address(token), 1); // OTC disabled, the vault is not a whitelisted caller
        require(address(token).codehash == hashBefore && registry.isAdmitted(address(token)), "still admitted");
        _claimedBy(cfg, address(0xA11)); // new commitments still accepted
        _failsSafe(o, BUYER, 1, _reason("caller must be whitelisted"));

        token.setTransferValidator(address(new CreatorValidatorMock())); // a whole new validator: still admitted
        require(registry.isAdmitted(address(token)), "validator swap invisible to admission");
    }

    /// @dev docs/47 HN-3 (Medium, the PR #8 buyer-induced failure, re-verified on main). For a collection whose
    /// policy blocks receivers with code (ERC721-C level 2+, a common setting), a buyer who opens from a smart
    /// wallet or an EIP-7702 delegated EOA makes delivery impossible, then collects the FULL reference after the
    /// deadline instead of the Quick Sell amount, while Expo may already have bought the token.
    function test_KnownIssue_HN3_BuyerInducedDeliveryFailurePaysFullReference() public {
        CreatorValidatorMock validator = new CreatorValidatorMock();
        CreatorTokenNFT token = new CreatorTokenNFT(address(validator));
        validator.setLevel(address(token), 2);
        uint64 cfg = _cfg(address(token));

        // An EOA buyer is delivered.
        token.mint(address(vault), 1);
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 1);

        // A contract-wallet buyer: delivery fails, compensation pays REF (40) instead of Quick Sell (36).
        address wallet = address(new PlainWallet());
        token.mint(address(vault), 2);
        uint256 paid = _failsSafe(_claimedBy(cfg, wallet), wallet, 2, _reason("receiver has code"));
        require(paid == REF && paid > QUICK, "over-compensation versus Quick Sell");
        require(token.ownerOf(2) == address(vault), "Expo keeps the bought token");

        // An EIP-7702 delegated EOA is a "receiver with code" too.
        address eoa7702 = _delegatedEoa(address(0x7702));
        token.mint(address(vault), 3);
        _failsSafe(_claimedBy(cfg, eoa7702), eoa7702, 3, _reason("receiver has code"));
    }

    /// @dev docs/47 HN-3, variant: a collection that runs the receiver hook even on transferFrom, and a buyer
    /// contract whose hook rejects. Same over-compensation, chosen entirely by the buyer.
    function test_KnownIssue_HN3_RejectingReceiverHookPaysFullReference() public {
        RestrictedNFT token = new RestrictedNFT();
        token.setHookOnTransferFrom(true);
        uint64 cfg = _cfg(address(token));
        address wallet = address(new RejectingWallet());
        token.mint(address(vault), 1);
        _failsSafe(_claimedBy(cfg, wallet), wallet, 1, _reason("no NFTs here"));
    }

    /// @dev docs/47 HN-4, fixed by docs/48: a safeTransferFrom-only token cannot be delivered (the buyer is
    /// compensated), plain recover still fails, and recoverSafe moves it once no claim of the collection waits.
    function test_Hostile_HN4_RecoverSafeAfterClaimSettles() public {
        RestrictedNFT safeOnly = new RestrictedNFT();
        safeOnly.setSafeOnly(true);
        uint64 cfg = _cfg(address(safeOnly));
        safeOnly.mint(address(vault), 1);
        uint256 o = _claimedBy(cfg, BUYER);
        hv.expectRevert(abi.encodeWithSelector(ExpoVault.TokenOwed.selector, address(safeOnly)));
        vault.recoverSafe(address(safeOnly), 1, address(this));
        _failsSafe(o, BUYER, 1, _reason("safeTransferFrom only"));
        hv.expectRevert(bytes("safeTransferFrom only"));
        vault.recover(address(safeOnly), 1, address(this));
        vault.recoverSafe(address(safeOnly), 1, address(0xCAFE));
        require(safeOnly.ownerOf(1) == address(0xCAFE), "recovered");
    }

    /// @dev Residual HN-4: soulbound and vault-blacklisted tokens stay stranded on both recovery paths.
    function test_KnownIssue_HN4_SoulboundAndBlacklistedStayStranded() public {
        SoulboundNFT soul = new SoulboundNFT();
        soul.mint(address(vault), 1);
        hv.expectRevert(bytes("soulbound"));
        vault.recoverSafe(address(soul), 1, address(0xCAFE));
        RestrictedNFT blk = new RestrictedNFT();
        blk.mint(address(vault), 1);
        blk.setBlacklisted(address(vault), true);
        hv.expectRevert(bytes("blacklisted"));
        vault.recoverSafe(address(blk), 1, address(0xCAFE));
    }

    /// @dev docs/47 HN-5, fixed by docs/48: a review lives at most MAX_REVIEW_PERIOD (365 days).
    function test_Hostile_HN5_AdmissionExpiryIsBounded() public {
        address[] memory list = new address[](1);
        list[0] = address(nftA);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("evidence");
        hv.expectRevert(ExpoAdmissionRegistry.InvalidBatch.selector);
        registry.admit(list, evidence, type(uint64).max);
        hv.expectRevert(ExpoAdmissionRegistry.InvalidBatch.selector);
        registry.admit(list, evidence, uint64(block.timestamp + 365 days + 1));
        registry.admit(list, evidence, uint64(block.timestamp + 365 days));
    }

    /// @dev docs/47 HN-6 (Info). The on-chain gate is ERC-165 plus an owner digest: a contract that claims every
    /// interface and implements none is admitted (its deliveries then fail safe), and so is an ERC-721 that also
    /// claims ERC-1155. The fork evidence of docs/23 is the only real check.
    function test_KnownIssue_HN6_AdmissionTrustsErc165Only() public {
        InterfaceLiar liar = new InterfaceLiar();
        uint64 cfg = _cfg(address(liar));
        // It has no ownerOf at all: the pool's first ownerOf call reverts without data.
        _failsSafe(_claimedBy(cfg, BUYER), BUYER, 1, "");
        _admit(address(new Hybrid721And1155()));
    }

    /// @dev docs/47 HN-7 (Info). A collection controls its own ledger: when the vault moves one of its tokens it can
    /// also move any other token of the SAME collection out of the vault, and the pool's checks still pass. It cannot
    /// touch other collections (see test_Hostile_ReentrancyAndCrossCollectionTheftContained).
    function test_KnownIssue_HN7_CollectionCanDrainItsOwnTokensFromVault() public {
        SwapNFT token = new SwapNFT();
        uint64 cfg = _cfg(address(token));
        token.mint(address(vault), 1);
        token.mint(address(vault), 2);
        uint256 o = _claimedBy(cfg, BUYER);
        token.arm(2, 2, address(0xBAD));
        _delivers(o, BUYER, address(token), 1);
        require(token.ownerOf(2) == address(0xBAD), "the other vault token left with the delivery");
    }

    /// @dev docs/47 HN-8, fixed by docs/48: an EIP-7702 delegated EOA (code 0xef0100 ‖ address) could re-delegate,
    /// rewrite its ledger and delegate back with the same code hash; admit now refuses it.
    function test_Hostile_HN8_DelegatedEoaIsNotAdmitted() public {
        address eoa = address(0xE7702);
        hv.etch(eoa, abi.encodePacked(hex"ef0100", address(new MockNFT())));
        address[] memory list = new address[](1);
        list[0] = eoa;
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("evidence");
        hv.expectRevert(abi.encodeWithSelector(ExpoAdmissionRegistry.InvalidCollection.selector, eoa));
        registry.admit(list, evidence, uint64(block.timestamp + 30 days));
    }

    /// @dev docs/47 HN-9 (Medium, any collection). The claim window and the delivery window are the same deadline:
    /// a buyer who claims in the last second leaves the operator no time to buy and deliver, and is paid the full
    /// reference instead of the Quick Sell amount, with a perfectly standard ERC-721.
    function test_KnownIssue_HN9_LastSecondClaimForcesFullReference() public {
        uint64 cfg = _cfg(address(nftA));
        uint256 o = _open(cfg);
        _reveal(o);
        hv.warp(_deadline(o) - 1);
        hv.prank(BUYER);
        pool.claimNFT(o);
        hv.warp(_deadline(o));
        nftA.mint(address(vault), 1); // even a token already in the vault is too late
        _expectFulfillRevert(o, 1, abi.encodeWithSelector(ExpoGachaPool.Expired.selector)); // delivery window closed
        uint256 before = usdc.balanceOf(BUYER);
        pool.compensate(o);
        require(usdc.balanceOf(BUYER) - before == REF && REF > QUICK, "full reference, not Quick Sell");
    }
}

// ==================================================================== defences that hold

contract HostileNFTDefencesTest is HostileBase {
    /// @dev Every state-changing route back into the pool or vault from inside the vault's transfer fails, and so
    /// does pulling another collection's token out of the vault; the guarded opening still settles afterwards.
    function test_Hostile_ReentrancyAndCrossCollectionTheftContained() public {
        uint64 cfgA = _cfg(address(nftA));
        uint256 victim = _claimedBy(cfgA, BUYER);
        nftA.mint(address(vault), 7);
        hv.warp(block.timestamp + 23 hours);

        ReentrantHostileNFT bad = new ReentrantHostileNFT();
        uint64 cfgBad = _cfg(address(bad));
        address attacker = address(0xBAD);
        uint256 o = _claimedBy(cfgBad, attacker);
        bad.mint(address(vault), 1);
        hv.warp(block.timestamp + 2 hours); // the victim's deadline has passed, the attacker's has not
        bad.arm(address(pool), address(vault), address(nftA), victim, 7);

        _delivers(o, attacker, address(bad), 1);
        require(bad.attempts() == 9 && bad.successes() == 0, "no re-entry or cross-collection call succeeded");
        require(nftA.ownerOf(7) == address(vault), "other collection untouched");
        require(_state(victim) == ExpoGachaPool.State.ClaimRequested, "victim untouched");
        require(_compensateAfterDeadline(victim, BUYER) == REF, "only the guard blocked compensate");
    }

    /// @dev A transfer that moves a different token than the one requested is caught by the post-delivery check.
    function test_Hostile_WrongTokenMovedIsRejected() public {
        SwapNFT token = new SwapNFT();
        uint64 cfg = _cfg(address(token));
        token.mint(address(vault), 1);
        token.mint(address(vault), 2);
        uint256 o = _claimedBy(cfg, BUYER);
        token.arm(1, 2, address(0));
        _failsSafe(o, BUYER, 1, abi.encodeWithSelector(ExpoGachaPool.Invalid.selector));
    }

    /// @dev Gas-burning and revert-bomb collections only fail their own delivery (no try/catch anywhere in the
    /// settlement path, so 63/64 tricks cannot turn a failed transfer into a success). The revert-data copy costs
    /// the operator a bounded multiple of what the bomb costs the collection.
    function test_Hostile_GasAndRevertBombsFailSafe() public {
        BombNFT bomb = new BombNFT();
        uint64 cfg = _cfg(address(bomb));
        bomb.mint(address(vault), 1);
        bomb.mint(address(vault), 2);
        bomb.arm(1, 0);
        _failsSafe(_claimedBy(cfg, BUYER), BUYER, 1, ""); // out of gas: no revert data
        bomb.arm(2, 200_000);
        uint256 o = _claimedBy(cfg, BUYER);
        uint256 g = gasleft();
        (bool ok, bytes memory err) = _fulfillResult(o, 2);
        require(!ok && err.length == 200_000, "revert bomb fails and its data is bubbled unchanged");
        require(g - gasleft() < 1_000_000, "200 kB revert bomb costs the operator < 1M gas");
    }

    /// @dev A return-data bomb on a successful transfer is not copied by the vault's typed call (no return values
    /// declared), so delivery succeeds at near-normal cost.
    function test_Hostile_ReturnBombOnSuccessDelivers() public {
        BombNFT bomb = new BombNFT();
        uint64 cfg = _cfg(address(bomb));
        bomb.mint(address(vault), 1);
        bomb.mint(address(vault), 2);
        uint256 o = _claimedBy(cfg, BUYER);
        uint256 g = gasleft();
        _delivers(o, BUYER, address(bomb), 1);
        uint256 normal = g - gasleft();
        bomb.arm(3, 200_000); // the bomb costs the collection ~95k gas of its own memory
        o = _claimedBy(cfg, BUYER);
        g = gasleft();
        _delivers(o, BUYER, address(bomb), 2);
        uint256 bombed = g - gasleft();
        // A copy into the vault's memory would add another ~95k; the extra stays at the callee's own cost.
        require(bombed - normal < 130_000, "return data is not copied by the vault");
    }

    /// @dev `open`, `finalize`, `quickSell` and `compensate` never call a collection, so a collection that
    /// implements nothing cannot block openings of a basket that contains it, nor other settlements.
    function test_Hostile_CollectionCannotBlockOpeningsOrOtherSettlements() public {
        InterfaceLiar dead = new InterfaceLiar();
        _admit(address(dead));
        ExpoGachaPool.Entitlement[][4] memory items;
        items[0] = new ExpoGachaPool.Entitlement[](2); // two equal Commons, drawn 50/50 by weight
        items[0][0] = ExpoGachaPool.Entitlement(address(nftA), 0, 1000, bytes32(0), REF, BUDGET, 1);
        items[0][1] = ExpoGachaPool.Entitlement(address(dead), 0, 1000, bytes32(0), REF, BUDGET, 1);
        ExpoGachaPool.ConfigInput memory input = _input(items);
        uint64 cfg = pool.createConfig(input, ExpoGachaPool.Kind.Etf, 100);
        for (uint256 i; i < 6; ++i) {
            uint256 o = _open(cfg);
            _reveal(o);
            ExpoGachaPool.Entitlement memory e = pool.awarded(o);
            if (e.collection == address(dead)) {
                hv.prank(BUYER);
                pool.quickSell(o); // never touches the collection
            } else {
                hv.prank(BUYER);
                pool.claimNFT(o);
                nftA.mint(address(vault), 100 + i);
                _delivers(o, BUYER, address(nftA), 100 + i);
            }
        }
    }

    /// @dev ERC-1155 is unsupported and fails closed: a pure ERC-1155 is refused at admission, and the vault cannot
    /// receive ERC-1155 tokens at all (no onERC1155Received), so no ERC-1155 purchase into the vault can succeed.
    function test_Hostile_Erc1155RefusedAtAdmissionAndByVault() public {
        Mock1155 multi = new Mock1155();
        address[] memory list = new address[](1);
        list[0] = address(multi);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("evidence");
        hv.expectRevert(abi.encodeWithSelector(ExpoAdmissionRegistry.InvalidCollection.selector, address(multi)));
        registry.admit(list, evidence, uint64(block.timestamp + 1 days));
        address holder = address(0x1155);
        multi.mint(holder, 1, 5);
        hv.prank(holder);
        hv.expectRevert(abi.encodeWithSignature("ERC1155InvalidReceiver(address)", address(vault)));
        multi.safeTransferFrom(holder, address(vault), 1, 1, "");
    }

    /// @dev Raw CryptoPunks-style contracts (no ERC-165, no ownerOf) are refused; only an ERC-721 wrapper can be
    /// admitted.
    function test_Hostile_PunksStyleRefused() public {
        PunksLike punks = new PunksLike();
        address[] memory list = new address[](1);
        list[0] = address(punks);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("evidence");
        hv.expectRevert(abi.encodeWithSelector(ExpoAdmissionRegistry.InvalidCollection.selector, address(punks)));
        registry.admit(list, evidence, uint64(block.timestamp + 1 days));
    }

    /// @dev The operator cannot be bypassed by the collection, and the buyer cannot redirect delivery.
    function test_Hostile_OnlyOperatorAndOnlyBuyer() public {
        uint64 cfg = _cfg(address(nftA));
        nftA.mint(address(vault), 1);
        uint256 o = _claimedBy(cfg, BUYER);
        hv.prank(address(nftA));
        hv.expectRevert(ExpoGachaPool.Unauthorized.selector);
        pool.fulfill(o, 1, new bytes32[](0));
        hv.prank(address(nftA));
        hv.expectRevert();
        vault.release(address(nftA), 1, address(nftA));
    }
}

// ==================================================================== compatibility matrix

contract HostileNFTCompatibilityTest is HostileBase {
    function test_Compat_SolmateStyleWorks() public {
        SolmateStyleNFT token = new SolmateStyleNFT();
        uint64 cfg = _cfg(address(token));
        token.mint(address(vault), type(uint256).max);
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), type(uint256).max);
    }

    function test_Compat_Erc721aLazyOwnershipWorks() public {
        LazyBatchNFT token = new LazyBatchNFT();
        uint64 cfg = _cfg(address(token));
        token.mintBatch(address(0xD00D), 3); // 0..2 elsewhere
        token.mintBatch(address(vault), 5); // 3..7 in the vault, only slot 3 written
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 5); // middle of the batch
        require(token.ownerOf(6) == address(vault) && token.ownerOf(7) == address(vault), "rest of batch intact");
        require(token.ownerOf(4) == address(vault) && token.ownerOf(2) == address(0xD00D), "neighbours intact");
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 7); // last of the batch
        uint256 o = _claimedBy(cfg, BUYER);
        hv.prank(OPERATOR);
        hv.expectRevert(bytes("OwnerQueryForNonexistentToken"));
        pool.fulfill(o, 8, new bytes32[](0)); // not yet minted
    }

    function test_Compat_OperatorFilterRegistryWorks() public {
        OperatorFilterNFT token = new OperatorFilterNFT();
        token.setFiltered(address(vault), true); // even a filtered vault: the owner moving its own token is exempt
        uint64 cfg = _cfg(address(token));
        token.mint(address(vault), 1);
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 1);
    }

    function test_Compat_Erc721cLevels() public {
        CreatorValidatorMock v = new CreatorValidatorMock();
        CreatorTokenNFT token = new CreatorTokenNFT(address(v));
        uint64 cfg = _cfg(address(token));
        for (uint256 i = 1; i <= 7; ++i) {
            token.mint(address(vault), i);
        }
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 1); // level 0

        v.setLevel(address(token), 1); // OTC disabled
        _failsSafe(_claimedBy(cfg, BUYER), BUYER, 2, _reason("caller must be whitelisted")); // vault not whitelisted: fails safe
        v.setWhitelisted(address(token), address(vault), true);
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 3); // vault whitelisted: works

        v.setLevel(address(token), 2); // no receivers with code
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 4);
        address safe = address(new SafeLikeWallet());
        _failsSafe(_claimedBy(cfg, safe), safe, 5, _reason("receiver has code"));

        v.setLevel(address(token), 3); // verified EOAs only
        address fresh = address(0xE0A);
        _failsSafe(_claimedBy(cfg, fresh), fresh, 6, _reason("receiver not verified"));
        v.verify(fresh);
        _delivers(_claimedBy(cfg, fresh), fresh, address(token), 7);
    }

    function test_Compat_PausableBlacklistRoyaltyFailSafe() public {
        RestrictedNFT token = new RestrictedNFT();
        uint64 cfg = _cfg(address(token));
        for (uint256 i = 1; i <= 5; ++i) {
            token.mint(address(vault), i);
        }
        token.setPaused(true);
        _failsSafe(_claimedBy(cfg, BUYER), BUYER, 1, _reason("paused"));
        token.setPaused(false);
        vault.recover(address(token), 1, address(this)); // recoverable once unpaused

        token.setBlacklisted(address(vault), true);
        _failsSafe(_claimedBy(cfg, BUYER), BUYER, 2, _reason("blacklisted"));
        token.setBlacklisted(address(vault), false);

        token.setBlacklisted(address(0xB1), true); // a blacklisted winner
        _failsSafe(_claimedBy(cfg, address(0xB1)), address(0xB1), 3, _reason("blacklisted"));

        token.setCallerWhitelistOnly(true); // royalty enforcement: only approved marketplaces may move tokens
        _failsSafe(_claimedBy(cfg, BUYER), BUYER, 4, _reason("caller not allowed"));
        token.setCallerWhitelist(address(vault), true);
        _delivers(_claimedBy(cfg, BUYER), BUYER, address(token), 5);
    }

    /// @dev Soulbound (ERC-5192) tokens cannot be acquired into the vault: the purchase transfer itself reverts.
    function test_Compat_SoulboundCannotBeAcquired() public {
        SoulboundNFT soul = new SoulboundNFT();
        soul.mint(address(this), 1);
        hv.expectRevert(bytes("soulbound"));
        soul.transferFrom(address(this), address(vault), 1);
    }

    function test_Compat_ProxiesWork() public {
        MockNFT uups = MockNFT(address(new ERC1967Proxy(address(new MockNFT()), "")));
        uint64 c1 = _cfg(address(uups));
        uups.mint(address(vault), 1);
        _delivers(_claimedBy(c1, BUYER), BUYER, address(uups), 1);

        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new MockNFT()), address(this));
        MockNFT bp = MockNFT(address(new BeaconProxy(address(beacon), "")));
        uint64 c2 = _cfg(address(bp));
        bp.mint(address(vault), 2);
        _delivers(_claimedBy(c2, BUYER), BUYER, address(bp), 2);
    }

    /// @dev ownerOf reverting for a burned token makes delivery fail safe.
    function test_Compat_BurnedTokenFailsSafe() public {
        uint64 cfg = _cfg(address(nftA));
        _failsSafe(_claimedBy(cfg, BUYER), BUYER, 404, abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 404));
    }

    /// @dev The vault uses transferFrom, so contract recipients without onERC721Received, Safe-like wallets,
    /// rejecting hooks and EIP-7702 delegated EOAs all receive a standard ERC-721.
    function test_Compat_RecipientClassesWithStandardErc721() public {
        uint64 cfg = _cfg(address(nftA));
        address[4] memory buyers = [
            address(new PlainWallet()),
            address(new SafeLikeWallet()),
            address(new RejectingWallet()),
            _delegatedEoa(address(0x7702))
        ];
        for (uint256 i; i < 4; ++i) {
            nftA.mint(address(vault), 10 + i);
            _delivers(_claimedBy(cfg, buyers[i]), buyers[i], address(nftA), 10 + i);
        }
    }
}
