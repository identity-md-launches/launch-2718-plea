// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PleaCourt} from "src/PleaCourt.sol";
import {PleaHook} from "src/PleaHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {AdversarialIMD} from "test/mocks/AdversarialIMD.sol";
import {OrderedHookFixture} from "test/helpers/OrderedHookFixture.sol";

contract PleaExternalCallsTest is OrderedHookFixture {
    function wantsToken0() internal pure override returns (bool) {
        return true;
    }

    function pairCreationCode() internal pure override returns (bytes memory) {
        return type(AdversarialIMD).creationCode;
    }

    function deployPair(bytes32 salt) internal override returns (MockERC20) {
        return new AdversarialIMD{salt: salt}();
    }

    function approvedSale() internal returns (uint256 saleId) {
        submitAndApprove(seller, 1 ether);
        vm.startPrank(seller);
        token.approve(address(hook), 1 ether);
        (saleId,) = hook.sell(1 ether, 1);
        vm.stopPrank();
    }

    function uphold(uint256 oid) internal {
        for (uint256 i; i < 17; ++i) {
            vm.prank(judges[i]);
            court.ruleObjection(oid, true);
        }
    }

    function test_reentrantSellDuringIMDOutputIsRejectedAndOuterSaleSettles() public {
        AdversarialIMD pair = AdversarialIMD(address(imd));
        pair.setCallback(seller, address(hook), abi.encodeCall(PleaHook.sell, (1, 0)));
        uint256 saleId = approvedSale();
        assertEq(pair.attempts(), 1);
        assertFalse(pair.callbackSucceeded());
        assertEq(pair.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(court.sale(saleId).amount, 1 ether);
        assertGt(imd.balanceOf(seller), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_reentrantClaimCannotWithdrawTheSameBondTwice() public {
        AdversarialIMD pair = AdversarialIMD(address(imd));
        uint256 saleId = approvedSale();
        imd.transfer(address(pair), 1 ether);
        pair.execute(address(imd), abi.encodeWithSignature("approve(address,uint256)", address(court), 1 ether));
        uint256 oid = abi.decode(pair.execute(address(court), abi.encodeCall(PleaCourt.object, (saleId))), (uint256));
        uphold(oid);
        pair.setCallback(address(pair), address(court), abi.encodeCall(PleaCourt.claim, ()));
        pair.execute(address(court), abi.encodeCall(PleaCourt.claim, ()));
        assertEq(pair.attempts(), 1);
        assertFalse(pair.callbackSucceeded());
        assertEq(pair.callbackResult(), abi.encodeWithSelector(PleaCourt.NothingToClaim.selector));
        assertEq(imd.balanceOf(address(pair)), 1 ether);
        assertEq(court.claimable(address(pair)), 0);
        assertEq(court.totalClaimable(), 0);
        assertEq(court.bondsHeld(), 0);
    }

    function test_rejectedClaimTransferRestoresCreditAndOtherUsersRemainIndependent() public {
        uint256 saleId = approvedSale();
        vm.startPrank(stranger);
        imd.approve(address(court), 1 ether);
        uint256 oid = court.object(saleId);
        vm.stopPrank();
        uphold(oid);
        AdversarialIMD pair = AdversarialIMD(address(imd));
        pair.setRejection(stranger, true);
        uint256 beforeBalance = imd.balanceOf(stranger);
        vm.prank(stranger);
        vm.expectRevert(AdversarialIMD.TransferRefused.selector);
        court.claim();
        assertEq(court.claimable(stranger), 1 ether);
        assertEq(court.totalClaimable(), 1 ether);
        assertEq(imd.balanceOf(stranger), beforeBalance);
        assertEq(imd.balanceOf(address(court)), 1 ether);
        // A blocked claimant cannot block buyers or season rollover.
        buy(1 ether);
        vm.warp(block.timestamp + 30 days);
        court.endSeason();
        assertEq(court.claimable(stranger), 1 ether);
        pair.setRejection(stranger, false);
        vm.prank(stranger);
        court.claim();
        assertEq(imd.balanceOf(stranger), beforeBalance + 1 ether);
        assertEq(court.totalClaimable(), 0);
    }

    function test_falseReturningBondTransferCannotMarkSaleObjected() public {
        uint256 saleId = approvedSale();
        AdversarialIMD pair = AdversarialIMD(address(imd));
        pair.setReturnFalse(true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        court.object(saleId);
        assertFalse(court.sale(saleId).objected);
        assertEq(court.objectionCount(), 0);
        assertEq(court.bondsHeld(), 0);
        pair.setReturnFalse(false);
        vm.startPrank(stranger);
        imd.approve(address(court), 1 ether);
        court.object(saleId);
        vm.stopPrank();
        assertEq(court.bondsHeld(), 1 ether);
    }
}
