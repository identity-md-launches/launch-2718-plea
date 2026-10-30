# PLEA hook — adversarial security review

Scope: `src/PleaHook.sol`, `src/PleaCourt.sol`, `src/Letterbox.sol`, `src/PLEAToken.sol` at this
commit, reviewed against the `uniswap-v4-security` and `eth-security` checklists. This is the
independent-minded review the brief asks for, written by the same contributor that built the code:
tests passing are not an audit, and work that holds other people's IMD still needs a separate
reviewer before release. Each finding says what was tried, what the code does, and what remains.

## 1. Sell-gate bypass

| Attack | Result |
| --- | --- |
| Sell PLEA through any router (exact input or exact output) | `beforeSwap` reverts `SellRequiresPlea`: direction is derived from `zeroForOne` vs. `tokenIsCurrency0`, not from amounts, so both swap kinds are caught (tests `test_sellThroughRouterRevertsWithoutPlea`, `test_sellExactOutputThroughRouterReverts`). |
| Router passes the approved seller's address in `hookData` | Ignored. Identity is never read from `hookData`; every sell that reaches `beforeSwap` is refused while the gate stands (`test_sellThroughRouterRevertsEvenWithApprovedPlea`). |
| Make the hook the `sender` without `sell` | The PoolManager never calls a hook for a swap the hook itself initiates (`Hooks.noSelfCall`), so the hook's own swap is the only sell that skips `beforeSwap`, and `poolManager.swap` is only called from `unlockCallback`, which only the PoolManager calls, only during an unlock the hook itself started in `sell` after `court.authorizeSale` (or once trading is free). `sell` is `nonReentrant`. The earlier transient "selling" flag was unreachable for the same reason and is gone. |
| Single-sided PLEA liquidity above the price, then withdraw IMD after buyers take it | `beforeAddLiquidity` admits only the factory, owner-allowlisted providers, or anyone after the dead-man switch (`test_strangerCannotAddLiquidity`). The callback sees the calling contract, not the end LP, so the owner must never allowlist a shared position manager (README, After launch 4). Removal is never gated, so nothing can be trapped and the factory's fee collect (a zero-liquidity modify) passes untouched (`test_factoryCollectsFeesWithZeroLiquidityChange`). |
| Partial fill: the window is charged more than the pool took | `authorizeSale` reserves, `settleSale` (hook-only, same transaction) charges only the consumed PLEA and records the sale at that amount; the window stays open for the rest (`test_partialFillChargesOnlyWhatThePoolTook`). |
| Donate to the pool / use `beforeDonate` | Not enabled; donations do not move PLEA out to anyone. |
| Sell more than approved, or after the 7 minutes, or from another wallet's window | Court checks `Approved`, `now <= windowExpiry`, `sold + amount <= amount`, keyed by `msg.sender` of `sell` (tests `test_sellMoreThanApprovedReverts`, `test_sellAfterWindowReverts`, `test_sellByOtherSellerWindowReverts`). |
| Sell on another venue | **Open by design.** The token is standard, as the launch requires; a v2/v3 pool or an OTC trade is outside this hook. The gate protects this pool's IMD only. Documented in README. |
| Open a second pool on this hook with the same token and no gate | `beforeInitialize` binds once and only from the factory (`test_initialize_secondPoolReverts`, `test_initialize_fromStrangerReverts`). A pool on a different hook is the previous row. |

## 2. Oracle (Cabal) manipulation

- **Who decides.** 17 of 30 judges on one side settle a plea or an objection. The judges are trusted
  oracles the owner installs; a majority can approve anything or deny everything. That is the brief's
  model. A single compromised key can only cast one vote per plea per round (`hasScored`), and one per
  objection (`hasRuled`). A judge cannot score their own plea, and neither the sale's seller nor the
  objector rules on an objection (`Recused`).
- **Hung Cabal.** When all 30 have voted and neither side has 17 (any 14/16 to 16/14 split), the plea
  is denied with the median of all 30 and the seller may appeal. Without this a split vote left the plea
  pending forever, blocked every further vote, and let the dead-man switch fire on a Cabal that had
  voted in full (`test_hungCabalDeniesAndStopsTheClock`, reviewer proof `Proof_dd7e9df2facb`).
- **Fact points are per judge.** A judge who credits 71 fact points approves any score; this is the
  judge's own vote and counts once. Sellers cannot self-declare facts.
- **Seat multiplier.** Owner-granted; it scales only the judge's score of that seller, capped at 54,
  so a seat alone (54 < 71) never approves without fact points.
