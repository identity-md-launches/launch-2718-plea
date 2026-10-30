// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PleaCourt} from "src/PleaCourt.sol";
import {PLEAToken} from "src/PLEAToken.sol";
import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {FactoryStub} from "test/mocks/FactoryStub.sol";
import {Swapper} from "test/mocks/Swapper.sol";

contract HookHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    PleaHook public immutable hook;
    PleaCourt public immutable court;
    PLEAToken public immutable token;
    MockERC20 public immutable imd;
    IPoolManager public immutable manager;
    Swapper public immutable swapper;
    FactoryStub public immutable factory;
    address public immutable admin;
    PoolKey internal key;
    address[] public actors;
    address[] internal judges;
    uint256 public tokenDonations;
    uint256 public imdDonations;
    uint256 public feesReceived;
    uint256 public gatedSold;
    uint256 public buys;
    uint256 public sells;
    uint256 public rejectedSells;
    bool public everFree;

    constructor(
        PleaHook hook_,
        MockERC20 imd_,
        Swapper swapper_,
        address admin_,
        address[] memory actors_,
        address[] memory judges_
    ) {
        hook = hook_;
        court = hook_.court();
        token = PLEAToken(hook_.token());
        imd = imd_;
        manager = hook_.poolManager();
        swapper = swapper_;
        factory = FactoryStub(hook_.factory());
        admin = admin_;
        key = hook_.poolKey();
        actors = actors_;
        judges = judges_;
    }

    function actor(uint256 seed) public view returns (address) {
        return actors[seed % actors.length];
    }

    function preparePlea(uint256 seed, uint96 amountSeed) public {
        if (hook.tradesFreely()) return;
        address who = actor(seed);
        uint256 active = court.activePlea(who);
        if (active != 0) {
            IPleaCourt.Plea memory p = court.plea(active);
            if (p.status == IPleaCourt.Status.Approved && block.timestamp > p.windowExpiry) court.closeWindow(active);
            else return;
        }
        uint256 amount = bound(amountSeed, 1, 1e22);
        vm.prank(who);
        uint256 id = court.submitPlea("stateful integration plea", amount);
        for (uint256 i; i < 17; ++i) {
            vm.prank(judges[i]);
            court.judge(id, 45, 26);
        }
    }

    function sell(uint256 seed, uint96 amountSeed) public {
        address who = actor(seed);
        uint256 maximum = spendable(who);
        if (maximum == 0) return;
        uint256 amount = bound(amountSeed, 1, maximum);
        uint256 beforeToken = token.balanceOf(who);
        uint256 beforeIMD = imd.balanceOf(who);
        uint256 beforeManagerIMD = imd.balanceOf(address(manager));
        uint256 beforePot = imd.balanceOf(address(court));
        bool free = hook.tradesFreely();
        vm.startPrank(who);
        token.approve(address(hook), amount);
        (uint256 saleId, uint256 out) = hook.sell(amount, 0);
        vm.stopPrank();
        uint256 spent = beforeToken - token.balanceOf(who);
        uint256 fee = imd.balanceOf(address(court)) - beforePot;
        assertEq(imd.balanceOf(who) - beforeIMD, out);
        assertEq(beforeManagerIMD - imd.balanceOf(address(manager)), out + fee);
        assertEq(spent, amount, "full-range fixture must fully execute these bounded swaps");
        if (!free) {
            assertEq(court.sale(saleId).seller, who);
            assertEq(court.sale(saleId).amount, spent);
            gatedSold += spent;
        }
        feesReceived += fee;
        sells++;
        settled();
    }

    function spendable(address who) internal view returns (uint256 maximum) {
        maximum = token.balanceOf(who);
        if (maximum > 100 ether) maximum = 100 ether;
        if (!hook.tradesFreely()) {
            (, uint256 remaining) = court.saleWindow(who);
            if (remaining < maximum) maximum = remaining;
        }
    }

    function buy(uint96 amountSeed, bool exactOutput) public {
        uint256 amount = bound(amountSeed, 1, 10 ether);
        uint256 beforeToken = token.balanceOf(address(swapper));
        uint256 beforeIMD = imd.balanceOf(address(swapper));
        uint256 beforePot = imd.balanceOf(address(court));
        swapper.swapWithData(key, !hook.tokenIsCurrency0(), exactOutput ? int256(amount) : -int256(amount), "");
        uint256 paid = beforeIMD - imd.balanceOf(address(swapper));
        uint256 received = token.balanceOf(address(swapper)) - beforeToken;
        if (exactOutput) assertEq(received, amount);
        else assertEq(paid, amount);
        assertEq(imd.balanceOf(address(court)), beforePot, "buy paid a pot fee");
        buys++;
        settled();
    }

    function routerSell(uint96 amountSeed, bool exactOutput) public {
        uint256 amount = bound(amountSeed, 1, 10 ether);
        uint256 beforeToken = token.balanceOf(address(swapper));
        uint256 beforeIMD = imd.balanceOf(address(swapper));
        bool zeroForOne = hook.tokenIsCurrency0();
        if (!hook.tradesFreely()) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(PleaHook.SellRequiresPlea.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            swapper.swapWithData(key, zeroForOne, exactOutput ? int256(amount) : -int256(amount), abi.encode(actor(0)));
            assertEq(token.balanceOf(address(swapper)), beforeToken);
            assertEq(imd.balanceOf(address(swapper)), beforeIMD);
            rejectedSells++;
        } else {
            swapper.swapWithData(key, zeroForOne, exactOutput ? int256(amount) : -int256(amount), abi.encode(actor(0)));
            if (exactOutput) assertEq(imd.balanceOf(address(swapper)) - beforeIMD, amount);
            else assertEq(beforeToken - token.balanceOf(address(swapper)), amount);
        }
        settled();
    }

    function rejectedSlippage(uint256 seed) public {
        address who = actor(seed);
        uint256 amount = spendable(who);
        if (amount == 0) return;
        uint256 active = court.activePlea(who);
        bytes32 beforePlea = keccak256(abi.encode(court.plea(active)));
        uint256 beforeSales = court.saleCount();
        uint256 beforeToken = token.balanceOf(who);
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        vm.startPrank(who);
        token.approve(address(hook), amount);
        vm.expectPartialRevert(PleaHook.InsufficientOutput.selector);
        hook.sell(amount, type(uint256).max);
        vm.stopPrank();
        assertEq(token.balanceOf(who), beforeToken);
        assertEq(token.allowance(who, address(hook)), amount);
        assertEq(keccak256(abi.encode(court.plea(active))), beforePlea);
        assertEq(court.saleCount(), beforeSales);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        settled();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint96 amountSeed, bool allowanceRoute) public {
        address from = actor(fromSeed);
        address to = actor(toSeed);
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        if (allowanceRoute) {
            vm.prank(from);
            token.approve(address(this), amount);
            token.transferFrom(from, to, amount);
            assertEq(token.allowance(from, address(this)), 0);
        } else {
            vm.prank(from);
            token.transfer(to, amount);
        }
        assertEq(token.balanceOf(from), from == to ? beforeFrom : beforeFrom - amount);
        assertEq(token.balanceOf(to), from == to ? beforeTo : beforeTo + amount);
    }

    function donateToHook(uint256 seed, uint96 amountSeed, bool paired) public {
        address who = actor(seed);
        uint256 available = paired ? imd.balanceOf(who) : token.balanceOf(who);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(who);
        if (paired) imd.transfer(address(hook), amount);
        else token.transfer(address(hook), amount);
        if (paired) imdDonations += amount;
        else tokenDonations += amount;
    }

    function setFee(uint16 seed) public {
        uint16 fee = uint16(bound(seed, 0, 1000));
        vm.prank(admin);
        hook.setPotFeeBps(fee);
    }

    function collectFactoryFees() public {
        (int128 a, int128 b) =
            factory.modify(key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), 0);
        assertTrue(a >= 0 && b >= 0);
        settled();
    }

    function advanceTime(uint16 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 8 minutes));
    }

    function triggerDeadMan() public {
        if (hook.tradesFreely()) return;
        court.submitPlea("unanswered plea from an independent seller", 1);
        uint64 deadline = court.deadManDeadline();
        vm.warp(deadline);
        court.triggerDeadManSwitch();
        everFree = true;
    }

    // Checked before this handler transaction ends, so transient state checks cannot pass merely by reset.
    function settled() internal view {
        assertFalse(manager.isUnlocked(), "manager stayed unlocked");
        assertEq(manager.getNonzeroDeltaCount(), 0, "unsettled currencies");
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(swapper), key.currency0), 0);
        assertEq(manager.currencyDelta(address(swapper), key.currency1), 0);
        assertEq(token.balanceOf(address(hook)), tokenDonations, "hook retained or spent donated PLEA");
        assertEq(imd.balanceOf(address(hook)), imdDonations, "hook retained or spent donated IMD");
    }
}
