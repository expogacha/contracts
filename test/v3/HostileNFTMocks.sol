// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev Hostile and compatibility ERC-721 mocks for the hostile-collection audit (docs/47). None of them is a real
/// library: each reproduces only the behaviour the Expo vault and pool path depends on.

// ==================================================================== hostile

/// @dev Upgrade target with MockNFT's storage layout (OZ 5 ERC721 slots 0-5) plus a fake-owner map: `transferFrom`
/// moves nothing but makes `ownerOf` report the recipient. Also usable directly as an admitted malicious collection.
contract LiarNFT is ERC721 {
    mapping(uint256 => address) public fakeOwner;

    constructor() ERC721("Liar", "LIE") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function ownerOf(uint256 id) public view override returns (address) {
        address f = fakeOwner[id];
        return f != address(0) ? f : super.ownerOf(id);
    }

    /// @dev The real ledger entry, which the lie hides.
    function realOwnerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function transferFrom(address, address to, uint256 id) public override {
        fakeOwner[id] = to;
        emit Transfer(msg.sender, to, id); // a Transfer event is not a transfer
    }
}

/// @dev Moves a different token (mode 1), or the requested token plus another one of the vault's tokens (mode 2).
contract SwapNFT is ERC721 {
    uint8 public mode;
    uint256 public other;
    address public thief;

    constructor() ERC721("Swap", "SWAP") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function arm(uint8 m, uint256 otherId, address to) external {
        mode = m;
        other = otherId;
        thief = to;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (mode == 1) {
            _transfer(from, to, other);
            return;
        }
        if (mode == 2) _transfer(from, thief, other);
        super.transferFrom(from, to, id);
    }
}

interface IPoolLike {
    function compensate(uint256) external;
    function quickSell(uint256) external;
    function fulfill(uint256, uint256, bytes32[] calldata) external;
    function finalize(uint256) external;
    function claimNFT(uint256) external;
    function withdrawCreatorFees() external;
}

interface IVaultLike {
    function release(address, uint256, address) external;
    function recover(address, uint256, address) external;
}

/// @dev On the vault's transfer, tries every state-changing route back into the pool and the vault, and tries to
/// pull another collection's token out of the vault. Records which attempts succeeded.
contract ReentrantHostileNFT is ERC721 {
    address public pool;
    address public vault;
    address public otherCollection;
    uint256 public otherOpening;
    uint256 public otherToken;
    uint256 public successes;
    uint256 public attempts;

    constructor() ERC721("Reentrant", "RE") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function arm(address p, address v, address coll, uint256 opening, uint256 token) external {
        pool = p;
        vault = v;
        otherCollection = coll;
        otherOpening = opening;
        otherToken = token;
    }

    function _try(address target, bytes memory data) private {
        ++attempts;
        (bool ok,) = target.call(data);
        if (ok) ++successes;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (pool != address(0)) {
            bytes32[] memory none = new bytes32[](0);
            _try(pool, abi.encodeCall(IPoolLike.compensate, (otherOpening)));
            _try(pool, abi.encodeCall(IPoolLike.quickSell, (otherOpening)));
            _try(pool, abi.encodeCall(IPoolLike.fulfill, (otherOpening, otherToken, none)));
            _try(pool, abi.encodeCall(IPoolLike.claimNFT, (otherOpening)));
            _try(pool, abi.encodeCall(IPoolLike.withdrawCreatorFees, ()));
            _try(vault, abi.encodeCall(IVaultLike.release, (otherCollection, otherToken, address(this))));
            _try(vault, abi.encodeCall(IVaultLike.recover, (otherCollection, otherToken, address(this))));
            _try(otherCollection, abi.encodeCall(IERC721.transferFrom, (vault, address(this), otherToken)));
            _try(
                otherCollection,
                abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", vault, address(this), otherToken)
            );
        }
        super.transferFrom(from, to, id);
    }
}

/// @dev Mode 1: burns all gas in transferFrom. Mode 2: reverts with `size` bytes. Mode 3: succeeds, then returns
/// `size` bytes of return data.
contract BombNFT is ERC721 {
    uint8 public mode;
    uint256 public size;

    constructor() ERC721("Bomb", "BOMB") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function arm(uint8 m, uint256 s) external {
        mode = m;
        size = s;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (mode == 1) {
            while (true) {}
        }
        if (mode == 2) {
            uint256 s = size;
            assembly {
                revert(0, s)
            }
        }
        super.transferFrom(from, to, id);
        if (mode == 3) {
            uint256 s = size;
            assembly {
                return(0, s)
            }
        }
    }
}

