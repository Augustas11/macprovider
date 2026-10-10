## Round-1 findings

1. **FIXED — Agreement renewal pauses routing pools after grace.** Renewal now uses `RoutingInvalidReason`, preserving pools that remain authorized to route. The operator reactivation guard uses the same predicate. See [creator_selfserve.go:546](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/creator_selfserve.go:546), [durable_store.go:1064](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/durable_store.go:1064), and [SPEC-043:91](/Users/augstar/macprovider-no-expiry/specs/SPEC-043-trusted-pool-creator-onboarding.md:91).

2. **FIXED — Native-MTP journey evidence retains calendar rejection.** Consumption preserves structural checks and removes wall-clock rejection. The existing aged-evidence and governance round-trip tests passed. See [native_mtp_journey_evidence.py:483](/Users/augstar/macprovider-no-expiry/scripts/native_mtp_journey_evidence.py:483).

3. **FIXED — Discovery retirement removes older-client recovery.** The protected workflow and ops entrypoint remain available on demand, without a schedule. Existing renewal workflow, sequence-ceiling, and same-target resolver checks passed. See [renew-release-discovery-head.yml:3](/Users/augstar/macprovider-no-expiry/.github/workflows/renew-release-discovery-head.yml:3) and [discovery-renew.sh:12](/Users/augstar/macprovider-no-expiry/scripts/ops/discovery-renew.sh:12).

4. **FIXED — SPEC-049 overstates withdrawal by entry removal.** The normative wording now distinguishes configuration-only approval from release-derived approval and documents the overriding withdrawal mechanisms. See [SPEC-049:423](/Users/augstar/macprovider-no-expiry/specs/SPEC-049-operator-constrained-privacy-class.md:423) and [privacy_authority.go:792](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/relayblind/privacy_authority.go:792).

## Summary

**Architecture gate: PASS.** No new CRITICAL, HIGH, MEDIUM, or LOW architecture findings identified in the complete ten-commit diff and related source.

## Analysis

The reviewed paths consistently separate structural timestamp validation from calendar-driven inactivation:

- Tier-2 retains timestamp ordering while keeping the loaded catalog active: [catalog.go:732](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/tier2/catalog.go:732), [catalog.go:779](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/tier2/catalog.go:779).
- Evidence supersession uses coordinator-assigned job order: [evidence_pg.go:98](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/autotune/evidence_pg.go:98).
- Revocation fallback preserves verified cached state while excluding store and anchor-integrity failures from network fallback: [NativeMTPRevocationFeed.swift:396](/Users/augstar/macprovider-no-expiry/phase3-binary/Sources/macprovider-cli/NativeMTPRevocationFeed.swift:396).
- Trusted-pool routing deadlines derive from manifest policy rather than Agreement or on-call dates: [durable_store.go:3975](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/durable_store.go:3975).

## Root Cause

The round-1 gaps were secondary lifecycle and compatibility paths retaining the former expiry contract. The follow-up reconciles those paths; no additional architectural root cause was identified.

## Recommendations

No additional architecture fix is required for this gate. Live deployment order and fleet state remain unverified under the required no-network boundary.

## Trade-offs

| Decision | Benefit | Retained cost |
|---|---|---|
| On-demand discovery renewal | Preserves older-client recovery | Operator dispatch remains necessary for older clients |
| Last-known revocation enforcement | Avoids calendar-driven native-MTP shutdown | Anchorless bootstrap residual remains documented |

## References and validation

Passed existing checks:

- Three targeted Python tests covering aged evidence, governance round trip, and approval precedence.
- Two targeted receipt catalog/verifier tests.
- Discovery renewal workflow, base/ceiling selector, and target resolver tests.

Coordinator tests were not run: installed Go is 1.26.4; the module requires 1.26.6. Swift and hardware execution were not run. No source files edited, custom inputs constructed, or network hosts contacted.

C/H/M/L = 0/0/0/0
