// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoVault} from "../src/ExpoVault.sol";
import {deployTestVault} from "./v3/VaultTestDeploy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface MainnetForkVm {
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function createSelectFork(string calldata url, uint256 blockNumber) external returns (uint256);
    function skip(bool) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address, uint256) external;
    function expectRevert(bytes4) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function label(address, string calldata) external;
    function store(address target, bytes32 slot, bytes32 value) external;
}

// Seaport 1.6 types (enums encode as uint8).
struct OfferItem {
    uint8 itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    uint8 itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    uint8 orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

struct CriteriaResolver {
    uint256 orderIndex;
    uint8 side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

interface ISeaport16 {
    function validate(Order[] calldata orders) external returns (bool);
    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool);
}

struct CollectionSecurityPolicy {
    uint8 rulesetId;
    uint48 listId;
    address customRuleset;
    uint8 globalOptions;
    uint16 rulesetOptions;
    uint16 tokenType;
}

/// @dev Limit Break Creator Token Transfer Validator (modular rulesets), 0x721C008f… on mainnet.
interface ICreatorTokenValidator {
    function getCollectionSecurityPolicy(address collection) external view returns (CollectionSecurityPolicy memory);
    function validateTransferSim(address collection, address caller, address from, address to)
        external
        view
        returns (bool, bytes4);
    function validateTransfer(address caller, address from, address to) external;
    function createList(string calldata name) external returns (uint48);
    function addAccountsToList(uint48 id, uint8 listType, address[] calldata accounts) external;
    function applyListToCollection(address collection, uint48 id) external;
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
}

interface ICreatorToken {
    function getTransferValidator() external view returns (address);
}

interface IOwnable {
    function owner() external view returns (address);
}

interface IProxyAdminOwner {
    function owner() external view returns (address);
}

interface IOperatorFilterRegistry {
    function unsubscribe(address registrant, bool copyExistingEntries) external;
    function updateOperator(address registrant, address operator, bool filtered) external;
}

/// @dev Smart-contract wallet without onERC721Received (the vault delivers with transferFrom).
contract MainnetForkPlainWallet {
    function ping() external pure returns (bool) {
        return true;
    }
}

/// @dev Any marketplace or contract operator that is not on a collection's lists.
contract MainnetForkStrangerOperator {
    function move(address collection, address from, address to, uint256 tokenId) external {
        IERC721(collection).transferFrom(from, to, tokenId);
    }
}

/// @notice docs/23 admission fork test for the five prepared mainnet intra-collection gachas (docs/45).
///
/// Exact path exercised on a pinned Ethereum mainnet fork, with the real collection contracts and the real
/// Limit Break validator and OpenSea operator filter state at that block:
///  1. Acquisition: Seaport 1.6 `fulfillAdvancedOrder` with recipient = ExpoVault, the call
///     `contracts/script/seaport-acquirer.mjs` makes. The order is a real listing of the current holder,
///     made through the OpenSea conduit key, so the NFT moves `holder -> vault` with the OpenSea conduit as the
///     ERC-721 caller (exactly what a filled OpenSea listing does). It is validated on chain by the impersonated
///     holder instead of being signed and has no OpenSea signed zone: neither changes the token transfer.
///  2. Delivery: `ExpoVault.release` by its bound pool, so the collection sees `caller = from = vault`
///     (the call ExpoGachaPool.deliver makes), to an EOA and to a contract without a receiver hook.
/// ExpoVault is not deployed on mainnet; a fresh one is deployed on the fork, bound to this test contract as pool.
/// Negative controls tighten the real policies on the fork as the collection owner could, and require the same
/// path to fail; they prove the path is really gated by the validator / filter registry.
///
/// Every positive run first asserts the facts docs/45 records (validator, ruleset, list, options, Jirasan's
/// EIP-1967 implementation and ProxyAdmin, code hashes). A later block where any of them drifted fails instead of
/// passing on stale evidence; testPinnedStateCatchesDrift proves the check bites.
///
/// Run: EXPO_FORK_RPC_URL=<mainnet archive rpc> forge test --match-path test/ExpoMainnetGachaFork.t.sol -vv
/// EXPO_MAINNET_FORK_BLOCK overrides the pinned block. Skipped without EXPO_FORK_RPC_URL.
/// Keep the URL in the environment, never on the command line. A failing createSelectFork (bad URL, no archive
/// state, rate limit) can echo the full RPC URL, API key included, in forge's error output: do not paste such
/// output into issues, PRs, logs or chat.
contract ExpoMainnetGachaForkTest {
    MainnetForkVm constant vm = MainnetForkVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_address(string key, address val);
    event log_named_uint(string key, uint256 val);
    event log_named_bytes32(string key, bytes32 val);
    event log_named_string(string key, string val);

    uint256 constant PINNED_BLOCK = 26_327_265;

    address constant INVISIBLE_FRIENDS = 0x59468516a8259058baD1cA5F8f4BFF190d30E066;
    address constant JIRASAN = 0x7Fb2D396a3cc840f2c4213F044566ed400159b40;
    address constant IMAGINARY_ONES = 0x716F29B8972D551294d9E02B3eb0fC1107FbF4aA;
    address constant GENUINE_UNDEAD = 0xcD44Ef6b018fe6061CBb50C44aF94ce5f1cFc0B1;
    address constant BRAINROT = 0x38793a3FDfd098E820ddF59706280681354341fC;

    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    bytes32 constant OPENSEA_CONDUIT_KEY = 0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    address constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    address constant LB_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    address constant OPERATOR_FILTER_REGISTRY = 0x000000000000AAeB6D7670E522A718067333cd4E;
    bytes32 constant EIP1967_IMPLEMENTATION = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes4 constant OPERATOR_IS_BLACKLISTED = bytes4(keccak256("CreatorTokenTransferValidator__OperatorIsBlacklisted()"));
    bytes4 constant CALLER_OR_FROM_MUST_BE_WHITELISTED =
        bytes4(keccak256("CreatorTokenTransferValidator__CallerOrFromMustBeWhitelisted()"));
    bytes4 constant OTC_NOT_ALLOWED_FOR_SMART_WALLETS =
        bytes4(keccak256("CreatorTokenTransferValidator__OTCNotAllowedForSmartWallets()"));
    /// Genuine Undead wraps every validator refusal in its own error (the collection does, not Seaport).
    bytes4 constant VALIDATOR_CALL_FAILED = bytes4(keccak256("ValidatorCallFailed()"));
    /// OpenSea operator filter registry refusal.
    bytes4 constant ADDRESS_FILTERED = bytes4(keccak256("AddressFiltered(address)"));

    // Pinned facts at PINNED_BLOCK (docs/45). Drift in any of them invalidates the admission evidence.
    uint8 constant RULESET_BLACKLIST = 3;
    uint16 constant GENUINE_UNDEAD_RULESET_OPTIONS = 0;
    uint16 constant BRAINROT_RULESET_OPTIONS = 6;
    address constant JIRASAN_IMPLEMENTATION = 0x2DB0a76244Ba51F0F9440dA67Ffc68e772CE3143;
    address constant JIRASAN_PROXY_ADMIN = 0xB1a1Bdc9d9F0cf4f434D1b47E26F451C4c45E708;
    address constant JIRASAN_PROXY_ADMIN_OWNER = 0xAA621C4DeF4a23f587d660fA08894cca51b8e2DF;
    bytes32 constant EIP1967_ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant INVISIBLE_FRIENDS_CODEHASH = 0xc02f6b4fe37a8ef6dd56e2c69f1bfe872d00cd43e4cf3883b4e5a60c4089278b;
    bytes32 constant JIRASAN_PROXY_CODEHASH = 0x386a6e997380fb1794d8d5b6b4ec049f7c60a75704cda7fde1afbe6d6cc51d05;
    bytes32 constant JIRASAN_IMPLEMENTATION_CODEHASH = 0x357c408d0096d00ee794b23835527ed4f56079568e6c11307a9c2dd7f1348de0;
    bytes32 constant JIRASAN_PROXY_ADMIN_CODEHASH = 0xfdb374f62c5df71a60c5965707d6653c4910b1e309693a88263492ade756df11;
    bytes32 constant IMAGINARY_ONES_CODEHASH = 0x010c5f02ed3ced7857d96c4fabc88edfda187f88afd7da87b69ca357a07464bb;
    bytes32 constant GENUINE_UNDEAD_CODEHASH = 0xd9fc1c70bd21bed13fd3910973e35272f2830b2fd1efec12a76bdd51f64514ca;
    bytes32 constant BRAINROT_CODEHASH = 0xc540b4381651fe4ca54b19da3d008c82dafaddb8c2e4f891c9648e6c97e911a5;
    bytes32 constant LB_VALIDATOR_CODEHASH = 0xab56b0c7eb7fb035bd2d8b560fa3c52fca081af10a0f204c88e6074cb974f0ef;

    uint8 constant RULESET_WHITELIST = 4;
    uint8 constant LIST_TYPE_BLACKLIST = 0;

    ExpoVault vault;
    address operator = address(0x0FE7A70);
    address eoaRecipient = address(0xB0B0B0);
    MainnetForkPlainWallet walletRecipient;
    uint256 salt;
    bool active;

    function setUp() public {
        string memory url = vm.envOr("EXPO_FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, vm.envOr("EXPO_MAINNET_FORK_BLOCK", PINNED_BLOCK));
        active = true;
        vault = deployTestVault(address(this));
        vault.bindPool(address(this)); // stands in for ExpoGachaPool: only the caller of release() differs.
        walletRecipient = new MainnetForkPlainWallet();
        vm.deal(operator, 100 ether);
        vm.label(address(vault), "ExpoVault");
        vm.label(OPENSEA_CONDUIT, "OpenSeaConduit");
    }

    // ------------------------------------------------------------------ positive: the real policies today

    function testInvisibleFriendsAdmissionPath() public {
        _admit(INVISIBLE_FRIENDS, 2001, 1555);
    }

    function testJirasanAdmissionPath() public {
        _admit(JIRASAN, 7509, 2582);
    }

    function testImaginaryOnesAdmissionPath() public {
        _admit(IMAGINARY_ONES, 837, 8246);
    }

    function testGenuineUndeadAdmissionPath() public {
        _admit(GENUINE_UNDEAD, 3460, 6269);
    }

    function testBrainrotAdmissionPath() public {
        _admit(BRAINROT, 2815, 462);
    }

    // ------------------------------------------------------------------ negative controls

    /// The teammate's check: validateTransferSim accepts a stranger operator. That is the correct answer for a
    /// Blacklist ruleset with an empty list, and the real transfer agrees. Once the owner blacklists it, both the
    /// simulation and the real transfer refuse it, and so does the vault leg when the vault is blacklisted.
    function testGenuineUndeadBlacklistControl() public {
        _blacklistControl(GENUINE_UNDEAD, 3460, 6269, VALIDATOR_CALL_FAILED);
    }

    function testBrainrotBlacklistControl() public {
        _blacklistControl(BRAINROT, 2815, 462, OPERATOR_IS_BLACKLISTED);
    }

    /// What-if: the creator switches to the Whitelist ruleset (Limit Break's default) keeping its current options.
    function testGenuineUndeadWhitelistSwitch() public {
        _whitelistSwitch(GENUINE_UNDEAD, 3460, 6269, false, VALIDATOR_CALL_FAILED, VALIDATOR_CALL_FAILED);
    }

    function testBrainrotWhitelistSwitch() public {
        // BRAINROT already carries rulesetOptions 6 (OTC allowed for 7702 delegates and smart wallets).
        _whitelistSwitch(BRAINROT, 2815, 462, true, bytes4(0), CALLER_OR_FROM_MUST_BE_WHITELISTED);
    }

    /// Jirasan's implementation enforces the OpenSea operator filter registry (empty subscription today). The
    /// owner can filter the OpenSea conduit, which stops acquisition (and new approvals of it); owner-initiated
    /// vault delivery is exempt from the registry check.
    function testJirasanOperatorFilterControl() public {
        if (_skip()) return;
        uint256 first = 7509;
        uint256 second = 2582;
        _acquire(JIRASAN, first);
        (AdvancedOrder memory order, address holder,) = _listing(JIRASAN, second); // approved before the filter
        address owner = IOwnable(JIRASAN).owner();
        vm.startPrank(owner);
        IOperatorFilterRegistry(OPERATOR_FILTER_REGISTRY).unsubscribe(JIRASAN, false);
        IOperatorFilterRegistry(OPERATOR_FILTER_REGISTRY).updateOperator(JIRASAN, OPENSEA_CONDUIT, true);
        IOperatorFilterRegistry(OPERATOR_FILTER_REGISTRY).updateOperator(JIRASAN, address(vault), true);
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_FILTERED, OPENSEA_CONDUIT));
        ISeaport16(SEAPORT).fulfillAdvancedOrder{value: 0.01 ether}(
            order, new CriteriaResolver[](0), bytes32(0), address(vault)
        );
        _owned(JIRASAN, second, holder, "filtered conduit: unchanged");
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_FILTERED, OPENSEA_CONDUIT));
        IERC721(JIRASAN).setApprovalForAll(OPENSEA_CONDUIT, true);
        // from == msg.sender is never filtered by the registry pattern, so delivery still lands.
        vault.release(JIRASAN, first, eoaRecipient);
        _owned(JIRASAN, first, eoaRecipient, "filtered: vault delivery");
    }

    /// The pinned-state check is not decorative: a policy change, a list change or a proxy upgrade each fail it.
    function testPinnedStateCatchesDrift() public {
        if (_skip()) return;
        address[5] memory c = [INVISIBLE_FRIENDS, JIRASAN, IMAGINARY_ONES, GENUINE_UNDEAD, BRAINROT];
        for (uint256 i; i < c.length; ++i) {
            this.checkPinned(c[i]);
        }
        ICreatorTokenValidator v = ICreatorTokenValidator(LB_VALIDATOR);

        CollectionSecurityPolicy memory p = v.getCollectionSecurityPolicy(BRAINROT);
        vm.prank(IOwnable(BRAINROT).owner());
        v.setRulesetOfCollection(BRAINROT, RULESET_WHITELIST, address(0), p.globalOptions, p.rulesetOptions);
        vm.expectRevert(_reason("pinned: rulesetId drifted"));
        this.checkPinned(BRAINROT);

        vm.startPrank(IOwnable(GENUINE_UNDEAD).owner());
        uint48 listId = v.createList("expo-fork-drift");
        v.applyListToCollection(GENUINE_UNDEAD, listId);
        vm.stopPrank();
        vm.expectRevert(_reason("pinned: listId drifted"));
        this.checkPinned(GENUINE_UNDEAD);

        // An upgrade as the ProxyAdmin owner could make it: point the proxy at another implementation.
        vm.store(JIRASAN, EIP1967_IMPLEMENTATION, bytes32(uint256(uint160(address(vault)))));
        vm.expectRevert(_reason("pinned: Jirasan implementation drifted"));
        this.checkPinned(JIRASAN);
    }

    /// `validateTransfer(caller, from, to)` takes no collection argument: the validator applies the policy of
    /// msg.sender. Called by BRAINROT it accepts a stranger operator (Blacklist, empty list); the same arguments
    /// from any other account are judged under that account's (default) policy and are refused. Only
    /// validateTransferSim(collection, ...) answers for a collection when called off-chain or by Expo.
    function testValidateTransferReadsCallerPolicy() public {
        if (_skip()) return;
        ICreatorTokenValidator v = ICreatorTokenValidator(LB_VALIDATOR);
        address holder = IERC721(BRAINROT).ownerOf(2815);
        address stranger = address(new MainnetForkStrangerOperator());
        (bool simOk,) = v.validateTransferSim(BRAINROT, stranger, holder, address(vault));
        require(simOk, "sim: BRAINROT refuses stranger");

        vm.prank(BRAINROT);
        v.validateTransfer(stranger, holder, address(vault));

        vm.prank(eoaRecipient);
        vm.expectRevert(CALLER_OR_FROM_MUST_BE_WHITELISTED); // default policy: Whitelist ruleset, list 0
        v.validateTransfer(stranger, holder, address(vault));
    }

    /// Harness control for every collection: a stranger without approval cannot move a vault token, and a
    /// failed call leaves ownerOf on the vault (a reverted or lying call is never counted as delivery).
    function testStrangerCannotMoveVaultTokens() public {
        if (_skip()) return;
        address[5] memory c = [INVISIBLE_FRIENDS, JIRASAN, IMAGINARY_ONES, GENUINE_UNDEAD, BRAINROT];
        uint256[5] memory ids = [uint256(2001), 7509, 837, 3460, 2815];
        MainnetForkStrangerOperator stranger = new MainnetForkStrangerOperator();
        for (uint256 i; i < c.length; ++i) {
            _acquire(c[i], ids[i]);
            vm.expectRevert();
            stranger.move(c[i], address(vault), eoaRecipient, ids[i]);
            _owned(c[i], ids[i], address(vault), "stranger: still in vault");
            vm.prank(operator);
            vm.expectRevert(ExpoVault.Unauthorized.selector);
            vault.release(c[i], ids[i], eoaRecipient);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _admit(address collection, uint256 first, uint256 second) private {
        if (_skip()) return;
        _describe(collection);
        _acquire(collection, first);
        vault.release(collection, first, eoaRecipient);
        _owned(collection, first, eoaRecipient, "delivery to EOA");
        _acquire(collection, second);
        vault.release(collection, second, address(walletRecipient));
        _owned(collection, second, address(walletRecipient), "delivery to contract wallet");
    }

    function _blacklistControl(address collection, uint256 first, uint256 second, bytes4 refusal) private {
        if (_skip()) return;
        ICreatorTokenValidator v = ICreatorTokenValidator(LB_VALIDATOR);
        address holder = IERC721(collection).ownerOf(second);
        MainnetForkStrangerOperator stranger = new MainnetForkStrangerOperator();
        (bool simOk,) = v.validateTransferSim(collection, address(stranger), holder, address(vault));
        require(simOk, "sim: stranger refused under today's policy");

        _acquire(collection, first);

        address owner = IOwnable(collection).owner();
        vm.startPrank(owner);
        uint48 listId = v.createList("expo-fork-negative-control");
        address[] memory blocked = new address[](3);
        (blocked[0], blocked[1], blocked[2]) = (address(stranger), address(vault), OPENSEA_CONDUIT);
        v.addAccountsToList(listId, LIST_TYPE_BLACKLIST, blocked);
        v.applyListToCollection(collection, listId);
        vm.stopPrank();

        (simOk,) = v.validateTransferSim(collection, address(stranger), holder, address(vault));
        require(!simOk, "sim: blacklisted stranger accepted");
        vm.prank(holder);
        IERC721(collection).setApprovalForAll(address(stranger), true);
        vm.expectRevert(refusal);
        stranger.move(collection, holder, address(vault), second);
        _owned(collection, second, holder, "blacklisted stranger: unchanged");

        (simOk,) = v.validateTransferSim(collection, address(vault), address(vault), eoaRecipient);
        require(!simOk, "sim: blacklisted vault accepted");
        vm.expectRevert(refusal);
        vault.release(collection, first, eoaRecipient);
        _owned(collection, first, address(vault), "blacklisted vault: still in vault");

        _expectAcquireFails(collection, second, abi.encodePacked(refusal));
    }

    function _whitelistSwitch(
        address collection,
        uint256 first,
        uint256 second,
        bool deliveryExpected,
        bytes4 deliveryRefusal,
        bytes4 acquireRefusal
    ) private {
        if (_skip()) return;
        ICreatorTokenValidator v = ICreatorTokenValidator(LB_VALIDATOR);
        CollectionSecurityPolicy memory p = v.getCollectionSecurityPolicy(collection);
        _acquire(collection, first);
        vm.prank(IOwnable(collection).owner());
        v.setRulesetOfCollection(collection, RULESET_WHITELIST, address(0), p.globalOptions, p.rulesetOptions);

        if (deliveryExpected) {
            vault.release(collection, first, eoaRecipient);
            _owned(collection, first, eoaRecipient, "whitelist switch: delivery");
        } else {
            (bool simOk, bytes4 reason) = v.validateTransferSim(collection, address(vault), address(vault), eoaRecipient);
            require(!simOk && reason == OTC_NOT_ALLOWED_FOR_SMART_WALLETS, "sim: vault OTC accepted");
            vm.expectRevert(deliveryRefusal);
            vault.release(collection, first, eoaRecipient);
            _owned(collection, first, address(vault), "whitelist switch: stuck in vault");
        }
        // The OpenSea conduit is not on Limit Break's default whitelist (list 0).
        _expectAcquireFails(collection, second, abi.encodePacked(acquireRefusal));
    }

    function _acquire(address collection, uint256 tokenId) private {
        (AdvancedOrder memory order, address holder, uint256 price) = _listing(collection, tokenId);
        uint256 paidBefore = holder.balance;
        vm.prank(operator);
        ISeaport16(SEAPORT).fulfillAdvancedOrder{value: price}(order, new CriteriaResolver[](0), bytes32(0), address(vault));
        _owned(collection, tokenId, address(vault), "acquisition into vault");
        require(holder.balance == paidBefore + price, "seller not paid");
    }

    /// Expects the Seaport purchase into the vault to revert with `refusal`, the collection's own revert data.
    /// Seaport 1.6 and the OpenSea conduit bubble a token's revert data unchanged (checked on the fork for the
    /// validator errors, Genuine Undead's ValidatorCallFailed wrapper and the operator filter's AddressFiltered),
    /// so the exact refusal is asserted, not just any revert from Seaport.
    function _expectAcquireFails(address collection, uint256 tokenId, bytes memory refusal) private {
        (AdvancedOrder memory order, address holder,) = _listing(collection, tokenId);
        vm.prank(operator);
        vm.expectRevert(refusal);
        ISeaport16(SEAPORT).fulfillAdvancedOrder{value: 0.01 ether}(
            order, new CriteriaResolver[](0), bytes32(0), address(vault)
        );
        _owned(collection, tokenId, holder, "refused acquisition: unchanged");
    }

    /// The current holder lists `tokenId` for 0.01 ETH through the OpenSea conduit and validates the order on chain.
    function _listing(address collection, uint256 tokenId)
        private
        returns (AdvancedOrder memory order, address holder, uint256 price)
    {
        holder = IERC721(collection).ownerOf(tokenId);
        require(holder != address(vault), "already in vault");
        price = 0.01 ether;
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(2, collection, tokenId, 1, 1);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(0, address(0), 0, price, price, holder);
        OrderParameters memory params = OrderParameters(
            holder, address(0), offer, consideration, 0, block.timestamp - 1, block.timestamp + 1 hours, bytes32(0),
            ++salt, OPENSEA_CONDUIT_KEY, 1
        );
        Order[] memory orders = new Order[](1);
        orders[0] = Order(params, "");
        vm.startPrank(holder);
        if (!IERC721(collection).isApprovedForAll(holder, OPENSEA_CONDUIT)) {
            IERC721(collection).setApprovalForAll(OPENSEA_CONDUIT, true);
        }
        ISeaport16(SEAPORT).validate(orders);
        vm.stopPrank();
        order = AdvancedOrder(params, 1, 1, "", "");
    }

    function _owned(address collection, uint256 tokenId, address expected, string memory step) private view {
        require(IERC721(collection).ownerOf(tokenId) == expected, step);
    }

    /// External so a test can expect its revert (testPinnedStateCatchesDrift).
    function checkPinned(address collection) external {
        _describe(collection);
    }

    /// Logs the collection's transfer-relevant state and requires it to match the pinned docs/45 facts.
    function _describe(address collection) private {
        emit log_named_address("collection", collection);
        emit log_named_uint("fork block", block.number);
        emit log_named_bytes32("collection codehash", collection.codehash);
        address impl = address(uint160(uint256(_load(collection, EIP1967_IMPLEMENTATION))));
        emit log_named_address("eip1967 implementation", impl);
        if (impl != address(0)) emit log_named_bytes32("implementation codehash", impl.codehash);
        emit log_named_bytes32("vault codehash", address(vault).codehash);
        (bool ok, bytes memory out) = collection.staticcall(abi.encodeCall(ICreatorToken.getTransferValidator, ()));
        address validator = ok && out.length == 32 ? abi.decode(out, (address)) : address(0);
        emit log_named_address("transfer validator", validator);

        require(collection.codehash == _pinnedCodehash(collection), "pinned: collection codehash drifted");
        if (collection == JIRASAN) {
            require(impl == JIRASAN_IMPLEMENTATION, "pinned: Jirasan implementation drifted");
            require(impl.codehash == JIRASAN_IMPLEMENTATION_CODEHASH, "pinned: Jirasan implementation codehash drifted");
            address admin = address(uint160(uint256(_load(collection, EIP1967_ADMIN))));
            emit log_named_address("eip1967 admin", admin);
            require(admin == JIRASAN_PROXY_ADMIN, "pinned: Jirasan ProxyAdmin drifted");
            require(admin.codehash == JIRASAN_PROXY_ADMIN_CODEHASH, "pinned: Jirasan ProxyAdmin codehash drifted");
            address adminOwner = IProxyAdminOwner(admin).owner();
            emit log_named_address("ProxyAdmin owner", adminOwner);
            require(adminOwner == JIRASAN_PROXY_ADMIN_OWNER, "pinned: Jirasan ProxyAdmin owner drifted");
            require(adminOwner.code.length == 0, "pinned: Jirasan ProxyAdmin owner is no longer a plain EOA");
        } else {
            require(impl == address(0), "pinned: unexpected EIP-1967 implementation");
        }

        if (collection == GENUINE_UNDEAD || collection == BRAINROT) {
            require(validator == LB_VALIDATOR, "pinned: transfer validator drifted");
            require(validator.codehash == LB_VALIDATOR_CODEHASH, "pinned: validator codehash drifted");
            CollectionSecurityPolicy memory p = ICreatorTokenValidator(validator).getCollectionSecurityPolicy(collection);
            emit log_named_uint("rulesetId", p.rulesetId);
            emit log_named_uint("listId", p.listId);
            emit log_named_uint("globalOptions", p.globalOptions);
            emit log_named_uint("rulesetOptions", p.rulesetOptions);
            require(p.rulesetId == RULESET_BLACKLIST, "pinned: rulesetId drifted");
            require(p.listId == 0, "pinned: listId drifted");
            require(p.customRuleset == address(0), "pinned: customRuleset drifted");
            require(p.globalOptions == 0, "pinned: globalOptions drifted");
            require(
                p.rulesetOptions
                    == (collection == BRAINROT ? BRAINROT_RULESET_OPTIONS : GENUINE_UNDEAD_RULESET_OPTIONS),
                "pinned: rulesetOptions drifted"
            );
        } else {
            require(validator == address(0), "pinned: unexpected transfer validator");
        }
    }

    function _pinnedCodehash(address collection) private pure returns (bytes32) {
        if (collection == INVISIBLE_FRIENDS) return INVISIBLE_FRIENDS_CODEHASH;
        if (collection == JIRASAN) return JIRASAN_PROXY_CODEHASH;
        if (collection == IMAGINARY_ONES) return IMAGINARY_ONES_CODEHASH;
        if (collection == GENUINE_UNDEAD) return GENUINE_UNDEAD_CODEHASH;
        if (collection == BRAINROT) return BRAINROT_CODEHASH;
        revert("pinned: unknown collection");
    }

    function _load(address target, bytes32 slot) private view returns (bytes32 value) {
        (bool ok, bytes memory out) = address(uint160(uint256(keccak256("hevm cheat code")))).staticcall(
            abi.encodeWithSignature("load(address,bytes32)", target, slot)
        );
        require(ok, "load");
        value = abi.decode(out, (bytes32));
    }

    function _reason(string memory message) private pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }

    function _skip() private returns (bool) {
        if (!active) vm.skip(true);
        return !active;
    }
}