/// @dev Claims every interface (ERC-721 included) but implements none of them.
contract InterfaceLiar {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @dev CryptoPunks-style market contract: no ERC-165, no ownerOf/transferFrom.
contract PunksLike {
    mapping(uint256 => address) public punkIndexToAddress;

    function setOwner(uint256 i, address o) external {
        punkIndexToAddress[i] = o;
    }

    function transferPunk(address to, uint256 i) external {
        require(punkIndexToAddress[i] == msg.sender, "not owner");
        punkIndexToAddress[i] = to;
    }
}

/// @dev Plain ERC-1155.
contract Mock1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev ERC-721 that also reports the ERC-1155 interface (as some hybrids do).
contract Hybrid721And1155 is ERC721 {
    constructor() ERC721("Hybrid", "HYB") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0xd9b67a26 || super.supportsInterface(id);
    }
}

// ==================================================================== policy-restricted (legit but restrictive)

/// @dev Restriction switches seen in real collections, all changeable by the collection owner after admission
/// without changing the runtime code hash.
contract RestrictedNFT is ERC721 {
    bool public paused;
    bool public blockCodeReceivers;
    bool public callerWhitelistOnly; // royalty enforcement / OTC disabled: even the owner needs a listed caller
    bool public hookOnTransferFrom; // calls onERC721Received even on transferFrom
    bool public safeOnly; // transferFrom refused; only safeTransferFrom works
    bool private inSafe;
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public callerWhitelist;

    constructor() ERC721("Restricted", "RST") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setPaused(bool v) external {
        paused = v;
    }

    function setBlockCodeReceivers(bool v) external {
        blockCodeReceivers = v;
    }

    function setCallerWhitelistOnly(bool v) external {
        callerWhitelistOnly = v;
    }

    function setHookOnTransferFrom(bool v) external {
        hookOnTransferFrom = v;
    }

    function setSafeOnly(bool v) external {
        safeOnly = v;
    }

    function setBlacklisted(address a, bool v) external {
        blacklisted[a] = v;
    }

    function setCallerWhitelist(address a, bool v) external {
        callerWhitelist[a] = v;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (safeOnly && !inSafe) revert("safeTransferFrom only");
        super.transferFrom(from, to, id);
        if (hookOnTransferFrom && to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, "")
                    == IERC721Receiver.onERC721Received.selector,
                "receiver rejected"
            );
        }
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override {
        inSafe = true;
        super.safeTransferFrom(from, to, id, data);
        inSafe = false;
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        address from = _ownerOf(id);
        if (from != address(0)) {
            require(!paused, "paused");
            require(!blacklisted[from] && !blacklisted[to] && !blacklisted[msg.sender], "blacklisted");
            require(!blockCodeReceivers || to.code.length == 0, "contract receivers blocked");
            require(!callerWhitelistOnly || callerWhitelist[msg.sender], "caller not allowed");
        }
        return super._update(to, id, auth);
    }
}

/// @dev ERC-5192 soulbound: minted locked, every later transfer reverts.
contract SoulboundNFT is ERC721 {
    event Locked(uint256 tokenId);

    constructor() ERC721("Soul", "SOUL") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
        emit Locked(id);
    }

    function locked(uint256) external pure returns (bool) {
        return true;
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0xb45a3c0e || super.supportsInterface(id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (_ownerOf(id) != address(0)) revert("soulbound");
        return super._update(to, id, auth);
    }
}

/// @dev Limit Break Creator Token (ERC721-C) transfer validator, reduced to the policies that matter here. Level 0:
/// none. Level 1: OTC disabled, the caller must be whitelisted even when it owns the token. Level 2: OTC allowed,
/// receivers with code (contracts, Safes, EIP-7702 delegated EOAs) blocked unless whitelisted. Level 3: receivers
/// must be verified EOAs (EOA registry signature).
contract CreatorValidatorMock {
    mapping(address => uint8) public levelOf;
    mapping(address => mapping(address => bool)) public whitelisted; // collection => account
    mapping(address => bool) public verifiedEOA;

    function setLevel(address collection, uint8 level) external {
        levelOf[collection] = level;
    }

    function setWhitelisted(address collection, address a, bool v) external {
        whitelisted[collection][a] = v;
    }

    function verify(address a) external {
        verifiedEOA[a] = true;
    }

    function validateTransfer(address caller, address from, address to) external view {
        uint8 level = levelOf[msg.sender];
        if (level == 1 && !whitelisted[msg.sender][caller]) revert("caller must be whitelisted");
        if (level == 2 && to.code.length > 0 && !whitelisted[msg.sender][to]) revert("receiver has code");
        if (level == 3 && !verifiedEOA[to] && !whitelisted[msg.sender][to]) revert("receiver not verified");
        from; // unused by these levels
    }
}

