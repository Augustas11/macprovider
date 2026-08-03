# SPEC-016 round 20 — Claude-side adversarial cross-check (2026-06-25)

**Source:** Claude cross-check on locked v0.1.19 (commit `5c034a0`), conducted
mid-IMPL between Step 1 commit (`1df0235` on branch `impl/spec-016`) and Step
2 kickoff. Two parallel Claude subagents (critic + analyst lenses) were
deliberately used to find what 19 codex rounds with the same lens may have
missed.

This round is **not** a codex audit. Per [[feedback-codex-only-audits]], the
formal SPEC/IMPL audit loops use codex via `/ccg` or `/ask codex`. This is a
**cross-check** layered on top of the codex CONVERGED state, motivated by the
analyst's framing: *same-family auditors share writer's blind spots; a
different lens (Claude) catches the cross-section interaction surface codex
audited vertically*.

Round 20 absorbs the 3 criticals + 4 of the 5 majors. M3 (EIP-712
`verifyingContract` UX) is documented-as-known-limitation rather than fixed
to avoid a typed-data shape change after Step 1 IMPL committed the verifier.

## Findings + closure

### C1 — `Idempotency-Key` header on `POST /admin/payout/record-funding` is decorative

**Where:** §4.9 line 2788. The endpoint declares `Idempotency-Key: <opaque>`
but the response table only lists 409 for `UNIQUE(tx_hash)`. There is no
table or check that the same opaque header replayed with a *different*
`tx_hash` is rejected — meaning an operator typo (or buggy retry loop)
inserts a new row with a fresh `tx_hash` and inflates
`cumulative_funding_usdc_base_units`. The §7.4 drift alarm only PAGES on
NEGATIVE drift, so a positive-direction inflation silently absorbs missing
on-chain USDC.

**Closure (v0.1.20):** the simplest defensible binding is to make the
header non-decorative by REQUIRING `Idempotency-Key == tx_hash` (case-
insensitive equality, both `0x`-prefixed lowercase hex). This collapses two
idempotency keys into one and lets `UNIQUE(tx_hash)` continue to be the
real enforcer. Mismatch → 422 `idempotency_key_mismatch`. The opaque-key
framing is retired — the funding endpoint's natural key IS the tx_hash.

### C2 — `from_address == hot_wallet_address` self-funding bypass during bootstrap

**Where:** §4.9 line 2802. The endpoint rejects `to_address !=
payout.security.hot_wallet_address` but has no symmetric check on
`from_address`. During the `source='manual'` bootstrap window (before the
first payout confirms and irrevocably flips
`payout_bootstrap_complete`), an operator-key holder can submit a row with
`from = to = hot_wallet` and a fake `tx_hash`; cumulative funding inflates
by amount X with no on-chain counterpart. §7.4 query (D) detects negative
drift (operator-key compromise signature) but ONLY after a payout would
have failed; the inflation makes the on-chain side look HIGHER than expected
(positive drift), which is benign-default.

**Closure (v0.1.20):**

1. §4.9 adds a 400 rejection when `from_address ==
   payout.security.hot_wallet_address` regardless of `source`. The hot
   wallet cannot be its own funder.
2. §7.4 adds a new reconciliation query (E) detecting `from_address ==
   to_address` rows in `payout_hot_wallet_funding` as a hard
   `payout_invariant_violation` signal.
3. The §3.2 deny-list framing (line 419) is updated to note that the
   hot wallet is denied as a payout DESTINATION *and* as a funding
   SOURCE; mirrors §4.9 enforcement at the spec-level invariant.

### C3 — `amount_base_units == lpr.provider_credits` not asserted at write-time

**Where:** §4.3 step 5 (INSERT into `payout_attempts`) and §4.3 step 2 (line
880). Step 2 prose says "USDC amount in base units equals `provider_credits`
exactly" but the identity is not asserted INSIDE the `BEGIN IMMEDIATE`
transaction at step 5. The §7.4 per-provider query (A) catches drift
*after* `ClaimPayoutReady` has fired `UPDATE … SET status='consumed'`. The
spec is one bug-fix away from over-paying: any future code path that sets
`amount_base_units` from anything other than `lpr.provider_credits` passes
`ClaimPayoutReady`'s gross-only validation and burns operator USDC.

**Closure (v0.1.20):** §4.3 step 5 adds a normative pre-INSERT invariant
inside the `BEGIN IMMEDIATE` transaction:

> Before INSERTing the `payout_attempts` row, the IMPL MUST assert
> `amount_base_units == lpr.provider_credits` (both INTEGER USDC base
> units). On mismatch, the IMPL MUST `ROLLBACK`, emit
> `payout_invariant_violation where='amount_credit_mismatch'` per §7.1
> (severity=PAGE) with fields `(payout_id, lpr_provider_credits,
> computed_amount_base_units)`, and HALT the runner pending operator
> forensic review.

The `where='amount_credit_mismatch'` enum value is added to §7.1's
`payout_invariant_violation` enum table.

### M1 — Reorg detection has no liveness contract for already-confirmed rows

**Where:** §4.7 lines 1810-1818. The reorg revert path triggers "if the
runner observes that a previously-confirmed PROVIDER-PAYOUT tx is no
longer present in the canonical chain", but there is no MANDATED
re-polling cadence for already-confirmed rows. The hourly chain-balance
reconciliation (`chain_recon_interval`, default 1h) catches the drift
side-effect but cannot identify WHICH row reorged. Operator sees a
drift PAGE and has to manually scan every confirmed row against chain.

**Closure (v0.1.20):** §4.7 adds a normative `payout.tuning.reorg_poll_window`
(default `24h`, bounds `[1h, 168h]`). Every cadence cycle, the runner MUST
re-poll receipt status (via the §4.4 two-RPC discipline) for every
`payout_attempts` row where `confirmed_at_utc >= now - reorg_poll_window`
AND `is_cancel_self_transfer = 0`. Any row whose receipt becomes "not
found" on either RPC enters the §4.7 reorg path with the row identified.
This costs at most `max_rows_per_run × confirmation_blocks` RPC reads per
cycle and gives the operator a row-pointed reorg event instead of an
opaque drift PAGE.

### M2 — `confirmation_blocks` floor doesn't state the finality model

**Where:** §payout.tuning.confirmation_blocks line 3423, default 5,
bounds [2, 50]. Base reaches "soft" finality at ~2s but "hard" finality
only after L1 commitment (minutes-to-hour). 5 Base blocks ≈ 10s is
soft-finality only. Base has had ≥7-block reorgs during sequencer
incidents in 2024-2025; the spec asserts "vanishingly rare in practice"
without citation.

**Closure (v0.1.20):** §payout.tuning.confirmation_blocks (and §1 Goals
where reorgs are first mentioned) state explicitly:

> **Finality model.** `confirmation_blocks` is a SOFT-finality threshold
> only. Hard finality on Base requires L1 commitment (minutes-to-hour
> latency). Operators sizing this value MUST consider the per-payout
> amount: at the default `per_payout_cap_usdc_base_units = 1_000_000_000`
> ($1,000), soft finality at 30 blocks (~60s) is the recommended
> baseline. The v0.1.19 default of 5 was sized for $10–$100 payouts on
> a network that has not yet experienced a sequencer incident; operators
> running with `per_payout_cap >= 100_000_000` ($100) MUST raise this to
> ≥30. The bounds tighten to **[5, 200]** (was [2, 50]) — 2 blocks is
> unsafe even at sub-$1 per-payout amounts and 50 blocks was too low
> a ceiling to express the L1-commitment-aligned settings real operators
> may want.

The default itself is NOT changed in v0.1.20 to avoid invalidating Step 1
schema or runner behavior that may already assume `default=5`. The
default-change is a follow-up sweep in v0.2 with the rationale that the
default should track typical per-payout amount; the bound widening and
the prose are the load-bearing changes here.

### M4 — Singleton-runner lease has no fencing token against the chain

**Where:** §4.8b lease semantics. The `holder_token` is SQLite-side
self-fencing only. A process that signs an envelope and crashes after
`eth_sendRawTransaction` (broadcast) but before COMMITting the persist
is correctly handled by the §4.6 nonce-gap path. A process that COMMITs
persist but stalls between the post-COMMIT lease re-read (line 1219)
and the syscall to `eth_sendRawTransaction` (lines 1232-1234) sits in a
small but non-zero window where takeover can elect a new holder. The
new holder rebroadcasts the same persisted envelope; the chain dedupes
by nonce so only one tx lands. **The chain's nonce-uniqueness is
load-bearing for this race**, not defense-in-depth.

**Closure (v0.1.20):** §4.8b adds an explicit non-normative explanatory
paragraph:

> **Chain-nonce uniqueness is load-bearing for the post-CAS broadcast
> race.** Between the §4.3 step 6 post-COMMIT lease re-read and the
> `eth_sendRawTransaction` syscall, a GC stall or page fault can elect
> a new lease holder. The new holder MAY re-broadcast the persisted
> envelope (same nonce, same signature, byte-identical tx). The Base
> sequencer's nonce-uniqueness rule is what guarantees at most one
> confirms — IMPL MUST NOT rely on a second software guard to make
> this single. Test required: simulate the stall by injecting a 30s
> sleep between persist-COMMIT and `eth_sendRawTransaction`; assert
> at most one of the two broadcasts succeeds and the other receives
> the RPC's `nonce too low` / `already known` response without
> halting the runner.

### M5 — No money-conservation invariant query in §7.4

**Where:** §7.4. The per-provider query (A) catches drift in any single
provider's row-set but does not label conservation as the load-bearing
invariant. Operators reading §7.4 see a list of queries without the
binding "run these weekly; ANY row returned is a money-correctness
incident, not a warning."

**Closure (v0.1.20):** §7.4 adds:

1. A new aggregate-level query (F):

   ```sql
   -- (F) Money-conservation invariant. SUM over consumed ledger rows
   -- vs SUM over confirmed non-abandoned non-cancel attempts. Any
   -- non-zero result is a money-correctness incident.
   SELECT
     (SELECT COALESCE(SUM(provider_credits), 0)
        FROM ledger_payout_ready
       WHERE status = 'consumed'
         AND payout_currency = 'USDC-BASE')
     -
     (SELECT COALESCE(SUM(amount_base_units), 0)
        FROM payout_attempts pa
        INNER JOIN ledger_payout_ready lpr ON lpr.id = pa.payout_id
       WHERE lpr.status = 'consumed'
         AND lpr.payout_currency = 'USDC-BASE'
         AND pa.confirmed_at_utc IS NOT NULL
         AND pa.abandoned_at_utc IS NULL
         AND pa.is_cancel_self_transfer = 0)
     AS conservation_delta;
   ```

   Any non-zero `conservation_delta` is a money-correctness incident
   that MUST page the operator (out-of-band — query (F) is operator-
   run, not auto-scheduled in v0.1.20).

2. A normative operational binding:

   > **The operator MUST run query (F) weekly and the operator MUST
   > treat any non-zero `conservation_delta` as a SEV-1 incident,
   > halting the runner via `/admin/payout/runtime-flags` until the
   > drift source is identified.** Query (F) supersedes the per-
   > provider query (A) as the canonical money-conservation check;
   > (A) remains useful for per-provider attribution but (F) is the
   > load-bearing aggregate invariant.

### M3 — EIP-712 `verifyingContract = hot_wallet_address` (DEFERRED, not absorbed)

**Where:** §3.2 step 5. EIP-712 defines `verifyingContract` as "the
contract that is to verify the signature" — wallets like Rabby/Safe
display this as a contract address and warn or refuse-to-sign when the
target is an EOA. The spec's "sentinel" framing acknowledges the
non-canonical usage but doesn't address the wallet-UX impact.

**Why deferred to v0.2:** Step 1 IMPL committed the verifier with the
current typed-data shape. Changing `verifyingContract` to a real
registry contract OR moving the hot-wallet binding into the struct
fields requires re-deriving test vectors and re-auditing §3.2 — half-
day of rework on already-audited code. The wallet-UX risk is real but
not a money-correctness defect. Documented as known limitation in
§3.2 v0.1.20 prose; revisit when SPEC-014 v0.9 builds the portal
signing UX (the UX surface is where this defect actually manifests).

## Convergence

**This is a Claude-side cross-check, not a codex round.** v0.1.20 MUST go
through one codex audit round (`specs/AUDIT_SPEC_016_R20_PROMPT.md`) to
confirm CONVERGED 0/0/0 against the seven deltas above before Step 2 IMPL
proceeds. Round 20 (Claude) → Round 21 (codex) is the expected sequence;
the audit-file numbering reflects the round that authored the file,
matching repo convention.

## Cross-references

- v0.1.19 audit-narrative-split commit: `5c034a0` (locked SPEC, codex
  CONVERGED 0/0/0)
- Step 1 IMPL commit: `1df0235` on branch `impl/spec-016`
- IMPL prompt: `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
- Step 1 IMPL audit: `specs/SPEC-016-IMPL-PROMPT-audit.md`
