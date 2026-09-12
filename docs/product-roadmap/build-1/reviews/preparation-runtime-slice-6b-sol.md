# Build 1 preparation runtime slice 6B — independent review record

Date: 2026-09-12

## Reviewed bytes

- Repository base: `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`
- Runtime commit: `fe9376d726df963992f261fd212ec85f38508db4`
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

The first review at `69d747fd` was reopened after an independent storage-mapping pass found that the unique-temp record did not bind enough information to recover its durable target. The correction rounds added complete payload and digest binding, exact v17 durable target leaves, canonical base64 rejection, a constructible envelope cap, and the exact 4,096-byte cancellation cap. All three lanes then independently reviewed the complete cumulative diff from `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f` through `fe9376d7` and reported zero Critical, High, and Medium findings. `Package.resolved` was clean and absent from the diff.

## Material finding resolutions

- Public `ModelPreparationAction` remains the exact closed eight-field SPEC-044 v2 object. `event_model_key` is carried by enclosing cleanup and private lifecycle records.
- Cleanup targets and records recompute artifact identity from the authoritative model tuple, root identity digest, and verified receipt digest.
- `ModelPreparationPublicationReceipt` excludes `artifact_identity_digest`; its digest is computed over bounded canonical receipt bytes, eliminating the prior circular binding.
- Cleanup records verify receipt digest plus tuple, root, and event correlations before deriving artifact identity.
- Closed JSON shapes, duplicate-key rejection, canonical numeric spelling, size limits, exact root identity version, safe integer caps, and relative-leaf validation fail closed.
- Unique-temp v2 envelopes bind durable record kind, exact target leaf, writer UUIDv4, generation, complete payload, and payload SHA-256. Decode rejects noncanonical base64 and filename disagreement.
- Per-target payload limits match v17, including the exact 4,096-byte cancellation boundary. The 360,000-byte envelope cap can contain the largest permitted 262,144-byte payload after base64 framing.

## Fresh validation

- `swift test --disable-automatic-resolution --filter ModelPreparationPrivateCodecTests`
  - Result: PASS; 23 XCTest tests, 0 failures.
  - The separate Swift Testing runner selected 0 tests and is not counted.
- `git diff --check c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f..fe9376d7`
  - Result: PASS.

## Broader validation limits

No broader run is claimed green.

- Unfiltered locked `swift test` was interrupted after an existing `CandidateProviderRunnerTests` cleanup hung in `Process.waitUntilExit()` after the child process had disappeared.
- Excluding that suite reached `StageForwardParityTests` and exited because the machine could not load the default MLX Metal library.
- Excluding both unrelated blockers executed 2,799 XCTest tests with 26 skipped and 30 failures. Failures were in existing coordinator compatibility-policy, doctor-output, and legacy-hello tests; none referenced either new slice file.

These failures remain repository/baseline evidence to reconcile. They are not reported as passing acceptance evidence and do not replace the focused test proof for this bounded contract slice.
