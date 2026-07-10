# Runbook: SPEC-vs-code drift remediation

**Version:** 1.0
**Date:** 2026-07-10
**Owner:** operator
**Source:** the 2026-07-10 7-lane SPEC-vs-code drift audit + reverse sweep.
**Prereq context:** the tranche 3+4 corpus-hygiene pass shipped in PR #543
(status-header honesty + canonical numbers SPEC-021/030 + SPEC-007 restore).
This runbook tracks everything the audit surfaced that PR #543 did **not** fix.

---

## Governing discipline (applies to every item below)

- **Worktree isolation.** Every code/spec task starts from a fresh sibling
  worktree off `origin/main`. Never edit the canonical checkout.
- **Codex 3-lane audit loop.** SPEC and IMPL changes loop three independent
  codex lanes (code / security / architect) → fix → re-audit until **0 CRITICAL,
  0 HIGH, 0 MEDIUM**. LOW/INFO may ship documented. Audits are codex, not Claude.
- **Money-path via PR.** Billing, settlement, payout, gateway-auth changes go
  through PRs (never direct push), authored as Augustas11 so antfleet-ops can
  review; antfleet-ops approves → Augustas11 squash-merges.
- **Verify before claiming.** Money-path fixes verify against production ledger
  / live endpoints before the fix is called done.
- **Decision-log.** Append a `beta/DECISION_CRITERIA.md` entry when a number,
  gate, or money-path behavior changes.

---

## Priority ranking

Scored on five impact axes — **M**oney, **B**uyer-visible/availability,
**S**ecurity boundary, **I**ncident-recurrence, **D**rift-risk — plus effort
and whether it needs production verification before code is touched.

