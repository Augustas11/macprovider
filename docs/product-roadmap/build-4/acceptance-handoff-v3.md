# Product Build 4 planning acceptance and handoff v3

Assessment date: 2026-09-11  
Branch: `codex/product-build-4`  
Inspected base: `1d2c930bad81704dd0acc0322226725d8b64aceb`  
Historical roadmap baseline: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`  
Scope delivered: planning, contract assessment, test specification, and independent plan gate only

## Disposition

The Product Build 4 planning gate passed on revision v3 with an independent GPT-5.6 Sol verdict of 0 Critical, 0 High, 0 Medium, 0 Low, and 2 Informational findings.

The implementation gate remains closed. No normative SPEC amendment or runtime source change is authorized from this branch until:

1. Product Build 2's accepted provider-identity reservation and supported-client contracts land;
2. Product Build 3's accepted production observation scope, stable provider identity/Sybil-resistance authority, reference/calibration evidence, and economics mapping land;
3. their exact fields replace the provisional dependency fields in plan sections 6.2-6.8; and
4. the revised exact plan and test specification pass a fresh independent gate with zero Critical, High, and Medium findings.

No pool-scoped relay-blind guard, relay-blind-plus-enforce restriction, positive-verification exclusion, or rewards exclusion was removed or weakened.

## Current outcome classification

| Outcome | Current state | Evidence boundary |
|---|---|---|
| Plaintext Trusted Pool authorization, membership, predicates, and generation fencing | Partial/landed | Current coordinator code and focused tests; not production-qualified |
| Global relay-blind reservation, opaque dispatch, replay defense, cancellation/recovery | Partial/landed | Current SPEC-041 implementation; pool intent remains deliberately rejected |
| Pool-scoped relay-blind admission | Deliberately blocked | Gateway/coordinator reject before quota; preserve until successor contract implementation |
| Relay-blind verified-settlement enforce composition | Deliberately blocked | Current config rejects the composition |
| Relay-blind positive verification/reward attribution | Deliberately excluded | Current billing/reward flags remain authoritative |
| Successor private-pool receipt/digest/key contract | Planned and plan-gated only | v3 plan/test; no runtime or SPEC authority landed |
| Pool-scoped lifecycle rechecks and encrypted dispatch binding | Planned and plan-gated only | v3 defines owner-specific gateway/coordinator cutoffs; no runtime implementation |
| Independently supported private verified settlement | Dependency-blocked | Requires accepted Build 3 observation/stable-identity/economics contract |
| Physical MLX private-pool settled request | Unverified/blocker | Requires implementation plus at least one supported physical Mac journey and protected evidence |
| Trusted Pool production qualification/activation | Out of scope | Local planning or integration cannot qualify production |

## Independent review history

| Revision | Plan SHA-256 | Test-spec SHA-256 | Review SHA-256 | Result |
|---|---|---|---|---|
| v1 | `88f28f3955e937834993f557de0589f0f332865b38f60db06c90276c2e69b15d` | `ca2bd4ee731b5a0129692c337891e0a651a1ec53c82452967980b1fdce268739` | `47ab964929d5ee2fe66739de4bdd191ef7ea265ef7ca4bff7d3ae915ae3bbcbc` | FAIL: C0/H3/M5/L2/I2 |
| v2 | `ca2508bd6a75df8b07620bccb159f1c5dea128c50f9f94cb7b127e301260c050` | `dfd151990058d9e4941269763758a30839cd64d1124391d131bcf781c3e142c3` | `ab003a6d55b069a7b49764a1654818d76fbaeea173ae1af0f39dcc87e5a0d2b7` | FAIL: C0/H2/M2/L0/I0 |
| v3 | `3329ea2d547338a68d8049fde4613fb7c37860aa40fb99b0c21b8c3eb67880eb` | `b3c8485b035366aef24a5f540ff5f668079271fbd70bb82beba870b7958c4469` | `7264d1136e3d70cf9dcd72ada04c34e6e1a3b55a8ad7ecf79820f71cec64e4f3` | PASS: C0/H0/M0/L0/I2 |

The v3 review confirmed closure of the receipt-key archive and emergency-revocation contract, cross-service dispatch cutoffs/recovery, exhaustive mixed-version monotonicity, pool-bound field-level retention, observation trust outcomes, observation capture origin, migrations/rollback, and protected evidence.

## Fresh local evidence

The following commands ran successfully on the inspected base and selected the named tests:

```text
cd phase4-coordinator && go test ./internal/billing -run 'TestRouteSnapshotPoolID_(DigestBinding|RoundTripsThroughSettlementLoader)$' -count=1
ok github.com/augstar/macprovider-coordinator/internal/billing 0.724s

cd phase4-coordinator && go test ./internal/buyer -run 'TestPoolIsolation_(RevokedMemberRejectedImmediately|LoopFenceRejectsStaleBeforeDispatch|ActiveDispatchContextCancelledOnImmediateRevoke)$|TestRelayBlindErrorCarriesCompletePrivacyMetadata$' -count=1
ok github.com/augstar/macprovider-coordinator/internal/buyer 0.727s

cd phase5-gateway && go test ./internal/router -run 'TestPoolSelection_(AuthorizedAndCapable_EmitsHeader|Unauthorized_FailsClosedWithoutCapabilityFetch|OldCoordinatorNoAdvertisement_FailsClosed|WalletSessionCannotSelectPool)$|TestRelayBlindProbePreservesDefaultOffPlaintextCompatibility$' -count=1
ok github.com/augstar/macprovider-gateway/internal/router 1.105s

cd test/integration && go test -run '^TestRelayBlindReservationRejectsPoolSelectionBeforeQuota$' -count=1
PASS
ok github.com/augstar/macprovider-integration 10.243s
```

These runs prove current deliberate restrictions and selected plaintext/pool protections. They do not prove any planned successor contract, private-pool dispatch, verified settlement, actual MLX inference, deployed behavior, production qualification, rewards, or payouts.

## Reviewable now

- Normative owners and dependency graph.
- Provisional successor protocol/version separation and compatibility rules.
- Receipt-key authority/archive and deterministic settlement finality.
- Owner-specific gateway authorization and coordinator dispatch cutoffs.
- Coordinator-owned observation capture/audit linkage.
- Migration, rollback, exhaustive compatibility, retention, observability, and protected-evidence contracts.
- The complete negative and acceptance test design.

## Qualification blockers

- Accepted Build 2 exact identity-set/pin/client/API contract is not incorporated.
- Accepted Build 3 production observation, stable-identity/Sybil-resistance, reference/calibration, and economics contract is not incorporated.
- The SPEC-041/SPEC-042 privacy-wording conflict requires a normative amendment.
- Successor SPEC-015/SPEC-022 receipt, key, outcome, and compatibility authority has not landed.
- No Build 4 runtime implementation exists on this branch.
- No local multi-service successor integration or actual MLX joined request has run.
- No protected physical-hardware evidence, deployed-service evidence, or Trusted Pool production qualification exists.

The next Build 4 session should rebase or explicitly stack on the accepted Build 2 and Build 3 revisions, record those exact bases, replace provisional fields, and reopen the plan gate before any Phase A or source work.
