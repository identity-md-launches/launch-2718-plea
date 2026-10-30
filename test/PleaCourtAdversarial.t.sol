// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PleaCourt} from "src/PleaCourt.sol";
import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {CourtFixture} from "test/helpers/CourtFixture.sol";

contract PleaCourtAdversarialTest is CourtFixture {
    function test_maximumTextAndUint128AmountAcceptedButNextAmountRejectedAtomically() public {
        bytes memory text = new bytes(1000);
        for (uint256 i; i < text.length; ++i) {
            text[i] = bytes1(uint8(65 + i % 26));
        }
        vm.prank(alice);
        uint256 id = court.submitPlea(string(text), type(uint128).max);
        assertEq(bytes(court.pleaText(id)), text);
        assertEq(court.plea(id).amount, type(uint128).max);
        vm.prank(bob);
        vm.expectRevert(PleaCourt.AmountTooLarge.selector);
        court.submitPlea("overflow", uint256(type(uint128).max) + 1);
        assertEq(court.pleaCount(), 1);
        assertEq(court.pendingCount(), 1);
        assertEq(court.activePlea(bob), 0);
    }

    function test_zeroJudgeReplacementRollsBackAllMembershipChanges() public {
        address[] memory replacement = new address[](30);
        for (uint256 i; i < 30; ++i) {
            replacement[i] = makeAddr(string.concat("replacement", vm.toString(i)));
        }
        replacement[29] = address(0); // Invalid input, not a deployment address.
        vm.prank(owner);
        vm.expectRevert(PleaCourt.BadJudges.selector);
        court.setJudges(replacement);
        address[] memory afterPanel = court.judges();
        for (uint256 i; i < 30; ++i) {
            assertEq(afterPanel[i], panel[i]);
            assertTrue(court.isJudge(panel[i]));
            assertFalse(court.isJudge(replacement[i]));
        }
    }

    function test_courtAuthorityFollowsHookOwnershipImmediately() public {
        vm.prank(owner);
        driver.transferOwner(bob);
        vm.prank(owner);
        vm.expectRevert(PleaCourt.NotOwner.selector);
        court.setSeat(alice, true);
        vm.prank(bob);
        court.setSeat(alice, true);
        assertEq(court.effectiveScore(alice, 45), 54);
        vm.prank(owner);
        vm.expectRevert(PleaCourt.NotOwner.selector);
        court.setJudges(panel);
    }

    function test_rejectedVotesDoNotConsumeTheJudgeOrChangeTheTimer() public {
        uint256 id = submit(alice, 1);
        uint64 deadline = court.deadManDeadline();
        vm.startPrank(panel[0]);
        vm.expectRevert(PleaCourt.ScoreTooHigh.selector);
        court.judge(id, type(uint8).max, 71);
        vm.expectRevert(PleaCourt.FactPointsTooHigh.selector);
        court.judge(id, 45, type(uint8).max);
        vm.stopPrank();
        assertFalse(court.hasScored(id, 1, panel[0]));
        assertEq(court.scores(id, 1).length, 0);
        assertEq(court.deadManDeadline(), deadline);
        vote(id, 0, 1, 45, 26);
        vm.prank(panel[0]);
        vm.expectRevert(PleaCourt.AlreadyVoted.selector);
        court.judge(id, 0, 0);
        assertEq(court.plea(id).approveVotes, 1);
        assertEq(court.plea(id).denyVotes, 0);
        assertEq(court.scores(id, 1).length, 1);
    }

    function test_evenMedianUsesBothMiddleValuesAndFloors() public {
        uint256 id = submit(alice, 1);
        vote(id, 0, 1, 0, 0);
        for (uint256 i = 1; i < 18; ++i) {
            vote(id, i, 1, uint8(i + 1), 71);
        }
        // Sorted scores: 0, 2, 3, ... 18; middle scores 9 and 10.
        assertEq(court.plea(id).medianScore, 9);
        assertEq(court.seasonPoints(1, alice), 9);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Approved));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_seatRoundingAndFactThreshold(uint8 rawSeed, bool seat) public {
        uint8 raw = uint8(bound(rawSeed, 0, 45));
        vm.prank(owner);
        court.setSeat(alice, seat);
        uint256 effective = seat ? uint256(raw) + raw / 5 : raw;
        uint256 yes = submit(alice, 1);
        vote(yes, 0, 17, raw, uint8(71 - effective));
        assertEq(uint8(court.pleaStatus(yes)), uint8(IPleaCourt.Status.Approved));
        assertEq(court.plea(yes).medianScore, effective);
        vm.prank(owner);
        court.setSeat(bob, seat);
        uint256 no = submit(bob, 1);
        vote(no, 0, 17, raw, uint8(70 - effective));
        assertEq(uint8(court.pleaStatus(no)), uint8(IPleaCourt.Status.Denied));
        assertEq(court.seasonPoints(1, bob), 0);
    }

    function test_15To14SplitRemainsPendingUntilDeadManDeadline() public {
        uint256 id = submit(alice, 1);
        vote(id, 0, 15, 45, 26);
        vote(id, 15, 14, 45, 25);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Pending));
        assertEq(court.pendingCount(), 1);
        uint64 deadline = court.deadManDeadline();
        vm.warp(deadline - 1);
        assertFalse(court.tradesFreely());
        vm.warp(deadline);
        // The last judge is too late: the silence already freed trading, and the late vote is refused.
        vm.prank(panel[29]);
        vm.expectRevert(PleaCourt.FreeTrading.selector);
        court.judge(id, 45, 25);
        vm.expectEmit(true, true, true, true, address(court));
        emit PleaCourt.DeadManSwitchTriggered(deadline, deadline);
        court.triggerDeadManSwitch();
        assertTrue(court.tradesFreely());
        court.triggerDeadManSwitch(); // Idempotent: cannot rearm the restriction.
        vm.prank(alice);
        court.withdrawPlea(id);
        assertEq(court.pendingCount(), 0);
        assertTrue(court.deadManTriggered());
        assertTrue(court.tradesFreely());
    }

    function test_15To15SplitIsAHungDenialAppealableOnceAndStopsTheClock() public {
        uint256 id = submit(alice, 1);
        vote(id, 0, 15, 45, 26);
        vote(id, 15, 14, 45, 25);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Pending));
        vote(id, 29, 1, 45, 25); // 30th vote: neither side reached 17.
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(uint8(p.status), uint8(IPleaCourt.Status.Denied));
        assertEq(p.approveVotes, 15);
        assertEq(p.denyVotes, 15);
        assertEq(court.pendingCount(), 0);
        assertEq(court.deadManDeadline(), 0);
        assertEq(court.seasonPoints(1, alice), 0);
        (uint64 expiry,) = court.saleWindow(alice);
        assertEq(expiry, 0);
        vm.expectRevert(PleaCourt.NoApprovedPlea.selector);
        driver.authorize(alice, 1);
        // A hung denial is the first denial: one appeal after 4 hours, not a second.
        vm.warp(p.decidedAt + 4 hours);
        vm.prank(alice);
        court.appeal(id);
        vote(id, 0, 17, 0, 0);
        vm.warp(block.timestamp + 4 hours);
        vm.prank(alice);
        vm.expectRevert(PleaCourt.AlreadyAppealed.selector);
        court.appeal(id);
        assertFalse(court.tradesFreely());
    }

    function test_partialVotesAndNewPleasCannotExtendSilenceDeadline() public {
        uint256 id = submit(alice, 1);
        uint64 deadline = court.deadManDeadline();
        vm.warp(block.timestamp + 32 hours);
        vote(id, 0, 16, 45, 26);
        uint256 otherId = submit(bob, 1);
        assertEq(court.deadManDeadline(), deadline);
        vm.prank(bob);
        court.withdrawPlea(otherId);
        assertEq(court.deadManDeadline(), deadline);
        vm.warp(deadline);
        vm.prank(panel[16]);
        vm.expectRevert(PleaCourt.FreeTrading.selector);
        court.judge(id, 45, 26);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Pending));
        assertTrue(court.tradesFreely());
    }

    function test_appealBoundaryPreservesRoundOneAndResetsVotingRights() public {
        uint256 id = submit(alice, 1);
        vote(id, 0, 17, 45, 25);
        uint64 earliest = court.plea(id).decidedAt + 4 hours;
        vm.warp(earliest - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.AppealTooEarly.selector, earliest));
        court.appeal(id);
        assertFalse(court.plea(id).appealed);
        vm.warp(earliest);
        vm.prank(alice);
        court.appeal(id);
        assertEq(court.scores(id, 1).length, 17);
        assertEq(court.scores(id, 2).length, 0);
        assertTrue(court.hasScored(id, 1, panel[0]));
        assertFalse(court.hasScored(id, 2, panel[0]));
        vote(id, 0, 17, 45, 26);
        assertEq(uint8(court.pleaStatus(id)), uint8(IPleaCourt.Status.Approved));
        assertEq(court.plea(id).round, 2);
        assertEq(court.pendingCount(), 0);
    }

    function test_expiryCannotBeClosedAtLastSellableSecond() public {
        uint256 id = approved(alice, 10, 45);
        uint64 expiry = court.plea(id).windowExpiry;
        vm.warp(expiry);
        vm.expectRevert(PleaCourt.WindowStillOpen.selector);
        court.closeWindow(id);
        driver.authorize(alice, 4);
        (, uint256 remaining) = court.saleWindow(alice);
        assertEq(remaining, 6);
        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.WindowExpired.selector, expiry));
        driver.authorize(alice, 1);
        vm.expectEmit(true, true, true, true, address(court));
        emit PleaCourt.SaleWindowClosed(id, alice, 4, true);
        court.closeWindow(id);
        assertEq(court.activePlea(alice), 0);
        assertEq(court.plea(id).sold, 4);
        assertEq(court.saleCount(), 1);
    }

    function test_failedBondTransferLeavesSaleOpenToAnotherObjector() public {
        approved(alice, 10, 45);
        uint256 sale = driver.authorize(alice, 10);
        vm.prank(bob);
        vm.expectRevert(); // ERC20 allowance rejection, followed by complete rollback checks.
        court.object(sale);
        assertFalse(court.sale(sale).objected);
        assertEq(court.objectionCount(), 0);
        assertEq(court.bondsHeld(), 0);
        assertEq(imd.balanceOf(address(court)), 0);
        uint256 oid = objectTo(outsider, sale);
        assertEq(oid, 1);
        assertEq(court.objection(oid).objector, outsider);
    }

    function test_objectionInclusiveBoundaryAndOneSecondTooLate() public {
        approved(alice, 2, 45);
        uint256 first = driver.authorize(alice, 1);
        uint256 second = driver.authorize(alice, 1);
        uint64 at = court.sale(first).executedAt;
        vm.warp(at + 20 minutes);
        uint256 oid = objectTo(bob, first);
        assertEq(court.objection(oid).saleId, first);
        vm.warp(at + 20 minutes + 1);
        vm.prank(outsider);
        vm.expectRevert(PleaCourt.ObjectionWindowClosed.selector);
        court.object(second);
        assertFalse(court.sale(second).objected);
        assertEq(court.bondsHeld(), 1 ether);
    }

    function test_objectionNeedsDistinctJudgesAndCannotBeResolvedTwice() public {
        approved(alice, 1, 45);
        uint256 oid = objectTo(bob, driver.authorize(alice, 1));
        vm.prank(outsider);
        vm.expectRevert(PleaCourt.NotJudge.selector);
        court.ruleObjection(oid, true);
        for (uint256 i; i < 16; ++i) {
            vm.prank(panel[i]);
            court.ruleObjection(oid, false);
        }
        vm.prank(panel[0]);
        vm.expectRevert(PleaCourt.AlreadyVoted.selector);
        court.ruleObjection(oid, true);
        assertFalse(court.objection(oid).resolved);
        assertEq(court.bondsHeld(), 1 ether);
        vm.prank(panel[16]);
        court.ruleObjection(oid, false);
        vm.prank(panel[17]);
        vm.expectRevert(PleaCourt.ObjectionResolvedAlready.selector);
        court.ruleObjection(oid, true);
        assertEq(court.prizePot(), 1 ether);
        assertEq(court.claimable(bob), 0);
    }

    function test_timeoutOneSecondBeforeAndAtBoundaryThenSingleClaim() public {
        approved(alice, 1, 45);
        uint256 oid = objectTo(bob, driver.authorize(alice, 1));
        uint256 deadline = court.objection(oid).openedAt + 48 hours;
        vm.warp(deadline - 1);
        vm.prank(bob);
        vm.expectRevert(PleaCourt.RulingPeriodOpen.selector);
        court.reclaimObjectionBond(oid);
        vm.warp(deadline);
        vm.prank(bob);
        court.reclaimObjectionBond(oid);
        assertEq(court.totalClaimable(), 1 ether);
        assertEq(court.bondsHeld(), 0);
        assertEq(court.prizePot(), 0);
        vm.prank(bob);
        court.claim();
        assertEq(imd.balanceOf(bob), 1000 ether);
        vm.prank(bob);
        vm.expectRevert(PleaCourt.NothingToClaim.selector);
        court.claim();
        vm.prank(bob);
        vm.expectRevert(PleaCourt.ObjectionResolvedAlready.selector);
        court.reclaimObjectionBond(oid);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_prizeRoundingReservesBondsAndOldClaims(uint96 seed) public {
        approved(alice, 2, 1);
        approved(bob, 1, 2);
        approved(outsider, 1, 3);
        uint256 refunded = objectTo(bob, driver.authorize(alice, 1));
        uint256 pending = objectTo(outsider, driver.authorize(alice, 1));
        pending;
        vm.warp(block.timestamp + 48 hours);
        vm.prank(bob);
        court.reclaimObjectionBond(refunded);
        uint256 pot = bound(seed, 1, 1e24);
        imd.transfer(address(court), pot);
        vm.warp(court.seasonStart() + 30 days);
        court.endSeason();
        uint256 a = court.prizeCredit(1, alice);
        uint256 b = court.prizeCredit(1, bob);
        uint256 c = court.prizeCredit(1, outsider);
        assertEq(court.claimable(bob), 1 ether); // The returned bond stays immediately claimable.
        assertEq(court.claimable(alice), 0);
        assertEq(court.claimable(outsider), 0);
        assertLe(a * 6, pot);
        assertGt((a + 1) * 6, pot);
        assertLe(b * 6, pot * 2);
        assertGt((b + 1) * 6, pot * 2);
        assertLe(c * 6, pot * 3);
        assertGt((c + 1) * 6, pot * 3);
        assertLt(pot - a - b - c, 3);
        assertEq(court.bondsHeld(), 1 ether);
        assertEq(court.totalClaimable(), a + b + c + 1 ether);
        assertEq(court.prizePot(), pot - a - b - c);
        assertEq(imd.balanceOf(address(court)), court.totalClaimable() + court.bondsHeld() + court.prizePot());

        // Prizes stay locked for exactly PRIZE_LOCK, then pay once.
        uint64 unlockAt = court.prizeUnlockAt(1);
        assertEq(unlockAt, block.timestamp + 3 days);
        vm.warp(unlockAt - 1);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.PrizeLocked.selector, unlockAt));
        court.claimPrize(1);
        vm.warp(unlockAt);
        uint256 before = imd.balanceOf(outsider);
        if (c > 0) {
            vm.prank(outsider);
            court.claimPrize(1);
        }
        assertEq(imd.balanceOf(outsider) - before, c);
        vm.prank(outsider);
        vm.expectRevert(PleaCourt.NothingToClaim.selector);
        court.claimPrize(1);
        assertEq(court.totalClaimable(), a + b + 1 ether);
        assertEq(court.prizePot(), pot - a - b - c);
    }
}
