// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PleaCourt} from "../src/PleaCourt.sol";
import {IPleaCourt} from "../src/interfaces/IPleaCourt.sol";
import {PleaBase} from "./PleaBase.t.sol";

contract PleaCourtTest is PleaBase {
    // ---------------------------------------------------------------- configuration

    function test_setJudgesOnlyOwnerAndExactly30() public {
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NotOwner.selector);
        court.setJudges(judges);
        address[] memory few = new address[](29);
        vm.prank(owner);
        vm.expectRevert(PleaCourt.BadJudges.selector);
        court.setJudges(few);
        address[] memory dup = judges;
        dup[1] = dup[0];
        vm.prank(owner);
        vm.expectRevert(PleaCourt.BadJudges.selector);
        court.setJudges(dup);
        assertTrue(court.cabalConfigured());
        assertEq(court.judges().length, 30);
        // replacing the panel drops the old judges
        address[] memory fresh = new address[](30);
        for (uint256 i = 0; i < 30; i++) {
            fresh[i] = makeAddr(string.concat("fresh", vm.toString(i)));
        }
        vm.prank(owner);
        court.setJudges(fresh);
        assertFalse(court.isJudge(judges[0]));
        assertTrue(court.isJudge(fresh[0]));
    }

    function test_unconfiguredCabalCannotJudge() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("x", 1);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NotJudge.selector);
        court.judge(id, 1, 1);
    }

    function test_setSeat() public {
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NotOwner.selector);
        court.setSeat(seller, true);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.SeatSet(seller, true);
        court.setSeat(seller, true);
        assertTrue(court.hasSeat(seller));
        assertEq(court.effectiveScore(seller, 45), 54);
        assertEq(court.effectiveScore(stranger, 45), 45);
    }

    // ---------------------------------------------------------------- submission

    function test_submitEmitsAndStores() public {
        vm.prank(seller);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.PleaSubmitted(1, seller, 5e18, "let me out", false);
        uint256 id = court.submitPlea("let me out", 5e18);
        assertEq(id, 1);
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(p.seller, seller);
        assertEq(p.amount, 5e18);
        assertEq(uint8(p.status), uint8(IPleaCourt.Status.Pending));
        assertEq(p.round, 1);
        assertEq(court.pleaText(id), "let me out");
        assertEq(court.activePlea(seller), id);
        assertEq(court.pendingCount(), 1);
    }

    function test_submitInvalidInputsRevert() public {
        vm.startPrank(seller);
        vm.expectRevert(PleaCourt.ZeroAmount.selector);
        court.submitPlea("x", 0);
        vm.expectRevert(PleaCourt.EmptyPlea.selector);
        court.submitPlea("", 1);
        bytes memory long = new bytes(1001);
        vm.expectRevert(PleaCourt.PleaTooLong.selector);
        court.submitPlea(string(long), 1);
        uint256 id = court.submitPlea("x", 1);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.ActivePleaExists.selector, id));
        court.submitPlea("y", 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- judging

    function test_approvalAt17Votes() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("facts", 1e18);
        score(id, 16, 45, 26);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Pending));
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.Verdict(id, seller, 1, true, 45, 17, 0);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.SaleWindowOpened(id, seller, 1e18, uint64(block.timestamp + 7 minutes));
        vm.prank(judges[16]);
        court.judge(id, 45, 26);
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(uint8(p.status), uint8(IPleaCourt.Status.Approved));
        assertEq(p.medianScore, 45);
        assertEq(court.pendingCount(), 0);
        assertEq(court.lastVerdictAt(), block.timestamp);
        assertEq(court.seasonPoints(1, seller), 45);
        // late judges cannot vote on a decided plea
        vm.prank(judges[17]);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.Approved));
        court.judge(id, 45, 26);
    }

    function test_denialAt17Votes() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("no facts", 1e18);
        // 13 approve, then 17 deny: the deny side reaches the majority first
        score(id, 13, 45, 26);
        for (uint256 i = 13; i < 30; i++) {
            vm.prank(judges[i]);
            court.judge(id, 44, 26);
        }
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(uint8(p.status), uint8(IPleaCourt.Status.Denied));
        assertEq(p.approveVotes, 13);
        assertEq(p.denyVotes, 17);
        assertEq(p.medianScore, 44);
        assertEq(court.seasonPoints(1, seller), 0);
    }

    function test_judgeInputChecks() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("x", 1);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NotJudge.selector);
        court.judge(id, 1, 1);
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.ScoreTooHigh.selector);
        court.judge(id, 46, 0);
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.FactPointsTooHigh.selector);
        court.judge(id, 0, 72);
        vm.prank(judges[0]);
        court.judge(id, 45, 0);
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.AlreadyVoted.selector);
        court.judge(id, 45, 0);
        vm.prank(judges[0]);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.None));
        court.judge(99, 45, 0);
    }

    function test_seatMultiplierLowersTheBar() public {
        vm.prank(owner);
        court.setSeat(seller, true);
        vm.prank(seller);
        uint256 id = court.submitPlea("seat", 1);
        vm.prank(stranger);
        uint256 id2 = court.submitPlea("no seat", 1);
        // 45 * 1.2 = 54; 54 + 17 = 71 approves; 45 + 17 = 62 does not
        score(id, 17, 45, 17);
        score(id2, 17, 45, 17);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Approved));
        assertEq(court.plea(id).medianScore, 54);
        assertEq(uint8(court.pleaStatus(id2)), uint8(IPleaCourt.Status.Denied));
    }

    function testFuzz_voteSideFollowsTheBar(uint8 s, uint8 facts, bool seat) public {
        s = uint8(bound(s, 0, 45));
        facts = uint8(bound(facts, 0, 71));
        if (seat) {
            vm.prank(owner);
            court.setSeat(seller, true);
        }
        vm.prank(seller);
        uint256 id = court.submitPlea("fuzz", 1);
        vm.prank(judges[0]);
        court.judge(id, s, facts);
        uint256 effective = seat ? uint256(s) * 12 / 10 : s;
        bool approve = effective + facts >= 71;
        assertEq(court.plea(id).approveVotes, approve ? 1 : 0);
        assertEq(court.plea(id).denyVotes, approve ? 0 : 1);
        assertEq(court.requiredScore(facts), facts >= 71 ? 0 : 71 - facts);
    }

    function test_medianOfMixedScores() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("mix", 1);
        for (uint256 i = 0; i < 17; i++) {
            vm.prank(judges[i]);
            court.judge(id, uint8(29 + i), 71); // 29..45, all approve with 71 fact points
        }
        assertEq(court.plea(id).medianScore, 37);
    }

    // ---------------------------------------------------------------- appeals and withdrawal

    function test_appealFlow() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("try", 1e18);
        denyPlea(id);
        uint64 deniedAt = uint64(block.timestamp);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NotSeller.selector);
        court.appeal(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.AppealTooEarly.selector, deniedAt + 4 hours));
        court.appeal(id);
        vm.warp(deniedAt + 4 hours);
        vm.prank(seller);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.PleaAppealed(id, seller, 2);
        court.appeal(id);
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(uint8(p.status), uint8(IPleaCourt.Status.Pending));
        assertEq(p.round, 2);
        assertEq(p.denyVotes, 0);
        assertEq(court.pendingCount(), 1);
        // the same judges vote again in round 2
        approvePlea(id);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Approved));
        assertEq(court.scores(id, 1).length, 17);
        assertEq(court.scores(id, 2).length, 17);
    }

    function test_onlyOneAppeal() public {
        vm.prank(seller);
        uint256 id = court.submitPlea("try", 1e18);
        denyPlea(id);
        vm.warp(block.timestamp + 4 hours);
        vm.prank(seller);
        court.appeal(id);
        denyPlea(id);
        vm.warp(block.timestamp + 4 hours);
        vm.prank(seller);
        vm.expectRevert(PleaCourt.AlreadyAppealed.selector);
        court.appeal(id);
        // a denied plea blocks a new one until withdrawn
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.ActivePleaExists.selector, id));
        court.submitPlea("new", 1);
        vm.prank(seller);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.PleaWithdrawn(id, seller);
        court.withdrawPlea(id);
        vm.prank(seller);
        court.submitPlea("new", 1);
    }

    function test_appealOfApprovedReverts() public {
        uint256 id = submitAndApprove(seller, 1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.Approved));
        court.appeal(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.Approved));
        court.withdrawPlea(id);
    }

    function test_closeWindowAfterExpiry() public {
        uint256 id = submitAndApprove(seller, 1);
        vm.expectRevert(PleaCourt.WindowStillOpen.selector);
        court.closeWindow(id);
        vm.warp(block.timestamp + 7 minutes + 1);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.SaleWindowClosed(id, seller, 0, true);
        court.closeWindow(id);
        assertEq(court.activePlea(seller), 0);
    }

    // ---------------------------------------------------------------- objections

    function _sell(uint256 amount) internal returns (uint256 saleId) {
        vm.startPrank(seller);
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

    function test_objectionWindow() public {
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(1e18);
        vm.expectRevert(PleaCourt.NoSuchSale.selector);
        court.object(99);
        uint64 executedAt = court.sale(saleId).executedAt;
        vm.warp(executedAt + 20 minutes + 1);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.ObjectionWindowClosed.selector);
        court.object(saleId);
    }

    function test_objectionUpheld() public {
        uint256 pleaId = submitAndApprove(seller, 1e18);
        assertEq(court.leaderboard().length, 1);
        uint256 saleId = _sell(1e18);
        uint256 bond = court.OBJECTION_BOND();
        uint256 before = imd.balanceOf(stranger);
        vm.startPrank(stranger);
        imd.approve(address(court), bond);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.ObjectionRaised(1, saleId, stranger, seller);
        uint256 oid = court.object(saleId);
        vm.stopPrank();
        assertEq(before - imd.balanceOf(stranger), bond);
        assertEq(court.bondsHeld(), bond);
        assertEq(court.prizePot(), 0, "bond is not pot");
        vm.prank(buyer);
        vm.expectRevert(PleaCourt.AlreadyObjected.selector);
        court.object(saleId);

        for (uint256 i = 0; i < 16; i++) {
            vm.prank(judges[i]);
            court.ruleObjection(oid, true);
        }
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.AlreadyVoted.selector);
        court.ruleObjection(oid, true);
        vm.prank(judges[16]);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.ObjectionResolved(oid, saleId, true, false);
        court.ruleObjection(oid, true);

        assertEq(court.bannedUntil(seller), block.timestamp + 7 days);
        assertEq(court.seasonPoints(1, seller), 0);
        assertEq(court.leaderboard().length, 0);
        assertEq(court.claimable(stranger), bond);
        assertEq(court.bondsHeld(), 0);
        vm.prank(stranger);
        court.claim();
        assertEq(imd.balanceOf(stranger), before);
        // banned sellers cannot plead
        vm.warp(block.timestamp + 1);
        uint64 until = court.bannedUntil(seller);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.Banned.selector, until));
        court.submitPlea("again", 1);
        vm.warp(until + 1);
        vm.prank(seller);
        court.submitPlea("again", 1);
        assertEq(uint8(court.pleaStatus(pleaId)), uint8(IPleaCourt.Status.Closed));
        vm.prank(judges[17]);
        vm.expectRevert(PleaCourt.ObjectionResolvedAlready.selector);
        court.ruleObjection(oid, true);
    }

    function test_objectionDismissedForfeitsBond() public {
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(1e18);
        uint256 oid = _object(stranger, saleId);
        for (uint256 i = 0; i < 17; i++) {
            vm.prank(judges[i]);
            court.ruleObjection(oid, false);
        }
        assertEq(court.prizePot(), court.OBJECTION_BOND());
        assertEq(court.claimable(stranger), 0);
        assertEq(court.bannedUntil(seller), 0);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.ObjectionResolvedAlready.selector);
        court.reclaimObjectionBond(oid);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NothingToClaim.selector);
        court.claim();
    }

    function test_objectionUnruledBondReclaim() public {
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(1e18);
        uint256 oid = _object(stranger, saleId);
        vm.prank(seller);
        vm.expectRevert(PleaCourt.NotObjector.selector);
        court.reclaimObjectionBond(oid);
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.RulingPeriodOpen.selector);
        court.reclaimObjectionBond(oid);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(stranger);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.ObjectionResolved(oid, saleId, false, true);
        court.reclaimObjectionBond(oid);
        assertEq(court.claimable(stranger), court.OBJECTION_BOND());
        vm.prank(judges[0]);
        vm.expectRevert(PleaCourt.ObjectionResolvedAlready.selector);
        court.ruleObjection(oid, true);
    }

    function test_objectionNeedsBond() public {
        submitAndApprove(seller, 1e18);
        uint256 saleId = _sell(1e18);
        address broke = makeAddr("broke");
        vm.prank(broke);
        vm.expectRevert();
        court.object(saleId);
    }

    // ---------------------------------------------------------------- seasons

    function test_seasonEndTooEarlyReverts() public {
        (uint256 id, uint64 startedAt, uint64 endsAt) = hook.currentSeason();
        assertEq(id, 1);
        assertEq(endsAt, startedAt + 30 days);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.SeasonNotOver.selector, endsAt));
        court.endSeason();
    }

    function test_seasonSplitsPotProRata() public {
        address second = makeAddr("second");
        address third = makeAddr("third");
        uint256 a = submitAndApprove(seller, 1); // 45 points
        vm.prank(second);
        uint256 b = court.submitPlea("b", 1);
        score(b, 17, 30, 41); // 30 points
        vm.prank(third);
        uint256 c = court.submitPlea("c", 1);
        denyPlea(c); // nothing
        a;
        IPleaCourt.Entry[] memory board = hook.leaderboard();
        assertEq(board.length, 2);
        assertEq(board[0].account, seller);
        assertEq(board[0].points, 45);
        assertEq(board[1].account, second);
        assertEq(board[1].points, 30);

        imd.transfer(address(court), 75e18); // sponsor the pot
        assertEq(court.prizePot(), 75e18);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.SeasonEnded(1, 75e18, 2, block.timestamp);
        court.endSeason();
        assertEq(court.claimable(seller), 45e18);
        assertEq(court.claimable(second), 30e18);
        assertEq(court.prizePot(), 0);
        (uint256 id,,) = hook.currentSeason();
        assertEq(id, 2);
        assertEq(hook.leaderboard().length, 0);
        vm.prank(seller);
        vm.expectEmit(true, true, true, true);
        emit PleaCourt.Claimed(seller, 45e18);
        court.claim();
        assertEq(imd.balanceOf(seller), 45e18);
        vm.prank(second);
        court.claim();
        assertEq(imd.balanceOf(address(court)), 0);
    }

    function test_emptySeasonRollsPotOver() public {
        imd.transfer(address(court), 1e18);
        vm.warp(block.timestamp + 30 days);
        court.endSeason();
        assertEq(court.prizePot(), 1e18);
        (uint256 id,,) = court.currentSeason();
        assertEq(id, 2);
    }

    function test_leaderboardKeepsTop25() public {
        for (uint256 i = 0; i < 26; i++) {
            address who = makeAddr(string.concat("player", vm.toString(i)));
            vm.prank(who);
            uint256 id = court.submitPlea("p", 1);
            // scores 29..45 for the first 17 slots keep every approval distinct in points
            uint8 s = uint8(20 + i);
            score(id, 17, s, 71);
        }
        IPleaCourt.Entry[] memory board = court.leaderboard();
        assertEq(board.length, 25);
        assertEq(board[0].points, 45);
        assertEq(board[24].points, 21, "the lowest entry was pushed out");
        for (uint256 i = 1; i < 25; i++) {
            assertGe(board[i - 1].points, board[i].points);
        }
    }

    function test_pointsAccumulateAcrossPleas() public {
        submitAndApprove(seller, 1);
        vm.startPrank(seller);
        token.approve(address(hook), 1);
        hook.sell(1, 0);
        vm.stopPrank();
        submitAndApprove(seller, 1);
        assertEq(court.seasonPoints(1, seller), 90);
        assertEq(court.leaderboard()[0].points, 90);
    }
}
