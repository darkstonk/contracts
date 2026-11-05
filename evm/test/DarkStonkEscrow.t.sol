// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DarkStonkEscrow} from "../src/DarkStonkEscrow.sol";

interface IERC20Full {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// A coin that keeps 1% of every transfer: the pool must refuse it.
contract TaxCoin {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a - a / 100;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a - a / 100;
        return true;
    }
}

/// A payout wallet that refuses ETH and tries to re-enter on the way.
contract Reenterer {
    DarkStonkEscrow esc;
    bytes32 id;

    constructor(DarkStonkEscrow e) {
        esc = e;
    }

    function arm(bytes32 i) external {
        id = i;
    }

    receive() external payable {
        esc.cancel(id);
    }
}

/**
 * Runs against a fork of Robinhood Chain mainnet with a real Pons coin:
 *   forge test --fork-url robinhood
 */
contract DarkStonkEscrowTest is Test {
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    uint256 constant ONE = 1e18;

    DarkStonkEscrow esc;
    IERC20Full coin = IERC20Full(PONS);
    uint256 matcherKey = 0xA11CE;
    address matcher;
    address admin = makeAddr("admin");
    address fees = makeAddr("fees");
    address seller = makeAddr("seller");
    address sellerPayout = makeAddr("sellerPayout");
    address buyer = makeAddr("buyer");
    address buyerPayout = makeAddr("buyerPayout");
    address taker = makeAddr("taker");

    // 1 PONS = 0.00005 ETH, in wei per 1e18 base units
    uint256 constant PRICE = 5e13;

    function setUp() public {
        matcher = vm.addr(matcherKey);
        esc = new DarkStonkEscrow(admin, matcher, fees, 50);
        deal(PONS, seller, 1_000_000 * ONE);
        deal(PONS, taker, 1_000_000 * ONE);
        vm.deal(buyer, 100 ether);
        vm.deal(taker, 100 ether);
        vm.prank(seller);
        coin.approve(address(esc), type(uint256).max);
        vm.prank(taker);
        coin.approve(address(esc), type(uint256).max);
    }

    /* ------------------------------------------------------------ helpers */

    function sign(address who, address to, uint8 side, DarkStonkEscrow.Take[] memory takes, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typehash = keccak256("Approval(address taker,address to,uint8 side,bytes32 takes,uint256 deadline)");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", esc.DOMAIN_SEPARATOR(), keccak256(abi.encode(typehash, who, to, side, keccak256(abi.encode(takes)), deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(matcherKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function openSell(uint64 nonce, uint128 amount, uint256 price) internal returns (bytes32 id) {
        bytes32 c = esc.commitmentOf(price, sellerPayout, bytes32(uint256(nonce)));
        vm.prank(seller);
        id = esc.openSell(nonce, PONS, amount, c, uint40(block.timestamp + 7 days));
    }

    function openBuy(uint64 nonce, uint256 wei_, uint256 price) internal returns (bytes32 id) {
        bytes32 c = esc.commitmentOf(price, buyerPayout, bytes32(uint256(nonce)));
        vm.prank(buyer);
        id = esc.openBuy{value: wei_}(nonce, PONS, c, uint40(block.timestamp + 7 days));
    }

    function one(bytes32 id, uint256 amount, uint256 price, address payout, uint64 nonce) internal pure returns (DarkStonkEscrow.Take[] memory t) {
        t = new DarkStonkEscrow.Take[](1);
        t[0] = DarkStonkEscrow.Take(id, amount, price, payout, bytes32(uint256(nonce)));
    }

    function left(bytes32 id) internal view returns (uint128 l) {
        (,,,,,, l,) = esc.orders(id);
    }

    /* ------------------------------------------------------------ makers */

    function test_openSellEscrowsTheCoin() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        assertEq(id, esc.orderId(seller, 1));
        assertEq(coin.balanceOf(address(esc)), 1000 * ONE);
        assertEq(left(id), 1000 * ONE);
    }

    function test_sameNonceTwiceIsRefused() public {
        openSell(1, uint128(10 * ONE), PRICE);
        vm.prank(seller);
        vm.expectRevert(DarkStonkEscrow.Taken.selector);
        esc.openSell(1, PONS, uint128(10 * ONE), bytes32(0), uint40(block.timestamp + 1 days));
    }

    function test_cancelReturnsEverythingEvenWhilePaused() public {
        bytes32 s = openSell(1, uint128(1000 * ONE), PRICE);
        bytes32 b = openBuy(2, 1 ether, PRICE);
        vm.prank(admin);
        esc.setConfig(matcher, fees, 50, true);
        uint256 coinBefore = coin.balanceOf(seller);
        vm.prank(seller);
        esc.cancel(s);
        assertEq(coin.balanceOf(seller) - coinBefore, 1000 * ONE);
        uint256 ethBefore = buyer.balance;
        vm.prank(buyer);
        esc.cancel(b);
        assertEq(buyer.balance - ethBefore, 1 ether);
        assertEq(left(s), 0);
    }

    function test_onlyTheMakerCancels() public {
        bytes32 s = openSell(1, uint128(10 * ONE), PRICE);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.NotMaker.selector);
        esc.cancel(s);
    }

    /// A coin that keeps 1% of every transfer: the order books what arrived, and the buyer pays for what reaches them.
    function test_feeOnTransferCoinsWork() public {
        TaxCoin t = new TaxCoin();
        t.mint(seller, 1000 * ONE);
        bytes32 c = esc.commitmentOf(PRICE, sellerPayout, bytes32(uint256(9)));
        vm.startPrank(seller);
        t.approve(address(esc), 1000 * ONE);
        bytes32 id = esc.openSell(9, address(t), uint128(1000 * ONE), c, uint40(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(left(id), 990 * ONE, "the order books the 990 that arrived");

        DarkStonkEscrow.Take[] memory tk = new DarkStonkEscrow.Take[](1);
        tk[0] = DarkStonkEscrow.Take(id, 100 * ONE, PRICE, sellerPayout, bytes32(uint256(9)));
        bytes memory sig = sign(taker, taker, 0, tk, block.timestamp + 120);
        uint256 before = taker.balance;
        vm.prank(taker);
        esc.takeSells{value: 100 * PRICE}(tk, taker, block.timestamp + 120, sig);
        assertEq(t.balanceOf(taker), 99 * ONE, "the taker got 99 after the coin's cut");
        assertEq(before - taker.balance, 99 * PRICE, "the taker paid for 99, the rest of the ETH came back");
        assertEq(left(id), 890 * ONE, "the order dropped by what left escrow");

        // cancel hands back what is left
        vm.prank(seller);
        esc.cancel(id);
        assertEq(t.balanceOf(seller), 890 * ONE - (890 * ONE) / 100, "the seller got the rest, less the coin's cut");
    }

    function test_expiryInThePastIsRefused() public {
        vm.prank(seller);
        vm.expectRevert(DarkStonkEscrow.Expired.selector);
        esc.openSell(1, PONS, 1, bytes32(0), uint40(block.timestamp));
    }

    /* ------------------------------------------------------------ takers */

    function test_takeSellPaysTheSellerAndTheFee() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 400 * ONE, PRICE, sellerPayout, 1);
        uint256 deadline = block.timestamp + 120;
        bytes memory sig = sign(taker, taker, 0, t, deadline);
        uint256 cost = 400 * PRICE; // 0.02 ETH
        uint256 before = coin.balanceOf(taker);
        vm.prank(taker);
        esc.takeSells{value: cost}(t, taker, deadline, sig);
        assertEq(coin.balanceOf(taker) - before, 400 * ONE);
        assertEq(sellerPayout.balance, cost - cost / 200);
        assertEq(fees.balance, cost / 200);
        assertEq(left(id), 600 * ONE);
    }

    function test_takeSellToAFreshWallet() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        address fresh = makeAddr("fresh");
        DarkStonkEscrow.Take[] memory t = one(id, 1000 * ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, fresh, 0, t, block.timestamp + 120);
        vm.prank(taker);
        esc.takeSells{value: 1000 * PRICE}(t, fresh, block.timestamp + 120, sig);
        assertEq(coin.balanceOf(fresh), 1000 * ONE);
        (address maker,,,,,,,) = esc.orders(id);
        assertEq(maker, address(0)); // filled orders are deleted
    }

    function test_approvalIsBoundToTheRecipient() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 10 * ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.BadApproval.selector);
        esc.takeSells{value: 10 * PRICE}(t, makeAddr("elsewhere"), block.timestamp + 120, sig);
    }

    function test_approvalCantBeReplayed() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 10 * ONE, PRICE, sellerPayout, 1);
        uint256 d = block.timestamp + 120;
        bytes memory sig = sign(taker, taker, 0, t, d);
        vm.startPrank(taker);
        esc.takeSells{value: 10 * PRICE}(t, taker, d, sig);
        vm.expectRevert(DarkStonkEscrow.BadApproval.selector);
        esc.takeSells{value: 10 * PRICE}(t, taker, d, sig);
        vm.stopPrank();
    }

    function test_approvalIsBoundToTheTaker() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 10 * ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(DarkStonkEscrow.BadApproval.selector);
        esc.takeSells{value: 10 * PRICE}(t, taker, block.timestamp + 120, sig);
    }

    function test_noApprovalNoFill() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 10 * ONE, PRICE, sellerPayout, 1);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.BadApproval.selector);
        esc.takeSells{value: 10 * PRICE}(t, taker, block.timestamp + 120, new bytes(65));
    }

    function test_expiredApprovalIsRefused() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 10 * ONE, PRICE, sellerPayout, 1);
        uint256 d = block.timestamp + 120;
        bytes memory sig = sign(taker, taker, 0, t, d);
        vm.warp(d + 1);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.Expired.selector);
        esc.takeSells{value: 10 * PRICE}(t, taker, d, sig);
    }

    /// even a matcher-signed take can't change the committed price or payout
    function test_wrongRevealIsRefusedEvenWithAnApproval() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory cheap = one(id, 10 * ONE, PRICE / 2, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, cheap, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.BadCommitment.selector);
        esc.takeSells{value: 5 * PRICE}(cheap, taker, block.timestamp + 120, sig);

        DarkStonkEscrow.Take[] memory stolen = one(id, 10 * ONE, PRICE, taker, 1);
        sig = sign(taker, taker, 0, stolen, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.BadCommitment.selector);
        esc.takeSells{value: 10 * PRICE}(stolen, taker, block.timestamp + 120, sig);
    }

    function test_tooLittleValueIsRefused() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 10 * ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.WrongValue.selector);
        esc.takeSells{value: 10 * PRICE - 1}(t, taker, block.timestamp + 120, sig);
    }

    function test_extraValueComesBack() public {
        bytes32 id = openSell(1, uint128(1000 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 10 * ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        uint256 before = taker.balance;
        vm.prank(taker);
        esc.takeSells{value: 10 * PRICE + 1 ether}(t, taker, block.timestamp + 120, sig);
        assertEq(before - taker.balance, 10 * PRICE);
    }

    function test_takingMoreThanIsLeftIsRefused() public {
        bytes32 id = openSell(1, uint128(10 * ONE), PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 11 * ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.TooMuch.selector);
        esc.takeSells{value: 11 * PRICE}(t, taker, block.timestamp + 120, sig);
    }

    function test_expiredOrdersCantBeTaken() public {
        bytes32 id = openSell(1, uint128(10 * ONE), PRICE);
        vm.warp(block.timestamp + 8 days);
        DarkStonkEscrow.Take[] memory t = one(id, ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.Expired.selector);
        esc.takeSells{value: PRICE}(t, taker, block.timestamp + 120, sig);
        // but the maker still gets it all back
        vm.prank(seller);
        esc.cancel(id);
    }

    function test_takeSeveralSellsInOneGo() public {
        bytes32 a = openSell(1, uint128(100 * ONE), PRICE);
        bytes32 b = openSell(2, uint128(100 * ONE), PRICE + 1e12);
        DarkStonkEscrow.Take[] memory t = new DarkStonkEscrow.Take[](2);
        t[0] = DarkStonkEscrow.Take(a, 100 * ONE, PRICE, sellerPayout, bytes32(uint256(1)));
        t[1] = DarkStonkEscrow.Take(b, 50 * ONE, PRICE + 1e12, sellerPayout, bytes32(uint256(2)));
        uint256 cost = 100 * PRICE + 50 * (PRICE + 1e12);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        uint256 before = coin.balanceOf(taker);
        vm.prank(taker);
        esc.takeSells{value: cost}(t, taker, block.timestamp + 120, sig);
        assertEq(coin.balanceOf(taker) - before, 150 * ONE);
        assertEq(left(b), 50 * ONE);
    }

    function test_takeBuyPaysTheTakerInEth() public {
        bytes32 id = openBuy(1, 1 ether, PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 1000 * ONE, PRICE, buyerPayout, 1);
        bytes memory sig = sign(taker, taker, 1, t, block.timestamp + 120);
        uint256 cost = 1000 * PRICE; // 0.05 ETH
        uint256 eth = taker.balance;
        vm.prank(taker);
        esc.takeBuys(t, block.timestamp + 120, sig);
        assertEq(coin.balanceOf(buyerPayout), 1000 * ONE);
        assertEq(taker.balance - eth, cost - cost / 200);
        assertEq(fees.balance, cost / 200);
        assertEq(left(id), 1 ether - cost);
    }

    function test_takeBuyCantSpendMoreThanEscrowed() public {
        bytes32 id = openBuy(1, 0.01 ether, PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, 1000 * ONE, PRICE, buyerPayout, 1);
        bytes memory sig = sign(taker, taker, 1, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.TooMuch.selector);
        esc.takeBuys(t, block.timestamp + 120, sig);
    }

    function test_sideMustMatch() public {
        bytes32 id = openBuy(1, 1 ether, PRICE);
        DarkStonkEscrow.Take[] memory t = one(id, ONE, PRICE, buyerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.BadSide.selector);
        esc.takeSells{value: PRICE}(t, taker, block.timestamp + 120, sig);
    }

    function test_pausedStopsFills() public {
        bytes32 id = openSell(1, uint128(10 * ONE), PRICE);
        vm.prank(admin);
        esc.setConfig(matcher, fees, 50, true);
        DarkStonkEscrow.Take[] memory t = one(id, ONE, PRICE, sellerPayout, 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.Paused.selector);
        esc.takeSells{value: PRICE}(t, taker, block.timestamp + 120, sig);
    }

    function test_reentryFromAPayoutIsBlocked() public {
        Reenterer r = new Reenterer(esc);
        bytes32 c = esc.commitmentOf(PRICE, address(r), bytes32(uint256(1)));
        vm.prank(seller);
        bytes32 id = esc.openSell(1, PONS, uint128(10 * ONE), c, uint40(block.timestamp + 1 days));
        r.arm(id);
        DarkStonkEscrow.Take[] memory t = one(id, ONE, PRICE, address(r), 1);
        bytes memory sig = sign(taker, taker, 0, t, block.timestamp + 120);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.TransferFailed.selector);
        esc.takeSells{value: PRICE}(t, taker, block.timestamp + 120, sig);
    }

    /* ------------------------------------------------------------ crossing */

    function test_crossSettlesAtTheMidpoint() public {
        bytes32 s = openSell(1, uint128(1000 * ONE), PRICE);
        bytes32 b = openBuy(2, 1 ether, PRICE * 2);
        DarkStonkEscrow.Take memory st = DarkStonkEscrow.Take(s, 0, PRICE, sellerPayout, bytes32(uint256(1)));
        DarkStonkEscrow.Take memory bt = DarkStonkEscrow.Take(b, 0, PRICE * 2, buyerPayout, bytes32(uint256(2)));
        st.amount = 1; // only checked for non-zero; the amount crossed is the third argument
        bt.amount = 1;
        vm.prank(matcher);
        esc.cross(st, bt, 1000 * ONE);
        uint256 cost = (1000 * ONE * ((PRICE + PRICE * 2) / 2)) / ONE;
        assertEq(coin.balanceOf(buyerPayout), 1000 * ONE);
        assertEq(sellerPayout.balance, cost - cost / 200);
        assertEq(left(b), 1 ether - cost);
    }

    function test_onlyTheMatcherCrosses() public {
        bytes32 s = openSell(1, uint128(1000 * ONE), PRICE);
        bytes32 b = openBuy(2, 1 ether, PRICE * 2);
        DarkStonkEscrow.Take memory st = DarkStonkEscrow.Take(s, 1, PRICE, sellerPayout, bytes32(uint256(1)));
        DarkStonkEscrow.Take memory bt = DarkStonkEscrow.Take(b, 1, PRICE * 2, buyerPayout, bytes32(uint256(2)));
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.NotMatcher.selector);
        esc.cross(st, bt, 10 * ONE);
    }

    function test_noCrossWhenTheBuyIsBelowTheSell() public {
        bytes32 s = openSell(1, uint128(1000 * ONE), PRICE * 2);
        bytes32 b = openBuy(2, 1 ether, PRICE);
        DarkStonkEscrow.Take memory st = DarkStonkEscrow.Take(s, 1, PRICE * 2, sellerPayout, bytes32(uint256(1)));
        DarkStonkEscrow.Take memory bt = DarkStonkEscrow.Take(b, 1, PRICE, buyerPayout, bytes32(uint256(2)));
        vm.prank(matcher);
        vm.expectRevert(DarkStonkEscrow.NoCross.selector);
        esc.cross(st, bt, 10 * ONE);
    }

    /* ------------------------------------------------------------ admin */

    function test_feeIsCapped() public {
        vm.prank(admin);
        vm.expectRevert(DarkStonkEscrow.FeeTooHigh.selector);
        esc.setConfig(matcher, fees, 101, false);
    }

    function test_adminHandoverTakesTwoSteps() public {
        address next = makeAddr("next");
        vm.prank(admin);
        esc.proposeAdmin(next);
        assertEq(esc.admin(), admin);
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.NotAdmin.selector);
        esc.acceptAdmin();
        vm.prank(next);
        esc.acceptAdmin();
        assertEq(esc.admin(), next);
    }

    function test_onlyAdminSetsConfig() public {
        vm.prank(taker);
        vm.expectRevert(DarkStonkEscrow.NotAdmin.selector);
        esc.setConfig(taker, taker, 0, false);
    }
}
