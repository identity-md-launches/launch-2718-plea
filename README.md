# PLEA ($PLEA) — a Uniswap v4 launch where selling takes a plea

X: [@plea_imd](https://x.com/plea_imd). Chain: Ethereum (chain id 1). Pair: IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals). Pool: LP fee 12500 (1.25%), tick spacing 60.

Buying PLEA is always open. Selling PLEA into the pool needs an approved plea judged by the Cabal, a
panel of 30 IMD oracle judges. If the Cabal goes silent for 33 hours while a plea waits, PLEA trades
freely forever.

## Contracts

| Contract | File | Deployed by |
| --- | --- | --- |
| `PLEAToken` | `src/PLEAToken.sol` | the launch factory (the launch token) |
| `PleaHook` | `src/PleaHook.sol` | the launch factory (the hook) |
| `PleaCourt` | `src/PleaCourt.sol` | `PleaHook`'s constructor; `hook.court()` |
| `Letterbox` | `src/Letterbox.sol` | `PleaCourt`'s constructor; `court.letterbox()` / `hook.letterbox()` |
| `HookFlags` | `src/HookFlags.sol` | internal library of hook address bits (used by tests) |

### PLEAToken

Standard fixed-supply ERC-20 (OpenZeppelin v5.4). Name `PLEA`, symbol `PLEA`, 18 decimals,
1,000,000,000 tokens (10^27 minor units) minted once to the deployer, the launch factory. No owner,
mint, pause, blocklist, fee or upgrade. Everything the brief asks about selling lives in the hook, not
the token: a plain transfer of PLEA between wallets is never gated, and selling PLEA anywhere other
than this hook's pool is not something a standard token can stop (see Limitations).

### PleaHook

Constructor: `(IPoolManager poolManager, address token, address owner, address factory)`, written in
the manifest as `$poolManager`, `$token`, `$owner`, `$factory`. The constructor stores them, creates
the court and validates its own address bits. It calls no other contract.

Permissions (the Wizard's canonical shape, all other flags false):

```json
{ "hook": "BaseHook", "name": "PleaHook", "pausable": false, "currencySettler": false,
  "safeCast": false, "transientStorage": false, "shares": { "options": false },
  "permissions": { "beforeInitialize": true, "beforeAddLiquidity": true, "beforeSwap": true },
  "access": "ownable", "info": { "license": "MIT" } }
```

Address flags: `BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP` = `0x2880` (bits 13, 11, 7).
Mine the deployment salt for these bits.

- `beforeInitialize` (added because every IMD launch needs an initialize callback): only the launch
  factory may open the pool, once, and the pool must contain the launch token. The other currency is
  recorded as the pair (IMD) and handed to the court. Any LP fee and tick spacing are accepted.
- `beforeAddLiquidity`: only the factory, owner-allowlisted providers, or anyone once trading is free.
  Without it, anyone could place single-sided PLEA liquidity above the price and collect IMD as buyers
  took it, which is a sell without a plea. The callback sees the contract that calls `modifyLiquidity`,
  not the end LP, so the allowlist is for parties whose positions are their own, never a shared position
  manager (see After launch). No remove-liquidity callbacks exist, so the factory's fee collect (a
  zero-liquidity modify) is never touched or taxed.
- `beforeSwap`: a buy (IMD in, PLEA out) always passes, exact input or exact output, from any router.
  Every sell that reaches the callback is refused with `SellRequiresPlea` until trading is free. The
  hook's own `sell` never reaches it: v4-core skips a hook's callbacks for swaps the hook itself
  initiates (`Hooks.noSelfCall`), so the only sell route is the hook's `sell`, which the court gates.
  No swap deltas are returned (no NoOp surface).

`sell(amountIn, minOut)` is the sell route: it asks the court to reserve `amountIn` of the caller's
approved window, pulls the PLEA from `msg.sender`, swaps exact input inside its own unlock, sends the pot
fee (if any) to the court and the rest of the IMD straight to the seller via `take`, then settles the
reservation to what the pool consumed (`court.settleSale`). If the pool ran dry the unconsumed PLEA is
refunded, only the consumed part is charged to the window and recorded as the sale, and the window stays
open for the rest. `minOut` is the seller's slippage bound. After the dead-man switch `sell` needs no
plea and takes no pot fee.

Owner functions (owner = `$owner`, `0xd6302976e590b9b947da8774b7f1246164e0ce98`): `setPotFeeBps`
(max 1000 = 10%), `setLiquidityProvider`. The owner can never block a buy, block the factory's
liquidity or fee collect, or move anyone's tokens.

### PleaCourt

- **Pleas.** `submitPlea(text, amount)` (or the letterbox) records the text on chain, the PLEA amount
  the seller wants to sell, and opens round 1. One in-flight plea per seller. Refused until the Cabal is
  installed (`CabalNotConfigured`), while the seller is banned, and before the seller's `nextPleaAt`
  after a denial.
- **The Cabal.** `setJudges(address[30])` installs exactly 30 distinct judges. A judge calls
  `judge(pleaId, score, factPoints)`: `score` 0–45, `factPoints` 0–71 (the verifiable facts the judge
  credits, each lowering the bar by one from 71). Seat holders' scores are multiplied by 1.2. The judge's
  vote is an approval when `scaledScore + factPoints >= 71`. As soon as 17 judges share a side, the
  median of the Cabal's scores is settled whatever the other 13 say, so the verdict is final: `Verdict`
  is emitted with the median of the scores given so far. When all 30 have voted and neither side has 17
  (a hung Cabal), the plea is denied with that median: approval needs 17 to agree, and the seller may
  appeal. A judge cannot score their own plea (`Recused`).
- **Approved:** a 7-minute sale window for up to the plea's amount, through `hook.sell`. Selling it all
  or `closeWindow` after expiry closes the plea and frees the seller to plead again. The median score is
  added to the seller's season points, and the plea records the season they went to.
- **Denied:** one re-hearing, 4 hours after the denial: either `appeal`, which opens round 2 of the same
  plea with fresh votes, or (after withdrawing the denied plea) a replacement plea, which the court
  marks as the re-hearing so it cannot be appealed in turn. A re-hearing that is denied too puts the
  seller on a 24-hour cooldown (`DENIAL_COOLDOWN`) before any new plea. `nextPleaAt(seller)` and
  `rehearingOwed(seller)` show where a seller stands.
- **Withdrawal.** A pending plea can be withdrawn only while no judge has scored its current round: once
  the Cabal is judging, its verdict is owed (`VotesCast`). A denied plea can always be withdrawn, which
  forfeits the appeal but not the cooldown.
- **Objections.** `object(saleId)` by anyone but the seller within 20 minutes of a sale, posting a 1 IMD
  bond. Judges rule within 48 hours (`ruleObjection`; the seller and the objector are recused). 17
  upholds: the seller is banned from pleading for 7 days, whatever plea they have in flight is struck
  (`Struck`, its window closed), their points of the sale's season are voided (or, if that season has
  already ended, the prize it earned them is forfeited back into the pot), and the bond is credited back.
  17 dismissals forfeit the bond to the prize pot. Once the 48 hours pass no judge can rule and the
  objector reclaims the bond.
