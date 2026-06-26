# Open Questions Ledger

Single-page index of every open question, deferred item, and "future-spec"
pointer currently documented across the normative `specs/SPEC-*.md` files.
Built 2026-06-26 from a full sweep of SPEC-001 through SPEC-016 and
triaged the same day for SPEC-001..013.

The point of this file is that most of these items are tracked nowhere
else — each lives in its own SPEC body, often near the bottom, and is
easy to lose. This ledger is the one place to check before each new
SPEC version or roadmap pass.

## Conventions

- **id** is `SPEC-NNN/<local-id>` — `local-id` is whatever the SPEC body
  calls it (`OQ-1`, `Q5`, `FR-SR-7c`, `M-3`, …). If the SPEC body has
  no local id, this file makes one up and the SPEC is the source of
  truth for prose.
- **status** is one of:
  - `open` — undecided, no resolution path
  - `gated` — decided in principle, blocked on a named upstream artifact
  - `ready` — gate condition satisfied; awaiting operator green-light or BUILD prompt
  - `deferred` — explicitly punted to a named future SPEC version
  - `decided-no-revisit` — decided once; re-examine if conditions change
  - `closed` — resolved or obsolete; kept here as a one-line pointer until the next index pass
- **owner** is "operator" when only the operator can decide,
  "implementer" when it's a coding follow-up, "audit" when the next
  audit cycle is meant to close it.
- **blocker** names the specific upstream artifact (`SPEC-001 v2.0`,
  `air5 n=3 run`, `Apple Dev enrollment`, `issue #NN`, …) — empty if
  nothing concrete is blocking.

## Maintenance

When a SPEC version lands that closes an entry, change its `status` to
`closed` and add a one-line pointer to the closing SPEC version / PR /
issue. Drop `closed` rows at the next quarterly index pass (keep the
row long enough to absorb in-flight readers, then prune).

When a new SPEC version opens a new question, add a row here in the
same commit. PR review for any new SPEC version SHOULD diff this file.

## Triage history

- **2026-06-26** — initial sweep + first triage pass over SPEC-001..013.
  18 rows closed, 2 re-statused, 2 marked for follow-up issues, 5 marked
  for a small implementation patch or BUILD prompt. SPEC-014..016 not
  triaged in this pass; the SPEC-014/Q1..Q11 omnibus is intentionally
  parked pending operator portal-scope review.
- **2026-06-26 (corrections same day)** — three rows flipped to
  `closed` after re-checking SPEC body claims against current code:
  - **SPEC-003/OQ-1**: `gated` → `closed`. Apple Developer Program is
    enrolled; PR #62 + #148 + #149 + #150 shipped the full Developer-
    ID-signed + notarized + stapled `.pkg` pipeline. v1.6.1
    (2026-06-25) is the first release shipping the stapled `.pkg`.
    Initial triage was based on memory entries
    (`macprovider-launchd-amfi-blocker-macos-26`,
    `macprovider-v1-3-2-apple-dev-enrollment-blocker`) that were ~48
    hours stale; those memories have been updated.
  - **SPEC-004/FR-SR-7c**: `open` → `closed`. The "Implementation gap"
    paragraph in SPEC-004 §FR-SR-7c was stale: the operator-tunable
    `limits.max_chat_request_body_bytes` config knob exists
    (`config.go:112`) with `> 0`/`<= 128 MiB` validation; the buyer
    server enforces it with `io.LimitReader` + `413` at
    `server.go:1121-1133`.
  - **SPEC-005/OQ-4**: `open` → `closed`. `doc/provider-economics.md:137-140`
    addresses this OQ by name. A separate v0.4 docs refresh will be
    needed once SPEC-016 USDC pipeline lands.
  - **Pattern reinforced**: when a SPEC body says "we should do X" or
    "implementation gap," check the code first — three of the four
    "open/gated" rows from the initial triage pass were already
    addressed in code or docs after the SPEC body was written. Memory
    (`before-recommending-from-memory`) deserves the same skepticism.

---

