# AUDIT_SPEC_015_IMPL_STEP_0 — Locked-spec candidate absorption audit

You are auditing Step 0 of `specs/BUILD_SPEC_015_IMPL_PROMPT.md` on branch
`impl/spec-015-step-00`.

## Scope

Step 0 is spec-only. The only intended modified files are:

- `specs/SPEC-001-phase3-binary.md`
- `specs/SPEC-002-coordinator.md`
- `specs/SPEC-006-buyer-api.md`

No runtime code, tests, README text, deployment config, or other locked specs
should be modified in this step.

## Intended changes

1. SPEC-001 line-3 version bumps from v1.5 to v1.6.
   - Top change-log block records SPEC-015 v0.1.3 absorption.
   - §6.7.1 initial-stage `auth_request` table gains exactly one optional
     `provider_receipt_public_key` row.
   - New §6.7.5 cross-references SPEC-015 and states the field is
     initial-stage only, parser-optional, standard padded base64 of exactly
     32-byte ed25519 public key material.
   - Proof-stage frame text/table is not modified to include the field.

2. SPEC-002 line-3 version bumps from v1.3.5 to v1.4.
   - Top change-log block records SPEC-015 v0.1.3 absorption.
   - `/poolz` provider row gains additive `receipt_pubkey` and
     `receipt_pubkey_prev` fields.
   - `receipt_pubkey` is nullable standard padded base64 32-byte ed25519
     public key.
   - `receipt_pubkey_prev` is nullable and, when populated, has exactly
     `pubkey`, `rotated_at`, and `expires_at`.
   - Cross-reference text points back to SPEC-015 and keeps durable storage
     out of scope.

3. SPEC-006 line-3 version bumps from v0.8.3 to v0.9.
   - Top change-log block records SPEC-015 v0.1.3 absorption.
   - Response-pass-through allowlist gains exactly `X-MacProvider-Receipt`.
   - Inbound buyer request header stripping rules remain unchanged.
   - No `X-MacProvider-Receipt-Pending` or any second buyer-visible
     receipt-related `X-MacProvider-*` header is introduced.

## Audit tasks

Review the diff against `origin/spec/015-receipts-v0-1` and report findings
by severity:

- CRITICAL: any code/runtime change; edits to locked specs outside the three
  intended files; proof-stage `provider_receipt_public_key`; second
  receipt-related buyer-visible header; non-additive wire/schema change.
- MAJOR: wrong field/header name; wrong base64/public-key semantics; parser
  requiredness not optional; `/poolz` null/object shape mismatches SPEC-015;
  change-log misstates the absorption; response allowlist incomplete or
  internally inconsistent.
- MINOR: wording, line-placement, or clarity issues that do not change the
  contract.

The lock gate for this step is 0 CRITICAL and 0 MAJOR.

Return a concise report with:

- Verdict: READY or NEEDS FIX PASS.
- Counts: CRITICAL / MAJOR / MINOR.
- Findings with file/line references.
- Any residual non-blocking notes.