- **Seasons.** 30 days each from deployment. The board keeps the top 50 by season points
  (`BOARD_CAPACITY`): the top 25 are the winners (`leaderboard()`), the next 25 a bench that moves up
  when a winner is struck (`fullBoard()` shows both). `endSeason()` (anyone, after the season ends)
  splits the prize pot pro rata to points among the top 25 as prize credits (`prizeCredit(season,
  addr)`), resets the board and starts the next season. Prizes unlock 3 days after the season end
  (`PRIZE_LOCK`, `prizeUnlockAt(season)`), after every objection to that season's sales has been ruled;
  `claimPrize(season)` then pays them. The pot is every IMD the court holds that is not a pending bond
  or an unpaid credit: pot fees from gated sales, forfeited bonds and anything anyone transfers to the
  court. An empty board rolls the pot over, except after the dead-man switch (below).
- **Dead-man switch.** While at least one plea is pending, a deadline runs 33 hours from the later of
  "a plea became pending with none before it" and "the last verdict". Past it, `tradesFreely()` is
  true: the hook lets every sell and every liquidity add through, and no state change can reverse it
  (the first state-changing call latches `deadManTriggered` and emits `DeadManSwitchTriggered`;
  `triggerDeadManSwitch()` does so on demand). Pleas, judging and appeals then refuse with `FreeTrading`.
  No plea can be submitted before the Cabal is installed, so the clock cannot start on a panel that
  does not exist. After the switch nobody can earn points again: the next `endSeason` pays the board as
  usual, and whatever the board does not take, then and in every later season, is credited to the hook's
  owner (`PotSwept`, paid by `claim()`), so no IMD is stranded in the court.

