// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PleaCourt} from "src/PleaCourt.sol";
import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {CourtFixture} from "test/helpers/CourtFixture.sol";

/// @dev Adversarial checks of the revised court: the two findings reported last round (bench promotion,
/// partial-fill accounting) as regressions, and attempts to get around the new re-hearing, cooldown,
/// ruling-period and prize-lock rules.
contract PleaCourtRevisionTest is CourtFixture {
    // ------------------------------------------------------------ regression: struck winner's seat

    function test_strikingAWinnerPromotesTheTwentySixthSellerIntoThePrize() public {
        address[] memory sellers = new address[](26);
        uint256[] memory sales = new uint256[](26);
        for (uint256 i; i < 26; ++i) {
            sellers[i] = makeAddr(string.concat("ranked seller", vm.toString(i)));
            approved(sellers[i], 1, uint8(45 - i)); // Distinct medians 45 down to 20.
            sales[i] = driver.authorize(sellers[i], 1);
        }
        address last = sellers[25];
        IPleaCourt.Entry[] memory board = court.leaderboard();
        assertEq(board.length, 25);
        for (uint256 i; i < board.length; ++i) {
            assertTrue(board[i].account != last, "26th seller listed before any strike");
        }
        assertEq(court.fullBoard().length, 26);

        rule(objectTo(bob, sales[0]), true); // Strike the leader.
        board = court.leaderboard();
        assertEq(board.length, 25);
        assertEq(board[0].account, sellers[1]);
        assertEq(board[24].account, last, "bench seller not promoted");

        imd.transfer(address(court), 1000 ether);
        vm.warp(court.seasonStart() + 30 days);
        court.endSeason();
        assertEq(court.prizeCredit(1, sellers[0]), 0);
        assertGt(court.prizeCredit(1, last), 0);
    }

    // ------------------------------------------------------------ regression: partial fills

    function test_partialFillReturnsTheUnconsumedReservationToTheWindow() public {
        uint256 id = approved(alice, 10, 45);
        uint256 first = driver.authorizePartial(alice, 10, 3);
        assertEq(court.sale(first).amount, 3);
        assertEq(court.plea(id).sold, 3);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Approved));
        (, uint256 remaining) = court.saleWindow(alice);
        assertEq(remaining, 7);
        vm.expectEmit(true, true, true, true, address(court));
        emit PleaCourt.SaleWindowClosed(id, alice, 10, false);
        driver.authorize(alice, 7);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Closed));
        assertEq(court.activePlea(alice), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_settleNeverChargesMoreThanConsumed(uint128 amountSeed, uint128 reserveSeed, uint128 usedSeed)
        public
    {
        uint256 amount = bound(amountSeed, 1, type(uint128).max);
        uint256 reserve = bound(reserveSeed, 1, amount);
        uint256 used = bound(usedSeed, 0, reserve);
        uint256 id = approved(alice, amount, 45);
        uint256 saleId = driver.authorizePartial(alice, reserve, used);
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(p.sold, used);
        assertEq(court.sale(saleId).amount, used);
        assertEq(p.status == IPleaCourt.Status.Closed, used == amount);
        if (used < amount) {
            (, uint256 remaining) = court.saleWindow(alice);
            assertEq(remaining, amount - used);
        }
    }

    function test_settleRejectsUnknownSalesAndOverconsumptionAtomically() public {
        uint256 id = approved(alice, 5, 45);
        vm.expectRevert(PleaCourt.NoSuchSale.selector);
        driver.settle(1, 0);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.ExceedsApprovedAmount.selector, 5));
        driver.authorizePartial(alice, 5, 6);
        assertEq(court.saleCount(), 0);
        assertEq(court.plea(id).sold, 0);
        vm.prank(alice);
        vm.expectRevert(PleaCourt.NotHook.selector);
        court.settleSale(1, 0);
        vm.prank(alice);
        vm.expectRevert(PleaCourt.NotHook.selector);
        court.authorizeSale(alice, 1);
    }

    // ------------------------------------------------------------ re-hearing cannot be laundered

    function test_withdrawAndResubmitCannotEscapeTheOneRehearingRule() public {
        uint256 first = submit(alice, 1);
        vote(first, 0, 17, 0, 0);
        uint64 earliest = court.plea(first).decidedAt + 4 hours;
        assertEq(court.nextPleaAt(alice), earliest);
        assertTrue(court.rehearingOwed(alice));
        vm.prank(alice);
        court.withdrawPlea(first);

        // Neither route opens a fresh plea before 4 hours.
        vm.warp(earliest - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.PleaTooEarly.selector, earliest));
        court.submitPlea("again", 1);
        vm.prank(alice);
        (bool ok, bytes memory err) = address(box).call(abi.encodeWithSignature("post(string,uint256)", "again", 1));
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(PleaCourt.PleaTooEarly.selector, earliest));

        // The replacement is the re-hearing; withdrawing it unvoted does not reset the debt.
        vm.warp(earliest);
        uint256 second = submit(alice, 1);
        assertTrue(court.plea(second).appealed);
        vm.prank(alice);
        court.withdrawPlea(second);
        uint256 third = submit(alice, 1);
        assertTrue(court.plea(third).appealed);

        vote(third, 0, 17, 0, 0);
        uint64 cooldown = court.plea(third).decidedAt + 24 hours;
        assertEq(court.nextPleaAt(alice), cooldown);
        assertFalse(court.rehearingOwed(alice));
        vm.warp(court.plea(third).decidedAt + 4 hours);
        vm.prank(alice);
        vm.expectRevert(PleaCourt.AlreadyAppealed.selector);
        court.appeal(third);
        vm.prank(alice);
        court.withdrawPlea(third);
        vm.warp(cooldown - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.PleaTooEarly.selector, cooldown));
        court.submitPlea("later", 1);
        vm.warp(cooldown);
        uint256 fresh = submit(alice, 1);
        assertFalse(court.plea(fresh).appealed, "a plea after the cooldown is a fresh plea");
    }

    function test_partiallyScoredPleaCannotBeWithdrawnToDodgeADenial() public {
        uint256 id = submit(alice, 1);
        vote(id, 0, 16, 0, 0);
        vm.prank(alice);
        vm.expectRevert(PleaCourt.VotesCast.selector);
        court.withdrawPlea(id);
        vm.prank(bob);
        vm.expectRevert(PleaCourt.NotSeller.selector);
        court.withdrawPlea(id);
        vote(id, 16, 1, 0, 0);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Denied));
        assertTrue(court.rehearingOwed(alice));
    }

    // ------------------------------------------------------------ bans

    function test_struckSellerCannotSpendTheRestOfTheWindowNorPleadDuringTheBan() public {
        uint256 id = approved(alice, 10, 45);
        uint256 saleId = driver.authorize(alice, 4);
        rule(objectTo(bob, saleId), true);
        uint64 until = court.bannedUntil(alice);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Struck));
        (uint64 expiry, uint256 remaining) = court.saleWindow(alice);
        assertEq(expiry, 0);
        assertEq(remaining, 0);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.Banned.selector, until));
        driver.authorize(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WrongStatus.selector, IPleaCourt.Status.Struck));
        court.closeWindow(id);
        vm.warp(until - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.Banned.selector, until));
        court.submitPlea("sorry", 1);
        vm.warp(until);
        vm.expectRevert(PleaCourt.NoApprovedPlea.selector);
        driver.authorize(alice, 1);
        submit(alice, 1);
    }

    // ------------------------------------------------------------ ruling period and prize lock

    function test_rulingAtTheLastSecondStillBansAndPrecedesThePrizeUnlock() public {
        // Approved in the season's last second; the season ends; the sale comes at the window's end.
        vm.warp(court.seasonStart() + 30 days - 1);
        uint256 id = approved(alice, 1, 45);
        approved(bob, 1, 30);
        assertEq(court.plea(id).season, 1);
        imd.transfer(address(court), 100 ether);
        vm.warp(block.timestamp + 1);
        court.endSeason();
        uint256 prize = court.prizeCredit(1, alice);
        assertGt(prize, 0);
        vm.warp(court.plea(id).windowExpiry);
        uint256 saleId = driver.authorize(alice, 1);
        assertEq(court.sale(saleId).season, 1);
        vm.warp(block.timestamp + 20 minutes);
        uint256 oid = objectTo(outsider, saleId);
        for (uint256 i; i < 16; ++i) {
            vm.prank(panel[i]);
            court.ruleObjection(oid, true);
        }
        vm.warp(court.objection(oid).openedAt + 48 hours); // Inclusive end of the ruling period.
        assertLt(block.timestamp, court.prizeUnlockAt(1), "ruling period must end before prizes unlock");
        uint256 potBefore = court.prizePot();
        vm.prank(panel[16]);
        court.ruleObjection(oid, true);
        assertEq(court.prizeCredit(1, alice), 0);
        assertEq(court.prizePot(), potBefore + prize, "forfeited prize must return to the pot");
        assertGt(court.prizeCredit(1, bob), 0, "an innocent winner keeps their prize");
        vm.warp(court.prizeUnlockAt(1));
        vm.prank(alice);
        vm.expectRevert(PleaCourt.NothingToClaim.selector);
        court.claimPrize(1);
    }

    function test_unendedSeasonPrizeCannotBeClaimed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.PrizeLocked.selector, 0));
        court.claimPrize(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.PrizeLocked.selector, 0));
        court.claimPrize(type(uint256).max);
    }

    // ------------------------------------------------------------ regression: endSeason latches the switch

    /// @dev Last round's low finding. The switch falls due at the exact second the season ends and nobody
    /// latches it: `endSeason` must sweep the pot to the owner, not roll it into a season nobody can win.
    function test_switchDueAtTheSeasonEndIsLatchedAndSweptByEndSeason() public {
        uint256 seasonEnd = court.seasonStart() + 30 days;
        vm.warp(seasonEnd - 33 hours);
        submit(alice, 1); // Nobody votes.
        assertEq(court.deadManDeadline(), seasonEnd);
        imd.transfer(address(court), 7 ether);
        vm.warp(seasonEnd);
        assertFalse(court.deadManTriggered());
        vm.expectEmit(true, true, true, true, address(court));
        emit PleaCourt.PotSwept(1, owner, 7 ether);
        court.endSeason();
        assertTrue(court.deadManTriggered());
        assertEq(court.claimable(owner), 7 ether);
        assertEq(court.prizePot(), 0);
    }

    /// @dev One second earlier the switch is not due: the pot rolls over, and the latch cannot be applied
    /// retroactively to the season already ended. The next season's end sweeps it.
    function test_switchDueOneSecondAfterTheSeasonEndRollsThePotOnce() public {
        uint256 seasonEnd = court.seasonStart() + 30 days;
        vm.warp(seasonEnd - 33 hours + 1);
        submit(alice, 1);
        imd.transfer(address(court), 7 ether);
        vm.warp(seasonEnd);
        court.endSeason();
        assertFalse(court.deadManTriggered());
        assertEq(court.prizePot(), 7 ether);
        assertEq(court.claimable(owner), 0);

        vm.warp(seasonEnd + 1);
        assertTrue(court.tradesFreely());
        vm.warp(court.seasonStart() + 30 days);
        court.endSeason();
        assertTrue(court.deadManTriggered());
        assertEq(court.claimable(owner), 7 ether);
        assertEq(court.prizePot(), 0);
    }

    /// @dev Before a due switch the board is still paid: only what it does not take is swept.
    function test_endSeasonLatchPaysTheBoardBeforeSweepingTheRest() public {
        approved(bob, 1, 45);
        driver.authorize(bob, 1);
        uint256 seasonEnd = court.seasonStart() + 30 days;
        vm.warp(seasonEnd - 33 hours);
        submit(alice, 1);
        imd.transfer(address(court), 9 ether);
        vm.warp(seasonEnd);
        court.endSeason();
        assertTrue(court.deadManTriggered());
        uint256 prize = court.prizeCredit(1, bob);
        assertGt(prize, 0, "board must still be paid");
        assertEq(court.claimable(owner) + prize, 9 ether, "pot is either prize or sweep");
        assertEq(court.prizePot(), 0);
    }

    // ------------------------------------------------------------ regression: a judge's own plea

    /// @dev Any split of a judge's own plea that gives neither side 17 is settled as a denial by the 29th
    /// eligible vote and never earlier, whatever order the votes arrive in.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_judgeSellerSplitIsDeniedAtExactlyTheTwentyNinthVote(uint256 approveSeed, uint256 orderSeed)
        public
    {
        uint256 approvals = bound(approveSeed, 13, 16); // Denials 29 - approvals, also 13..16.
        address judgeSeller = panel[0];
        uint256 id = submit(judgeSeller, 1);
        assertEq(court.eligibleJudges(id), 29);

        uint256 a;
        uint256 d;
        for (uint256 i = 1; i < 30; ++i) {
            bool yes = a < approvals && (d == 29 - approvals || (orderSeed >> i) & 1 == 1);
            vm.prank(panel[i]);
            court.judge(id, yes ? 45 : 44, 26);
            if (yes) ++a;
            else ++d;
            if (i < 29) assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Pending));
        }
        assertEq(a, approvals);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Denied), "29 eligible votes must settle");
        assertEq(court.pendingCount(), 0);
        assertEq(court.plea(id).approveVotes, approvals);
        vm.warp(block.timestamp + 33 hours);
        assertFalse(court.tradesFreely());
    }

    /// @dev Eligibility is read at each vote: once the owner rotates the judge-seller off the panel, the plea
    /// waits for the replacement's vote instead of settling at 29.
    function test_rotatingTheJudgeSellerOffThePanelRestoresThirtyEligibleVotes() public {
        address judgeSeller = panel[0];
        uint256 id = submit(judgeSeller, 1);
        vote(id, 1, 14, 45, 26);
        vote(id, 15, 14, 44, 26); // 28 votes, 14/14.
        address newcomer = makeAddr("replacement judge");
        address[] memory next = panel;
        next[0] = newcomer;
        vm.prank(owner);
        court.setJudges(next);
        assertEq(court.eligibleJudges(id), 30);
        vm.prank(panel[29]);
        court.judge(id, 44, 26); // 29th vote: no longer the last eligible one.
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Pending));
        vm.prank(newcomer);
        court.judge(id, 45, 26);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Denied));
        assertEq(court.plea(id).approveVotes, 15);
    }
}
