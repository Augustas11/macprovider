# deepsec pilot — phase4-coordinator/internal/billing

**Pilot scope:** `phase4-coordinator/internal/billing/**` (12 Go files,
~3.4k LoC).
**Harness:** `vercel-labs/deepsec` v2.1.2 (npm).
**Agent:** `codex` (gpt-5.5, effort=xhigh), via the codex CLI's logged-in
ChatGPT Plus subscription — no API keys, no AI_GATEWAY_API_KEY.
**Working dir:** `/tmp/deepsec-pilot/.deepsec/` (zero footprint in
the macprovider repo — repo accessed via symlink, no git changes, no
PR, no branch).
**Concurrency / batch:** `--concurrency 2 --batch-size 3` (per brief).

## Run summary

| Phase | Wall time | Subscription burn (gateway-equivalent $) | Tokens |
|---|---|---|---|
| `scan` (regex matchers) | <1s | – | – |
| `process` (12 files, 4 batches) | 690s (~11.5 min) | $6.25 | 558,722 |
| `revalidate` (10 findings, 2 batches) | 329s (~5.5 min) | $3.05 | ~400k est. |
| `export` (md-dir) | <1s | – | – |
| **Total** | **~17 min wall-clock** | **~$9.30 equivalent** | **~960k** |

**Zero 429s, zero retries, zero timeouts.** Codex subscription quota
held cleanly for the full run; nowhere near the 5-hour Plus window.

## Critical first-run signal — matcher recall on Go

deepsec's built-in regex matcher set is heavily web-framework oriented:
74 of 198 matchers fired (the others gated themselves off — no React,
Express, Next, Django, FastAPI, etc.), and the 74 that ran produced
**1 candidate site inside billing**: `snapshot.go` flagged by
`crypto-usage` (the `crypto/sha256` import — informational, not a
vuln claim). That's 1 candidate across 12 Go files = **~8% recall** on
money-path Go code, vs. the `data/macprovider/files/*.json` mirror that
shows 0 candidates would have been investigated by default.

A naive `pnpm deepsec scan && pnpm deepsec process --project-id macprovider`
would have produced **0 useful billing findings**. To get the 10
findings below I bypassed the matcher gate with
`pnpm deepsec process --files-from <12-file manifest>` (`--files-from`
is direct mode and runs the AI on every listed file regardless of
matcher hits). This is documented behavior, not a workaround, but it
means **default `scan → process` on Go money-path code is effectively
inert**. Two follow-ups are available in the harness:

1. Write Go-specific matchers via the `writing-matchers.md` workflow
   (grow from a confirmed TP — we now have 10 to seed from).
2. Always operate in direct mode with a curated `--files-from` manifest
   per money-path package.

## Findings (severity distribution)

| CRITICAL | HIGH | MEDIUM | HIGH_BUG | BUG | LOW |
|---|---|---|---|---|---|
| 0 | 1 | 0 | 6 | 3 | 0 |

**Revalidation verdict: 10 TP, 0 FP, 0 fixed, 0 uncertain.** Codex
re-checked each finding against the actual code in a second pass and
confirmed all 10 as true-positive. *Caveat: same-model revalidation
will rubber-stamp same-model errors; treat the TP labels as
"codex-self-confirmed" rather than independently verified.*

deepsec severity legend (per docs):
- `HIGH`/`MEDIUM` — security severity (auth, payment integrity, etc.)
- `HIGH_BUG`/`BUG` — correctness / reliability bugs in security-adjacent code

## Per-finding one-liners