Views for the frontend (on the hook, proxied to the court): `pleaStatus(id)`, `saleWindowExpiry(seller)`
(expiry and remaining amount), `currentSeason()`, `leaderboard()` (sorted top 25), `deadManTimer()`
(deadline, seconds left, fired), `tradesFreely()`. On the court also `plea(id)`, `pleaText(id)`,
`scores(id, round)`, `sale(id)`, `objection(id)`, `judges()`, `fullBoard()`, `prizePot()`,
`prizeCredit(season, addr)`, `prizeUnlockAt(season)`, `claimable(addr)`, `seasonPoints(season, addr)`,
`nextPleaAt(addr)`, `rehearingOwed(addr)`, `bannedUntil(addr)`, `requiredScore(factPoints)`,
`effectiveScore(seller, score)`.

Events: `PleaSubmitted`, `JudgeScored`, `Verdict`, `PleaAppealed`, `PleaWithdrawn`, `PleaStruck`,
`SaleWindowOpened`, `SaleWindowClosed`, `SaleRecorded`, `ObjectionRaised`, `ObjectionRuled`,
`ObjectionResolved`, `SellerBanned`, `PointsAwarded`, `SeasonEnded`, `PrizeAwarded`, `PrizeForfeited`,
`PrizeClaimed`, `PotSwept`, `Claimed`, `DeadManSwitchTriggered`, `JudgesSet`, `SeatSet`, `Bound`; on
the hook `PoolBound`, `SellExecuted`, `PotFeeSet`, `LiquidityProviderSet`; on the letterbox `Posted`,
`NonceInvalidated`.

### Letterbox

`post(text, amount)` submits the caller's own plea. `postSigned(seller, text, amount, deadline, sig)`
lets anyone (a relayer paying gas) post a plea the seller signed (EIP-712, domain `PLEA Letterbox`
v1, per-seller nonce, deadline). `invalidateNonce()` spends the caller's current nonce, cancelling any
plea they signed with it. The court accepts `submitPleaFor` only from the letterbox.

## Fees

- The pool's LP fee is 1.25% (`pool.fee` 12500), accrued in both currencies to the factory's position
  and collected by the factory for the payer and the network. The hook neither overrides nor taxes it.
- "Fees in IMD": the hook's own fee is the **pot fee**, a share of the IMD proceeds of every gated sale
  that funds the season prize pot. It stays in IMD (the brief asks for IMD, so it is not converted to
  ETH), is taken from the pair side only, and is sent to the court inside the same swap. Buys pay no hook
  fee, and sells after the dead-man switch pay none either, through `hook.sell` or any router. The brief
  names no rate, so `potFeeBps` starts at **0** and the owner sets it (max 10%); until set, the pot is
  funded by forfeited objection bonds and direct IMD transfers to the court.

## Chosen constants (the brief left these open)

| Constant | Value | Where |
| --- | --- | --- |
| `SEASON_LENGTH` | 30 days | PleaCourt |
| `OBJECTION_BOND` | 1 IMD | PleaCourt |
| `OBJECTION_RULING_PERIOD` | 48 hours | PleaCourt |
| `OBJECTION_BAN` | 7 days | PleaCourt |
| `MAX_PLEA_BYTES` | 1000 | PleaCourt |
| `MAX_FACT_POINTS` | 71 (one point lowers the bar by one) | PleaCourt |
| `DENIAL_COOLDOWN` | 24 hours before a new plea after a failed re-hearing | PleaCourt |
| `PRIZE_LOCK` | 3 days from season end to prize unlock (covers 7 min + 20 min + 48 h of objections) | PleaCourt |
| `BOARD_CAPACITY` | 50 (top 25 winners plus a bench of 25) | PleaCourt |
| `MAX_POT_FEE_BPS` | 1000 (10%) | PleaHook |

Fixed by the brief: 30 judges, 17 to agree, scores 0–45, bar 71 − fact points, 1.2× for seat holders,
7-minute window, 4-hour appeal delay, 20-minute objection window, 33-hour dead-man period, top 25.

## Deployment (the launch)

IMD's factory deploys both contracts; nothing here deploys, signs or broadcasts.

| Contract | Constructor arguments |
| --- | --- |
| `PLEAToken` | none |
| `PleaHook` | `$poolManager`, `$token`, `$owner`, `$factory` |

The hook's address must carry flags `0x2880`. The factory opens the PLEA/IMD pool itself, which binds
the hook (`PoolBound`) and the court (`Bound`); the hook refuses any other pool and any other opener.

## After launch (owner responsibilities)

1. **`court.setJudges(address[30])`** — the Cabal. These are IMD's oracle judge addresses, which only
   the requester / IMD can supply; nothing is pre-filled. Until set, nobody can plead or judge, so the
   33-hour dead-man clock cannot start before the panel exists; it starts with the first plea after.
   Replacing the panel drops the old judges; votes already cast stand (see SECURITY.md on owner trust).
