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
| 20 | **`signup_rate_limited` → retryable:false + streaming `end.Retryable` override.** #548 left `signup_rate_limited` retryable:true (harmless — not hot-loopable, but inconsistent with the other abuse-limit codes now false); flip it. Separately, the coordinator streaming SSE terminal-error writer doesn't honor the `end.Retryable` override that the non-streaming path does (SPEC-019). Both carried from #548 closing audit. | D | S | #548 r4 audit |
| 21 | **Future-code completeness guard.** The retryable completeness tests guard only the current hand-curated inventory; a future emitted code omitted from both map and list still passes CI. A proper AST/registration-based guard would make the "fails CI" claim literally true. | D | M | #548 r4 audit |
| 22 | **Cross-spec 404/known-model reconciliation.** SPEC-010 R-3.3.4 now normatively `MUST` union declared `supported_models` into `seenModels` (implemented in #555), but SPEC-006 §17.2 defines 404 by "served or recently seen" without naming declarations, and SPEC-002 R-3.X.6 calls the union `MAY`. Add cross-references so the three agree (SPEC-010's MUST is authoritative). | D | S | #555 audit |
| 23 | **SPEC-020 tokenless-corner client-enforceability.** The coordinator marks a token-mint race-loser / issuer-less session `AuthBearerlessDuplicate` but doesn't propagate `auth_state`/`assigned_provider_token` to the client, so that corner's notify-only verdict isn't client-enforceable (prod `mac` unaffected — it holds a validated token). Add coordinator→client `auth_state` propagation. | S D | S | #558 audit |

---

## Decision gates (operator)

- **G1 (item 2, after ledger probe):** if honest long completions are being
  clamped → revert divisor to content-bytes `/4` (protect provider credit); else
  → bump SPEC-005 to document the `/16` observed-bytes clamp. **Default: measure,
  then protect provider credit.**
- **G2 (item 4): RESOLVED → (c) amend SPEC-020, do NOT flip the code default.**
  Runtime check (2026-07-11): the prod `mac` provider is `tier: provisional`
  (bearer-validated), with no `accept_provisional` opt-in — flipping the default
  to false would immediately break prod auto-update, and the whole fleet is
  provisional by design (`providers: []`), so "provisional→notify-only" defeats
  SPEC-020's purpose. Binary replacement is crypto-gated (ECDSA + host + self-test
  + drain + rollback); threat model T-3 accepts the residual. Fix = document
  bearer-validated-provisional as auto-update-eligible in the trust table.
- **G3 (item 5):** implement the `seenModels` union (503) vs strike R-3.3.4.
  **Default: implement** (the spec's one buyer-visible promise; aligns with the
  model-id incident fixes).

---

## Status log

| Date | Item | State |
|------|------|-------|
| 2026-07-10 | Runbook created; Wave A kicked off (1a+16, 2-probe, 3) | in progress |
| 2026-07-10 | Item 3 (SPEC-022 deadline, #546) — 3 codex rounds + attribution lane to 0 C/H/M; 2 pre-existing MEDIUMs carried as items 18/19 | MERGED (f7e1505) |
| 2026-07-11 | Item 2 (billing under-credit) — probe RAN on Pearl ledger (35d, 3428× 200s). Reality overturns the ~75% theory: clamp bound on only **4.66%** of honest reported rows, median loss **1 tok**, total under-credit **$0.0009** over 35 days. `pct_reported_present`=81.9%. Negligible $ impact; not an emergency. **G1 verdict: do NOT emergency-revert; reclassify to SPEC-005 conformance (fold into item 11 v0.6).** | resolved (reclassified P0→P3) |
| 2026-07-11 | Item 1a+16 (retryable + healthz, #548) — buyer `retryable` contract end-to-end (coordinator+gateway, all 64/93 codes classified + completeness tests) + healthz HEAD. **4 codex audit rounds** (mis-scoped as "small"; a shared-envelope field is a cross-boundary contract — see [[feedback-shared-contract-field-not-mechanical]]); closing audit 0 live-wrong HIGH | MERGED (13907c9) |
| 2026-07-11 | Item 4 (G2, #558) — RESOLVED via (c): amend SPEC-020 trust table (spec+comments only, no behavior change; prod keeps auto-updating). Runtime check proved prod `mac` is provisional → flip would've broken it. 3 codex rounds (spec-completeness) to 0 C/H/M. Carried item 23. | MERGED (77608d5) |
| 2026-07-11 | Item 5 (SPEC-010 R-3.3.4 404→503, #555) — `seenModels` unions declared `supported_models` + `ModelKnown` live-scan (cap-pressure-robust). 2 codex rounds to 0 C/H/M. Carried item 22. | MERGED (38393ec) |
| 2026-07-11 | **Wave C started.** Item 8 (SPEC-031 canary/degrade/sanctions, #564) — reconstructed normative baseline for the subsystem behind 3 incidents with zero spec. **9 codex three-lane rounds** to 0 C/H/M (code PASS R3, architect PASS R7, security PASS R9). CRITICAL reframing: nonce echo = liveness/instruction-following, NOT identity/anti-downgrade (deferred to SPEC-008 + item 9). Correlated-fault design walked quorum→known-good-control→fingerprint-suspend→**ephemeral-discard** (Sybil-safe fixed point; operator-only persistent containment). Honest §14 conformance table (Implemented/Partial/Gap) + §16 re-enable bar (FR-CAN22/23/15/18/14/26 + observe-until-CAN8). Docs-only + 2 comment-only `canary_probe.go` edits. | MERGED (c4a98ae) |
