# #1690 audit R2: negotiated, MAC'd settlement trailers (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine. Do not modify any file.

**Focus:** `git diff 00cb36fd ac0731b5`, the fix for the round-1 delivered-only findings. Full context is `git diff 92340eee ac0731b5` (6d48d9cc delivered-only billing + the fixes). The baseline pre-#1690 behaviour is origin/main.

## Round-1 findings and the claimed fixes

1. **Non-streaming missing or stripped trailers failed open to legacy debit.**
   `coordinatorNonStreamingSettlementFinality` (`phase5-gateway/internal/router/settlement_trailers.go`) now holds as `missing_settlement_finality_trailer` when trailers were declared but values are missing, the MAC is missing or bad, the tuple is replayed, or headers are substituted. Streaming and non-streaming share the observe-mode fallback `settleMissingFinalityTrailerAsObserve`.
2. **Mixed-version was unsafe in both directions, and the runbook contradicted SPEC-022 R-12.8.**
   - Per-request negotiation: the gateway sends `X-MacProvider-Internal-Settlement-Trailers: 1`, and only when a service bearer is configured.
   - The coordinator honours it only together with a matching service-token bearer (`gatewayNegotiatedSettlementTrailers`, `phase4-coordinator/internal/buyer/settlement_trailers.go`). A buyer-port request carrying an `X-MacProvider-Internal-*` header without the token is refused.
   - A caller that did not negotiate gets the exact pre-#1690 order (record, ingest, header finality, then write) on both HTTP and WS. Negotiated callers get delivered-only recording plus trailers.
   - Loopback credit does not depend on the order: it requires a pinned-key receipt that backs the usage.
   - Runbook §9 and R-12.8 now agree: drain ledger recovery, then coordinator, gateway, the new gateway pin, CLI, and v2 allowlists last. Rollback runs in reverse, with the pin off first.
   - Evidence for the v14 claim: the origin/main gateway has `maxKnownSchemaVersion = 13`, and the production Pearl gateway (v1.8.193) has `gateway.db` `max(schema_migrations)` = 13. So an older gateway refuses a v14 DB.
3. **Rotation-grace key mismatch between the hot path and final verification.**
   Every site is now current-key only. `ActiveReceiptPubkeyPrev` is removed, per SPEC-022 R-4.4.1 (quarantine any key other than the route-snapshot key) and SPEC-015 §7.5 step 7.
4. **Unauthenticated trailers.**
   New trailer `X-MacProvider-Settlement-Finality-Mac`: HMAC-SHA256 keyed by the gateway service token, over a domain tag, the account, the gateway-sent request id and the seven finality values, each length-prefixed. The gateway compares with `hmac.Equal`, and the same test vector is pinned on both sides.
5. **A post-delivery record or ingest failure** now sends a signed open `pending` tuple, so the gateway holds. WS `Logged = true` is set only on success, and there is no second provider-fault row.
6. **Strip-everything downgrade.** The gateway config `coordinator.require_settlement_trailers` (default false) holds any coordinator 200, streaming or non-streaming, that declares no settlement trailers. The runbook enables it after both deploys are confirmed.

## Check

- **CODE:**
  - correctness of negotiation on the HTTP and WS paths;
  - MAC canonicalization agreeing byte-for-byte on both sides;
  - the non-negotiated path truly matching origin/main's order;
  - the pin's effect on paid 200s without a route snapshot (held; is that correct and recoverable?);
  - test adequacy.
- **SECURITY / money path:**
  - Can a buyer or provider forge negotiation, the MAC, or finality?
  - Is any path double-settled, left unsettled forever, free-delivered, or billed while undelivered?
  - Do the old-gateway/new-coordinator and new-gateway/old-coordinator pairings each behave safely?
  - Is the MAC key handled without logging?
  - Does removing prev-key acceptance open any gap?
- **ARCH:**
  - SPEC-022 R-12.8, the v0.2.2 change log, runbook §9 and the rollback order are consistent;
  - the held-settlement reconciler path resolves every hold;
  - CONFORMANCE consistency.

Pre-#1690 exposures (for example, unsigned streaming finality headers, which are unchanged) should be labelled PRE-EXISTING, not counted as new, unless this diff makes them worse.

Report only real defects at their true severity, with file:line. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
