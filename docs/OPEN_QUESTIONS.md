# Open Questions Ledger

Single-page index of every open question, deferred item, and "future-spec"
pointer currently documented across the normative `specs/SPEC-*.md` files.
Built 2026-06-26 from a full sweep of SPEC-001 through SPEC-016.

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
  - `deferred` — explicitly punted to a named future SPEC version
  - `decided-no-revisit` — decided once; re-examine if conditions change
  - `resolved` — closed; kept here as a pointer until the next index pass
- **owner** is "operator" when only the operator can decide,
  "implementer" when it's a coding follow-up, "audit" when the next
  audit cycle is meant to close it.
- **blocker** names the specific upstream artifact (`SPEC-001 v2.0`,
  `air5 n=3 run`, `Apple Dev enrollment`, `issue #82`, …) — empty if
  nothing concrete is blocking.

## Maintenance

When a SPEC version lands that closes an entry, change its `status` to
`resolved` and add a one-line pointer to the closing SPEC version /
PR / issue. Drop `resolved` rows at the next quarterly index pass
(keep the row long enough to absorb in-flight readers, then prune).

When a new SPEC version opens a new question, add a row here in the
same commit. PR review for any new SPEC version SHOULD diff this file.

---

## SPEC-001 — Phase 3 Binary (v1.6, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-001/OQ-1 | open | operator | — | Streaming `usage` chunk with empty `choices: []` — some downstream clients may not expect it. "Operator to confirm downstream client compat." Never revisited; one of the oldest dormant items in the repo. |
| SPEC-001/OQ-2 | deferred | — | future Tier-2 SPEC | Tier announcement format — version string vs structured object to enable tier-1.5. SPEC-008 landed but did not address this. Likely stale. |

## SPEC-002 — Coordinator (v1.4, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-002/OQ-6 | decided-no-revisit | operator | — | Surface `X-MacProvider-Tier` to buyers. Decided "no" — kept invisible in v1; router weight handles QoS. Marked for reconsideration if buyer-side routing control is needed. |

