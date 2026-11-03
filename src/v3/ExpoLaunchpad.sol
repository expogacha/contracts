// SPDX-License-Identifier: MIT
/*
 *        .-------------.
 *       /  o   O   o    \        _____ __  __ ____   ___
 *      |   O   o   O   o |      | ____|\ \/ /|  _ \ / _ \
 *      |   o   O   o   O |      |  _|   \  / | |_) | | | |
 *       \    o   O   o  /       | |___  /  \ |  __/| |_| |
 *        '-------------'        |_____|/_/\_\|_|    \___/
 *       |   [ E X P O ]  |         ____    _    ____ _   _    _
 *       |                |        / ___|  / \  / ___| | | |  / \
 *       |   (+)     ___  |       | |  _  / _ \| |   | |_| | / _ \
 *       |          | o | |       | |_| |/ ___ \ |___|  _  |/ ___ \
 *       |__________|___|_|        \____/_/   \_\____|_| |_/_/   \_\
 *
 *       ExpoLaunchpad
 *       Anyone launches a gacha, at a price signed by the quote service.
 *
 *       https://expogacha.com
 *
 *       Insert coin. Turn the handle. Keep the capsule or sell it back.
 */
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ExpoGachaPool} from "./ExpoGachaPool.sol";

/// @title Expo Gacha launchpad
/// @author Expo Gacha
/// @custom:website https://expogacha.com
/// @notice Unaudited permissionless launchpad (docs/31, docs/33). Anyone launches a gacha from approved collections,
/// but only with economics Expo's quote key signed: price, odds, entitlements, caps and creator fee. The pool, as
/// the only reserve, enforces admission, odds and exposure limits again.
/// v3.2 (docs/46): each entitlement carries its draw weight, so `entitlementsHash` binds the weights; the EIP-712
/// domain version is "2" so a v3.1 quote can never be submitted to a v3.2 launchpad.
contract ExpoLaunchpad is Ownable, EIP712 {
    using SafeERC20 for IERC20;

    struct Quote {
        address creator;
        bytes32 gachaId;
        uint128 priceUsdc;
        uint16[4] odds;
        bytes32 entitlementsHash;
        uint16 quickSellBps;
        uint32 settlementWindow;
        uint16 creatorFeeBps;
        uint32 maxOpen;
        bytes32 metadataHash;
        uint256 nonce;
        uint64 expiresAt;
    }

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address creator,bytes32 gachaId,uint128 priceUsdc,uint16[4] odds,bytes32 entitlementsHash,uint16 quickSellBps,uint32 settlementWindow,uint16 creatorFeeBps,uint32 maxOpen,bytes32 metadataHash,uint256 nonce,uint64 expiresAt)"
    );
    /// @notice Paid into the shared reserve on every launch, in the pool token's base units; fixed at deployment.
    uint256 public immutable CREATION_FEE;

    ExpoGachaPool public immutable pool;
    IERC20 public immutable usdc;
    address public quoteSigner;
    mapping(uint256 => bool) public usedNonce;

    error Unauthorized();
    error Expired();
    error Used();
    error BadSignature();
    error Invalid();

    event QuoteSignerSet(address signer);
    event Launched(uint64 indexed configId, address indexed creator, bytes32 indexed gachaId, uint256 nonce);

    constructor(ExpoGachaPool pool_, address owner_, address signer, uint256 creationFee)
        Ownable(owner_)
        EIP712("ExpoLaunchpad", "2")
    {
        if (address(pool_).code.length == 0 || signer == address(0) || creationFee == 0) revert Invalid();
        CREATION_FEE = creationFee;
        pool = pool_;
        usdc = pool_.usdc();
        quoteSigner = signer;
    }

    function setQuoteSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert Invalid();
        quoteSigner = signer;
        emit QuoteSignerSet(signer);
    }

    function quoteDigest(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    q.creator,
                    q.gachaId,
                    q.priceUsdc,
                    keccak256(abi.encodePacked(q.odds)),
                    q.entitlementsHash,
                    q.quickSellBps,
                    q.settlementWindow,
                    q.creatorFeeBps,
                    q.maxOpen,
                    q.metadataHash,
                    q.nonce,
                    q.expiresAt
                )
            )
        );
    }

    function launch(Quote calldata q, ExpoGachaPool.Entitlement[][4] calldata items, bytes calldata signature)
        external
        returns (uint64 configId)
    {
        if (msg.sender != q.creator) revert Unauthorized();
        if (block.timestamp > q.expiresAt) revert Expired();
        if (usedNonce[q.nonce]) revert Used();
        usedNonce[q.nonce] = true;
        if (ECDSA.recover(quoteDigest(q), signature) != quoteSigner) revert BadSignature();
        if (keccak256(abi.encode(items)) != q.entitlementsHash) revert BadSignature();
        if (q.creatorFeeBps > pool.MAX_CREATOR_FEE_BPS()) revert Invalid();
        usdc.safeTransferFrom(msg.sender, address(pool), CREATION_FEE);
        configId = pool.createLaunchpadConfig(
            ExpoGachaPool.ConfigInput(
                q.gachaId, q.priceUsdc, q.odds, q.quickSellBps, q.settlementWindow, q.metadataHash, items
            ),
            q.creator,
            q.creatorFeeBps,
            q.maxOpen
        );
        emit Launched(configId, q.creator, q.gachaId, q.nonce);
    }
}
