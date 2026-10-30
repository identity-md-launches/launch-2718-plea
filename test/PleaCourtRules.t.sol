// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PleaCourt} from "../src/PleaCourt.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {IPleaCourt} from "../src/interfaces/IPleaCourt.sol";
import {PleaBase} from "./PleaBase.t.sol";

/// @dev Stands in for PleaHook where a court with no Cabal is needed: the court reads only `owner()`.
contract HookStub {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @notice The rules added by the review: hung Cabal verdicts, withdrawal after votes, the Cabal before
/// pleas, denial cooldowns, bans that bite everywhere, strikes that reach ended seasons and promote the
/// bench, recusal, objection precedence, the post-switch pot, and partial fills.
contract PleaCourtRulesTest is PleaBase {
    function _sell(address who, uint256 amount) internal returns (uint256 saleId) {
        vm.startPrank(who);
        token.approve(address(hook), amount);
        (saleId,) = hook.sell(amount, 0);
        vm.stopPrank();
    }

    function _object(address who, uint256 saleId) internal returns (uint256 objectionId) {
        vm.startPrank(who);
        imd.approve(address(court), court.OBJECTION_BOND());
        objectionId = court.object(saleId);
        vm.stopPrank();
    }

    /// @dev 16 upholds; the caller casts the 17th so it can expect its events.
    function _uphold16(uint256 objectionId) internal {
        for (uint256 i = 0; i < 16; i++) {
            vm.prank(judges[i]);
            court.ruleObjection(objectionId, true);
        }
    }

    function _uphold(uint256 objectionId) internal {
        _uphold16(objectionId);
        vm.prank(judges[16]);
        court.ruleObjection(objectionId, true);
    }

    // ---------------------------------------------------------------- hung Cabal

    function test_hungCabalDeniesAndStopsTheClock() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("borderline", 1e18);
        score(id, 16, 45, 26); // 16 approve
        for (uint256 i = 16; i < 29; i++) {
            vm.prank(judges[i]);
            court.judge(id, 44, 26); // 13 deny
        }
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Pending));
        // sorted scores: 14 x 44 then 16 x 45, so both middle values are 45
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.Verdict(id, seller, 1, false, 45, 16, 14);
        vm.prank(judges[29]);
        court.judge(id, 44, 26);
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(uint8(p.status), uint8(IPleaCourt.Status.Denied));
        assertEq(p.approveVotes, 16);
        assertEq(p.denyVotes, 14);
        assertEq(court.pendingCount(), 0);
        assertEq(court.deadManDeadline(), 0);
        assertEq(court.lastVerdictAt(), block.timestamp);
        assertEq(court.seasonPoints(1, seller), 0);
        vm.warp(block.timestamp + 33 hours);
        assertFalse(court.tradesFreely());
        // the seller may appeal a hung verdict like any denial
        vm.prank(seller);
        court.appeal(id);
        assertEq(court.plea(id).round, 2);
    }

    // ---------------------------------------------------------------- withdrawal

    function test_withdrawRefusedOnceVotesAreCast() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("x", 1e18);
        vm.prank(judges[0]);
        court.judge(id, 45, 26);
        vm.prank(seller);
        vm.expectRevert(PleaCourt.VotesCast.selector);
        court.withdrawPlea(id);
        assertEq(court.pendingCount(), 1);
        // an unvoted plea withdraws freely
        vm.prank(stranger);
        uint256 other = court.submitPlea("y", 1);
        vm.prank(stranger);
        court.withdrawPlea(other);
        assertEq(court.pendingCount(), 1);
        // the verdict lands and resets the clock
        for (uint256 i = 1; i < 17; i++) {
            vm.prank(judges[i]);
            court.judge(id, 45, 26);
        }
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Approved));
    }

    function test_withdrawVotedPleaAllowedAfterTheSwitch() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("x", 1e18);
        vm.prank(judges[0]);
        court.judge(id, 45, 26);
        vm.warp(block.timestamp + 33 hours);
        vm.prank(seller);
        court.withdrawPlea(id);
        assertTrue(court.deadManTriggered());
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Withdrawn));
    }

    // ---------------------------------------------------------------- the Cabal before pleas

    function test_noPleaBeforeTheCabalIsSet() public {
        PleaCourt fresh = new PleaCourt(address(new HookStub(owner)));
        assertFalse(fresh.cabalConfigured());
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.CabalNotConfigured.selector);
        fresh.submitPlea("x", 1);
        vm.warp(block.timestamp + 100 days);
        assertFalse(fresh.tradesFreely(), "no plea, no clock");
        vm.prank(owner);
        fresh.setJudges(judges);
        vm.prank(stranger);
        fresh.submitPlea("x", 1);
        (uint64 deadline,,) = fresh.deadManTimer();
        assertEq(deadline, block.timestamp + 33 hours);
    }

    function test_amountAboveUint128Reverts() public {
        vm.prank(seller);
        vm.expectRevert(PleaCourt.AmountTooLarge.selector);
        court.submitPlea("t", 2 ** 128);
        vm.prank(seller);
        court.submitPlea("t", 2 ** 128 - 1);
    }

    // ---------------------------------------------------------------- denial cooldown

    function test_deniedSellerGetsOneRehearingThenACooldown() public {
        vm.prank(seller);
        uint256 id1 = court.submitPlea("x", 1e18);
        denyPlea(id1);
        uint64 deniedAt = uint64(block.timestamp);
        assertTrue(court.rehearingOwed(seller));
        assertEq(court.nextPleaAt(seller), deniedAt + 4 hours);
        // withdraw and resubmit at once: refused until the appeal delay has passed
        vm.prank(seller);
        court.withdrawPlea(id1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.PleaTooEarly.selector, deniedAt + 4 hours));
        court.submitPlea("x", 1e18);
        vm.warp(deniedAt + 4 hours);
        vm.prank(seller);
        uint256 id2 = court.submitPlea("x again", 1e18);
        assertTrue(court.plea(id2).appealed, "the replacement plea is the seller's re-hearing");
        denyPlea(id2);
        uint64 deniedAgainAt = uint64(block.timestamp);
        assertFalse(court.rehearingOwed(seller));
        assertEq(court.nextPleaAt(seller), deniedAgainAt + 24 hours);
        vm.warp(deniedAgainAt + 4 hours);
        vm.prank(seller);
        vm.expectRevert(PleaCourt.AlreadyAppealed.selector);
        court.appeal(id2);
        vm.prank(seller);
        court.withdrawPlea(id2);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.PleaTooEarly.selector, deniedAgainAt + 24 hours));
        court.submitPlea("x", 1e18);
        vm.warp(deniedAgainAt + 24 hours);
        vm.prank(seller);
        uint256 id3 = court.submitPlea("x", 1e18);
        assertFalse(court.plea(id3).appealed);
    }

    function test_approvedRehearingClearsTheDebt() public {
        vm.prank(seller);
        uint256 id1 = court.submitPlea("x", 1e18);
        denyPlea(id1);
        vm.warp(block.timestamp + 4 hours);
        vm.prank(seller);
        court.withdrawPlea(id1);
        vm.prank(seller);
        uint256 id2 = court.submitPlea("better", 1e18);
        approvePlea(id2);
        assertFalse(court.rehearingOwed(seller));
        assertEq(court.nextPleaAt(seller), block.timestamp - 4 hours + 4 hours);
        _sell(seller, 1e18);
        vm.prank(seller);
        uint256 id3 = court.submitPlea("next", 1);
        assertFalse(court.plea(id3).appealed, "a seller approved since is not on a re-hearing");
    }

    // ---------------------------------------------------------------- bans everywhere

    function test_upheldObjectionStrikesTheOpenWindowAndBlocksSales() public {
        uint256 pleaId = submitAndApprove(seller, 2e18);
        uint256 saleId = _sell(seller, 1e18);
        uint256 oid = _object(stranger, saleId);
        _uphold16(oid);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.SaleWindowClosed(pleaId, seller, 1e18, false);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.PleaStruck(pleaId, seller);
        vm.prank(judges[16]);
        court.ruleObjection(oid, true);
        assertEq(uint8(court.pleaStatus(pleaId)), uint8(IPleaCourt.Status.Struck));
        assertEq(court.activePlea(seller), 0);
        (uint64 expiry, uint256 remaining) = hook.saleWindowExpiry(seller);
        assertEq(expiry, 0);
        assertEq(remaining, 0);
        uint64 until = court.bannedUntil(seller);
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.Banned.selector, until));
        hook.sell(1e18, 0);
        vm.stopPrank();
    }

    function test_upheldObjectionStrikesAPendingPleaAndBlocksAppeals() public {
        // sale from plea A, then plea B pending while A's sale is objected to
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(seller, 1e18);
        vm.prank(seller);
        uint256 b = court.submitPlea("B", 1e18);
        vm.prank(judges[0]);
        court.judge(b, 45, 26);
        uint256 oid = _object(stranger, saleId);
        _uphold(oid);
        assertEq(uint8(court.pleaStatus(b)), uint8(IPleaCourt.Status.Struck));
        assertEq(court.pendingCount(), 0, "a struck pending plea leaves the clock");
        vm.prank(judges[1]);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.Struck));
        court.judge(b, 45, 26);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.Struck));
        court.appeal(b);
        // after the ban the seller starts over
        vm.warp(court.bannedUntil(seller));
        vm.prank(seller);
        uint256 c = court.submitPlea("C", 1e18);
        assertEq(uint8(court.pleaStatus(c)), uint8(IPleaCourt.Status.Pending));
    }

    function test_upheldObjectionStrikesADeniedPleaSoNoAppealRunsDuringTheBan() public {
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(seller, 1e18);
        vm.prank(seller);
        uint256 b = court.submitPlea("B", 1e18);
        denyPlea(b);
        uint256 oid = _object(stranger, saleId);
        _uphold(oid);
        assertEq(uint8(court.pleaStatus(b)), uint8(IPleaCourt.Status.Struck));
        vm.warp(block.timestamp + 4 hours);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.Struck));
        court.appeal(b);
        uint64 until = court.bannedUntil(seller);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.Banned.selector, until));
        court.submitPlea("C", 1e18);
    }

    // ---------------------------------------------------------------- strikes and seasons

    function test_strikeAfterSeasonEndForfeitsThePrize() public {
        imd.transfer(address(court), 100e18);
        vm.warp(court.seasonStart() + court.SEASON_LENGTH());
        uint256 pleaId = submitAndApprove(seller, 1e21);
        assertEq(court.plea(pleaId).season, 1);
        vm.prank(seller);
        court.endSeason();
        assertEq(court.prizeCredit(1, seller), 100e18);
        assertEq(court.prizePot(), 0);
        uint256 saleId = _sell(seller, 1e21);
        assertEq(court.sale(saleId).season, 1, "the sale carries the season of its points");
        uint256 oid = _object(stranger, saleId);
        _uphold16(oid);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.PrizeForfeited(1, seller, 100e18);
        vm.prank(judges[16]);
        court.ruleObjection(oid, true);
        assertEq(court.prizeCredit(1, seller), 0);
        assertEq(court.claimable(seller), 0);
        assertEq(court.prizePot(), 100e18, "the forfeited prize is back in the pot");
        assertEq(court.seasonPoints(2, seller), 0);
        vm.warp(court.prizeUnlockAt(1));
        vm.prank(seller);
        vm.expectRevert(PleaCourt.NothingToClaim.selector);
        court.claimPrize(1);
    }

    function test_strikeInTheCurrentSeasonLeavesEarlierPrizesAlone() public {
        imd.transfer(address(court), 10e18);
        submitAndApprove(seller, 1e18);
        _sell(seller, 1e18);
        vm.warp(block.timestamp + 30 days);
        court.endSeason();
        assertEq(court.prizeCredit(1, seller), 10e18);
        // season 2: a struck sale voids season-2 points only
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(seller, 1e18);
        uint256 oid = _object(stranger, saleId);
        _uphold(oid);
        assertEq(court.seasonPoints(2, seller), 0);
        assertEq(court.prizeCredit(1, seller), 10e18);
    }

    function test_strikePromotesTheBench() public {
        address[] memory players = new address[](26);
        for (uint256 i = 0; i < 26; i++) {
            players[i] = makeAddr(string.concat("player", vm.toString(i)));
            vm.prank(players[i]);
            uint256 id = court.submitPlea("p", 1);
            score(id, 17, uint8(20 + i), 71); // 20..45 points
        }
        assertEq(court.leaderboard().length, 25);
        assertEq(court.fullBoard().length, 26);
        assertEq(court.leaderboard()[24].points, 21, "the 20-point seller is on the bench");
        // the 45-point seller's first window lapses; they plead again (90 points), sell, and are struck
        address top = players[25];
        vm.warp(block.timestamp + 8 minutes);
        court.closeWindow(court.activePlea(top));
        factory.send(IERC20(address(token)), top, 1e18);
        vm.prank(top);
        uint256 tid = court.submitPlea("sell", 1e18);
        approvePlea(tid);
        uint256 saleId = _sell(top, 1e18);
        uint256 oid = _object(stranger, saleId);
        _uphold(oid);
        IPleaCourt.Entry[] memory board = court.leaderboard();
        assertEq(board.length, 25);
        assertEq(board[0].points, 44);
        assertEq(board[24].points, 20, "the bench seller moved up");
        assertEq(board[24].account, players[0]);
        imd.transfer(address(court), 100e18);
        vm.warp(block.timestamp + 30 days);
        court.endSeason();
        assertGt(court.prizeCredit(1, players[0]), 0, "the promoted seller is paid");
        assertEq(court.prizeCredit(1, top), 0);
    }

    function test_boardCapacityIsFifty() public {
        for (uint256 i = 0; i < 52; i++) {
            address who = makeAddr(string.concat("p", vm.toString(i)));
            vm.prank(who);
            uint256 id = court.submitPlea("p", 1);
            score(id, 17, uint8(i % 46), 71);
        }
        assertEq(court.fullBoard().length, 50);
        assertEq(court.leaderboard().length, 25);
    }

    // ---------------------------------------------------------------- recusal and objection precedence

    function test_judgeCannotScoreOwnPlea() public {
        vm.prank(judges[0]);
        uint256 id = court.submitPlea("mine", 1e18);
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.Recused.selector);
        court.judge(id, 45, 71);
        vm.prank(judges[1]);
        court.judge(id, 45, 71);
    }

    function test_sellerAndObjectorCannotRuleOnTheObjection() public {
        address judgeSeller = judges[0];
        factory.send(IERC20(address(token)), judgeSeller, 1e18);
        vm.prank(judgeSeller);
        uint256 id = court.submitPlea("x", 1e18);
        for (uint256 i = 1; i < 18; i++) {
            vm.prank(judges[i]);
            court.judge(id, 45, 26);
        }
        uint256 saleId = _sell(judgeSeller, 1e18);
        imd.transfer(judges[1], 1e18);
        uint256 oid = _object(judges[1], saleId);
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.Recused.selector);
        court.ruleObjection(oid, false);
        vm.prank(judges[1]);
        vm.expectRevert(PleaCourt.Recused.selector);
        court.ruleObjection(oid, true);
        vm.prank(judges[2]);
        court.ruleObjection(oid, true);
    }

    function test_sellerCannotObjectToOwnSale() public {
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(seller, 1e18);
        imd.transfer(seller, 1e18);
        vm.startPrank(seller);
        imd.approve(address(court), 1e18);
        vm.expectRevert(PleaCourt.SelfObjection.selector);
        court.object(saleId);
        vm.stopPrank();
        _object(stranger, saleId);
    }

    function test_noRulingAfterTheRulingPeriod() public {
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(seller, 1e18);
        uint256 oid = _object(stranger, saleId);
        for (uint256 i = 0; i < 16; i++) {
            vm.prank(judges[i]);
            court.ruleObjection(oid, true);
        }
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(judges[16]);
        vm.expectRevert(PleaCourt.RulingPeriodOver.selector);
        court.ruleObjection(oid, true);
        vm.prank(stranger);
        court.reclaimObjectionBond(oid);
        assertEq(court.bannedUntil(seller), 0);
    }

    // ---------------------------------------------------------------- after the dead-man switch

    function test_freeSellsPayNoFeeAndThePotGoesToTheOwner() public {
        vm.prank(owner);
        hook.setPotFeeBps(1000);
        submitAndApprove(seller, 1e18);
        _sell(seller, 1e18);
        uint256 potBefore = court.prizePot();
        assertGt(potBefore, 0);
        vm.prank(stranger);
        court.submitPlea("x", 1e18);
        vm.warp(block.timestamp + 33 hours);
        court.triggerDeadManSwitch();
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        vm.expectEmit(true, true, false, false);
        emit PleaHook.SellExecuted(0, seller, 1e18, 0, 0, true);
        (, uint256 out) = hook.sell(1e18, 0);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(court.prizePot(), potBefore, "a free sale pays no pot fee");
        // the board (the seller's 45 points) takes the pot at the season end; the rest is swept
        imd.transfer(address(court), 1e18);
        vm.warp(block.timestamp + 30 days);
        court.endSeason();
        assertEq(court.prizeCredit(1, seller), potBefore + 1e18);
        assertEq(court.claimable(owner), 0);
        // later seasons have no board: everything that arrives goes to the owner
        imd.transfer(address(court), 2e18);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.PotSwept(2, owner, 2e18);
        court.endSeason();
        assertEq(court.claimable(owner), 2e18);
        assertEq(court.prizePot(), 0);
        vm.prank(owner);
        court.claim();
        assertEq(imd.balanceOf(owner), 2e18);
    }

    function test_potRollsOverWhileTheGateStands() public {
        imd.transfer(address(court), 1e18);
        vm.warp(block.timestamp + 30 days);
        court.endSeason();
        assertEq(court.claimable(owner), 0);
        assertEq(court.prizePot(), 1e18);
    }

    // ---------------------------------------------------------------- partial fills

    function test_partialFillChargesOnlyWhatThePoolTook() public {
        // leave only a thin band of liquidity around the price
        factory.modify(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), -1e21);
        factory.modify(key, -60, 60, 1e18);
        uint256 pleaId = submitAndApprove(seller, 1e18);
        uint256 before = token.balanceOf(seller);
        vm.startPrank(seller);
        token.approve(address(hook), 1e18);
        (uint256 saleId, uint256 out) = hook.sell(1e18, 1);
        vm.stopPrank();
        uint256 consumed = before - token.balanceOf(seller);
        assertGt(out, 0);
        assertLt(consumed, 1e18, "the thin pool took only part of the input");
        IPleaCourt.Plea memory p = court.plea(pleaId);
        assertEq(p.sold, consumed);
        assertEq(uint8(p.status), uint8(IPleaCourt.Status.Approved), "the window stays open for the rest");
        assertEq(court.sale(saleId).amount, consumed);
        (, uint256 remaining) = hook.saleWindowExpiry(seller);
        assertEq(remaining, 1e18 - consumed);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_settleSaleOnlyFromTheHook() public {
        vm.expectRevert(PleaCourt.NotHook.selector);
        court.settleSale(1, 0);
    }
}