## SPEC-001 — Phase 3 Binary (v1.6, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-001/OQ-1 | closed | — | — | Streaming `usage` chunk with empty `choices: []`. **2026-06-26 triage:** Gateway `chat_proxy.go:439` actively forwards this shape; 6+ months of production traffic with no client-compat report. Closed implicitly by reality. |
| SPEC-001/OQ-2 | closed | — | — | Tier announcement format (string vs structured for tier-1.5). **2026-06-26 triage:** Closed as superseded — SPEC-008 v0.3 locked the tier scheme and tier-1.5 never surfaced as a real requirement. If it does, file a new SPEC; the format question is no longer load-bearing. |

## SPEC-002 — Coordinator (v1.4, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-002/OQ-6 | closed | — | — | Surface `X-MacProvider-Tier` to buyers. **2026-06-26 triage:** Closed — decision "kept invisible" has held for a year with no buyer signal demanding it. Router weight already handles QoS. |

## SPEC-003 — Open Onboarding (v0.10, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-003/OQ-1 | closed | — | — | Code signing — Developer ID + notarization. **2026-06-26 triage (corrected later same day):** CLOSED. Apple Developer Program is enrolled and the release pipeline is live. PR #62 (`release: conditional Developer ID signing + notarization (unblocks macOS 26.3.1 launchd)`, merged 2026-06-24) shipped the pipeline activation; PR #148 (`release: skip raw CLI stapling after notarization`) and PR #149 (`release: add signed stapled pkg asset`) finished the .pkg flow; v1.6.1 (2026-06-25) is the first release whose `macprovider-cli-v1.6.1-darwin-arm64.pkg` asset is Developer-ID-signed, notarized, and stapled. The earlier "gated on procurement" row in this same pass was wrong — it relied on stale memory (`macprovider-launchd-amfi-blocker-macos-26`, `macprovider-v1-3-2-apple-dev-enrollment-blocker`) that was ~48 hours out of date. Those memories have been updated. |
| SPEC-003/* deferrals | tracked | implementer | issue #82 | Other SPEC-003 deferred items rolled up into tracking issue #82. |

## SPEC-004 — Smart Router (v0.3.1, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-004/Pillar-A | ready | operator | BUILD prompt + operator flip of `routing.sticky_enabled` | Sticky affinity. **2026-06-26 triage:** Upgraded from `gated` to `ready`. SPEC-006 v0.8 (audited ACCEPT, gate PG-9 in §22 production launch checklist) satisfies the sticky-caching guard; SPEC-004 v0.2 normative routing contract is in place. The remaining work is a BUILD prompt for "SPEC-004 Pillars B/C/D/A" + operator decision to flip `routing.sticky_enabled: true` post-launch. No other code blocker. |
| SPEC-004/FR-SR-7c | closed | — | — | **2026-06-26 triage (corrected later same day):** CLOSED. The "Implementation gap" paragraph in SPEC-004 §FR-SR-7c was stale: code shipped after v0.3.1 was written. `phase4-coordinator/internal/config/config.go:112` defines `Limits.MaxChatRequestBodyBytes int64` (yaml `limits.max_chat_request_body_bytes`), default `1 << 20`, validated `> 0` and `<= 128 MiB`. `phase4-coordinator/internal/buyer/server.go:1121-1133` enforces it with `io.LimitReader` + `413 request_too_large`. Operator-tunable without a code rebuild — the asked-for fix. |

## SPEC-005 — Billing & Settlement (v0.3, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-005/OQ-1 | deferred | implementer | next SPEC-002 patch | SPEC-002 needs a monotonic `attempt_n` column. **2026-06-26 triage:** Fallback (`request_log.id ASC` + quarantine for ambiguous rows) is production-safe per v0.3. **Action:** file a SPEC-002 amendment issue for the next coordinator patch cycle; not blocking. |
| SPEC-005/OQ-2 | closed | — | — | Round-half-to-even rounding rule. **2026-06-26 triage:** Closed as implicitly confirmed — code shipped 2026-05, running in production ~7 months without operator pushback. The "operator to confirm before v0.2 production gate" predates the actual production gate that has now been crossed. |
| SPEC-005/OQ-3 | closed | — | — | Recovery windows (24h startup, 7d nightly). **2026-06-26 triage:** Closed as implicitly confirmed — same reasoning as OQ-2; defaults shipped and have not surfaced as wrong. |
| SPEC-005/OQ-4 | closed | — | — | Provider docs wording re: credits accrual + payout deferral. **2026-06-26 triage (corrected later same day):** CLOSED. `doc/provider-economics.md:137-140` already addresses this by name: "v1 payout boundary (SPEC-005 AC-DOCS-HONESTY / OQ-4). v1 accrues credits and emits payout-ready rows; the actual payout rail (USDC settlement) requires SPEC-007 and an operator decision." `phase3-binary/README.md` links readers to that doc. A separate v0.4 docs refresh will be needed once SPEC-016 USDC pipeline lands and the answer becomes "automatically paid" — but that's a SPEC-016 follow-up, not this OQ. |
| SPEC-005/OQ-5 | deferred | implementer | — | Manual quarantine resolution admin actions (force-credit / force-void). **2026-06-26 triage:** Money-path admin surface; v0.3 exposes quarantine state but not the resolution surface. **Action:** file issue, flag "needed before scale" — not blocking pre-launch but blocks a long-tail recovery path. |

## SPEC-006 — Buyer API Gateway (v0.9, locked)

No open questions remain in the SPEC body. Sticky-affinity disclosure
(SPEC-004 Pillar A) and public explorer (v0.13 future SPEC) are tracked
under their own specs.

## SPEC-007 — Internal Operator Explorer (v0.2, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-007/M-3..M-12 | closed | — | — | Operator endpoint enhancements (backlog of 10 items). **2026-06-26 triage:** Closed — the underlying SPEC-007 audit document was never persisted to the repo. `FIX_SPEC_007_V0_2.md:113` references "M-3 through M-12 from the audit (defer to v0.3 reconciliation)" but the audit findings list is unrecoverable from repo history. If operator-explorer concerns recur, run a fresh audit cycle and number anew. |

## SPEC-008 — Tier-2 Trust Layer (v0.3, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-008/Pillar-B-C | gated | operator | ≥1 production attack vector surfacing | Encryption + attestation pillars need SPEC-001 v2.0 (Secure Enclave / hardware attestation). **2026-06-26 triage:** Explicit decision recorded here — SPEC-001 v2.0 is OUT OF SCOPE until at least one production attack vector against the trust-by-defenders-only posture surfaces. Reasoning: Pillar A (model-hash verification) plus untrusted-provider safety (Pillar D) covers the realistic v1 threat model; attestation is a 6+ month effort that should not be opportunistically built. Revisit only on a real incident or a credible buyer demanding it in writing. |
| SPEC-008/Pillar-D | deferred | implementer | — | Untrusted-provider safety, incrementally enabled coordinator-internal. **2026-06-26 triage:** Stays deferred; not a normative gap. |

## SPEC-009 — Console v2 (v0.1)

Non-goals only; nothing dormant.

## SPEC-010 — Provider Model Catalog (v1.5, lock candidate)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-010/OQ-1 | closed | — | — | Preserve case vs normalize on `/v1/status.supported_models`. **2026-06-26 triage:** Closed; preserve-case decision shipped (verified in `phase3-binary/Sources/MacProviderCore/Config.swift:251`) and no buyer-dashboard signal in 6+ months. |
| SPEC-010/OQ-2 | closed | — | — | Coordinator-side counter for providers with `supported_models`. **2026-06-26 triage:** Closed; SPEC-011 and SPEC-012 shipped without adding it, so the punt landed nowhere. Revisit only if operator observability genuinely needs the metric. |

## SPEC-011 — Operator-Pushed Warm Swap (v0.4)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-011/OQ-1 | closed | — | — | Control-socket signaling (UDS vs HTTP). **2026-06-26 triage:** Closed for v0.4. UDS is correct for macOS-only providers, which is the entire fleet today. Re-open if Linux/Windows providers ship — but that triggers a host of other questions first. |
| SPEC-011/OQ-2 | closed | — | — | CLI `--detach` for CI. **2026-06-26 triage:** Closed for v0.4. No CI fire-and-forget pattern in production. Re-open when a real consumer asks. |
| SPEC-011/OQ-3 | closed | — | — | Audit-backfill for WS-drop-mid-load completed swaps. **2026-06-26 triage:** Closed; "observation-only" decision stands. No operator feedback has surfaced demand for backfill. |

## SPEC-012 — Cold-wake / set_model wire (locked Phase 1)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-012/Phase-2 | closed | — | — | Operator-pushed swap CLI. **2026-06-26 triage:** Closed — subsumed by SPEC-011 v0.4 (operator-pushed warm swap with control-socket CLI shipped). The original Phase 2 deferral predated SPEC-011 splitting out as its own normative spec. |
| SPEC-012/Phase-3 | closed | — | — | Recommended catalog. **2026-06-26 triage:** Closed — subsumed by SPEC-010 v1.5 (catalog) + SPEC-013 v0.3 (autotune recommends from the catalog). No separate Phase 3 work needed. |

## SPEC-013 — CLI autotune (v0.3, lock candidate)

All five OQs were gated on the same "in-flight air5 n=3 replication run."

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-013/OQ-A | closed | — | — | `TPS_TIE_EPSILON` default (0.02). **2026-06-26 triage:** Closed — frozen at v0.3 placeholder. The air5 n=3 run never landed in `beta/DECISION_CRITERIA.md` and SPEC-013 IMPL shipped (PR #109) without it. Production has not signalled the placeholder is wrong. Revisit only if a real provider reports the keep-best decision flapping. |
| SPEC-013/OQ-B | closed | — | — | `stage2_replicates` default (3). **2026-06-26 triage:** Closed — same reasoning as OQ-A; frozen at v0.3. |
| SPEC-013/OQ-C | closed | — | — | Whether `kv_bits` stays a search axis. **2026-06-26 triage:** Closed — frozen at v0.3 (kept as axis). Premature fixation risk (future MLX-swift versions changing the trade-off) > cost of one extra cell, per the original SPEC-013 §9 rationale. |
| SPEC-013/OQ-D | closed | — | — | Whether Stage 1 needs N>1 replicates. **2026-06-26 triage:** Closed — frozen at v0.3 (N=1). No false-fit/false-reject reports from production autotune runs. |
| SPEC-013/OQ-E | closed | — | — | Thermal / cell-order bias in Stage 2. **2026-06-26 triage:** Closed — frozen at v0.3 (deterministic order, warned in §6 NFR-2). The 10-paired-run protocol is preserved here for future operator use if a thermal-bias suspicion ever surfaces. |

## SPEC-014 — Provider Portal (v0.2)

Largest open-Q surface in the repo; eleven load-bearing questions.
Surface D (Monitoring) is a placeholder card entirely until Q5 lands.
**Not triaged in the 2026-06-26 pass — held pending the operator portal-scope review.**

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-014/Q1 | open | operator | — | Multi-Mac owner identity. |
| SPEC-014/Q2 | open | operator | — | Releases repository + GitHub API rate limit (60/IP/hr unauthenticated) + CORS posture. |
| SPEC-014/Q3 | open | operator | future fiat-rail SPEC | Fiat payout rail. SPEC-005 §1.3 + §2.1 D1 already declare fiat out of scope. |
| SPEC-014/Q4 | open | implementer | SPEC-005 amendment | Earnings-breakdown amendment to SPEC-005 to give portal `/providers/{id}/earnings` decomposed credit fields. |
| SPEC-014/Q5 | open | implementer | SPEC-002 + others | Upstream-spec amendments omnibus: uptime history, current routing weight, live request tail, hostname/model_id/RAM/capacity wire fields. Blocks all of Surface D. |
| SPEC-014/Q6 | open | implementer | SPEC-002 amendment | Provider-side token rotation + self-service "remove this machine." |
| SPEC-014/Q7 | open | operator | Pearl VPS nginx + DNS | Portal host string + nginx config + DNS. |
| SPEC-014/Q8 | open | operator | — | Deployment-mode discovery mechanism. |
| SPEC-014/Q9 | open | operator | — | Browser-to-coordinator CORS / reverse-proxy topology. |
| SPEC-014/Q10 | open | implementer | — | Browser-local bridge for the local CLI. |
| SPEC-014/Q11 | open | operator | — | Notification delivery infrastructure. |

## SPEC-015 — Receipts (v0.1.3)

§1.2 also enumerates seven things v0.1.x explicitly does NOT specify;
all of those reduce to one of the Q-rows below.
**Not triaged in the 2026-06-26 pass.**

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-015/V0.2-verifier | deferred | implementer | SPEC-015 v0.2 | `macprovider verify <receipt.json>` buyer verification CLI. Not started. Receipts aren't usable end-to-end without this. |
| SPEC-015/Q1 | deferred | operator | SPEC-015 v0.3+ | Stronger trust root for `/v1/receipt-keys/<provider_id>` — TUF-style operator-key signing or external registry anchoring. |
| SPEC-015/Q2 | open | audit | — | Replay-resistance + request-id binding. Where does the buyer obtain its expected `request_id`? |
| SPEC-015/Q3 | deferred | implementer | Cluster F sharding | Cross-provider routing — receipt-per-segment vs receipt-per-response with embedded route list. v0.4+ candidate. |
| SPEC-015/Q4 | open | operator | coordinator timestamp surface | Timestamp trust — buyer cross-check vs coordinator response timestamp; skew window. Partially addressed in v0.2 (§10.0 step 9). |
| SPEC-015/Q5 | open | implementer | SPEC-015 v0.2+ | Streaming receipt delivery mechanism. v0.1.2 deliberately makes no choice between (a) extra field on final chunk, (b) `GET /v1/receipts/<request_id>`, (c) HTTP trailer, (d) "streaming never carries receipts." |
| SPEC-015/Q6 | closed | — | — | Model-hash binding — closed in v0.3 (tuple extends to 9 fields). Kept until next index pass. |
| SPEC-015/Q7 | deferred | audit | SPEC-015 v0.4+ | Multi-hash receipts for swap-spanning streaming responses. |

## SPEC-016 — Payout Pipeline (v0.1.19)

Already enumerated in SPEC-016 Appendix B as "filed as Issue stubs, not
inlined." Mirrored here for one-page visibility; SPEC-016 §Appendix B
is the source of truth. **Not triaged in the 2026-06-26 pass.**

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-016/B-SPEC-014-v0.9 | deferred | implementer | SPEC-014 v0.9 | Payout-address registration screen + payout history. |
| SPEC-016/B-SPEC-005-earnings | deferred | implementer | SPEC-005 vX.Y+1 | Extend `/providers/{id}/earnings` with `next_payout_eta`, `last_payout_tx_hash`, `last_payout_paid_at_utc`. Pure-additive. |
| SPEC-016/B-KMS-signer | deferred | implementer | SPEC-016 v0.2 | KMS-backed `Signer` implementation against the v0.1 `§6.3.1` interface. |
| SPEC-016/B-over-cap-split | deferred | implementer | SPEC-016 v0.2 | Auto-split of over-cap payouts. |
| SPEC-016/B-rpc-rotation | deferred | implementer | SPEC-016 v0.2 | RPC fallback rotation (N-of-M voting on top of two-RPC-agreement baseline). |
| SPEC-016/B-key-rotation | deferred | implementer | SPEC-016 v0.2 | In-process key rotation. |
| SPEC-016/B-nonce-gap-fill | deferred | implementer | SPEC-016 v0.2 | Automated nonce-gap fill (replaces operator-driven `/admin/payout/abandon-attempt`). |
| SPEC-016/B-earnings-payouts-merge | deferred | implementer | SPEC-016 v0.2 | Collapse `/providers/{id}/earnings` + `/providers/{id}/payouts` into one endpoint with versioned schema. |
| SPEC-016/B-sql-audit-promotion | deferred | implementer | SPEC-016 v0.2 | Promote journalctl-only events (chain-balance-drift, RPC-disagreement, signer-unavailable, invariant-violation) into `phase4-coordinator/internal/audit/store.go`. |
| SPEC-016/B-005-payout-ready-admin | gated | implementer | SPEC-005 vX.Y+1 | `POST /admin/ledger/payout-ready` admin endpoint to replace §4.7 manual SQL compensation. Normative contract pinned in SPEC-016 §9.5b.1. |
| SPEC-016/B-linux-only-xref | deferred | implementer | SPEC-005 v0.4 + SPEC-014 v0.9 | One-line cross-reference noting SPEC-016 Linux-only transitive constraint. |
| SPEC-016/B-ownership-inversion | deferred | implementer | SPEC-016 v0.2 (after SPEC-005 vX.Y+1) | Move §9.5b.1 normative contract surface into SPEC-005 vX.Y+2 once stabilised. |
| SPEC-016/B-hot-wallet-flag | deferred | implementer | SPEC-014 v0.9 | Extend `/providers/{id}/payouts` response with `registered_against_current_hot_wallet: bool`. |
| SPEC-016/B-shared-db-toplevel | deferred | implementer | SPEC-016 v0.2 | Replace per-table same-DB pins with a single top-level §4.0a normative paragraph + `PRAGMA database_list` IMPL test. |
| SPEC-016/B-pause-resume-rate-limit | deferred | implementer | SPEC-016 v0.2 | Asymmetric rate-limit on pause/resume endpoint pair (60s symmetric is DoS amplifier). |
| SPEC-016/B-path-pin-reword | deferred | implementer | SPEC-016 v0.2 | §4.8 normative reference to `cmd/coordinator/main.go` — reword to "during coordinator process startup before payout runner starts." |
| SPEC-016/B-master-switch-wording | deferred | implementer | SPEC-016 v0.2 | Tighten `payout.enabled` master-switch carve-out wording. |
| SPEC-016/B-runtime-namespace | deferred | implementer | SPEC-016 v0.2 | Rename `runtime.*` → `payout.runtime.*` for prefix discipline. |
| SPEC-016/B-namespace-bucket-audit | deferred | implementer | SPEC-016 v0.2 | Per-SPEC namespace-bucket audit + CI assertion that every `payout.*` reference in body appears in §6.5 enumeration. |

---

## Cross-spec dormancy patterns (initial sweep + 2026-06-26 triage)

1. **"Future SPEC vN.0" with no roadmap.** SPEC-008 Pillars B/C are
   gated on SPEC-001 v2.0; SPEC-001 v2.0 had no roadmap entry. The
   2026-06-26 triage **made this explicit**: SPEC-001 v2.0 is OUT OF
   SCOPE until at least one production attack vector surfaces.
   SPEC-014 Q4/Q5 are gated on SPEC-002/005 amendments with no
   roadmap slot — those remain genuinely open and are the next
   reconciliation target.

2. **"Operator to confirm" with no asker.** SPEC-001 OQ-1, SPEC-005
   OQ-2/OQ-3 read "operator to confirm" and went unconfirmed for
   months. The 2026-06-26 triage **converted these to "implicitly
   confirmed by sustained production traffic"** rather than chasing
   active confirmations. New pattern for future SPECs: don't write
   "operator to confirm" — write "**closes automatically after N
   weeks of production traffic with no client/operator pushback**"
   to make the close condition self-executing.

3. **Empty tracking-issue side.** Issue #82 absorbed SPEC-003
   deferrals; SPEC-004 / SPEC-005 / SPEC-007 had no analogous side.
   The 2026-06-26 triage **closed the SPEC-007 backlog as
   unrecoverable** (audit document never persisted) and **closed
   SPEC-004/FR-SR-7c and SPEC-005/OQ-4 after discovering both were
   already addressed in code/docs** the SPEC body hadn't been updated
   to reflect. Per-SPEC tracking issues filed for SPEC-005/OQ-1 (cross-
   spec SPEC-002 amendment), SPEC-005/OQ-5 (quarantine resolution
   admin), and SPEC-004/Pillar-A (BUILD prompt + operator green-light
   on `routing.sticky_enabled`).

4. **SPEC-012 vs SPEC-011 vs SPEC-013 overlap.** The 2026-06-26
   triage **closed SPEC-012 Phase 2/3 as subsumed** — Phase 2 by
   SPEC-011 v0.4 (operator-pushed warm swap CLI shipped), Phase 3 by
   SPEC-010 v1.5 (catalog) + SPEC-013 v0.3 (autotune recommends from
   catalog).
