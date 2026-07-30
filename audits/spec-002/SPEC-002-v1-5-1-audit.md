# SPEC-002 v1.5.1 audit trail (issue #197)

Three-lane codex audit on the v1.5.1 R-2 normative clarifications + sanitizer hardening.

## Scope

v1.5.1 closes the SPEC text gaps identified by codex on PR #195 (architect R7/R8) plus the C1 sanitizer-bypass class surfaced by the v1.5.1 R1 code + security lanes:

1. **UUID-tolerance** — `external_request_id` is opaque sanitized text, not UUIDv4-shape-required. Sanitization is byte-level (raw C1 bytes must be rejected, not just runes).
2. **Per-key migration-state machine** — each composite reconciliation key has its own `legacy | unindexed | indexed` state; aggregate is min-wise. Canonical vocabulary `"legacy"|"unindexed"|"indexed"` MUST be emitted by tooling.
3. **Machine-readable state surface** — `coordinator migrate-indexes --check --format json` exposes per-key + aggregate state via `requestlog.Store.MigrationState`.
4. **State `unindexed` operational binding** — production reconciliation tooling MUST fail closed; explicit override MUST NOT be default.
5. **Sanitizer hardening code change** — `sanitizeExternalRequestID` / `sanitizeAccountID` consolidated into `sanitizeOpaqueHeader`; byte-level C1 rejection + invalid UTF-8 rejection; tests pinned for 0x80, 0x9b, 0x9f, and invalid UTF-8 leads.

## R1 → R2 disposition

R1 returned 0 CRITICAL / 4 HIGH (1 CODE + 1 SECURITY convergent on C1 sanitizer; 2 ARCHITECT on state-machine + state-(B) operational binding) / 1 MEDIUM / 2 LOW.

Convergent CODE+SECURITY HIGH (C1 raw-byte bypass via `utf8.RuneError`):
- Fixed in [phase4-coordinator/internal/buyer/server.go](../phase4-coordinator/internal/buyer/server.go): `sanitizeExternalRequestID` and `sanitizeAccountID` now route through a shared `sanitizeOpaqueHeader` that validates UTF-8 then iterates byte-by-byte over the C0/DEL/C1 reject set.
- Regression tests added in [phase4-coordinator/internal/buyer/server_test.go](../phase4-coordinator/internal/buyer/server_test.go) `TestRequestLogExternalRequestIDRejectsMalformedHeader`: new cases `c1_low` (0x80), `c1_csi` (0x9b), `c1_high` (0x9f), `invalid_utf8_lead`, `invalid_utf8_alone`.

ARCHITECT HIGH #1 (state-(B) operational binding ambiguous vs SPEC-005 schema-check):
- SPEC §11 v1.5.1 block now binds production reconciliation tooling to fail closed under state `unindexed`; explicit `--allow-unindexed-scan` override allowed for fixture/dev/recovery only.

ARCHITECT HIGH #2 (state machine must be per-key, not whole-schema):
- SPEC §11 v1.5.1 block restructured: per-key state machine; aggregate is min(states) with `legacy` if any key legacy, `indexed` only if all keys indexed, `unindexed` otherwise.
- Implemented in [phase4-coordinator/internal/requestlog/store.go](../phase4-coordinator/internal/requestlog/store.go) `MigrationState` returning `MigrationStatus{Aggregate, Keys[]}` with per-key `MigrationKeyState`.
- Test: [phase4-coordinator/internal/requestlog/store_test.go](../phase4-coordinator/internal/requestlog/store_test.go) `TestMigrationStateReportsPerKeyStatesAndAggregate` exercises all three states and the legacy-wins aggregation.

ARCHITECT MEDIUM (machine-readable enum + CLI surface):
- Canonical vocabulary `"legacy"|"unindexed"|"indexed"` pinned normatively.
- New CLI: `coordinator migrate-indexes --check --format json` in [phase4-coordinator/cmd/coordinator/migrate_indexes.go](../phase4-coordinator/cmd/coordinator/migrate_indexes.go); read-only, does not mutate schema.

ARCHITECT LOW (naming clash "Phase-C reconciliation tooling" with state (C)):
- Removed; SPEC text now refers to "reconciliation tooling" without the Phase-C qualifier.

CODE LOW (workflow note: `migrate-indexes` against legacy DB takes A → C directly):
- Clarified in the "Expected operator workflow" paragraph.

## Round dispositions

### R1 (3 lanes)
- CODE: 1 HIGH (raw C1 bytes bypass sanitizer via `utf8.RuneError`) + 1 LOW (workflow note).
- SECURITY: 1 HIGH (same C1 raw-byte bypass — terminal CSI injection).
- ARCHITECT: 2 HIGH (state-(B) operational binding ambiguous; state machine should be per-key, not whole-schema) + 1 MEDIUM (machine-readable enum + CLI surface) + 1 LOW (Phase-C naming clash with state C).