| # | Item | Axes | Effort | Type | Anchor |
|---|------|------|--------|------|--------|
| **P0 — prod-active** |
| 1 | Buyer-503 remediation: (a) `retryable:false` on transient `no_provider_available`/`provider_timeout`; (b) degrade-window semantics; (c) second-provider gating | B I M | S–M | code, money-path PR | `phase4-coordinator/internal/buyer/server.go:7220`,`:60` |
| 2 | Billing under-credit investigation → fix: `ceil(wire_bytes/16)` + `min(reported, byte_estimate)` clamp vs SPEC-005 `ceil(bytes/4)` | M | S probe, then M | prod query FIRST | `internal/billing/formula.go:262`, `internal/buyer/server.go:6333` |
| 3 | SPEC-022 pending-deadline 30s→300s | M S | S | code + spec | `internal/buyer/route_snapshot.go:62` |
| **P1 — security boundaries + buyer correctness** |
| 4 | SPEC-020 `accept_provisional` default vs notify-only trust table | S D | S | decision + code/spec | `AutoUpdateTrustState.swift:62` |
| 5 | SPEC-010 R-3.3.4 404→503 (`seenModels` union) | B D | M | code or spec-strike | `internal/pool/provider.go:721` |
| 6 | Provider-local cache isolation spec → SPEC-024 v0.2 | S D | M | new spec | `ConversationCache.swift`, `KVCacheTelemetry.swift` |
| 7 | SPEC-008 attestation reconciliation (SE-P256 format, `/v1/models` per-model fields, transcript + canonical-JSON encoding) | S D | M | spec v0.4 + code | `internal/tier2/pillar_c_se.go`, `pillar_b.go:105`, `catalog.go:32` |
| **P2 — write the missing normative baseline** |
| 8 | Canary/degrade/sanctions spec (3 incidents/week, zero spec) | I B D | L | new spec | `internal/ws/canary_probe.go`, `canary_store.go` |
| 9 | Proof-of-weights / OPoI + autotune hello-gate spec | S D | L | new spec | `internal/pow/drift.go`, `internal/autotune/gate.go` |
| 10 | Hardware-evidence verifier spec (`hardware-verifier.v1`) | S D | M | new spec | `internal/stats/hardwareverify/verify.go` |
| **P3 — spec-debt consolidation + rewrites** |
| 11 | SPEC-005 v0.6 money-path bump (houses #2 + 6 columns + clamps + 10M cap + model-key normalization + SPEC-024 fold-in) | M D | L | spec, money-path | `internal/billing/formula.go`, `store.go` |
| 12 | SPEC-001 v1.7 consolidation (spec v1.6 vs binary 1.8.26; FR-16, FR-11, control-socket frames) | D | L | spec | `CoordinatorClient.swift:1182` |
| 13 | SPEC-014 v0.9 (canonical spec forbids the live GitHub-auth portal) | D | M | spec rewrite | `frontdoor/provider-portal/index.html` |
| 14 | SPEC-025/026 CLI-wrapper rewrite (arch inverted by PR #418) | D | L | spec rewrite | `phase3-binary/app/Sources/Malibu/` |
| **P4 — housekeeping** |
| 15 | SPEC-018 AC-45: `X-MacProvider-Streaming-Mode` stripped by gateway | D | S | spec + tiny code | `phase5-gateway/internal/router/server.go:889` |
| 16 | healthz HEAD→405 on coordinator provider-port + gateway | B | S | code | `internal/ws/server.go`, gateway `server.go:317` |
| 17 | SPEC-016 v0.1.20↔v0.1.22 fork (when PR #164 lands) | D | S | spec | deferred |

---

## Implementation plan (waves)

**Wave A — stop the bleeding (in progress).** Items 1(a), 2-probe, 3, 16.
- 2-probe is a read-only production ledger query — run it FIRST; it sizes the
  only money-correctness risk and gates decision gate G1.
- 1(a) retryable-table fix (bundled with 16 healthz-HEAD) as one buyer-path PR.
- 3 SPEC-022 deadline as its own money-path PR (hard gate before any enforce flip).
- Items 1(b)/1(c) fold into the canary spec (Wave C).

**Wave B — decisions + close buyer-visible gaps.** Items 2-fix (bundled with 11),
4, 5. Resolve the decision gate, then implement.

**Wave C — write the missing baselines.** Items 8 (first; formalizes 1(b)), 9, 7,
6, 10. Each runs the SPEC audit loop before PR; probe live behavior before design.

**Wave D — consolidation & rewrites.** Items 12, 13, 14, 15. Driven by forcing
functions (e.g. 14 at the next Malibu release).

**Wave E — deferred.** Item 17 when PR #164 merges.

---

## Carried follow-ups (surfaced by Wave A codex audits)

New items the audit loop surfaced as **pre-existing** (attribution-confirmed) and
carried documented rather than blocking the PR that found them:

| # | Item | Axes | Effort | Source |
|---|------|------|--------|--------|
| 18 | **Gateway charges buyer on pre-dispatch `route_snapshot_failed`.** When the coordinator returns 500 `route_snapshot_failed` before provider dispatch, the gateway reads absent finality headers as `Legacy` and settles the reservation on the prompt estimate — the buyer is debited for a request with no provider invocation. Should be a pre-dispatch no-charge refund (both streaming modes). | **M** B | S–M | #546 round-2 audit |
| 19 | **`route_snapshot_policy_version` derivation.** It is a static literal marking default cutovers (v0=30s, v1=300s) but does not uniquely encode a runtime-reconfigured `pending_deadline_seconds`; report-by-policy-version aggregation merges different effective deadlines. Full derivation belongs to the unimplemented SPEC-022 R-1.1 policy object. | D | M | #546 round-2 audit |

---

## Decision gates (operator)

- **G1 (item 2, after ledger probe):** if honest long completions are being
  clamped → revert divisor to content-bytes `/4` (protect provider credit); else
  → bump SPEC-005 to document the `/16` observed-bytes clamp. **Default: measure,
  then protect provider credit.**
- **G2 (item 4):** flip `accept_provisional` default to `false` (+ opt-in) vs
  amend the SPEC-020 trust table. **Default: flip to false** (trust boundary; beta
  pool is small).
- **G3 (item 5):** implement the `seenModels` union (503) vs strike R-3.3.4.
  **Default: implement** (the spec's one buyer-visible promise; aligns with the
  model-id incident fixes).

---

## Status log

| Date | Item | State |
|------|------|-------|
| 2026-07-10 | Runbook created; Wave A kicked off (1a+16, 2-probe, 3) | in progress |
| 2026-07-10 | Item 3 (SPEC-022 deadline, #546) — 3 codex rounds + attribution lane to 0 C/H/M; 2 pre-existing MEDIUMs carried as items 18/19 | approved, merging |
