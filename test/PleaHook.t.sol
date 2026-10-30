// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {PleaCourt} from "../src/PleaCourt.sol";
import {IPleaCourt} from "../src/interfaces/IPleaCourt.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FactoryStub} from "./mocks/FactoryStub.sol";
import {PleaBase} from "./PleaBase.t.sol";

contract PleaHookTest is PleaBase {
    // ---------------------------------------------------------------- deployment and permissions

    function test_permissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeSwapReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
    }

    function test_ownerIsTheGivenOwnerNotTheFactory() public view {
        assertEq(hook.owner(), owner);
        assertTrue(hook.owner() != address(factory));
        assertEq(hook.factory(), address(factory));
        assertEq(hook.token(), address(token));
        assertEq(address(hook.court().letterbox()), address(hook.letterbox()));
    }

    function test_deployAtWrongAddressReverts() public {
        vm.expectRevert();
        new PleaHook(manager, address(token), owner, address(factory));
    }

    function test_poolBound() public view {
        assertTrue(hook.bound());
        assertEq(Currency.unwrap(hook.paired()), address(imd));
        assertEq(address(court.imd()), address(imd));
        assertEq(hook.tokenIsCurrency0(), sellIsZeroForOne());
        PoolKey memory k = hook.poolKey();
        assertEq(k.fee, POOL_FEE);
    }

    function test_initialize_secondPoolReverts() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        factory.initialize(other, SQRT_PRICE_1_1);
    }

    function test_initialize_fromStrangerReverts() public {
        // a fresh hook, so the only refusal is the sender
        FactoryStub f2 = new FactoryStub(manager);
        bytes memory code =
            abi.encodePacked(type(PleaHook).creationCode, abi.encode(manager, address(token), owner, address(f2)));
        PleaHook h2 = PleaHook(f2.deploy(code, mineSalt(address(f2), code, FLAGS)));
        PoolKey memory k = key;
        k.hooks = IHooks(address(h2));
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        assertFalse(h2.bound());
        f2.initialize(k, SQRT_PRICE_1_1);
        assertTrue(h2.bound());
    }

    function test_initialize_poolWithoutTokenReverts() public {
        FactoryStub f2 = new FactoryStub(manager);
        bytes memory code =
            abi.encodePacked(type(PleaHook).creationCode, abi.encode(manager, address(token), owner, address(f2)));
        PleaHook h2 = PleaHook(f2.deploy(code, mineSalt(address(f2), code, FLAGS)));
        MockERC20 a = new MockERC20("A", "A", 0);
        (address c0, address c1) = address(a) < address(imd) ? (address(a), address(imd)) : (address(imd), address(a));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(h2)));
        vm.expectRevert();
        f2.initialize(k, SQRT_PRICE_1_1);
    }

    function test_callbacksRefuseNonManager() public {
        vm.expectRevert(PleaHook.NotPoolManager.selector);
        hook.beforeInitialize(address(factory), key, SQRT_PRICE_1_1);
        vm.expectRevert(PleaHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(factory), key, ModifyLiquidityParams(-60, 60, 1, 0), "");
        vm.expectRevert(PleaHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, SQRT_PRICE_1_1 / 2), "");
        vm.expectRevert(PleaHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(seller, uint256(1), uint256(0)));
        vm.expectRevert(PleaCourt.NotHook.selector);
        court.authorizeSale(seller, 1);
        vm.expectRevert(PleaCourt.NotHook.selector);
        court.bind(address(imd));
    }

    // ---------------------------------------------------------------- buys

    function test_buyIsAlwaysOpen() public {
        uint256 before = token.balanceOf(address(swapper));
        buy(1e18);
        assertGt(token.balanceOf(address(swapper)), before);
    }

    function testFuzz_buyNeverBlocked(uint256 amount) public {
        amount = bound(amount, 1e9, 1e22);
        uint256 before = token.balanceOf(address(swapper));
        buy(amount);
        assertGt(token.balanceOf(address(swapper)), before);
    }

    function test_buyExactOutputOpen() public {
        bool zeroForOne = !sellIsZeroForOne();
        uint256 before = token.balanceOf(address(swapper));
        swapper.swapWithData(key, zeroForOne, int256(1e18), "");
        assertEq(token.balanceOf(address(swapper)) - before, 1e18);
    }

    // ---------------------------------------------------------------- sells through routers

    function test_sellThroughRouterRevertsWithoutPlea() public {
        vm.expectRevert();
        swapper.swap(key, sellIsZeroForOne(), 1e18);
    }

    function test_sellThroughRouterRevertsEvenWithApprovedPlea() public {
        submitAndApprove(seller, 1e18);
        // a router claiming the seller's identity in hookData gets nowhere: only the hook's own route sells
        vm.expectRevert();
        swapper.swapWithData(key, sellIsZeroForOne(), -int256(1e18), abi.encode(seller));
    }

    function test_sellExactOutputThroughRouterReverts() public {
        vm.expectRevert();
        swapper.swapWithData(key, sellIsZeroForOne(), int256(1e18), "");
    }

    // ---------------------------------------------------------------- sells through the hook

    function test_sellWithoutPleaReverts() public {
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        vm.expectRevert(PleaCourt.NoApprovedPlea.selector);
        hook.sell(1e18, 0);
        vm.stopPrank();
    }

    function test_sellWhilePendingReverts() public {
        vm.startPrank(seller);
        court.submitPlea("please", 1e18);
        token.approve(address(hook), 1e18);
        vm.expectRevert(PleaCourt.NoApprovedPlea.selector);
        hook.sell(1e18, 0);
        vm.stopPrank();
    }

    function test_sellInWindow() public {
        uint256 pleaId = submitAndApprove(seller, 2e18);
        (uint64 expiry, uint256 remaining) = hook.saleWindowExpiry(seller);
        assertEq(expiry, block.timestamp + 7 minutes);
        assertEq(remaining, 2e18);

        vm.startPrank(seller);
        token.approve(address(hook), 2e18);
        uint256 imdBefore = imd.balanceOf(seller);
        vm.expectEmit(true, true, false, false);
        emit PleaHook.SellExecuted(1, seller, 1e18, 0, 0, false);
        (uint256 saleId, uint256 out) = hook.sell(1e18, 0);
        vm.stopPrank();

        assertEq(saleId, 1);
        assertGt(out, 0);
        assertEq(imd.balanceOf(seller) - imdBefore, out);
        assertEq(token.balanceOf(address(hook)), 0, "hook keeps no PLEA");
        IPleaCourt.Sale memory s = court.sale(1);
        assertEq(s.seller, seller);
        assertEq(s.amount, 1e18);
        assertEq(s.pleaId, pleaId);
        (, remaining) = hook.saleWindowExpiry(seller);
        assertEq(remaining, 1e18);
        assertEq(uint8(hook.pleaStatus(pleaId)), uint8(IPleaCourt.Status.Approved));
    }

    function test_sellWholeAmountClosesWindow() public {
        uint256 pleaId = submitAndApprove(seller, 1e18);
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        vm.expectEmit(true, true, false, true);
        emit PleaCourt.SaleWindowClosed(pleaId, seller, 1e18, false);
        hook.sell(1e18, 0);
        vm.stopPrank();
        assertEq(uint8(court.pleaStatus(pleaId)), uint8(IPleaCourt.Status.Closed));
        assertEq(court.activePlea(seller), 0);
        // and the seller can plead again
        vm.prank(seller);
        court.submitPlea("again", 1);
    }

    function test_sellMoreThanApprovedReverts() public {
        submitAndApprove(seller, 1e18);
        vm.startPrank(seller);
        token.approve(address(hook), 2e18);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.ExceedsApprovedAmount.selector, 1e18));
        hook.sell(1e18 + 1, 0);
        vm.stopPrank();
    }

    function test_sellAfterWindowReverts() public {
        uint256 pleaId = submitAndApprove(seller, 1e18);
        uint64 expiry = court.plea(pleaId).windowExpiry;
        vm.warp(expiry + 1);
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WindowExpired.selector, expiry));
        hook.sell(1e18, 0);
        vm.stopPrank();
        (uint64 e, uint256 r) = hook.saleWindowExpiry(seller);
        assertEq(e, 0);
        assertEq(r, 0);
    }

    function test_sellAtWindowEdgeSucceeds() public {
        uint256 pleaId = submitAndApprove(seller, 1e18);
        vm.warp(court.plea(pleaId).windowExpiry);
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        hook.sell(1e18, 0);
        vm.stopPrank();
    }

    function test_sellMinOutReverts() public {
        submitAndApprove(seller, 1e18);
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        vm.expectRevert();
        hook.sell(1e18, 1e18); // the 1.25% LP fee alone makes 1:1 impossible
        vm.stopPrank();
    }

    function test_sellByOtherSellerWindowReverts() public {
        submitAndApprove(seller, 1e18);
        factory.send(IERC20(address(token)), stranger, 1e18);
        vm.startPrank(stranger);
        token.approve(address(hook), 1e18);
        vm.expectRevert(PleaCourt.NoApprovedPlea.selector);
        hook.sell(1e18, 0);
        vm.stopPrank();
    }

    function test_sellZeroReverts() public {
        vm.prank(seller);
        vm.expectRevert(PleaHook.ZeroAmount.selector);
        hook.sell(0, 0);
    }

    function test_potFeeFundsTheCourt() public {
        vm.prank(owner);
        hook.setPotFeeBps(500);
        submitAndApprove(seller, 1e18);
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        (, uint256 net) = hook.sell(1e18, 0);
        vm.stopPrank();
        uint256 fee = imd.balanceOf(address(court));
        assertGt(fee, 0);
        assertEq(court.prizePot(), fee);
        // fee is 5% of the gross output: net = gross - gross * 5%
        uint256 gross = net + fee;
        assertEq(fee, gross * 500 / 10_000);
    }

    function test_setPotFee() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.setPotFeeBps(1);
        vm.prank(owner);
        vm.expectRevert(PleaHook.FeeTooHigh.selector);
        hook.setPotFeeBps(1001);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PleaHook.PotFeeSet(1000);
        hook.setPotFeeBps(1000);
        assertEq(hook.potFeeBps(), 1000);
    }

    // ---------------------------------------------------------------- liquidity

    function test_strangerCannotAddLiquidity() public {
        FactoryStub lp = new FactoryStub(manager);
        imd.transfer(address(lp), 1e20);
        factory.send(IERC20(address(token)), address(lp), 1e20);
        vm.expectRevert();
        lp.modify(key, -60, 60, 1e18);
        vm.prank(owner);
        hook.setLiquidityProvider(address(lp), true);
        lp.modify(key, -60, 60, 1e18);
        lp.modify(key, -60, 60, -1e18);
    }

    function test_factoryCollectsFeesWithZeroLiquidityChange() public {
        buy(1e20);
        (int128 a0, int128 a1) =
            factory.modify(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0);
        assertTrue(a0 >= 0 && a1 >= 0);
        assertTrue(a0 > 0 || a1 > 0, "fees accrued");
    }

    function test_factoryCanRemoveLiquidity() public {
        factory.modify(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), -1e20);
    }

    // ---------------------------------------------------------------- dead-man switch

    function test_deadManFreesSellsEverywhere() public {
        vm.prank(seller);
        court.submitPlea("nobody listens", 1e18);
        (uint64 deadline, uint256 left, bool fired) = hook.deadManTimer();
        assertEq(deadline, block.timestamp + 33 hours);
        assertEq(left, 33 hours);
        assertFalse(fired);

        vm.warp(deadline - 1);
        assertFalse(hook.tradesFreely());
        vm.expectRevert();
        swapper.swap(key, sellIsZeroForOne(), 1e18);
        vm.expectRevert(PleaCourt.DeadManNotDue.selector);
        court.triggerDeadManSwitch();

        vm.warp(deadline);
        assertTrue(hook.tradesFreely());
        swapper.swap(key, sellIsZeroForOne(), 1e18); // any router
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.DeadManSwitchTriggered(uint64(block.timestamp), deadline);
        court.triggerDeadManSwitch();
        assertTrue(court.deadManTriggered());

        // the hook's own route also works without a plea, no fee is owed to a plea
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        (uint256 saleId,) = hook.sell(1e18, 0);
        vm.stopPrank();
        assertEq(saleId, 0);

        // and liquidity is open
        FactoryStub lp = new FactoryStub(manager);
        imd.transfer(address(lp), 1e20);
        factory.send(IERC20(address(token)), address(lp), 1e20);
        lp.modify(key, -60, 60, 1e18);
    }

    function test_deadManIsPermanentEvenIfTheCabalWakesUp() public {
        vm.prank(seller);
        uint256 pleaId = court.submitPlea("late", 1e18);
        vm.warp(block.timestamp + 33 hours);
        assertTrue(court.tradesFreely());
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.FreeTrading.selector);
        court.judge(pleaId, 45, 26);
        assertTrue(court.tradesFreely());
        // withdrawing the only pending plea latches the switch instead of resetting the timer
        vm.prank(seller);
        court.withdrawPlea(pleaId);
        assertTrue(court.deadManTriggered());
        assertTrue(court.tradesFreely());
        assertEq(court.pendingCount(), 0);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.FreeTrading.selector);
        court.submitPlea("too late", 1);
    }

    function test_verdictRestartsTheTimer() public {
        vm.prank(seller);
        uint256 a = court.submitPlea("a", 1e18);
        vm.warp(block.timestamp + 20 hours);
        vm.prank(stranger);
        court.submitPlea("b", 1e18);
        denyPlea(a);
        (uint64 deadline,,) = court.deadManTimer();
        assertEq(deadline, block.timestamp + 33 hours);
        vm.warp(block.timestamp + 13 hours + 1); // 33h after the first plea
        assertFalse(court.tradesFreely());
        vm.warp(block.timestamp + 20 hours);
        assertTrue(court.tradesFreely());
    }

    function test_noTimerWithoutPendingPlea() public {
        (uint64 deadline,, bool fired) = court.deadManTimer();
        assertEq(deadline, 0);
        assertFalse(fired);
        vm.warp(block.timestamp + 100 days);
        assertFalse(court.tradesFreely());
        vm.expectRevert(PleaCourt.DeadManNotDue.selector);
        court.triggerDeadManSwitch();
        vm.prank(seller);
        uint256 id = court.submitPlea("x", 1);
        vm.prank(seller);
        court.withdrawPlea(id);
        (deadline,,) = court.deadManTimer();
        assertEq(deadline, 0);
    }
}
