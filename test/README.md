# PLEA adversarial test additions

The original implementation and tests are unchanged. These additions test the court, signed plea intake, and real local Uniswap v4 swaps. They need only the already vendored dependencies; they use no RPC, environment-changing cheatcodes, ffi, network downloads, or files under `test/scratch/`.

Two implementation defects are reported in `.imd-findings.json`, each with the full source of an independently runnable failing Foundry test. Those proofs were run against the current implementation before being embedded in the report. Their expected failures are not assertions blessing the defective behavior in the passing suite:

- **Medium — missing leaderboard promotion:** with 26 scored sellers, upholding an objection against a listed winner leaves 24 entries despite 25 eligible sellers. The omitted seller receives no season prize.
- **Medium — partial-fill sale accounting:** a request for 1 PLEA consumes only `3042383861004483` wei in the proof's narrow-range pool, but the court records 1 PLEA sold and closes the window. Refunding tokens does not restore the remaining allowance.

## Test inventory

| File | Coverage |
| --- | --- |
| `PleaCourtAdversarial.t.sol` | Input/type boundaries, ownership changes, invalid votes without state effects, odd/even and seat score rounding, quorum split and dead-man timing, appeal/window boundaries, objection failures and deadlines, prize rounding with bonds and prior claims reserved |
| `LetterboxAdversarial.t.sol` | Mutations of every signed field, deadline equality, chain/address domain separation, malformed and high-s signatures, nonce rollback on court failure, retry and replay protection |
| `PleaHookAdversarial.t.sol` | Both PLEA currency orderings; exact input/output sell-gate spoofing, allowance/slippage rollback, fee rounding and multiple sales, donated balances, fresh token-only liquidity, empty liquidity with a positive minimum output, revoked LP withdrawals and fee collection, ownership and buy liveness |
| `PleaExternalCalls.t.sol` | Reentrant sale during pair-token output, reentrant claim, failed claim transfer preserving credit, false-returning bond transfers preserving sale eligibility |
| `PleaCourtInvariant.t.sol` | Random court actions with six actors, independent expected balances/credits/points, vote histogram median oracle, pending and active state, bonds, claims and season settlement |
| `PleaHookInvariant.t.sol` | Real PoolManager random sequences, both currency orderings, separate campaigns keeping the gate active and allowing dead-man activation, fixed token supply, conservation of both tokens, fees, donations, settlement and rejected-swap rollback |

Fuzz tests added here use 1,000 runs. Each invariant campaign uses 256 runs at depth 64, with `fail-on-revert = true`, set inline in the test source. Only selected handler functions are targets. Expected failures are checked explicitly; unexpected reverts fail the campaign. Fixtures seed reachable votes, sales, bonds, fees and claims, so zero activity cannot make the accounting assertions pass. A deterministic court handler test also reaches the appeal, bond timeout and season payout branches.

The hook handler checks PoolManager's lock and outstanding currency deltas **inside the same handler call** as the swap, before transient storage is cleared by the transaction boundary. The court driver isolates court authorization; actual token settlement is exercised by the separate hook campaigns. No implementation storage is overwritten. CREATE2 deploys the real hook at its required permission bits and deploys pair tokens in both orderings.

The court invariant uses six actors to test liabilities and the state machine. It does not claim to prove top-25 selection after a strike; that property fails and is reported. Hook conservation campaigns use full-range liquidity and bounded trades, while the failing partial-fill property is retained in the report. No partial-fill behavior is asserted as correct.

## Five discovery passes

The supplied Pashov guides were applied as five manual passes; no subagents were used. Trail of Bits' property review and the supplied Foundry and Uniswap v4 references informed the test selection. The Solidity and this document were written for this repository, rather than copied from the reference templates.