- **Owner trust (replacing the panel, seats).** `setJudges` replaces the whole panel in one transaction
  with no delay; old judges' cast votes stand, and new judges may vote in the same round, so a round can
  hold more than 30 votes and the owner could stack a verdict. `setSeat` is read live per vote. An owner
  that installs keys it controls can approve any plea (which ends the gate for that seller) or install
  a silent panel so the dead-man switch fires (which ends the gate for everyone): **the owner can end
  the gate early through the panel**, and the earlier claim here that it could not was wrong. These are
  the trust assumptions of a design whose judges the owner appoints, not bypasses available to anyone
  else. `renounceOwnership` before `setJudges` leaves a court nobody can ever plead to. Mitigation: the
  owner is the requester's address, a disclosed role; a timelock or multisig on it is recommended before
  launch (open item).
- **Owner cannot** block buys, block the factory's liquidity or fee collect, touch pot IMD except the
  post-switch sweep credited to it, or move anyone's tokens.
- **Dead-man gaming by the Cabal.** A Cabal that issues one verdict every <33h keeps the gate alive
  while ignoring most pleas. Judges could also deny everything. Both are verdicts, which is what the
  brief keys the switch to. A per-plea deadline (33h after submission) would be stricter; left as an
  open design choice for the requester.

## 3. Timing and reentrancy

- **`sell` reentrancy.** `nonReentrant`; state (court window spend) is written before the token pull and
  the unlock; IMD is sent by `poolManager.take` directly to the seller and court, so the hook never
  holds IMD and has no ETH path. A malicious `seller` cannot be a reentrant token (PLEA and IMD are
  fixed), and `take` to an EOA/contract does not call back into the hook.
- **Dead-man latch.** The deadline derives from `pendingSince` and `lastVerdictAt`. Any state change
  that could move it (`judge`, `appeal`, `withdrawPlea`, `authorizeSale`, `ruleObjection`, `_submit`)
  first latches `deadManTriggered` when due, so a late verdict or the withdrawal of the last pending
  plea cannot un-free trading (`test_deadManIsPermanentEvenIfTheCabalWakesUp`,
  `test_noTimerWithoutPendingPlea`). `beforeSwap` reads `tradesFreely()` as a view, which is consistent
  with the latch.
- **Clock before the Cabal.** No plea can be submitted until `setJudges` has run
  (`CabalNotConfigured`), so a stranger cannot start the 33-hour clock on a panel that does not exist
  (`test_noPleaBeforeTheCabalIsSet`).
- **Window edges.** The sale window is inclusive of `windowExpiry` (`test_sellAtWindowEdgeSucceeds`);
  the objection window is inclusive of `executedAt + 20 min`; the appeal is allowed at exactly
  `decidedAt + 4h`; rulings are accepted up to and including `openedAt + 48h`, reclaims only after. A
  verdict and the sale can land in the same block; objections open from the sale's block.
- **Season end and strikes.** `endSeason` is permissionless and uses the court's balance at that
  moment, so a last-second IMD transfer to the court raises the pot (a donation, not a theft). Prizes
  are credited, never pushed, so a recipient that cannot receive IMD cannot block the season end. Each
  sale carries the season its plea's points went to, and an upheld objection strikes that season: the
  points while it runs, the prize credit once it has ended. Prize credits unlock 3 days after the season
  end, longer than the 7 min + 20 min + 48 h in which any objection to the season's sales must be
  raised and ruled, so a seller cannot bank a prize by ending the season between the verdict and the
  ruling (`test_strikeAfterSeasonEndForfeitsThePrize`, reviewer proof `Proof_19f1179b7c87`).
- **Block timestamp** is used only for windows and deadlines, never for randomness; a validator can
  shift a window edge by seconds at most.

## 4. Griefing of objections and appeals

- **Objection spam.** One objection per sale, never by the seller, and a 1 IMD bond that is forfeited
  to the pot when 17 judges dismiss it. Upheld or unruled (48h) objections return the bond as a
  claimable credit. Griefing cost is therefore bounded by the bond, and the seller's only exposure is a
  7-day plea ban if 17 judges uphold, which the objector cannot cause alone. A seller's second wallet
  can still take the single slot; that does not shield the sale, because the judges rule on the sale,
  not the objector, and the bond returns to the objector either way. Rulings stop at 48 hours, so an
  objector cannot reclaim ahead of a ruling in progress, and a ruling cannot land after a reclaim.
- **Appeal and re-hearing spam.** One re-hearing per denial, by the seller only, after 4 hours: an
  appeal (round 2, fresh votes) or a replacement plea, which the court marks as the re-hearing. A second
  denial puts the seller on a 24-hour cooldown. Withdrawing a denied plea no longer resets any of this
  (`test_deniedSellerGetsOneRehearingThenACooldown`).
