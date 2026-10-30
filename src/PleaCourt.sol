// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPleaCourt} from "./interfaces/IPleaCourt.sol";
import {Letterbox} from "./Letterbox.sol";

interface IOwned {
    function owner() external view returns (address);
}

/// @title PleaCourt
/// @notice The state behind the PLEA sell gate: pleas, the Cabal's verdicts, appeals, sale windows,
/// objections, seasons with a leaderboard and prize pot, and the dead-man switch. Created by the
/// PleaHook's constructor; the hook is the only caller that may authorise a sale.
/// @dev Administration is by the hook's owner (read live from the hook), so there is one owner.
contract PleaCourt is IPleaCourt {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants (see README)

    /// @notice Size of the Cabal.
    uint256 public constant JUDGE_COUNT = 30;
    /// @notice Judges that must agree on a side before the median is settled (a majority of 30).
    uint256 public constant QUORUM = 17;
    /// @notice Highest score a judge may give.
    uint256 public constant MAX_SCORE = 45;
    /// @notice Required score before fact points: `BASE_BAR - factPoints`.
    uint256 public constant BASE_BAR = 71;
    /// @notice Fact points cannot push the bar below zero.
    uint256 public constant MAX_FACT_POINTS = BASE_BAR;
    /// @notice Seat holders' scores are multiplied by 1.2 (12 / 10).
    uint256 public constant SEAT_MULTIPLIER_NUM = 12;
    uint256 public constant SEAT_MULTIPLIER_DEN = 10;
    /// @notice An approved seller may sell through the hook for this long.
    uint256 public constant SALE_WINDOW = 7 minutes;
    /// @notice A denied seller may appeal once, after this long.
    uint256 public constant APPEAL_DELAY = 4 hours;
    /// @notice Anyone may object to a sale for this long after it executes.
    uint256 public constant OBJECTION_WINDOW = 20 minutes;
    /// @notice No verdict for this long while a plea is pending frees trading forever.
    uint256 public constant DEAD_MAN_PERIOD = 33 hours;
    /// @notice Length of a season (chosen; the brief leaves it open).
    uint256 public constant SEASON_LENGTH = 30 days;
    /// @notice Leaderboard size and number of prize winners.
    uint256 public constant TOP_N = 25;
    /// @notice IMD bond an objector posts; returned if upheld or unruled, kept by the pot if dismissed (chosen).
    uint256 public constant OBJECTION_BOND = 1 ether;
    /// @notice The Cabal has this long to rule on an objection before the objector may reclaim the bond (chosen).
    uint256 public constant OBJECTION_RULING_PERIOD = 48 hours;
    /// @notice A seller whose sale is objected to successfully is barred from pleading for this long (chosen).
    uint256 public constant OBJECTION_BAN = 7 days;
    /// @notice Longest plea text, in bytes (chosen).
    uint256 public constant MAX_PLEA_BYTES = 1000;
    /// @notice A seller whose re-hearing (appeal or replacement plea) was also denied waits this long before
    /// pleading again (chosen).
    uint256 public constant DENIAL_COOLDOWN = 24 hours;
    /// @notice Season prizes unlock this long after the season ends: longer than a sale window, an objection
    /// window and a ruling period together, so every objection to the season's sales is ruled first (chosen).
    uint256 public constant PRIZE_LOCK = 3 days;
    /// @notice Entries the board keeps so a struck winner is replaced by the next eligible seller: the top 25
    /// plus a bench of the next 25.
    uint256 public constant BOARD_CAPACITY = 2 * TOP_N;

    // ------------------------------------------------------------------ errors

    error NotHook();
    error NotOwner();
    error NotJudge();
    error NotSeller();
    error NotObjector();
    error AlreadyBound();
    error NotBound();
    error FreeTrading();
    error CabalNotConfigured();
    error BadJudges();
    error EmptyPlea();
    error PleaTooLong();
    error ZeroAmount();
    error AmountTooLarge();
    error ActivePleaExists(uint256 pleaId);
    error Banned(uint64 until);
    error PleaTooEarly(uint64 earliest);
    error WrongStatus(Status status);
    error AlreadyVoted();
    error VotesCast();
    error Recused();
    error SelfObjection();
    error RulingPeriodOver();
    error PrizeLocked(uint64 unlockAt);
    error ScoreTooHigh();
    error FactPointsTooHigh();
    error AlreadyAppealed();
    error AppealTooEarly(uint64 earliest);
    error NoApprovedPlea();
    error WindowExpired(uint64 expiry);
    error ExceedsApprovedAmount(uint256 remaining);
    error WindowStillOpen();
    error NoSuchSale();
    error ObjectionWindowClosed();
    error AlreadyObjected();
    error ObjectionResolvedAlready();
    error RulingPeriodOpen();
    error SeasonNotOver(uint64 endsAt);
    error DeadManNotDue();
    error NothingToClaim();

    // ------------------------------------------------------------------ events

    event Bound(address indexed imd);
    event JudgesSet(address[] judges);
    event SeatSet(address indexed account, bool holds);
    event PleaSubmitted(uint256 indexed pleaId, address indexed seller, uint256 amount, string text, bool viaLetterbox);
    event JudgeScored(
        uint256 indexed pleaId,
        uint8 round,
        address indexed judge,
        uint16 effectiveScore,
        uint8 factPoints,
        bool approve
    );
    event Verdict(
        uint256 indexed pleaId,
        address indexed seller,
        uint8 round,
        bool approved,
        uint16 medianScore,
        uint16 approveVotes,
        uint16 denyVotes
    );
    event PleaAppealed(uint256 indexed pleaId, address indexed seller, uint8 round);
    event PleaWithdrawn(uint256 indexed pleaId, address indexed seller);
    event PleaStruck(uint256 indexed pleaId, address indexed seller);
    event SaleWindowOpened(uint256 indexed pleaId, address indexed seller, uint256 amount, uint64 expiry);
    event SaleWindowClosed(uint256 indexed pleaId, address indexed seller, uint256 sold, bool expired);
    event SaleRecorded(uint256 indexed saleId, uint256 indexed pleaId, address indexed seller, uint256 amount);
    event ObjectionRaised(
        uint256 indexed objectionId, uint256 indexed saleId, address indexed objector, address seller
    );
    event ObjectionRuled(uint256 indexed objectionId, address indexed judge, bool uphold);
    event ObjectionResolved(uint256 indexed objectionId, uint256 indexed saleId, bool upheld, bool byTimeout);
    event SellerBanned(address indexed seller, uint64 until);
    event PointsAwarded(uint256 indexed season, address indexed account, uint256 points, uint256 total);
    event SeasonEnded(uint256 indexed season, uint256 pot, uint256 winners, uint256 nextSeasonStart);
    event PrizeAwarded(uint256 indexed season, address indexed account, uint256 amount);
    event PrizeForfeited(uint256 indexed season, address indexed account, uint256 amount);
    event PrizeClaimed(uint256 indexed season, address indexed account, uint256 amount);
    event PotSwept(uint256 indexed season, address indexed to, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event DeadManSwitchTriggered(uint64 at, uint64 deadline);

    // ------------------------------------------------------------------ storage

    /// @notice The PleaHook that created this court; the only caller that may authorise a sale.
    address public immutable hook;
    /// @notice Drop-box through which pleas can be posted on a seller's behalf.
    Letterbox public immutable letterbox;
    /// @notice The pair currency (IMD), set once when the hook's pool is initialized. Prizes and bonds are in it.
    IERC20 public imd;

    address[] private _judges;
    mapping(address => bool) public isJudge;
    mapping(address => bool) public hasSeat;

    uint256 public pleaCount;
    mapping(uint256 => Plea) private _pleas;
    mapping(uint256 => string) public pleaText;
    /// @notice The seller's plea that is still in flight (pending, approved with an open window, or denied
    /// and appealable); zero when none.
    mapping(address => uint256) public activePlea;
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) public hasScored;
    mapping(uint256 => mapping(uint8 => uint16[])) private _scores;
    /// @notice Earliest time a seller may plead again after a denial.
    mapping(address => uint64) public nextPleaAt;
    /// @notice True after a first denial until the seller's one re-hearing has been heard: the next plea
    /// the seller submits is that re-hearing and cannot be appealed.
    mapping(address => bool) public rehearingOwed;

    uint256 public saleCount;
    mapping(uint256 => Sale) private _sales;

    uint256 public objectionCount;
    mapping(uint256 => Objection) private _objections;
    mapping(uint256 => mapping(address => bool)) public hasRuled;
    uint256 public bondsHeld;
    mapping(address => uint64) public bannedUntil;

    uint256 public pendingCount;
    uint64 public pendingSince;
    uint64 public lastVerdictAt;
    bool public deadManTriggered;

    uint256 public season = 1;
    uint64 public seasonStart;
    Entry[] private _board;
    mapping(uint256 => mapping(address => uint256)) public seasonPoints;
    /// @notice When each ended season ended; zero while it has not.
    mapping(uint256 => uint64) public seasonEndedAt;
    /// @notice Unclaimed season prizes, locked until `prizeUnlockAt(season)` and forfeited by a strike.
    mapping(uint256 => mapping(address => uint256)) public prizeCredit;
    /// @notice Immediately claimable IMD: returned bonds and the post-switch pot sweep.
    mapping(address => uint256) public claimable;
    /// @notice Everything credited and not yet paid out, prizes included.
    uint256 public totalClaimable;

    // ------------------------------------------------------------------ modifiers

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != IOwned(hook).owner()) revert NotOwner();
        _;
    }

    modifier onlyJudge() {
        if (!isJudge[msg.sender]) revert NotJudge();
        _;
    }

    constructor(address hook_) {
        hook = hook_;
        letterbox = new Letterbox(address(this));
        seasonStart = uint64(block.timestamp);
    }

    // ------------------------------------------------------------------ hook-only

    /// @notice Records the pair currency when the hook's pool is initialized. Once.
    function bind(address imd_) external onlyHook {
        if (address(imd) != address(0)) revert AlreadyBound();
        imd = IERC20(imd_);
        emit Bound(imd_);
    }

    /// @notice Reserves `amount` of `seller`'s open sale window for a sale the hook is about to execute.
    /// Reverts unless the seller holds an approved plea whose window is open and whose approved amount
    /// covers it, and is not banned. The hook settles the sale with `settleSale` in the same transaction.
    function authorizeSale(address seller, uint256 amount) external onlyHook returns (uint256 saleId) {
        _latchDeadMan();
        if (bannedUntil[seller] > block.timestamp) revert Banned(bannedUntil[seller]);
        uint256 pleaId = activePlea[seller];
        Plea storage p = _pleas[pleaId];
        if (pleaId == 0 || p.status != Status.Approved) revert NoApprovedPlea();
        if (block.timestamp > p.windowExpiry) revert WindowExpired(p.windowExpiry);
        uint256 remaining = p.amount - p.sold;
        if (amount > remaining) revert ExceedsApprovedAmount(remaining);
        p.sold += uint128(amount);
        saleId = ++saleCount;
        _sales[saleId] = Sale({
            pleaId: pleaId,
            seller: seller,
            amount: uint128(amount),
            executedAt: uint64(block.timestamp),
            objected: false,
            season: p.season
        });
    }

    /// @notice Settles a reserved sale to the PLEA the pool consumed: the unconsumed rest of the
    /// reservation returns to the window, and the window closes once the whole approved amount is sold.
    function settleSale(uint256 saleId, uint256 consumed) external onlyHook {
        Sale storage s = _sales[saleId];
        if (s.seller == address(0)) revert NoSuchSale();
        Plea storage p = _pleas[s.pleaId];
        if (consumed > s.amount) revert ExceedsApprovedAmount(s.amount);
        p.sold -= uint128(s.amount - consumed);
        s.amount = uint128(consumed);
        emit SaleRecorded(saleId, s.pleaId, s.seller, consumed);
        if (p.status == Status.Approved && p.sold == p.amount) _closeWindow(s.pleaId, p, false);
    }

    // ------------------------------------------------------------------ owner

    /// @notice Installs the Cabal: exactly 30 distinct judge addresses. Replaces any earlier panel.
    function setJudges(address[] calldata panel) external onlyOwner {
        if (panel.length != JUDGE_COUNT) revert BadJudges();
        uint256 old = _judges.length;
        for (uint256 i = 0; i < old; i++) {
            isJudge[_judges[i]] = false;
        }
        delete _judges;
        for (uint256 i = 0; i < panel.length; i++) {
            address j = panel[i];
            if (j == address(0) || isJudge[j]) revert BadJudges();
            isJudge[j] = true;
            _judges.push(j);
        }
        emit JudgesSet(panel);
    }

    /// @notice Grants or revokes a seat. Seat holders' scores are multiplied by 1.2.
    function setSeat(address account, bool holds) external onlyOwner {
        hasSeat[account] = holds;
        emit SeatSet(account, holds);
    }

    // ------------------------------------------------------------------ pleas

    /// @notice Submits a plea to sell `amount` PLEA, with the seller's case in `text`.
    function submitPlea(string calldata text, uint256 amount) external returns (uint256 pleaId) {
        return _submit(msg.sender, text, amount, false);
    }

    /// @notice The letterbox's route: it has already identified `seller`.
    function submitPleaFor(address seller, string calldata text, uint256 amount) external returns (uint256 pleaId) {
        if (msg.sender != address(letterbox)) revert NotHook();
        return _submit(seller, text, amount, true);
    }

    function _submit(address seller, string calldata text, uint256 amount, bool viaLetterbox)
        internal
        returns (uint256 pleaId)
    {
        _latchDeadMan();
        if (deadManTriggered) revert FreeTrading();
        if (!cabalConfigured()) revert CabalNotConfigured();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert AmountTooLarge();
        if (bytes(text).length == 0) revert EmptyPlea();
        if (bytes(text).length > MAX_PLEA_BYTES) revert PleaTooLong();
        if (bannedUntil[seller] > block.timestamp) revert Banned(bannedUntil[seller]);
        if (nextPleaAt[seller] > block.timestamp) revert PleaTooEarly(nextPleaAt[seller]);
        uint256 active = activePlea[seller];
        if (active != 0) revert ActivePleaExists(active);

        pleaId = ++pleaCount;
        Plea storage p = _pleas[pleaId];
        p.seller = seller;
        p.amount = uint128(amount);
        p.submittedAt = uint64(block.timestamp);
        p.round = 1;
        // a plea after a denial is the seller's one re-hearing: it cannot be appealed in turn
        p.appealed = rehearingOwed[seller];
        p.status = Status.Pending;
        pleaText[pleaId] = text;
        activePlea[seller] = pleaId;
        _enterPending();
        emit PleaSubmitted(pleaId, seller, amount, text, viaLetterbox);
    }

    /// @notice A judge's score for a pending plea. `score` is 0-45; `factPoints` are the verifiable facts the
    /// judge credits, each lowering the bar by one from 71. Seat holders' scores are scaled by 1.2. The
    /// judge approves when the scaled score reaches `71 - factPoints`. Once 17 judges share a side the
    /// median is settled and the verdict is final. When the whole Cabal has voted and neither side has
    /// 17, the plea is denied (approval needs 17 to agree) and the seller may appeal. A judge never
    /// scores their own plea.
    function judge(uint256 pleaId, uint8 score, uint8 factPoints) external onlyJudge {
        _latchDeadMan();
        if (deadManTriggered) revert FreeTrading();
        Plea storage p = _pleas[pleaId];
        if (p.status != Status.Pending) revert WrongStatus(p.status);
        if (msg.sender == p.seller) revert Recused();
        if (score > MAX_SCORE) revert ScoreTooHigh();
        if (factPoints > MAX_FACT_POINTS) revert FactPointsTooHigh();
        uint8 round = p.round;
        if (hasScored[pleaId][round][msg.sender]) revert AlreadyVoted();
        hasScored[pleaId][round][msg.sender] = true;

        uint16 effective = uint16(effectiveScore(p.seller, score));
        bool approve = uint256(effective) + factPoints >= BASE_BAR;
        _scores[pleaId][round].push(effective);
        if (approve) p.approveVotes += 1;
        else p.denyVotes += 1;
        emit JudgeScored(pleaId, round, msg.sender, effective, factPoints, approve);

        if (p.approveVotes >= QUORUM) _decide(pleaId, p, true);
        else if (p.denyVotes >= QUORUM) _decide(pleaId, p, false);
        else if (uint256(p.approveVotes) + p.denyVotes >= eligibleJudges(pleaId)) _decide(pleaId, p, false); // hung
    }

    /// @notice Judges who may score `pleaId`: the whole Cabal, less the seller when the seller sits on it.
    /// The hung-Cabal rule settles the plea once this many have voted, so a judge's own plea cannot hang.
    function eligibleJudges(uint256 pleaId) public view returns (uint256) {
        return isJudge[_pleas[pleaId].seller] ? JUDGE_COUNT - 1 : JUDGE_COUNT;
    }

    function _decide(uint256 pleaId, Plea storage p, bool approved) internal {
        uint16 median = _median(_scores[pleaId][p.round]);
        p.medianScore = median;
        p.decidedAt = uint64(block.timestamp);
        lastVerdictAt = uint64(block.timestamp);
        _leavePending();
        emit Verdict(pleaId, p.seller, p.round, approved, median, p.approveVotes, p.denyVotes);
        if (approved) {
            p.status = Status.Approved;
            p.season = uint64(season);
            p.windowExpiry = uint64(block.timestamp + SALE_WINDOW);
            rehearingOwed[p.seller] = false;
            _award(p.seller, median);
            emit SaleWindowOpened(pleaId, p.seller, p.amount, p.windowExpiry);
        } else {
            p.status = Status.Denied;
            if (p.appealed) {
                // the re-hearing failed too: a fresh plea only after the cooldown
                rehearingOwed[p.seller] = false;
                nextPleaAt[p.seller] = uint64(block.timestamp + DENIAL_COOLDOWN);
            } else {
                // one re-hearing, as an appeal or a replacement plea, and not before 4 hours
                rehearingOwed[p.seller] = true;
                nextPleaAt[p.seller] = uint64(block.timestamp + APPEAL_DELAY);
            }
        }
    }

    /// @notice One appeal of a denied plea, by its seller, 4 hours after the denial. Opens a second round.
    function appeal(uint256 pleaId) external {
        Plea storage p = _pleas[pleaId];
        if (msg.sender != p.seller) revert NotSeller();
        if (p.status != Status.Denied) revert WrongStatus(p.status);
        if (p.appealed) revert AlreadyAppealed();
        _latchDeadMan();
        if (deadManTriggered) revert FreeTrading();
        if (bannedUntil[p.seller] > block.timestamp) revert Banned(bannedUntil[p.seller]);
        uint64 earliest = p.decidedAt + uint64(APPEAL_DELAY);
        if (block.timestamp < earliest) revert AppealTooEarly(earliest);
        p.appealed = true;
        p.round = 2;
        p.approveVotes = 0;
        p.denyVotes = 0;
        p.medianScore = 0;
        p.status = Status.Pending;
        _enterPending();
        emit PleaAppealed(pleaId, p.seller, 2);
    }

    /// @notice Withdraws a pending or denied plea so the seller can submit another. Forfeits any appeal.
    /// A pending plea the Cabal has started to score cannot be withdrawn: its verdict is owed, and the
    /// denial's cooldown applies to the seller's next plea whether or not this one is withdrawn.
    function withdrawPlea(uint256 pleaId) external {
        Plea storage p = _pleas[pleaId];
        if (msg.sender != p.seller) revert NotSeller();
        _latchDeadMan();
        if (p.status == Status.Pending) {
            if (!deadManTriggered && _scores[pleaId][p.round].length != 0) revert VotesCast();
            _leavePending();
        } else if (p.status != Status.Denied) {
            revert WrongStatus(p.status);
        }
        p.status = Status.Withdrawn;
        activePlea[p.seller] = 0;
        emit PleaWithdrawn(pleaId, p.seller);
    }

    /// @dev An upheld objection ends whatever plea the seller has in flight.
    function _strikeActivePlea(address seller) internal {
        uint256 pleaId = activePlea[seller];
        if (pleaId == 0) return;
        Plea storage p = _pleas[pleaId];
        if (p.status == Status.Pending) _leavePending();
        else if (p.status == Status.Approved) emit SaleWindowClosed(pleaId, seller, p.sold, false);
        p.status = Status.Struck;
        activePlea[seller] = 0;
        emit PleaStruck(pleaId, seller);
    }

    /// @notice Closes an approved plea whose 7-minute window has passed, freeing the seller to plead again.
    function closeWindow(uint256 pleaId) external {
        Plea storage p = _pleas[pleaId];
        if (p.status != Status.Approved) revert WrongStatus(p.status);
        if (block.timestamp <= p.windowExpiry) revert WindowStillOpen();
        _closeWindow(pleaId, p, true);
    }

    function _closeWindow(uint256 pleaId, Plea storage p, bool expired) internal {
        p.status = Status.Closed;
        activePlea[p.seller] = 0;
        emit SaleWindowClosed(pleaId, p.seller, p.sold, expired);
    }

    // ------------------------------------------------------------------ objections

    /// @notice Objects to a sale within 20 minutes of its execution, posting the IMD bond. The seller cannot
    /// object to their own sale.
    function object(uint256 saleId) external returns (uint256 objectionId) {
        Sale storage s = _sales[saleId];
        if (s.seller == address(0)) revert NoSuchSale();
        if (msg.sender == s.seller) revert SelfObjection();
        if (s.objected) revert AlreadyObjected();
        if (block.timestamp > s.executedAt + OBJECTION_WINDOW) revert ObjectionWindowClosed();
        if (address(imd) == address(0)) revert NotBound();
        s.objected = true;
        objectionId = ++objectionCount;
        _objections[objectionId] = Objection({
            saleId: saleId,
            objector: msg.sender,
            openedAt: uint64(block.timestamp),
            upholdVotes: 0,
            dismissVotes: 0,
            resolved: false,
            upheld: false,
            bondReturned: false
        });
        bondsHeld += OBJECTION_BOND;
        emit ObjectionRaised(objectionId, saleId, msg.sender, s.seller);
        imd.safeTransferFrom(msg.sender, address(this), OBJECTION_BOND);
    }

    /// @notice A judge's ruling on an objection, within the ruling period. 17 upholds ban the seller, void
    /// the season points of the sale's season (or forfeit the prize they already earned), and strike the
    /// seller's plea in flight; 17 dismissals forfeit the objector's bond to the pot. The sale's seller and
    /// the objector never rule.
    function ruleObjection(uint256 objectionId, bool uphold) external onlyJudge {
        _latchDeadMan();
        Objection storage o = _objections[objectionId];
        if (o.objector == address(0)) revert NoSuchSale();
        if (o.resolved) revert ObjectionResolvedAlready();
        if (block.timestamp > o.openedAt + OBJECTION_RULING_PERIOD) revert RulingPeriodOver();
        Sale storage s = _sales[o.saleId];
        if (msg.sender == s.seller || msg.sender == o.objector) revert Recused();
        if (hasRuled[objectionId][msg.sender]) revert AlreadyVoted();
        hasRuled[objectionId][msg.sender] = true;
        if (uphold) o.upholdVotes += 1;
        else o.dismissVotes += 1;
        emit ObjectionRuled(objectionId, msg.sender, uphold);

        if (o.upholdVotes >= QUORUM) {
            o.resolved = true;
            o.upheld = true;
            address seller = s.seller;
            uint64 until = uint64(block.timestamp + OBJECTION_BAN);
            bannedUntil[seller] = until;
            _strike(seller, s.season);
            _strikeActivePlea(seller);
            _returnBond(o);
            emit SellerBanned(seller, until);
            emit ObjectionResolved(objectionId, o.saleId, true, false);
        } else if (o.dismissVotes >= QUORUM) {
            o.resolved = true;
            bondsHeld -= OBJECTION_BOND; // the bond joins the pot
            emit ObjectionResolved(objectionId, o.saleId, false, false);
        }
    }

    /// @notice The objector takes the bond back when the Cabal has not ruled within the ruling period.
    function reclaimObjectionBond(uint256 objectionId) external {
        Objection storage o = _objections[objectionId];
        if (msg.sender != o.objector) revert NotObjector();
        if (o.resolved) revert ObjectionResolvedAlready();
        if (block.timestamp < o.openedAt + OBJECTION_RULING_PERIOD) revert RulingPeriodOpen();
        o.resolved = true;
        _returnBond(o);
        emit ObjectionResolved(objectionId, o.saleId, false, true);
    }

    function _returnBond(Objection storage o) internal {
        o.bondReturned = true;
        bondsHeld -= OBJECTION_BOND;
        _credit(o.objector, OBJECTION_BOND);
    }

    // ------------------------------------------------------------------ seasons

    /// @notice Ends the season once its length has passed: the prize pot is split among the top 25 of the
    /// leaderboard, pro rata to points, as prize credits that unlock after `PRIZE_LOCK` (`claimPrize`).
    /// An empty leaderboard rolls the pot into the next season, except after the dead-man switch, when
    /// nobody can earn points again: what the board does not take is credited to the hook's owner.
    function endSeason() external {
        uint64 endsAt = seasonStart + uint64(SEASON_LENGTH);
        if (block.timestamp < endsAt) revert SeasonNotOver(endsAt);
        _latchDeadMan(); // a due switch sweeps this pot rather than rolling it over

        uint256 pot = prizePot();
        uint256 ended = season;
        Entry[] memory top = _sorted(TOP_N);
        uint256 n = top.length;
        uint256 totalPoints;
        for (uint256 i = 0; i < n; i++) {
            totalPoints += top[i].points;
        }
        uint256 winners;
        uint256 paid;
        if (pot > 0 && totalPoints > 0) {
            for (uint256 i = 0; i < n; i++) {
                uint256 share = pot * top[i].points / totalPoints;
                if (share == 0) continue;
                winners++;
                paid += share;
                prizeCredit[ended][top[i].account] += share;
                totalClaimable += share;
                emit PrizeAwarded(ended, top[i].account, share);
            }
        }
        delete _board;
        seasonEndedAt[ended] = uint64(block.timestamp);
        season = ended + 1;
        seasonStart = uint64(block.timestamp);
        emit SeasonEnded(ended, pot, winners, block.timestamp);
        if (deadManTriggered && pot > paid) {
            address to = IOwned(hook).owner();
            if (to != address(0)) {
                _credit(to, pot - paid);
                emit PotSwept(ended, to, pot - paid);
            }
        }
    }

    /// @notice Pays out the caller's prize of an ended season once its lock has passed.
    function claimPrize(uint256 season_) external {
        uint64 unlockAt = prizeUnlockAt(season_);
        if (unlockAt == 0 || block.timestamp < unlockAt) revert PrizeLocked(unlockAt);
        uint256 amount = prizeCredit[season_][msg.sender];
        if (amount == 0) revert NothingToClaim();
        prizeCredit[season_][msg.sender] = 0;
        totalClaimable -= amount;
        emit PrizeClaimed(season_, msg.sender, amount);
        imd.safeTransfer(msg.sender, amount);
    }

    /// @notice Pays out everything immediately claimable by the caller: returned bonds and pot sweeps.
    function claim() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        emit Claimed(msg.sender, amount);
        imd.safeTransfer(msg.sender, amount);
    }

    function _credit(address account, uint256 amount) internal {
        claimable[account] += amount;
        totalClaimable += amount;
    }

    function _award(address account, uint256 pts) internal {
        if (pts == 0) return;
        uint256 total = seasonPoints[season][account] + pts;
        seasonPoints[season][account] = total;
        uint256 n = _board.length;
        uint256 minIdx;
        uint256 minPts = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (_board[i].account == account) {
                _board[i].points = total;
                emit PointsAwarded(season, account, pts, total);
                return;
            }
            if (_board[i].points < minPts) {
                minPts = _board[i].points;
                minIdx = i;
            }
        }
        if (n < BOARD_CAPACITY) _board.push(Entry({account: account, points: total}));
        else if (total > minPts) _board[minIdx] = Entry({account: account, points: total});
        emit PointsAwarded(season, account, pts, total);
    }

    /// @dev Voids `account`'s points of `season_`: off the board while that season runs (the bench entry
    /// behind them moves up), or the prize credited to them once it has ended, back into the pot.
    function _strike(address account, uint256 season_) internal {
        if (season_ == season) {
            seasonPoints[season][account] = 0;
            uint256 n = _board.length;
            for (uint256 i = 0; i < n; i++) {
                if (_board[i].account == account) {
                    _board[i] = _board[n - 1];
                    _board.pop();
                    break;
                }
            }
        } else {
            uint256 amount = prizeCredit[season_][account];
            if (amount == 0) return;
            prizeCredit[season_][account] = 0;
            totalClaimable -= amount;
            emit PrizeForfeited(season_, account, amount);
        }
    }

    // ------------------------------------------------------------------ dead-man switch

    /// @notice Flips the switch once the Cabal has returned no verdict for 33 hours with a plea pending.
    /// The sell restriction is already off from the moment the deadline passes; this records it.
    function triggerDeadManSwitch() external {
        if (deadManTriggered) return;
        if (!tradesFreely()) revert DeadManNotDue();
        _latchDeadMan();
    }

    /// @dev Makes the switch permanent the moment it is due, before any state change could move the deadline.
    function _latchDeadMan() internal {
        if (!deadManTriggered && tradesFreely()) {
            deadManTriggered = true;
            emit DeadManSwitchTriggered(uint64(block.timestamp), deadManDeadline());
        }
    }

    function _enterPending() internal {
        if (pendingCount == 0) pendingSince = uint64(block.timestamp);
        pendingCount += 1;
    }

    function _leavePending() internal {
        pendingCount -= 1;
        if (pendingCount == 0) pendingSince = 0;
    }

    // ------------------------------------------------------------------ views

    /// @notice Whether PLEA sells are free of the plea gate: the dead-man switch fired or is due.
    function tradesFreely() public view returns (bool) {
        if (deadManTriggered) return true;
        uint64 deadline = deadManDeadline();
        return deadline != 0 && block.timestamp >= deadline;
    }

    /// @notice When the dead-man switch becomes due, or zero while no plea is pending.
    function deadManDeadline() public view returns (uint64) {
        if (pendingCount == 0) return 0;
        uint64 from = pendingSince > lastVerdictAt ? pendingSince : lastVerdictAt;
        return from + uint64(DEAD_MAN_PERIOD);
    }

    /// @notice The dead-man timer for a frontend: the deadline, the seconds left, and whether it has fired.
    function deadManTimer() external view returns (uint64 deadline, uint256 secondsLeft, bool triggered) {
        deadline = deadManDeadline();
        triggered = tradesFreely();
        if (deadline != 0 && block.timestamp < deadline) secondsLeft = deadline - block.timestamp;
    }

    function plea(uint256 pleaId) external view returns (Plea memory) {
        return _pleas[pleaId];
    }

    function pleaStatus(uint256 pleaId) external view returns (Status) {
        return _pleas[pleaId].status;
    }

    function scores(uint256 pleaId, uint8 round) external view returns (uint16[] memory) {
        return _scores[pleaId][round];
    }

    function sale(uint256 saleId) external view returns (Sale memory) {
        return _sales[saleId];
    }

    function objection(uint256 objectionId) external view returns (Objection memory) {
        return _objections[objectionId];
    }

    function judges() external view returns (address[] memory) {
        return _judges;
    }

    function cabalConfigured() public view returns (bool) {
        return _judges.length == JUDGE_COUNT;
    }

    /// @notice A seller's open sale window: its expiry (zero when none) and the PLEA still sellable in it.
    function saleWindow(address seller) external view returns (uint64 expiry, uint256 remaining) {
        Plea storage p = _pleas[activePlea[seller]];
        if (p.status == Status.Approved && block.timestamp <= p.windowExpiry) {
            expiry = p.windowExpiry;
            remaining = p.amount - p.sold;
        }
    }

    /// @notice The current season, when it started and when it can be ended.
    function currentSeason() external view returns (uint256 id, uint64 startedAt, uint64 endsAt) {
        return (season, seasonStart, seasonStart + uint64(SEASON_LENGTH));
    }

    /// @notice The season leaderboard, highest points first, at most 25 entries: the winners if the season
    /// ended now.
    function leaderboard() external view returns (Entry[] memory) {
        return _sorted(TOP_N);
    }

    /// @notice The whole board, highest points first: the top 25 and the bench behind them.
    function fullBoard() external view returns (Entry[] memory) {
        return _sorted(BOARD_CAPACITY);
    }

    /// @notice When the prizes of an ended season unlock; zero while the season has not ended.
    function prizeUnlockAt(uint256 season_) public view returns (uint64) {
        uint64 endedAt = seasonEndedAt[season_];
        return endedAt == 0 ? 0 : endedAt + uint64(PRIZE_LOCK);
    }

    function _sorted(uint256 limit) internal view returns (Entry[] memory top) {
        Entry[] memory sorted = _board;
        uint256 n = sorted.length;
        for (uint256 i = 1; i < n; i++) {
            Entry memory e = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1].points < e.points) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = e;
        }
        if (n <= limit) return sorted;
        top = new Entry[](limit);
        for (uint256 i = 0; i < limit; i++) {
            top[i] = sorted[i];
        }
    }

    /// @notice IMD in the court that belongs to nobody yet: the prize pot the season end will split.
    function prizePot() public view returns (uint256) {
        if (address(imd) == address(0)) return 0;
        return imd.balanceOf(address(this)) - totalClaimable - bondsHeld;
    }

    /// @notice A judge's raw score after the seat multiplier, capped at 65535 (never reached).
    function effectiveScore(address seller, uint8 score) public view returns (uint256) {
        return hasSeat[seller] ? uint256(score) * SEAT_MULTIPLIER_NUM / SEAT_MULTIPLIER_DEN : score;
    }

    /// @notice The bar a judge's scaled score must reach after crediting `factPoints` facts.
    function requiredScore(uint8 factPoints) external pure returns (uint256) {
        return factPoints >= BASE_BAR ? 0 : BASE_BAR - factPoints;
    }

    function _median(uint16[] storage list) internal view returns (uint16) {
        uint256 n = list.length;
        if (n == 0) return 0;
        uint16[] memory s = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            uint16 v = list[i];
            uint256 j = i;
            while (j > 0 && s[j - 1] > v) {
                s[j] = s[j - 1];
                j--;
            }
            s[j] = v;
        }
        if (n % 2 == 1) return s[n / 2];
        return uint16((uint256(s[n / 2 - 1]) + uint256(s[n / 2])) / 2);
    }
}
