# AUDIT_SPEC_015_v0_4_IMPL_STEP_2

Step: SPEC-015 v0.4 implementation Step 2 - coordinator route-time settlement
snapshot.

Date: 2026-07-01

Verdict: READY.

Final counts:

| Lane | Tool | Critical | High | Medium | Status |
|---|---|---:|---:|---:|---|
| Code | Codex subagent | 0 | 0 | 0 | READY |
| Security | Codex subagent | 0 | 0 | 0 | READY |
| Architect | Codex subagent | 0 | 0 | 0 | READY |
| Adversarial verification | Claude subscription CLI | 0 | 0 | 0 | READY |
| Product design critic | Claude subscription CLI | 0 | 0 | 0 | READY |

Scope to audit:

- `implementation-notes-spec-015-v0-4.md` Step 2.
- `specs/SPEC-015-receipts.md` §N.2.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/jcs.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/tier2/catalog.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 2 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Implementation validation before audit:

- `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer` PASS.
- `cd phase4-coordinator && go test ./...` PASS.

Closure evidence:

- Code lane rerun after the JCS numeric canonicalization fix: READY, 0
  critical / 0 high / 0 medium.
- Security lane retained from prior clean pass: READY, 0 critical / 0 high / 0
  medium.
- Architect lane retained from prior clean rerun: READY, 0 critical / 0 high /
  0 medium.
- Claude adversarial rerun via subscription CLI
  `claude --setting-sources local -p "$(cat specs/AUDIT_SPEC_015_v0_4_IMPL_STEP_2_ADVERSARIAL_PROMPT.md)"`
  returned READY, 0 critical / 0 high / 0 medium.
- Claude product design critic retained from prior clean pass: READY, 0
  critical / 0 high / 0 medium.

Critical/high/medium findings fixed during Step 2 audit loop:

- Prompt hash was computed from pre-rewrite buyer JSON. Fixed by hashing the
  provider-bound dispatch body and adding alias-route regression coverage.
- `catalog_signature_pubkey_fingerprint` used bare hex. Fixed to
  `ed25519-sha256:<64 lowercase hex>` across catalog material, schema,
  validation, and tests.
- Catalog material and SPEC-008 hash status could be read from different
  catalog states. Fixed by computing snapshot material and hash status from one
  locked catalog state.
- JCS number rendering used Go shortest formatting directly. Fixed with
  ECMAScript threshold rendering and regression coverage for decimal prompt
  options.

Low/advisory items retained for SPEC-022 / PR notes:

- Provider-side attempt identity is not yet carried end-to-end; SPEC-022 should
  pin the final receipt/ledger/snapshot join invariant.
- Terminal-attempt orphan snapshots remain fail-safe because settlement must
  require a matching ledger row.
- `route_decision_ts_unix_ms` remains the original route decision timestamp on
  retry/failover snapshots and may need a separate per-advance timestamp later.