- **Bans.** An upheld objection bans the seller for 7 days from pleading, from selling (checked in
  `authorizeSale`) and from appealing, and strikes whatever plea they have in flight, so an open window,
  a pending plea or an appealable denial cannot outlive the ban
  (`test_upheldObjectionStrikesTheOpenWindowAndBlocksSales` and the two tests after it).
- **Plea spam to trip the dead-man switch.** Anyone can keep one plea pending per address. The switch
  measures the Cabal's silence, not the plea backlog: a single verdict anywhere restarts the clock
  (`test_verdictRestartsTheTimer`). A pending plea cannot be withdrawn once a judge has scored it, so
  sellers cannot starve the Cabal of verdicts by withdrawing before the 17th vote while keeping
  overlapping pleas pending (`test_withdrawRefusedOnceVotesAreCast`, reviewer proof
  `Proof_33477e169a57`); and a Cabal that votes in full always produces a verdict (hung rule above). A
  Cabal that scores nothing for 33 hours is, by the brief, the switch's case.
- **Leaderboard squatting.** The board is capped at 50 (25 winners and a bench of 25) and updated in
  O(50); points come only from approved medians, so entries cost real approvals. `_strike` after an
  upheld objection removes the seller's season points and board entry, and the bench entry behind them
  becomes the 25th winner (`test_strikePromotesTheBench`). Beyond 25 strikes in one season a place may
  go unfilled (documented bound).
- **Post-switch pot.** After the dead-man switch `hook.sell` takes no pot fee, and every `endSeason`
  credits what the board does not take to the hook's owner, so no IMD is stranded
  (`test_freeSellsPayNoFeeAndThePotGoesToTheOwner`).
- **Plea text size.** Capped at 1000 bytes; the submitter pays its storage.

## 5. Checklist items

- Every callback and `unlockCallback` check `msg.sender == poolManager` (`test_callbacksRefuseNonManager`
  and the pinned floor test).
- No return deltas, so no NoOp surface and the delta sum in `unlockCallback` is settled in full:
  PLEA settled by sync/transfer/settle, IMD taken in full (fee + net).
- `transferFrom` only from `msg.sender` (`sell`, `object`); SafeERC20 everywhere; no infinite approvals
  made by the contracts; no `selfdestruct`, `delegatecall`, upgrade path or initializer; no
  `abi.encodePacked` of two dynamic values (the letterbox hashes `text` first and uses `abi.encode`).
- Constructor calls no external contract and takes four one-word arguments; `Ownable(owner_)` is the
  manifest's `$owner`, never `msg.sender`/`tx.origin`.
- Library functions are all `internal` (`HookFlags`, OZ, v4-core), so the bytecode has no link
  placeholders.
- Bytecode: hook runtime 10.0 KB, court 20.7 KB, letterbox 3.3 KB, token 1.7 KB, each under EIP-170.
  Hook initcode (which carries the court and letterbox) 36.6 KB, under EIP-3860's 49 KB.

## 6. Independent review (revision 2)

An independent reviewer reported 8 defects, 6 low findings and 3 notes against the first release; all
are answered in `.imd-responses.json`. The 8 defects (hung Cabal, mid-vote withdrawal, strikes after
the season end, the clock before the Cabal, the withdraw-and-resubmit re-hearing, bans not enforced
on sales and appeals, no promotion after a strike, the post-switch pot) are fixed as described above.
Of the low findings, partial fills, self-objection and reclaim precedence, the liquidity allowlist
documentation, letterbox nonce cancellation, recusal and the error name are fixed; "points without a
sale" is kept by design (the reviewer's own proof asserts points at approval) and documented in the
README's limitations.

## 7. Open items before release

1. Independent review of this revision (the reviewer who raised the findings answers the responses).
2. A timelock or multisig as `$owner` (judge replacement and the pot fee are owner powers, and the
   panel is the owner's way to end the gate).
3. Fork rehearsal against mainnet IMD: confirm IMD is a plain ERC-20 that `PoolManager.take` can
   deliver to a wallet, and that the factory adds liquidity as `sender` itself (else allowlist its
   position manager with `setLiquidityProvider`).
4. The requester's choices: the pot fee rate (0 until set), the season length, the objection bond,
   whether the dead-man clock should be per plea rather than per Cabal silence.
5. Slither/Mythril were not run here (not available on this machine); the six verifier detectors were
   written around as listed above.
