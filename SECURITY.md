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
| Router passes the approved seller's address in `hookData` | Ignored. Identity is never read from `hookData`; only the hook's own `sell` (sender = hook, transient `_selling` set) passes (`test_sellThroughRouterRevertsEvenWithApprovedPlea`). |
| Make the hook the `sender` without `sell` | `poolManager.swap` is only called from `unlockCallback`, which only the PoolManager calls, only during an unlock the hook itself started in `sell`. The transient flag is set and cleared around that unlock; a nested call cannot set it. `sell` is `nonReentrant`. |
| Single-sided PLEA liquidity above the price, then withdraw IMD after buyers take it | `beforeAddLiquidity` admits only the factory, owner-allowlisted providers, or anyone after the dead-man switch (`test_strangerCannotAddLiquidity`). Removal is never gated, so nothing can be trapped and the factory's fee collect (a zero-liquidity modify) passes untouched (`test_factoryCollectsFeesWithZeroLiquidityChange`). |
| Donate to the pool / use `beforeDonate` | Not enabled; donations do not move PLEA out to anyone. |
| Sell more than approved, or after the 7 minutes, or from another wallet's window | Court checks `Approved`, `now <= windowExpiry`, `sold + amount <= amount`, keyed by `msg.sender` of `sell` (tests `test_sellMoreThanApprovedReverts`, `test_sellAfterWindowReverts`, `test_sellByOtherSellerWindowReverts`). |
| Sell on another venue | **Open by design.** The token is standard, as the launch requires; a v2/v3 pool or an OTC trade is outside this hook. The gate protects this pool's IMD only. Documented in README. |
| Open a second pool on this hook with the same token and no gate | `beforeInitialize` binds once and only from the factory (`test_initialize_secondPoolReverts`, `test_initialize_fromStrangerReverts`). A pool on a different hook is the previous row. |

## 2. Oracle (Cabal) manipulation

- **Who decides.** 17 of 30 judges on one side settle a plea or an objection. The judges are trusted
  oracles the owner installs; a majority can approve anything or deny everything. That is the brief's
  model. A single compromised key can only cast one vote per plea per round (`hasScored`), and one per
  objection (`hasRuled`).
- **Fact points are per judge.** A judge who credits 71 fact points approves any score; this is the
  judge's own vote and counts once. Sellers cannot self-declare facts.
- **Seat multiplier.** Owner-granted; it scales only the judge's score of that seller, capped at 54,
  so a seat alone (54 < 71) never approves without fact points.
- **Replacing the panel mid-plea.** `setJudges` drops old judges' rights but not their cast votes, and
  new judges may vote in the same round. The owner could stack a verdict this way. Mitigation: the owner
  is the requester's address; this is a disclosed owner power, not an anonymous one. A timelock on the
  owner is recommended before launch (open item).
- **Owner cannot** block buys, block the factory, touch pot IMD, move tokens, or end the gate early.
  The owner also cannot stop the dead-man switch: 33 silent hours free trading whatever the owner does.
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
  that could move it (`judge`, `appeal`, `withdrawPlea`, `authorizeSale`, `_submit`) first latches
  `deadManTriggered` when due, so a late verdict or the withdrawal of the last pending plea cannot
  un-free trading (`test_deadManIsPermanentEvenIfTheCabalWakesUp`, `test_noTimerWithoutPendingPlea`).
  `beforeSwap` reads `tradesFreely()` as a view, which is consistent with the latch.
- **Window edges.** The sale window is inclusive of `windowExpiry` (`test_sellAtWindowEdgeSucceeds`);
  the objection window is inclusive of `executedAt + 20 min`; the appeal is allowed at exactly
  `decidedAt + 4h`. A verdict and the sale can land in the same block; objections open from the sale's
  block.
- **Season end.** `endSeason` is permissionless and uses the court's balance at that moment, so a
  last-second IMD transfer to the court raises the pot (a donation, not a theft). Prizes are credited,
  never pushed, so a recipient that cannot receive IMD cannot block the season end.
- **Block timestamp** is used only for windows and deadlines, never for randomness; a validator can
  shift a window edge by seconds at most.

## 4. Griefing of objections and appeals

- **Objection spam.** One objection per sale, and a 1 IMD bond that is forfeited to the pot when 17
  judges dismiss it. Upheld or unruled (48h) objections return the bond as a claimable credit. Griefing
  cost is therefore bounded by the bond, and the seller's only exposure is a 7-day plea ban if 17 judges
  uphold, which the objector cannot cause alone.
- **Appeal spam.** One appeal per plea, by the seller only, after 4 hours; round 2 resets votes. A seller
  cannot keep a plea pending to run the dead-man clock any more than a fresh plea would, and withdrawing
  a pending plea resets the timer when nothing else is pending.
- **Plea spam to trip the dead-man switch.** Anyone can keep one plea pending per address. The switch
  measures the Cabal's silence, not the plea backlog: a single verdict anywhere restarts the clock
  (`test_verdictRestartsTheTimer`). A Cabal that judges at all is never tripped by spam.
- **Leaderboard squatting.** The board is capped at 25 and updated in O(25); points come only from
  approved medians, so entries cost real approvals. `_strike` after an upheld objection removes the
  seller's season points and board entry.
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
- Bytecode: hook runtime 9.9 KB, court 17.2 KB, letterbox 3.2 KB, token 1.7 KB, each under EIP-170.
  Hook initcode (which carries the court and letterbox) 32.9 KB, under EIP-3860's 49 KB.

## 6. Open items before release

1. Independent review by another contributor (this file is the author's own adversarial pass).
2. A timelock or multisig as `$owner` (judge replacement and the pot fee are owner powers).
3. Fork rehearsal against mainnet IMD: confirm IMD is a plain ERC-20 that `PoolManager.take` can
   deliver to a wallet, and that the factory adds liquidity as `sender` itself (else allowlist its
   position manager with `setLiquidityProvider`).
4. The requester's choices: the pot fee rate (0 until set), the season length, the objection bond,
   whether the dead-man clock should be per plea rather than per Cabal silence.
5. Slither/Mythril were not run here (not available on this machine); the six verifier detectors were
   written around as listed above.
