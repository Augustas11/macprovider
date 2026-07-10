# AUDIT SPEC-015 v0.4 Implementation Step 5

Date: 2026-07-01

Scope:

- Branch/worktree: `impl/spec-015-v0-4-settlement-receipts`
- Step: coordinator receipt ingestion, durable verdict state, and redacted
  receipt authorization/candidate read API.
- Claude adversarial/product lanes are deferred until full implementation per
  operator instruction.

Validation evidence:

| Command | Result |
|---|---|
| `cd phase4-coordinator && go test ./internal/billing -run 'SettlementReceipt\|Settlement\|RouteSnapshot' -count=1 -v` | PASS |
| `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer ./internal/config` | PASS |
| `cd phase4-coordinator && go test ./...` | PASS |
| `git diff --check` | PASS |

Final Codex lane status:

| Lane | Final status |
|---|---|
| Code | CRITICAL=0 / HIGH=0 / MEDIUM=0 |
| Security | CRITICAL=0 / HIGH=0 / MEDIUM=0 |
| Architect | CRITICAL=0 / HIGH=0 / MEDIUM=0 |

Findings fixed:

- CODE-M1: `settlement_receipt_verdict` audit payloads lacked SPEC-022 R-11
  structured verdict fields. Fixed by persisting and emitting paid entrypoint,
  provider session/generation, route policy/mode, route-time hash status,
  route-time provider model hash, receipt profile/version, receipt result,
  buyer/provider no-money outcomes, payout exclusion outcome, and related
  catalog/model evidence.
- SECURITY-H1: provider-controlled receipt facts could overwrite
  coordinator-authoritative model/output/usage evidence in durable verdict rows
  and audit payloads. Fixed by sourcing those fields only from route/output
  evidence and keeping receipt tuple facts in `facts_json` plus an explicitly
  receipt-scoped tuple digest diagnostic.
- ARCH-H1: SPEC-022 consumers had no durable read API. Fixed with
  `GetSettlementReceiptAuthorization`.
- ARCH-H2: receipt deadlines trusted caller-supplied receive time. Fixed by
  coordinator-stamping receipt arrival through the store clock; tests use an
  unexported package seam.
- ARCH-H3: verified verdicts could become stale after later overlap backfill.
  Fixed by rejoining current `settlement_attempt_outputs` state in the read
  API before returning positive candidate evidence.
- ARCH-H4 / ARCH-M1: pending receipt deadline and route mode policy bounds were
  not enforced. Fixed with config validation, route snapshot validation, and
  schema constraints for `pending_deadline_seconds <= 900` and
  `route_snapshot_mode IN ('observe','enforce')`.
- SECURITY-M1: audit payloads exposed raw `account_scope`. Fixed by emitting
  stable `account_scope_hash` and testing the raw field is absent.
- SECURITY-M2 / ARCH-M1: terminal duplicate/late no-op verdict audits omitted
  verdict fields when verifier checks were unavailable. Fixed by always
  emitting verdict outcome, reason, deadline, idempotency status, Step 5 money
  outcomes, and `attempted_received_at_unix_ms`; checks remain optional.
- ARCH-H1 rerun: the read API exposed `Payable=true`, which was too close to
  final SPEC-022 money authorization. Fixed by renaming the API surface to
  `PositiveSettlementCandidate` / `CandidateBlockedReason`.

Residual risks:

- Step 5 intentionally does not move money. SPEC-022 must add the final money
  gate and must not widen `PositiveSettlementCandidate` into final debit,
  provider credit, or payout authorization.
- `gopls` was not available to all auditor lanes; Go compilation/tests covered
  the modified packages.

Conclusion:

Step 5 is closed for Codex code/security/architect audit lanes with 0
critical, 0 high, and 0 medium findings.
