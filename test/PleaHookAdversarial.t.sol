// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PleaCourt} from "src/PleaCourt.sol";
import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {FactoryStub} from "test/mocks/FactoryStub.sol";
import {OrderedHookFixture} from "test/helpers/OrderedHookFixture.sol";

abstract contract PleaHookAdversarialBase is OrderedHookFixture {
    using StateLibrary for IPoolManager;

    function wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_spoofedHookDataCannotSellExactInputOrExactOutput() public {
        submitAndApprove(seller, 10 ether);
        bytes memory data = abi.encode(seller, address(hook), true);
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, PleaHook.SellRequiresPlea.selector));
        swapper.swapWithData(key, sellIsZeroForOne(), -int256(1 ether), data);
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, PleaHook.SellRequiresPlea.selector));
        swapper.swapWithData(key, sellIsZeroForOne(), int256(1 ether), data);
        assertEq(court.saleCount(), 0);
        (, uint256 remaining) = court.saleWindow(seller);
        assertEq(remaining, 10 ether);
    }

    function test_insufficientAllowanceRollsBackAuthorizationAndCanBeRetried() public {
        uint256 id = submitAndApprove(seller, 1 ether);
        uint256 beforeBalance = token.balanceOf(seller);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, 1 ether)
        );
        hook.sell(1 ether, 0);
        assertEq(court.plea(id).sold, 0);
        assertEq(court.saleCount(), 0);
        assertEq(court.activePlea(seller), id);
        assertEq(token.balanceOf(seller), beforeBalance);
        vm.startPrank(seller);
        token.approve(address(hook), 1 ether);
        (uint256 sale,) = hook.sell(1 ether, 1);
        vm.stopPrank();
        assertEq(sale, 1);
        assertEq(court.plea(id).sold, 1 ether);
    }

    function test_slippageFailureRollsBackPoolFeeAllowanceAndCourt() public {
        uint256 id = submitAndApprove(seller, 1 ether);
        vm.prank(owner);
        hook.setPotFeeBps(1000);
        (uint160 beforePrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint256 beforeToken = token.balanceOf(seller);
        uint256 beforeImd = imd.balanceOf(seller);
        vm.startPrank(seller);
        token.approve(address(hook), 1 ether);
        vm.expectPartialRevert(PleaHook.InsufficientOutput.selector);
        hook.sell(1 ether, type(uint256).max);
        vm.stopPrank();
        (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(court.plea(id).sold, 0);
        assertEq(court.activePlea(seller), id);
        assertEq(court.saleCount(), 0);
        assertEq(imd.balanceOf(address(court)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(seller), beforeToken);
        assertEq(imd.balanceOf(seller), beforeImd);
        assertEq(token.allowance(seller, address(hook)), 1 ether);
        vm.prank(seller);
        (, uint256 proceeds) = hook.sell(1 ether, 1);
        assertGt(proceeds, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeAndSplitSalesConserveBothCurrencies(uint96 seed, uint16 feeSeed) public {
        uint256 amount = bound(seed, 2, 100 ether);
        uint16 rate = uint16(bound(feeSeed, 0, 1000));
        vm.prank(owner);
        hook.setPotFeeBps(rate);
        uint256 id = submitAndApprove(seller, amount);
        uint256 initial = token.balanceOf(seller);
        vm.startPrank(seller);
        token.approve(address(hook), amount);
        uint256 first = amount / 2;
        (, uint256 net1) = hook.sell(first, 0);
        (, uint256 net2) = hook.sell(amount - first, 0);
        vm.stopPrank();
        uint256 fees = imd.balanceOf(address(court));
        uint256 gross = net1 + net2 + fees;
        assertEq(token.balanceOf(seller), initial - amount);
        assertEq(imd.balanceOf(seller), net1 + net2);
        assertEq(court.prizePot(), fees);
        assertLe(fees * 10_000, gross * rate);
        assertLt(gross * rate - fees * 10_000, 20_000, "at most two fee-rounding remainders");
        assertEq(court.plea(id).sold, amount);
        assertEq(court.sale(1).amount + court.sale(2).amount, amount);
        assertEq(court.activePlea(seller), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_donationsCannotSubsidizeUnauthorizedSeller() public {
        factory.send(IERC20(address(token)), address(hook), 5 ether);
        imd.transfer(address(hook), 7 ether);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NoApprovedPlea.selector);
        hook.sell(1 ether, 0);
        submitAndApprove(seller, 1 ether);
        vm.startPrank(seller);
        token.approve(address(hook), 1 ether);
        hook.sell(1 ether, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(address(hook)), 5 ether);
        assertEq(imd.balanceOf(address(hook)), 7 ether);
    }

    function test_buyOnFreshTokenOnlyPoolNeedsNoExistingIMD() public {
        launch(false);
        int24 lower = sellIsZeroForOne() ? int24(60) : int24(-120);
        factory.modify(key, lower, lower + 60, 1e21);
        assertEq(imd.balanceOf(address(manager)), 0);
        vm.prank(owner);
        hook.setPotFeeBps(1000);
        uint256 beforeBalance = token.balanceOf(address(swapper));
        buy(1 ether);
        assertGt(token.balanceOf(address(swapper)), beforeBalance);
        assertGt(imd.balanceOf(address(manager)), 0);
        assertEq(imd.balanceOf(address(court)), 0, "buy must not pay a sell pot fee");
    }

    function test_emptyPoolCannotConsumeApprovalWhenMinimumOutputIsPositive() public {
        launch(false);
        uint256 id = submitAndApprove(seller, 1 ether);
        vm.startPrank(seller);
        token.approve(address(hook), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PleaHook.InsufficientOutput.selector, 0, 1));
        hook.sell(1 ether, 1);
        vm.stopPrank();
        assertEq(court.plea(id).sold, 0);
        assertEq(court.saleCount(), 0);
        assertEq(court.activePlea(seller), id);
    }

    function test_revokedLPStillCollectsAndWithdrawsButCannotIncreasePosition() public {
        FactoryStub lp = new FactoryStub(manager);
        imd.transfer(address(lp), 10 ether);
        factory.send(IERC20(address(token)), address(lp), 10 ether);
        vm.prank(owner);
        hook.setLiquidityProvider(address(lp), true);
        lp.modify(key, -600, 600, 1 ether);
        vm.prank(owner);
        hook.setLiquidityProvider(address(lp), false);
        buy(1 ether);
        (int128 a, int128 b) = lp.modify(key, -600, 600, 0);
        assertTrue(a > 0 || b > 0);
        vm.expectRevert(wrapped(IHooks.beforeAddLiquidity.selector, PleaHook.LiquidityRestricted.selector));
        lp.modify(key, -600, 600, 1);
        (a, b) = lp.modify(key, -600, 600, -int256(1 ether));
        assertTrue(a > 0 && b > 0);
        vm.prank(owner);
        hook.setLiquidityProvider(address(factory), false);
        factory.modify(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0);
    }

    function test_ownerTransferMovesCourtAndHookPermissionsTogether() public {
        vm.prank(owner);
        hook.transferOwnership(stranger);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.setPotFeeBps(1);
        vm.prank(owner);
        vm.expectRevert(PleaCourt.NotOwner.selector);
        court.setSeat(seller, true);
        vm.prank(stranger);
        hook.setPotFeeBps(1000);
        vm.prank(stranger);
        court.setSeat(seller, true);
        assertTrue(court.hasSeat(seller));
        assertEq(hook.potFeeBps(), 1000);
        buy(1 ether);
    }

    function test_buyUnaffectedByPendingDeniedExpiredAndBannedSeller() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("facts", 1 ether);
        buy(1 ether);
        denyPlea(id);
        buy(1 ether);
        vm.warp(block.timestamp + 4 hours);
        vm.prank(seller);
        court.appeal(id);
        approvePlea(id);
        vm.startPrank(seller);
        token.approve(address(hook), 1 ether);
        (uint256 sale,) = hook.sell(1 ether, 1);
        vm.stopPrank();
        vm.startPrank(stranger);
        imd.approve(address(court), 1 ether);
        uint256 oid = court.object(sale);
        vm.stopPrank();
        for (uint256 i; i < 17; ++i) {
            vm.prank(judges[i]);
            court.ruleObjection(oid, true);
        }
        assertGt(court.bannedUntil(seller), block.timestamp);
        buy(1 ether);
        submitAndApprove(buyer, 1 ether);
        vm.warp(block.timestamp + 7 minutes + 1);
        uint256 beforeBalance = token.balanceOf(address(swapper));
        swapper.swapWithData(key, !sellIsZeroForOne(), int256(1 ether), abi.encode(seller));
        assertEq(token.balanceOf(address(swapper)), beforeBalance + 1 ether);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract PleaHookToken0AdversarialTest is PleaHookAdversarialBase {
    function wantsToken0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract PleaHookToken1AdversarialTest is PleaHookAdversarialBase {
    function wantsToken0() internal pure override returns (bool) {
        return false;
    }
}
