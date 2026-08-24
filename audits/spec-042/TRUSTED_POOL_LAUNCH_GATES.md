# SPEC-042 Trusted Pool Launch Gates

TL;DR: The remaining #1053 work is three top-level gates, not an open-ended backlog: signed journey evidence, conformance/spec reconciliation, and final launch audit.
TL;DR: The new local harness proves the narrow Layer 2 request path can produce redacted evidence, but it does not make Trusted Pools production-live or cryptographically private.

## Scope

This file is the launch gate ledger for SPEC-042 Trusted Pools. It applies to the Layer 2 administrative-trust product only: creator-operated pools over MacProvider routing and settlement rails. It does not authorize Privacy Pool, coordinator-blind content, anonymous routing, zero-knowledge membership, regulated-vertical compliance, or provider-operator-blind claims.

The current executable local proof is:

- `phase4-coordinator/internal/buyer/spec042_trusted_pool_layer2_journey_test.go:TestJourneyTrustedPoolLayer2MVPCandidate`
- `journeys/JOURNEY-TRUSTED-POOL-LAYER2-MVP.md`
- `.github/workflows/build-signed-trusted-pool-layer2-journey.yml`
- `scripts/build-trusted-pool-layer2-journey-result.py`
- `scripts/test-signed-trusted-pool-layer2-journey-workflow.sh`

## Gate Ledger

| Gate | Status | What Exists | Stop Condition |
|---|---|---|---|
| 1. Evidence / journey proof | Partial | Local harness exercises gateway-authenticated pool selection, admitted `trusted_pool_v1` member routing, route-snapshot pool label binding, fail-closed no-member behavior after generation bump, redaction checks, and no payout-ready mutation before any payout job. | A reviewed redacted artifact under `journeys/evidence/trusted-pool-layer2-*.redacted.json` is produced from a clean commit, signed by the protected workflow, validated by governance, and accepted as evidence-only for R002/R005/R006/R010. |
| 2. SPEC-042 promotion / conformance reconciliation | Partial | CONFORMANCE points R002/R005/R006/R010 at the local harness and the non-promoting journey, while all rows remain `pending`. SPEC-042 v0.0.29 explicitly records the local harness and states the unresolved carries. | Human decision records which SPEC-043 promise/retention surfaces are accepted or superseded by SPEC-042, production evidence is attached, and only requirement rows with all deferred subclauses closed are promoted. |
| 3. Final launch audit gating | Partial | This file defines the launch gate ledger. Repo rules require code/security/architecture audit lanes over the full fix diff at 0 Critical / 0 High / 0 Medium before treating an implementation slice as done. | Full launch diff, signed evidence artifact, production activation evidence, rollout/rollback proof, and conformance changes pass code/security/architecture plus adversarial/product review at 0 C/H/M. |

## Explicit Non-Launch Conditions

Trusted Pools must not be advertised or enabled as production-live while any of these remain true:

- `specs/CONFORMANCE.json` keeps SPEC-042 production status as `not-deployed`.
- `JOURNEY-TRUSTED-POOL-LAYER2-MVP` has no signed journey-result artifact.
- The only new route-path harness evidence is local: it proves `pool_id` route-snapshot labeling and canonical digest persistence, not production route-recorded `manifest_version` / `manifest_core_digest` labels.
- Production activation evidence lacks the signed-launch digest and matching root-custody disclosure hash required by `trusted_pools.production_activation`.
- SPEC-042 has not accepted or superseded the SPEC-043-owned closed schema, retention-policy, policy/status, and public-announcement surfaces.
- Remaining production predicate evidence is local-only or unit-only.
- The final launch audit has not reached 0 Critical / 0 High / 0 Medium.

## Next Slice

The next non-code launch step is to generate the redacted evidence artifact from a clean commit by running:

```sh
MACPROVIDER_CAPTURE_TRUSTED_POOL_LAYER2=1 go test ./internal/buyer -run TestJourneyTrustedPoolLayer2MVPCandidate -count=1
```

from `phase4-coordinator`, then commit the redacted artifact and run the protected signer workflow. That artifact remains evidence-only and must not be used to promote whole SPEC-042 rows unless the deferred subclauses are closed separately.
