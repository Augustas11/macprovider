# Build 1 preparation runtime slice 6B — independent review record

Date: 2026-09-12

## Reviewed bytes

- Repository base: `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`
- Runtime commit: `9e72f1fdb6efefbfcd38e175e13444a6f88b17d8`
- Runtime PR: https://github.com/Augustas11/macprovider/pull/1491
- Files:
  - `phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift`
  - `phase3-binary/Tests/macprovider-cliTests/ModelPreparationPrivateCodecTests.swift`

## Gate result

All reviewers used native GPT-5.6 Sol subagents and independently inspected the complete two-file diff.

| Lane | Critical | High | Medium | Result |
| --- | ---: | ---: | ---: | --- |
| Code | 0 | 0 | 0 | PASS |
| Security | 0 | 0 | 0 | PASS |
| Architecture/contracts | 0 | 0 | 0 | PASS |

The first review at `69d747fd` was reopened after independent storage mapping found that its temp record did not bind enough information to recover its durable target. Corrections through `fe9376d7` added payload/digest/target binding, but a subsequent storage-feasibility review found that renaming this envelope into `root.identity` would violate its exact closed raw schema. Secure-storage work paused while v18 and v19 plan reviews rejected stale exact-artifact gate references; the independently approved v20 plan/test resolved the representation and the gate wording. Commit `9e72f1fd` replaces the v17 temp schema with a five-kind byte-identical private-state temp/durable envelope while leaving raw root identity separate. All three lanes then independently reviewed the complete cumulative diff from `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f` through `9e72f1fd` and reported zero Critical, High, and Medium findings. `Package.resolved` was clean and absent from the diff.

## Material finding resolutions

- Public `ModelPreparationAction` remains the exact closed eight-field SPEC-044 v2 object. `event_model_key` is carried by enclosing cleanup and private lifecycle records.
- Cleanup targets and records recompute artifact identity from the authoritative model tuple, root identity digest, and verified receipt digest.
- `ModelPreparationPublicationReceipt` excludes `artifact_identity_digest`; its digest is computed over bounded canonical receipt bytes, eliminating the prior circular binding.
- Cleanup records verify receipt digest plus tuple, root, and event correlations before deriving artifact identity.
- Closed JSON shapes, duplicate-key rejection, canonical numeric spelling, size limits, exact root identity version, safe integer caps, and relative-leaf validation fail closed.
- V20 private-state envelopes bind one of five durable record kinds, exact target leaf, writer UUIDv4, generation, complete payload, and payload SHA-256. The same encoded bytes can be a UUID-named temp or durable target; only the temp requires filename UUID agreement. Decode rejects noncanonical base64 and the old v17 schema.
- Raw `root.identity` is excluded from the envelope kind inventory. Per-target inner limits include the exact 4,096-byte cancellation boundary; the 360,000-byte outer cap contains the largest permitted 262,144-byte payload after base64 framing.

## Fresh validation

- `swift test --disable-automatic-resolution --filter ModelPreparationPrivateCodecTests`
  - Result: PASS; 23 XCTest tests, 0 failures.
  - The separate Swift Testing runner selected 0 tests and is not counted.
- `git diff --check c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f..9e72f1fd`
  - Result: PASS.

## Broader validation limits

No broader run is claimed green.

- Unfiltered locked `swift test` was interrupted after an existing `CandidateProviderRunnerTests` cleanup hung in `Process.waitUntilExit()` after the child process had disappeared.
- Excluding that suite reached `StageForwardParityTests` and exited because the machine could not load the default MLX Metal library.
- Excluding both unrelated blockers executed 2,799 XCTest tests with 26 skipped and 30 failures. Failures were in existing coordinator compatibility-policy, doctor-output, and legacy-hello tests; none referenced either new slice file.

These failures remain repository/baseline evidence to reconcile. They are not reported as passing acceptance evidence and do not replace the focused test proof for this bounded contract slice.