| Pass | Property and source | Test/model |
| --- | --- | --- |
| Conservation | Court IMD covers pot, bonds and credits; payments cannot exceed inflows (`object`, `_credit`, `claim`, `endSeason`) | Independent inflow/payout and pot/bond/credit ghosts, every actor's liability, terminal claim liveness |
| Round trips and rounding | Refunds must preserve unspent sale allowance; proportional prizes and fee rounding cannot create funds (`sell`, `unlockCallback`, `endSeason`) | Reported partial-fill proof; fee conservation and prize quotient bounds, return-bond/claim cycle |
| State transitions | One active plea, unique round votes, 17-vote decisions, bounded sales, resolved objections stay resolved, dead-man activation is permanent | Court handler, deadline units, pending and vote count invariants, hook shutdown campaigns |
| Adversarial value/liveness | No unauthorized sell, spoofed identity, second claim, failed transfer state corruption, or loss of an eligible top-25 prize | Exact wrapped gate errors, reentrancy probes, rollback assertions, reported leaderboard proof |
| Protocol-specific | Fixed ERC-20 supply, authentic v4 callback sender, correct swap direction for both exactness modes, settled deltas, callable LP exits | Actual PoolManager, both currency orderings, token transfer handler, in-transaction settlement assertions |

## Independent security review

This review is independent of the implementation author's `SECURITY.md`. It reviews the supplied source and local executions, not a deployed launch.

- **Sell gate:** the router cannot select a different seller through `hookData`; exact input and exact output sells fail with the intended hook error. Buys remain open across pending, denied, expired and banned states. Foreign callback callers are rejected by the original tests. Single-sided liquidity is restricted by the sender allowlist. Removing liquidity and collecting fees remain available after an LP loses permission. The confirmed exception concerns accounting after an authorized partial fill, not an unauthorized swap bypass.
- **Oracle manipulation:** score/fact bounds, unique votes, 16-vote nonfinality, the 17th decision, 15/15 deadlock, round separation, median rounding and ownership transitions are tested. A 17-judge coalition remains trusted by design. Owner rotation preserves already-cast votes and can stack a verdict across panels; the implementation already discloses this owner power. Seats are also owner-controlled, and their value is read when each vote is cast.
- **Timing and reentrancy:** sale, appeal, objection, bond-timeout and silence deadlines have equality/adjacent-second cases. Partial votes and new pending pleas cannot restart silence. Late judging cannot reverse free trading. A pair-token callback cannot reenter `sell`; credit is cleared before an external claim transfer, preventing a second withdrawal. A failed swap or transfer rolls back accounting and allowances.
- **Griefing:** a failed objection bond payment leaves the sale available to a later objector; duplicate objections/votes and repeated resolution/claim are rejected. An unruled bond is reclaimable at its deadline. A recipient refusing an IMD transfer cannot block buys or season rollover. Top-25 removal fairness fails as reported.

Operational/design limits remain: an allowlisted shared position manager must enforce who can add liquidity; the hook sees that contract as the LP. The appeal limit is per plea ID: the existing implementation permits withdrawal of a denied plea and immediate new submission, so it does not enforce a seller-wide cooldown across new IDs. Dead-man activation is lazy, and an external caller may need to invoke `triggerDeadManSwitch` to persist its event. These are not strengthened into new passing guarantees here.

No fork block or RPC variable is specified by this assignment, so these tests run entirely offline with the actual vendored PoolManager and local pair tokens. A deployment rehearsal against the actual IMD token and launch factory remains outstanding. The hostile token mock probes failure paths; it does not claim that live IMD has callbacks, transfer fees, pausing, or false returns. No Slither, Mythril, or formal-verification result is claimed.

## Reproduction

From the repository root:

```sh
FOUNDRY_FUZZ_SEED=0xc3444dc9a9ca7b611c389c04aeb93c00dc6def31451c5675f5ec3cf18c9e2fb1 forge build
FOUNDRY_FUZZ_SEED=0xc3444dc9a9ca7b611c389c04aeb93c00dc6def31451c5675f5ec3cf18c9e2fb1 forge test
```

To reproduce a reported defect, save its `proof` field verbatim as a `.t.sol` file under `test/scratch/`, then run `forge test --match-path` on that file. The proof imports project source and vendored libraries only, and intentionally fails until the implementation is repaired. `test/scratch/` is not part of the submission.
