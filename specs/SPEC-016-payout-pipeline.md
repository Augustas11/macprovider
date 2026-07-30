# SPEC-016 — Provider payout pipeline (USDC on Base)

**Version:** 0.1.23 (2026-07-30, draft — lineage reconciliation per issue #586. Merges the two divergent `v0.1.2x` lineages: the `main` v0.1.20 Wave-2 provider-token custody gate (2026-07-04 — payout attempts require provider-token trust: pinned/operator-issued, bearer-validated, or explicit `self_minted_verified` proof; tokenless self-minted sessions are not payout eligible) AND the `impl/spec-016` v0.1.22 IMPL follow-up (2026-06-29 — §7.1 gains `payout_stale_outbox_backlog`, `payout_rpc_chronic_outage`, `payout_spki_drain_skipped_unsupported_client`; §4.7 step 5 keyset-paginated bounded-memory scan with `staleOutboxScanCeiling=20000`; §4.4 two-RPC discipline via `TrackingRPCClient` + `ChronicOutageTracker`). Both lineages' normative content is retained in full; see the v0.1.23 change-log entry for the drop-nothing cross-check.)
**Status:** Draft (IMPL merged via PR #164, default-off — `payout.enabled=false`
everywhere until the operator funds the hot wallet and discharges the eight
§9 prerequisites; flipping the flag is an operator decision gated on §9).
**Depends on:** SPEC-005 v0.3 (§5.1 unit definition; §10.1 WAL
mode + synchronous=FULL requirement; §11.4 earnings endpoint;
§2.1 D1 donation-only / no-custodial framing),
SPEC-006 v0.9 (buyer surface — not extended by this SPEC),
SPEC-014 v0.8 (provider portal — consumes SPEC-016 read
surface; SPEC-014 v0.9 candidate MUST add the payout-address
registration + payout history screens called out in §3 and §9,
filed as a separate follow-up).

---

## Change log

Audit-narrative-by-round detail lives in the per-round audit files
under `docs/spec-history/spec-016/SPEC-016-rN-audit.md` (one file per codex round, plus
the v0.1 internal-critic and rounds 2-7 Claude rounds preserved as
git-history-only). The change-log entries below are one-liners per
version pointing at the corresponding audit file. Per
[[feedback-spec-audit-file-convention]], audit narrative does NOT
live in this SPEC body.

**v0.1.23 (2026-07-30, draft — lineage reconciliation, issue #586):**
Merges the forked `main` and `impl/spec-016` spec lineages when PR #164
landed. The fork: `main` advanced v0.1.20 → Wave-2 provider-token custody
(2026-07-04, entry below) while the IMPL branch had already advanced
v0.1.20 → v0.1.21 → v0.1.22 (2026-06-29), so the version numbers are
non-monotonic versus date. This entry records the drop-nothing
cross-check: (a) the Wave-2 custody gate survives — §"payout selection"
normative text requiring `pinned`/`operator_issued`, `bearer_validated`,
or explicit `self_minted_verified` trust, plus its change-log entry;
(b) all v0.1.21/v0.1.22 IMPL-follow-up normative deltas survive — the
three §7.1 events, the §4.7 bounded keyset scan + `staleOutboxScanCeiling`,
and the §4.4 `TrackingRPCClient`/`ChronicOutageTracker` discipline.
No new normative requirements; Status line updated to reflect that
`internal/payout/` is now on `main`, default-off pending §9.

**v0.1.20 (2026-07-04, draft — Wave 2 provider-token custody,
`main`-lineage entry; see also the 2026-06-25 v0.1.20 entry from the
IMPL-branch lineage below):**
Payout attempts require provider-token trust: pinned/operator-issued,
bearer-validated, or explicit `self_minted_verified` proof. A
tokenless `self_minted` provider session remains visible but MUST NOT
enter payout selection.

**v0.1.22 (2026-06-29, draft — issue #165 IMPL follow-up, 3-round
codex audit converged):**
Absorbs the two LOW arch advisories deferred from the PR #164 FULL
audit cycle (see [[tracking-issue-scope-control]]), expanded
through R1/R2/R3 audit to also close the prefix-starvation
denial-of-detection class, the SIGHUP-vs-wrapper SPKI-drain
regression, and the unbounded-materialization risk. §7.1 gains
three event rows:
- `payout_stale_outbox_backlog` (severity=WARN) — emitted by the
  §4.7 step 5 producer when this cycle's PRODUCED outbox row count
  hit the operator-configured cap (sized from
  `payout.tuning.max_rows_per_run`) before the candidate set was
  exhausted, so a backlog remains for future cycles to drain.
  Repeats every runner cycle while the backlog persists — operators
  see the gauge per cycle until queue depth falls below cap.
  Fields: `run_id, limit, produced, total_candidates,
  scan_ceiling_hit, total_scanned, ts_utc`.
  `total_candidates` is the REMAINING un-paged backlog AFTER this
  cycle's production completes (NOT pre-cycle count). A
  `total_candidates = -1` sentinel signals the operator that the
  count query itself failed (degraded observability, NOT that there
  is no backlog). Severity escalates from WARN to PAGE when
  `scan_ceiling_hit = true` (the defensive runner-cycle scan
  ceiling of 20000 rows was reached; backlog is deeper than the
  cycle can drain).
- `payout_rpc_chronic_outage` (severity=PAGE) — emitted by the
  chronic-outage tracker when one RPC's error rate exceeds the
  threshold over the sliding window. Fields: `rpc_label,
  window_seconds, sample_count, error_count, error_rate,
  threshold, ts_utc`. Defaults: 10-minute window, 50% threshold,
  10 minimum samples, 10-minute PAGE cooldown per label. Closes
  the silent-degradation gap where ONE chronic RPC failure
  produces no operator event (the §4.4 disagreement detector
  fires only when BOTH RPCs return AND disagree).
- `payout_spki_drain_skipped_unsupported_client` (severity=WARN)
  — emitted when an accepted SPKI pin rotation could NOT drain
  pooled TLS connections because the current `RPCClient`
  implementation doesn't expose `CloseIdleConnections()`. Fields:
  `rpc_label, ts_utc`. Until the idle-conn TTL expires, the OLD
  pin remains in force on existing connections. Operators MUST
  rotate again or restart to enforce hardening immediately. Future
  RPC wrappers MUST forward `CloseIdleConnections()` to remain
  rotation-safe; this WARN is the canary for that contract.
IMPL surface: `phase4-coordinator/internal/payout/orphans.go`
(LIMIT + backlog gauge) and `phase4-coordinator/internal/payout/chronic.go`
(sliding-window tracker + `TrackingRPCClient` wrapper).

**§4.7 step 5 production cap (NORMATIVE in v0.1.22).** The
stale-cancel producer's per-cycle PAGE production is capped by
`payout.tuning.max_rows_per_run` (the same operator config the
§4.3 step 1 ready-row scan uses). The cap bounds *produced outbox
rows*, NOT *scanned candidates* — non-actionable candidates
(missing `tx_hash`, transient RPC error, at-least-one-RPC-still-
sees-receipt) do not consume the budget; the scan continues past
them via keyset pagination so persistent non-actionable rows
cannot indefinitely suppress truly stale cancels from PAGEing.
The SELECT scans in chunks of 256 rows ordered by
`(updated_at_utc, payout_id, attempt_seq)` (covered by the
partial index `idx_pa_stale_cancel_keyset` per migration 0013);
each chunk advances a strict-tuple cursor so memory stays O(chunk)
regardless of backlog. A defensive runner-cycle ceiling of
`staleOutboxScanCeiling = 20000` rows caps total scan work and
keeps RunOnce wall-time bounded; the final chunk's `LIMIT` is
clamped to the remaining ceiling so total scanned rows never
exceed 20000.
When the production cap is hit before the candidate set is
exhausted, the producer emits `payout_stale_outbox_backlog` with
`run_id, limit, produced, total_candidates, scan_ceiling_hit,
total_scanned, ts_utc`. Severity is `WARN` by default but
escalates to `PAGE` when `scan_ceiling_hit = true` (the 20000-row
ceiling was reached — backlog is deeper than this cycle can drain
and demands operator action). The event repeats every cycle until
backlog drains under cap. `total_candidates` is the *remaining*
un-paged candidates AFTER this cycle's production completes (i.e.
backlog awaiting future cycles); a value of -1 is the sentinel
emitted when the count query itself fails (degraded observability,
NOT zero backlog). Operators sizing
`max_rows_per_run` MUST recognize it as a SHARED budget across §4.3
step-1 ready-row payment work AND §4.7 step-5 stale-cancel PAGE
production; lowering the cap reduces both. The cap's normative
bound remains `[1, 500]` per §payout.tuning.

**§4.4 two-RPC discipline gap closure (NORMATIVE in v0.1.22).** The
§4.4 disagreement detector fires only when BOTH RPCs return AND
disagree. A chronic single-RPC failure (network partition, vendor
outage) is silently swallowed by the runner's degrade-and-retry
behavior. The `payout_rpc_chronic_outage` PAGE closes that gap:
every RPC call through the production `TrackingRPCClient` wrapper
records success/failure into the `ChronicOutageTracker`; an
independent goroutine ticker drives Evaluate at `min(window/2,
1min)` (decoupled from `payout.tuning.run_interval` so detection
stays responsive when operators run the cycle at the [5m, 24h]
upper bound). The wrapper covers every `RPCClient` interface method
including `CloseIdleConnections()` so SIGHUP SPKI pin rotation
still drains pooled TLS connections through the wrapper.

**v0.1.21 (2026-06-25, draft — codex round-21 fix pass on
v0.1.20):** Round 21 returned NEEDS FIX PASS 0/1/1/1. Fixes:
MAJOR-1 (M2 fix-out) — stale `[2, 50]` confirmation_blocks
bound at §4.3 step 7 line 1295 replaced with `[5, 200]`;
two stale `[2, 50]` references in `BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
(lines 82, 885) also updated to `[5, 200]`; "MUST explicitly
set to opt out" prose corrected to "operators with config
values in `[2, 4]` MUST raise to ≥5". MEDIUM-1 (M4 fix-out)
— IMPL test (4) in §4.8b rewritten to pin the injection
point AFTER the post-COMMIT lease re-read and removed the
impossible cross-process lease-loss assertion; the test now
explicitly asserts chain nonce-uniqueness is what serializes
the race. LOW-1 (M1 fix-out) — §4.7 re-poll budget paragraph
clarified to distinguish row re-polls vs RPC calls
(`N_rows × 2` RPC calls because two-RPC discipline; 200 rows
= 400 RPC calls per cycle). Full r21 closure narrative:
`docs/spec-history/spec-016/SPEC-016-r21-audit.md`.

**v0.1.20 (2026-06-25, draft — Claude-side cross-check absorbed):**
Round-20 Claude cross-check (critic + analyst lenses, parallel)
absorbed 3 criticals + 4 majors: C1 `Idempotency-Key` on
`/admin/payout/record-funding` bound to `tx_hash` equality (§4.9);
C2 `from_address == hot_wallet` rejected during bootstrap + §7.4
query (E) detector + §3.2 deny-list framing extended (§4.9 / §7.4 /
§3.2); C3 `amount_base_units == lpr.provider_credits` pre-INSERT
invariant inside the §4.3 step 5 `BEGIN IMMEDIATE` transaction with
new `payout_invariant_violation where='amount_credit_mismatch'`
enum value; M1 normative `payout.tuning.reorg_poll_window` re-poll
cadence for already-confirmed rows (§4.7 / §payout.tuning); M2
finality-model paragraph + `confirmation_blocks` bounds widened
from [2, 50] to [5, 200] (§payout.tuning / §1); M4 chain-nonce-
uniqueness load-bearing explanatory paragraph + IMPL stall test
(§4.8b); M5 §7.4 query (F) money-conservation aggregate invariant
+ weekly operational binding. M3 (EIP-712 `verifyingContract` UX)
deferred — Step 1 verifier already committed; documented as known
limitation in §3.2. Full audit narrative: `docs/spec-history/spec-016/SPEC-016-r20-audit.md`.

**v0.1.19 (2026-06-25, draft — audit-narrative split):** Splits the
inlined codex round-9..19 audit findings out of this SPEC body into
per-round `docs/spec-history/spec-016/SPEC-016-rN-audit.md` files. NO normative changes.
Body shrinks from ~5,860 lines to its normative core.

**v0.1.18 (2026-06-25, draft — post-convergence LOW sweep, no
audit fix pass):** Swept the 4 LOWs deferred since round-11
(`payout_runner_lease_conflict` → `_lost` at the §4.3 self-fence
site; §4.8a reaper CAS SQL aligned with sync emitter's
`RETURNING id`; §4.8a/b section order swapped to §4.8 → §4.8a →
§4.8b → §4.8c; one stale "§4.3 step 5" Signer-behavior ref → "step
6"). No normative requirement change. Commit `4dc4b24`.

**v0.1.17 (2026-06-25, draft — round-18 codex audit fix pass):**
Codex round 18 returned 0 CRIT + 0 MAJOR + 2 MED + 0 LOW; both MEDs
absorbed. Full findings + closure verification: `docs/spec-history/spec-016/SPEC-016-r18-audit.md`.
Fixes: §4.8c `cancel_reconfirm_stale_outbox` table + reaper added
for the §7.1 `payout_cancel_self_transfer_reconfirm_stale` PAGE
(closes crash-between-COMMIT-and-emit silent-suppression class);
§4.7 step-4 SQL literal block now actually clears
`cancel_reconfirm_stale_paged_at_utc = NULL` (prose said it did,
SQL didn't). Commit `7be223d`.

**v0.1.16 (2026-06-25, draft — round-17 codex audit fix pass):**
Codex round 17 returned 0 CRIT + 0 MAJOR + 1 MED + 0 LOW; absorbed.
Full findings: `docs/spec-history/spec-016/SPEC-016-r17-audit.md`. Fix: added
`cancel_reconfirm_stale_paged_at_utc` column to `payout_attempts`
+ CAS-based once-per-transition emission so the reconfirm-stale
PAGE doesn't re-fire on every coordinator restart. Commit
`ac31250`.

**v0.1.15 (2026-06-25, draft — round-16 codex audit fix pass):**
Codex round 16 returned 0 CRIT + 0 MAJOR + 3 MED + 0 LOW; all
absorbed. Full findings: `docs/spec-history/spec-016/SPEC-016-r16-audit.md`. Fixes:
cancel-confirmed event scoped to transition-only (no re-emit per
cycle); §7.1 `payout_reorg_revert` gains `is_cancel_self_transfer`
discriminator field; new `payout_cancel_self_transfer_reconfirm_stale`
PAGE event after 3 × `run_interval`. Commit `f6d4918`.

**v0.1.14 (2026-06-25, draft — round-15 codex audit fix pass):**
Codex round 15 returned 0 CRIT + 2 MAJOR + 1 MED + 0 LOW; all
absorbed. Full findings: `docs/spec-history/spec-016/SPEC-016-r15-audit.md`. Fixes
extend provider-payout discipline (pre-broadcast verify + CAS,
reorg recovery, observability) to the new cancel-handling machinery
from v0.1.13: §4.6 cancel preflight + CAS broadcast stamping;
§4.7 cancel-reorg carve-out (separate from provider-orphan flow);
§7.1 `payout_cancel_self_transfer_confirmed` (INFO) + §7.4
query (D) cancel observability roll-up. Commit `7f7a4b4`.

**v0.1.13 (2026-06-25, draft — round-14 codex audit fix pass):**
Codex round 14 returned 0 CRIT + 1 MAJOR + 0 MED + 4 deferred
LOW; absorbed. Full findings: `docs/spec-history/spec-016/SPEC-016-r14-audit.md`. Fix:
§4.3 step 5 lookup did not filter `is_cancel_self_transfer = 0`;
a confirmed cancel could be passed to `ClaimPayoutReady`,
consuming the provider's `ledger_payout_ready` row without
paying. §7.4 reconciliation excluded cancels from outflow sums,
so the misclassification would NOT trip drift — silent provider
loss. Three compound fixes: (a) §4.3 step 5 filter on
`is_cancel_self_transfer = 0`; (b) new cancel-handling pre-check
that handles live cancel rows separately; (c) cancel-specific
chain-side verification (different constants from provider
payouts; no `ClaimPayoutReady` call). **Real money-OUT defect
class that 13 prior rounds missed.** Commit `3cf8658`.

**v0.1.12 (2026-06-25, draft — round-13 codex audit fix pass):**
Codex round 13 returned 0 CRIT + 0 MAJOR + 1 MED + 4 deferred
LOW; absorbed. Full findings: `docs/spec-history/spec-016/SPEC-016-r13-audit.md`. Fix:
§4.6 `/admin/payout/abandon-attempt` `UPDATE` extended with
state-check predicates (`AND confirmed_at_utc IS NULL AND
abandoned_at_utc IS NULL`) + row-count disambiguation
(404 not_found / 409 already_confirmed / 409 already_abandoned).
Commit `4ad3e1a`.

**v0.1.11 (2026-06-25, draft — round-12 codex audit fix pass):**
Codex round 12 returned 0 CRIT + 1 MAJOR + 0 MED + 4 deferred
LOW; absorbed. Full findings: `docs/spec-history/spec-016/SPEC-016-r12-audit.md`. Fix:
§4.3 step 6 CAS persist extended with
`AND confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL` +
state-changed-during-sign halt; §4.6 abandon-attempt gains 409
`runner_active` rejection when lease is fresh. Both sides close
the concurrent-abandon-vs-runner-CAS race. Commit `0fba334`.

**v0.1.10 (2026-06-25, draft — round-11 codex audit fix pass):**
Codex round 11 returned 0 CRIT + 2 MAJOR + 2 MED + 4 LOW;
MAJORs+MEDs absorbed, 4 LOWs deferred per user scope decision.
Full findings: `docs/spec-history/spec-016/SPEC-016-r11-audit.md`. Fixes: §5.3
stale-reservation halt + cap-counts-all-regardless-of-age; §4.3
step 6 CAS persist via `BEGIN IMMEDIATE` with lease holder_token
re-check; §7.1 enum gains `prebroadcast_signed_tx`; §9 BetterStack
prereq tightened to per-event-name verification (not per-tier).
Commit `6749491`.

**v0.1.9 (2026-06-25, draft — round-10 codex audit fix pass):**
Codex round 10 returned 0 CRIT + 3 MAJOR + 5 MED + 7 LOW; all
absorbed. Full findings: `docs/spec-history/spec-016/SPEC-016-r10-audit.md`. Fixes:
§4.3 step 6 pre-broadcast Signer-output verification (ecrecover,
not just Signer.FromAddress); §4.8b `payout_runner_lease` table
+ acquire/heartbeat/takeover/self-fencing/release algorithm
(closes "stop-the-world-GC then resume" race); §5.3 reservation-
aware per-day cap query; §4.8a `runtime_flag_audit` outbox +
reaper CAS pattern; §4.7 `observed_*` snapshot columns for
immutable orphan binding; §9.5b.1 strict gross_credits =
provider_credits equality; §9.5b.1 Idempotency-Key header == body
equality; misc LOWs cleaned. Commit `72d2c14`.

**v0.1.8 (2026-06-25, draft — round-9 codex audit fix pass):**
First codex-lens audit (rounds 1-8 were Claude internal). Codex
round 9 returned 2 CRIT + 5 MAJOR + 2 MED; all absorbed. Full
findings: `docs/spec-history/spec-016/SPEC-016-r9-audit.md`. CRITs: (a) §9.5b.1
compensation insert not bound to original orphan's provider/amount
— compromised operator key could use a $10 orphan to authorize
unbounded compensation to a different provider; (b) §4.3 fresh-
attempt creation lacked a live per-payout guard — multi-process
race could double-broadcast at different nonces, double-pay.
Fixes plus 5 MAJORs + 2 MEDs. Commit `68a942e`.

**v0.1.7 (2026-06-25, draft — round-8 Claude convergent fix
pass, scoped to 3 cross-lens-convergent findings):** Round-8
Claude lens-parallel audit (code-reviewer + security-reviewer +
architect subagents) returned 2 CRIT + 2 MAJOR + 7 MED + 0 LOW.
Per user scope decision, v0.1.7 applied ONLY the 3 cross-lens-
convergent findings (`payout.security.pause_resume_min_interval`
missing from §6.5 enumeration; `runtime.registration_paused`
restart-persistence gap closed via new §4.8a `runtime_flags`
table; §3.3 503 `rotation_in_progress` added to response table).
This is the LAST Claude-audit-driven version; round 9 onward used
codex per [[feedback-codex-only-audits]]. Round-8 narrative lived
in this conversation only (Claude rounds 1-8 do not have separate
SPEC-016-rN-audit.md files); see `git log e0d838f..5f6266d --
specs/SPEC-016-payout-pipeline.md` for the full Claude-round
trajectory. Commit `5f6266d`.

**v0.1.6 (2026-06-24, draft — round-7 Claude audit fix pass):**
3 MAJOR + 7 MED + 2 LOW absorbed. Narrative in git history only
(commit `b3ef608`).

**v0.1.5 (2026-06-24, draft — round-6 Claude audit fix pass):**
5 MAJOR + 9 MED + 2 LOW absorbed. Narrative in git history only
(commit `2a14964`).

**v0.1.4 (2026-06-24, draft — round-5 Claude audit fix pass):**
1 CRIT + 2 MAJOR + 6 MED + 1 LOW absorbed. Narrative in git
history only.

**v0.1.3 (2026-06-24, draft — round-4 Claude audit fix pass; full
detail at commit `0eba7e6`):** 3 CRIT + 9 MAJOR + 8 MED absorbed.

**v0.1.2 (2026-06-24, draft — round-3 Claude audit fix pass; full
detail at commit `e35b3a5`):** 2 CRIT + 6 MAJOR + 13 MED absorbed.

**v0.1.1 (2026-06-24, draft — round-2 Claude audit fix pass; full
detail at commit `693fc3b`):** 5 CRIT + 12 MAJOR + 10 MED absorbed.

**v0.1 (2026-06-24, draft — round-1 internal-critic fix
pass absorbed, never pushed standalone; full detail at
commit `e0d838f`):**

Initial draft. Defined the contract by which the existing
`ledger_payout_ready` rows produced by
`phase4-coordinator/internal/billing/settlement.go` (SPEC-005
§11.x) are turned into on-chain USDC transfers on Base
mainnet to operator-owned provider payout addresses, then
claimed via the existing `ClaimPayoutReady` primitive at
`phase4-coordinator/internal/billing/payout.go:10`.

**Rail locked: USDC on Base (chain id 8453).** Rationale lives
in `beta/DECISION_CRITERIA.md` Entry 88 (rail decision), not in
this SPEC body. Summary for reviewers: Antfeed (the P2P AI
marketplace this network composes with) already settles on
Base, so the operator's hot-wallet operational surface area is
shared; sub-cent transfer cost; ~2s blocks; EVM tooling parity.
USDC contract on Base mainnet is
`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` — the operator
MUST verify this against
`https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
at IMPL kickoff and pin it into a config constant.

Scope explicitly EXCLUDED at v0.1 (see §2): non-Base rails
(ACH, Stripe Connect, USDC-Solana, etc.), custodial balances,
provider-side KYC, buyer refunds, multi-currency payout, and a
`PayoutAdapter` multi-rail abstraction. Each is a future vX.Y
if it ever ships.

Accounting schema is already complete — `payout_currency`
and `payout_external_id` columns on `ledger_payout_ready`
(`phase4-coordinator/internal/billing/store.go:111-112`) were
added in anticipation of exactly this work. SPEC-016's IMPL
MUST NOT modify the `ledger_payout_ready` DDL nor the existing
`trg_lpr_terminal_status_guard` trigger at
`store.go:121-126`.

`ClaimPayoutReady` is the only claim primitive — IMPL MUST
call the existing function at
`phase4-coordinator/internal/billing/payout.go:10`, NOT define
a replacement.

Hot-wallet design at v0.1.1 is local-file + operator-supplied
KEK at process start. KMS / HSM is a v0.2 thought experiment,
captured in §6.6 as a forward pointer; the `Signer` interface
in §4.1 is the seam.

Idempotency token at v0.1 is the chain-level `nonce`, NOT the
tx hash. The `UNIQUE(from_address, nonce)` constraint on
`payout_attempts` plus the chain's own nonce-uniqueness rule
guarantees at-most-one confirmed on-chain transfer per
`(payout_id, attempt_seq)`. On retry, IMPL MUST rebroadcast
the raw signed tx bit-for-bit (persisted in
`payout_attempts.raw_signed_tx`); re-signing is FORBIDDEN
because EIP-1559 envelopes re-pull a fresh gas-fee oracle
reading and produce different signed bytes (different tx
hash) at the same nonce.

Two RPCs are REQUIRED at v0.1 for receipt cross-confirmation
(round-2 SEC C5 fix); the originating prompt's "v0.1 MAY
assume single RPC" framing is superseded.

No IMPL bundled. Per [[feedback-bundle-spec-impl-one-pr]]
EXCEPTION rule, this is a net-new SPEC with NO downstream
implementer yet; IMPL will be written in a fresh session
against `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` (to be
authored after this v0.1.x merges).

Deferred follow-ups filed as Issue stubs, not inlined: (a)
SPEC-005 vX.Y+1 candidate: optional snapshot of the
credit→USD unit invariant in `ledger_config_snapshots` (today
the invariant is documented at SPEC-005 §5.1 only; if it ever
changes, payout rows MUST reference the snapshot active at
the row's window); (b) SPEC-014 v0.9 candidate: payout-address
registration + payout history screens (§3, §7).

---

## 1 Scope

SPEC-016 specifies the contract by which `ledger_payout_ready`
rows in `status='ready'` are converted to USDC transfers on Base
mainnet (chain id 8453) to operator-owned provider payout
addresses, marked `status='consumed'` with the on-chain tx hash
recorded in `payout_external_id` and the canonical currency tag
in `payout_currency`, and surfaced in the provider portal
(SPEC-014).

It does NOT specify:

- Settlement (the production of `ledger_payout_ready` rows) —
  that lives in SPEC-005 and ships today via
  `phase4-coordinator/internal/billing/settlement.go:79-130`.
- Portal UI — that lives in SPEC-014; SPEC-016 only defines the
  data shape the portal consumes.
- Buyer billing (gross credits, splits, rate cards) — SPEC-005
  / SPEC-006.

**Receipt → payout audit chain preserved unchanged.** SPEC-015
v0.3.3 receipts bind to a `request_id` recorded in
`request_log`; SPEC-005 sets
`ledger_request_credits.settlement_id → ledger_payout_ready.id`;
SPEC-016 adds `payout_attempts.(payout_id, attempt_seq) →
ledger_payout_ready.id` and records `payout_attempts.tx_hash`.
The full chain is
`request_id → settlement_id → payout_id → (attempt_seq,
tx_hash)`. Note the `(attempt_seq, tx_hash)` tail: a single
`payout_id` may have multiple `payout_attempts` rows (original,
cancel self-transfers, post-abandon retries). The CANONICAL
confirmed attempt is the unique row matching
`idx_pa_one_active_per_payout` per §4.5 (single confirmed
non-cancel non-abandoned row per payout_id); compensation rows
for reorg orphans live at the SPEC-005 layer with their own
`payout_id`. SPEC-016 MUST NOT modify any upstream identifier.

## 2 Out of scope (v0.1)

1. **Custodial balances.** The operator MUST NOT hold per-
   provider balances. The hot wallet only debits; it never
   credits a per-provider account.
2. **Non-Base rails.** ACH, Stripe Connect, USDC-Solana,
   Polygon, Ethereum mainnet, USD-on-card, wire, gift card,
   etc. Future SPEC vX.Y or SPEC-NNN if ever shipped.
3. **Provider-side KYC.** Each provider supplies a Base
   address; the on-chain transfer IS the receipt. Tax
   reporting is the operator's separate obligation; SPEC-016
   does not mediate it.
4. **Buyer refunds / chargebacks.** SPEC-005's
   `idempotency_key` infrastructure on `ledger_payout_ready`
   plus the `voided` terminal status cover credit-side
   reversals. SPEC-016 only moves funds OUT, never back. The
   closest analogue (reorg revert) is handled by §4.7 as a
   compensation flow at the SPEC-005 layer, NOT by reversing
   the SPEC-016 on-chain transfer.
5. **Multi-currency payouts.** USDC-on-Base only at v0.1. The
   `payout_currency` column accommodates future expansion;
   v0.1 IMPL MUST always write the canonical string
   `"USDC-BASE"` (uppercase, hyphen-separated, no whitespace).
6. **`PayoutAdapter` multi-rail abstraction.** Single-rail
   concrete implementation is shorter, easier to audit, easier
   to refactor than a premature polymorphic interface. A
   future SPEC-016 vX.Y that adds a second rail will carry the
   refactor.
7. **Auto-refill of the hot wallet.** v0.1 has no upstream
   funding loop. The operator funds manually from operator
   treasury.
8. **Per-payout fee deduction from provider funds.** Gas is
   paid from the operator hot wallet (§5); the provider
   always receives the full `provider_credits → USDC` amount.

**Linux-only constraint when `payout.enabled = true`.** §6.3
requires the runner process to run on Linux (Crashreporter on
macOS bypasses `RLIMIT_CORE`). §3.3 requires the registration
handler + runner to be co-resident in the same coordinator
process (clock authority). Therefore enabling
`payout.enabled = true` constrains the ENTIRE coordinator
process — including SPEC-005 settlement + SPEC-014 portal
endpoints + buyer-mux + ws-mux — to Linux. macOS dev
environments cannot run a payout-enabled coordinator. This is
a deliberate cut; the dev workflow on macOS continues to work
with `payout.enabled = false` (default).

## 3 Provider payout-address registration (FR-P1)

### 3.1 Storage

There is no `providers` table on the coordinator today —
provider identity lives in `provider_tokens`
(`phase4-coordinator/internal/auth/tokens.go:247`) and the
in-memory `pool.Registry`. SPEC-016 IMPL MUST create:

```sql
CREATE TABLE IF NOT EXISTS provider_payout_addresses (
    provider_id      TEXT NOT NULL,
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    address          TEXT NOT NULL,
    payout_allowed   INTEGER NOT NULL DEFAULT 1 CHECK(payout_allowed IN (0,1)),
    pending_until_utc TEXT NULL,
    rotated_from     TEXT NULL,
    registered_at_utc TEXT NOT NULL,
    registered_against_hot_wallet TEXT NOT NULL,
    UNIQUE(provider_id, chain)
);
CREATE INDEX IF NOT EXISTS idx_ppa_provider ON provider_payout_addresses(provider_id);
```

`registered_against_hot_wallet` is the operator's
`payout.security.hot_wallet_address` value AT registration time
(used as EIP-712 `verifyingContract`, §3.2 step 5). After a
§6.4 key rotation, rows whose
`registered_against_hot_wallet != payout.security.hot_wallet_address`
are SKIPPED by the runner (§4.3 step 1) until the provider
re-registers against the new hot wallet. This makes the
"EIP-712 signature is valid only for the current hot wallet"
property operationally explicit rather than implicit.

The table MUST live in the same SQLite database as
`ledger_payout_ready` so the §7.4 reconciliation query can
join without cross-DB plumbing. Every connection touching this
table or `payout_attempts` MUST assert `PRAGMA
foreign_keys=ON` and `PRAGMA journal_mode=WAL` and `PRAGMA
synchronous=FULL` at open, failing fast otherwise (matches
SPEC-005 §10.1).

`payout_allowed` is the §8 compliance gate.

`pending_until_utc` is the §3.3 cooling-off field: a freshly-
registered or rotated address is NOT eligible for payout
selection (§4.3 step 1) until `now() >= pending_until_utc`.
Default cooling-off period is 24 hours; configurable via
`payout.tuning.address_cooling_off_period` (minimum 1 hour at
config-parse).

`chain` is locked to `'base-mainnet'` at v0.1. The CHECK
constraint is the canary that catches an accidentally-
broadened IMPL.

`registered_at_utc` is the timestamp of the current row's
address (rewritten on rotation). `rotated_from` preserves the
predecessor address for the MOST RECENT rotation only; deeper
history lives in the §3.4 structured log stream.

### 3.2 Address validation

The IMPL MUST validate, before INSERT or UPDATE:

1. Address is exactly 42 ASCII chars, starts with `0x`, and
   the remaining 40 chars are hex (`[0-9a-fA-F]`).
2. EIP-55 enforcement follows the standard exactly: an
   all-lowercase or all-uppercase 40-hex address is accepted
   as checksum-skipped (per EIP-55 backward-compat rule), and
   IMPL stores the canonicalised mixed-case checksummed form.
   A mixed-case address whose checksum DOES NOT match the
   canonical EIP-55 checksum is REJECTED.
3. `provider_id` MUST already exist in `provider_tokens`
   (`phase4-coordinator/internal/auth/tokens.go:247`).
   Rejection on miss emits
   `provider_payout_address_rejected_unknown_provider`.
4. Address MUST NOT be in the deny-list. The deny-list MUST
   include at minimum: the zero address
   `0x0000000000000000000000000000000000000000`, the USDC
   contract address itself
   `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, known
   burn addresses (`0x000…dead`), and the configured hot-
   wallet address (self-payment denial). Operator MAY add
   more. **The hot wallet is denied as a payout
   DESTINATION here AND as a funding SOURCE in §4.9
   `POST /admin/payout/record-funding`** (v0.1.20 round-20
   C2 closure — the symmetric ban closes the bootstrap
   `from = to = hot_wallet` self-funding inflation attack
   class; see §4.9 400-response table and §7.4 query (E)).
5. **EIP-712 proof-of-possession.** The request body MUST
   include a `signature` field — a 65-byte (r||s||v)
   hex-encoded EIP-712 typed-data signature over the
   following domain + struct:

   ```
   EIP-712 Domain:
   {
     name:              "macprovider-payout",
     version:           "1",
     chainId:           8453,
     verifyingContract: <payout.security.hot_wallet_address>
   }

   PayoutAddressRegistration:
   {
     providerId: string,    // matches ^[A-Za-z0-9_-]{1,128}$
     address:    address,   // canonical EIP-55 checksum
     chain:      string,    // exactly "base-mainnet"
     nonce:      bytes32,   // opaque 32 bytes hex
     tsUtc:      uint64     // unix seconds; ±5 min skew
   }
   ```

   EIP-712 (NOT EIP-191) is REQUIRED because the domain
   separator binds the signature to `(name, version,
   chainId, verifyingContract)`, defeating cross-message /
   cross-surface signature replay. The plaintext-prefix
   EIP-191 personal_sign format used in earlier drafts was
   vulnerable to (a) newline injection in `provider_id`,
   (b) cross-surface replay if any other macprovider EIP-191
   surface ever signs a colliding prefix, (c) confusing UX
   in wallets where the user sees plain text and can't tell
   what they're signing.

   The `verifyingContract` field is the operator's pinned
   `payout.security.hot_wallet_address` (a sentinel — there is no
   smart contract at this step; the address is canonical
   for the domain separator). Pinning to the hot wallet
   means a signature is valid only for the current hot
   wallet; key rotation (§6.4) implicitly invalidates all
   prior signatures, which is the correct behavior.

   `provider_id` MUST match `^[A-Za-z0-9_-]{1,128}$` —
   REJECT 400 `bad_provider_id` on miss. This sanitization
   defeats the newline-injection class even though EIP-712
   structured signing makes raw concatenation moot.

   `nonce` is a fresh 32-byte hex-encoded value (anti-replay
   table below). `ts_utc` MUST be within ±5 minutes of the
   coordinator's clock else REJECT 400 `signature_skew`.

   The coordinator MUST verify the EIP-712 signature using
   the canonical-checksummed address from step 2 as the
   expected signer (`ecrecover(typedDataHash, sig) ==
   canonical_address`) AND verify the typed-data
   `providerId` field equals the URL-path `provider_id`,
   AND verify the typed-data `address` field equals the
   canonical-checksummed address from step 2, AND verify
   the typed-data `chain` field equals the request body's
   `chain` field, AND verify the typed-data `nonce` field
   equals the request body's `nonce` field, AND verify the
   typed-data `tsUtc` field equals the request body's
   `ts_utc` field (unix seconds). REJECT 400
   `signature_mismatch` on ecrecover inequality,
   `providerid_mismatch` on the providerId check,
   `address_mismatch` on the address check,
   `chain_mismatch` on the chain check, `nonce_mismatch`
   on the nonce check, `tsutc_mismatch` on the tsUtc
   check. These field-by-field equality checks make every
   typed-data field operationally load-bearing — a
   typed-data field that isn't verified is decorative and
   lets a captured signature be replayed with a fresh
   body.nonce / body.ts_utc indefinitely (the anti-replay
   table keys on body.nonce and the skew check uses
   body.ts_utc; without typed-data parity, a captured
   signature stays valid forever).

   This defeats registration of an address the registrant
   cannot sign for — closes the stolen-token attack class
   for BOTH first-ever registration AND rotation. The
   provider portal (SPEC-014 v0.9) supplies the signing UX
   via a connected wallet (Coinbase Wallet, Rabby, Safe).
   The curl path (during §9.5 bootstrap before SPEC-014
   v0.9) REQUIRES the provider — NOT the operator — to
   produce the EIP-712 signature and send it to the
   operator out-of-band; the operator MUST NEVER touch the
   provider's private key (this would subvert the entire
   proof-of-possession threat model).

   Replay protection table (IMPL-internal):

   ```sql
   CREATE TABLE IF NOT EXISTS provider_payout_address_nonces (
       canonical_address TEXT NOT NULL,
       nonce             TEXT NOT NULL,
       seen_at_utc       TEXT NOT NULL,
       PRIMARY KEY(canonical_address, nonce)
   );
   CREATE INDEX IF NOT EXISTS idx_ppan_seen ON provider_payout_address_nonces(seen_at_utc);
   ```

   PK is scoped to the canonical signing address, NOT
   `provider_id`. This defeats cross-provider replay where
   an attacker holding a captured signature for one
   provider's registration could replay it under a different
   provider_id (the EIP-712 typed data includes providerId
   so ecrecover would yield a different address anyway, but
   the table-level scoping is defense-in-depth).

   IMPL prunes entries older than 10 MINUTES (== 2× the
   ts_utc skew bound) via a background cleanup. A longer
   retention left an open replay window past the skew
   window; the bound is `min(skew_window, prune_retention)`.

When step 2 rejects a checksum mismatch, the 400 response
body MUST be exactly:

```
HTTP/1.1 400 Bad Request
{ "error": "checksum_mismatch" }
```

The canonical checksummed form is NOT echoed to the caller —
echoing it would let an attacker who tricks a provider into
posting a deliberately-broken attacker-controlled address see
the portal "helpfully" return an EIP-55-cased attacker
address. The canonical form is logged server-side per §3.4.

### 3.3 Registration / rotation endpoint

The handler and the `provider_payout_addresses` CRUD live in
`phase4-coordinator/internal/payout/addresses.go`. `billing/`
reads the table via a thin read-only accessor exposed by
`payout/`. The endpoint mounts on the `:8444` ws-mux listener
(the same listener that hosts `/providers/{id}/earnings` per
`phase4-coordinator/internal/billing/endpoints.go:68` — auth
realm is per-path, NOT per-listener).

IMPL MUST declare every registered handler in a single
`map[path]authRealm` table verified at coordinator startup;
any registered route NOT in the table fails closed (rejects
all requests). EXACT-MATCH patterns only — trailing-slash
prefix routes on `:8444` are FORBIDDEN because Go's stdlib
`http.ServeMux` longest-prefix matching can route a crafted
escaped URL (e.g. `/admin/payout/../providers/x/payouts`) to
an unexpected handler before normalization. IMPL MUST use
`chi`, `gorilla/mux`, or an equivalent router that does not
collapse prefixes — `http.ServeMux` is REJECTED for this
listener at IMPL audit. An IMPL test MUST POST a series of
escaped / dot-segmented URLs and assert each request lands
on the realm the path-table declared.

**Clock authority.** Both `pending_until_utc` (set at
registration) and `:now` (read at §4.3 step 1) MUST come
from the SAME coordinator process clock. The registration
handler and the runner are co-resident in the same
coordinator process per §4.1; IMPL MUST assert this
co-residency at startup (e.g. a deployment-mode check that
fails-fast if the runner is configured to a different
process or host) and MUST NOT honor any clock-skew tolerance
when comparing `pending_until_utc` to `:now`. This makes the
cooling-off boundary non-bypassable by multi-host
deployment expansion.

```
POST /providers/{provider_id}/payout-address
Authorization: Bearer <provider_token>   ; per SPEC-002 §7.3
Content-Type: application/json

{ "chain": "base-mainnet",
  "address": "0xAbC...checksummed",
  "nonce": "0x<64-hex-chars>",
  "ts_utc": 1719234896,
  "signature": "0x<130-hex-chars EIP-712 r||s||v>" }

Response:
  201 Created      — first-ever registration; pending_until_utc
                     = now + 24h (or configured period).
  200 OK           — rotation; pending_until_utc rewritten.
  400 Bad Request  — failed §3.2 validation. Body:
                     { "error": "<one of: bad_format,
                                 checksum_mismatch,
                                 unknown_provider,
                                 denylist,
                                 signature_mismatch,
                                 signature_skew,
                                 nonce_replayed,
                                 missing_field>" }
  401 Unauthorized — invalid / missing provider_token.
  403 Forbidden    — provider_token does not own provider_id.
  409 Conflict     — payout_allowed=0 (operator gate).
  429 Too Many     — provider-scoped rate-limit (default 6/hr).
  503 Service      — runtime.registration_paused == 1 (per §6.4.1
       Unavailable   pause endpoint). Body:
                     { "error": "rotation_in_progress" }.
                     Logged as
                     provider_payout_address_change_rejected with
                     reason="registration_paused" per §7.1. The
                     pause-state check MUST run BEFORE
                     authentication so unauthenticated probes
                     cannot use response-code timing to detect
                     pause state; both unauthenticated and
                     authenticated requests get identical 503
                     bodies during a pause.
```

Authentication is via the per-Mac `provider_token` (same
token SPEC-014 portal uses for `/providers/{id}/earnings`);
the operator key is NOT accepted on this surface (rotations
are provider-initiated only). Every response, including
4xx/5xx, MUST emit a structured log line per §7.1 — a
failed-registration burst is a stolen-token signal.

**TOCTOU pause re-check (NORMATIVE — closes the v0.1.7
single-check gap).** The §6.4.1 pause endpoint can fire
AFTER a §3.3 request passes the pre-auth pause check but
BEFORE the request commits its INSERT/UPDATE on
`provider_payout_addresses`. Without a second check, the
in-flight request would commit a row stamped against the
OLD hot wallet during the rotation window — the exact
stranded-row defect §6.4 step 5 exists to prevent. The
§3.3 IMPL MUST perform TWO pause checks against
`runtime_flags.value WHERE name='registration_paused'`:

1. The existing pre-auth check (returns 503
   `rotation_in_progress` before evaluating
   `provider_token`).
2. A SECOND check inside the SAME `BEGIN IMMEDIATE` SQLite
   transaction that writes the `provider_payout_addresses`
   row. If `value = 1` at this point, the IMPL MUST
   ROLLBACK and return the SAME 503 body. The transaction
   MUST use `BEGIN IMMEDIATE` (not deferred) so the
   pause-flag read takes a write-intent lock against the
   `runtime_flags` row, serialising with any concurrent
   §6.4.1 pause endpoint call against the same SQLite
   connection pool.

The 503 body and `provider_payout_address_change_rejected
reason="registration_paused"` event from BOTH check sites
are identical; the response-code-timing carve-out applies
to both sites symmetrically.

The 24h `pending_until_utc` cooling-off is the v0.1.1
defense against stolen-token + immediate-rotation + backlog-
drain. During the cooling-off, queued `ledger_payout_ready`
rows for this provider continue to use the PREVIOUS address
(or remain `ready` indefinitely if no previous). The portal
MUST surface "address change pending until X" as a banner so
a legitimate provider sees an unexpected rotation in time to
revoke the token. Operator MAY also receive a webhook /
email notification — v0.1 does NOT specify the notification
transport.

### 3.4 Rotation audit

Every successful INSERT or UPDATE MUST emit:

```
event=provider_payout_address_changed
provider_id=<id>
chain=base-mainnet
old_address=<canonical 0x...|none>
new_address=<canonical 0x...>
pending_until_utc=<RFC3339Nano>
actor=provider_token
ts_utc=<RFC3339Nano>
```

`new_address` and `old_address` MUST be the canonicalised
EIP-55 checksummed forms (not the submitted form). The
`pending_until_utc` and `ts_utc` fields in this audit log
are RFC3339Nano formatted strings — the logger stamps the
canonical RFC3339Nano form even though the §3.2 step 5
EIP-712 input takes `tsUtc` as uint64 unix seconds. The
input vs log normalisation lives at the handler boundary
(unix seconds in → RFC3339Nano out). All §7.1 event-table
fields named `ts_utc` are RFC3339Nano.

**Handler writes `registered_against_hot_wallet`.** On
every successful INSERT or UPDATE the handler MUST stamp
`registered_against_hot_wallet =
payout.security.hot_wallet_address` (read from runtime
config — the value loaded at process start and held
immutable per §6.5). The client MUST NOT supply this
field; if present in the request body it MUST be ignored
(do NOT REJECT — silent ignore prevents an attacker from
probing whether the column exists). JSON decoder posture:
the endpoint MUST allow unknown fields by explicit
decode-then-overwrite (the handler decodes into a typed
struct that does NOT include the `registered_against_hot_wallet`
field, then writes the server-side value); IMPL MUST NOT
use `DisallowUnknownFields()` strict mode for this
endpoint specifically — the silent-ignore property is
load-bearing for the probing defense. This value is what
§4.3 step 1 SELECT joins against; mismatch (after a §6.4
rotation) silently routes the row to the "unpayable until
re-registration" bucket. The signing-time `verifyingContract`
field in the EIP-712 typed-data (§3.2 step 5) is the SAME
hot-wallet address, so a signature signed against
verifyingContract=X stays bound to a registration row
stamped `registered_against_hot_wallet=X` — operational
coupling.

Failed registrations emit
`provider_payout_address_change_rejected` with `reason`,
`provider_id`, `src_ip`, `submitted_fingerprint` fields.
`submitted_fingerprint` is
NOT the raw submitted bytes — it is the first 6 + last 4
chars + length of the submitted address string (e.g.
`"0xAbCdEf...1234 len=42"`). Logging the raw bytes was an
info-disclosure + log-injection vector: an attacker
enumerating addresses via the public endpoint would write
attacker-controlled bytes (potentially containing newlines
or ANSI escapes) into operator log infra. The fingerprint
keeps the burst-detection signal (an enumeration burst
still produces N distinct fingerprints with consistent
length) while denying the attacker any controlled-bytes
pivot.

### 3.5 Gate on settlement

A provider with no row in `provider_payout_addresses`, OR
with `payout_allowed=0`, OR with `pending_until_utc >
now()` AND no `rotated_from` predecessor that the runner
could fall back to (first-ever registration during
cooling-off), OR with `registered_against_hot_wallet !=
payout.security.hot_wallet_address` (row registered against
a prior hot wallet pre-§6.4 rotation, awaiting
re-registration per §6.4 step 5), OR whose provider-token
trust state is only tokenless `self_minted` / unverified,
MUST NOT have any payout attempt initiated on their behalf.
Eligible trust states are pinned/operator-issued provider
configuration, a WebSocket session admitted with
`bearer_validated`, or an explicit `self_minted_verified`
proof-of-custody state. Their
`ledger_payout_ready` rows remain in `status='ready'`.

If a rotation is `pending_until_utc > now()` AND
`rotated_from` is set, the runner pays to `rotated_from`
during the cooling-off — the PREVIOUS address remains
canonical until the cooling-off expires.

The portal MUST surface this state per-provider (SPEC-014
v0.9 candidate) and the operator MUST be able to count it
system-wide via §7.4 reconciliation.

## 4 Payout execution loop (FR-P2)

### 4.1 Package layout

IMPL MUST add `phase4-coordinator/internal/payout/`
containing:

- `runner.go` — periodic loop.
- `evm.go` — Base RPC client + ABI encoding for USDC
  `transfer(address,uint256)`.
- `signer.go` — concrete local-file signer at v0.1.2; the
  package-internal `Signer` interface this satisfies (defined
  in §6.3.1) is the seam for the v0.2 KMS substitution
  (§6.6).
- `attempts.go` — `payout_attempts` table CRUD (§4.5).
- `addresses.go` — `provider_payout_addresses` CRUD + the
  §3.3 handler (§3 entirety).
- `funding.go` — `payout_hot_wallet_funding` CRUD + the
  `/admin/payout/record-funding` handler (§4.9).
- `orphans.go` — `payout_reorg_orphans` CRUD + the
  `/admin/payout/record-orphan` handler (§4.7).

**Cross-package boundary (billing/ ↔ payout/).** `billing/`
MUST NOT import `payout/`. Cross-package address reads from
`billing/` (if any) MUST go through a `PayoutAddressReader`
interface DECLARED in `billing/` and SATISFIED by a thin
adapter in `payout/`, wired in `main.go`. The interface
exposes exactly:

```go
type PayoutAddressReader interface {
    LookupPayoutAddress(ctx context.Context, providerID, chain string) (address string, payoutAllowed bool, err error)
}
```

`payout/` is permitted to import `billing/` for the
`ClaimPayoutReady` call (§4.3 step 8). The direction is
strictly one-way: `payout/ → billing/`, never the reverse.
IMPL audit MUST include an import-graph test asserting
this.

The runner starts from `cmd/coordinator/main.go` only when
config explicitly enables it (`payout.enabled: true`).
Default config ships `payout.enabled: false`.

### 4.2 Cadence

- Default cadence: every 6 hours.
- Configurable via `payout.tuning.run_interval` (Go duration, min 5
  minutes at config-parse).
- Operator MAY trigger a single immediate run via
  `POST /admin/payout/run-now` on the `:8444` listener
  (operator-key authenticated). Endpoint MUST be idempotent
  within an in-flight run (return 409 if one is active) AND
  rate-limited via `payout.tuning.run_now_min_interval` (default
  60s — defends against a tight-loop CPU/RPC DoS by an
  operator-key holder; return 429 if invoked sooner than the
  interval). Every invocation emits `payout_run_now_invoked`
  per §7.1.

### 4.3 Per-run algorithm

For each scheduled run, the loop MUST execute IN ORDER, exiting
any step on error and logging structurally:

1. **Select.**

   ```sql
   SELECT lpr.id, lpr.provider_id, lpr.gross_credits,
          lpr.provider_credits, lpr.window_start_utc,
          lpr.window_end_utc,
          CASE WHEN ppa.pending_until_utc IS NOT NULL
                AND ppa.pending_until_utc > :now
               THEN ppa.rotated_from
               ELSE ppa.address END AS effective_address
     FROM ledger_payout_ready lpr
     INNER JOIN provider_payout_addresses ppa
       ON ppa.provider_id = lpr.provider_id
      AND ppa.chain = 'base-mainnet'
      AND ppa.payout_allowed = 1
      AND ppa.registered_against_hot_wallet = :hot_wallet
    WHERE lpr.status = 'ready'
      AND (ppa.pending_until_utc IS NULL
           OR ppa.pending_until_utc <= :now
           OR ppa.rotated_from IS NOT NULL)
    ORDER BY lpr.id ASC
    LIMIT :max_rows_per_run;
   ```

   The `registered_against_hot_wallet = :hot_wallet` clause
   excludes rows that were registered against a prior hot
   wallet (pre-§6.4 rotation). Such rows wait until the
   provider re-registers against the current hot wallet
   (operator notifies via §5a channel during rotation).

   The outer `COALESCE(..., ppa.address)` was REMOVED in
   v0.1.2: for first-ever registration during cooling-off the
   CASE returns NULL, but that row is already excluded by the
   WHERE `rotated_from IS NOT NULL`. The COALESCE was a
   defense-in-depth in the WRONG direction — if the WHERE
   ever loosened, the SELECT would silently pay to the
   pending-but-uncooled-off address. IMPL MUST treat a NULL
   `effective_address` as a hard error (skip + log
   `payout_invariant_violation`) — it can never legally
   appear given the WHERE clause.

   `gross_credits` MUST be in the projection because step 8
   passes it to `ClaimPayoutReady`. `max_rows_per_run`
   default 50. The cooling-off + rotated_from fallback (§3.5)
   is encoded directly in the JOIN + WHERE.

2. **Per-row amount.** USDC amount in base units (6 decimals)
   equals `provider_credits` exactly. SPEC-005 §5.1 locks
   1 credit = 1 USD micro-dollar = 10⁻⁶ USD, and USDC on Base
   uses 6 decimals; the conversion is a unit identity, not a
   rate lookup. IMPL MUST hardcode this identity and MUST
   reject (log + skip) any configuration that introduces a
   multiplier.
3. **Singleton-runner lease (NORMATIVE — closes the multi-
   process double-attempt class).** Steps 4–5 (cap re-check,
   attempt lookup, nonce allocation, attempt persistence)
   MUST run under THREE compound guards:

   (a) **DB-backed singleton runner lease.** The IMPL MUST
   hold a row in the `payout_runner_lease` table (schema
   in §4.8b) for the duration of every cadence cycle. Lease
   acquire, takeover, and heartbeat semantics are
   normatively pinned in §4.8b (codex round-10 MAJOR-2
   closure). Before executing ANY of step 4–5, the IMPL
   MUST re-read its own `holder_token` from the lease row
   inside the same `BEGIN IMMEDIATE` transaction as step
   3(b) below; if the token has changed (i.e. another
   process took over), the current process MUST self-halt
   the cycle and emit `payout_runner_lease_lost` per
   §7.1 (severity=PAGE). v0.1.18 (codex round-11 LOW-1
   closure): the prior wording used
   `payout_runner_lease_conflict` here, but that event
   semantically signals lease-ACQUIRE failure (per §4.8b
   acquire algorithm), not post-acquire token loss; the
   correct event for self-fencing detection is
   `payout_runner_lease_lost`. The token comparison is
   the "self-fencing" check that protects against the
   classic stop-the-world-GC-then-resume scenario.

   (b) **Per-attempt `BEGIN IMMEDIATE` transaction.** A
   single SQLite transaction spans the §5 cap re-read
   (using the reservation-aware query from §5.3 NEW v0.1.9
   which counts live reserved attempts, NOT just
   broadcasts), the §4.8b lease-token re-read, nonce
   allocation, and `payout_attempts` INSERT (step 4–5). On
   COMMIT, the row is observable by every other reader.
   The `BEGIN IMMEDIATE` mode (not `BEGIN DEFERRED`) is
   required so the txn takes a write lock at start, not at
   first write — this serialises against any concurrent
   §4.3 cycle attempting the same payout_id even if the
   lease guard is bypassed.

   (c) **DB-side belt-and-suspenders partial UNIQUE
   INDEX.** The `idx_pa_one_live_non_cancel_per_payout`
   index (defined in §4.5) forces the second INSERT to
   fail with `UNIQUE constraint violation` even if both
   guards (a) and (b) are bypassed. IMPL MUST catch and
   abort the run with
   `payout_invariant_violation where='duplicate live attempt'`
   plus halt the runner pending operator forensic review.

   The three guards compose: (a) prevents two processes
   from starting the cycle; (b) prevents two cycles within
   one process from racing; (c) catches any residual
   bypass at the DB layer. Any one defense holding stops
   the double-spend.
4. **Cap check.** Apply §5 caps. If the row's amount exceeds
   per-payout cap, OR cumulative paid + broadcast amount this
   24h window would exceed per-day cap, skip the row and
   emit `payout_capped`. The row remains `ready` for a
   future run.
5. **Attempt record (PROVIDER-PAYOUT attempts only).**
   v0.1.13 (codex round-14 MAJOR-1 closure): the lookup
   MUST filter to provider-payout attempts ONLY — cancel
   self-transfer rows (`is_cancel_self_transfer = 1`) are
   nonce-gap recovery records and MUST NEVER be confused
   with provider-payout attempts:

   ```sql
   SELECT * FROM payout_attempts
    WHERE payout_id = :payout_id
      AND abandoned_at_utc IS NULL
      AND is_cancel_self_transfer = 0
    ORDER BY attempt_seq DESC
    LIMIT 1;
   ```

   - If confirmed-and-non-abandoned, jump to step 8.
   - If pending (broadcast but not confirmed), jump to
     step 7 to poll.
   - If none exists, FIRST run the cancel-handling
     pre-check below; only AFTER it confirms that no live
     cancel self-transfer is blocking, generate a fresh
     nonce per §4.6 and a new `attempt_seq` (next integer
     for this payout_id), assert the C3 money-conservation
     pre-INSERT invariant below, then INSERT the row into
     `payout_attempts` (the
     `idx_pa_one_live_non_cancel_per_payout` partial
     UNIQUE INDEX from §4.5 enforces at-most-one live
     non-cancel row per payout_id at the DB layer), then
     COMMIT the `BEGIN IMMEDIATE` transaction from step 3.

   **C3 money-conservation pre-INSERT invariant
   (NORMATIVE — v0.1.20 round-20 closure).** Inside the
   `BEGIN IMMEDIATE` transaction from step 3 — BEFORE the
   `INSERT` on `payout_attempts` — the IMPL MUST assert
   `amount_base_units == lpr.provider_credits` (both
   INTEGER, USDC base units, no implicit coercion). The
   `lpr.provider_credits` value MUST be re-read inside
   this transaction from `ledger_payout_ready` by
   `payout_id`, NOT trusted from the §4.3 step 1 SELECT
   (which is outside this txn). On mismatch the IMPL
   MUST `ROLLBACK`, emit
   `payout_invariant_violation where='amount_credit_mismatch'`
   per §7.1 (severity=PAGE) with fields
   `(payout_id, lpr_provider_credits,
     computed_amount_base_units, attempt_seq)`,
   and HALT the runner pending operator forensic review.
   Rationale: §4.3 step 2 prose locks
   `amount_base_units = provider_credits` as a unit
   identity, but SPEC-005's `ClaimPayoutReady` only
   validates `gross_credits` — any future code path or
   refactor that lets `amount_base_units` drift from
   `provider_credits` passes the `ClaimPayoutReady`
   gross-check and burns operator USDC; the per-provider
   §7.4 query (A) catches the drift only AFTER
   `UPDATE … SET status='consumed'` has fired. Asserting
   the identity at the write site closes the window. The
   `where='amount_credit_mismatch'` enum value is added
   to §7.1's `payout_invariant_violation` enum table.

   **Cancel-handling pre-check (NORMATIVE — closes
   codex round-14 MAJOR-1's confused-deputy class).**
   Before allocating a fresh non-cancel attempt, the
   runner MUST query for live cancel self-transfer rows
   for the same `payout_id`:

   ```sql
   SELECT attempt_seq, nonce, raw_signed_tx,
          broadcast_at_utc, confirmed_at_utc
     FROM payout_attempts
    WHERE payout_id = :payout_id
      AND is_cancel_self_transfer = 1
      AND abandoned_at_utc IS NULL
    ORDER BY attempt_seq ASC;
   ```

   For each row returned:

   - **Unbroadcast** (`broadcast_at_utc IS NULL`): the
     persisted bytes are from a prior cycle that crashed
     between persist and broadcast. The runner MUST
     rebroadcast the persisted `raw_signed_tx`
     bit-for-bit (re-signing FORBIDDEN per §4.6) on both
     RPCs and stamp `broadcast_at_utc = now()`. Then poll
     for confirmation via §4.3 step 7 — BUT using
     cancel-specific verification (see below), NOT the
     standard provider-payout verification.

   - **Broadcast, unconfirmed**
     (`broadcast_at_utc IS NOT NULL AND confirmed_at_utc
     IS NULL`): poll via §4.3 step 7 with cancel-specific
     verification.

   - **Confirmed** (`confirmed_at_utc IS NOT NULL`): the
     nonce gap is filled. The IMPL MUST:
     - emit `payout_cancel_self_transfer_confirmed`
       per §7.1 (severity=INFO) with fields
       `(run_id, payout_id, attempt_seq, nonce, tx_hash,
       block_number, gas_used_native_wei, ts_utc)` —
       **but ONLY on the transition** from
       `confirmed_at_utc IS NULL` to non-NULL (v0.1.15
       codex round-16 MED-1 closure). Specifically, the
       event MUST be emitted by the SAME §4.3 cycle that
       runs the UPDATE setting `confirmed_at_utc =
       <observed_at>` after passing cancel-specific §4.3
       step 7 verification. The transition UPDATE MUST
       also clear `cancel_reconfirm_stale_paged_at_utc =
       NULL` (v0.1.16 codex round-17 MED-1 closure) so
       any future §4.7 reorg-reactivation can correctly
       re-arm the once-per-stale-transition PAGE
       suppression marker. A later pre-check that loads
       an already-confirmed cancel row MUST NOT re-emit
       this event (otherwise an INFO log would fire every
       cycle until fresh non-cancel allocation makes
       progress — breaks the "per-cancel-confirmation"
       contract and creates log spam). §7.4 query (D) is
       the crash-recovery canonical roll-up if the process
       dies between the DB UPDATE commit and the INFO
       log emit (the DB row IS the canonical record;
       the event is a notification view).
     - NOT call `ClaimPayoutReady` (cancel rows do NOT
       consume `ledger_payout_ready`).
     - NOT modify `ledger_payout_ready` in any way.
     Proceed to fresh non-cancel allocation.

   If ANY cancel row is in the unbroadcast or
   broadcast-unconfirmed state, the runner MUST HALT
   fresh non-cancel allocation for this `payout_id`
   until either the cancel confirms OR the operator
   resolves the nonce gap via
   `/admin/payout/abandon-attempt` (which itself
   requires the runner-active gate per §4.6). The HALT
   does NOT emit `payout_invariant_violation` — a
   live cancel is a legitimate state.

   **Cancel-specific chain-side verification (NORMATIVE).**
   When confirming a cancel self-transfer in §4.3 step 7,
   the chain-side value verification uses DIFFERENT
   constants than the provider-payout case:
   - `tx.to` MUST equal `payout.security.hot_wallet_address`
     (NOT the USDC contract — cancels are native ETH
     self-transfers at the same nonce; the calldata is
     empty and `value = 1 base unit` per §4.6
     `amount_base_units = 1`).
   - There is NO Transfer log to verify (no ERC-20
     transfer occurred).
   - The recovered sender still MUST equal
     `payout.security.hot_wallet_address`.
   - On confirmation, do NOT call `ClaimPayoutReady`;
     do NOT pass the cancel `tx_hash` to anything that
     consumes `ledger_payout_ready`. Cancel rows are
     audit/gas records only.

   Any mismatch on the above emits
   `payout_chain_value_mismatch
   mismatch_class='cancel_self_transfer_mismatch'`
   (NEW v0.1.13 enum value) and HALTs.

   **Why this matters (money-OUT defect class).** Without
   the filter + pre-check + cancel-specific verification,
   a cold IMPL could literally implement "load any
   non-abandoned attempt, if confirmed jump to step 8"
   and pass a confirmed CANCEL self-transfer's `tx_hash`
   to `ClaimPayoutReady`, consuming the provider's
   `ledger_payout_ready` row without ever paying the
   provider. §7.4 reconciliation queries already exclude
   `is_cancel_self_transfer = 1` from outflow sums, so
   the misclassification would NOT trip the drift alarm
   — silent provider loss.
6. **Build + sign + verify-pre-broadcast + persist + broadcast.**
   Build USDC `transfer(to, amount)` calldata; build EIP-1559
   tx with hot-wallet sender, the computed nonce, chain id
   8453, USDC contract as `to`; sign via the `Signer`
   interface (§6.3).

   **Pre-broadcast Signer-output verification (NORMATIVE —
   closes codex round-10 MAJOR-1).** AFTER `SignTx` returns
   and BEFORE persisting `raw_signed_tx` or invoking
   `eth_sendRawTransaction`, the IMPL MUST locally decode
   the returned `rawSignedTx` and assert ALL of the
   following match the unsigned tx the runner built:
   - `nonce` equals the runner-computed nonce
   - `chain_id` equals 8453 (Base mainnet)
   - `to` equals the configured USDC contract address
     (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`)
   - `value` equals 0 (USDC transfer carries amount in
     calldata, not in the tx value field)
   - `input` (calldata) is byte-equal to the runner-built
     calldata (`0xa9059cbb` selector + abi.encode(
     effective_address, amount_base_units))
   - `max_priority_fee_per_gas` and `max_fee_per_gas` are
     within the bounds the runner computed
   - locally recompute `tx_hash` from the signed envelope
     and assert it equals the `txHash` the Signer returned
   - locally `ecrecover` the signature and assert the
     recovered address equals
     `payout.security.hot_wallet_address` (NOT just trust
     `Signer.FromAddress()` — a compromised Signer could
     return a tx signed by a different key while
     advertising the right `FromAddress`)

   Any mismatch HALTS the runner BEFORE broadcast, emits
   `payout_chain_value_mismatch mismatch_class='prebroadcast_signed_tx'`
   per §7.1 (severity=PAGE), and pages the operator. The
   pre-broadcast check defeats a Signer-compromise class
   that the §4.3 step 7 chain-side verification only
   catches AFTER funds move; the pre-broadcast check
   stops the attack pre-flight.

   THEN persist `raw_signed_tx` AND its computed `tx_hash`
   on the `payout_attempts` row via a `BEGIN IMMEDIATE`
   compare-and-set (CAS) — **NORMATIVE per codex round-11
   MAJOR-2 closure**:

   ```sql
   BEGIN IMMEDIATE;
     -- 1. Re-read the lease holder_token in this txn.
     SELECT holder_token FROM payout_runner_lease WHERE id = 1;
     -- If returned value != <this process's acquired token>:
     -- ROLLBACK, discard the just-signed envelope (do NOT
     -- broadcast, do NOT persist), emit
     -- payout_runner_lease_lost per §7.1 (severity=PAGE),
     -- and self-halt. The newly-elected lease holder will
     -- restart the §4.3 cycle from step 1 against fresh
     -- ledger state.
     --
     -- 2. CAS-persist the signed envelope ONLY if
     --    raw_signed_tx is still NULL (no other process or
     --    prior iteration has already persisted bytes for
     --    this attempt row).
     UPDATE payout_attempts
        SET raw_signed_tx = :raw_signed_tx,
            tx_hash       = :computed_tx_hash,
            updated_at_utc = :now
      WHERE payout_id = :payout_id
        AND attempt_seq = :attempt_seq
        AND raw_signed_tx IS NULL
        AND confirmed_at_utc IS NULL
        AND abandoned_at_utc IS NULL;
     -- v0.1.11 (codex round-12 MAJOR-1 closure): the CAS
     -- predicate now ALSO requires confirmed_at_utc IS NULL
     -- AND abandoned_at_utc IS NULL. Without these, an
     -- operator-key holder racing
     -- /admin/payout/abandon-attempt against the runner's
     -- signing phase could mark the attempt abandoned and
     -- broadcast a cancel tx at the same nonce, then the
     -- runner could still CAS-persist + broadcast the
     -- original — producing two competing txs at the same
     -- nonce. The new gated predicate + the §4.6
     -- runner-active rejection (below) close this race
     -- from both sides.
     --
     -- If row count = 0, IMPL MUST re-read the row in the
     -- same txn to disambiguate:
     --   - no row exists: should be impossible (FK on
     --     payout_runner_lease + §4.3 step 3-5 just
     --     INSERTed it); emit
     --     payout_invariant_violation
     --     where='attempt_row_missing_during_sign'
     --     + ROLLBACK + halt.
     --   - row exists, abandoned_at_utc IS NOT NULL OR
     --     confirmed_at_utc IS NOT NULL: state changed
     --     during sign (concurrent abandon, or confirm
     --     races for an already-broadcast attempt). Discard
     --     the just-signed envelope (do NOT broadcast, do
     --     NOT log the raw signed bytes — see
     --     side-channel discipline below), emit
     --     payout_invariant_violation
     --     where='attempt_state_changed_during_sign'
     --     detail='<abandoned|confirmed>'
     --     per §7.1 (severity=PAGE), ROLLBACK + halt.
     --   - row exists, raw_signed_tx IS NOT NULL: bytes
     --     already exist (prior cycle iteration or peer
     --     process persisted them). Discard the just-signed
     --     envelope and use the existing persisted bytes
     --     for the rebroadcast below; re-signing is
     --     FORBIDDEN per §4.6 nonce discipline.
   COMMIT;
   ```

   **Side-channel discipline (NORMATIVE).** The
   "discard the just-signed envelope" paths MUST NOT log
   the `raw_signed_tx` bytes, the `tx_hash` of the
   discarded envelope, or any timing measurement of the
   sign+CAS critical section. A log line that contains
   the discarded `tx_hash` would let an attacker who can
   read journalctl correlate which nonces have already
   been signed (useful for replay-mempool attacks).
   `payout_invariant_violation` event fields are limited
   to `(payout_id, attempt_seq, where, detail, ts_utc)`;
   the bytes never leave process memory before zeroization.

   The CAS pattern closes the codex round-11 MAJOR-2 gap:
   without it, a runner that passes the pre-step-6 token
   read, stalls past the stale window, gets taken over, then
   resumes could sign + persist + broadcast a *different*
   envelope at the same nonce than the newly-elected holder.
   With nondeterministic ECDSA, both envelopes have valid
   signatures and matching ecrecover'd senders, so the §4.3
   step 7 chain-side verification would pass either one —
   but DB receipt tracking can then chase the wrong
   `tx_hash` after funds moved.

   AFTER COMMIT (and before broadcast), the IMPL MUST
   re-read the lease holder_token ONE MORE TIME (standalone
   read; no txn required) and assert it still equals the
   acquired token. If lost between COMMIT and this final
   read: do NOT broadcast the persisted bytes — emit
   `payout_runner_lease_lost` and self-halt. The newly-
   elected holder will pick up the row via §4.3 step 5's
   "pending (broadcast but not confirmed) → jump to step 7
   to poll" path AND the §4.5 retry path: bytes are
   persisted with `broadcast_at_utc IS NULL`, the new
   holder re-broadcasts the EXISTING bytes via
   `eth_sendRawTransaction` (re-signing FORBIDDEN), then
   stamps `broadcast_at_utc = now()` in a follow-up update.

   ONLY if the post-COMMIT lease check passes, the current
   holder invokes `eth_sendRawTransaction` on BOTH RPCs and
   stamps `broadcast_at_utc = now()` on the row. A process
   crash between persistence and broadcast leaves the row
   eligible for retry (§4.5) without nonce loss; the next
   holder picks up the persisted bytes and rebroadcasts.
7. **Confirm via TWO independent RPCs (with chain-side
   value verification).** Poll both configured RPCs (§9.2)
   until both return a receipt at depth ≥
   `payout.tuning.confirmation_blocks` (default 5; bounds
   `[5, 200]` per §payout.tuning hard floors — v0.1.20
   round-20 M2 closure widened bounds from `[2, 50]`). The
   TWO receipts MUST agree on:
   - `tx_hash`
   - `block_hash` (NEW in v0.1.8 — closes the
     same-block-hash-different-block-content reorg gap)
   - `block_number`
   - `status` (success — `0x1`)
   - `to` (must equal the configured USDC contract address
     for chain id 8453, i.e. `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`)

   **Chain-side value verification (NORMATIVE — closes the
   "tx succeeds but no USDC transferred" defect).** The
   receipt `to == USDC contract` is necessary but NOT
   sufficient — a calldata bug, ABI-encoding mismatch, or
   compromised Signer can produce a successful tx that
   does NOT transfer `amount_base_units` to
   `effective_address`. The runner MUST additionally
   verify on BOTH RPC receipts:

   (a) **Transaction input matches the expected ABI
   calldata.** Fetch the full transaction (not just the
   receipt) via `eth_getTransactionByHash` on each RPC and
   assert `tx.input` is byte-equal to the concatenation
   `0xa9059cbb || abi.encode(address, uint256)` (i.e.
   exactly 68 bytes: 4-byte selector + 32-byte
   left-padded address + 32-byte uint256 amount), where
   `address = effective_address` (left-padded to 32
   bytes) and `uint256 = amount_base_units` (big-endian
   uint256). The 4-byte selector `0xa9059cbb` is the
   keccak256 prefix of `transfer(address,uint256)` and is
   fixed across all ERC-20 tokens; the IMPL MUST reject
   any other selector AND reject any `tx.input` length
   other than exactly 68 bytes.

   (b) **Recovered sender equals the hot wallet.** Recover
   the `from` address from the tx signature (or trust the
   RPC's `tx.from` field IF both RPCs agree on it) and
   assert it equals `payout.security.hot_wallet_address`.

   (c) **Exactly one matching Transfer log.** Iterate the
   receipt's `logs` array and assert exactly ONE log
   matches:
   - `log.address == USDC contract address`
   - `log.topics[0] == keccak256("Transfer(address,address,uint256)")`
     (the fixed value
     `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef`)
   - `log.topics[1] == hot_wallet_address` (left-padded
     to 32 bytes)
   - `log.topics[2] == effective_address` (left-padded
     to 32 bytes)
   - `abi.decode(log.data, uint256) == amount_base_units`

   The "exactly one" requirement defeats a malicious USDC-
   contract-upgrade or sandwich-attack pattern where the
   receipt contains multiple Transfer logs and the intended
   amount lands elsewhere. Any disagreement between RPCs on
   any of the above fields, or any mismatch on the
   expected values, HALTS the runner, emits
   `payout_chain_value_mismatch` per §7.1 (NEW event,
   severity=PAGE), and pages the operator. A mismatch is
   stronger evidence of compromise than a §7.4 drift alarm —
   it means the signed tx body or the broadcast path is
   wrong, not that the wallet is being skimmed externally.

   Single-RPC trust is REJECTED at v0.1 — the originating
   prompt's "MAY assume single RPC" is superseded.

8. **Claim.** Call
   `ClaimPayoutReady(ctx, payoutID, expectedGrossCredits,
   payoutExternalID, "USDC-BASE")` at
   `phase4-coordinator/internal/billing/payout.go:10`.
   Signature is
   `(ctx context.Context, payoutID int64, expectedGrossCredits int64, payoutExternalID, payoutCurrency string) (bool, error)`.
   `expectedGrossCredits` MUST be `lpr.gross_credits` from
   step 1 (NOT `provider_credits`). `payoutExternalID` MUST
   be the agreed tx hash from step 7. `payoutCurrency` MUST
   be the literal string `"USDC-BASE"` (never empty, never
   NULL). IMPL MUST add a unit test asserting the literal is
   passed; the §7.4 reconciliation surfaces a NULL
   `payout_currency` on a `consumed` row as a separate
   failure class to catch any regression.
9. **Log.** Emit `payout_paid` per §7.1. On failure in
   steps 6-8, emit `payout_failed` with `stage` and
   `error_class`.

### 4.4 RPC failure tolerance + key/trust separation

The runner MUST tolerate transient RPC errors at steps 6/7:

- Step 6 broadcast failure on either RPC → retry up to N
  times (default 3) with exponential backoff. If at least
  ONE RPC confirms acceptance into its mempool, the
  broadcast is treated as successful for the purposes of
  step 7 polling. If both RPCs reject (e.g. nonce too low,
  insufficient funds, malformed envelope), leave the row
  pending; the next run cycle retries via step 5.
- Step 7 receipt-poll: if ONE RPC returns confirmed and the
  OTHER returns "not found" past a tolerance window
  (default 2 minutes), emit `payout_rpc_disagreement` and
  HALT — silent disagreement is the lying-RPC threat model.

The runner MUST NOT advance to step 8 without TWO-RPC
agreement on a confirmed receipt AND chain-side value
verification per step 7 (a/b/c).

**RPC trust separation requirements** (defense against the
case where both RPC endpoints are subverted in tandem —
DNS hijack on operator resolver, shared TLS trust-store
compromise, single secrets-store breach):

1. The two RPC URLs + keys MUST be loaded from SEPARATE
   secrets paths. Single-config-file with both keys is
   FORBIDDEN. Acceptable: two distinct systemd
   `LoadCredential=` entries; two distinct env-vars under
   different prefixes (`PAYOUT_RPC_PRIMARY_*` and
   `PAYOUT_RPC_SECONDARY_*`).
2. The two RPC hostnames SHOULD resolve via different DNS
   chains where the operator's infrastructure allows.
3. Optional TLS certificate-pinning via
   `payout.tuning.rpc_url_primary_pin_spki` /
   `payout.tuning.rpc_url_secondary_pin_spki` config keys (SHA-256
   of the SubjectPublicKeyInfo); when set, the runner MUST
   verify the served cert chain anchors to the pinned SPKI
   and reject otherwise. v0.1.2 makes the keys OPTIONAL but
   the configurability hooks are normative.
4. `payout.security.chain_recon_interval` default is 1 HOUR (NOT
   24h — earlier default would give an attacker who fakes
   both RPC receipts a 24-hour drain window before the
   on-chain `balanceOf` discrepancy is detected).
5. `payout.security.chain_recon_tolerance_usdc_base_units` default
   is `100_000` (== $0.10) — the smallest plausible
   per-payout amount; any drift above this is paged.

### 4.5 Per-row attempt table (deterministic retry)

```sql
CREATE TABLE IF NOT EXISTS payout_attempts (
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL CHECK(attempt_seq >= 1),
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    from_address     TEXT NOT NULL,
    to_address       TEXT NOT NULL,
    amount_base_units INTEGER NOT NULL CHECK(amount_base_units > 0),
    nonce            INTEGER NOT NULL CHECK(nonce >= 0),
    raw_signed_tx    BLOB NULL,
    tx_hash          TEXT NULL,
    broadcast_at_utc TEXT NULL,
    confirmed_at_utc TEXT NULL,
    block_number     INTEGER NULL,
    gas_used_native_wei INTEGER NULL,
    is_cancel_self_transfer INTEGER NOT NULL DEFAULT 0 CHECK(is_cancel_self_transfer IN (0,1)),
    last_error       TEXT NULL,
    abandoned_at_utc TEXT NULL,
    abandoned_reason TEXT NULL,
    -- v0.1.16 (codex round-17 MED-1 closure): durable
    -- suppression marker for the §4.7 cancel-reorg
    -- reconfirm-stale PAGE event. Persistent across
    -- coordinator restart so an unresolved stale cancel
    -- does NOT re-page after every restart. NULL =
    -- not-stale OR newly-reactivated by §4.7 reorg;
    -- non-NULL = stale-paged at the recorded timestamp
    -- (suppress further pages until §4.3 confirmation
    -- clears it back to NULL).
    cancel_reconfirm_stale_paged_at_utc TEXT NULL,
    updated_at_utc   TEXT NOT NULL,
    PRIMARY KEY(payout_id, attempt_seq)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_from_nonce_active
    ON payout_attempts(from_address, nonce)
 WHERE abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_unconfirmed
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_confirmed_recent
    ON payout_attempts(confirmed_at_utc)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_broadcast_recent
    ON payout_attempts(broadcast_at_utc)
 WHERE broadcast_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_cancel_recent
    ON payout_attempts(broadcast_at_utc)
 WHERE is_cancel_self_transfer = 1 AND broadcast_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_one_active_per_payout
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0;
-- v0.1.8: at-most-one LIVE (not necessarily confirmed) non-cancel
-- attempt per payout_id — defense against the §4.3-step-3
-- singleton-lease bypass class (multi-process race, run-now +
-- cadence overlap). Without this, two pending attempts at
-- different nonces can both pay the chain before either claim
-- consumes the ledger row.
CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_one_live_non_cancel_per_payout
    ON payout_attempts(payout_id)
 WHERE abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0;
```

`gas_used_native_wei` is populated post-confirmation from
the receipt; it powers the §6.2 aggregate cancel-gas-burn
visibility (`cancel_gas_native_wei_24h`).

The `(payout_id, attempt_seq)` PK lets a payout_id have
multiple attempt rows (the original payout attempt, plus any
cancel self-transfers, plus any post-abandon fresh attempts).

Two partial UNIQUE indexes provide complementary defenses:

- `idx_pa_one_active_per_payout` (existing): at-most-one
  CONFIRMED non-cancel non-abandoned row per payout_id —
  the post-confirmation double-spend guarantee at the
  application layer; the chain nonce is the on-chain
  guarantee.
- `idx_pa_one_live_non_cancel_per_payout` (NEW in v0.1.8,
  closes codex round-9 CRIT-2): at-most-one LIVE
  (not yet abandoned) non-cancel row per payout_id —
  the pre-confirmation double-spend guarantee. Without
  this, two §4.3 cadence cycles racing (multi-process
  deploy bug, run-now + cadence overlap) could both
  INSERT pending attempts at DIFFERENT nonces, broadcast
  both, and have BOTH chain transfers confirm before
  either `ClaimPayoutReady` lands. The new index forces
  the second INSERT to fail with `UNIQUE constraint
  violation`; IMPL MUST catch and halt the runner with
  `payout_invariant_violation where='duplicate live attempt'`.
  Abandon-then-retry is unaffected: the abandon-marker
  trigger sets `abandoned_at_utc` IS NOT NULL, lifting
  the original row out of the index's WHERE clause, and a
  fresh attempt INSERT succeeds with a new `attempt_seq`.

The `idx_pa_from_nonce_active` partial UNIQUE index requires
`abandoned_at_utc IS NULL`, so an abandon-then-cancel flow
can re-use the same nonce in a fresh row after the abandon
row is flagged in the same transaction. An unconditional
UNIQUE would make the §4.6 cancel-self-transfer insert at
the original nonce impossible. The chain itself enforces
real on-chain nonce uniqueness (only one tx per nonce can
confirm).

`is_cancel_self_transfer = 1` rows are emitted by
`/admin/payout/abandon-attempt` (§4.6) — they consume gas and
count toward the §5 day cap but are NOT a payout to a
provider.

The `chain` CHECK matches the §3.1 canary; a multi-rail
expansion must amend BOTH constraints.

The signed tx envelope itself is persisted in `raw_signed_tx`
BEFORE broadcast in step 6; on retry IMPL MUST rebroadcast
the exact bytes. Re-signing is FORBIDDEN.

### 4.6 Nonce strategy + abandon

- IMPL maintains a `wallet_nonce_cursor` (single row, single
  column) per `from_address`. At runner startup it MUST sync
  the cursor by querying `getTransactionCount(pending)` from
  BOTH RPCs. The two MUST agree within ±1; difference >1
  halts the runner and pages the operator
  (`payout_rpc_disagreement` per §7.1, reason=
  `nonce_cold_start_mismatch`). The cursor is set to
  `max(cursor_in_db, max(rpc_a, rpc_b))`. A lying RPC
  returning a too-high nonce would silently force every
  fresh attempt to fail at broadcast against the honest RPC
  until §7.4 catches the drift — the ±1 check at cold-start
  closes that stealth-DoS window. Even within tolerance,
  any disagreement (`rpc_a != rpc_b`) MUST emit
  `payout_nonce_cold_start_within_tolerance` per §7.1 with
  both RPC values, so a 1-off lying-RPC signal is not silently
  absorbed.
- On fresh-attempt allocation, claim the next nonce
  atomically. Persist `(payout_id, attempt_seq, nonce)` in
  `payout_attempts` BEFORE signing.
- On retry of an existing non-abandoned attempt, REUSE the
  persisted nonce + `raw_signed_tx` (re-broadcast verbatim).
- Nonce gaps (an abandoned `payout_attempts` row that was
  never confirmed) MUST be filled with an explicit 0-value
  self-transfer at the same nonce before subsequent payouts
  can use higher nonces. v0.1.1 ships the operator-driven
  recovery path:

  ```
  POST /admin/payout/abandon-attempt
  Authorization: Bearer <operator_key>
  Content-Type: application/json
  Idempotency-Key: <opaque>

  { "payout_id": 123,
    "attempt_seq": 1,
    "broadcast_cancel_self_transfer": true,
    "confirm": true,
    "tip_multiplier": 2.0,
    "reason": "free-text required (logged)" }

  Response:
    200 OK   — atomic transaction completed: abandoned_at_utc
               + abandoned_reason set on the original row;
               if broadcast_cancel_self_transfer=true, a new
               payout_attempts row with attempt_seq+1 is
               INSERTed (same transaction) with
               is_cancel_self_transfer=1,
               to_address = from_address = payout.security.hot_wallet_address,
               amount_base_units = 1 (cheapest
               §4.5-CHECK-compatible value; 1 base unit ==
               $0.000001), original nonce, capped tip; the
               cancel tx is signed in-tx and persisted with
               raw_signed_tx + tx_hash. v0.1.14 (codex
               round-15 MAJOR-1 closure):
               broadcast_at_utc MUST be persisted as NULL at
               INSERT time, NOT set to :now. (v0.1.13 and
               earlier stamped broadcast_at_utc BEFORE
               COMMIT, which made a row look broadcast even
               if the post-COMMIT eth_sendRawTransaction
               crashed or both RPCs rejected — the §4.3
               cancel-handling pre-check then misclassified
               it as "broadcast, unconfirmed" and only
               polled, never rebroadcasting.) broadcast_at_utc
               is stamped via a CAS UPDATE post-broadcast (see
               below). The DB transaction MUST use
               `BEGIN IMMEDIATE` so the partial-UNIQUE-INDEX
               check on (from_address, nonce) is serialised
               against concurrent abandons; default
               `BEGIN DEFERRED` permits the SQLite writer
               race that would break atomicity. After
               COMMIT, the runner MUST:

               (1) Run cancel-broadcast preflight verification
               (NORMATIVE v0.1.14): locally decode the
               persisted raw_signed_tx and assert
               `nonce == payout_attempts.nonce`,
               `chain_id == 8453`,
               `to == payout.security.hot_wallet_address`,
               `value == 1 wei`, `input` is empty, fee
               fields are within the §4.6 capped values,
               locally recomputed `tx_hash` equals the
               stored value, and `ecrecover(sender)` equals
               `payout.security.hot_wallet_address`. Any
               mismatch MUST emit
               `payout_chain_value_mismatch
               mismatch_class='prebroadcast_signed_tx'`
               (existing enum) and MUST NOT broadcast.
               This is the cancel-side analogue of the
               §4.3 step 6 provider-payout preflight; it
               catches a compromised Signer that returns
               a malicious cancel envelope before funds
               move (gas cost is still real for cancels).

               (2) Invoke `eth_sendRawTransaction` on both
               configured RPCs.

               (3) If at least ONE RPC accepts, stamp
               broadcast_at_utc via CAS:

               ```sql
               UPDATE payout_attempts
                  SET broadcast_at_utc = :now,
                      updated_at_utc   = :now
                WHERE payout_id   = :payout_id
                  AND attempt_seq = :attempt_seq
                  AND is_cancel_self_transfer = 1
                  AND broadcast_at_utc IS NULL
                  AND confirmed_at_utc IS NULL
                  AND abandoned_at_utc IS NULL;
               ```

               (4) If BOTH RPCs reject (RPC down, gas-spike
               rejection, etc), leave `broadcast_at_utc`
               NULL. The next cadence cycle's §4.3
               cancel-handling pre-check (unbroadcast
               branch) rebroadcasts the persisted bytes
               bit-for-bit, repeating preflight + CAS-stamp.

               The post-COMMIT crash that previously
               stranded a cancel row at "broadcast_at_utc
               IS NOT NULL but never actually broadcast"
               can no longer happen: a crash before the
               CAS leaves broadcast_at_utc NULL → cancel-
               handling pre-check rebroadcasts; a crash
               after at least one RPC accepted AND after
               the CAS commits is recoverable via §4.3 step
               7 cancel polling.

               If broadcast fails post-commit (RPC down,
               gas-spike rejection), the cancel row remains
               in `payout_attempts` with its raw_signed_tx
               AND broadcast_at_utc NULL; the next cadence
               cycle picks it up for re-broadcast via the
               §4.3 cancel-handling pre-check
               (unbroadcast branch). The persisted bytes are
               re-broadcast bit-for-bit (re-signing is
               FORBIDDEN, same as §4.5 retry discipline).
               Counts toward §5 day cap + §6.2 24h
               aggregate gas-burn cap. The
               idx_pa_from_nonce_active partial UNIQUE index
               permits the same (from_address, nonce) tuple
               on the new row because the original row's
               abandoned_at_utc is now non-NULL in the same
               transaction.
    400      — missing confirm/Idempotency-Key/reason.
    404 Not Found — (NEW v0.1.12) no
                    payout_attempts row matches
                    (payout_id, attempt_seq).
                    Body: `{"error":"not_found"}`.
    409 Conflict — one of:
                   `{"error":"already_confirmed"}` — the
                   attempt is confirmed; nothing to abandon.
                   (Disambiguated in v0.1.12; v0.1.11 and
                   earlier returned a generic 409 here.)
                   OR
                   `{"error":"already_abandoned"}` — the
                   attempt is already abandoned (idempotent
                   re-abandon). (NEW v0.1.12.)
                   OR (v0.1.11 codex round-12 MAJOR-1
                   closure):
                   `{"error":"runner_active"}` — the
                   payout runner is actively holding the
                   §4.8b lease (heartbeat fresh within
                   `3 * payout.tuning.run_interval`). The
                   operator MUST first stop the runner
                   (flip `payout.enabled: false`, wait for
                   the heartbeat to go stale OR restart
                   the coordinator which releases the
                   lease on clean shutdown) before
                   abandoning an in-flight attempt. Without
                   this gate, an operator-key holder
                   racing abandon against the §4.3 step 6
                   sign+CAS could mark the attempt
                   abandoned and broadcast a cancel tx at
                   the same nonce, then the runner's CAS
                   would still see `raw_signed_tx IS NULL`
                   (the abandon doesn't write
                   raw_signed_tx) and might (without the
                   step 6 CAS predicate extensions) have
                   persisted + broadcast the original.
                   The runner_active rejection closes the
                   race from the abandon side; the step 6
                   CAS predicate extensions (`AND
                   confirmed_at_utc IS NULL AND
                   abandoned_at_utc IS NULL`) close it
                   from the runner side. BOTH defenses
                   are required: in the unlikely event
                   the lease is stale-but-runner-still-
                   stalled-signing (clock skew, partial
                   network partition), the runner-side
                   CAS catches the abandon committed in
                   the gap.
    422      — per-cancel gas spend would exceed
               payout.security.cancel_max_gas_native_wei ceiling
               OR per-24h aggregate gas spend would exceed
               payout.security.cancel_max_gas_native_wei_per_24h.
    429      — exceeded payout.security.abandon_rate_per_hour
               (default 3).
  ```

  **Runner-active rejection mechanics (v0.1.11 NORMATIVE).**
  The endpoint handler MUST perform the lease-presence
  check in the SAME `BEGIN IMMEDIATE` SQLite transaction
  as the abandon-marker UPDATE + cancel-row INSERT:

  ```sql
  BEGIN IMMEDIATE;
    -- Lease-active check (NEW v0.1.11): runner is
    -- considered active iff a lease row exists AND its
    -- heartbeat is within 3 * run_interval. The
    -- heartbeat staleness window matches §4.8b takeover
    -- semantics so the gating is symmetric.
    SELECT 1 FROM payout_runner_lease
     WHERE id = 1
       AND heartbeat_at_utc >= datetime(:now, '-' ||
           (3 * :run_interval_seconds) || ' seconds');
    -- If row returned → return 409 runner_active + ROLLBACK.
    -- If no row returned → proceed with the abandon
    --   marker UPDATE + cancel-row INSERT.
    UPDATE payout_attempts
       SET abandoned_at_utc = :now,
           abandoned_reason = :reason,
           updated_at_utc   = :now
     WHERE payout_id = :payout_id
       AND attempt_seq = :attempt_seq
       AND confirmed_at_utc IS NULL
       AND abandoned_at_utc IS NULL;
    -- v0.1.12 (codex round-13 MEDIUM-1 closure): the UPDATE
    -- MUST also gate on confirmed_at_utc IS NULL AND
    -- abandoned_at_utc IS NULL. Without these predicates,
    -- a cold implementer could mark a confirmed attempt
    -- abandoned, which removes it from §7.4 "confirmed
    -- non-abandoned" reconciliation queries and breaks the
    -- receipt/audit model. Not an immediate double-payment
    -- (the matching ledger_payout_ready row is already
    -- consumed), but a contract gap in the money-out state
    -- machine.
    --
    -- If the UPDATE affects 0 rows, IMPL MUST re-read the
    -- row IN THE SAME BEGIN IMMEDIATE transaction to
    -- disambiguate the response (do NOT proceed to the
    -- cancel-row INSERT):
    --   - no row exists                          → 404 not_found
    --   - confirmed_at_utc IS NOT NULL           → 409 already_confirmed
    --   - abandoned_at_utc IS NOT NULL           → 409 already_abandoned
    -- ROLLBACK in all three not-found/conflict cases (the
    -- lease-presence check above already committed a read
    -- lock, but no writes occurred — ROLLBACK is a no-op
    -- semantically and releases the lock cleanly).
    --
    -- Cancel-row INSERT (if broadcast_cancel_self_transfer=
    -- true) is permitted ONLY after the UPDATE affects
    -- EXACTLY ONE live, unconfirmed, non-abandoned row.
    -- ... (cancel-row INSERT as before) ...
  COMMIT;
  ```

  Operator runbook impact: abandoning an in-flight
  attempt now requires a runner stop. The
  `/admin/payout/balance` endpoint and §7.4 reconciliation
  remain available without the lease; only the
  state-mutating abandon path requires runner quiescence.
  Operator stops the runner via `payout.enabled: false`
  in `coordinator.toml` + SIGHUP, OR via coordinator
  restart (clean shutdown releases the lease per §4.8b).
  The lease-stale window (`3 * payout.tuning.run_interval`,
  default 15min at 5min cadence) is the maximum wait
  between operator-initiated stop and abandon-eligibility.

  Configurables — ALL RUNTIME-IMMUTABLE (loaded only at
  process start; SIGHUP / file-watch hot-reload is FORBIDDEN
  for this set; IMPL MUST add a test asserting they are not
  re-read post-startup). A compromised operator-key holder
  with `coordinator.toml` write access can otherwise edit
  the caps and burn the hot wallet via abandons.

  - `payout.security.cancel_max_tip_multiplier` — default 5×; HARD
    cap on `tip_multiplier` field; requests above the cap
    are silently floored AND logged with `cap_applied`.
  - `payout.security.abandon_rate_per_hour` — default 3; per-
    operator-token rate limit on the endpoint.
  - `payout.security.cancel_max_gas_native_wei` — default `1e16`
    (0.01 ETH); per-cancel gas spend ceiling. If exceeded,
    the request is REJECTED with 422.
  - `payout.security.cancel_max_gas_native_wei_per_24h` — default
    `5e16` (0.05 ETH/day); aggregate sliding-window
    ceiling computed as `SUM(payout_attempts.gas_used_native_wei
    WHERE is_cancel_self_transfer = 1 AND broadcast_at_utc
    >= now - 24h)` — for pending cancels (gas_used_native_wei
    NULL) use the cap-time gas estimate. If this estimate
    plus the historic sum would exceed the budget, the
    request is REJECTED with 422. Defends against the
    "3/hr × 24h × 5× tip" aggregate-drain attack class.

  Every `payout_attempt_abandoned` event MUST emit at
  severity=PAGE (per §7.1). Abandon should be a once-a-month
  operation; every invocation deserves human eyes.

  Until this endpoint is called for a gap-causing nonce, the
  runner halts at the next cadence cycle and emits
  `payout_nonce_gap`. No automatic gap-filling.

### 4.7 Reorg handling (record-only, NO consumed-row revert)

**This subsection applies to PROVIDER-PAYOUT attempts only
(`is_cancel_self_transfer = 0`).** v0.1.14 (codex round-15
MAJOR-2 closure) carves out a separate reorg path for
cancel self-transfers below — they do NOT consume
`ledger_payout_ready`, so the provider-orphan flow
(`payout_external_id`, `payout_reorg_orphans` table,
compensation via §9.5b.1) does NOT apply.

Base reorgs past `payout.tuning.confirmation_blocks` are vanishingly
rare in practice but possible. The
`trg_lpr_terminal_status_guard` trigger
(`phase4-coordinator/internal/billing/store.go:121-126`) is
intentional and v0.1.1 does NOT bypass it.

**Reorg poll cadence (NORMATIVE — v0.1.20 round-20 M1
closure).** Without a mandated re-poll cadence for already-
confirmed rows, the only signal that a confirmed payout has
been reorged out is the §7.4 hourly chain-balance
reconciliation — which catches the drift side-effect but
cannot identify WHICH row reorged, forcing the operator into
a manual basescan-vs-DB cross-check on every confirmed row.
Every cadence cycle the runner MUST re-poll receipt status
(via the §4.4 two-RPC discipline) for every
`payout_attempts` row matching:

```sql
SELECT id, payout_id, attempt_seq, payout_external_id
  FROM payout_attempts
 WHERE confirmed_at_utc IS NOT NULL
   AND abandoned_at_utc IS NULL
   AND is_cancel_self_transfer = 0
   AND confirmed_at_utc >= datetime('now', :neg_reorg_poll_window);
```

`:neg_reorg_poll_window` is derived from
`payout.tuning.reorg_poll_window` (default `24h`, bounds
`[1h, 168h]` — see §payout.tuning). Any row whose receipt
becomes "not found" on either RPC enters the reorg path below
with `(payout_id, attempt_seq, payout_external_id)`
identified. **Budget accounting (NORMATIVE).** Per-cycle the
runner issues at most `N_rows × 2` RPC calls (one per pinned
RPC per row), where `N_rows = max_rows_per_run ×
(reorg_poll_window / run_interval)`. At default values
(`max_rows_per_run=50`, `reorg_poll_window=24h`,
`run_interval=6h`) this is `200` row re-polls = `400` RPC
calls per cycle (200 per RPC) — well within the §4.4 RPC
budget which assumes ~10 req/s sustained per provider. The
two-RPC discipline matches the §4.3 step 7 receipt fetch:
both RPCs see the same row state OR a reorg is in progress.
Re-poll failures that are RPC errors (5xx, network) on
EITHER RPC are NOT reorgs; they emit
`payout_reorg_poll_rpc_error` (severity=WARN) and the row
remains confirmed pending the next cycle's re-poll.

If the runner observes that a previously-confirmed
PROVIDER-PAYOUT tx (`is_cancel_self_transfer = 0`) is no
longer present in the canonical chain on either RPC (receipt
returns "not found" after a prior confirmation — either via
the cadence re-poll above OR via an unrelated chain-side
operation), it MUST:

1. Emit `payout_reorg_revert` per §7.1 (severity: page
   operator) with the row identified
   (`payout_id, attempt_seq, payout_external_id,
   observed_via='reorg_poll_cadence' | 'incidental'`).
2. NOT attempt automatic revert. The trigger forbids it; the
   runner has no bypass.
3. NOT attempt a new transfer for the same `payout_id`. The
   `payout_external_id` column already holds the orphaned tx
   hash; the row remains `consumed`.
4. Insert a row into `payout_reorg_orphans` (new table,
   below) capturing the orphan tx hash + observed reorg
   block + RPC source.

**Cancel self-transfer reorg recovery (NEW v0.1.14 —
codex round-15 MAJOR-2 closure).** Cancel rows have
completely different reorg semantics: they consume no
ledger row, they have no provider beneficiary, and a
reorged-out cancel re-opens the nonce gap that the cancel
was filling. If the runner observes that a previously-
confirmed CANCEL tx (`is_cancel_self_transfer = 1`) is no
longer canonical on either RPC, the IMPL MUST:

1. Emit `payout_reorg_revert` per §7.1 with field
   `is_cancel_self_transfer=1` (the event already exists;
   the boolean field distinguishes cancel vs provider-payout
   reorg).
2. NOT insert a row into `payout_reorg_orphans` (that
   table is provider-payout-only and FK-references
   `ledger_payout_ready`; cancels have no ledger row to
   reference).
3. NOT call `ClaimPayoutReady`, NOT touch
   `ledger_payout_ready` in any way — the cancel was never
   associated with a ledger row to begin with.
4. Mark the cancel row LIVE AGAIN in a single
   `BEGIN IMMEDIATE` transaction (provided
   `abandoned_at_utc IS NULL` — an operator who has since
   abandoned the cancel takes precedence over the
   reorg-recovery path):

   ```sql
   BEGIN IMMEDIATE;
     UPDATE payout_attempts
        SET confirmed_at_utc                     = NULL,
            block_number                         = NULL,
            gas_used_native_wei                  = NULL,
            cancel_reconfirm_stale_paged_at_utc  = NULL,  -- v0.1.17 codex round-18 MED-2 closure: re-arm stale-PAGE suppression marker
            last_error                           = 'cancel_self_transfer_reorged:'
                                                   || :prior_tx_hash,
            updated_at_utc                       = :now
      WHERE payout_id   = :payout_id
        AND attempt_seq = :attempt_seq
        AND is_cancel_self_transfer = 1
        AND abandoned_at_utc IS NULL
        AND confirmed_at_utc IS NOT NULL;
     -- If 0 rows updated → the cancel was abandoned in
     -- the gap; do NOT proceed (the abandon path handles
     -- nonce-gap resolution via its own cancel-row INSERT).
   COMMIT;
   ```

5. The next §4.3 cancel-handling pre-check (above) MUST
   detect the live cancel (`broadcast_at_utc IS NOT NULL
   AND confirmed_at_utc IS NULL` — broadcast-unconfirmed
   branch) and re-poll via §4.3 step 7 cancel-specific
   verification. If the cancel re-confirms on a different
   block, the nonce gap is re-filled.

   **Reconfirm-stale escalation (NEW v0.1.15 — codex
   round-16 MED-3 closure; v0.1.16 codex round-17 MED-1
   adds durable suppression).** If a cancel row reactivated
   by this §4.7 path remains
   `broadcast_at_utc IS NOT NULL AND confirmed_at_utc IS
   NULL` AND BOTH RPCs return "not found" for the tx
   for longer than `3 × payout.tuning.run_interval`
   measured from the `updated_at_utc` written by the
   reorg UPDATE in step 4, the runner MUST emit
   `payout_cancel_self_transfer_reconfirm_stale`
   per §7.1 (severity=PAGE, NEW v0.1.15) with fields
   `(run_id, payout_id, attempt_seq, nonce, tx_hash,
   last_seen_block, updated_at_utc, ts_utc)` AND MUST
   continue to HALT fresh non-cancel allocation for this
   `payout_id` until the operator resolves via §4.6
   abandon-and-replace.

   **Once-per-transition emission via durable SQLite
   suppression marker (v0.1.16 codex round-17 MED-1
   closure).** The event fires once per
   cancel-row-transition-into-stale (NOT every cycle AND
   NOT every coordinator restart — an in-memory tracker
   would re-page after each restart for an unresolved
   stale cancel, breaking the once-per-transition contract).
   IMPL MUST track suppression via the
   `payout_attempts.cancel_reconfirm_stale_paged_at_utc`
   column (added in §4.5 schema v0.1.16):

   - Step 4 reorg UPDATE (above) MUST set
     `cancel_reconfirm_stale_paged_at_utc = NULL`
     alongside clearing `confirmed_at_utc`/`block_number`/
     `gas_used_native_wei`. This re-arms the suppression
     marker for the newly-reactivated cancel — if it
     later goes stale, the first stale-crossing emits a
     fresh PAGE.
   - On crossing the `3 × run_interval` threshold with
     both RPCs still returning "not found", the runner
     MUST atomically mark the row stale-paged AND insert
     a durable outbox row, ONLY if the marker is
     currently NULL (CAS pattern + outbox — v0.1.17 codex
     round-18 MED-1 closure):

     ```sql
     BEGIN IMMEDIATE;
       -- (1) Stale-marker CAS: NULL → :now transition.
       UPDATE payout_attempts
          SET cancel_reconfirm_stale_paged_at_utc = :now,
              updated_at_utc                       = :now
        WHERE payout_id   = :payout_id
          AND attempt_seq = :attempt_seq
          AND is_cancel_self_transfer = 1
          AND abandoned_at_utc IS NULL
          AND confirmed_at_utc IS NULL
          AND cancel_reconfirm_stale_paged_at_utc IS NULL;
       -- If UPDATE affected 0 rows → ROLLBACK and skip;
       -- another emitter (this process or another via the
       -- reaper) has already paged this cancel-row's
       -- current stale period.
       --
       -- If UPDATE affected 1 row → ALSO insert outbox
       -- row in this same txn:
       INSERT INTO cancel_reconfirm_stale_outbox
         (payout_id, attempt_seq, stale_started_at_utc,
          nonce, tx_hash, last_seen_block,
          reorg_reactivated_at_utc, emitted_to_log)
       VALUES
         (:payout_id, :attempt_seq, :now,
          :nonce, :tx_hash, :last_seen_block,
          :reorg_reactivated_at_utc, 0);
     COMMIT;
     ```

     **Outbox pattern (NORMATIVE — same defect class as
     v0.1.9 §4.8a runtime_flag_audit outbox).** A journalctl
     /zerolog write is NOT transactionally atomic with the
     SQLite CAS UPDATE. Without an outbox: a crash between
     COMMIT and the journalctl emit leaves
     `cancel_reconfirm_stale_paged_at_utc` non-NULL on the
     row but NO log line ever fires; future cycles hit the
     0-row path (CAS marker already set), so the PAGE is
     PERMANENTLY suppressed — re-opening the silent-stranded-
     cancel visibility gap. The outbox row IS the canonical
     delivery record; the log line is a notification view of
     it.

     AFTER COMMIT, the runner MUST:
     1. Compare-and-set claim the outbox row in a separate
        `BEGIN IMMEDIATE` txn:
        `UPDATE cancel_reconfirm_stale_outbox SET
        emitted_to_log = 1 WHERE id = <committed outbox id>
        AND emitted_to_log = 0 RETURNING id`.
     2. If claim succeeded (1 row), synchronously emit the
        §7.1 `payout_cancel_self_transfer_reconfirm_stale`
        PAGE event from the committed outbox row with
        `event_id = <outbox id>` for downstream dedupe.

     A background reaper (cadence: every
     `payout.tuning.run_interval`, MAY be the same goroutine
     as the §4.8a runtime_flag_audit reaper) MUST scan
     `cancel_reconfirm_stale_outbox WHERE emitted_to_log = 0
     AND stale_started_at_utc < now - 5 minutes` for
     orphaned rows (committed but the synchronous emitter
     crashed). For each row, the reaper runs the SAME CAS
     claim and, on success, emits the PAGE with `event_id`
     AND increments a `payout_stale_outbox_reaped`
     counter per §7.1 (severity=WARN) so operators can
     detect chronic emitter crashes. Downstream log consumers
     MUST de-dupe by `event_id`.

   - The §4.3 cancel-handling pre-check
     confirmed-branch (above) MUST clear
     `cancel_reconfirm_stale_paged_at_utc = NULL` in the
     SAME UPDATE that sets `confirmed_at_utc` from NULL
     to non-NULL. This re-arms the suppression marker for
     ANY future reorg-reactivation: a cancel that
     stales, gets re-confirmed by chain recovery, then
     reorgs again into a new stale period correctly
     emits a fresh PAGE on the next 3 × run_interval
     crossing.

   - Operator-driven §4.6 abandon (cancel row gets
     `abandoned_at_utc` set) drops the row out of the
     §4.3 cancel-handling pre-check entirely; the
     marker becomes moot.

   This event is an OPERATOR-RECOVERY SIGNAL ONLY;
   automatic re-signing remains FORBIDDEN per §4.6 nonce
   discipline. Without this signal, a literal IMPL would
   poll the broadcast-unconfirmed cancel indefinitely
   and silently hold fresh payouts for that `payout_id`
   (the cancel-handling pre-check HALT is correct on its
   own — fresh allocation MUST wait — but a permanently-
   stranded cancel needs operator visibility, which the
   PAGE event provides).

   If the cancel re-confirms before the
   `3 × run_interval` window elapses, the §4.3 step 7
   verification UPDATE clears the stale-paged state and
   emits `payout_cancel_self_transfer_confirmed` per the
   transition-only discipline above. If the operator
   abandons-and-replaces via §4.6, the abandoned cancel
   row drops out of the cancel-handling pre-check
   (filter is `abandoned_at_utc IS NULL`) and the fresh
   non-cancel allocation proceeds.

   Fresh non-cancel allocation for the same `payout_id` is
   HALTED until the cancel re-confirms or is operator-
   resolved — same discipline as v0.1.13 cancel-handling
   pre-check.

```sql
CREATE TABLE IF NOT EXISTS payout_reorg_orphans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL,
    orphan_tx_hash   TEXT NOT NULL,
    last_seen_block  INTEGER NOT NULL,
    observed_at_utc  TEXT NOT NULL,
    rpc_source       TEXT NOT NULL,
    -- Snapshot columns (v0.1.9 — codex round-10 MED-5
    -- closure): captured at orphan-observation time so
    -- §9.5b.1 compensation binds to IMMUTABLE values, not
    -- to current ledger_payout_ready.provider_credits
    -- (which could be mutated post-orphan by a compromised
    -- operator-key calling a hypothetical SPEC-005 admin
    -- mutation endpoint). These columns are the canonical
    -- compensation contract for the §9.5b.1 422
    -- orphan_mismatch check.
    observed_provider_id           TEXT    NOT NULL,
    observed_provider_credits      INTEGER NOT NULL,
    observed_gross_credits         INTEGER NOT NULL,
    observed_amount_base_units     INTEGER NOT NULL,
    operator_resolution TEXT NULL,
    compensation_settlement_id INTEGER NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    resolved_at_utc  TEXT NULL,
    FOREIGN KEY(payout_id, attempt_seq) REFERENCES payout_attempts(payout_id, attempt_seq) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_pro_unresolved ON payout_reorg_orphans(observed_at_utc) WHERE resolved_at_utc IS NULL;
```

The §4.7 orphan-recording flow (operator runbook +
`/admin/payout/record-orphan` endpoint) MUST populate the
four `observed_*` snapshot columns at INSERT time from a
join against `ledger_payout_ready` AND `payout_attempts`:
`observed_provider_id = lpr.provider_id`,
`observed_provider_credits = lpr.provider_credits`,
`observed_gross_credits = lpr.gross_credits`,
`observed_amount_base_units = pa.amount_base_units`.
Once written, these columns are immutable for the orphan
row's lifetime; §9.5b.1 binds compensation to them, NOT
to the current `lpr.*` values.

`compensation_settlement_id` is the new SPEC-005 row's id
issued to compensate the provider for the orphaned payment
(NULL until compensation is recorded). The §7.4
reconciliation surface MUST surface any orphan unresolved
> N days as a separate failure class to defeat
favoritism / fraud via selective compensation.

**Same-SQLite-DB requirement (cross-spec contract).**
`payout_reorg_orphans` MUST live in the SAME SQLite
database file as `ledger_payout_ready` so the §9.5b.1
`POST /admin/ledger/payout-ready` SPEC-005 IMPL can perform
its orphan-row prerequisite check in the SAME SQLite
transaction as the INSERT. Splitting the SPEC-005 billing
database from the SPEC-016 payout database silently breaks
the §9.5b.1 per-call cap defense and the orphan-row
prerequisite. Mirrors §3.1's `provider_payout_addresses`
same-DB pin. IMPL test required.

Operator-driven resolution is record-only via:

```
POST /admin/payout/record-orphan
Authorization: Bearer <operator_key>
Content-Type: application/json

{ "payout_id": 123,
  "attempt_seq": 1,
  "operator_resolution": "free-text — e.g. 'compensated via SPEC-005 fresh row id 4567' or 'no compensation; provider acknowledged'",
  "reason": "free-text" }

Response:
  200 OK   — resolution recorded.
  404      — no matching orphan row.
```

If compensation is warranted, the operator inserts a fresh
`ledger_payout_ready` row VIA THE SPEC-005 ADMIN
ENDPOINT (NOT raw SQL). SPEC-005 v0.3 does NOT currently
define such an endpoint; SPEC-005 vX.Y+1 candidate
`POST /admin/ledger/payout-ready` is a HARD §9.5b
prerequisite. Earlier drafts of this SPEC carried a manual
SQL recipe for compensation; the recipe was REMOVED because
(a) it omitted required `ledger_payout_ready` columns
(`created_at_utc`, explicit `operator_credits`); (b) the
synthetic 1-second window risked colliding with the
`UNIQUE(provider_id, window_start_utc, window_end_utc)`
constraint when two orphans observed in the same second;
(c) raw SQL bypasses SPEC-005's settlement-time invariants
and audit triggers. Compensation flow under v0.1.3:

1. Operator calls the SPEC-005 admin endpoint with the
   orphan's `provider_id`, `provider_credits`, and an
   `idempotency_key` of the form
   `reorg_compensation:<orig_payout_id>:<orig_attempt_seq>`.
2. The endpoint returns the new `ledger_payout_ready.id`.
3. Operator calls
   `POST /admin/payout/record-orphan` with
   `compensation_settlement_id = <new id>` to link the
   compensation back to the orphan record.
4. The runner picks up the fresh row on the next cadence
   cycle and pays it via §4.3 — with a NEW nonce and a
   NEW tx hash, so the double-pay class remains
   structurally eliminated (the original orphan row's
   `payout_external_id` is never re-used).

A `payout_reorg_compensation_recorded` event MUST emit per
§7.1 with `payout_id`, `attempt_seq`,
`compensation_settlement_id`, `reason`, `actor=operator_key`.

The original orphan row stays `consumed` forever — the in-DB
row records what the runner attempted, the orphan_tx_hash is
forensic evidence, and compensation is a separate
`ledger_payout_ready` row with its own audit trail.

Because there is no re-attempt path post-consume on the
ORIGINAL row, the double-pay class is structurally
eliminated — the runner cannot broadcast a second transfer
for the same original `payout_id` because the row never
returns to `ready`. Compensation transfers happen on a
different `payout_id` with a fresh on-chain nonce.

`POST /admin/payout/record-orphan` request body extends to:

```
{ "payout_id": 123,
  "attempt_seq": 1,
  "operator_resolution": "free-text",
  "compensation_settlement_id": 4567 | null,
  "reason": "free-text" }
```

`compensation_settlement_id` is optional on first call (a
record-only resolution like "provider acknowledged loss; no
compensation") but if non-NULL MUST reference a
`ledger_payout_ready.id` that exists.

### 4.8 Runner state

```sql
CREATE TABLE IF NOT EXISTS payout_runner_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    last_run_started_at_utc  TEXT NULL,
    last_run_finished_at_utc TEXT NULL,
    last_run_paid            INTEGER NOT NULL DEFAULT 0,
    last_run_capped          INTEGER NOT NULL DEFAULT 0,
    last_run_failed          INTEGER NOT NULL DEFAULT 0,
    last_run_skipped_no_addr INTEGER NOT NULL DEFAULT 0,
    last_run_cancel_gas_native_wei INTEGER NOT NULL DEFAULT 0,
    last_run_error_text      TEXT NULL,
    payout_bootstrap_complete INTEGER NOT NULL DEFAULT 0 CHECK(payout_bootstrap_complete IN (0,1)),
    bootstrap_completed_at_utc TEXT NULL,
    updated_at_utc           TEXT NOT NULL
);

-- One-way flip: 0 → 1 permitted; 1 → 0 rejected by trigger.
CREATE TRIGGER IF NOT EXISTS trg_prs_bootstrap_one_way
BEFORE UPDATE OF payout_bootstrap_complete ON payout_runner_state
WHEN OLD.payout_bootstrap_complete = 1 AND NEW.payout_bootstrap_complete = 0
BEGIN
    SELECT RAISE(ABORT, 'payout_bootstrap_complete is one-way');
END;

-- Auto-flip on first confirmation. The runner does NOT
-- application-write this — the trigger fires inside the
-- same SQLite transaction that wrote confirmed_at_utc.
CREATE TRIGGER IF NOT EXISTS trg_pa_bootstrap_flip
AFTER UPDATE OF confirmed_at_utc ON payout_attempts
WHEN NEW.confirmed_at_utc IS NOT NULL AND OLD.confirmed_at_utc IS NULL
BEGIN
    UPDATE payout_runner_state
       SET payout_bootstrap_complete = 1,
           bootstrap_completed_at_utc = NEW.confirmed_at_utc,
           updated_at_utc = NEW.confirmed_at_utc
     WHERE id = 1 AND payout_bootstrap_complete = 0;
END;

-- Sibling trigger for INSERTs that land confirmed_at_utc
-- non-NULL directly (test harness or future helper that
-- bypasses the broadcast+poll path). Without this, the
-- UPDATE-only trigger leaves the bootstrap flag at 0,
-- silently re-opening the §4.9 source='manual' window.
CREATE TRIGGER IF NOT EXISTS trg_pa_bootstrap_flip_insert
AFTER INSERT ON payout_attempts
WHEN NEW.confirmed_at_utc IS NOT NULL
BEGIN
    UPDATE payout_runner_state
       SET payout_bootstrap_complete = 1,
           bootstrap_completed_at_utc = NEW.confirmed_at_utc,
           updated_at_utc = NEW.confirmed_at_utc
     WHERE id = 1 AND payout_bootstrap_complete = 0;
END;
```

The `payout_bootstrap_complete` flag flips the first time
any `payout_attempts` row reaches `confirmed_at_utc IS NOT
NULL`. The dual trigger pair (`trg_pa_bootstrap_flip` AFTER
UPDATE + `trg_pa_bootstrap_flip_insert` AFTER INSERT)
guarantees atomicity with the confirmation regardless of
which Go code path writes the row. The flag gates §4.9
`source='manual'` funding records (rejected post-flip).

**Startup row initialization (REQUIRED).** The
`payout_runner_state` row is single-row (PK CHECK id=1).
The bootstrap-flip trigger's `UPDATE ... WHERE id=1 AND
payout_bootstrap_complete=0` no-ops if the row does not
exist. IMPL MUST execute the following INSERT in
`cmd/coordinator/main.go` BEFORE `runner.Start()` is
invoked (same goroutine, same `*sql.DB` handle; the
happens-before edge is the synchronous return of the
INSERT before the function call that constructs the
runner returns):

```sql
INSERT OR IGNORE INTO payout_runner_state
  (id, payout_bootstrap_complete, updated_at_utc)
VALUES (1, 0, '<RFC3339Nano startup time>');
```

IMPL test required: assert
`SELECT count(*) FROM payout_runner_state` returns 1
BEFORE any `payout_attempts` write is attempted. A
soft "execute at startup" wording would otherwise allow
an IMPL to place the INSERT inside `runner.Start()` AFTER
the loop begins, re-opening the v0.1.3 C2 fake-funding
closure for one cycle.

### 4.8a Runtime flags table (v0.1.7 — `runtime.*` persistence)

```sql
CREATE TABLE IF NOT EXISTS runtime_flags (
    name              TEXT PRIMARY KEY,
    value             INTEGER NOT NULL CHECK(value IN (0,1)),
    updated_at_utc    TEXT NOT NULL,
    updated_by_actor  TEXT NOT NULL,   -- "operator_key:<key_id>"
                                       -- for §6.4.1 toggles;
                                       -- "system:bootstrap_seed"
                                       -- ONLY on first-ever DB
                                       -- initialization.
    updated_reason    TEXT NOT NULL    -- §6.4.1 endpoint body
                                       -- "reason" field; "" for
                                       -- bootstrap seed.
);

-- Outbox table for §6.4.1 audit-trail atomicity (closes
-- codex round-9 MAJOR-5: a journalctl/zerolog write cannot
-- be transactionally atomic with SQLite; the audit row IS
-- the transactional record, and the §7.1 event is emitted
-- AFTER commit from the committed row).
CREATE TABLE IF NOT EXISTS runtime_flag_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    flag_name         TEXT NOT NULL,
    old_value         INTEGER NOT NULL CHECK(old_value IN (0,1)),
    new_value         INTEGER NOT NULL CHECK(new_value IN (0,1)),
    actor             TEXT NOT NULL,   -- "operator_key:<key_id>"
    reason            TEXT NOT NULL,
    occurred_at_utc   TEXT NOT NULL,
    emitted_to_log    INTEGER NOT NULL DEFAULT 0 CHECK(emitted_to_log IN (0,1))
);
CREATE INDEX IF NOT EXISTS idx_rfa_unemitted
    ON runtime_flag_audit(id) WHERE emitted_to_log = 0;
```

**Bootstrap seed (FIRST-EVER INIT ONLY — closes codex
round-9 MAJOR-6 fail-open class).** The seed MUST run
exactly once, gated by a separate sentinel that proves
this is the first-ever DB initialization:

```sql
-- Sentinel: one-row table that proves first-ever bootstrap
-- has occurred. After this row exists, the runtime_flags
-- seed is FORBIDDEN.
CREATE TABLE IF NOT EXISTS runtime_flags_bootstrapped (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    bootstrapped_at_utc TEXT NOT NULL
);

-- First-ever-init seed runs ONLY when ALL THREE runtime
-- tables are simultaneously empty (codex round-10 MED-4
-- closes the sentinel-asymmetry case: v0.1.8 only checked
-- the sentinel-present-but-flag-missing direction; the
-- sentinel-missing-but-flag-present case could let an
-- attacker who deleted only the sentinel trigger a reseed
-- that overwrites an operator-set pause to value=0). The
-- runtime_flag_audit table is checked too because any
-- legitimate runtime_flags row must have a matching audit
-- row by the §4.8a discipline.
BEGIN IMMEDIATE;
  -- ACTION TABLE (IMPL MUST implement these checks in
  -- Go BEFORE issuing the INSERTs below):
  --
  -- runtime_flags_bootstrapped: EMPTY,  runtime_flags: EMPTY,  runtime_flag_audit: EMPTY
  --   → first-ever boot; proceed with INSERTs below.
  -- runtime_flags_bootstrapped: NONEMPTY, runtime_flags: NONEMPTY, runtime_flag_audit: NONEMPTY-or-EMPTY
  --   → normal restart; SKIP seed; let §6.4.1 audit-trail
  --     discipline below handle the audit row check.
  -- runtime_flags_bootstrapped: NONEMPTY, runtime_flags: EMPTY (for ANY closed-set flag)
  --   → tampering or migration error; EMIT
  --     `payout_invariant_violation where='runtime_flag missing'
  --     name='<flag_name>'` per §7.1 (severity=PAGE) and HALT
  --     before accepting traffic. DO NOT recreate the row.
  -- runtime_flags_bootstrapped: EMPTY, runtime_flags: NONEMPTY OR runtime_flag_audit: NONEMPTY
  --   → sentinel-tampering / partial-DB-restore; EMIT
  --     `payout_invariant_violation where='runtime_flags_bootstrap_sentinel_missing'`
  --     per §7.1 (severity=PAGE) and HALT before accepting
  --     traffic. DO NOT reseed.
  INSERT INTO runtime_flags
    (name, value, updated_at_utc, updated_by_actor, updated_reason)
  VALUES
    ('registration_paused', 0,
     '<RFC3339Nano startup time>',
     'system:bootstrap_seed', '');
  INSERT INTO runtime_flags_bootstrapped
    (id, bootstrapped_at_utc)
  VALUES (1, '<RFC3339Nano startup time>');
COMMIT;
```

**Persistence + restart semantics (NORMATIVE).** The
`runtime_flags` table is the durable backing store for
the `runtime.*` namespace defined in §6.5. On coordinator
startup, the §3.3 handler MUST read the
`registration_paused` value BEFORE accepting traffic; a
process restart between §6.4 step 1 (pause) and step 4
(resume) MUST NOT auto-unpause. The first-ever
bootstrap-seed sequence above runs ONLY on initial DB
init (gated by the `runtime_flags_bootstrapped`
sentinel); subsequent restarts MUST read the existing
row and honor whatever state the operator last set. If
the `runtime_flags` row for any closed-set flag is
missing on a NON-first-ever startup (the sentinel row
exists but the flag row does not), IMPL MUST emit
`payout_invariant_violation where='runtime_flag missing'
name='<flag_name>'` per §7.1 (severity=PAGE) and HALT
before the §3.3 handler accepts traffic — startup MUST
NOT silently recreate the missing flag as value=0.

**Atomicity discipline (closes codex round-9 MAJOR-5).** A
log write (journalctl/zerolog per §7.1.1) cannot be
transactionally atomic with a SQLite write. v0.1.8
resolves this via a durable outbox pattern: every §6.4.1
admin endpoint MUST perform the following in ONE
`BEGIN IMMEDIATE` SQLite transaction:

1. UPDATE `runtime_flags` SET value = <new>, updated_at_utc,
   updated_by_actor, updated_reason WHERE name = '<flag>'.
2. INSERT INTO `runtime_flag_audit` (flag_name, old_value,
   new_value, actor, reason, occurred_at_utc,
   emitted_to_log) VALUES (..., 0).
3. COMMIT.

If COMMIT fails, the §6.4.1 endpoint returns 500 and the
§7.1 event is NOT emitted (because nothing committed —
this is the consistent failure mode). AFTER COMMIT
succeeds, the endpoint handler MUST:

1. Run a compare-and-set claim in a `BEGIN IMMEDIATE`
   txn: `UPDATE runtime_flag_audit SET emitted_to_log = 1
   WHERE id = <committed audit id> AND emitted_to_log = 0
   RETURNING id`. If the UPDATE returns 0 rows, another
   emitter (sync or reaper) has already claimed this row;
   skip the log emit.
2. If the claim succeeded (returned 1 row), synchronously
   emit the §7.1 zerolog event from the committed audit
   row. The log line MUST include `event_id = <audit id>`
   so downstream consumers can dedupe.

A background reaper (cadence: every
`payout.tuning.run_interval`) MUST scan `runtime_flag_audit
WHERE emitted_to_log = 0 AND occurred_at_utc < now -
5 minutes` for orphaned rows (committed but the
synchronous emitter crashed before the compare-and-set
above). For each row, the reaper MUST:

1. Run the SAME compare-and-set claim — v0.1.18 (codex
   round-11 LOW-2 closure) aligns the SQL shorthand with
   the sync emitter's full form, including
   `RETURNING id`:
   `UPDATE runtime_flag_audit SET emitted_to_log = 1
   WHERE id = <row id> AND emitted_to_log = 0 RETURNING
   id`. If the UPDATE returns 0 rows, another emitter has
   already claimed this row; skip the log emit. (Closes
   codex round-10 MED-7 double-emit class — without
   CAS, the reaper and a late-running synchronous
   emitter could both emit the same row.)
2. If the claim succeeded, emit the §7.1 zerolog event
   with `event_id = <audit id>` AND increment the
   `payout_flag_audit_reaped` counter per §7.1
   (severity=WARN) so operators can detect a chronic
   emitter crash. If the claim failed, skip.

Downstream log consumers (BetterStack alert filter, log
shippers, dashboards) MUST de-dupe events by `event_id` —
the spec guarantees at-MOST-once delivery from any single
emitter site (via CAS), but the network/forwarder layer
between zerolog and the downstream consumer can still
deliver duplicates; dedupe-by-event_id is the canonical
defense.

The DB row IS the canonical audit record; the log line is
a notification view of it.

**Audit-trail discipline (renamed from "cross-check
against raw DB write" in v0.1.7).** Operators MUST scan
`runtime_flag_audit` for any row whose `actor` does not
start with `operator_key:` or `system:bootstrap_seed` —
that is the raw-DB-write tampering signal. The dual
records (audit row + zerolog event) are intentionally
redundant; a write that bypasses the §6.4.1 endpoint
WILL miss BOTH the audit row AND the zerolog event,
which is detectable by comparing the `runtime_flags`
row's `updated_at_utc` against the most recent
`runtime_flag_audit` row for the same flag — any
diff = tampering.

**Same-DB pin.** The `runtime_flags` table MUST live in
the same SQLite database file as `payout_runner_state`
and `payout_attempts` (consistent with §3.1's
`provider_payout_addresses` pin and §4.7's
`payout_reorg_orphans` pin to SPEC-005's
`ledger_payout_ready` DB). The §6.4.1 endpoint's
event-emission and flag-update happen in ONE SQLite
transaction; a separate-DB topology would split them
into two transactions and re-open an event-emitted-
but-flag-not-flipped (or vice versa) gap window. The
comprehensive "all SPEC-016 tables in one DB" pin is
deferred to v0.2 (filed in Appendix B).

IMPL test required (1): spawn coordinator with
`registration_paused = 1` pre-seeded AND the
`runtime_flags_bootstrapped` sentinel pre-seeded; assert
that a clean restart preserves the value and that §3.3
returns 503 BEFORE the runner finishes startup.

IMPL test required (2): delete the `registration_paused`
row while leaving the `runtime_flags_bootstrapped`
sentinel in place; assert that startup emits
`payout_invariant_violation` and HALTS before the §3.3
handler accepts traffic; assert NO new
`registration_paused` row is created at startup.

IMPL test required (3): call §6.4.1 pause endpoint;
assert `runtime_flag_audit` row is INSERTed in the SAME
SQLite transaction as the `runtime_flags` UPDATE; assert
the §7.1 zerolog line is emitted AFTER commit; assert
`emitted_to_log` flips to 1 after the log write.

**Trigger-presence assertion (defense against DROP TRIGGER
+ UPDATE bypass).** All three bootstrap-related triggers
(`trg_prs_bootstrap_one_way`, `trg_pa_bootstrap_flip`,
`trg_pa_bootstrap_flip_insert`) and the
`trg_lpr_terminal_status_guard` trigger from SPEC-005 are
soft DB-side guards — a compromised actor with DB write
access can `DROP TRIGGER` + mutate + `CREATE TRIGGER` to
bypass them. v0.1.4 hardens this by requiring IMPL to
assert trigger presence at runner startup AND at the top
of every cadence cycle:

```sql
SELECT name FROM sqlite_master
 WHERE type = 'trigger'
   AND name IN ('trg_prs_bootstrap_one_way',
                'trg_pa_bootstrap_flip',
                'trg_pa_bootstrap_flip_insert',
                'trg_lpr_terminal_status_guard');
```

If the result set does NOT include all four trigger names,
IMPL MUST emit
`payout_invariant_violation where='trigger missing' detail='<name>'`
per §7.1 and HALT the runner. Operator response is
forensic — investigate why the trigger is missing
(legitimate schema migration vs. compromise) before
re-creating and resuming.

**Intra-transaction trigger-presence assertion (defense
against DROP+UPDATE+CREATE inside one cadence cycle).**
The startup + top-of-cycle check leaves an intra-cycle
window — an attacker with DB write can DROP a trigger,
INSERT/UPDATE the row bypassing it, and CREATE the trigger
back, all between two top-of-cycle assertions. v0.1.5
closes this for the TWO money-path-mutating call sites:

- §4.9 `source='manual'` acceptance check (the
  `payout_bootstrap_complete` SELECT that gates the INSERT)
  MUST be performed in the SAME SQLite transaction as:

  ```sql
  SELECT count(*) FROM sqlite_master
   WHERE type='trigger'
     AND name IN ('trg_prs_bootstrap_one_way',
                  'trg_pa_bootstrap_flip',
                  'trg_pa_bootstrap_flip_insert');
  -- REJECT 422 bootstrap_trigger_missing if count != 3
  -- AND emit payout_invariant_violation per §7.1.
  ```

  v0.1.8 adds `trg_prs_bootstrap_one_way` to the IN list
  (closes codex round-9 MAJOR-7): without it, an attacker
  with raw DB write could DROP `trg_prs_bootstrap_one_way`
  in one txn, reset `payout_bootstrap_complete` from 1
  back to 0 in another txn, CREATE the trigger back, and
  then submit a `source='manual'` funding record — the
  two AFTER-trigger checks alone (UPDATE + INSERT bootstrap-
  flip) cannot detect this because they fire AFTER the
  flag was already manipulated. All three bootstrap-related
  triggers MUST be present at the manual-funding txn for
  the §4.9 fail-closed gate to hold.

- §4.3 step 8 `ClaimPayoutReady` invocation MUST be
  performed in the SAME SQLite transaction as:

  ```sql
  SELECT count(*) FROM sqlite_master
   WHERE type='trigger'
     AND name = 'trg_lpr_terminal_status_guard';
  -- abort the claim, leave the row in 'ready', emit
  -- payout_invariant_violation if count != 1.
  ```

A drop-and-recreate that fully completes between two
top-of-cycle checks is now detectable AT the money-path
call boundary, because the SQLite transaction's snapshot
view of `sqlite_master` is consistent with its other
statements — the attacker cannot DROP, mutate, and
CREATE all within the same SQLite txn (DDL serialises
writes against the same connection).

The `last_run_cancel_gas_native_wei` field is observability
only — the cap-check at §4.6 reads from
`SUM(payout_attempts.gas_used_native_wei WHERE
is_cancel_self_transfer = 1 AND broadcast_at_utc >=
now - 24h)` directly, NOT from this column (which would
miss cancel transfers across runs).

### 4.8b Singleton-runner lease table (v0.1.9 — codex round-10 MAJOR-2 closure)

The §4.3 step 3 singleton-runner lease guard requires a
concrete table + algorithm. The v0.1.8 prose referenced
`(host, pid, started_at_utc)` and a heartbeat without
defining the schema or takeover semantics — codex round-10
correctly flagged this as not implementable.

```sql
CREATE TABLE IF NOT EXISTS payout_runner_lease (
    id                       INTEGER PRIMARY KEY CHECK(id = 1),
    holder_host              TEXT NOT NULL,
    holder_pid               INTEGER NOT NULL,
    holder_started_at_utc    TEXT NOT NULL,
    holder_token             TEXT NOT NULL,   -- random 16-byte
                                              -- hex; rotates on
                                              -- every (re)acquire
    heartbeat_at_utc         TEXT NOT NULL,
    acquired_at_utc          TEXT NOT NULL,
    takeover_count           INTEGER NOT NULL DEFAULT 0
);

-- Bootstrap seed: zero-row table by default (no lease until
-- the first runner process acquires it).
```

**Lease semantics (NORMATIVE):**

- **Acquire.** On runner start, IMPL MUST attempt acquire
  in a single `BEGIN IMMEDIATE` transaction:
  1. `SELECT * FROM payout_runner_lease WHERE id = 1`.
  2. If no row exists, `INSERT` a row with the current
     process's `(holder_host, holder_pid,
     holder_started_at_utc, fresh holder_token,
     heartbeat_at_utc=now, acquired_at_utc=now,
     takeover_count=0)`. COMMIT. Lease acquired.
  3. If a row exists AND `heartbeat_at_utc >= now -
     (3 × payout.tuning.run_interval)` (the holder is
     alive), the acquire FAILS. Emit
     `payout_runner_lease_conflict` per §7.1
     (severity=PAGE) and refuse to start the runner.
  4. If a row exists AND `heartbeat_at_utc < now -
     (3 × payout.tuning.run_interval)` (the holder is
     stale), perform a TAKEOVER: `UPDATE
     payout_runner_lease SET holder_host=<this host>,
     holder_pid=<this pid>, holder_started_at_utc=
     <this started time>, holder_token=<fresh 16-byte
     hex>, heartbeat_at_utc=now, acquired_at_utc=now,
     takeover_count=takeover_count+1 WHERE id=1`. COMMIT.
     Lease acquired via takeover. Emit a new
     `payout_runner_lease_taken_over` event per §7.1
     (severity=PAGE — takeover is rare and operationally
     significant).

- **Heartbeat.** While running, the IMPL MUST update
  `heartbeat_at_utc = now` on the lease row at least
  every `payout.tuning.run_interval` (the heartbeat
  cadence and the run cadence are the same). The heartbeat
  UPDATE MUST be a `BEGIN IMMEDIATE` transaction that ALSO
  re-asserts `WHERE holder_token = <this process's
  acquired token>`; if the UPDATE affects 0 rows, this
  process has been taken over and MUST self-halt with
  `payout_runner_lease_lost` (severity=PAGE).

- **Self-fencing on every §4.3 step.** Before each step
  4, 5, 6, 7, 8 of §4.3, the IMPL MUST re-read
  `holder_token` from the lease row (within the same
  `BEGIN IMMEDIATE` transaction as the step 3(b) txn
  for steps 4–5; standalone read for steps 6–8) and
  compare to the in-memory acquired token. Mismatch
  triggers self-halt + `payout_runner_lease_lost`. This
  defeats the stop-the-world-GC class where this process
  stalled long enough for a takeover, then resumed and
  tried to broadcast a tx the new holder doesn't know
  about.

- **Release.** On clean shutdown, the IMPL MUST `DELETE
  FROM payout_runner_lease WHERE id=1 AND holder_token =
  <acquired token>` so the next process can acquire
  without waiting the takeover-stale window. A crash skips
  this; the next process triggers takeover after the
  stale window elapses.

- **Same-DB pin.** The `payout_runner_lease` table MUST
  live in the same SQLite database file as
  `payout_runner_state`, `payout_attempts`,
  `runtime_flags`, and SPEC-005's `ledger_payout_ready`
  (mirrors §3.1 / §4.7 / §4.8a pins). IMPL MUST share one
  `*sql.DB` handle across the lease, runner, and §6.4.1
  endpoints — otherwise the §4.3 step 3(b) BEGIN IMMEDIATE
  cannot atomically re-read the lease token alongside the
  cap re-check.

**Two new §7.1 events:**

- `payout_runner_lease_taken_over` (severity=PAGE) — fields
  `prior_holder_host, prior_holder_pid, prior_holder_started_at_utc,
  prior_heartbeat_at_utc, new_holder_host, new_holder_pid,
  takeover_count, ts_utc`.
- `payout_runner_lease_lost` (severity=PAGE) — fields
  `local_pid, local_holder_token, observed_holder_token,
  observed_holder_host, observed_holder_pid, ts_utc`.

IMPL test required (1): spawn two coordinator processes in
quick succession against the same DB; assert the first
acquires the lease and the second emits
`payout_runner_lease_conflict` and exits.

IMPL test required (2): kill the lease-holder process with
`-9`; wait `3 × run_interval`; spawn a new coordinator; assert
takeover succeeds and `payout_runner_lease_taken_over` is
emitted with `takeover_count=1`.

IMPL test required (3): in a single process, manually
overwrite the lease row's `holder_token` to a different value;
on the next §4.3 cycle, assert the self-fencing check halts the
runner with `payout_runner_lease_lost`.

**Chain-nonce uniqueness is load-bearing for the post-CAS
broadcast race (NORMATIVE explanatory — v0.1.20 round-20 M4
closure).** The §4.3 step 6 sequence is (a) CAS-persist the
signed envelope inside `BEGIN IMMEDIATE`, (b) COMMIT, (c)
re-read `holder_token` post-COMMIT, (d) only if lease still
held, invoke `eth_sendRawTransaction`. Between (c) and (d) a
GC stall or page fault can elapse `3 × run_interval` and elect
a new lease holder. The new holder, on its next §4.3 cycle,
sees the persisted-but-unbroadcast envelope and rebroadcasts
it (re-signing is FORBIDDEN per §4.6). At that point both
processes may broadcast the same signed envelope (same nonce,
same signature, byte-identical). **The Base sequencer's
nonce-uniqueness rule is what guarantees at most one of the
two broadcasts confirms** — IMPL MUST NOT rely on a second
software guard to make this single. This is not a defect; it
is an architectural assumption made explicit.

IMPL test required (4): the post-CAS broadcast race window.
This test exists because the lease re-read at §4.3 step 6
runs BEFORE the `eth_sendRawTransaction` syscall, but the
window between that re-read and the syscall is unguarded by
software — only chain nonce-uniqueness covers it. Inject a
synthetic 30-second sleep AFTER the §4.3 step 6 post-COMMIT
lease re-read returned OK, BEFORE the
`eth_sendRawTransaction` syscall. Manually advance the lease
heartbeat past `3 × run_interval` during the sleep so a
takeover would succeed. Spawn a second process to acquire
the lease; verify the second process rebroadcasts the
persisted envelope. On the first process's resumed broadcast,
assert it receives the RPC's `nonce too low` or `already known`
response (NOT `successful`) and the first process records the
broadcast outcome WITHOUT emitting a misleading
`payout_invariant_violation`. The first process MAY emit a
`payout_runner_lease_lost` on the NEXT cadence cycle when the
self-fencing check (§4.8b "Self-fencing on every §4.3 step")
re-reads the lease token, but that emit is NOT a requirement
of this test — the requirement is that the chain serializes
the two broadcasts via nonce-uniqueness without either process
double-spending. Test FAILS if both processes' broadcasts
return `successful` OR if the first process emits
`payout_invariant_violation` on the nonce-collision response.

### 4.8c Cancel reconfirm-stale outbox (v0.1.17 — codex round-18 MED-1 closure)

Durable delivery record for the §7.1
`payout_cancel_self_transfer_reconfirm_stale` PAGE event,
written in the SAME `BEGIN IMMEDIATE` transaction as the
§4.7 cancel-reorg stale-marker CAS. Closes the
crash-between-COMMIT-and-emit silent-suppression class:
without the outbox, a process crash after the CAS UPDATE
COMMITs but before the journalctl emit would leave the
marker non-NULL AND no PAGE ever fires (future cycles hit
the 0-row CAS path → PERMANENTLY silent stranded cancel).

Same outbox+reaper pattern as §4.8a `runtime_flag_audit`.

```sql
CREATE TABLE IF NOT EXISTS cancel_reconfirm_stale_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payout_id                 INTEGER NOT NULL,
    attempt_seq               INTEGER NOT NULL,
    stale_started_at_utc      TEXT NOT NULL,  -- == the
                                              -- NULL→:now
                                              -- transition
                                              -- ts on the
                                              -- payout_attempts
                                              -- row's
                                              -- cancel_reconfirm_stale_paged_at_utc
                                              -- column.
    nonce                     INTEGER NOT NULL,
    tx_hash                   TEXT NOT NULL,
    last_seen_block           INTEGER NOT NULL,
    reorg_reactivated_at_utc  TEXT NOT NULL,  -- the
                                              -- updated_at_utc
                                              -- written by
                                              -- §4.7 step 4
                                              -- reorg
                                              -- reactivation
    emitted_to_log            INTEGER NOT NULL DEFAULT 0 CHECK(emitted_to_log IN (0,1)),
    FOREIGN KEY(payout_id, attempt_seq) REFERENCES payout_attempts(payout_id, attempt_seq) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_crso_unemitted
    ON cancel_reconfirm_stale_outbox(id) WHERE emitted_to_log = 0;
CREATE UNIQUE INDEX IF NOT EXISTS idx_crso_one_per_stale_period
    ON cancel_reconfirm_stale_outbox(payout_id, attempt_seq, stale_started_at_utc);
```

The `idx_crso_one_per_stale_period` UNIQUE constraint
enforces at-most-one outbox row per (cancel-row,
stale-period) tuple at the DB layer — belt-and-suspenders
defense if the §4.7 step-5 CAS pattern is bypassed.

**Same-DB pin.** The `cancel_reconfirm_stale_outbox` table
MUST live in the same SQLite database file as
`payout_attempts` (mirrors §3.1 / §4.7 / §4.8a / §4.8b
pins). IMPL MUST share one `*sql.DB` handle across the
runner and the reaper. The comprehensive "all SPEC-016
tables in one DB" pin remains deferred to v0.2 per
Appendix B.

**IMPL test required.** Pre-seed a cancel row with
`cancel_reconfirm_stale_paged_at_utc = NULL`; trigger the
§4.7 step-5 CAS; assert the outbox row exists with
`emitted_to_log = 0`; assert restart preserves both the
marker AND the outbox row; assert reaper emits and flips
to `emitted_to_log = 1`; assert a second reaper pass
detects no orphan and emits no duplicate.

### 4.9 Hot-wallet funding records

The `/admin/payout/balance` surface and the §7.4 chain-balance
reconciliation BOTH need an in-DB record of every USDC deposit
into the hot wallet, so they can compute "expected on-chain
balance = (sum of deposits) − (sum of confirmed non-abandoned
non-cancel outflows)". v0.1.2 ships this table inline:

```sql
CREATE TABLE IF NOT EXISTS payout_hot_wallet_funding (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_address       TEXT NOT NULL,
    to_address         TEXT NOT NULL,
    amount_base_units  INTEGER NOT NULL CHECK(amount_base_units > 0),
    tx_hash            TEXT NOT NULL,
    block_number       INTEGER NOT NULL,
    observed_at_utc    TEXT NOT NULL,
    source             TEXT NOT NULL CHECK(source IN ('manual','rpc-confirmed')),
    operator_note      TEXT NULL,
    UNIQUE(tx_hash)
);
CREATE INDEX IF NOT EXISTS idx_phwf_to ON payout_hot_wallet_funding(to_address);
```

`to_address` is the recipient of the inbound USDC transfer
— always equal to `payout.security.hot_wallet_address` per the
request body validation. The column was added in v0.1.4 to
fix a §7.4 query-vs-schema mismatch where the
chain-balance reconciliation referenced `to_address` but
the schema only had `from_address` (the SENDER), breaking
the negative-drift alarm at runtime.

Records are inserted via:

```
POST /admin/payout/record-funding
Authorization: Bearer <operator_key>
Content-Type: application/json
Idempotency-Key: <tx_hash — case-insensitive, 0x-prefixed lowercase hex,
                  MUST equal request body tx_hash>

{ "from_address": "0x...sender of funds...",
  "to_address":   "0x...hot wallet — MUST equal payout.security.hot_wallet_address...",
  "amount_base_units": 100000000,
  "tx_hash": "0x...funding tx hash...",
  "block_number": 1234567,
  "source": "rpc-confirmed" | "manual",
  "operator_note": "free-text" }

Response:
  201 Created — record inserted; payout_funding_recorded
                event emitted per §7.1.
  400         — missing field / amount_base_units <= 0 /
                to_address != payout.security.hot_wallet_address /
                from_address == payout.security.hot_wallet_address
                (v0.1.20 round-20 C2 closure: hot wallet may not
                fund itself — see §3.2 deny-list).
  409 Conflict — UNIQUE(tx_hash) violation (already recorded).
  422         — receipt verification mismatch (see below) /
                idempotency_key_mismatch (v0.1.20 round-20 C1
                closure: see "Idempotency binding" below).
```

**Idempotency binding (NORMATIVE — v0.1.20 round-20 C1 closure).**
The `Idempotency-Key` header MUST equal the request body's `tx_hash`
field (case-insensitive equality on `0x`-prefixed lowercase hex).
Mismatch → 422 `idempotency_key_mismatch`. This collapses two
potential idempotency keys into one and lets the existing
`UNIQUE(tx_hash)` constraint be the sole enforcer; the v0.1.19
"opaque key" framing was decorative — a buggy retry loop or
operator typo could submit the same logical funding event with a
fresh `Idempotency-Key` and a fresh `tx_hash` (e.g. one character
off), inflating `cumulative_funding_usdc_base_units` past the
real on-chain balance. The §7.4 drift alarm only PAGES on
NEGATIVE drift, so positive inflation silently absorbs missing
on-chain USDC. Binding the header to `tx_hash` makes
`UNIQUE(tx_hash)` the load-bearing dedup AND requires the
operator to commit to the tx_hash they're recording before the
request fires.

**`source = 'rpc-confirmed'` (ongoing, post-bootstrap):**

IMPL MUST fetch the receipt for `tx_hash` from BOTH RPCs
(§4.4 two-RPC discipline) and REJECT 422
`receipt_mismatch` unless ALL of the following hold on
BOTH receipts:

- `to` field matches the USDC contract address pinned in
  the operator's config.
- The USDC `Transfer` event log within the receipt has
  `from = <request body's from_address>`,
  `to = payout.security.hot_wallet_address`, `value =
  amount_base_units`.
- `block_number` matches.
- `status` = success.

If EITHER RPC returns a null receipt or
`eth_getTransactionReceipt` returns "not found" (e.g.
the funding tx is older than the RPC's pruning window),
REJECT 422 `receipt_not_available`. The operator MUST
either pick an RPC that retains the receipt or use the
`source='manual'` bootstrap path BEFORE the bootstrap
flag flips.

**`source = 'manual'` (BOOTSTRAP-ONLY):**

The endpoint accepts `source='manual'` ONLY when the
`payout_runner_state.payout_bootstrap_complete` flag is
FALSE. The flag starts FALSE on a fresh deployment and
flips IRREVOCABLY to TRUE the first time any
`payout_attempts` row reaches `confirmed_at_utc IS NOT
NULL`. After the flip, `source='manual'` requests are
REJECTED with 422 `bootstrap_complete`. The flag is
runtime-immutable via the §6.5 hot-reload prohibition;
once flipped, only a fresh database can reset it.

This narrowing closes the operator-key-compromise
fake-funding attack class: the only window where an
attacker can record a non-existent funding tx is the
bootstrap window before the first payout confirms, which
is operator-supervised and naturally short. After
bootstrap, all funding records require BOTH-RPC receipt
match, defeating the inflated-expected-balance attack on
§7.4.

A `payout_funding_recorded` event MUST emit per §7.1.

§7.4 chain-balance reconciliation reads from this table:

```sql
SELECT COALESCE(SUM(amount_base_units), 0) FROM payout_hot_wallet_funding
  WHERE to_address = :hot_wallet
```

versus the on-chain `balanceOf` + the §7.4 outflow query.

## 5 Fee policy (FR-P3)

### 5.1 Gas on the operator

Gas fees on Base are paid from the operator hot wallet, NOT
deducted from `provider_credits`. The provider always receives
exactly `provider_credits` USDC base units. At Base's sub-cent
transfer cost the operator's per-payout gas overhead is
negligible; v0.2 MAY revisit if Base base-fees rise structurally.

### 5.2 Per-payout cap

`payout.security.per_payout_cap_usdc_base_units` — default
`500_000_000` (i.e. $500 = 500 USDC × 10⁶ base units). All
caps in SPEC-016 are USDC base units (== USD micro-dollars
== credits, by SPEC-005 §5.1 unit identity).

A row whose `provider_credits` exceeds this cap is SKIPPED
with `payout_capped reason=per_payout`. The row remains
`status='ready'`.

The operator MAY split a capped row manually via the SPEC-005
settlement-admin path (out of scope) or MAY raise the cap via
config + restart. v0.1 does NOT auto-split.

### 5.3 Per-day cap

`payout.security.per_day_cap_usdc_base_units` — default
`5_000_000_000` (i.e. $5,000). Computed against a rolling
24h window using `broadcast_at_utc` (NOT `confirmed_at_utc`)
so a broadcast burst cannot bypass the cap during the
confirmation-lag window. v0.1.9 (codex round-10 MAJOR-3
closure) extends the query to ALSO count "reserved" attempts
— rows INSERTed by §4.3 step 5 but not yet broadcast (e.g.
crashed between persist+broadcast, OR a concurrent process
inserting in parallel if the §4.8b lease guard somehow
fails open). Without the reservation count, a parallel
process whose lease check passes (e.g. clock skew during
takeover) could INSERT an unbroadcast live attempt that
the cap query skips because `broadcast_at_utc IS NULL`;
both processes then proceed to broadcast and the day cap
is exceeded.

**Stale-reservation halt (NORMATIVE — codex round-11
MAJOR-1 closure).** v0.1.9's reservation-aware cap used
`updated_at_utc >= :now_minus_24h` to bound the (B)
disjunct so a long-stranded reservation wouldn't pin the
cap indefinitely. Codex round-11 correctly flagged this
as a silent age-out: the row stays non-abandoned + recoverable,
and after 24h it stops counting against the cap — so the
next §4.3 cycle's new reservations PLUS the stale reservation
(when eventually broadcast) can exceed the intended rolling
cap. v0.1.10 fixes this by REMOVING the age bound from the
(B) disjunct and adding a normative halt-check: BEFORE
running the cap sum (inside the SAME §4.3 step 3(b) BEGIN
IMMEDIATE transaction), the IMPL MUST execute:

```sql
SELECT COUNT(*) FROM payout_attempts
 WHERE broadcast_at_utc IS NULL
   AND confirmed_at_utc IS NULL
   AND abandoned_at_utc IS NULL
   AND updated_at_utc < :now_minus_24h;
```

If the count > 0, IMPL MUST ROLLBACK the §4.3 step 3(b)
transaction, emit `payout_invariant_violation
where='stale_unbroadcast_attempt'` per §7.1 (severity=PAGE)
with a list of the offending `(payout_id, attempt_seq,
updated_at_utc)` tuples, and HALT the runner until the
operator either abandons the stale rows via
`/admin/payout/abandon-attempt` (§4.6) or deterministically
recovers and broadcasts them. The halt is fail-closed: a
stale reservation is either a crash-loop loss-of-state (the
attempt got persisted but the broadcast retry path crashed
too) or evidence of compromise; in either case continuing
the runner with stale rows present is unsafe.

```sql
-- Reservation-aware query (NORMATIVE — codex round-10 MAJOR-3,
-- amended by codex round-11 MAJOR-1: no age bound on (B);
-- staleness is enforced by the halt-check above).
SELECT COALESCE(SUM(amount_base_units), 0)
  FROM payout_attempts
 WHERE abandoned_at_utc IS NULL
   AND (
     -- (A) broadcasts in the rolling 24h window
     (broadcast_at_utc IS NOT NULL
      AND broadcast_at_utc >= :now_minus_24h
      AND broadcast_at_utc <= :now)
     OR
     -- (B) ALL live reserved attempts (INSERTed but not yet
     --     broadcast), regardless of age. The §4.3 step 3(b)
     --     stale-reservation halt above guarantees no row
     --     here is older than 24h; if one slips through
     --     (e.g. clock skew across processes), it STILL
     --     counts and any cap breach correctly fires
     --     payout_capped — which is the conservative
     --     behavior (better to refuse a legitimate payout
     --     than to silently over-spend).
     (broadcast_at_utc IS NULL
      AND confirmed_at_utc IS NULL)
   );
```

The candidate row's `amount_base_units` is ADDED to the
above sum INSIDE the §4.3 step 3(b) `BEGIN IMMEDIATE`
transaction before the INSERT — i.e. the cap check
includes the row about to be inserted. The cap check and
the INSERT are atomic; if the candidate row would push
the sum over the cap, the txn ROLLBACKs and `payout_capped`
is emitted.

The query includes `is_cancel_self_transfer = 1` rows so
operator-triggered cancel transfers count against the same
budget. This is INTENTIONAL: a malicious operator-key holder
burning the day cap via cancels (DoS against legitimate
payouts, but no fund drain) is bounded by the §4.6
runtime-immutable abandon caps; with those caps loaded at
startup-only, the worst-case starvation is bounded by the
configured `cancel_max_gas_native_wei_per_24h` + abandon
rate-limit, both of which a compromised operator-key holder
cannot escalate without process restart visibility.

Both sides are in USDC base units; no unit conversion. The
upper bound `<= :now` defeats clock-skew under-counting.

When the next row's amount would push the 24h window past
the cap, the runner SKIPS that row (and subsequent rows)
and emits `payout_daily_cap_tripped`. The runner resumes on
the next cadence cycle whose 24h-window total is below the
cap.

### 5.4 Minimum payout

Inherited from SPEC-005 `MinPayoutCredits`; SPEC-016 MUST
NOT add a second check.

## 6 Hot-wallet operations (FR-P4)

### 6.1 Funding

The operator funds the hot wallet manually. v0.1 has NO
auto-refill path.

### 6.2 Balance monitoring

The runner MUST expose a `GET /admin/payout/balance` JSON
endpoint on the `:8444` listener (operator-key
authenticated):

```json
{
  "from_address": "0x...",
  "usdc_base_units": 12345600,
  "native_wei": 1234567890000000,
  "cancel_gas_native_wei_24h": 0,
  "cancel_gas_native_wei_total": 0,
  "cumulative_funding_usdc_base_units": 100000000,
  "as_of_block": 1234567,
  "as_of_utc": "2026-..."
}
```

The v0.1.4 draft surfaced `last_run_cancel_gas_native_wei`
on this endpoint; v0.1.5 removed it because §4.8 declares
the per-run column observability-only (NOT used for any
cap-check). Surfacing it on a public admin endpoint invited
operator dashboards keying on a value the SPEC warns
against using for decisions.

The `cancel_gas_native_wei_24h` field is computed at request
time from `SUM(payout_attempts.gas_used_native_wei WHERE
is_cancel_self_transfer = 1 AND broadcast_at_utc >= now -
24h)`; `_total` sums lifetime. The per-run
`last_run_cancel_gas_native_wei` field on
`payout_runner_state` is observability only and is NOT
used for cap-checks (it would miss multi-run drain
attacks).

`cumulative_funding_usdc_base_units` is the §4.9
`SUM(payout_hot_wallet_funding.amount_base_units WHERE
to_address = hot_wallet)` (recipient column).

Every invocation emits `payout_balance_queried` per §7.1
(info disclosure trail — operator key holders' read pattern
is auditable).

The runner MUST emit a structured log line every cadence
cycle. When `usdc_base_units < payout.tuning.low_balance_threshold`
(default `2 * payout.security.per_day_cap_usdc_base_units` — a fixed
multiple, NOT a function of `sum(ready rows)` which can grow
unboundedly during a halt), emit `payout_low_balance` at
warning level. Native ETH balance has a separate threshold
`payout.tuning.low_native_threshold` (default `1e16` wei == 0.01
ETH) — when tripped, emit `payout_low_native_balance` (gas
exhaustion would silently halt the runner).

When `usdc_base_units` is insufficient for the next selected
row, the runner SKIPS that row + subsequent rows, emits
`payout_insufficient_funds`, and halts until the next
cadence cycle.

### 6.3 Key custody

The wallet signing key MUST be persisted on-disk in
encrypted form (AES-256-GCM recommended). The AES key-
encryption-key (KEK) MUST be supplied by the operator at
process start via either:

- environment variable `MACPROVIDER_PAYOUT_WALLET_KEK`
  (loaded ONLY into process memory; never echoed; never
  logged; only allowed when systemd `LoadCredential=` is
  not available), OR
- systemd `LoadCredential=` (PREFERRED — sourced from a
  systemd-creds-encrypted blob outside the process cwd).

**Runtime OS:** v0.1.2 SUPPORTS LINUX ONLY for the runner
process. macOS dev environments are EXPLICITLY FORBIDDEN
because (a) macOS Crashreporter writes diagnostic reports
to `~/Library/Logs/DiagnosticReports/` regardless of
`RLIMIT_CORE`, and (b) per
[[macprovider-launchd-amfi-blocker-macos-26]] macOS is the
provider-side dev surface only — the coordinator + payout
runner live on Pearl Linux. IMPL MUST refuse to start the
runner on `runtime.GOOS != "linux"`.

Process hardening REQUIRED at startup:

- `setrlimit(RLIMIT_CORE, 0)` — disables core dumps from
  the kernel side.
- `prctl(PR_SET_DUMPABLE, 0)` — prevents ptrace-attached
  debuggers from reading process memory by the same uid.
- **systemd-coredump bypass check.** Modern systemd-Linux
  configures `kernel.core_pattern` as
  `|/lib/systemd/systemd-coredump`. The kernel pipes cores
  to systemd BEFORE `RLIMIT_CORE` is consulted in many
  configurations. IMPL startup self-test MUST verify:
  `cat /proc/sys/kernel/core_pattern` MUST NOT start with
  `|` AND MUST NOT contain `systemd-coredump`. Fail-loud
  otherwise. Operators who use systemd-coredump MUST override
  `kernel.core_pattern` at the runner host via sysctl (e.g.
  `kernel.core_pattern = core.%p`) — simpler and harder to
  misconfigure than per-unit `Coredump=no`. The "check unit
  for Coredump=no" alternative was dropped in v0.1.3 because
  it required brittle systemd introspection AND the per-PID
  `coredumpctl` check was trivially zero at process startup.
- `mlock` (or `mlockall(MCL_CURRENT|MCL_FUTURE)`) on the
  decrypted key bytes; the return code MUST be checked and
  the process MUST fail-loud on `EPERM` / `ENOMEM` —
  silent fall-back to unpinned memory is FORBIDDEN. IMPL
  MUST add a test asserting `/proc/self/status` shows
  `VmLck` ≥ keysize.
- The coordinator process MUST run as a dedicated uid with
  no login shell; the env-var path (`/proc/<pid>/environ`
  is readable by same-uid processes) is closed by
  same-uid-isolation.

The wallet signing key is decrypted in process memory on
startup and held for the runner's lifetime. The plaintext
MUST NEVER be persisted to disk by the coordinator. The KEK
plaintext MUST NEVER be persisted to disk either.

Signing happens via the package-internal `Signer` interface
defined in `payout/signer.go`. v0.1.2 ships ONE
implementation: the local-file signer described above. The
`Signer` interface is the seam for the v0.2 KMS swap (§6.6);
the §4.3 step 6 sequence is unchanged under v0.2 because the
signed envelope is still received synchronously from the
signer before persistence + broadcast.

The chain-level `nonce` is the idempotency token; the
signed envelope is persisted to `payout_attempts.raw_signed_tx`
BEFORE broadcast (§4.3 step 6) and re-broadcast bit-for-bit
on retry. RFC 6979 deterministic ECDSA is RECOMMENDED for
general ECDSA-nonce-reuse hygiene but is NOT load-bearing
for SPEC-016's idempotency guarantee.

### 6.3.1 Signer interface contract

The package-internal interface in `payout/signer.go` MUST
expose at minimum:

```go
type Signer interface {
    // FromAddress returns the EIP-55-checksummed Ethereum
    // address of the signing key. MUST return the same
    // value for the signer's lifetime.
    FromAddress() string

    // SignTx signs an unsigned EIP-1559 transaction envelope
    // and returns (rawSignedTx, txHash). MUST NOT broadcast.
    //
    // unsignedTxBytes format: EIP-2718 type-prefixed RLP-
    // encoded unsigned EIP-1559 transaction (txType 0x02)
    // with empty signature fields (V, R, S = 0). I.e. the
    // exact bytes that, when keccak256-hashed and signed,
    // produce the signing-hash for an EIP-1559 tx. KMS
    // implementations that require a 32-byte digest input
    // MUST keccak256 the unsignedTxBytes themselves; the
    // SPEC-016 caller does NOT pre-hash.
    //
    // For the same input bytes called twice, the
    // implementation SHOULD return identical output bytes
    // (deterministic ECDSA via RFC 6979) but SPEC-016
    // does NOT depend on determinism for idempotency —
    // the chain-level nonce + raw_signed_tx persistence
    // (§4.3 step 6) is the actual guarantee. ctx supports
    // cancellation; KMS implementations MAY block on a
    // network call; local-file implementations MUST NOT
    // block longer than 100ms.
    SignTx(ctx context.Context, unsignedTxBytes []byte) (rawSignedTx []byte, txHash string, err error)
}

// EIP-712 signature verification (§3.2 step 5) uses ecrecover
// — a public-key operation. It does NOT invoke the Signer
// interface, because verification does not require the
// hot-wallet private key. The Signer interface MUST NOT
// expose any sign-arbitrary-message primitive at v0.1.3
// (footgun: would let a future code path sign anything with
// the hot-wallet key). v0.2 MAY add `SignMessage` on a
// SEPARATELY-keyed signer when an actual production caller
// emerges.
```

Error semantics:

- A nil `err` REQUIRES non-nil `rawSignedTx` AND non-empty
  `txHash`. The runner treats partial returns as a
  protocol violation and panics in tests / fail-loud in
  production.
- `ctx.Err() != nil` paths return `err = ctx.Err()`; the
  runner treats this as transient and retries at the next
  cadence cycle.
- "Wrong chain id" / "key unavailable" / "policy refused
  (KMS)" MUST return a typed error that the runner can
  distinguish from transient — these halt the runner and
  page the operator (`payout_signer_unavailable` per §7.1).
- The implementation MUST NOT log, print, or return the
  signing key in any error path. IMPL audit MUST include
  a regression test asserting this.

The v0.2 KMS substitution implements this exact interface;
no §4.3 step 6 change is required because the synchronous
return contract is preserved. (v0.1.18 codex round-11 LOW-4
closure: prior wording referenced "§4.3 step 5" — stale
since the v0.1.8 §4.3 step renumbering, when the
singleton-runner lease became new step 3 and bumped sign/
build/broadcast from step 5 to step 6.)

### 6.4 Key rotation

Procedure (manual, operator-driven):

1. **Halt the runner AND pause the registration handler.**
   Flip `payout.enabled: false` + flip the in-process flag
   `runtime.registration_paused: true` (per §6.5 the
   `runtime.*` namespace carves out in-process flags that
   are neither security nor tuning config keys — set via
   the §6.4.1 endpoint below). The §3.3 handler returns
   `503 Service Unavailable {"error":"rotation_in_progress"}`
   for the rotation duration. Without this, a provider who
   registers during steps 2–3 stamps
   `registered_against_hot_wallet = <old wallet>` and the
   row is stranded post-rotation.
2. For each `payout_attempts` row with `confirmed_at_utc IS
   NULL AND abandoned_at_utc IS NULL`, the operator MUST
   either wait for confirmation or call
   `POST /admin/payout/abandon-attempt` (§4.6,
   `broadcast_cancel_self_transfer=true`) to push a
   higher-tip self-transfer at the stuck nonce. v0.1.1
   ships this admin endpoint inline.
3. Generate fresh wallet; transfer remaining hot-wallet
   balance to the fresh address (a single regular USDC
   transfer signed by the OLD wallet); rewrite the
   encrypted wallet file + config; rotate the KEK if also
   compromising the on-disk envelope.
4. Restart with `payout.enabled: true`. The restart
   does NOT auto-unpause registration — the
   `runtime.registration_paused` value persists across
   restarts via §4.8a `runtime_flags` table. The operator
   MUST call the §6.4.1 resume endpoint to flip the row
   back to 0 once rotation is complete; the §3.3 handler
   continues to return 503 until that call lands. The
   runner re-syncs the nonce cursor from BOTH RPCs'
   `getTransactionCount` for the new address.
5. **All registered providers MUST re-register their payout
   address against the new hot wallet.** The EIP-712
   `verifyingContract` field in §3.2 step 5 pins to
   `payout.security.hot_wallet_address` — rotating the hot wallet
   invalidates every prior signature's typed-data hash.
   The runner's §4.3 step 1 SELECT filters
   `ppa.registered_against_hot_wallet =
   payout.security.hot_wallet_address`, so post-rotation rows
   registered against the old wallet are SKIPPED until
   re-registration. Operator MUST notify every provider via
   the §9.5a channel (manual email/webhook process) within
   the rotation runbook. Until each provider re-registers,
   their `ledger_payout_ready` backlog accumulates with
   `status='ready'` — not lost, but unpaid.

A future v0.2 MAY add in-process rotation + automatic
provider notification.

### 6.4.1 Pause/resume registration endpoints

```
POST /admin/payout/pause-registration
Authorization: Bearer <operator_key>
Content-Type: application/json

{ "reason": "free-text required (logged)" }

Response:
  200 OK   — runtime.registration_paused flipped 0→1;
             payout_registration_paused (severity=PAGE)
             event emitted per §7.1.
  400      — missing reason.
  409      — already paused (runtime.registration_paused
             is already 1).
  429      — exceeded payout.security.pause_resume_min_interval
             (default 60s).

POST /admin/payout/resume-registration
Authorization: Bearer <operator_key>
Content-Type: application/json

{ "reason": "free-text required (logged)" }

Response:
  200 OK   — runtime.registration_paused flipped 1→0;
             payout_registration_resumed (severity=PAGE)
             event emitted per §7.1.
  400      — missing reason.
  409      — already running (runtime.registration_paused
             is already 0).
  429      — exceeded payout.security.pause_resume_min_interval.
```

Both endpoints MUST be rate-limited by
`payout.security.pause_resume_min_interval` (default 60s)
to prevent an operator-key holder from spamming
pause/resume to defeat rate-limit logging or to mask
malicious activity behind a flood of events.

Both events are severity=PAGE because pausing the
registration handler mid-flight is high-signal
operational state (legitimate use is bounded to §6.4
rotation windows; any other invocation deserves human
eyes).

### 6.5 Config namespaces: security (immutable) vs tuning (hot-reloadable) vs runtime (in-process flags)

**Namespace-bucketing discipline (REQUIRED for every future
SPEC-016 vX.Y).** Every new payout-related identifier MUST
be placed into exactly one of three namespaces at SPEC
write time. Bare `payout.X` keys (without `security.` /
`tuning.` infix) are FORBIDDEN; the v0.1.4 half-refactor
defect was caused by exactly that. The buckets:

- `payout.security.*` — config keys loaded at process
  start, runtime-immutable. Mutating in `coordinator.toml`
  post-start has NO effect until restart.
- `payout.tuning.*` — config keys hot-reloadable via SIGHUP
  with bound re-enforcement (below).
- `runtime.*` — operator-toggleable operational state NOT
  backed by `coordinator.toml`. Mutated via authenticated
  admin endpoints (e.g. `runtime.registration_paused`
  toggled by §6.4.1 pause/resume endpoints; v0.1.x also
  keeps `payout.enabled` as a singleton master switch
  separate from this bucket because it gates whether the
  namespace loaders run at all). Persistence: every
  `runtime.*` flag MUST persist across coordinator
  restarts via the `runtime_flags` SQLite table defined in
  §4.8a (same database file as `payout_runner_state` per
  the same-DB pin discipline). Volatile-only (process-
  memory) `runtime.*` flags are FORBIDDEN — a coordinator
  crash mid-§6.4 rotation between step 1 (pause) and step 4
  (resume) would otherwise silently auto-unpause and re-open
  the rotation-window stranded-row defect that §6.4 step 5
  exists to prevent. **`runtime.*` is a CLOSED namespace
  in v0.1.x.** The ONLY permitted flag is
  `runtime.registration_paused`. Any new `runtime.*` flag
  introduced in a future SPEC-016 minor version MUST: (a)
  have a corresponding admin endpoint with operator-key
  auth + rate-limit, (b) emit a severity=PAGE event on
  every toggle per §7.1, (c) be analyzed in the SPEC
  change-log for operator-key-compromise blast radius, (d)
  NOT bypass any §5 cap, §6.4 rotation gate, or §7.4
  reconciliation surface. Flags that would weaken signer
  binding, RPC pinning, or money-path caps are FORBIDDEN.

`payout.*` config splits into TWO namespaces with distinct
hot-reload semantics:

**`payout.security.*` — RUNTIME-IMMUTABLE.** Loaded only
at process start; SIGHUP / fsnotify / runtime-debug-endpoint
reload is FORBIDDEN. Keys:

- `payout.security.hot_wallet_address`
- `payout.security.rpc_url_primary` /
  `payout.security.rpc_url_secondary`
- `payout.security.per_payout_cap_usdc_base_units`
- `payout.security.per_day_cap_usdc_base_units`
- `payout.security.cancel_max_tip_multiplier`
- `payout.security.cancel_max_gas_native_wei`
- `payout.security.cancel_max_gas_native_wei_per_24h`
- `payout.security.abandon_rate_per_hour`
- `payout.security.chain_recon_interval`
- `payout.security.chain_recon_tolerance_usdc_base_units`
- `payout.security.pause_resume_min_interval` (default 60s;
  rate-limit floor for the §6.4.1 pause/resume endpoint pair —
  immutable so an operator-key-compromise attacker cannot
  hot-edit to 0s and use rate-limit bypass to mask probing.
  See MAJOR-A1 in v0.1.7 change-log for the half-refactor
  defect this enumeration closes.)

These defend against an operator-key-compromised attacker
who could otherwise hot-edit `coordinator.toml` to silence
the §7.4 drift alarm, inflate the cancel-gas budget, or
redirect outflows. Mutating ANY of these in
`coordinator.toml` post-start has NO effect until restart;
IMPL test required.

**`payout.tuning.*` — HOT-RELOADABLE via SIGHUP ONLY.**
Operator MAY mutate `coordinator.toml` + send SIGHUP without
restart; the runner re-reads on the next cadence cycle.
SIGHUP is the ONLY supported trigger — fsnotify
(filesystem watch on the config file) and any reload
endpoint (`POST /admin/payout/reload-config` or similar)
are FORBIDDEN for the tuning namespace. The fsnotify path
would couple the live config to filesystem-watch races; a
reload endpoint would give an operator-key-compromise
attacker an in-process surface that defeats the
security/tuning split (they'd hot-reload tuning keys via
the endpoint without filesystem write). IMPL test MUST
assert tuning values do NOT change when only the config
file mtime advances (no SIGHUP). Each successful reload
emits `payout_config_reloaded` per §7.1 with the key +
old + new values for operator audit trail. **`payout_config_reloaded`
is severity=PAGE** — a hot-reload of any tuning key is a
high-signal operational event (operator-key compromise can
weaponize this surface, see hard floors + reload-time
re-enforcement below). The BetterStack filter (§9
prerequisite item 6) MUST match this event name.

**Reload-time bound re-enforcement (REQUIRED).** Every
config-parse-time bound on a `payout.tuning.*` key MUST
also be re-enforced on hot-reload. A reload request that
violates a bound is REJECTED, the live value is RETAINED,
and `payout_config_reload_rejected` (severity=PAGE per
§7.1) is emitted with the key + violating value + bound.
Without this, an attacker SIGHUP-reload can bypass the
parse-time floor.

**Hard floors / ceilings on hot-reloadable keys (REQUIRED
at parse time AND at every reload):**

- `payout.tuning.address_cooling_off_period` >= 1h.
  Setting below 1h defeats the §3.3 stolen-token defense.
- `payout.tuning.confirmation_blocks` ∈ [5, 200] (v0.1.20
  round-20 M2 closure — was [2, 50]). **Finality model
  (NORMATIVE):** `confirmation_blocks` is a SOFT-finality
  threshold only — soft finality on Base is reached at the
  sequencer; hard finality requires L1 commitment
  (minutes-to-hour latency). The v0.1.19 default `5`
  (~10s) is sized for sub-$100 per-payout amounts on a
  network that has not yet experienced a sequencer
  incident. Base has had ≥7-block reorgs during sequencer
  incidents in 2024-2025; operators MUST size
  `confirmation_blocks` against the per-payout amount.
  Recommended baseline at the default
  `payout.security.per_payout_cap_usdc_base_units =
  1_000_000_000` ($1,000) is `confirmation_blocks >= 30`
  (~60s). The default itself remains `5` in v0.1.20 to
  avoid invalidating Step 1 IMPL behavior; a v0.2 sweep
  may raise the default to track typical per-payout
  amounts. Below 5 is rejected at parse time even though
  v0.1.19 allowed it — operators with config values in
  `[2, 4]` MUST raise to ≥5 before upgrading. The v0.1.19
  default `5` is at the new floor, so operators on default
  config need no action. 200 is the new ceiling (was 50) to
  express L1-commitment-aligned settings for high-value
  payouts.
- `payout.tuning.low_balance_threshold` <= 2 ×
  `payout.security.per_day_cap_usdc_base_units`. The
  v0.1.5 draft used 10× but that allowed silencing the
  alarm for the entire realistic operating range
  ($5k cap × 10 = $50k threshold — well above any actual
  hot-wallet balance). 2× is tight enough to alert
  before the operator funds the next top-up while still
  giving headroom for legitimate transient dips.
- `payout.tuning.low_native_threshold` <= 1e18 (1 ETH —
  prevents disabling the gas-exhaustion alarm).
- `payout.tuning.run_interval` ∈ [5m, 24h].
- `payout.tuning.run_now_min_interval` ∈ [10s, 1h].
- `payout.tuning.max_rows_per_run` ∈ [1, 500].
- `payout.tuning.reorg_poll_window` ∈ [1h, 168h]. Sets the
  window within which already-confirmed PROVIDER-PAYOUT
  rows are re-polled every cadence cycle (v0.1.20 round-20
  M1 closure — see §4.7 "Reorg poll cadence"). Below 1h
  is too tight (a single cycle of RPC outage skips the
  re-poll for hot rows entirely); above 168h is more
  cost than benefit (the §7.4 hourly chain-balance
  reconciliation already catches the drift side-effect of
  any week-old reorg).

Bounds on `payout.tuning.rpc_url_*_pin_spki` are syntactic
(64-hex-char SHA-256 or empty); content-correctness is
operational.

Keys:

- `payout.tuning.run_interval`
- `payout.tuning.confirmation_blocks`
- `payout.tuning.low_balance_threshold`
- `payout.tuning.low_native_threshold`
- `payout.tuning.address_cooling_off_period`
- `payout.tuning.run_now_min_interval`
- `payout.tuning.rpc_url_primary_pin_spki` /
  `payout.tuning.rpc_url_secondary_pin_spki` (cert pinning
  hash is operational hygiene, not security-critical: cert
  rotation by the RPC provider is the legitimate hot-reload
  case)
- `payout.tuning.max_rows_per_run`
- `payout.tuning.reorg_poll_window` (v0.1.20 round-20 M1
  closure — re-poll cadence for already-confirmed rows; see
  §4.7)

Splitting the namespace gives operators tuning headroom
(adjust `confirmation_blocks` after observing first-month
drift patterns without dropping the live money path)
while preserving the security-namespace's threat-model
guarantees against operator-key compromise.

**In-flight `pending_until_utc` rows are NOT recomputed on
`address_cooling_off_period` reload.** A reduction (within
the 1h floor) shortens NEW registrations' cooling-off;
in-flight rows keep their original `pending_until_utc`.
An increase similarly does not extend in-flight rows. This
prevents the attack class where an attacker shortens the
period mid-flight to retroactively drain a queued backlog.

The non-`payout.*` namespace (SPEC-005 / SPEC-014 / SPEC-006
keys) is unaffected by this rule and follows its own
discipline.

### 6.6 KMS / HSM (forward pointer, not normative)

A v0.2 thought-experiment: replace the local encrypted file
with a KMS-backed `Signer` implementation (AWS KMS, GCP KMS,
Vault Transit). v0.1.1 is sufficient because (a) the operator
is a single party, (b) the hot wallet float is small, and (c)
the v0.1 audit surface is materially shorter without remote
signing. The `Signer` interface (§4.1, §6.3) is the seam; no
§4.3 rewrite is required for the swap.

## 7 Auditability & receipts (FR-P5)

### 7.1 Structured logs (operator's source of truth)

Every payout-runner action MUST emit a structured log line
via the existing zerolog setup. Required event names and
minimum field set (all amounts in USDC base units; ALL
operator-key endpoints log actor=operator_key):

| event | fields |
|---|---|
| `payout_run_started` | `run_id, ts_utc` |
| `payout_run_finished` | `run_id, ts_utc, paid, capped, failed, skipped_no_addr, skipped_funds, error_text` |
| `payout_run_now_invoked` | `run_id, actor=operator_key, ts_utc` |
| `payout_paid` | `run_id, payout_id, attempt_seq, provider_id, amount_usdc_base_units, tx_hash, block_number, nonce, ts_utc` |
| `payout_failed` | `run_id, payout_id, attempt_seq, provider_id, stage, error_class, error_text, ts_utc` |
| `payout_capped` | `run_id, payout_id, provider_id, reason, ts_utc` |
| `payout_low_balance` | `from_address, usdc_base_units, threshold_usdc_base_units, ts_utc` |
| `payout_low_native_balance` | `from_address, native_wei, threshold_wei, ts_utc` |
| `payout_insufficient_funds` | `run_id, payout_id, provider_id, required_usdc_base_units, available_usdc_base_units, ts_utc` |
| `payout_daily_cap_tripped` | `run_id, window_paid_usdc_base_units, cap_usdc_base_units, ts_utc` |
| `payout_reorg_revert` (v0.1.15 adds `is_cancel_self_transfer` discriminator; v0.1.20 round-20 M1 closure adds `observed_via`) | `payout_id, attempt_seq, tx_hash, last_seen_block, rpc_source, is_cancel_self_transfer (0=provider-payout reorg per §4.7 provider path; 1=cancel-self-transfer reorg per §4.7 cancel carve-out), observed_via ('reorg_poll_cadence' = caught by the §4.7 mandated re-poll loop; 'incidental' = caught during some other RPC call), ts_utc` |
| `payout_reorg_poll_rpc_error` (severity=WARN; NEW v0.1.20 round-20 M1 closure) | `payout_id, attempt_seq, tx_hash, rpc_source, error_class, ts_utc` |
| `payout_rpc_disagreement` | `payout_id, attempt_seq, rpc_a_state, rpc_b_state, ts_utc` |
| `payout_chain_balance_drift_positive` | `from_address, in_db_expected_usdc_base_units, on_chain_usdc_base_units, drift_usdc_base_units, ts_utc` |
| `payout_chain_balance_drift_negative` (severity=PAGE) | `from_address, in_db_expected_usdc_base_units, on_chain_usdc_base_units, drift_usdc_base_units, ts_utc` |
| `payout_nonce_cold_start_within_tolerance` | `from_address, rpc_a_nonce, rpc_b_nonce, chosen_nonce, ts_utc` |
| `payout_config_reloaded` (severity=PAGE) | `key (payout.tuning.* only), old_value, new_value, actor, ts_utc` |
| `payout_config_reload_rejected` (severity=PAGE) | `key, attempted_value, bound, actor, ts_utc` |
| `payout_registration_paused` (severity=PAGE) | `actor=operator_key, reason, ts_utc` |
| `payout_registration_resumed` (severity=PAGE) | `actor=operator_key, reason, ts_utc` |
| `payout_nonce_gap` | `from_address, expected_nonce, observed_pending_nonce, ts_utc` |
| `payout_attempt_abandoned` (severity=PAGE) | `payout_id, attempt_seq, nonce, cancel_self_transfer_tx_hash, cap_applied, reason, actor=operator_key, ts_utc` |
| `payout_reorg_orphan_recorded` | `payout_id, attempt_seq, orphan_tx_hash, operator_resolution, compensation_settlement_id, reason, actor=operator_key, ts_utc` |
| `payout_reorg_compensation_recorded` | `payout_id, attempt_seq, compensation_settlement_id, reason, actor=operator_key, ts_utc` |
| `payout_funding_recorded` | `from_address, amount_base_units, tx_hash, block_number, source, operator_note, actor=operator_key, ts_utc` |
| `payout_balance_queried` | `from_address, actor=operator_key, ts_utc` |
| `payout_allowed_changed` | `provider_id, old_allowed, new_allowed, reason, actor=operator_key, ts_utc` |
| `payout_signer_unavailable` | `from_address, error_class, ts_utc` |
| `payout_invariant_violation` (severity=PAGE) | `where (enum: 'amount_credit_mismatch' (NEW v0.1.20 round-20 C3 closure), 'attempt_row_missing_during_sign', 'attempt_state_changed_during_sign', 'duplicate live attempt', 'runtime_flag missing', 'runtime_flags_bootstrap_sentinel_missing', 'stale_unbroadcast_attempt', 'trigger missing'), detail, ts_utc` |
| `provider_payout_address_changed` | per §3.4 |
| `provider_payout_address_change_rejected` | `reason, provider_id, src_ip, submitted_fingerprint, ts_utc` |
| `provider_payout_address_rejected_unknown_provider` | `provider_id, submitted_fingerprint, src_ip, ts_utc` |
| `payout_chain_value_mismatch` (severity=PAGE; NEW v0.1.8; v0.1.10 adds `prebroadcast_signed_tx`; v0.1.13 adds `cancel_self_transfer_mismatch`) | `payout_id, attempt_seq, tx_hash, mismatch_class (prebroadcast_signed_tx, input_calldata, sender_recovery, transfer_log_count, transfer_log_to, transfer_log_amount, rpc_disagreement_on_logs, cancel_self_transfer_mismatch), expected, observed, ts_utc` |
| `payout_runner_lease_conflict` (severity=PAGE; NEW v0.1.8) | `local_pid, local_started_at_utc, holder_host, holder_pid, holder_started_at_utc, holder_heartbeat_at_utc, ts_utc` |
| `payout_flag_audit_reaped` (severity=WARN; NEW v0.1.8; v0.1.9 adds `event_id`) | `event_id (=runtime_flag_audit.id), flag_audit_id, flag_name, old_value, new_value, occurred_at_utc, reap_lag_seconds, ts_utc` |
| `payout_runner_lease_taken_over` (severity=PAGE; NEW v0.1.9) | `prior_holder_host, prior_holder_pid, prior_holder_started_at_utc, prior_heartbeat_at_utc, new_holder_host, new_holder_pid, takeover_count, ts_utc` |
| `payout_runner_lease_lost` (severity=PAGE; NEW v0.1.9) | `local_pid, local_holder_token, observed_holder_token, observed_holder_host, observed_holder_pid, ts_utc` |
| `payout_cancel_self_transfer_confirmed` (severity=INFO; NEW v0.1.14; v0.1.15 clarifies transition-only emission) | `run_id, payout_id, attempt_seq, nonce, tx_hash, block_number, gas_used_native_wei, ts_utc` |
| `payout_cancel_self_transfer_reconfirm_stale` (severity=PAGE; NEW v0.1.15; v0.1.17 adds `event_id`) | `event_id (=cancel_reconfirm_stale_outbox.id), run_id, payout_id, attempt_seq, nonce, tx_hash, last_seen_block, updated_at_utc, ts_utc` |
| `payout_stale_outbox_reaped` (severity=WARN; NEW v0.1.17) | `event_id (=cancel_reconfirm_stale_outbox.id), payout_id, attempt_seq, stale_started_at_utc, reap_lag_seconds, ts_utc` |
| `payout_stale_outbox_backlog` (severity=WARN; escalates to PAGE on `scan_ceiling_hit=true`; NEW v0.1.22) | `run_id, limit, produced, total_candidates, scan_ceiling_hit, total_scanned, ts_utc` |
| `payout_rpc_chronic_outage` (severity=PAGE; NEW v0.1.22) | `rpc_label, window_seconds, sample_count, error_count, error_rate, threshold, ts_utc` |
| `payout_spki_drain_skipped_unsupported_client` (severity=WARN; NEW v0.1.22) | `rpc_label, ts_utc` — emitted when an accepted SPKI pin rotation could not drain pooled TLS conns because the RPC client doesn't implement `CloseIdleConnections`. Pooled conns will eventually drain via idle-timeout but until then the OLD pin remains in force on existing connections. |

### 7.1.1 Where these events live

All events listed above are JOURNALCTL-only at v0.1.2 (zerolog
to stdout, captured by systemd-journald, archived per the
existing pipeline + BetterStack filter per §9
prerequisite item 6). SQL-side
promotion of `payout_chain_balance_drift_positive`,
`payout_chain_balance_drift_negative`,
`payout_rpc_disagreement`, `payout_signer_unavailable`, and
`payout_invariant_violation` to the existing audit-store
schema (`phase4-coordinator/internal/audit/store.go`, which
already has `receipt_rotation` + `swap_event`) is a SPEC-016
v0.2 candidate (Appendix B) — deferred because the journalctl
path is sufficient for the v0.1 alert workflow.

Retention: these logs are the operator's source of truth.
IMPL MUST document a 7-year retention default; operator MAY
override per local jurisdiction. Retention is enforced by
the existing journalctl/BetterStack archive pipeline.

### 7.2 Portal surface

SPEC-014 v0.9 (separate follow-up; NOT in this PR) MUST add
a "Payouts" surface that renders, per the requesting
provider's `provider_token`:

- Current registered payout address (or "not set"), plus
  any `pending_until_utc` cooling-off banner.
- Last 50 payouts: `(window_end_utc, provider_credits → USD,
  tx_hash → basescan link, block_number, paid_at_utc)`.
- Pending payouts count + total USD of `ready` rows for
  that provider waiting on address registration or runner
  cycle.

v0.1.1 surfaces the data via:

- `GET /providers/{provider_id}/earnings` (extend response —
  filed as SPEC-005 vX.Y+1 follow-up).
- `GET /providers/{provider_id}/payouts` (NEW; §7.3).

### 7.3 Provider-facing payouts read endpoint

The endpoint and `/providers/{provider_id}/earnings` are
SIBLINGS rather than folded into a single endpoint because
they have different lifecycles: earnings is current-window-
mutable (live accrual), payouts is append-only (cacheable
hours). A future consolidation in a SPEC-005 vX.Y+1
extension MAY collapse them; v0.1 keeps the split to avoid
forcing a cache-invalidation strategy that does not yet
exist.

```
GET /providers/{provider_id}/payouts?limit=50
Authorization: Bearer <provider_token>

200 OK:
{
  "provider_id": "...",
  "registered_address": "0x..." | null,
  "address_pending_until_utc": "..." | null,
  "payout_allowed": true | false,
  "paid": [
    {
      "payout_id": 123,
      "attempt_seq": 1,
      "window_start_utc": "...",
      "window_end_utc": "...",
      "amount_usdc_base_units": 12340000,
      "tx_hash": "0x...",
      "block_number": 1234567,
      "paid_at_utc": "..."
    }
  ],
  "pending": {
    "count": 2,
    "total_amount_usdc_base_units": 5400000
  }
}
```

Same auth contract as `/providers/{id}/earnings`: the
`provider_token` MUST own `provider_id`, else 403.

Rate-limit posture is IDENTICAL to
`/providers/{id}/earnings`: bound by
`endpoints.provider_payouts.rate_limit_per_minute` (default
60); the existing per-provider sliding-window limiter at
`phase4-coordinator/internal/billing/endpoints.go:453-465`
MUST be reused, NOT reimplemented.

### 7.4 Weekly reconciliation queries

The operator MUST be able to run a small set of SQL queries
that confirms in-DB ledger matches on-chain ledger over an
arbitrary window. IMPL MUST commit them as a checked-in file
at `phase4-coordinator/internal/payout/reconcile.sql`.

```sql
-- Per-provider sum of on-chain transfers vs in-DB credits.
-- Units: both sides in USDC base units. By SPEC-005 §5.1 the
-- credit unit identity is 1 credit == $0.000001 == 1 USDC
-- base unit. delta != 0 means either (a) the runner broadcast
-- an amount that doesn't match the row's provider_credits OR
-- (b) DB hand-edit.
SELECT
  lpr.provider_id,
  SUM(lpr.provider_credits) AS in_db_credits,
  SUM(pa.amount_base_units) AS on_chain_usdc_base_units,
  SUM(lpr.provider_credits) - SUM(pa.amount_base_units) AS delta
FROM ledger_payout_ready lpr
INNER JOIN payout_attempts pa ON pa.payout_id = lpr.id
WHERE lpr.status = 'consumed'
  AND lpr.payout_currency = 'USDC-BASE'
  AND pa.confirmed_at_utc IS NOT NULL
  AND pa.abandoned_at_utc IS NULL
  AND pa.is_cancel_self_transfer = 0
  AND pa.confirmed_at_utc >= :from_utc
  AND pa.confirmed_at_utc <  :to_utc
GROUP BY lpr.provider_id
HAVING delta != 0;

-- Catches the silent-invisible regression class: any
-- consumed row with NULL payout_currency is an IMPL bug
-- (ClaimPayoutReady was called without the canonical string).
SELECT id, provider_id, gross_credits, payout_external_id
  FROM ledger_payout_ready
 WHERE status = 'consumed'
   AND payout_currency IS NULL;
```

Any row returned by either query is a reconciliation
failure.

Additionally the runner MUST periodically (every
`payout.security.chain_recon_interval`, default **1h**) query the
USDC contract's
on-chain `balanceOf(hot_wallet)` from BOTH RPCs and
compare against the in-DB expected balance:

```sql
-- expected_balance = total_funded - total_paid_out
-- Cancel self-transfers (is_cancel_self_transfer=1) move
-- 1 base unit hot→hot (net-zero on-chain), so they MUST be
-- excluded from outflow; including them would slowly drift
-- expected below on_chain producing false drift alerts.
SELECT
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_hot_wallet_funding
    WHERE to_address = :hot_wallet)
  -
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_attempts
    WHERE confirmed_at_utc IS NOT NULL
      AND abandoned_at_utc IS NULL
      AND is_cancel_self_transfer = 0
      AND from_address = :hot_wallet);
```

When `|on_chain_balance − expected_balance| >
payout.security.chain_recon_tolerance_usdc_base_units` (default
`100_000` == $0.10), emit a SIGNED drift event per §7.1
and HALT the runner. The sign matters:

- `on_chain − expected > tolerance` →
  `payout_chain_balance_drift_positive` (operator likely
  forgot to record a funding deposit; benign default).
- `on_chain − expected < -tolerance` →
  `payout_chain_balance_drift_negative` (severity=PAGE;
  runbook: "POSSIBLE FAKE FUNDING RECORD — in-DB
  cumulative funding exceeds on-chain balance; cross-check
  basescan for every `source='manual'` row inserted during
  bootstrap"). Negative drift is the signature of the
  operator-key-compromise fake-funding attack class.

Both RPCs MUST agree on `balanceOf(hot_wallet)` within the
same tolerance; RPC disagreement triggers
`payout_rpc_disagreement` instead.

The §4.9 `payout_hot_wallet_funding` table is the ground
truth for the funding side; if the operator forgets to
record a deposit, the positive-drift alert fires (benign
default interpretation).

Reconciliation also surfaces stale orphans:

```sql
-- (A) Orphans unresolved >30d signal compensation neglect /
-- favoritism. Operator must either resolve with a
-- compensation_settlement_id or document
-- operator_resolution as 'no compensation'.
SELECT id, payout_id, attempt_seq, orphan_tx_hash, observed_at_utc
  FROM payout_reorg_orphans
 WHERE resolved_at_utc IS NULL
   AND observed_at_utc < :now_minus_30d;

-- (B) Compensation FORGERY detection — any orphan whose
-- compensation_settlement_id references a row that no longer
-- exists. Hand-edit / silent delete signal.
SELECT pro.id, pro.payout_id, pro.attempt_seq, pro.compensation_settlement_id
  FROM payout_reorg_orphans pro
 WHERE pro.compensation_settlement_id IS NOT NULL
   AND pro.compensation_settlement_id NOT IN
       (SELECT id FROM ledger_payout_ready);

-- (C) Detect ledger_payout_ready rows whose idempotency_key
-- matches the reorg_compensation:* pattern (created via the
-- SPEC-005 admin endpoint) but have no corresponding orphan
-- row linking back. Fake-compensation signal.
SELECT lpr.id, lpr.provider_id, lpr.idempotency_key, lpr.gross_credits
  FROM ledger_payout_ready lpr
 WHERE lpr.idempotency_key LIKE 'reorg_compensation:%'
   AND lpr.id NOT IN
       (SELECT compensation_settlement_id FROM payout_reorg_orphans
         WHERE compensation_settlement_id IS NOT NULL);
```

Any row returned by (B) or (C) is a SECURITY incident: the
operator MUST investigate whether an operator-key compromise
or DB hand-edit produced an off-the-books compensation. The
queries are intentionally read-only — the SPEC does NOT
auto-remediate; operator judgment is the response gate.

The operator MAY ALSO cross-check via Etherscan/Basescan
export of hot-wallet transfers; that cross-check is
procedural and NOT specified.

**Cancel observability query (D) — NEW v0.1.14, codex
round-15 MEDIUM-1 closure.** Confirmed cancel
self-transfers do NOT consume `ledger_payout_ready` and are
intentionally excluded from the outflow sums above (which
would otherwise double-count cancel gas vs the
`cancel_gas_native_wei_24h` aggregate). They DO need
operator-visible observability — gas burned on cancels is
real money out the hot-wallet door. Operators run query (D)
on the same weekly cadence:

```sql
-- (D) Cancel self-transfer observability roll-up.
SELECT payout_id, attempt_seq, nonce, tx_hash,
       confirmed_at_utc, block_number,
       gas_used_native_wei
  FROM payout_attempts
 WHERE is_cancel_self_transfer = 1
   AND confirmed_at_utc >= :from_utc
   AND confirmed_at_utc <  :to_utc
 ORDER BY confirmed_at_utc ASC;
```

The result joined against §6.2's
`cancel_gas_native_wei_24h` aggregate gives operators a
ground-truth audit of every gas-burning cancel event.
Query (D) is OBSERVABILITY ONLY — the result MUST NOT be
added to provider outflow sums (queries (A) and (B)
above). Pair with the new `payout_cancel_self_transfer_confirmed`
§7.1 event for per-event visibility and the per-week query
for roll-up reconciliation.

```sql
-- (E) Hot-wallet self-funding detection (v0.1.20 round-20
-- C2 closure). Any funding row where the source equals the
-- destination is a hard payout_invariant_violation — the
-- hot wallet cannot legally fund itself; this row is
-- either an operator-key compromise fake-funding attempt
-- (worst case) or a hand-edit (still bad). The §4.9
-- endpoint rejects from_address == to_address at insertion;
-- query (E) catches any row that slipped past validation
-- (DB hand-edit, schema drift, future endpoint adding the
-- same data shape without the from/to check).
SELECT id, from_address, to_address, amount_base_units,
       tx_hash, block_number, observed_at_utc, source
  FROM payout_hot_wallet_funding
 WHERE lower(from_address) = lower(to_address);

-- (F) Money-conservation invariant (v0.1.20 round-20 M5
-- closure). The load-bearing aggregate invariant on the
-- payout pipeline: sum of consumed ledger credits MUST
-- equal sum of confirmed non-abandoned non-cancel
-- on-chain transfers. Any non-zero conservation_delta is
-- a money-correctness incident, NOT a warning. Query (A)
-- catches per-provider drift but does not name the
-- aggregate invariant; query (F) is the canonical check.
SELECT
  (SELECT COALESCE(SUM(provider_credits), 0)
     FROM ledger_payout_ready
    WHERE status = 'consumed'
      AND payout_currency = 'USDC-BASE')
  -
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_attempts pa
     INNER JOIN ledger_payout_ready lpr
        ON lpr.id = pa.payout_id
    WHERE lpr.status = 'consumed'
      AND lpr.payout_currency = 'USDC-BASE'
      AND pa.confirmed_at_utc IS NOT NULL
      AND pa.abandoned_at_utc IS NULL
      AND pa.is_cancel_self_transfer = 0)
  AS conservation_delta;
```

**Operational binding for query (F) (NORMATIVE — v0.1.20
round-20 M5 closure).** The operator MUST run query (F)
weekly. ANY non-zero `conservation_delta` is a SEV-1
incident: the operator MUST halt the runner via
`/admin/payout/runtime-flags` (`payout.enabled=false`)
until the drift source is identified and resolved. Query
(F) supersedes query (A) as the canonical money-
conservation check at v0.1.20; (A) remains useful for
per-provider attribution when (F) is non-zero. Query (E)
is paired with (F) — operators run BOTH on the same
cadence (a non-zero (E) likely manifests as a non-zero (F)
if the fake-funding has not yet been paid out, but (E)
identifies the row directly).

## 8 Compliance posture (FR-P6)

SPEC-016 takes NO position on the operator's KYC / AML
obligations. The technical machinery is rail-agnostic to
compliance state — a `ledger_payout_ready` row may be in
`status='ready'` and the runner gates separately on
`provider_payout_addresses.payout_allowed = 1` (§3.1).

The operator MUST consult counsel before flipping the runner
on for any provider in a regulated jurisdiction. The operator
controls eligibility via:

```
POST /admin/payout/allow
Authorization: Bearer <operator_key>
Content-Type: application/json

{ "provider_id": "...", "allowed": true,
  "reason": "free-text required (logged)" }

Response:
  200 OK   — transition recorded; structured log emitted.
  400      — missing reason.
```

Toggling `payout_allowed=0` does NOT void existing
`ledger_payout_ready` rows; it only prevents the runner from
selecting them in §4.3 step 1. Restoration to `allowed=1`
resumes payout on the next cadence cycle.

`payout_allowed_changed` log line per §7.1.

## 9 Operator-action prerequisites before IMPL ships

IMPL MUST NOT begin until ALL EIGHT prerequisites are
discharged:

1. **Hot wallet provisioned + funded.** Fresh Base address (or
   designated single-purpose address), funded with USDC for
   initial smoke (suggested 100 USDC) and ~$5 native ETH for
   gas headroom. Encrypted wallet file generated; KEK loaded
   via systemd `LoadCredential=` (preferred) or env var.
   Address pinned in `payout.security.hot_wallet_address`.
2. **TWO RPC providers chosen + API keys provisioned.**
   v0.1.1 REQUIRES two independent RPCs for receipt
   cross-confirmation (§4.4). Different operators (e.g.
   Alchemy + QuickNode), ideally different ASNs. Both URLs +
   keys pinned in `payout.security.rpc_url_primary` and
   `payout.security.rpc_url_secondary`. v0.1's single-RPC framing is
   superseded.
3. **Cap decisions.** Operator sets
   `payout.security.per_payout_cap_usdc_base_units`,
   `payout.security.per_day_cap_usdc_base_units`,
   `payout.tuning.run_interval`,
   `payout.tuning.confirmation_blocks`,
   `payout.tuning.address_cooling_off_period`,
   `payout.security.cancel_max_tip_multiplier`,
   `payout.security.abandon_rate_per_hour`,
   `payout.security.chain_recon_interval`,
   `payout.security.chain_recon_tolerance_usdc_base_units`.
4. **Compliance posture decision.** Initial bulk
   `payout_allowed` set; policy that gates future
   provider eligibility documented.
5. **SPEC-014 v0.9 portal screens** for payout-address
   registration + payout history. IMPL MAY ship the
   registration ENDPOINT before SPEC-014 v0.9 if the operator
   uses `curl` for the initial provider set. Constraints on
   the curl path:

   - The EIP-712 signature (§3.2 step 5) MUST be produced by
     the PROVIDER, not the operator. The provider runs e.g.
     `cast wallet sign` against their own private key,
     produces the signature, and sends it to the operator
     out-of-band (email, signal, secure channel). The operator
     MUST NEVER touch the provider's private key — doing so
     subverts the entire proof-of-possession threat model.
   - The operator's curl command relays the provider-produced
     signature in the POST body verbatim; no signing happens
     operator-side.
   This part of item 5 is SOFT.

5a. **Manual provider-notification channel HARD prerequisite.**
   The §3.3 cooling-off banner is the legitimate-provider's
   out-of-band notice that an unexpected rotation happened.
   Without SPEC-014 v0.9's portal banner, that signal does
   not reach the provider. IMPL MUST NOT ship without the
   operator having a documented manual notification process
   (email or webhook to the provider) that fires on every
   `provider_payout_address_changed` event until SPEC-014
   v0.9 lands. The §3.2 EIP-712 proof-of-possession defeats
   most of the C2 threat class but does NOT defeat the case
   where a provider's wallet itself is compromised — the
   notification is the human-in-the-loop backstop.

5b. **SPEC-005 vX.Y+1 `POST /admin/ledger/payout-ready`
   admin endpoint — HARD PREREQUISITE.** v0.1.2 marked this
   as SOFT with a manual SQL fallback; the v0.1.2 manual SQL
   recipe was non-executable (omitted required columns + had
   a `UNIQUE(provider_id, window_start_utc, window_end_utc)`
   collision risk). v0.1.3 REMOVES the manual SQL fallback
   entirely. IMPL MUST NOT ship the payout runner without
   SPEC-005 vX.Y+1 also shipping the admin endpoint; the
   §4.7 reorg-compensation flow has no other safe path.

   **§9.5b.1 — Normative SPEC-005 vX.Y+1 contract surface
   required by SPEC-016.** SPEC-005 author can implement
   cold against this contract without consulting SPEC-016:

   ```
   POST /admin/ledger/payout-ready
   Authorization: Bearer <operator_key>
   Content-Type: application/json
   Idempotency-Key: <opaque>

   { "provider_id":      "<provider id>",
     "gross_credits":    <int>,
     "provider_credits": <int>,
     "operator_credits": 0,
     "cadence_days":     1,
     "source_credit_count": 1,
     "min_payout_credits_override": 0,
     "idempotency_key":  "reorg_compensation:<orig_payout_id>:<orig_attempt_seq>",
     "window_start_utc": "<RFC3339Nano synthetic — orphan observation time>",
     "window_end_utc":   "<RFC3339Nano synthetic — orphan observation time + 1µs * orphan_id>",
     "reason":           "<free-text required>" }

   Response:
     201 Created — { "id": <int> } — fresh
                   ledger_payout_ready row inserted with
                   status='ready', payout_currency=NULL,
                   payout_external_id=NULL. Field name is
                   `id` (matches SPEC-005's column name on
                   `ledger_payout_ready`).
     400         — missing required field, or
                   idempotency_key does not match
                   `^reorg_compensation:\d+:\d+$`, or the
                   `Idempotency-Key` HTTP header is not
                   byte-equal to the JSON body
                   `idempotency_key` field (closes codex
                   round-9 MED-8: replay-detection
                   referenced the header while
                   reconciliation depends on the body/DB
                   key — equality MUST be enforced).
     409 Conflict — Idempotency-Key replay (return the
                   original 201 response body).
     422         — provider_id not found in provider_tokens,
                   OR `gross_credits != provider_credits`
                   (v0.1.8 STRICT EQUALITY — closes codex
                   round-9 MED-9: since `operator_credits`
                   is pinned to 0 by §9.5b.1 contract,
                   SPEC-005's invariant
                   `provider_credits + operator_credits ==
                   gross_credits` collapses to strict
                   equality; the v0.1.7 wording
                   `provider_credits > gross_credits` was
                   asymmetric and admitted
                   `provider_credits < gross_credits` —
                   that case would skim USDC into the
                   reconciliation drift unaccountably),
                   OR provider_credits exceeds
                   payout.security.per_payout_cap_usdc_base_units,
                   OR no matching unresolved orphan record,
                   OR orphan-binding mismatch (codex
                   round-9 CRIT-1 + round-10 MED-6 align
                   summary with detail): request
                   provider_id does not equal
                   pro.observed_provider_id, OR request
                   provider_credits does not equal
                   pro.observed_provider_credits, OR
                   request gross_credits does not equal
                   pro.observed_provider_credits (NOTE:
                   the compensation gross MUST equal the
                   observed PROVIDER credits, not the
                   observed gross — operator share is
                   pinned to 0), OR request
                   operator_credits != 0. See normative
                   requirements below.
   ```

   Normative requirements on the SPEC-005 IMPL:

   - The endpoint MUST honor the `min_payout_credits_override:
     0` field by inserting `min_payout_credits = 0` on the
     row, bypassing the SPEC-005 §5 minimum threshold. The
     orphan being compensated already cleared the threshold
     at original-payment time; the compensation MUST NOT
     re-test it.
   - The endpoint MUST NOT trigger a fresh settlement run.
     The row is inserted directly into
     `ledger_payout_ready`, not into
     `ledger_request_credits`. There is no `settlement_id`
     linkage on the underlying request rows because the
     compensation is operator-funded out of band, not
     accrual-funded.
   - The `idempotency_key` MUST use the exact prefix
     `reorg_compensation:` — SPEC-016 §7.4 reconciliation
     query (C) LIKE-matches this prefix to detect
     compensation rows without a corresponding
     `payout_reorg_orphans` entry.
   - The `window_start_utc` / `window_end_utc` are
     SYNTHETIC values used to satisfy SPEC-005's
     `UNIQUE(provider_id, window_start_utc, window_end_utc)`
     constraint. The `+ 1µs * orphan_id` offset on the end
     prevents collision when multiple orphans for the same
     provider are observed in the same nanosecond.
   - Every successful invocation MUST emit a SPEC-005
     structured log event
     `ledger_payout_ready_admin_inserted` with
     `provider_id, id, idempotency_key, reason,
     actor=operator_key, ts_utc` so the operator audit
     trail covers admin-inserted rows separately from
     settlement-emitted rows.
   - **The SPEC-005 IMPL MUST bind the compensation row to
     the original orphan's IMMUTABLE snapshot columns in
     the SAME SQLite transaction as the INSERT.** Closes
     codex round-9 CRIT-1 + round-10 MED-5: the binding is
     to `payout_reorg_orphans.observed_*` (snapshot at
     orphan-observation time per §4.7), NOT to
     `ledger_payout_ready.*` (mutable). v0.1.8 originally
     bound to current `lpr.*` values; v0.1.9 (codex round-10
     MED-5 closure) tightens to the snapshot columns so a
     compromised operator-key calling a future SPEC-005
     ledger-mutation endpoint cannot change what
     compensation is allowed for an already-observed
     orphan. v0.1.9 (codex round-10 CRIT-1 framing):
     the IMPL MUST parse `orig_payout_id` and
     `orig_attempt_seq` from the `idempotency_key` regex
     match, then `SELECT
     observed_provider_id,
     observed_provider_credits,
     observed_gross_credits,
     observed_amount_base_units,
     compensation_settlement_id
     FROM payout_reorg_orphans
     WHERE payout_id = <orig_payout_id>
     AND attempt_seq = <orig_attempt_seq>`
     in the SAME SQLite transaction as the INSERT, and
     assert ALL of:
     - exactly one row returned (else 422
       `no_matching_orphan`)
     - `compensation_settlement_id IS NULL` (else 422
       `orphan_already_compensated`)
     - request `provider_id = observed_provider_id`
     - request `provider_credits = observed_provider_credits`
     - request `gross_credits = observed_provider_credits`
       (NOTE: equals `observed_provider_credits`, NOT
       `observed_gross_credits` — the compensation is
       provider-only, no operator share, per the
       `operator_credits = 0` pin below; the original
       `observed_gross_credits` is recorded for audit
       trail but not used as the compensation target)
     - request `operator_credits = 0`

     Any miss returns 422 `orphan_mismatch` with a body
     field naming which assertion failed. This defeats the
     operator-key-compromise high-leverage drain (an
     attacker who can call this endpoint MUST first
     manufacture a `payout_reorg_orphans` row via
     `/admin/payout/record-orphan` for the EXACT amount AND
     provider — which is detectable by the §7.4 stale-orphan
     reconciliation query: no real `payout_attempts` row
     corresponds to a fake orphan; query (B) catches the
     inverse case where the compensation references a
     non-existent ledger row).
   - **Per-call cap.** The SPEC-005 IMPL MUST cap
     `provider_credits` at
     `payout.security.per_payout_cap_usdc_base_units` (the
     same per-payout cap §5.2 enforces on the runner).
     This makes compensation rows subject to the same
     blast-radius bound as settlement rows; an
     over-cap compensation requires operator splitting
     across multiple calls.
   - **Trigger name binding (cross-spec contract).**
     SPEC-005 vX.Y+1 MUST **preserve** the existing trigger
     `trg_lpr_terminal_status_guard` on `ledger_payout_ready`
     with that EXACT NAME (case-sensitive). The trigger
     already exists today at
     `phase4-coordinator/internal/billing/store.go:121-126`;
     the cross-spec contract is that SPEC-005 MUST NOT rename
     or drop it across schema migrations (it would
     be valid for SPEC-005 to re-issue the same
     `CREATE TRIGGER IF NOT EXISTS` for idempotency, but not
     to `DROP TRIGGER` it). SPEC-016 §4.8 asserts presence
     by exact name at every cadence cycle; a rename in a
     future SPEC-005 schema migration halts the SPEC-016
     runner cycle 1. Any future rename MUST be coordinated
     with a SPEC-016 minor-version bump.
   - **Same-SQLite-DB requirement.** The SPEC-005 admin
     endpoint MUST query `payout_reorg_orphans` (SPEC-016-
     owned, created in `payout/orphans.go`) in the SAME
     SQLite transaction as the `ledger_payout_ready`
     INSERT. For this to be possible, `payout_reorg_orphans`
     MUST live in the same SQLite database file as
     `ledger_payout_ready` (cf. §4.7 normative pin). SPEC-005
     vX.Y+1 IMPL MUST use the same `*sql.DB` handle — a
     separate DB connection cannot satisfy "same SQLite
     transaction".
6. **BetterStack alert filter extended** to match EVERY
   §7.1 event with severity=PAGE or severity=WARN.
   v0.1.9 (codex round-10 MED-8 closure) makes this
   discipline normative — past versions enumerated a
   subset and silently missed events added by later
   minor revisions. The CURRENT minimum filter set
   (always re-verify against §7.1 at IMPL time):
   - `payout_low_balance` (WARN)
   - `payout_low_native_balance` (WARN)
   - `payout_insufficient_funds` (PAGE)
   - `payout_reorg_revert` (PAGE)
   - `payout_rpc_disagreement` (PAGE)
   - `payout_chain_balance_drift_positive` (WARN)
   - `payout_chain_balance_drift_negative` (PAGE)
   - `payout_nonce_gap` (WARN)
   - `payout_capped` (INFO — but include if operator wants
     visibility into cap-trip churn)
   - `payout_failed` (PAGE)
   - `payout_attempt_abandoned` (PAGE)
   - `payout_config_reloaded` (PAGE)
   - `payout_config_reload_rejected` (PAGE)
   - `payout_registration_paused` (PAGE — v0.1.6)
   - `payout_registration_resumed` (PAGE — v0.1.6)
   - `payout_invariant_violation` (PAGE)
   - `payout_signer_unavailable` (PAGE)
   - `payout_chain_value_mismatch` (PAGE — NEW v0.1.8)
   - `payout_runner_lease_conflict` (PAGE — NEW v0.1.8)
   - `payout_flag_audit_reaped` (WARN — NEW v0.1.8)
   - `payout_runner_lease_taken_over` (PAGE — NEW v0.1.9)
   - `payout_runner_lease_lost` (PAGE — NEW v0.1.9)
   - `payout_cancel_self_transfer_confirmed` (INFO — NEW v0.1.14; OPTIONAL for the alert filter, INFO not PAGE/WARN, but include if operator wants per-cancel visibility)
   - `payout_cancel_self_transfer_reconfirm_stale` (PAGE — NEW v0.1.15)
   - `payout_stale_outbox_reaped` (WARN — NEW v0.1.17)
   - `payout_stale_outbox_backlog` (WARN — NEW v0.1.22; A1: §4.7 step 5 production capped before candidate set exhausted)
   - `payout_rpc_chronic_outage` (PAGE — NEW v0.1.22; A2: per-RPC sliding-window error rate crossed threshold)
   - `payout_spki_drain_skipped_unsupported_client` (WARN — NEW v0.1.22; verify per `rpc_label` value: `primary` AND `secondary`)
   - `provider_payout_address_change_rejected` (WARN)
   - `provider_payout_address_rejected_unknown_provider` (WARN)

   Operator MUST verify with ONE synthetic alert per
   ENUMERATED PAGE/WARN event NAME (NOT one per severity
   tier — codex round-11 MED-2 closure) before flipping
   `payout.enabled: true`. The per-event verification
   catches typos and missing matchers in the BetterStack
   filter config that a per-severity-tier check would
   silently miss (e.g. `payout_runner_lease_lost` typo'd
   as `payout_runner_lease_lst` still passes the
   "at least one PAGE alert fires" test). (Per
   [[deve2-betterstack-live]], BetterStack monitor config
   lives in the BetterStack UI, not the repo.) Future
   SPEC-016 vX.Y MUST extend this list when adding any
   new PAGE/WARN event AND verify with a synthetic alert
   for the new event name as part of the version's
   go-live gate.
7. **Nginx routing on Pearl VPS** updated to proxy
   `/providers/{id}/payout-address`,
   `/providers/{id}/payouts`, and the new `/admin/payout/*`
   endpoints through `coordinator.streamvc.live → :8444`;
   portal CORS verified. The `coordinator.streamvc.live`
   config is the touchpoint, NOT `portal.streamvc.live`.
8. **Backup + restore** for the encrypted wallet file AND
   the KEK on separate media (NOT the same VPS). Loss of
   EITHER = total loss of access to hot-wallet funds. The
   operator's existing secrets-management process applies;
   v0.1 only requires that the operator confirm a
   restore-from-backup dry run has been validated before
   IMPL enables the runner.

SPEC-002 sufficiency note for §3.3: SPEC-002 FR-P12 tokens
are operator-issued or self-minted (FR-C9.4 provisional). A
self-minted provisional token MAY register a payout address
under v0.1.1 — but the operator MAY (compliance posture
decision in item 4) flip `payout_allowed=0` for all
provisional-tier providers until promoted to pinned, by
joining `provider_payout_addresses` to the SPEC-002 token-tier
data at operator-discretion. The operator decision is
documented inline as part of item 4.

Without items 1, 2, 3, 4, 5a, 5b, 6, 7, 8 (item 5 itself
is the only soft prerequisite), IMPL is blocked.

---

## Appendix A — IMPL prompt name

The next deliverable (NOT created in this PR) is
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`, authored in a
fresh session after this v0.1.x merges. That prompt will:

- Reference this SPEC at v0.1.x as the controlling contract.
- Carry the §9 prerequisites as a pre-flight checklist.
- Run the SPEC-audit-loop discipline applied to IMPL work per
  [[feedback-build-audit-loop]].
- Acknowledge the §6.5 namespace split: IMPL must ship TWO
  config-loader code paths — immutable-at-startup for
  `payout.security.*` (load once, fail-loud on any later
  reload attempt) and SIGHUP-reloadable for
  `payout.tuning.*` (with bound re-enforcement per §6.5 +
  `payout_config_reloaded` / `payout_config_reload_rejected`
  PAGE events per §7.1). This is non-trivial structurally
  and may justify splitting the IMPL into stepped prompts
  (STEP_1 schema + addresses, STEP_2 runner + RPC + signer,
  STEP_3 admin + funding + orphan, STEP_4 reconciliation +
  config-loader-split + ops) per the SPEC-015 stepped-IMPL
  pattern.

## Appendix B — Deferred follow-ups (filed as Issue stubs, not inlined)

- SPEC-014 v0.9: payout-address registration screen + payout
  history surface. Consumes §3.3 and §7.3.
- SPEC-005 vX.Y+1: extend `/providers/{id}/earnings` response
  with `next_payout_eta`, `last_payout_tx_hash`,
  `last_payout_paid_at_utc`. Pure additive; SPEC-016 v0.1
  does NOT require it.
- SPEC-016 v0.2 candidates: KMS-backed `Signer`
  implementation (§6.6, satisfying the §6.3.1 interface
  contract unchanged); auto-split of over-cap payouts
  (§5.2); RPC fallback rotation (v0.1.x requires TWO RPCs
  in agreement; v0.2 MAY add N-of-M voting); in-process
  key rotation (§6.4); automated nonce-gap fill (§4.6,
  replacing the operator-driven
  `/admin/payout/abandon-attempt` flow); collapse
  `/providers/{id}/earnings` and `/providers/{id}/payouts`
  into one endpoint with a versioned schema; SQL-side
  promotion of journalctl-only events
  (`payout_chain_balance_drift_positive`,
  `payout_chain_balance_drift_negative`,
  `payout_rpc_disagreement`,
  `payout_signer_unavailable`, `payout_invariant_violation`)
  into `phase4-coordinator/internal/audit/store.go`. NOTE:
  `/admin/payout/abandon-attempt` (§4.6),
  `/admin/payout/record-orphan` (§4.7), and
  `/admin/payout/record-funding` (§4.9) are IN-SCOPE for
  v0.1.x; the earlier-draft `/admin/payout/void`
  status-mutating endpoint was removed in v0.1.1.
- SPEC-005 vX.Y+1 candidate (HARD §9.5b prerequisite):
  add a `POST /admin/ledger/payout-ready` operator-key admin
  endpoint that inserts a fresh `ledger_payout_ready` row,
  to replace the §4.7 manual SQL compensation procedure
  with a structurally-audited admin surface. **Normative
  contract surface is pinned in §9.5b.1; SPEC-005 author
  can implement cold against it.**
- SPEC-005 v0.4 + SPEC-014 v0.9 cross-reference candidate:
  add a one-line normative note to SPEC-005 §10 and
  SPEC-014 §0 along the lines of "**SPEC-016 Linux-only
  constraint.** If the operator enables `payout.enabled=true`
  per SPEC-016 §2, this entire coordinator process inherits
  the Linux-only requirement from SPEC-016 §6.3." This
  surfaces the Linux-only transitivity to readers of those
  specs who never read SPEC-016.
- SPEC-016 v0.2: move §9.5b.1 normative contract surface
  into SPEC-005 vX.Y+2 (AFTER SPEC-005 vX.Y+1 IMPL lands
  and the contract has stabilised). The cross-spec
  ownership inversion (SPEC-016 owning the SPEC-005
  endpoint contract) was an acceptable v0.1.x trade-off
  but is anti-pattern long-term. SPEC-016 v0.2 retains a
  one-line pointer ("see SPEC-005 §X.Y for the admin
  endpoint contract"); SPEC-005 owns the canonical text.
- SPEC-014 v0.9: extend §7.3 `/providers/{id}/payouts`
  response with `registered_against_current_hot_wallet:
  bool` so the portal can render "pending re-registration
  after key rotation" state without joining against
  `payout.security.hot_wallet_address` (which the portal
  shouldn't see directly). The boolean is computed
  server-side as `registered_against_hot_wallet ==
  payout.security.hot_wallet_address`.
- SPEC-016 v0.2 candidate (#165 R4 arch LOW closure):
  revisit the defensive `staleOutboxScanCeiling = 20000`
  cap on the §4.7 step-5 producer. Trigger conditions:
  sustained `payout_stale_outbox_backlog scan_ceiling_hit=true`
  observations in production OR provider count / cancel
  backlog depth grows enough that 20000 rows per cycle is
  no longer comfortable headroom. Decision options:
  (a) raise the ceiling (cheap if `idx_pa_stale_cancel_keyset`
  scales linearly), (b) shorten the runner cycle, (c) split
  to a dedicated stale-cancel reconciliation worker
  (heaviest; only if the producer cycle starts blowing past
  its wall-clock budget). v0.1.22 ships with 20000 because
  it's well above expected v0.1 scale.
- SPEC-016 v0.2 candidate (#165 R4 sec MEDIUM closure):
  add a build-time CI check that enforces SPEC §7.1 +
  SPEC §9 alert-filter + `dist/payout-runbook.md` §3 stay
  in sync with the code's emit-event-name set. Currently
  each must be hand-edited per release; the v0.1.22 audit
  required four parallel edits to land
  `payout_spki_drain_skipped_unsupported_client`. A
  reflection-based or `go generate`-based check would
  catch drift at PR time.
- SPEC-016 v0.2 (filed by v0.1.7 round-8 SEC-MED): replace
  the one-table-at-a-time same-DB pins (`provider_payout_
  addresses` in §3.1; `payout_reorg_orphans` in §4.7;
  `runtime_flags` in §4.8a; `payout_runner_lease` in §4.8b)
  with a single top-level §4.0a "ALL SPEC-016 tables in
  the same SQLite DB as SPEC-005's `ledger_payout_ready`"
  normative paragraph + an IMPL test that asserts via
  `PRAGMA database_list` from both module entry points.
  Closes a class of "next-table-forgot-the-pin"
  regression. Bundled with the §9.5b.1 ownership-inversion
  cleanup above so SPEC-005 v0.4 lands the shared-DB
  contract on the canonical side.
- SPEC-016 v0.2 (filed by v0.1.7 round-8 CODE-MAJOR,
  carried forward in v0.1.9 codex round-10 LOW-15
  closure): asymmetric rate-limit on the §6.4.1
  pause/resume endpoint pair. Codex round-9 flagged the
  60s symmetric rate-limit as a DoS amplifier — a
  compromised operator-key holder hits pause once and
  the legitimate operator cannot resume for 60s. v0.2
  candidate: pause = rate-limited, resume = unrate-limited
  OR rate-limited at higher resolution; OR add a
  challenge-token mint endpoint that the resume call
  consumes.
- SPEC-016 v0.2 (filed by v0.1.7 round-8 CODE-MED):
  §4.8 references `cmd/coordinator/main.go` as a
  normative implementation pin. v0.2 candidate: reword
  to "during coordinator process startup BEFORE the
  payout runner is started (synchronous happens-before
  on the same `*sql.DB` handle)" + move the file path
  to implementation guidance. Bundle with v0.2
  normative-vs-implementation-guidance sweep across
  the whole spec.
- SPEC-016 v0.2 (filed by v0.1.7 round-8 CODE-MED):
  `payout.enabled` master-switch carve-out wording is
  too loose; future authors could argue any key is a
  "master switch". v0.2: tighten to "ONLY
  `payout.enabled` is permitted as a bare `payout.*`
  key; this is grandfathered for backwards compatibility
  with v0.1.0. NO new bare `payout.X` keys MAY be added
  in any future SPEC-016 vX.Y."
- SPEC-016 v0.2 (filed by v0.1.7 round-8 ARCH-MED,
  carried forward in v0.1.9 codex round-10 LOW-15
  closure): rename `runtime.*` → `payout.runtime.*` for
  prefix discipline. The current `runtime.*` namespace
  is top-level, not under `payout.*` — a future SPEC-NNN
  wanting in-process flags would collide. Deferred
  because v0.1.x already churned namespaces three times;
  fold into the v0.2 ownership-inversion + global same-DB
  pin batch.
- SPEC-016 v0.2 (filed by v0.1.7 round-8 ARCH-MED,
  partially closed in v0.1.7 §6.5 CLOSED-namespace
  declaration): formalize a per-SPEC namespace-bucket
  audit that compares the in-prose enumerated keys list
  against grep of every `payout.*` reference in the body.
  Half-refactor regressions are the dominant defect
  class across rounds 2-8 of SPEC-016; an IMPL test
  asserting "every `payout.*` mentioned in §3-§9 appears
  in the §6.5 enumeration" would lock the bucketing
  discipline at CI time.