### R2 fixes (5 MEDIUM emerged from R2 audit)
- Byte-level `sanitizeOpaqueHeader` (closes convergent R1 CODE+SECURITY HIGH).
- Per-key state machine: `MigrationState` returns per-key + aggregate `legacy | unindexed | indexed`.
- Canonical state vocabulary pinned normatively.
- New CLI `coordinator migrate-indexes --check --format json`.
- Registry invariant clause (non-empty, append-only).
- SPEC §11 + change-log restructured.
- R2 audit returned: CODE 2 MEDIUM (`--check` mutates schema; billing.Store doesn't enforce MUST); SECURITY 2 MEDIUM (other fields use weaker sanitizer; same MUST gap); ARCHITECT 1 MEDIUM (SPEC-005 alignment).

### R3 fixes
- `OpenStoreReadOnly` + route `--check` through it; validate `--format` before opening.
- `sanitizeRequestLogText` strengthened (UTF-8 validation + C1 strip).
- Sharpened operational-binding SPEC scope: applies to closing-the-books out-of-process tooling, NOT in-process recovery.
- Bumped SPEC-005 → v0.3.2; depend on SPEC-002 v1.5.1.
- Shared registry between MigrationState and MigrateIndexes (single source of truth).
- R3 audit returned: CODE 1 CRITICAL (`model` field not sanitized); SECURITY 1 CRITICAL (same) + 1 HIGH (`/v1/pool/check?provider_id=`); ARCHITECT 2 MEDIUM (SPEC-005 §1.4 stale; scope by data-surface contract) + 2 LOW.

### R4 fixes
- `sanitizeRequestLogText(b.model)` on persistence; sanitize `/v1/pool/check?provider_id=` before log.
- New `sqliteutil.ReadOnlyDSN` (mode=ro + query_only=ON; no WAL/synchronous pragmas).
- SPEC scope rewritten by data-surface contract (in-scope = closing-the-books joins to gateway `usage_events` / `audit_events`; out-of-scope = in-process AttemptN over single-table `request_log`).
- SPEC-005 §1.4 bumped to v1.5.1.
- Deprecate-and-add escape hatch + JSON array order normative.
- R4 audit returned: CODE 0 C/H/M + 1 LOW (test strength); SECURITY 0 C/H + 2 MEDIUM (provider-side `hello.provider_id`; SPEC FR-B9 prose gap); ARCHITECT 0 C/H + 1 MEDIUM (SPEC-005 §10.4 + SPEC-002 line 1560 residual "out-of-process") + 1 LOW.

### R5 fixes
- `requireString` hardened to reject control characters at WS parse time.
- New "Buyer-controlled text sanitization" §11 paragraph enumerating every column + sanitizer.
- SPEC-005 §10.4 + SPEC-002 line 1560 rewritten to data-surface contract phrasing.
- Tightened model-sanitize test to assert exactly 1 row with `model == "modelabc"`.
- `TestParseHelloRejectsControlCharsInRequiredStrings` regression test added.
- R5 audit returned: CODE 1 MEDIUM (other parsers bypass `requireString`); SECURITY 1 HIGH (same — `endpoint_url`, `model_hash`, `state_update.reason`, `heartbeat.model_hash`, unknown envelope `type`); ARCHITECT 0 C/H/M + 2 LOW. ARCHITECT lane converged.

### R6 fixes (security + code, architect skipped)
- Extracted shared `containsControlChar(s)` helper.
- Applied at: `ParseHello`/`parseAuthInitial` (model_hash + endpoint_url); `ParseStateUpdate` (reason, since); `ParseHeartbeat` (model_hash); `ParsePreflightAck` (request_id); `ParseNak` (in_reply_to, error.code, error.message); inference chunk/end relay handlers (post-parse).
- Unknown-envelope `type` redacted to sentinel before logging.
- R6 audit returned: CODE 1 HIGH (encrypted-frame `envelope.RequestID` / `aad.RequestID` log before guard); SECURITY 1 HIGH (same).

### R7 fixes (security + code)
- Two-layer guard in `handleInferenceChunk` / `handleInferenceEnd`: top-of-function on `envelope.RequestID` (before any tier2 log helper or `sessionFor` lookup), and post-AAD-decode on `requestID` (before `session.activeFor` and any decoded-id log).
- Plaintext-branch post-parse `chunk.RequestID` / `end.RequestID` guards from R5 remain in place.
- R7 audit: CODE 0 C/H/M (1 LOW cosmetic ordering); SECURITY 0 C/H/M.

### R8 NOT REQUIRED — Converged.

All three lanes at **0 CRITICAL / 0 HIGH / 0 MEDIUM**:
- CODE lane: R7 0 C/H/M (1 LOW cosmetic).
- SECURITY lane: R7 0 C/H/M.
- ARCHITECT lane: R5 0 C/H/M (2 LOW).

Loop closed.
