// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ExpoPool, IRandomness} from "../src/ExpoPool.sol";
import {MockNFT, MockRandomness} from "../src/MockAssets.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

interface Cheat {
    function prank(address) external;
    function expectRevert() external;
}

contract FeeToken is ERC20 {
    constructor() ERC20("Bad token", "BAD") {
        _mint(msg.sender, 1e15);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            super._update(from, address(1), 1);
            super._update(from, to, value - 1);
        } else {
            super._update(from, to, value);
        }
    }
}

contract ReentrantToken is ERC20 {
    ExpoPool public pool;
    bool public attempted;
    bool public entered;

    constructor() ERC20("Test reentry", "R") {
        _mint(msg.sender, 1e15);
    }

    function arm(ExpoPool p) external {
        pool = p;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (address(pool) != address(0)) {
            attempted = true;
            (entered,) = address(pool).call(abi.encodeCall(pool.open, (uint64(1))));
        }
        return super.transferFrom(from, to, value);
    }
}

contract LyingNFT is ERC165 {
    address public holder;

    constructor(address h) {
        holder = h;
    }

    function ownerOf(uint256) external view returns (address) {
        return holder;
    }
    function transferFrom(address, address, uint256) external pure {} // Deliberately does not transfer.
}

contract AdversarialTest {
    Cheat constant vm = Cheat(address(uint160(uint256(keccak256("hevm cheat code")))));

    function testRejectFeeOnTransferFunding() public {
        FeeToken t = new FeeToken();
        MockRandomness rng = new MockRandomness();
        ExpoPool p = new ExpoPool(t, IRandomness(address(rng)), address(this), address(this));
        t.approve(address(p), 100);
        vm.expectRevert();
        p.fund(100);
        require(t.balanceOf(address(p)) == 0);
    }

    function testPaymentReentryBlocked() public {
        ReentrantToken t = new ReentrantToken();
        MockNFT n = new MockNFT();
        MockRandomness rng = new MockRandomness();
        ExpoPool p = new ExpoPool(t, IRandomness(address(rng)), address(this), address(this));
        _config(p, address(n));
        t.approve(address(p), 1e15);
        p.fund(1000e6);
        t.arm(p);
        p.open(1);
        require(t.attempted() && !t.entered());
        require(p.openingCount() == 1);
    }

    function testRevertingOrLyingNFTCannotConsumeLiability() public {
        ReentrantToken t = new ReentrantToken();
        LyingNFT n = new LyingNFT(address(this));
        MockRandomness rng = new MockRandomness();
        ExpoPool p = new ExpoPool(t, IRandomness(address(rng)), address(this), address(this));
        _config(p, address(n));
        t.approve(address(p), 1e15);
        p.fund(1000e6);
        p.open(1);
        rng.fulfill(1, 0);
        p.finalize(1);
        // Buyer is this contract; delivering to itself cannot demonstrate transfer, so use a different buyer.
        address buyer = address(0x123);
        t.transfer(buyer, 50e6);
        vm.prank(buyer);
        t.approve(address(p), 50e6);
        vm.prank(buyer);
        p.open(1);
        rng.fulfill(2, 0);
        p.finalize(2);
        vm.prank(buyer);
        p.claimNFT(2);
        uint256 beforeReserve = p.reserved();
        vm.expectRevert();
        p.deliver(2);
        require(p.reserved() == beforeReserve);
    }

    function _config(ExpoPool p, address nft) internal {
        ExpoPool.Outcome[][4] memory items;
        items[0] = new ExpoPool.Outcome[](1);
        items[0][0] = ExpoPool.Outcome(nft, 0, 100e6);
        p.createConfig(50e6, [uint16(10000), 0, 0, 0], 9000, 1 days, keccak256("adversarial"), items);
    }
}
