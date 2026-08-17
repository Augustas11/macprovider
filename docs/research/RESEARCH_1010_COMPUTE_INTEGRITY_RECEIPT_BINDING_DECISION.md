# RESEARCH 1010 — Compute-Integrity Receipt Binding Decision

**Date:** 2026-08-17
**Issue:** https://github.com/Augustas11/macprovider/issues/1010
**Decision:** Do not add request-start compute-integrity state digests to
SPEC-015 v0.4 receipts or `usage`. If externally reviewable binding is needed,
publish a separate SPEC-036 compute-integrity audit artifact keyed to the same
request attempt and receipt tuple. A future SPEC-015 successor may reference
that artifact only through a new `receipt_version`.

## Scope

Issue #1010 asks whether request-start compute-integrity state digests belong
in a future receipt contract. This memo evaluates three options:

1. Add a future SPEC-015 receipt field.
2. Use a separate audit artifact.
3. Do not bind compute-integrity state at all.

The immediate decision is intentionally compatibility-preserving. It does not
change provider receipt signing, receipt ingestion, settlement money movement,
or external verifier behavior for SPEC-015 v0.4.

## Current Contracts

SPEC-015 v0.4 receipts are strict settlement receipts. They bind the account,
request, route attempt, provider identity, receipt-key identity, catalog body,
route snapshot, model id/hash, prompt/output hashes, terminal state, and strict
token usage. They are provider-signed and version-discriminated by
`receipt_version: "4"`.

SPEC-036 compute integrity is a coordinator-owned sampled/overt drift gate. Its
state can affect settlement only as a subordinate SPEC-022/SPEC-036 enforce-mode
gate after the coordinator evaluates request-start compute-integrity state. It
does not prove honest computation, hardware integrity, runtime binary integrity,
or private inference.

That boundary matters: a SPEC-015 receipt proves that a provider signed a
settlement tuple. SPEC-036 evidence proves that coordinator-owned sampling and
policy state did or did not classify a covered provider/model key as adverse at
request start.

## Options

### Option A — Add a SPEC-015 Receipt Field

This would put a field such as `compute_integrity_state_digest` or
`compute_integrity_audit_digest` inside a provider-signed receipt.

Rejected for v0.4. SPEC-015 v0.4 has a strict field set, strict `usage` shape,
and deployed verifier compatibility expectations. Adding an optional field to
v0.4 would either break strict verifiers or create an ambiguous "valid but
ignored" path. Adding a required field would create a new receipt profile while
pretending the version did not change.

Option A is acceptable only as a future SPEC-015 successor profile, e.g.
`receipt_version: "5"`, after SPEC-036 live enforcement has stable artifact
shape, retention, privacy, and verifier requirements.

### Option B — Separate Audit Artifact

This keeps the provider receipt focused on settlement tuple integrity and moves
compute-integrity policy/state evidence into a coordinator-owned artifact. The
artifact can be keyed by the v0.4 receipt identity tuple:

- `account_scope`
- `request_id`
- `attempt_n`
- `provider_id`
- `route_snapshot_digest`
- digest of the provider-signed SPEC-015 tuple

The artifact can then bind SPEC-036 fields without changing receipt wire shape:

- request-start compute-integrity state digest;
- effective SPEC-036 policy version/mode/digest;
- covered profile set and hardware runtime class digests;
- SPEC-022 coverage/effective enforce status;
- sanitized adverse-state reason and retention metadata.

Recommended. This preserves v0.4 compatibility, keeps provider-signed evidence
separate from coordinator-owned policy evidence, and gives auditors enough
material to reconstruct why a settlement outcome was narrowed or disclosed.

### Option C — No Binding

This is acceptable while SPEC-036 remains observe/warn-only or buyer-visible
compute-integrity settlement effect remains unavailable. It becomes too weak if
SPEC-036 enforce mode later changes money outcomes and operators need durable,
external, request-level auditability.

## Recommendation

Choose Option B now: separate SPEC-036 audit artifact, no SPEC-015 v0.4 receipt
field.

SPEC-015 should record that v0.4 receipts MUST NOT include
compute-integrity state digests, sampler state, policy digests, probe digests,
or artifact digests as tuple or `usage` fields. A v0.4 verifier that receives
such fields keeps using the existing strict extra-field rejection path.

SPEC-036 should own any future audit artifact and explicitly state that the
artifact is not a receipt, does not make an old receipt version compute-aware,
and is not required for v0.4 receipt validity. A future SPEC-015 version may
reference a SPEC-036 artifact digest only by defining a successor
`receipt_version`.

## Migration and Compatibility

Existing v0.4 receipts stay valid or invalid exactly as before. No v0.4 tuple
field, `usage` field, envelope field, or external verifier result schema changes
in this decision.

External `macprovider-verify` behavior remains:

- v0.4 receipts with the exact strict field set verify under existing v0.4
  rules;
- v0.4 receipts with compute-integrity fields are rejected as extra-field
  inputs;
- unknown future `receipt_version` values remain
  `inconclusive: unknown_receipt_version`;
- compute-integrity artifact verification, if built, is a separate command or
  mode, not an implicit part of v0.4 receipt verification.

Coordinator/gateway changes are deferred. A later implementation issue should
define the artifact schema, retention/redaction, retrieval authority, and
whether the artifact is operator-only, buyer-visible, or both.

## Follow-Up Implementation Surface

If this decision is accepted, later implementation work should be split from
the decision PR:

- SPEC-036 audit artifact schema and canonical digest preimage.
- Coordinator persistence/export of sanitized request-start compute-integrity
  artifact rows.
- Gateway or operator retrieval surface, if buyer or auditor access is desired.
- Optional `macprovider-verify` artifact-verification command.
- Future SPEC-015 successor profile only if the artifact digest must become
  provider-signed receipt material.
