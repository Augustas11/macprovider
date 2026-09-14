# Build 1 test specification r5 — c944 identity compatibility

Status: proposed companion to
`origin-main-c944-reconciliation-addendum-r1.md`. No conflicted source may be
resolved until independent GPT-5.6 Sol review approves both artifacts with zero
Critical, High, and Medium findings.

## Claims and evidence classes

This specification proves local compatibility of Build 1 with merged PR #1469.
It distinguishes deterministic fixtures, real coordinator/gateway services,
actual MLX inference, release-signed artifacts, and production evidence. A test
may satisfy only its recorded evidence class. Zero selected, skipped, timed-out,
interrupted, or historical runs do not pass a criterion.

## Matrix

### C944-01 — exact member authority

- Positive: resolve an exact canonical algorithm/hash pair for a verified and
  recommendable feed member; retain the artifact ID and exact feed provenance.
- Positive: direct row-bound primary snapshot-manifest identity remains valid
  without a six-value extension.
- Negative: duplicate pair, unnamed algorithm, listed-only member, wrong model,
  wrong release, stale feed, wrong signer, missing material, partial provenance,
  or mismatched candidate row fails closed.
- Evidence: upstream artifactidentity, buyer index, WS identity, pool pinning,
  PoW drift, and new Build 1 two-arm authority tests.

### C944-02 — distinct identity domains

- Use different values for member hash, candidate row hash, model ID, artifact
  ID, and economics model key.
- Assert Tier2 and rate resolution use the row/model-key values while the wire,
  receipt, and settlement use the member pair.
- Substituting any one domain with another is rejected before paid routing.

### C944-03 — immutable provider snapshot

- Mutate or replace the pool's `ArtifactIdentity`, nested provenance/member, and
  `IdentityPin` after preparation.
- Assert the prepared snapshot does not change through pointer aliasing and the
  commit guard rejects every replacement.
- Repeat for same visible model/hash with changed feed provenance or member pin.
- Run under `-race`.

### C944-04 — composite generation publication

- Publish old feed/index generation G, prepare an admission, then stage G+1.
- Exercise old-feed/new-index, new-feed/old-index, catalog-clear, failed rebuild,
  and successful atomic swap interleavings.
- Assert no mixed generation becomes settlement capable, a cleared interval is
  non-paid, old prepared authority cannot commit after the swap, and G+1 can
  succeed only with its exact member/provenance.
- Assert lock-order probes complete without deadlock or leaked pins.

### C944-05 — snapshot key compatibility

- Canonical fixture: `candidate_catalog_sha256` participates in the exact
  authenticated snapshot digest and round-trips without mutation.
- Historical c944 fixture: `artifact_candidate_catalog_sha256` verifies its
  original digest and normalizes only in memory.
- Reject both spellings, missing sixth field, partial six-value evidence,
  changed value, unknown schema, reconstructed current-feed value, or a decode/
  remarshal digest in place of original-byte verification.
- Restart SQLite and prove historical bytes/digest remain unchanged.

### C944-06 — event and receipt compatibility

- Read legacy admission events without inventing artifact authority.
- Preserve c944 and Build 1 coordinator event IDs, idempotency/replay keys, CAS
  heads, all-or-none evidence, receipt fields, and exactly-once settlement.
- Delayed/replayed receipts and changed/missing artifact evidence are rejected
  without altering prior settled truth.

### C944-07 — retry-time GGUF validation

- Compute GGUF identity from an opened descriptor and submit an offer.
- Before retry, change bytes in place, replace the inode, replace a pathname,
  exceed the digest deadline, or remove the file.
- Assert every case fails before signature/event reuse and does not retain paid
  admission. Unchanged bytes and identity may retry through the existing CAS
  path.

### C944-08 — preparation UX boundary

- The Build 1 provider preparation command truthfully rejects a non-primary
  artifact as unsupported for that command.
