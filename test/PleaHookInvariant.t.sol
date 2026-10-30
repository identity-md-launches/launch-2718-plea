// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OrderedHookFixture} from "test/helpers/OrderedHookFixture.sol";
import {HookHandler} from "test/helpers/HookHandler.sol";

abstract contract PleaHookInvariantBase is OrderedHookFixture {
    HookHandler internal handler;
    address[] internal holders;

    function includeDeadMan() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = seller;
        actors[1] = buyer;
        actors[2] = stranger;
        factory.send(IERC20(address(token)), buyer, 1e23);
        factory.send(IERC20(address(token)), stranger, 1e23);
        imd.transfer(seller, 1e23);
        handler = new HookHandler(hook, imd, swapper, owner, actors, judges);
        holders.push(address(this));
        holders.push(address(factory));
        holders.push(address(manager));
        holders.push(address(hook));
        holders.push(address(court));
        holders.push(address(swapper));
        holders.push(address(handler));
        for (uint256 i; i < actors.length; ++i) {
            holders.push(actors[i]);
            handler.preparePlea(i, 1000 ether);
        }
        handler.setFee(500);
        handler.sell(0, 1 ether);
        handler.buy(1 ether, false);
        handler.routerSell(1 ether, true);

        bytes4[] memory selectors = new bytes4[](includeDeadMan() ? 11 : 10);
        selectors[0] = handler.preparePlea.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.routerSell.selector;
        selectors[4] = handler.rejectedSlippage.selector;
        selectors[5] = handler.transfer.selector;
        selectors[6] = handler.donateToHook.selector;
        selectors[7] = handler.setFee.selector;
        selectors[8] = handler.collectFactoryFees.selector;
        selectors[9] = handler.advanceTime.selector;
        if (includeDeadMan()) selectors[10] = handler.triggerDeadMan.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyAndBothTokenBalancesAreConserved() public view {
        uint256 pleaSum;
        uint256 imdSum;
        for (uint256 i; i < holders.length; ++i) {
            pleaSum += token.balanceOf(holders[i]);
            imdSum += imd.balanceOf(holders[i]);
        }
        assertEq(pleaSum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), pleaSum);
        assertEq(imdSum, 1e30);
        assertEq(imd.totalSupply(), imdSum);
    }

    function invariant_onlyExplicitDonationsRemainInHookAndAllFeesReachCourt() public view {
        assertEq(token.balanceOf(address(hook)), handler.tokenDonations());
        assertEq(imd.balanceOf(address(hook)), handler.imdDonations());
        assertEq(imd.balanceOf(address(court)), handler.feesReceived());
        assertEq(court.prizePot(), handler.feesReceived());
        uint256 sold;
        for (uint256 id = 1; id <= court.saleCount(); ++id) {
            sold += court.sale(id).amount;
        }
        assertEq(sold, handler.gatedSold());
        if (handler.everFree()) assertTrue(hook.tradesFreely());
    }

    function afterInvariant() public view {
        assertGt(handler.buys(), 0);
        assertGt(handler.sells(), 0);
        assertGt(handler.rejectedSells(), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PleaHookToken0InvariantTest is PleaHookInvariantBase {
    function wantsToken0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PleaHookToken1InvariantTest is PleaHookInvariantBase {
    function wantsToken0() internal pure override returns (bool) {
        return false;
    }
}

/// @dev Keep the gate live throughout each sequence, complementing the permanent-shutdown campaigns above.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PleaHookGatedToken0InvariantTest is PleaHookInvariantBase {
    function wantsToken0() internal pure override returns (bool) {
        return true;
    }

    function includeDeadMan() internal pure override returns (bool) {
        return false;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PleaHookGatedToken1InvariantTest is PleaHookInvariantBase {
    function wantsToken0() internal pure override returns (bool) {
        return false;
    }

    function includeDeadMan() internal pure override returns (bool) {
        return false;
    }
}