2. **`court.setSeat(address, bool)`** — seat holders (1.2× multiplier). The brief does not say how seats
   are earned, so they are owner-granted.
3. **`hook.setPotFeeBps(uint16)`** — the pot fee on gated sale proceeds, 0 until set, at most 1000.
4. **`hook.setLiquidityProvider(address, bool)`** — only for a wallet or a contract whose positions are
   its own (the factory itself is always allowed). **Never allowlist a shared position manager or
   router**: the callback sees the calling contract, so through a shared one any PLEA holder could add
   single-sided PLEA liquidity above the price, let buyers fill it and withdraw IMD, a sell with no plea.
5. **Operations:** judges must keep ruling (every verdict restarts the dead-man clock; a hung Cabal
   still counts as a verdict once all 30 have voted); anyone may call `closeWindow`, `endSeason`,
   `triggerDeadManSwitch`; winners call `claimPrize(season)` once the prize lock has passed, objectors
   call `claim()`. After the dead-man switch the owner calls `claim()` for the swept pot.

## Assumptions

- The launch factory is the `sender` of `PoolManager.initialize` and of its own `modifyLiquidity`
  calls, as in the floor tests' probe. Its fee collect is a zero-liquidity modify, which this hook does
  not intercept.
- IMD is a plain 18-decimal ERC-20 whose transfers the PoolManager can `take` to a wallet. The hook never
  holds IMD; the court holds the pot.
- Judges are trusted oracles run by IMD. 17 colluding or compromised judges decide any plea or objection;
  that is the brief's trust model, not something the contracts can remove.
- The opening price is the deployer's; the hook does not check it.

## Limitations the brief should know about

- A standard token cannot stop PLEA being sold on another venue (a v2/v3 pool, a hookless v4 pool, an
  OTC trade). The gate is on this pool. Liquidity for this pool can only be seeded by the factory and
  allowlisted providers, which closes the single-sided-LP bypass here.
- The sale window authorises an amount per plea, not a price. The seller chooses `minOut`.
- `judge()` stores one vote per judge per round; the median emitted is of the votes cast when 17 agreed
  (or of all 30 when the Cabal hung).
- Season points are awarded at approval, as the brief's leaderboard is of judged pleas, so an approved
  plea that is never sold still earns its median; the only check on that is the Cabal's own judgment of
  a plea from a wallet that holds no PLEA (the amount is on chain). Points are voided only through an
  objection to a sale.
- The bench holds 25 entries, so the board is exact for up to 25 struck winners per season; beyond that
  a struck winner's place may go unfilled.
- Gas: a 1000-byte plea text costs the submitter roughly 700k gas to store.

## Security review

See `SECURITY.md` for the adversarial review (sell-gate bypass, oracle manipulation, timing and
reentrancy, griefing of objections and appeals), the Slither write-arounds, and open items.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
`optimizer_runs = 200`, `via_ir = false` (via-IR folds `block.timestamp` across `vm.warp`s in tests).
Dependencies are vendored as plain files under `lib/`: forge-std 1.17.0, v4-core `bea7f6d`,
OpenZeppelin Contracts 5.4.0, solmate `Owned` (needed by v4-core's `ProtocolFees`). No submodules,
no ffi, no fs permissions. Tests read no environment variables and run in any order.

The suite (89 tests) covers: token supply and transfers; hook permissions, binding, refusal of other
openers and pools, callbacks from non-managers; buys from any router (exact input, exact output,
fuzzed); sells refused from routers with or without a plea and from the hook without, while pending,
after the window, over the amount, under `minOut`, by another seller, while banned; partial fills; the
full plea → verdict → window → sale → objection lifecycle with events; hung-Cabal verdicts; appeals
(too early, once only, round 2), the replacement-plea re-hearing and the denial cooldown, withdrawal
(refused once scored) and window closing; objections upheld (striking the open window, a pending or a
denied plea, an ended season's prize, promoting the bench), dismissed, unruled, self-objection,
recusal, the ruling deadline; seasons (too early, pro-rata split, the prize lock and `claimPrize`,
empty rollover, top-25 of 50); the dead-man switch (timer, restart on verdict, permanence, no plea
before the Cabal, fee-free sells and liquidity afterwards, the pot sweep to the owner); the letterbox
(direct, signed, replay, forgery, expiry, nonce invalidation); the factory's zero-liquidity fee collect
with the hook live; a fuzz of the judge's vote side against the bar.
