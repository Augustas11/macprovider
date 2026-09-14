# Build 1 qualification blockers

Fresh read-only public endpoint preflight is preserved in public-feed-preflight.json. The configured CLI artifact-feed endpoint `/v1/catalog-artifacts` and detached signature both returned HTTP 404. Candidate feed and signature returned HTTP 200, which is availability evidence only, not fresh cryptographic validation. The baked artifact feed is absent by design. Thus the supported authenticated self-service preparation journey cannot currently obtain its required live artifact authority from the public coordinator. Publishing or deploying that feed is outside this task authority. Do not manufacture operator authority with fixture keys.

The repository contains public operator-curated candidate/artifact source metadata and a signed Tier2 catalog; these alone do not establish the live artifact-feed chain or independently justified actual-model compute references. Local cached model names alone do not establish complete trusted bytes. B1-T10 remains unproven. Test-generated signed fixture feeds and deterministic inference prove local integration only.

Available hardware is Apple M5 with 32 GiB RAM, macOS 26.5. Xcode 26.6 app tests can run; release-required Xcode 16.4 is absent. No signing/notarization/updater/release qualification or production deployment is performed.

This blocker does not waive physical acceptance and does not prevent completion of independently executable implementation, local testing and review, or subsequent per-build work after an honest acceptance handoff.

## Current CLI omits shipped artifact authority

`phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift:24` sets
`bakedArtifactFeedBase64` to nil. `AutotuneStaticInputs.loadRecommendationInputs`
uses that default in `loadArtifactFeed`, whose nil guard returns an absent
selection before any live artifact fetch. This existing rule-6 compatibility
behavior means even a reachable signed live artifact feed cannot activate
preparation authority in the current generated build. A live-feed 404 is not the
only blocker. No generated catalog authority was changed in the integration lane.

The implemented command fixture loader input, approved in
`command-composition-testability-addendum-r3.md` exercises real validation
with explicit test-owned baked bytes and disposable signer provenance. It cannot
establish shipping default trust, replace a publication/qualification gate, or
close B1-T10 physical acceptance. Production artifact authority remains unproven. The Swift25 parsed fixture journey passed with test-owned signed inputs and fixture inference; it does not satisfy physical acceptance.

## Signed snapshot integration

Fresh read-only `security find-identity -v -p codesigning` returned exit0 and `0 valid identities found`. No matching production-signed new CLI snapshot has been produced or exercised. App/CLI unsigned or injected-signature subprocess tests do not establish production code identity or MLX resource resolution from the snapshot. No signing identity, operator key or credential was created, changed or exported. Local implementation/tests continue; signed snapshot positive evidence requires an external signing prerequisite and remains unproven.

## Snapshot resource correction locally verified

The former binary-only snapshot omitted adjacent MLX resources. The approved correction now copies and validates the required resource layout; its full app Xcode suite passed641tests, including16 resource cases, and preliminary independent app security review has zero C/H/M/L. `CandidateProviderRunner.defaultProviderBinaryPath` uses the snapshot executable; candidate mode bypasses canonical re-exec. Snapshot-resources-r2 passed independent plan review before implementation. Actual pinned MLX GPU arithmetic passed through the app resource-copy path; this establishes resource loading for that helper, not a production-signed CLI or real model. The final combined implementation audits remain pending. No copied-snapshot real-model inference claim is supported until the implementation and qualification evidence are both resolved.

## Concurrent unmerged compatibility work

Active branch `feat/byom-v02-slice3-gguf-settlement-identity` at `1d82e1b181dfb91516106994750705d8883b6b5f` (base914f7caf, dirty worktree) develops GGUF/non-primary artifact identity and settlement. Its inspected runbook describes artifact-set mapping and operator feed activation prerequisites. It is not landed or incorporated in this Build1 branch. Overlapping BYOM/coordinator/SPEC paths need fresh reconciliation if it lands first; this implementation does not claim support from that other branch.
