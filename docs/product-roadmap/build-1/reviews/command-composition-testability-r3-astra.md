# Command composition testability r3 — independent Astra gate

**PASS — 0 Critical, 0 High, 0 Medium.** The two explicit baked-artifact initializer inputs are a viable narrowly scoped extension of the approved r2 context. This is a fixture testability approval, not default-production preparation qualification or closure of CODE-M2/B1-T11.

Exact reviewed addendum SHA-256: `5cd2f3d1daabcd14fa746a50587844a4938999307555bf576dea6490d019fdfe`, verified from disk. Base `914f7cafcdbcfc1805a10f4f34167218341d5587`.

## Code-grounded assessment

Current `AutotuneStaticInputs.loadRecommendationInputs` calls `loadArtifactFeed(candidate:)` with its static baked defaults. `AutotuneArtifactFeed.swift:623` returns an absent warning-free selection immediately when baked bytes are nil, before `loadSignedStatic` or its fetch callback. A fixture keyring/fetch closure alone therefore cannot enable preparation. The addendum accurately identifies a separate default-production blocker beyond the public endpoint 404.

Capturing defaulted optional baked bytes and signer on the loader instance and forwarding them into the existing loader is sufficient. It does not require moving or replacing validation. Explicit nil must be preserved as a real input, not coalesced back to another value. Production initializer defaults and `includeArtifactFeed: false` keep their current behavior. Direct existing `loadArtifactFeed` callers retain their current API/default semantics unless the caller explicitly supplies inputs.

The existing artifact loader validates baked schema before attempting fetch, uses the ordinary live sidecar verification/freshness policy, checks fallback freshness, and applies candidate/primary/release/signer qualification. A usable selection requires absence of integrity, update-required and stale classes. Fixture baked bytes enter the preexisting compiled-release input boundary; they do not represent a production manifest or prove their own signature. Live artifact bytes still require the actual Ed25519 sidecar verification with `verifySignature == nil`. No generated catalog/keyring edit, public flag, environment override, qualified selection injection or validator callback is authorized.

The agreed adoption correction remains mandatory: remove the XCTest/environment bypass and migrate rollback command fixtures to a real signed explicit context. Every `.run()` in Debug and Release must unconditionally delegate to the same `run(context: .production)` body and real authority validator. Retaining a legacy parsed-command wrapper that bypasses validation would contradict r2/r3 and is not approved.

## Required negative and wiring evidence

The following interprets the addendum using the actual loader branches:

| Case | Required observation |
| --- | --- |
| Generated/default nil, including a fetch spy capable of returning a valid live feed | Captured defaults equal generated values; artifact value absent; zero `catalog-artifacts` body/sidecar fetches. Other candidate/demand/rate fetches performed by `loadRecommendationInputs` are not falsely counted as artifact requests or claimed absent. |
| Explicit nil | Same absence/no-artifact-fetch behavior; no fallback to fixture bytes from another global/static context. |
| Explicit valid fixture + `includeArtifactFeed: false` | Artifact selection absent and no artifact fetch even though fixture bytes are available. |
| Explicit valid fixture + matching fresh live signed release | Real verifier and existing qualification produce the fixture selection, then the real catalog projection emits the preparation action and real owner consumes it. The plain production context stays absent. |
| Wrong live artifact signer | Use an actually valid signature under a different fixture key, ideally both keys in the fixture trust map; signer equality with the selected candidate must still reject it. A malformed signature alone only tests signature failure. No preparation action or owner success. |
| Wrong baked artifact signer | Exercise fallback deliberately so the baked signer is selected. A valid live document superseding an unused bad fallback is not evidence that fallback signer checks failed. No preparation action or owner success on the mismatched fallback. |
| Cross-release and candidate-body digest substitution | Use well-formed, freshly signed fixture documents so release/digest binding is the failing predicate, not a preceding schema/signature error. Verify no usable artifact selection, action or publication. |
| Explicit-context fixture isolation | Independent loader instances retain independent captured values; no process-global state, parser option or environment selector can activate fixture inputs. All keys and mutable paths remain test-owned. |

Reuse existing corpus coverage for stale/future/expired feeds and ordinary fallback rules, and run it after the plumbing change; do not reimplement the validators merely to support fixtures. Fixture policy/freshness must satisfy the current baked-relative loader policy through valid generated data, not exceptions. The original command-created offer/service settlement join remains a separate required B1-T11 result.

## Qualification limits

The unchanged generated nil default continues to prevent default production artifact preparation even if the endpoint is later available. Record that explicitly in qualification blockers. This approved seam does not publish a feed, change shipped authority, or establish real MLX/physical acceptance. Removing that production absence requires its own authorized release/catalog work; no such work is approved here.

No new code/test finding was established in the proposed initializer seam. The earlier command reservation correction remains intact. Source implementation, migration of existing command fixtures, fresh tests and the final stable combined-diff audit remain pending evidence.

## Exact scoped snapshot

Manifest SHA-256: `7a47dbb7a6935901628b26a56520e9c12488558cee95b93b26c2af8d382388d6`. Computed over the lexically sorted newline-terminated manifest below.

```text
5cd2f3d1daabcd14fa746a50587844a4938999307555bf576dea6490d019fdfe  docs/product-roadmap/build-1/command-composition-testability-addendum-r3.md
c2c42457baca745f21c59c73ad7e2ada70055c9a5a2b407d89ec879b0c65eba4  phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift
905bc308bc1e5cde8ddabea6b0202626a8cc600b98a1859cfb6a67fb9a81e7c2  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
948ed4e568e32844745998d62274ae52d44adf12ac2bb3bac1d7de1a2bbdb946  phase3-binary/Sources/macprovider-cli/ModelCommandExecutionContext.swift
8c456cc17ac3b2c6ed0738a1cedae79f162b56c9eef01401f6fd5d97d7281039  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
```

No source/runtime edits, subagents, secrets or external services were used. No test execution or runtime pass is claimed by this design review.
