// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExpoGachaPool, IAdmission} from "../../src/v3/ExpoGachaPool.sol";
import {ExpoAdmissionRegistry} from "../../src/v3/ExpoAdmissionRegistry.sol";
import {ExpoVault} from "../../src/ExpoVault.sol";
import {ExpoLegacyVault} from "../../src/ExpoLegacyVault.sol";
import {IRandomness} from "../../src/ExpoPool.sol";
import {MockNFT} from "../../src/MockAssets.sol";
import {ExpoVaultDeployment} from "../../script/ExpoVaultDeployment.sol";
import {V3Base} from "./ExpoGachaV3.t.sol";
import {TEST_PROXY_ADMIN_OWNER} from "./VaultTestDeploy.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface UpgradeVm {
    function prank(address) external;
    function warp(uint256) external;
    function load(address, bytes32) external view returns (bytes32);
    function etch(address, bytes calldata) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
}

/// @dev A next vault release: same storage, one appended namespace, a reinitializer migration (docs/48 upgrade rules).
contract ExpoVaultV2Mock is ExpoVault {
    /// @custom:storage-location erc7201:expogacha.storage.ExpoVaultV2Mock
    struct V2Storage {
        uint256 migrated;
    }

    bytes32 private constant V2_LOCATION = keccak256("expogacha.test.ExpoVaultV2Mock");

    function migrate(uint256 value) external reinitializer(2) {
        _v2().migrated = value;
    }

    function migrated() external view returns (uint256) {
        return _v2().migrated;
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function _v2() private pure returns (V2Storage storage $) {
        bytes32 slot = V2_LOCATION;
        assembly {
            $.slot := slot
        }
    }
}

/// @dev A malicious release: hands every token to whoever asks and claims the old implementation (docs/48 threat model).
contract ExpoVaultDrainer is ExpoVault {
    address public immutable fakeImplementation;

    constructor(address fake) {
        fakeImplementation = fake;
    }

    function drain(address collection, uint256 tokenId, address to) external {
        ERC721(collection).transferFrom(address(this), to, tokenId);
    }
}

/// @dev A collection that refuses plain `transferFrom` and only moves tokens through `safeTransferFrom` (HN-4).
contract SafeOnlyNFT is ERC721 {
    bool private inSafe;

    constructor() ERC721("Safe only", "SAFE") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function transferFrom(address from, address to, uint256 id) public override {
        require(inSafe, "safe transfers only");
        super.transferFrom(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override {
        inSafe = true;
        super.safeTransferFrom(from, to, id, data);
        inSafe = false;
    }
}

contract Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract ExpoVaultUpgradeTest is V3Base {
    UpgradeVm constant uvm = UpgradeVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant OWNABLE_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
    bytes32 constant OWNABLE2STEP_SLOT = 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00;
    address constant SAFE = TEST_PROXY_ADMIN_OWNER;
    address constant STRANGER = address(0xBAD);

    ProxyAdmin proxyAdmin;
    address implementation;

    function setUp() public override {
        super.setUp();
        proxyAdmin = ProxyAdmin(ExpoVaultDeployment.proxyAdminOf(address(vault)));
        implementation = vault.implementation();
    }

    function _upgrade(address to, bytes memory data) internal {
        uvm.prank(SAFE);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), to, data);
    }

    function _deliver(uint256 id, uint256 tokenId) internal {
        uvm.prank(OPERATOR);
        pool.fulfill(id, tokenId, new bytes32[](0));
    }

    // ------------------------------------------------------------ initialization (V-1)

    function test_ImplementationCannotBeInitialized() public {
        uvm.expectRevert(Initializable.InvalidInitialization.selector);
        ExpoVault(implementation).initialize(STRANGER);
        require(ExpoVault(implementation).owner() == address(0), "implementation has no owner");
        require(uint256(uvm.load(implementation, INITIALIZABLE_SLOT)) == type(uint64).max, "initializers disabled");
    }

    function test_ProxyCannotBeInitializedTwice() public {
        uvm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(STRANGER);
        uvm.prank(STRANGER);
        uvm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(STRANGER);
        require(vault.owner() == address(this), "owner unchanged");
    }

    function test_InitializeRejectsZeroOwner() public {
        address impl = address(new ExpoVault());
        uvm.expectRevert(ExpoVault.Invalid.selector);
        new TransparentUpgradeableProxy(impl, SAFE, abi.encodeCall(ExpoVault.initialize, (address(0))));
        uvm.expectRevert(ExpoVaultDeployment.InvalidParameter.selector);
        this.deployExternal(address(0), SAFE);
        uvm.expectRevert(ExpoVaultDeployment.InvalidParameter.selector);
        this.deployExternal(address(this), address(0));
    }

    function deployExternal(address owner, address admin) external returns (ExpoVault) {
        return ExpoVaultDeployment.deploy(owner, admin).vault;
    }

    /// @dev The deployment path initializes inside the proxy's constructor: once it returns, nobody can initialize.
    function test_DeploymentPathLeavesNoFrontRunWindow() public {
        ExpoVaultDeployment.Deployed memory d = ExpoVaultDeployment.deploy(address(this), SAFE);
        require(uint256(uvm.load(address(d.vault), INITIALIZABLE_SLOT)) == 1, "initialized in deployment");
        require(d.vault.owner() == address(this), "owner set atomically");
        uvm.prank(STRANGER);
        uvm.expectRevert(Initializable.InvalidInitialization.selector);
        d.vault.initialize(STRANGER);
    }

    // ------------------------------------------------------------ upgrade authority (V-2)

    function test_ProxyAdminIsOwnedBySafe() public view {
        require(address(uint160(uint256(uvm.load(address(vault), ADMIN_SLOT)))) == address(proxyAdmin), "admin");
        require(proxyAdmin.owner() == SAFE, "ProxyAdmin owner is the Safe");
        require(address(uint160(uint256(uvm.load(address(vault), IMPLEMENTATION_SLOT)))) == implementation, "impl");
    }

    function test_OnlyProxyAdminOwnerCanUpgrade() public {
        address next = address(new ExpoVaultV2Mock());
        address[3] memory callers = [address(this), address(pool), STRANGER];
        for (uint256 i; i < callers.length; ++i) {
            uvm.prank(callers[i]);
            uvm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), next, "");
        }
        // Calling the proxy directly is forwarded to the implementation, which has no upgrade function.
        address[2] memory direct = [SAFE, address(this)];
        for (uint256 i; i < direct.length; ++i) {
            uvm.prank(direct[i]);
            uvm.expectRevert();
            ITransparentUpgradeableProxy(address(vault)).upgradeToAndCall(next, "");
        }
        require(vault.implementation() == implementation, "not upgraded");
        _upgrade(next, "");
        require(vault.implementation() == next, "Safe upgraded");
    }

    function test_ProxyAdminCannotCallVaultFunctions() public {
        uvm.prank(address(proxyAdmin));
        uvm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
        vault.pool();
    }

    // ------------------------------------------------------------ storage (V-3)

    function test_StorageIsNamespaced() public view {
        require(
            vault.VAULT_STORAGE_LOCATION()
                == keccak256(abi.encode(uint256(keccak256("expogacha.storage.ExpoVault")) - 1)) & ~bytes32(uint256(0xff)),
            "ERC-7201 formula"
        );
        require(
            address(uint160(uint256(uvm.load(address(vault), vault.VAULT_STORAGE_LOCATION())))) == address(pool), "pool"
        );
        require(address(uint160(uint256(uvm.load(address(vault), OWNABLE_SLOT)))) == address(this), "owner slot");
        for (uint256 i; i < 10; ++i) {
            require(uvm.load(address(vault), bytes32(i)) == bytes32(0), "no sequential storage");
        }
    }

    function test_UpgradePreservesStateAndHeldNfts() public {
        for (uint256 t = 1; t <= 3; ++t) {
            nftA.mint(address(vault), t);
        }
        vault.transferOwnership(STRANGER); // pending, not accepted
        address next = address(new ExpoVaultV2Mock());
        _upgrade(next, abi.encodeCall(ExpoVaultV2Mock.migrate, (42)));

        ExpoVaultV2Mock v2 = ExpoVaultV2Mock(address(vault));
        require(v2.version() == 2 && v2.migrated() == 42, "migrated");
        require(vault.owner() == address(this) && vault.pendingOwner() == STRANGER, "owners kept");
        require(vault.pool() == address(pool), "pool kept");
        require(uint256(uvm.load(address(vault), INITIALIZABLE_SLOT)) == 2, "reinitialized to 2");
        for (uint256 t = 1; t <= 3; ++t) {
            require(nftA.ownerOf(t) == address(vault), "NFT kept");
        }
        uvm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.migrate(7);
        uvm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(STRANGER);
        uvm.prank(STRANGER);
        vault.acceptOwnership();
        require(vault.owner() == STRANGER, "two-step transfer survives the upgrade");
    }

    // ------------------------------------------------------------ evidence (V-4, V-5)

    function test_UpgradeToDifferentCodeVoidsEvidence() public {
        uint64 config = _etf(10);
        uint256 id = _claimed(config);
        nftA.mint(address(vault), 7);
        bytes32 before = registry.vaultCodehash();
        require(before == implementation.codehash, "bound to the implementation");

        _upgrade(address(new ExpoVaultV2Mock()), "");
        require(registry.vaultCodehash() != before, "new code");
        require(!registry.isAdmitted(address(nftA)) && !registry.isDeliverable(address(nftA)), "evidence void");
        uvm.expectRevert(abi.encodeWithSelector(ExpoGachaPool.NotAdmitted.selector, address(nftA)));
        _etf(10);
        uvm.prank(BUYER);
        uvm.expectRevert(abi.encodeWithSelector(ExpoGachaPool.NotAdmitted.selector, address(nftA)));
        pool.open(config, 0);
        uvm.prank(OPERATOR);
        uvm.expectRevert(abi.encodeWithSelector(ExpoGachaPool.NotAdmitted.selector, address(nftA)));
        pool.fulfill(id, 7, new bytes32[](0));

        // New evidence against the new implementation restores delivery.
        _admit(address(nftA));
        _deliver(id, 7);
        require(nftA.ownerOf(7) == BUYER && _state(id) == ExpoGachaPool.State.Delivered, "delivered");
    }

    function test_UpgradeWithoutReadmissionCompensatesWaitingClaim() public {
        uint256 id = _claimed(_etf(10));
        nftA.mint(address(vault), 7);
        _upgrade(address(new ExpoVaultV2Mock()), "");
        uvm.warp(block.timestamp + 1 days);
        uint256 balance = usdc.balanceOf(BUYER);
        pool.compensate(id);
        require(usdc.balanceOf(BUYER) - balance == 40e6, "full reference");
        require(pool.pendingClaims(address(nftA)) == 0, "claim cleared");
    }

    function test_UpgradeToIdenticalCodeKeepsEvidence() public {
        _upgrade(address(new ExpoVault()), "");
        require(vault.implementation() != implementation, "new address");
        require(registry.isAdmitted(address(nftA)) && registry.isDeliverable(address(nftA)), "same code, same evidence");
    }

    function test_ImplementationCodeChangeVoidsEvidence() public {
        uvm.etch(implementation, address(new ExpoVaultV2Mock()).code);
        require(!registry.isAdmitted(address(nftA)), "implementation code changed");
    }

    /// @dev The registry trusts the vault's own report; a malicious release can lie (docs/48 limits). The monitor and
    /// the backend read the EIP-1967 slot instead, which this pins.
    function test_MaliciousUpgradeCanDrainAndIsVisibleInSlot() public {
        nftA.mint(address(vault), 9);
        address drainer = address(new ExpoVaultDrainer(implementation));
        _upgrade(drainer, "");
        ExpoVaultDrainer(address(vault)).drain(address(nftA), 9, STRANGER);
        require(nftA.ownerOf(9) == STRANGER, "an upgrader can move every held NFT");
        require(address(uint160(uint256(uvm.load(address(vault), IMPLEMENTATION_SLOT)))) == drainer, "slot shows it");
    }

    function test_RegistryRejectsUnproxiedVault() public {
        address impl = address(new ExpoVault());
        uvm.expectRevert(ExpoAdmissionRegistry.InvalidBatch.selector);
        new ExpoAdmissionRegistry(address(this), impl);
        ExpoLegacyVault legacy = new ExpoLegacyVault(address(this));
        uvm.expectRevert(ExpoAdmissionRegistry.InvalidBatch.selector);
        new ExpoAdmissionRegistry(address(this), address(legacy));
    }

    function test_DeliveryIgnoresExpiryButNotRevocation() public {
        address[] memory list = new address[](1);
        list[0] = address(nftA);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("short");
        registry.admit(list, evidence, uint64(block.timestamp + 2 hours));
        uint256 first = _claimed(_etf(10));
        uint256 second = _claimed(_etf(10));
        nftA.mint(address(vault), 1);
        nftA.mint(address(vault), 2);
        uvm.warp(block.timestamp + 3 hours);
        require(!registry.isAdmitted(address(nftA)) && registry.isDeliverable(address(nftA)), "expired, deliverable");
        _deliver(first, 1);
        registry.revoke(address(nftA));
        uvm.prank(OPERATOR);
        uvm.expectRevert(abi.encodeWithSelector(ExpoGachaPool.NotAdmitted.selector, address(nftA)));
        pool.fulfill(second, 2, new bytes32[](0));
    }

    // ------------------------------------------------------------ admission hardening (HN-5, HN-8)

    function test_Hostile_AdmissionExpiryIsBounded() public {
        address[] memory list = new address[](1);
        list[0] = address(nftB);
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("e");
        uvm.expectRevert(ExpoAdmissionRegistry.InvalidBatch.selector);
        registry.admit(list, evidence, type(uint64).max);
        uvm.expectRevert(ExpoAdmissionRegistry.InvalidBatch.selector);
        registry.admit(list, evidence, uint64(block.timestamp + 365 days + 1));
        registry.admit(list, evidence, uint64(block.timestamp + 365 days));
    }

    function test_Hostile_DelegatedEoaIsNotACollection() public {
        address eoa = address(0x7702);
        uvm.etch(eoa, abi.encodePacked(hex"ef0100", address(nftB)));
        address[] memory list = new address[](1);
        list[0] = eoa;
        bytes32[] memory evidence = new bytes32[](1);
        evidence[0] = keccak256("e");
        uvm.expectRevert(abi.encodeWithSelector(ExpoAdmissionRegistry.InvalidCollection.selector, eoa));
        registry.admit(list, evidence, uint64(block.timestamp + 1 days));
    }

    // ------------------------------------------------------------ recovery (V-6)

    function test_PendingClaimsFollowTheClaimLifecycle() public {
        uint64 config = _etf(10);
        uint256 a = _claimed(config);
        uint256 b = _claimed(config);
        uint256 c = _open(config);
        _reveal(c); // revealed, not claimed: not counted
        require(pool.pendingClaims(address(nftA)) == 2, "two claims");
        nftA.mint(address(vault), 1);
        _deliver(a, 1);
        require(pool.pendingClaims(address(nftA)) == 1, "fulfil decrements");
        uvm.warp(block.timestamp + 1 days);
        pool.compensate(b);
        pool.compensate(c);
        require(pool.pendingClaims(address(nftA)) == 0, "compensation of the claim decrements; the reveal does not");
    }

    function test_RecoverBlockedWhileClaimWaits() public {
        uint256 id = _claimed(_etf(10));
        nftA.mint(address(vault), 5);
        nftB.mint(address(vault), 5);
        uvm.expectRevert(abi.encodeWithSelector(ExpoVault.TokenOwed.selector, address(nftA)));
        vault.recover(address(nftA), 5, address(this));
        uvm.expectRevert(abi.encodeWithSelector(ExpoVault.TokenOwed.selector, address(nftA)));
        vault.recoverSafe(address(nftA), 5, address(this));
        vault.recover(address(nftB), 5, STRANGER); // another collection: Expo's inventory
        require(nftB.ownerOf(5) == STRANGER, "recovered");

        _deliver(id, 5);
        nftA.mint(address(vault), 6);
        vault.recover(address(nftA), 6, STRANGER);
        require(nftA.ownerOf(6) == STRANGER, "recoverable after settlement");
    }

    function test_RecoverAllowedAfterCompensation() public {
        uint256 id = _claimed(_etf(10));
        nftA.mint(address(vault), 5);
        uvm.warp(block.timestamp + 1 days);
        pool.compensate(id);
        vault.recover(address(nftA), 5, STRANGER);
        require(nftA.ownerOf(5) == STRANGER, "stranded token recovered after the buyer was paid");
    }

    function test_OnlyOwnerRecovers() public {
        nftA.mint(address(vault), 5);
        address[3] memory callers = [STRANGER, address(pool), SAFE];
        for (uint256 i; i < callers.length; ++i) {
            uvm.prank(callers[i]);
            uvm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, callers[i]));
            vault.recover(address(nftA), 5, callers[i]);
            uvm.prank(callers[i]);
            uvm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, callers[i]));
            vault.recoverSafe(address(nftA), 5, callers[i]);
        }
        uvm.prank(STRANGER);
        uvm.expectRevert(ExpoVault.Unauthorized.selector);
        vault.release(address(nftA), 5, STRANGER);
    }

    function test_Hostile_RecoverSafeMovesSafeOnlyTokens() public {
        SafeOnlyNFT safeOnly = new SafeOnlyNFT();
        safeOnly.mint(address(vault), 1);
        uvm.expectRevert(bytes("safe transfers only"));
        vault.recover(address(safeOnly), 1, address(this));
        Receiver receiver = new Receiver();
        vault.recoverSafe(address(safeOnly), 1, address(receiver));
        require(safeOnly.ownerOf(1) == address(receiver), "recovered through safeTransferFrom");
        uvm.expectRevert(ExpoVault.Invalid.selector);
        vault.recoverSafe(address(nftA), 1, address(vault));
    }

    function test_OwnershipIsTwoStepAndCannotBeRenounced() public {
        uvm.expectRevert(ExpoVault.Invalid.selector);
        vault.renounceOwnership();
        vault.transferOwnership(STRANGER);
        require(vault.owner() == address(this), "still owner until accepted");
        uvm.prank(address(0xF00));
        uvm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xF00)));
        vault.acceptOwnership();
        uvm.prank(STRANGER);
        vault.acceptOwnership();
        require(vault.owner() == STRANGER, "accepted");
    }

    function test_BindPoolOnceByOwner() public {
        ExpoVault fresh = ExpoVaultDeployment.deploy(address(this), SAFE).vault;
        uvm.prank(STRANGER);
        uvm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, STRANGER));
        fresh.bindPool(address(pool));
        uvm.expectRevert(ExpoVault.Invalid.selector);
        fresh.bindPool(STRANGER); // not a contract
        fresh.bindPool(address(pool));
        uvm.expectRevert(ExpoVault.Invalid.selector);
        fresh.bindPool(address(registry));
        // Before binding nothing is owed, so recovery is open; after binding the pool's ledger applies.
        require(fresh.pool() == address(pool), "bound");
    }
}