## SPEC-003 — Open Onboarding (v0.10, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-003/OQ-1 | gated | operator | Apple Dev Program enrollment ($99) | Code signing — Developer ID + notarization vs `xattr -d` workaround. v1.2 ships unsigned; install.sh strips quarantine. Active blocker today: v1.3.1+ launchd installs fail on macOS 26 (memory: `macprovider-launchd-amfi-blocker-macos-26`, `macprovider-v1-3-2-apple-dev-enrollment-blocker`). |
| SPEC-003/* deferrals | tracked | implementer | issue #82 | Other SPEC-003 deferred items rolled up into tracking issue #82 (memory: `spec-003-v0-9-2-composed-contract`, `tracking-issue-scope-control`). |

## SPEC-004 — Smart Router (v0.3.1, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-004/Pillar-A | gated | implementer | SPEC-006 v0.8 PG-9 | Sticky affinity must not be implemented until SPEC-006 v0.8 lands gateway conversation-key mechanism and lifts the sticky-caching prohibition. Recheck whether PG-9 has opened. |
| SPEC-004/FR-SR-7c | open | implementer | — | 1 MiB coordinator ingress cap is hardcoded in v0.3; "follow-up to make operator-tunable" matching gateway `Limits.RequestBodyBytes` pattern. No issue filed. |

## SPEC-005 — Billing & Settlement (v0.3, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-005/OQ-1 | open | implementer | SPEC-002 patch | SPEC-002 needs a monotonic `attempt_n` column. v0.3 uses `request_log.id ASC` fallback + quarantine. Not filed against SPEC-002. |
| SPEC-005/OQ-2 | open | operator | — | Rounding rule (round-half-to-even) — "operator to confirm before v0.2 production gate." |
| SPEC-005/OQ-3 | open | operator | — | Recovery windows (24h startup, 7d nightly) — "operator to confirm operational fit." |
| SPEC-005/OQ-4 | open | implementer | — | Provider docs wording re: credits accrual + payout deferral. Pure docs miss. |
| SPEC-005/OQ-5 | deferred | implementer | — | Manual quarantine resolution admin actions (force-credit / force-void). v0.3 exposes quarantine state but not the resolution surface. Money-path; not in issue #82. |

## SPEC-006 — Buyer API Gateway (v0.9, locked)

No open questions remain in the SPEC body. Sticky-affinity disclosure
(SPEC-004 Pillar A) and public explorer (v0.13 future SPEC) are tracked
under their own specs.

## SPEC-007 — Internal Operator Explorer (v0.2, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-007/M-3..M-12 | deferred | implementer | SPEC-007 v0.3+ | Operator endpoint enhancements (backlog of 10 items). v0.3 has not been opened. |

## SPEC-008 — Tier-2 Trust Layer (v0.3, locked)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-008/Pillar-B-C | gated | implementer | SPEC-001 v2.0 | Encryption + attestation pillars need SPEC-001 v2.0. SPEC-001 v2.0 has no roadmap entry — silent dependency. |
| SPEC-008/Pillar-D | deferred | implementer | — | Untrusted-provider safety, incrementally enabled coordinator-internal. |

## SPEC-009 — Console v2 (v0.1)

Non-goals only; nothing dormant.

## SPEC-010 — Provider Model Catalog (v1.5, lock candidate)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-010/OQ-1 | decided-no-revisit | implementer | buyer-dashboard signal | Preserve case vs normalize on `/v1/status.supported_models`. Decision: preserve (spots config issues). Reconsider if buyer dashboards demand consistency. |
| SPEC-010/OQ-2 | deferred | implementer | SPEC-011/012 | Coordinator-side counter for providers with `supported_models`. Punted to SPEC-011 / SPEC-012. |

## SPEC-011 — Operator-Pushed Warm Swap (v0.4)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-011/OQ-1 | deferred | implementer | SPEC-011 v0.5+ | Control-socket signaling: Unix domain socket today; future cross-platform target may need localhost HTTP. |
| SPEC-011/OQ-2 | deferred | implementer | SPEC-011 v0.5+ | CLI `--detach` for CI fire-and-forget. |
| SPEC-011/OQ-3 | decided-no-revisit | operator | operator feedback | Audit-backfill for WS-drop-mid-load completed swaps. Decided "observation-only, no backfill"; revisit if operator pain surfaces. |

## SPEC-012 — Cold-wake / set_model wire (locked Phase 1)

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-012/Phase-2 | deferred | implementer | SPEC-012 v0.4 | Operator-pushed swap CLI. Look for overlap with SPEC-011 v0.4 before opening — may already be effectively superseded. |
| SPEC-012/Phase-3 | deferred | implementer | SPEC-012 v0.5 | Recommended catalog. Likely subsumed by SPEC-013; reconcile. |

## SPEC-013 — CLI autotune (v0.3, lock candidate)

All five are gated on the **in-flight air5 n=3 replication run**. If
the run has happened, all five can close in one v0.4 patch; if the
run has stalled, the run itself is the dormant item.

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-013/OQ-A | gated | audit | air5 n=3 run | `TPS_TIE_EPSILON` default (currently 0.02). |
| SPEC-013/OQ-B | gated | audit | air5 n=3 run | `stage2_replicates` default (currently 3). |
| SPEC-013/OQ-C | gated | audit | air5 n=3 run | Whether `kv_bits` stays a search axis or bakes in as default 8. |
| SPEC-013/OQ-D | gated | audit | air5 n=3 run | Whether Stage 1 fit-determination needs N>1 replicates. |
| SPEC-013/OQ-E | gated | audit | air5 n=3 run | Thermal / cell-order bias in Stage 2. Sampling protocol: 10 paired forward/reverse runs, threshold 5% mismatch. |

## SPEC-014 — Provider Portal (v0.2)

Largest open-Q surface in the repo; eleven load-bearing questions.
Surface D (Monitoring) is a placeholder card entirely until Q5 lands.

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

| id | status | owner | blocker | summary |
|---|---|---|---|---|
| SPEC-015/V0.2-verifier | deferred | implementer | SPEC-015 v0.2 | `macprovider verify <receipt.json>` buyer verification CLI. Not started. Receipts aren't usable end-to-end without this. |
| SPEC-015/Q1 | deferred | operator | SPEC-015 v0.3+ | Stronger trust root for `/v1/receipt-keys/<provider_id>` — TUF-style operator-key signing or external registry anchoring. |
| SPEC-015/Q2 | open | audit | — | Replay-resistance + request-id binding. Where does the buyer obtain its expected `request_id`? |
| SPEC-015/Q3 | deferred | implementer | Cluster F sharding | Cross-provider routing — receipt-per-segment vs receipt-per-response with embedded route list. v0.4+ candidate. |
| SPEC-015/Q4 | open | operator | coordinator timestamp surface | Timestamp trust — buyer cross-check vs coordinator response timestamp; skew window. Partially addressed in v0.2 (§10.0 step 9). |
| SPEC-015/Q5 | open | implementer | SPEC-015 v0.2+ | Streaming receipt delivery mechanism. v0.1.2 deliberately makes no choice between (a) extra field on final chunk, (b) `GET /v1/receipts/<request_id>`, (c) HTTP trailer, (d) "streaming never carries receipts." |
| SPEC-015/Q6 | resolved | — | — | Model-hash binding — RESOLVED in v0.3 (tuple extends to 9 fields). Kept until next index pass. |
| SPEC-015/Q7 | deferred | audit | SPEC-015 v0.4+ | Multi-hash receipts for swap-spanning streaming responses. |

## SPEC-016 — Payout Pipeline (v0.1.19)

Already enumerated in SPEC-016 Appendix B as "filed as Issue stubs, not
inlined." Mirrored here for one-page visibility; SPEC-016 §Appendix B
is the source of truth.

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

## Cross-spec dormancy patterns

A few patterns stand out from the sweep:

1. **"Future SPEC vN.0" with no roadmap.** SPEC-008 Pillars B/C are
   gated on SPEC-001 v2.0; SPEC-001 v2.0 has no roadmap entry. Same
   shape: SPEC-014 Q4 gated on SPEC-005 amendment without a SPEC-005
   roadmap slot, SPEC-014 Q5 gated on SPEC-002 amendment without a
   SPEC-002 roadmap slot.

2. **"Operator to confirm" with no asker.** SPEC-001 OQ-1, SPEC-005
   OQ-2/OQ-3 all read "operator to confirm" and have been confirmed
   by nobody for months. These need either a poke or a "confirmed in
   prod, closing" entry.

3. **Empty tracking-issue side.** Issue #82 absorbed SPEC-003 deferrals
   per memory, but the analogous side for SPEC-004 / SPEC-005 / SPEC-007
   was never opened. Three of the ledger rows above could fold into
   one new tracking issue per SPEC if the operator preferred GitHub
   over this file.

4. **SPEC-012 vs SPEC-011 vs SPEC-013 overlap.** The cold-wake / warm-
   swap / autotune trio grew in parallel. SPEC-012 Phase 2/3 deferrals
   may already be fulfilled by SPEC-011 v0.4 and SPEC-013 v0.3 — a
   reconciliation pass would let the SPEC-012 entries close.
