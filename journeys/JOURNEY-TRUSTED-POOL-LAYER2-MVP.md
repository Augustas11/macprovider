# JOURNEY-TRUSTED-POOL-LAYER2-MVP

TL;DR: This is the signed evidence contract for the SPEC-042 Layer 2 MVP request path. It captures narrow evidence for pool selection authority, per-attempt tenant isolation, labels bound to route snapshots, and rollout/fail-closed capability behavior, but it is evidence-only and does not promote full requirement rows.

TL;DR: This journey is not evidence for production pool launch, durable manifest/membership reconstruction, full trust-predicate coverage, revenue-split execution, coordinator-blind content, provider-operator blindness, or Layer 3 privacy.

## Scope

This journey proves a reviewed, isolated candidate run of the Trusted Pool Layer 2 MVP path:

- a request scoped to an authorized pool is accepted and served by an admitted, eligible member;
- a pool-required request whose pool selection or eligibility is unsatisfied fails closed before global fallback;
- the settlement route snapshot preserves `pool_id` plus a canonical route digest for the successful request, while `manifest_version` and `manifest_core_digest` remain candidate-identity evidence fields in this local harness;
- the emitted evidence is redacted and explicitly does not claim Privacy Pool, coordinator-blind, or provider-operator-blind properties.

Mapped evidence targets:

- `SPEC-042-R002`
- `SPEC-042-R005`
- `SPEC-042-R006`
- `SPEC-042-R010`

Signed evidence:

- Redacted artifact: `journeys/evidence/trusted-pool-layer2-20260824T011501Z.redacted.json`
- Signed envelope: `journeys/evidence/trusted-pool-layer2-20260824T011501Z.spec-042-r002-spec-042-r005-spec-042-r006-spec-042-r010.journey-result.signed.json`
- Workflow run: [`32683243549`](https://github.com/Augustas11/macprovider/actions/runs/32683243549)
- Manifest: `journeys/evidence/trusted-pool-layer2-20260824T011501Z.spec-042-r002-spec-042-r005-spec-042-r006-spec-042-r010.evidence-manifest.json`

Not satisfied by this journey:

- `SPEC-042-R001` manifest identity/history/rollback, because durable production wiring remains separate;
- `SPEC-042-R003` membership/revocation lifecycle, because durable membership/blocklist reconstruction remains separate;
- `SPEC-042-R004` full predicate coverage, because only the currently wired fail-closed path can be exercised here;
- `SPEC-042-R007` retention matrix, `SPEC-042-R008` signed promise surfaces, `SPEC-042-R009` Layer 3 binding/claim control, `SPEC-042-R011` lifecycle reconstruction, and `SPEC-042-R012` authority lifecycle.

## Evidence Contract

The reviewed redacted evidence artifact MUST be committed under:

```text
journeys/evidence/trusted-pool-layer2-*.redacted.json
```

It MUST use:

```json
{
  "schema_version": "macprovider.trusted-pool-layer2-evidence.v1",
  "journey_id": "JOURNEY-TRUSTED-POOL-LAYER2-MVP"
}
```

The signer workflow converts that artifact into a generic signed journey-result envelope only after:

- the redacted evidence source is repository-relative, non-symlinked, and byte-identical at `--evidence-sha`;
- `repository.commit` equals `--source-sha`;
- `--source-sha` is an ancestor of `--evidence-sha`;
- every selected requirement is pending and mapped to this evidence-only journey in `specs/CONFORMANCE.json`;
- selector preflight confirms each requirement's mapped implementation/test fragments still match `--source-sha`;
- the workflow is manually dispatched from current `origin/main`;
- redaction, no-secret, and no-overclaim checks pass.

## Required Steps

The signed result MUST contain exactly these passing physical steps, in this order:

1. `step-01-capture-pool-context`
2. `step-02-successful-pooled-request`
3. `step-03-fail-closed-unsatisfied-pool`
4. `step-04-settlement-and-logs`
5. `step-05-redaction`

Each step MUST reference the single artifact id:

```text
redacted-trusted-pool-layer2
```

## Required Observations

The redacted evidence and signed result MUST set these booleans to `true`:

- `isolated_environment`
- `raw_prompt_output_redacted`
- `successful_pooled_request`
- `pool_required_fail_closed`
- `pool_id_bound_to_route_snapshot`
- `pool_selection_authorized`
- `tenant_isolation_fail_closed_after_generation_bump`

They MUST set these booleans to `false`:

- `production_side_effects`
- `global_fallback_observed`
- `unauthorized_pool_oracle_observed`
- `coordinator_plaintext_privacy_claimed`
- `provider_operator_blindness_claimed`
- `payout_ready_mutated`

## Required Candidate Identity

The redacted evidence and signed result MUST include `candidate_identity` with:

- `pool_id`
- `manifest_version`
- `pool_generation`
- `manifest_core_digest`
- `route_snapshot_digest`
- `gateway_config_sha256`
- `coordinator_config_sha256`
- `provider_identity_fingerprint`
- `buyer_credential_fingerprint`

All digest/fingerprint fields MUST be 64-character lowercase hex strings. Stable operator, buyer, and provider identities MUST be represented only as redacted fingerprints.

## Evidence Workflow

Protected manual workflow:

```text
.github/workflows/build-signed-trusted-pool-layer2-journey.yml
```

Builder:

```text
scripts/build-trusted-pool-layer2-journey-result.py
```

Validator:

```text
scripts/check_spec_governance.py
```

Workflow contract test:

```text
scripts/test-signed-trusted-pool-layer2-journey-workflow.sh
```

Local redacted-evidence harness:

```text
phase4-coordinator/internal/buyer/spec042_trusted_pool_layer2_journey_test.go:TestJourneyTrustedPoolLayer2MVPCandidate
```

To capture a candidate redacted artifact from a clean worktree:

```sh
MACPROVIDER_CAPTURE_TRUSTED_POOL_LAYER2=1 go test ./internal/buyer -run TestJourneyTrustedPoolLayer2MVPCandidate -count=1
```

The local harness drives the real buyer HTTP handler with gateway-authenticated pool selection, an admitted `trusted_pool_v1` member, route-snapshot pool label binding, fail-closed no-member behavior after a generation bump, redaction checks, and zero payout-ready mutation before any payout job. The captured `expires_at` value is date-only (`YYYY-MM-DD`) to match the protected signer contract. It is a local artifact-generation harness only; the artifact still must be reviewed, committed, signed, and validated before it becomes governance evidence.

This workflow exports a short-lived artifact containing only the redacted evidence, the signed journey-result envelope, and an evidence manifest. It does not push, open PRs, merge, publish releases, print signing material, mutate `specs/CONFORMANCE.json`, or promote any requirement to conformant. The generic conformance promoter explicitly rejects `JOURNEY-TRUSTED-POOL-LAYER2-MVP` as evidence-only.