/// @dev ERC721-C shape: every transfer asks an owner-replaceable validator.
contract CreatorTokenNFT is ERC721 {
    address public validator;

    constructor(address v) ERC721("Creator", "C721") {
        validator = v;
    }

    function setTransferValidator(address v) external {
        validator = v;
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        address from = _ownerOf(id);
        if (from != address(0) && to != address(0) && validator != address(0)) {
            CreatorValidatorMock(validator).validateTransfer(msg.sender, from, to);
        }
        return super._update(to, id, auth);
    }
}

/// @dev OpenSea Operator Filter Registry semantics (`onlyAllowedOperator(from)`): only checked when the caller is
/// not the owner.
contract OperatorFilterNFT is ERC721 {
    mapping(address => bool) public filtered;

    constructor() ERC721("Filtered", "OFR") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setFiltered(address operator, bool v) external {
        filtered[operator] = v;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (from != msg.sender) require(!filtered[msg.sender], "operator filtered");
        super.transferFrom(from, to, id);
    }
}

// ==================================================================== non-OpenZeppelin implementations

/// @dev Solmate/Solady-style ERC-721: own storage, `ownerOf` reverts NOT_MINTED, no receiver check on transferFrom.
contract SolmateStyleNFT {
    event Transfer(address indexed from, address indexed to, uint256 indexed id);

    mapping(uint256 => address) internal _ownerOf;
    mapping(address => uint256) internal _balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function ownerOf(uint256 id) public view virtual returns (address owner) {
        require((owner = _ownerOf[id]) != address(0), "NOT_MINTED");
    }

    function balanceOf(address owner) external view returns (uint256) {
        require(owner != address(0), "ZERO_ADDRESS");
        return _balanceOf[owner];
    }

    function mint(address to, uint256 id) external {
        require(_ownerOf[id] == address(0), "ALREADY_MINTED");
        _ownerOf[id] = to;
        unchecked {
            _balanceOf[to]++;
        }
        emit Transfer(address(0), to, id);
    }

    function transferFrom(address from, address to, uint256 id) public virtual {
        require(from == ownerOf(id), "WRONG_FROM");
        require(to != address(0), "INVALID_RECIPIENT");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender] || msg.sender == getApproved[id], "NOT_AUTHORIZED"
        );
        unchecked {
            _balanceOf[from]--;
            _balanceOf[to]++;
        }
        _ownerOf[id] = to;
        delete getApproved[id];
        emit Transfer(from, to, id);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0x5b5e139f;
    }
}

/// @dev ERC721A-style lazy ownership: a batch mint writes only its first slot; ownerOf scans backwards; a transfer
/// initialises the next slot so the rest of the batch keeps its owner.
contract LazyBatchNFT is SolmateStyleNFT {
    uint256 public nextId;

    function mintBatch(address to, uint256 n) external {
        _ownerOf[nextId] = to;
        _balanceOf[to] += n;
        for (uint256 i; i < n; ++i) {
            emit Transfer(address(0), to, nextId + i);
        }
        nextId += n;
    }

    function ownerOf(uint256 id) public view override returns (address) {
        require(id < nextId, "OwnerQueryForNonexistentToken");
        for (uint256 i = id;; --i) {
            if (_ownerOf[i] != address(0)) return _ownerOf[i];
            if (i == 0) break;
        }
        revert("unreachable");
    }

    function transferFrom(address from, address to, uint256 id) public override {
        address prev = ownerOf(id);
        if (id + 1 < nextId && _ownerOf[id + 1] == address(0)) _ownerOf[id + 1] = prev;
        _ownerOf[id] = prev; // materialise, then the base moves it
        super.transferFrom(from, to, id);
    }
}

// ==================================================================== recipients

/// @dev A contract wallet whose receiver hook always rejects.
contract RejectingWallet {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("no NFTs here");
    }
}

/// @dev Safe-like wallet: has the receiver hooks (Safe's CompatibilityFallbackHandler) and arbitrary execution.
contract SafeLikeWallet {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory out) = target.call(data);
        require(ok, "exec failed");
        return out;
    }
}

/// @dev Code behind an EIP-7702 delegated EOA in these tests (a minimal smart-account implementation).
contract DelegateAccount {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}
