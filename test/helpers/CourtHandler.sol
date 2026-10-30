// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaCourt} from "src/PleaCourt.sol";
import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {CourtHookDriver} from "test/helpers/CourtFixture.sol";

/// @dev All expected rejections have explicit preconditions or expectRevert. Unexpected reverts fail the campaign.
contract CourtHandler is Test {
    PleaCourt public immutable court;
    CourtHookDriver public immutable driver;
    MockERC20 public immutable imd;
    address public immutable admin;
    address[] public actors;
    address[] internal panel;

    uint256 public inflows;
    uint256 public payouts;
    uint256 public pot;
    uint256 public reservedBonds;
    mapping(address => uint256) public credits;
    /// @dev Locked season prizes, by season, as the court should hold them.
    mapping(uint256 => mapping(address => uint256)) public prizeCredits;
    uint256 public prizesOutstanding;
    uint256 public sweptToOwner;
    uint256 public successfulPrizeClaims;
    mapping(address => uint256) public points;
    mapping(uint256 => mapping(uint8 => uint256[55])) internal histogram;
    bool public everFree;
    uint256 public successfulVotes;
    uint256 public successfulSales;
    uint256 public successfulObjections;
    uint256 public successfulClaims;
    uint256 public completedSeasons;

    constructor(
        PleaCourt court_,
        CourtHookDriver driver_,
        MockERC20 imd_,
        address admin_,
        address[] memory judges_,
        address[] memory actors_
    ) {
        court = court_;
        driver = driver_;
        imd = imd_;
        admin = admin_;
        panel = judges_;
        actors = actors_;
    }

    function actor(uint256 seed) public view returns (address) {
        return actors[seed % actors.length];
    }

    function submit(uint256 seed, uint128 amountSeed, bool viaLetterbox) public {
        address who = actor(seed);
        if (
            court.tradesFreely() || court.activePlea(who) != 0 || court.bannedUntil(who) > block.timestamp
                || court.nextPleaAt(who) > block.timestamp
        ) return;
        bool rehearing = court.rehearingOwed(who);
        uint256 amount = bound(amountSeed, 1, type(uint128).max);
        address box = address(court.letterbox());
        vm.prank(who);
        if (viaLetterbox) {
            // Keep the real Letterbox identity path in the randomized state machine.
            (bool ok, bytes memory result) =
                box.call(abi.encodeWithSignature("post(string,uint256)", "random plea", amount));
            assertTrue(ok, string(result));
        } else {
            court.submitPlea("random plea", amount);
        }
        // A plea filed while a re-hearing is owed is that re-hearing and cannot itself be appealed.
        assertEq(court.plea(court.activePlea(who)).appealed, rehearing);
    }

    function judgeOne(uint256 seed, uint256 judgeSeed, uint8 scoreSeed, uint8 factSeed) public {
        address who = actor(seed);
        uint256 id = court.activePlea(who);
        IPleaCourt.Plea memory p = court.plea(id);
        address judge = panel[judgeSeed % 30];
        if (court.tradesFreely() || p.status != IPleaCourt.Status.Pending || court.hasScored(id, p.round, judge)) {
            return;
        }
        uint8 raw = uint8(bound(scoreSeed, 0, 45));
        uint8 facts = uint8(bound(factSeed, 0, 71));
        uint256 effective = court.hasSeat(who) ? uint256(raw) + raw / 5 : raw;
        vm.prank(judge);
        court.judge(id, raw, facts);
        histogram[id][p.round][effective]++;
        successfulVotes++;
        IPleaCourt.Plea memory afterPlea = court.plea(id);
        if (afterPlea.status == IPleaCourt.Status.Approved || afterPlea.status == IPleaCourt.Status.Denied) {
            uint256 expected = median(id, p.round);
            assertEq(afterPlea.medianScore, expected, "median disagrees with independently binned votes");
            if (afterPlea.status == IPleaCourt.Status.Approved) points[who] += expected;
        }
    }

    // A completion action ensures randomly interleaved individual votes reach real verdicts frequently.
    function completeVerdict(uint256 seed, uint8 rawSeed, bool approve) public {
        for (uint256 j; j < 30; ++j) {
            judgeOne(seed, j, rawSeed, approve ? 71 : 0);
        }
    }

    function median(uint256 id, uint8 round) public view returns (uint256) {
        uint256 count;
        for (uint256 i; i < 55; ++i) {
            count += histogram[id][round][i];
        }
        if (count == 0) return 0;
        uint256 loRank = (count - 1) / 2;
        uint256 hiRank = count / 2;
        uint256 seen;
        uint256 lo;
        uint256 hi;
        for (uint256 i; i < 55; ++i) {
            uint256 next = seen + histogram[id][round][i];
            if (seen <= loRank && loRank < next) lo = i;
            if (seen <= hiRank && hiRank < next) hi = i;
            seen = next;
        }
        return (lo + hi) / 2;
    }

    function appeal(uint256 seed) public {
        address who = actor(seed);
        uint256 id = court.activePlea(who);
        IPleaCourt.Plea memory p = court.plea(id);
        if (
            court.tradesFreely() || p.status != IPleaCourt.Status.Denied || p.appealed
                || block.timestamp < p.decidedAt + 4 hours || court.bannedUntil(who) > block.timestamp
        ) return;
        vm.prank(who);
        court.appeal(id);
        assertEq(court.plea(id).round, 2);
    }

    function closeOrWithdraw(uint256 seed) public {
        address who = actor(seed);
        uint256 id = court.activePlea(who);
        IPleaCourt.Plea memory p = court.plea(id);
        if (p.status == IPleaCourt.Status.Approved && block.timestamp > p.windowExpiry) {
            court.closeWindow(id);
        } else if (
            p.status == IPleaCourt.Status.Pending && court.scores(id, p.round).length != 0 && !court.tradesFreely()
        ) {
            // A verdict in progress is owed: the seller cannot dodge it by withdrawing.
            vm.prank(who);
            vm.expectRevert(PleaCourt.VotesCast.selector);
            court.withdrawPlea(id);
        } else if (p.status == IPleaCourt.Status.Pending || p.status == IPleaCourt.Status.Denied) {
            vm.prank(who);
            court.withdrawPlea(id);
        }
        observeFree();
    }

    function authorize(uint256 seed, uint128 amountSeed) public {
        authorizePartial(seed, amountSeed, type(uint128).max);
    }

    /// @dev The pool may consume less than the reservation: only `consumed` is charged and recorded.
    function authorizePartial(uint256 seed, uint128 amountSeed, uint128 consumedSeed) public {
        address who = actor(seed);
        (uint64 expiry, uint256 remaining) = court.saleWindow(who);
        if (expiry == 0 || remaining == 0 || court.tradesFreely()) return;
        uint256 amount = bound(amountSeed, 1, remaining);
        uint256 consumed = bound(consumedSeed, 1, amount);
        uint256 pleaId = court.activePlea(who);
        uint256 soldBefore = court.plea(pleaId).sold;
        uint256 id = driver.authorizePartial(who, amount, consumed);
        assertEq(court.sale(id).amount, consumed);
        IPleaCourt.Plea memory p = court.plea(pleaId);
        assertEq(p.sold, soldBefore + consumed, "unconsumed reservation not returned to the window");
        assertEq(p.status == IPleaCourt.Status.Closed, p.sold == p.amount);
        successfulSales++;
    }

    function object(uint256 saleSeed, uint256 actorSeed) public {
        if (court.saleCount() == 0) return;
        uint256 saleId = 1 + saleSeed % court.saleCount();
        IPleaCourt.Sale memory s = court.sale(saleId);
        address who = actor(actorSeed);
        if (s.objected || block.timestamp > s.executedAt + 20 minutes || imd.balanceOf(who) < 1 ether) return;
        if (who == s.seller) {
            vm.prank(who);
            vm.expectRevert(PleaCourt.SelfObjection.selector);
            court.object(saleId);
            return;
        }
        vm.startPrank(who);
        imd.approve(address(court), 1 ether);
        court.object(saleId);
        vm.stopPrank();
        inflows += 1 ether;
        reservedBonds += 1 ether;
        successfulObjections++;
    }

    function rule(uint256 seed, bool uphold) public {
        if (court.objectionCount() == 0) return;
        uint256 id = 1 + seed % court.objectionCount();
        IPleaCourt.Objection memory beforeO = court.objection(id);
        if (beforeO.resolved) return;
        if (block.timestamp > beforeO.openedAt + 48 hours) {
            vm.prank(panel[0]);
            vm.expectRevert(PleaCourt.RulingPeriodOver.selector);
            court.ruleObjection(id, uphold);
            return;
        }
        for (uint256 j; j < 17; ++j) {
            vm.prank(panel[j]);
            court.ruleObjection(id, uphold);
        }
        reservedBonds -= 1 ether;
        if (uphold) {
            credits[beforeO.objector] += 1 ether;
            IPleaCourt.Sale memory s = court.sale(beforeO.saleId);
            if (s.season == court.season()) {
                points[s.seller] = 0;
            } else {
                // The sale's season already paid out: its prize is forfeited back into the pot.
                uint256 forfeited = prizeCredits[s.season][s.seller];
                prizeCredits[s.season][s.seller] = 0;
                prizesOutstanding -= forfeited;
                pot += forfeited;
            }
            assertEq(court.activePlea(s.seller), 0, "upheld objection left a plea in flight");
            assertGt(court.bannedUntil(s.seller), block.timestamp);
        } else {
            pot += 1 ether;
        }
    }

    function reclaim(uint256 seed) public {
        if (court.objectionCount() == 0) return;
        uint256 id = 1 + seed % court.objectionCount();
        IPleaCourt.Objection memory o = court.objection(id);
        if (o.resolved || block.timestamp < o.openedAt + 48 hours) return;
        vm.prank(o.objector);
        court.reclaimObjectionBond(id);
        reservedBonds -= 1 ether;
        credits[o.objector] += 1 ether;
    }

    function donate(uint256 seed, uint96 amountSeed) public {
        address who = actor(seed);
        uint256 available = imd.balanceOf(who);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(who);
        imd.transfer(address(court), amount);
        inflows += amount;
        pot += amount;
    }

    function claim(uint256 seed) public {
        claimFor(actor(seed));
    }

    function claimFor(address who) public {
        uint256 due = credits[who];
        uint256 beforeBalance = imd.balanceOf(who);
        vm.prank(who);
        if (due == 0) {
            vm.expectRevert(PleaCourt.NothingToClaim.selector);
            court.claim();
        } else {
            court.claim();
            assertEq(imd.balanceOf(who) - beforeBalance, due);
            credits[who] = 0;
            payouts += due;
            successfulClaims++;
        }
    }

    function claimPrize(uint256 seed, uint256 seasonSeed) public {
        uint256 ended = court.season() - 1;
        if (ended == 0) return;
        claimPrizeFor(actor(seed), 1 + seasonSeed % ended);
    }

    function claimPrizeFor(address who, uint256 season_) public {
        uint64 unlockAt = court.prizeUnlockAt(season_);
        uint256 due = prizeCredits[season_][who];
        assertEq(court.prizeCredit(season_, who), due, "prize credit mismatch");
        uint256 beforeBalance = imd.balanceOf(who);
        vm.prank(who);
        if (block.timestamp < unlockAt) {
            vm.expectRevert(abi.encodeWithSelector(PleaCourt.PrizeLocked.selector, unlockAt));
            court.claimPrize(season_);
        } else if (due == 0) {
            vm.expectRevert(PleaCourt.NothingToClaim.selector);
            court.claimPrize(season_);
        } else {
            court.claimPrize(season_);
            assertEq(imd.balanceOf(who) - beforeBalance, due);
            prizeCredits[season_][who] = 0;
            prizesOutstanding -= due;
            payouts += due;
            successfulPrizeClaims++;
        }
    }

    function endSeason() public {
        if (block.timestamp < court.seasonStart() + 30 days) return;
        uint256 ended = court.season();
        bool sweep = court.deadManTriggered();
        uint256 totalPoints;
        for (uint256 i; i < actors.length; ++i) {
            totalPoints += points[actors[i]];
        }
        uint256 distributed;
        if (totalPoints > 0) {
            for (uint256 i; i < actors.length; ++i) {
                uint256 share = pot * points[actors[i]] / totalPoints;
                prizeCredits[ended][actors[i]] += share;
                prizesOutstanding += share;
                distributed += share;
            }
        }
        court.endSeason();
        pot -= distributed;
        if (sweep && pot > 0) {
            // After the switch nobody can earn points again: the rest goes to the hook's owner.
            credits[admin] += pot;
            sweptToOwner += pot;
            pot = 0;
        }
        for (uint256 i; i < actors.length; ++i) {
            points[actors[i]] = 0;
        }
        completedSeasons++;
    }

    function advanceTime(uint256 secondsSeed) public {
        uint256 step = secondsSeed % 8 == 0 ? bound(secondsSeed, 0, 8 days) : bound(secondsSeed, 0, 8 minutes);
        vm.warp(block.timestamp + step);
        observeFree();
    }

    function setSeat(uint256 seed, bool holds) public {
        vm.prank(admin);
        court.setSeat(actor(seed), holds);
    }

    function observeFree() internal {
        bool free = court.tradesFreely();
        if (everFree) assertTrue(free, "dead-man switch reversed");
        if (free) everFree = true;
    }
}