| # | File:lines | Sev | Slug | Claim | Snap judgement |
|---|---|---|---|---|---|
| 1 | `endpoints.go:303,343,353,357` | HIGH_BUG | other-billing-integrity | `buyerEquivalentCredits` reconcile fallback re-runs `ComputeCredits` without `estimated_completion_tokens`, so the completion-clamp from 9bd77f4 is bypassed on the reconcile code path. | **Looks real.** Extension of 9bd77f4 — same bug class, second code path. |
| 2 | `endpoints.go:250,253,353,355` | HIGH_BUG | other-reconciliation-integrity | Reconcile silently `continue`s on `snapshotAt` errors (incl. `ErrNoSnapshot`, decode error, DB error, ctx cancel) then writes `status='complete'`. Unreconciled rows are invisible. | **Looks real.** Specific failure mode is clear; check whether `ErrNoSnapshot` is expected-and-recoverable in steady state. |
| 3 | `endpoints.go:101,109,427,…` | BUG | other-error-suppression | `h.sum` returns `0` on any DB error, so `/admin/ledger/summary` can 200 with zeroed totals during a DB outage; per-provider earnings can 404 instead of 5xx. | **Looks real.** Modest impact (observability), correct claim. |
| 4 | `formula.go:119,136,141` | HIGH | other-payment-integrity | **Provider-reported `prompt_tokens` is NOT clamped against any coordinator estimate** — only the completion side got the `billableCompletion` clamp in 9bd77f4. A malicious provider can over-report prompt tokens to 10M and inflate prompt-side credits. | **Looks real and high-value.** This is the *symmetric complement* of the 9bd77f4 fix — same threat model, prompt side. Almost certainly a real gap. |
| 5 | `payout.go:28,30,36,37` | HIGH_BUG | other-payout-state-corruption | `ClaimPayoutReady` doesn't reject empty `payoutExternalID` / `payoutCurrency`; `nullString("")` writes NULL; terminal-state trigger then prevents repair. | **Looks real.** Direct read of payout.go confirms no non-empty check. |
| 6 | `recovery.go:117,159,213,446` | HIGH_BUG | other-settled-ledger-corruption | `quarantineExistingLedgerForRequestAttemptTx` lacks a `settled = 0 AND settlement_id IS NULL` predicate, so several recovery branches (invalid_usage_tokens, missing_config_snapshot, ambiguous_attempt_n) can retroactively quarantine an already-settled / paid-out row. | **Plausible but needs trace.** Confidence "medium" — confirm whether other guards earlier in the call chain already prevent reaching this for settled rows. |
| 7 | `recovery.go:112,114,157,251` | BUG | other-nondeterministic-recovery | When `ts_utc` fails to parse, recovery substitutes `time.Now().UTC()` — making rate-card snapshot selection nondeterministic for malformed rows. | **Looks real.** Modest impact (malformed rows are rare). |
| 8 | `settlement.go:23,37,61,120` | HIGH_BUG | other-settlement-window-skew | `RunSettlement` compares `ts_utc TEXT` lexicographically against an `RFC3339Nano` cutoff. RFC3339Nano is **variable-width** — `2026-06-08T00:00:00.500Z` sorts BEFORE `2026-06-08T00:00:00Z` because `'.' < 'Z'`. Rows in the first fractional second after the boundary can spill into the wrong payout window. | **Looks real and clever.** This is the kind of subtle textual-time bug audits usually miss. Worth verifying with a regression test. |
| 9 | `settlement.go:152` | BUG | other-silent-settlement-failure | `StartWeeklySettlement` discards `RunSettlement` errors; weekly payout job can fail silently with no audit row or operator-visible signal. | **Looks real.** Observability gap. |
| 10 | `store.go:73` | HIGH_BUG | other-idempotency-invariant | `ledger_request_credits` UNIQUE is `(request_id, attempt_n, provider_id)` — schema permits multiple non-quarantined rows for the same `(request_id, attempt_n)` across different `provider_id`s. The hot-path / recovery code tries to enforce the SPEC-005 invariant, but the storage boundary doesn't. | **Looks real if the SPEC invariant is "one provider per attempt"** (which the INFO.md asserts). Recommend partial unique index `WHERE quarantined = 0`. |

