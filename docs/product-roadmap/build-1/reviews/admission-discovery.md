# Build 1 admission discovery

Date: 2026-09-10. Inspected base: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`.

This is bounded discovery evidence and implementation guidance, **not a gate
approval or proof of a completed production journey**. Discovery was read-only;
this report is the only file subsequently written by this lane. No operator
secrets or excluded third-party source were accessed.

## Result

The coordinator has signed offers, durable admission states, live provider-wire
probes, and settlement safeguards. It does not yet automatically promote a
probed candidate into catalog-priced and settlement-capable states. The complete
self-service path from prepared primary artifact to a correctly priced settled
request remains unproven.

## Landed evidence

- `phase4-coordinator/internal/ws/model_admission.go`: signed offer verification,
  append-only memory/SQLite stores, replay protection, withdrawals, sanctions,
  and state-machine validation.
- `phase4-coordinator/internal/ws/server.go:4215`,
  `maybeRunModelAdmissionSyntheticProbeForOffer`, and `:4249`,
  `runModelAdmissionSyntheticProbe`: bounded synthetic inference through the live
  provider WebSocket. Success reaches only `network_admitted_unsettled`;
  coordinator-side dereference of provider endpoint descriptors is absent.
- `phase4-coordinator/internal/buyer/model_admission.go`: non-settlement states
  remain excluded from default paid routing. `route_snapshot_test.go:751,832`
  covers catalog-priced and other non-settlement states.
- `buyer/model_admission.go:156`, `buyer/route_snapshot.go:24`, and
  `billing/route_snapshot.go`: settlement-capable admission evidence is bound into
  the immutable route snapshot.
- `ws/model_identity_test.go:16,108`: exact signed candidate-row hash authority,
  including compatible-previous release admission and heartbeats. Tier2 must
  agree with the admitted hash; it cannot override it.
- `buyer/catalog_artifacts_feed.go` and `buyer/autotune_feeds.go`: artifact-feed
  verification, release/signer binding, closed identity matrix, and consistency
  with the candidate primary hash. These serve verified bytes but do not yet
  provide admission promotion authority.
- `billing/settlement_verifier_test.go` and
  `test/integration/scenarios_test.go:173,231`: receipt verification, output and
  ledger binding, negative quarantine, and cross-service settlement coverage.

All shortened package paths above are under `phase4-coordinator/internal/`.

## Missing or partial

1. No production promotion to `catalog_priced` or `settlement_capable` was found.
   Callers of `AppendModelAdmissionDecision` that create those states are test
   fixtures; production callers perform synthetic probing and runtime revocation.
2. `billing.RouteSnapshot` lacks SPEC-047-R003's six fields for artifact-derived
   settlement evidence. Its existing `CatalogBodyDigest` is the **Tier2 catalog
   body**, not the candidate-catalog digest; these must remain distinct.
3. Signed rates and effective billing configuration are separate authorities.
   `/v1/rate-card` serves signed feed bytes when configured. Actual billing uses
   `billingCfg`, persisted billing configuration snapshots, and `billing.RateFor`.
   `scripts/catalog-release.py:1096`, `check_rate_card_parity`, checks release
   parity, but admission needs a runtime check before claiming correct economics.
4. An offer submitted without a live WS session stays submitted. Exact replay
   returns the prior event without rerunning the probe, so a bounded later-session
   reconciliation/retry path is needed.
5. Separate unit/integration portions do not establish preparation -> real
   runtime admission -> signed receipt -> correctly priced settled ledger success.

## Safe remaining implementation

Confirm normative ownership in SPEC-010-R001/R004, SPEC-023 section 3.7,
SPEC-047-R003/R004/R006/R008, and SPEC-022 before implementation. Preparation and
provider-signed assertions remain local evidence, never authority to price,
admit, or settle. Probe output and provider signatures do not prove computation.

Resolve the active provider's exact canonical snapshot-manifest hash against
coordinator-verified candidate and artifact feeds. Require unique model-key
resolution, the verified primary artifact, allowed `mlx_cache` runtime, and the
matching pinned revision. Reject a conflicting provider-offered catalog key.

Give admission a narrow trusted authority snapshot containing the selected
candidate release, artifact metadata/authenticated signer, signed rate row, and
effective billing snapshot. Resolve this from verified loaders rather than
provider JSON. After the bounded wire probe, independently reread the active
session and authority before promotion. Require unchanged served identity,
session/hash/runtime, sanctions clear, valid receipt key, enforce settlement,
active Tier2 material agreeing with the admitted candidate hash, and signed vs
effective price parity.

Extend admission binding and immutable route snapshots with all six artifact
values: `artifact_feed_sha256`, `artifact_id`, artifact `hash`, artifact
`hash_algorithm`, `artifact_feed_signer_key_id`, and a separate
`candidate_catalog_sha256`. Include these in canonical digest, validation,
persistence/readback, receipt-bound snapshot, and settlement verification.
Use an all-or-none optional extension to preserve old snapshot compatibility;
artifact-derived admission must require the full extension.

Make promotions durable coordinator decisions with stable idempotency. Stale
probe results must not overwrite withdrawal/revocation. Reconcile pending offers
when a matching WS session becomes ready or through a bounded explicit retry.

Recheck authority at routing and capture immutable evidence. At settlement,
verify captured evidence and its digest; never repair missing values using a
current feed, release, or keyring. Use the resolved authoritative model key for
pricing. Reject unknown/default fallback pricing on the new admission path and
check prompt/cache/completion rates, provider share, and multiplier against the
effective billing snapshot used by ledger computation.

## Meaningful additional tests

Use ephemeral test Ed25519 keys and existing signing helpers; these tests do not
require operator secrets.

- Complete signed offer -> test WS probe -> coordinator promotion -> paid
  request -> receipt verification -> exact expected buyer/provider/operator
  ledger credits, with nondefault rates and explicit arithmetic assertions.
- Every intermediate state has no default paid route or positive ledger credit.
- Primary success; secondary MLX, GGUF, declared/blocked artifacts, wrong
  runtime, unknown hash, and mismatched offered key fail closed.
- Six-field snapshot persistence and digest coverage; missing/partial/mutated,
  cross-release, and wrong-signer cases reject even when the model hash is the
  same or another signer is concurrently trusted.
- Changing current feeds after dispatch cannot repair or rewrite evidence.
- Signed/effective rate divergence, share/multiplier changes, and unknown/default
  rates reject promotion/routing.
- Probe completion after withdrawal, reconnect with changed hash/session, stale
  evaluation, expired catalog, absent receipt key, observe-only settlement, and
  sanctions do not admit the candidate.
- Offer without WS safely progresses after the matching session appears; retries
  append no duplicate decisions.
- Existing ordinary non-BYOM snapshot compatibility remains intact.

## Fresh verification

Executed from `phase4-coordinator` in the Build 1 worktree:

```sh
go test ./internal/ws ./internal/buyer -run 'TestCanonicalModelIdentityUsesSignedAutotuneRowWithoutTier2Fallback|TestCompatiblePreviousAdmissionKeepsExactSelectedRowIdentity|TestModelAdmissionSyntheticProbeWorkflowKeepsNonSettlementBoundaryAcrossStores|TestBYOMNonSettlementStatesAreHiddenFromDefaultPaidModelsAndRouting|TestBYOMSettlementCapableBindsAdmissionEventIntoRouteSnapshot|TestBYOMCatalogKeyMismatchFailsClosed' -count=1
```

Completed with exit code 0:

```text
ok  github.com/augstar/macprovider-coordinator/internal/ws     1.150s
ok  github.com/augstar/macprovider-coordinator/internal/buyer  0.767s
```

These tests validate existing boundaries and fixture-backed binding; they do
not validate the missing automatic promotion or a real hardware journey. They
were not rerun solely to persist this report.

## Hardware and production prerequisites

- Actual supported Apple Silicon runtime, sufficient memory/disk, exact pinned
  primary artifact, live WS admission, and receipt-capable CLI. The smallest
  committed candidate inspected is Llama 3.2 3B with catalog minimum RAM 4 GB;
  that threshold does not prove any present host can complete the journey.
- Active, unexpired signed Tier2 catalog covering the exact candidate hash,
  required by `tier2.SnapshotMaterial` and current route snapshots.
- Where compute-integrity enforcement applies, production reference coverage and
  approved calibration remain required: `computeintegrity/threshold.go:157`,
  `ValidateCalibrationForEnforce`, and state `blocked:calibration_missing`.
  Test fixtures do not establish production calibration or hardware evidence.
- Coherent signed candidate/artifact/rate release, matching effective billing
  configuration, enforce settlement, and SPEC-047-R008 signed production journey.
  Do not weaken Tier2, fabricate calibration, or infer verified computation from
  a provider signature to make the acceptance case pass.
