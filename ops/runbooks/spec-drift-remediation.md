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
| 10 | Hardware-evidence verifier spec (`hardware-verifier.v2`; shipped constant is `hardware-verifier.v2:verified_trusted_hardware`, not v1) | S D | M | new spec | `internal/stats/hardwareverify/verify.go` |
| **P3 — spec-debt consolidation + rewrites** |
| 11 | SPEC-005 v0.6 money-path bump (houses #2 + 6 columns + clamps + 10M cap + model-key normalization + SPEC-024 fold-in) | M D | L | spec, money-path | `internal/billing/formula.go`, `store.go` |
| 12 | SPEC-001 v1.7 consolidation (spec v1.6 vs binary **1.8.31**; FR-11 semaphore, FR-16 idle-prewarm, mode-based handshake, 17-frame control socket, §6.15 additive wire) — **✅ MERGED (squash `7b642ce`, 2026-07-13); 10-round audit 0 C/H/M** | D | L | spec | `CoordinatorClient.swift` (1.8.31) |
| 13 | SPEC-014 v0.9 — GitHub-OAuth dual-mode drift reconciliation (verify-before-design corrected the one-liner: portal is config-gated dual-mode, GitHub-OAuth **shipped but prod-off + incompletely wired**; v0.9 documents it as owner-of-last-resort for the OAuth transport with carried security residuals) — **✅ MERGED (squash `5555383`, 2026-07-13); 8-round codex 3-lane audit 0 C/H/M** | D | M | spec | `frontdoor/provider-portal/index.html` |
| 14 | SPEC-025/026 CLI-wrapper rewrite (arch inverted by PR #418) — reconciled both specs to shipped monitor-only wrapper: three-credential auth model (bootstrap identity signs live `identity_signature` / rotatable receipt key / bearer), dormant App-`p_*` apparatus, money-path fail-closed (§4.1 proof, wallet-501, App Attest), three launchd registrations + watchdog no-op-restart, distribution/Sparkle/Keychain fidelity — **✅ MERGED (squash `2fa8657`, 2026-07-13); 10-round codex 3-lane audit 0 C/H/M** | D | L | spec rewrite | `phase3-binary/app/Sources/Malibu/` |
| **P4 — housekeeping** |
| 15 | SPEC-018 AC-45: `X-MacProvider-Streaming-Mode` stripped by gateway — verify-before-design found the coordinator already fully implements AC-45 (kill-switch + per-(buyer,provider) downgrade) and sets the header on streaming 200s; the gateway's blanket `X-MacProvider-*` strip removed it before buyers on `api.streamvc.live`. Fix (Option 1): allowlist the header at the gateway with byte-exact enum validation (drop non-canonical), SPEC-006 → v0.9.9 §5.4 (both allowlist occurrences), SPEC-018 gap-note reconciled (doc-only, LOCKED spec untouched) — **✅ MERGED (squash `de06034` PR #588, 2026-07-14, admin-bypassed pre-existing `AgeThresholdRekey` date-flake); codex 3-lane audit 0 C/H/M (code R2 / security / architect)** | D | S | spec + tiny code | `phase5-gateway/internal/router/server.go` (`copyCleanHeadersWithReceipt`) |
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
| 18 | **Gateway charges buyer on pre-dispatch `route_snapshot_failed`.** When the coordinator returns 500 `route_snapshot_failed` before provider dispatch, the gateway reads absent finality headers as `Legacy` and settles the reservation on the prompt estimate — the buyer is debited for a request with no provider invocation. Should be a pre-dispatch no-charge refund (both streaming modes). — **✅ MERGED (squash `5467bef` PR #590, 2026-07-14); 6-round codex 3-lane → 0 C/H/M (R5 HIGH: attemptN write-before-bill undercharge; R6 ledger-exact redesign). Carried MEDIUM documented (wire-status vs ledger-status on write-before-bill paths, pre-existing/not-worsened).** | **M** B | S–M | #546 round-2 audit |
| 19 | **`route_snapshot_policy_version` derivation.** It is a static literal marking default cutovers (v0=30s, v1=300s) but does not uniquely encode a runtime-reconfigured `pending_deadline_seconds`; report-by-policy-version aggregation merges different effective deadlines. Full derivation belongs to the unimplemented SPEC-022 R-1.1 policy object. — **✅ MERGED (squash `d3ee07e` PR #592, 2026-07-14); codex 3-lane R1 0 C/H/M. verify-before-design: the effective deadline is already persisted per-row (`settlement_route_snapshots.pending_deadline_seconds`), so the `settlement_verdict_counters` diagnostics now disaggregate by it (LEFT JOIN on digest) — no migration, no settlement-correctness change. R-1.1 policy object stays the deferred follow-up.** | D | M | #546 round-2 audit |
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
| 2026-07-11 | Item 9 (SPEC-032 proof-of-weights/OPoI + autotune hello-gate, #566) — **verify-before-design read-only Pearl check reshaped the spec**: the hello-gate is LIVE in prod (`require_autotune_hello_gate:true`, `pool_size:1`) while OPoI/canary are disabled, so the live hello-gate admission policy is the substantive core and OPoI gets honest non-binding labeling. **8 codex three-lane rounds** to 0 C/H/M. Two CRITICALs collapsed by scope calls: (a) the draft's redundancy exemption would have routed buyers to providers whose evidence *proves* they can't serve the tier → v0.1 ships **no auto-probation** (redundancy = below-two operator alert + hot-reloadable gate); (b) the shipped gate doesn't enforce its capacity ceiling after hello → captured as **FR-HG7** (live prod bypass, priority Gap). OPoI/drift labeled observability-only (never gate routing/tiering/sanctions/**payout** — a stale runbook's OPoI payout-multiplier was an FR-PW2 money-path violation, marked superseded). Honest §14 table + FR-PW3 forward weight-binding bar. Docs-only + 1 comment-only `internal/ws/server.go` edit. | MERGED (c1909cb) |
| 2026-07-12 | Item 7 (SPEC-008 v0.4 attestation reconciliation, #567) — reconciled the shipped **self-signed Secure-Enclave** attestation (`macprovider-se-p256-v1`, default-enabled) that v0.3 entirely omitted. **14 codex three-lane rounds** to 0 C/H/M on the attestation scope (security + architect PASS 'complete'; code-fidelity byte-faithful). Design-discovery findings: the buyer-visible **`hardware_attestation`** field is derived tier-blind so an all-`self_signed` software-key pool discloses `hardware_attestation:"all"` (documented as a known overstatement; recommended forward coordinator+gateway code fix); the session-binding signature is required for **both** formats; the effective token cap is **1024 bytes** at the WS layer (invalid_auth_request/4001), making the documented 16/20-KiB Pillar-C caps unreachable. Bundled the SPEC-031 FR-CAN23 device-identity cross-spec correction. Carried pre-existing Pillar-B/D drifts as documented residuals (a separate reconciliation). Docs-only. | MERGED (db6289e) |
| 2026-07-12 | Item 6 (SPEC-024 v0.2 provider-local cache isolation + option-(a), #568) — new §11–§16 isolation baseline reconciled to shipped code, **bundling coordinated amendments** SPEC-004 v0.3.2 / SPEC-006 v0.9.8 / SPEC-008 v0.4.1. H1 (the shipped cache sends the derived `conv:` key to the provider, contradicting the prior provider-nonvisibility invariant) **RESOLVED via operator decision option (a): ratify the shipped design** — provider learns a stable opaque per-conversation identifier, never the raw tag/`account_id` (one-way HMAC), captured frames carry no raw values. **7 codex three-lane rounds** to 0 C/H/M all lanes (code PASS R3). Design-discovery: the shared-HIGH encrypted-envelope byte contract (§6.6/§10.6 said ciphertext = bare `body`; shipped = `inference_request_plaintext` JSON envelope with `conversation_key`), and an overstated buyer-deletion control corrected to the honest residual (provider-KV not buyer-purgeable; deterministic key + normal-routing re-population escape). Carried MUST-close residuals: provider-cache disclosure completeness (FR-CI10a), queued-routing `sticky_result` provenance (FR-CI11a), sticky read-path account compare (FR-CI13) — billing-attribution/disclosure items, not isolation breaches. Docs-only. | MERGED (e990f00) |
| 2026-07-12 | Item 10 (SPEC-033 hardware-evidence verifier `hardware-verifier.v2`, #569) — reconstructed baseline for the shipped, production-live coordinator verifier that promotes autotune hardware evidence to a `verified` profile (consumed by SPEC-032 admission). **6 codex three-lane rounds** to 0 C/H/M all lanes. Byte-matches `verify.go` + migrations 007/008/013/015/016/017 + the authenticated `POST /v1/providers/hardware-evidence` enqueue/replay path + both DB guard triggers (incl. the migration-016 **in-DB trust re-verification** on every promotion) + the operator inventory writer/demotion. Design-discovery: the ordered gate pipeline + `waiting_trust` non-terminal re-eval; the **exact-v2 vs verified-bit** two-consumer-class split; and the **security calibration** — a provider cannot self-certify (holds even under onboarding-role compromise), but `verified` is string-consistency + operator trust anchor (NOT proof-of-execution), is (chip,memory)-anchored not identity-anchored, and revocation is best-effort with one genuine **escape R1** (`app_register` source-flip dodges the `cli_hello`-scoped demotion; a compromised onboarding role can do it at scale) + one R2 ergonomics gap. Closed the naming drift (live constant is `v2:verified_trusted_hardware`, not v1). Docs-only. | MERGED (a7225c9) |
| 2026-07-12 | Item 2 (G1) — **probe RE-RUN** on a fresh Pearl ledger snapshot (35d ending 2026-07-12, 3787 byte-estimated 200s). Confirms the 2026-07-11 verdict and is marginally cleaner: `pct_bound_of_reported` **3.25%** (was 4.66%), median under-credit **1 tok**, total **1778 tok = $0.0009 provider / 35d** (~$0.01/yr), `pct_reported_present` 86.1%. No G1 revert trigger met (all under threshold). **Verdict unchanged: do NOT revert the `/16` divisor; fold the `/16`-clamp documentation into item 11 (SPEC-005 v0.6).** | confirmed (still P3) |
| 2026-07-13 | **Wave D started.** Item 12 (SPEC-001 v1.7, spec v1.6 → shipped binary **1.8.31**) — authored + **10-round codex 3-lane audit converged 0 C/H/M** (code PASS R5 w/ reviewer APPROVE + 154 Swift/4 Go tests; security PASS R7 0/0/0/0; architect PASS R10 0/0/0/0). Reconciled: FR-11 (blocking `AsyncSemaphore` + unbounded FIFO waiters + WS capacity-1 `error_queue_full`, retired the never-shipped 429/queue), FR-10 (disconnect-cancel marked aspirational/not-shipped), FR-16 (no-op `warm_up` + idle `IdlePrewarmer`, raw event strings), FR-25 (fixed WS capacity 1). **Long-tail thread R6–R10 = "handshake selection is transport-mode-based"** (WS-tunneled/credential-bootstrap → v2 `auth_request` on connect+reconnect; HTTP-forwarding → legacy `hello`; opt-ins vary only frame content) swept one site/round across FRs/§6.7/R-6.x/AC-5/AC-16/AC-18.x/matrix/scope/§7/handoff. Tier-2 reconciled (middleware-hook design never shipped; SPEC-008 wire pipeline live; dropped unsafe "hardware attestation proof"). Owner-of-last-resort schemas carried inline (§6.15 additive wire, §6.7.1.5 coordinator-sent frames incl. `catalog_compatible`/`bootstrap_identity_public_key`, 17-frame control socket, App-track/receipt-rotation/plaintext-envelope schemas). **PR [#572](https://github.com/Augustas11/macprovider/pull/572) MERGED (squash `7b642ce`, 2026-07-13) — antfleet-ops approved, Augustas11 squash-merged.** Docs-only. | ✅ MERGED |
| 2026-07-12 | Item 11 (SPEC-005 v0.6 + SPEC-024 v0.2.1 money-path reconciliation) — authored + **12-round codex 3-lane audit loop converged to 0 C/H/M** (code/security/architect all pass at R12). Houses item 2's `/16` documentation. Material findings surfaced + reconciled to shipped code: prompt-token provenance/bound (§5.3.2), cache under-reporting disclosure (§5.3.1), verified-receipt re-price (§7.5b), path-dependent cache-quarantine credit (four write shapes, §2.7), identity-first recovery snapshot precedence (§4.7/§10.2/§10.4), SPEC-024 §4–§6-only handoff. Carried code follow-ups documented in PR body (recovery flag-only credit retention, fallback quarantine-erasure, force-credit not reason-gated, SPEC-006 §17.7 `/4` drift, test-hardening). **PR [#571](https://github.com/Augustas11/macprovider/pull/571) MERGED (squash `8428a7c`, 2026-07-12) — antfleet-ops approved, Augustas11 squash-merged.** | ✅ MERGED |
| 2026-07-13 | Item 13 (SPEC-014 v0.9 GitHub-OAuth dual-mode drift reconciliation) — verify-before-design corrected the one-liner: portal is config-gated dual-mode, GitHub-OAuth shipped but prod-off + incompletely wired; v0.9 documents it as owner-of-last-resort for the OAuth transport with carried security residuals. **8-round codex 3-lane audit 0 C/H/M.** PR MERGED (squash `5555383`). Docs-only. | ✅ MERGED |
| 2026-07-13 | Item 14 (SPEC-025/026 CLI-wrapper rewrite, arch inverted by PR #418) — reconciled both specs to the shipped monitor-only wrapper: three-credential auth model, dormant App-`p_*` apparatus, money-path fail-closed (§4.1 proof / wallet-501 / App Attest), three launchd registrations + watchdog no-op-restart, distribution/Sparkle/Keychain fidelity. **10-round codex 3-lane audit 0 C/H/M.** PR [#583](https://github.com/Augustas11/macprovider/pull/583) MERGED (squash `2fa8657`). Spec rewrite, docs-only. | ✅ MERGED |
| 2026-07-14 | **Items 1(b)/1(c)** (canary last-provider floor + pool-redundancy telemetry) — the code SPEC-031 (#564) authorized. FR-CAN22 floor spares the sole **buyer-serving** provider from a canary-only sanction (`CanaryTripFloorHeld`), predicate = the coordinator's request-independent routability gates, under a proven non-regression guarantee; 1(c) surfaces `buyer_serving_for_model`/`pool_redundancy_low` without weakening the gate. FR-CAN3 runtime truncation-attribution dropped (provider-forgeable + moot). **9-round codex 3-lane audit 0 C/H/M.** SPEC-031 → v0.2, DECISION Entry 139. **PR [#587](https://github.com/Augustas11/macprovider/pull/587) — OPEN, intentionally un-merged (operator holding).** | ⏸ OPEN |
| 2026-07-14 | Item 15 (SPEC-018 AC-45 streaming-mode gateway passthrough) — verify-before-design: the coordinator already fully implements AC-45 (kill-switch + per-(buyer,provider) downgrade) and sets the header on streaming 200s; the gateway's blanket `X-MacProvider-*` strip removed it before buyers on `api.streamvc.live`. Fix (Option 1): allowlist at the gateway with byte-exact enum validation, SPEC-006 → v0.9.9 §5.4 (both allowlist occurrences), SPEC-018 gap-note reconciled (doc-only, LOCKED spec untouched). **codex 3-lane audit 0 C/H/M (code R2 / security / architect).** **PR [#588](https://github.com/Augustas11/macprovider/pull/588) MERGED (squash `de06034`)** — admin-bypassed the pre-existing `AgeThresholdRekey` date-deterministic phase4 CI red (fails on `main` itself; not this PR's — empty coordinator diff). | ✅ MERGED |
| 2026-07-14 | Item 18 (gateway charges buyer on pre-dispatch `route_snapshot_failed`, #590) — no-charge refund + verbatim passthrough gated on the coordinator's positive `X-MacProvider-Settlement-No-Prior-Dispatch` marker. **6-round codex 3-lane loop**: the marker signal for "was a provider billably credited" is request-wide and each approximation leaked (R1 retried-502 → R2/R3 coordinator-internal failover → R4 attemptN positive-marker → **R5 HIGH**: attemptN increments *after* the terminal WS write, undercharge, + over-counts non-billed 503 rows, overcharge). **R6 ledger-exact redesign** — `providerCredited` set inside `recordRow` at the billing-commit point + per-attempt `dispatchedThisAttempt`; all three lanes 0 C/H/M on CRITICAL/HIGH. **Carried MEDIUM (operator-decided ship):** on write-before-bill streaming/WS terminal paths the marker keys on the outward wire status, so a non-billable 503 rendered as 502 can be left unmarked → a later `route_snapshot_failed` settles instead of refunds — the SAME outcome as pre-item-18 (route_snapshot_failed was always settled), i.e. pre-existing/not-worsened; documented in SPEC-006 §17.7 / SPEC-022 (A) / DECISION Entry 140 with a tracked follow-up. **PR [#590](https://github.com/Augustas11/macprovider/pull/590) MERGED (squash `5467bef`)** — antfleet-ops approved, Augustas11 squash-merged, CI fully green (see next row). | ✅ MERGED |
| 2026-07-14 | **CI-health fix (not a drift item), #591** — root-caused the date-deterministic `AgeThresholdRekey` phase4 red that reded every PR (and forced item 15's admin-bypass): `setReadDeadline`/`setWriteDeadline` fed the server's injectable *logical* clock (`s.now()`) to the OS socket deadline, which the poller compares against the real wall clock. In prod `s.now()==time.Now().UTC()` so it was behavior-identical, but a test's frozen 2026-07-13 clock made the deadline already-expired once real time passed it → `read auth_challenge: EOF`. Fix: physical I/O deadlines use `time.Now()`; `s.now()` stays logical-time only. **Zero production change; full coordinator module green.** **PR [#591](https://github.com/Augustas11/macprovider/pull/591) MERGED (squash `0c5961b`)** — no more admin-bypass needed for phase4 CI. | ✅ MERGED |
| 2026-07-14 | Item 19 (`route_snapshot_policy_version` can't encode a runtime-reconfigured `pending_deadline_seconds`, #592) — **verify-before-design**: the effective deadline is already captured authoritatively per-row on `settlement_route_snapshots.pending_deadline_seconds` (set from runtime config at dispatch, hashed into the route-snapshot digest), so no schema migration was needed. The `settlement_verdict_counters` diagnostics (`/admin/ledger/summary`) grouped only by the coarse `route_snapshot_policy_version`, merging outcomes across deadline regimes; now they LEFT JOIN the route snapshot by `route_snapshot_digest` (dedup subquery → no count fan-out) and disaggregate by the effective `pending_deadline_seconds` (deadline `0` = unknown/absent snapshot). Read-only diagnostics + docs; no settlement-correctness change. Regression test proves two verdicts sharing policy/model/entrypoint/reason but different deadlines split into two rows. **Codex 3-lane R1 converged 0 C/H/M** (code 0/0/0/0, security 0/0/0/0, architect 0/0/0/3L — 3 doc-accuracy LOWs folded). SPEC-022 → v0.1.5 amends (B); R-1.1 authoritative policy object deferred. **PR [#592](https://github.com/Augustas11/macprovider/pull/592) MERGED (squash `d3ee07e`)** — antfleet-ops approved, Augustas11 squash-merged, CI fully green (14/14 — first PR since the #591 flake fix with no phase4 red). | ✅ MERGED |