Detailed per-finding markdown lives at:
- `/tmp/deepsec-pilot-billing/HIGH/` — 1 finding
- `/tmp/deepsec-pilot-billing/HIGH_BUG/` — 6 findings
- `/tmp/deepsec-pilot-billing/BUG/` — 3 findings

## Known-fixed mapping (vs `9bd77f4 Close audited billing and idempotency gaps`)

The ground-truth fix in 9bd77f4 was: add `billableCompletion()` in
`formula.go` to clamp provider-reported `completion_tokens` against
coordinator-observed `estimated_completion_tokens`, and thread the
estimate through `recovery.go` (HotPathInput.EstimatedCompTokens,
`invalidRecoveryEstimate` / `invalidRecoveryCompletion`).

### Confirms (deepsec re-found the bug *concept* on a *different code path*)

- **Finding #1** (endpoints.go `buyerEquivalentCredits`) — same
  completion-clamp omission as 9bd77f4 fixed in the main path, but on
  the **reconcile fallback path**. 9bd77f4's diff did NOT touch
  endpoints.go's reconcile fallback. **High recall signal** — deepsec
  generalized the threat model and found a missed instance.

### Novel — clean miss by 9bd77f4

- **Finding #4** (formula.go, prompt_tokens) — the **symmetric
  complement** of 9bd77f4. The original fix bounded completion against
  the coordinator's byte estimate; prompt tokens have no equivalent
  clamp and the buyer-side server *does* know the prompt content
  (so the coordinator could compute its own prompt-token count). If
  real, this is arguably the single highest-impact finding in the run.

### Novel — outside 9bd77f4 scope entirely

- Findings **#2, #3, #5, #6, #7, #8, #9, #10** — none of these touch
  the billable-completion clamp. They span: error swallowing
  (#3, #9), reconciliation-completeness invariants (#2), payout-state
  hygiene (#5), recovery vs settled-row safety (#6, #7), time-handling
  correctness (#8), and a schema-level invariant gap (#10). Of those,
  #4, #5, #8, #10 are the ones I'd hand-prioritize for genuine fix
  work first.

### Regressions of audited-and-closed bugs

- **None observed.** Findings do not duplicate items from
  `audits/2026-06-03/` or any locked SPEC-005 audit round.

## Pilot decision input

**Signal — strong on the high-context, code-reading side.** The 10
findings are substantive: every one is a specific, line-anchored
claim with a clear failure mode, and revalidation found 0 FP at
codex self-check. The agent burned ~$9 of gateway-equivalent on
~960k tokens to investigate 12 files end-to-end and read SPEC-005
+ cross-package context (buyer/server.go, requestlog/store.go,
ws/relay.go) to validate claims. That's competitive with a careful
codex audit lane, with the added structure of per-file JSON +
markdown export.

**Signal — weak on the matcher pre-filter for Go money-path.**
Default `scan → process` pipeline would have produced ~1 finding
total. The harness is built around a regex pre-filter that doesn't
cover Go billing-style code well. Operationally usable only via
`--files-from` direct mode or a custom matcher set.

**Caveats before adopting:**
- All 10 findings are codex-self-confirmed, not independently
  verified. A cross-model revalidation pass (`--agent claude`) would
  raise confidence further.
- 9bd77f4 ground-truth coverage: deepsec found 1 confirmed
  *generalization* of the original bug class (Finding #1) and 1 clean
  *symmetric miss* (Finding #4). Good recall, no false claims of
  pre-existing fixes being broken.
- This run cost ~17 wall-clock minutes on one package; scaling to the
  full `phase4-coordinator/` would be ~10× — order $90 gateway-
  equivalent for one full coordinator pass, well within one Plus
  window if metering stays linear.

**Recommendation:** worth a second pilot with cross-model revalidation
(claude pass over the same 10 findings) before committing to ongoing
use. The findings themselves are a useful work item regardless of the
adoption decision.
