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
  "safeCast": false, "transientStorage": true, "shares": { "options": false },
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
  took it, which is a sell without a plea. No remove-liquidity callbacks exist, so the factory's fee
  collect (a zero-liquidity modify) is never touched or taxed.
- `beforeSwap`: a buy (IMD in, PLEA out) always passes, exact input or exact output, from any router.
  A sell passes only when the sender is the hook itself inside its own `sell`, or when trading is free.
  Any other seller gets `SellRequiresPlea`. No swap deltas are returned (no NoOp surface).

`sell(amountIn, minOut)` is the sell route: it asks the court to spend the caller's approved window,
pulls the PLEA from `msg.sender`, swaps exact input inside its own unlock, sends the pot fee (if any) to
the court and the rest of the IMD straight to the seller via `take`. Unconsumed PLEA (only if the pool
runs dry) is refunded. `minOut` is the seller's slippage bound.

Owner functions (owner = `$owner`, `0xd6302976e590b9b947da8774b7f1246164e0ce98`): `setPotFeeBps`
(max 1000 = 10%), `setLiquidityProvider`. The owner can never block a buy, block the factory's
liquidity or fee collect, or move anyone's tokens.

### PleaCourt

- **Pleas.** `submitPlea(text, amount)` (or the letterbox) records the text on chain, the PLEA amount
  the seller wants to sell, and opens round 1. One in-flight plea per seller. Banned sellers are refused.
- **The Cabal.** `setJudges(address[30])` installs exactly 30 distinct judges. A judge calls
  `judge(pleaId, score, factPoints)`: `score` 0–45, `factPoints` 0–71 (the verifiable facts the judge
  credits, each lowering the bar by one from 71). Seat holders' scores are multiplied by 1.2. The judge's
  vote is an approval when `scaledScore + factPoints >= 71`. As soon as 17 judges share a side, the
  median of the Cabal's scores is settled whatever the other 13 say, so the verdict is final: `Verdict`
  is emitted with the median of the scores given so far.
- **Approved:** a 7-minute sale window for up to the plea's amount, through `hook.sell`. Selling it all
  or `closeWindow` after expiry closes the plea and frees the seller to plead again. The median score is
  added to the seller's season points.
- **Denied:** one `appeal` by the seller, 4 hours after the denial, opens round 2 with fresh votes. A
  denied plea blocks a new one until it is appealed or withdrawn.
- **Objections.** `object(saleId)` by anyone within 20 minutes of a sale, posting a 1 IMD bond. 17
  judges `ruleObjection(id, true)` uphold it: the seller is banned from pleading for 7 days, their
  season points are voided, the bond is credited back. 17 dismissals forfeit the bond to the prize pot.
  Unruled after 48 hours, the objector reclaims the bond.
- **Seasons.** 30 days each from deployment. The leaderboard keeps the top 25 by season points.
  `endSeason()` (anyone, after the season ends) splits the prize pot pro rata to points as claimable IMD
  (`claim()` pulls it), resets the board and starts the next season. The pot is every IMD the court
  holds that is not a pending bond or an unclaimed credit: pot fees from gated sales, forfeited bonds
  and anything anyone transfers to the court. An empty board rolls the pot over.
- **Dead-man switch.** While at least one plea is pending, a deadline runs 33 hours from the later of
  "a plea became pending with none before it" and "the last verdict". Past it, `tradesFreely()` is
  true: the hook lets every sell and every liquidity add through, and no state change can reverse it
  (the first state-changing call latches `deadManTriggered` and emits `DeadManSwitchTriggered`;
  `triggerDeadManSwitch()` does so on demand). Pleas, judging and appeals then refuse with `FreeTrading`.

Views for the frontend (on the hook, proxied to the court): `pleaStatus(id)`, `saleWindowExpiry(seller)`
(expiry and remaining amount), `currentSeason()`, `leaderboard()` (sorted), `deadManTimer()`
(deadline, seconds left, fired), `tradesFreely()`. On the court also `plea(id)`, `pleaText(id)`,
`scores(id, round)`, `sale(id)`, `objection(id)`, `judges()`, `prizePot()`, `claimable(addr)`,
`seasonPoints(season, addr)`, `requiredScore(factPoints)`, `effectiveScore(seller, score)`.