- The coordinator separately accepts a verified feed-derived GGUF member for
  network identity and settlement when every authority predicate is satisfied.
- Neither preparation success nor provider assertion grants identity, price,
  or settlement authority.

### C944-09 — route and settlement journey

- Through actual coordinator and gateway processes plus SQLite, route a
  feed-derived member whose member hash differs from its row hash and whose
  model key differs from its artifact ID.
- Persist the route snapshot, signed receipt, exact rate, token counts, gross,
  provider amount, and restart/replay truth.
- Reject listed-only, revoked, stale generation, changed pin, wrong rate/model,
  incomplete evidence, and digest substitution.
- This is real-service fixture evidence, not MLX inference or production proof.

### C944-10 — durable discovery bridge

- Preserve upstream GGUF computed-digest cache semantics and invalidate on
  device/inode/size/content change.
- Preserve Build 1 HF/durable discovery, deduplication, no-follow containment,
  corrupt-artifact recovery, cancellation, and active-model preservation.
- Replay the executable app arguments through the actual CLI parser after the
  final reconciled source is built.

### C944-11 — acceptance remap

- B1-T01/T02/T07/T08/T09/T10/T11/T12 must reference C944-01 through C944-10
  as mapped in the reconciliation addendum.
- B1-T03/T04/T05/T06/T13/T14 retain meaning and rerun when shared code or
  fixtures changed.
- B1-T10 records only the physical primary-MLX arm. GGUF/member qualification
  remains unproven unless separately run on representative hardware.

## Fresh command gates

Run targeted tests first:

```bash
cd phase3-binary && swift test --filter BYOMArtifactDigestTests
cd phase3-binary && swift test --filter BYOMAdmissionTests
cd phase4-coordinator && go test -race ./internal/artifactidentity ./internal/billing ./internal/buyer ./internal/pool ./internal/ws ./internal/pow
cd test/integration && go test -race -count=1 -run 'TestBuild1(ArtifactAdmissionSettlesThroughRealServices|PaidRouteRejectsClosingBeforeStatusRevocation|CLIServiceBridge)'
```

Run the catalog CC01-CC09 and lifecycle CR01-CR13 selectors, the approved
T06/T10/T11 race selections, settlement/restart tests, app capture/CLI replay,
and bootstrap tests recorded in `test-spec-r4.md`. Record selected, passed,
failed, skipped, duration, and log hash for every command.

Then run the broader surface gates:

```bash
cd phase3-binary && swift test
make test-coordinator
make test-gateway
make test-integration
make test-dist
make vet
make lint-coordinator
```

Run the generated Malibu Xcode tests separately; SwiftPM does not substitute
for them. Restore `phase3-binary/Package.resolved` exactly from c944 after the
last Swift command. Run SPEC governance and the final PR declaration validator
against current `origin/main` and the final PR body.

## Migration and rollback tests

- Start from canonical new, historical c944, legacy no-extension, corrupt,
  partial, both-key, and unknown-version SQLite fixtures.
- Reopen after process restart and verify byte/digest stability, authority
  classification, and no inferred upgrade.
- Abort reconciliation to the local pre-rebase checkpoint if a conflict cannot
  satisfy both c944 and Build 1 contracts. Tests may not rewrite fixtures to
  make an incompatible digest pass.

## Required final audits

Independent GPT-5.6 Sol code, security, and architecture reviewers inspect the
complete diff from the then-current `origin/main`. Each returns structured
severity, evidence, consequence, and required correction. The gate passes only
at zero Critical, High, and Medium findings across all lanes. Low/Info findings
remain recorded with explicit disposition.

## Qualification blockers

Local tests cannot prove release signing, production feed distribution, actual
model inference, physical computation, or deployed settlement. The physical
primary-MLX journey still requires an appropriate Mac, valid signed feed and
release, trusted model bytes, and live coordinator prerequisites. No GGUF/member
capacity or computation claim follows from deterministic fixtures.
