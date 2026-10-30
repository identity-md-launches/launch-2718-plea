// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {CourtFixture} from "test/helpers/CourtFixture.sol";
import {CourtHandler} from "test/helpers/CourtHandler.sol";

/// @dev Six actors, real court/letterbox and a hook-only authorization driver.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PleaCourtInvariantTest is CourtFixture {
    CourtHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 6; ++i) {
            address who = makeAddr(string.concat("stateful seller", vm.toString(i)));
            actors.push(who);
            imd.transfer(who, 10_000 ether);
        }
        handler = new CourtHandler(court, driver, imd, owner, panel, actors);
        for (uint256 i; i < actors.length; ++i) {
            handler.submit(i, 1 ether, i % 2 == 0);
            handler.completeVerdict(i, uint8(15 + i * 6), true);
            handler.authorize(i, 0.1 ether);
            handler.object(i, i + 1);
        }
        handler.donate(0, 100 ether);
        handler.rule(0, false);
        handler.rule(1, true);
        handler.claim(2);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.submit.selector;
        selectors[1] = handler.judgeOne.selector;
        selectors[2] = handler.completeVerdict.selector;
        selectors[3] = handler.appeal.selector;
        selectors[4] = handler.closeOrWithdraw.selector;
        selectors[5] = handler.authorize.selector;
        selectors[6] = handler.object.selector;
        selectors[7] = handler.rule.selector;
        selectors[8] = handler.reclaim.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.claim.selector;
        selectors[11] = handler.endSeason.selector;
        selectors[12] = handler.advanceTime.selector;
        selectors[13] = handler.setSeat.selector;
        selectors[14] = handler.completeVerdict.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_IMDIsConservedAndAllLiabilitiesAreBacked() public view {
        checkAccounting();
    }

    function checkAccounting() internal view {
        uint256 credits;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(court.claimable(actors[i]), handler.credits(actors[i]), "individual liability mismatch");
            credits += court.claimable(actors[i]);
        }
        assertEq(court.totalClaimable(), credits);
        assertEq(court.bondsHeld(), handler.reservedBonds());
        assertEq(court.prizePot(), handler.pot(), "prizes and bonds must never enter the available pot");
        uint256 balance = imd.balanceOf(address(court));
        assertEq(balance + handler.payouts(), handler.inflows(), "IMD disappeared or was created");
        assertEq(balance, credits + handler.reservedBonds() + handler.pot());
    }

    function invariant_pendingCountsActivePleasAndVoteBoundsAgree() public view {
        uint256 pending;
        for (uint256 id = 1; id <= court.pleaCount(); ++id) {
            IPleaCourt.Plea memory p = court.plea(id);
            assertLe(p.sold, p.amount);
            assertTrue(p.round == 1 || p.round == 2);
            assertEq(p.appealed, p.round == 2);
            assertLe(uint256(p.approveVotes) + p.denyVotes, 30);
            assertEq(uint256(p.approveVotes) + p.denyVotes, court.scores(id, p.round).length);
            if (p.status == IPleaCourt.Status.Pending) {
                pending++;
                assertLt(p.approveVotes, 17);
                assertLt(p.denyVotes, 17);
            }
            if (p.status == IPleaCourt.Status.Closed || p.status == IPleaCourt.Status.Withdrawn) {
                assertTrue(court.activePlea(p.seller) != id, "finished plea still owns seller's slot");
            } else {
                assertEq(court.activePlea(p.seller), id);
            }
            if (p.status == IPleaCourt.Status.Approved || p.status == IPleaCourt.Status.Closed) {
                assertEq(p.approveVotes, 17);
                assertEq(p.windowExpiry, p.decidedAt + 7 minutes);
            }
        }
        assertEq(court.pendingCount(), pending);
        assertEq(court.pendingSince() == 0, pending == 0);
        if (handler.everFree()) assertTrue(court.tradesFreely(), "free trading must be permanent");
    }

    function invariant_bondsResolveOnceAndBoardContainsEligibleActors() public view {
        uint256 unresolved;
        for (uint256 id = 1; id <= court.objectionCount(); ++id) {
            IPleaCourt.Objection memory o = court.objection(id);
            assertTrue(court.sale(o.saleId).objected);
            if (!o.resolved) {
                unresolved++;
                assertFalse(o.bondReturned);
            }
            if (o.upheld) {
                assertTrue(o.resolved);
                assertTrue(o.bondReturned);
                assertEq(o.upholdVotes, 17);
            }
            assertLe(uint256(o.upholdVotes) + o.dismissVotes, 30);
        }
        assertEq(unresolved * 1 ether, court.bondsHeld());
        IPleaCourt.Entry[] memory board = court.leaderboard();
        uint256 positive;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(court.seasonPoints(court.season(), actors[i]), handler.points(actors[i]));
            if (handler.points(actors[i]) > 0) positive++;
        }
        assertEq(board.length, positive); // Six actors; the separate top-25 strike defect is reported.
        for (uint256 i; i < board.length; ++i) {
            assertGt(board[i].points, 0);
            assertEq(board[i].points, handler.points(board[i].account));
            if (i > 0) assertGe(board[i - 1].points, board[i].points);
            for (uint256 j; j < i; ++j) {
                assertTrue(board[i].account != board[j].account);
            }
        }
    }

    function afterInvariant() public {
        // Every credited actor can actually withdraw; aggregate solvency alone is not sufficient.
        for (uint256 i; i < actors.length; ++i) {
            handler.claim(i);
        }
        assertEq(court.totalClaimable(), 0);
        checkAccounting();
        assertGt(handler.successfulVotes(), 0);
        assertGt(handler.successfulSales(), 0);
        assertGt(handler.successfulObjections(), 0);
        assertGt(handler.successfulClaims(), 0);
    }

    function test_handlerReachesAppealTimeoutAndSeasonSettlement() public {
        handler.advanceTime(48 hours);
        handler.reclaim(2);
        handler.claim(3);
        handler.closeOrWithdraw(0);
        handler.submit(0, 17, false);
        handler.completeVerdict(0, 30, false);
        handler.advanceTime(4 hours);
        handler.appeal(0);
        handler.completeVerdict(0, 30, true);
        for (uint256 i; i < 4; ++i) {
            handler.advanceTime(8 days);
        }
        handler.endSeason();
        assertEq(handler.completedSeasons(), 1);
        checkAccounting();
        invariant_pendingCountsActivePleasAndVoteBoundsAgree();
        invariant_bondsResolveOnceAndBoardContainsEligibleActors();
        afterInvariant();
    }
}