Events: `PleaSubmitted`, `JudgeScored`, `Verdict`, `PleaAppealed`, `PleaWithdrawn`, `SaleWindowOpened`,
`SaleWindowClosed`, `SaleRecorded`, `ObjectionRaised`, `ObjectionRuled`, `ObjectionResolved`,
`SellerBanned`, `PointsAwarded`, `SeasonEnded`, `PrizeAwarded`, `Claimed`, `DeadManSwitchTriggered`,
`JudgesSet`, `SeatSet`, `Bound`; on the hook `PoolBound`, `SellExecuted`, `PotFeeSet`,
`LiquidityProviderSet`; on the letterbox `Posted`.

### Letterbox

`post(text, amount)` submits the caller's own plea. `postSigned(seller, text, amount, deadline, sig)`
lets anyone (a relayer paying gas) post a plea the seller signed (EIP-712, domain `PLEA Letterbox`
v1, per-seller nonce, deadline). The court accepts `submitPleaFor` only from the letterbox.

## Fees

- The pool's LP fee is 1.25% (`pool.fee` 12500), accrued in both currencies to the factory's position
  and collected by the factory for the payer and the network. The hook neither overrides nor taxes it.
- "Fees in IMD": the hook's own fee is the **pot fee**, a share of the IMD proceeds of every gated sale
  that funds the season prize pot. It stays in IMD (the brief asks for IMD, so it is not converted to
  ETH), is taken from the pair side only, and is sent to the court inside the same swap. Buys pay no hook
  fee, and sells after the dead-man switch through other routers pay none either. The brief names no
  rate, so `potFeeBps` starts at **0** and the owner sets it (max 10%); until set, the pot is funded by
  forfeited objection bonds and direct IMD transfers to the court.

## Chosen constants (the brief left these open)

| Constant | Value | Where |
| --- | --- | --- |
| `SEASON_LENGTH` | 30 days | PleaCourt |
| `OBJECTION_BOND` | 1 IMD | PleaCourt |
| `OBJECTION_RULING_PERIOD` | 48 hours | PleaCourt |
| `OBJECTION_BAN` | 7 days | PleaCourt |
| `MAX_PLEA_BYTES` | 1000 | PleaCourt |
| `MAX_FACT_POINTS` | 71 (one point lowers the bar by one) | PleaCourt |
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
   the requester / IMD can supply; nothing is pre-filled. Until set, nobody can judge, and the 33-hour
   dead-man clock starts with the first plea: set the judges before the first plea or within 33 hours
   of it, or PLEA trades freely forever. Replacing the panel drops the old judges; votes already cast
   stand.
2. **`court.setSeat(address, bool)`** — seat holders (1.2× multiplier). The brief does not say how seats
   are earned, so they are owner-granted.
3. **`hook.setPotFeeBps(uint16)`** — the pot fee on gated sale proceeds, 0 until set, at most 1000.
4. **`hook.setLiquidityProvider(address, bool)`** — if the launch factory adds liquidity through a
   position manager rather than directly, allowlist that contract; the factory itself is always allowed.
5. **Operations:** judges must keep ruling (every verdict restarts the dead-man clock); anyone may call
   `closeWindow`, `endSeason`, `triggerDeadManSwitch`; winners and objectors call `claim()`.

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
- `judge()` stores one vote per judge per round; the median emitted is of the votes cast when 17 agreed.
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

The suite (66 tests) covers: token supply and transfers; hook permissions, binding, refusal of other
openers and pools, callbacks from non-managers; buys from any router (exact input, exact output,
fuzzed); sells refused from routers with or without a plea and from the hook without, while pending,
after the window, over the amount, under `minOut`, by another seller; the full plea → verdict → window
→ sale → objection lifecycle with events; appeals (too early, once only, round 2), withdrawal and window
closing; objections upheld, dismissed and unruled; seasons (too early, pro-rata split, claims, empty
rollover, top-25 cap); the dead-man switch (timer, restart on verdict, permanence, free sells and
liquidity afterwards); the letterbox (direct, signed, replay, forgery, expiry); the factory's
zero-liquidity fee collect with the hook live; a fuzz of the judge's vote side against the bar.
