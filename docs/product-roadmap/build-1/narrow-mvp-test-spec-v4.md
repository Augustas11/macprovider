<!-- SUPERSEDED/REJECTED DRAFT: retained only as review history. Use narrow-mvp-plan-v6.md and narrow-mvp-test-spec-v6.md as the authoritative approved Build 1 narrow MVP artifacts. -->
# Build 1 narrow MVP test specification v4

Scope: one shippable Build 1 MVP path for `meta-llama/llama-3.2-3b-instruct` / `mlx-community/Llama-3.2-3B-Instruct-4bit` on MLX `mlx_cache`, through staging-only admission and verified settlement evidence under an isolated non-production staging `verified_model_settlement_mode=enforce` configuration. Rewards, payout jobs, production enforcement, and production economic activation are out of scope. This test specification is tied to `docs/product-roadmap/build-1/narrow-mvp-plan-v4.md` and the dependent branch on PR #1510 head `6a90f39bfd4b8917ae10169b3c760e03cd2dfd91`.

## Evidence classes

- Unit evidence: Swift and Go tests that exercise contracts without external services.
- Fixture integration evidence: local coordinator/gateway tests and deterministic fixtures. Valuable for contract regressions, not physical acceptance.
- Physical staging evidence: actual Apple Silicon Mac, actual MLX inference, staging coordinator/gateway, verified settlement output. Required for Product Build 1 MVP acceptance.
- Production qualification: out of scope; must remain blocked/not activated.

No skipped, timed-out, zero-selected, fixture-only, historical, or operator-claimed run may be reported as physical acceptance.

## Required command groups

### Swift targeted tests

Run after implementation changes to the CLI/preparation path:

```bash
cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
cd phase3-binary && swift test --filter AutotuneArtifactFeedTests
cd phase3-binary && swift test --filter DurableModelArtifactStoreTests
cd phase3-binary && swift test --filter BYOMAdmissionTests
```

Add focused tests for the new MVP profile/action names once implemented, for example:

```bash
cd phase3-binary && swift test --filter Build1NarrowMVPTests
```

### Go targeted tests

Run if coordinator/gateway settlement or staging harness code changes:

```bash
cd test/integration && go test -run 'Settlement|Llama|ModelAdmission|Build1' -count=1
cd phase4-coordinator && go test ./internal/ws ./internal/buyer ./internal/billing -run 'ModelAdmission|CatalogArtifacts|Settlement|Rate' -count=1
cd phase5-gateway && go test ./internal/router -run 'Settlement|Models|Rate|Llama' -count=1
```

### Cross-surface checks

Run before PR handoff when executable code changes:

```bash
make test-coordinator
make test-gateway
make test-integration
cd phase3-binary && swift test
git diff --check
```

If a broad check cannot run because Docker, staging credentials, network, physical hardware, or a measured artifact-bound staging release are unavailable, record the exact blocker and run the next-best targeted tests. Do not mark the blocked check as passing.

## Test matrix

| Area | Positive case | Negative/failure cases | Acceptance evidence |
| --- | --- | --- | --- |
| MVP profile gate | Exact Llama 3B catalog key, MLX primary artifact, `mlx_cache`, signed revision/hash accepted | Qwen/OpenAI/Gemma rows, Llama free alias, non-primary artifact id, loopback runtime, wrong revision/hash rejected | Swift unit tests plus CLI JSON fixture. |
| Artifact feed verification | Bound `/v1/catalog-artifacts` and detached signature for the same release with measured positive `size_bytes` unlock artifact-derived action | Corrupt JSON, tampered sig, wrong signer, cross-release candidate digest, stale feed, missing primary artifact, unmeasured/non-positive size, bad hash, unsupported runtime source | Swift validator tests and script fixture tests. |
| Fallback behavior | Candidate/rate baked fallback may still show recommendation/economics warnings | No baked artifact feed or live verified feed means prepare/adopt action unavailable | CLI tests assert blocker and no prep authority. |
| Preparation transaction | Stage, verify snapshot manifest, publish/adopt, write managed-v3 inventory | Cancel before/after verification, crash recovery, digest mismatch, insufficient disk, hostile private-store files | Swift transaction tests; physical evidence for success. |
| Active model preservation | Previous active model remains active during failed/cancelled prep | Adoption cannot occur after cancelled transaction or mismatched authority | Control-socket/store tests; physical acceptance logs. |
| Runtime readiness | Running MLX model identity and local provider `/status` `model_hash`/`weights_manifest_sha256` match the prepared tuple | Serve stopped, stale socket, wrong model id, wrong artifact digest, unresponsive warm-swap | CLI status tests and physical capture from the physical provider only. |
| Admission state | Coordinator returns current state for the candidate/provider | `network_admitted_unsettled`, `catalog_priced`, `withdrawn`, `revoked`, stale coordinator status, receipt key unavailable | Unit/fixture tests for copy/action mapping; staging capture. |
| Pricing | Specific Llama 3B rate-card row bound and applied | Default rate fallback, stale rate-card, row drift, model alias mismatch | Swift economics tests and settlement math fixture. |
| Settlement | One non-streaming staging request settles with matching model/artifact/hardware context under isolated staging enforce mode | Replay, digest substitution, model drift between admission and route, missing receipt, delayed receipt reconciliation, observe-mode BYOM route attempted | Existing/new integration tests plus physical staging evidence. |
| Evidence bundle | Redacted manifest records command, binary version, git SHA, model tuple, hardware, local provider `/status` digest binding, request-id-bearing provider receipt/audit correlation, staging-enforce config proof, captures and blockers | Secrets printed, raw private paths exposed, skipped tests marked pass, fixture evidence mislabeled physical, fake provider evidence mislabeled MLX, served-count-only correlation accepted | Script tests and manual review. |

## Physical staging journey

The physical MVP journey must run on an Apple Silicon Mac and produce a redacted acceptance bundle with these steps:

1. Record git SHA, branch, binary version, OS, chip, RAM, free disk, MLX runtime version, staging coordinator/gateway URLs with secrets redacted, and proof the staging coordinator uses verified-model settlement enforce mode while rewards/payout jobs are disabled.
2. Verify candidate/rate/demand feeds and the artifact feed for the Llama 3B release. Record release id, signer key id, feed SHA-256, freshness decision, and chosen model tuple.
3. Prepare the artifact. Record measured feed `size_bytes`, available disk decision, staged byte count, snapshot-manifest digest, durable-store inventory digest, cancellation/recovery capability, and adopted model id.
4. Start or reload the CLI provider. Record `macprovider-cli` binary path/hash/version, process id, provider id, running model id, runtime source, local provider `/status` JSON fields `model_hash` and `weights_manifest_sha256`, context/concurrency profile, receipt key availability, local readiness state, and pre-request receipt-audit/log cursor. The digest authority for physical acceptance is local provider `/status`, not control-socket model name alone.
5. Submit/refresh staging admission. Record coordinator admission state and event id. Continue only if the coordinator reports the required state for settlement evidence; otherwise stop with blocker.
6. Send one non-streaming buyer request through the staging gateway to `mlx-community/Llama-3.2-3B-Instruct-4bit`. Record request id, response status, token usage, and route/provider id with secrets redacted. Physical acceptance requires a matching request id in provider-side `receipt_issued`/receipt audit or an equivalent provider log that also records provider id, model id, and receipt/settlement metadata; monotonic served-count advancement is supporting evidence only and must not be accepted as sole correlation proof.
7. Retrieve settlement/receipt evidence. Record model id, catalog key, artifact digest, hardware context, rate row, credits, provider share, verification status, request id, and route/provider id matching the provider-side receipt/audit correlation and local `/status` digest binding.
8. Record production blockers: production activation disabled, production rewards/payouts disabled, no payout job, no release publication, no production enforcement change.

Streaming may be captured as extra evidence, but the MVP acceptance minimum is one non-streaming physical request because Build 2 owns private streaming journeys. A fixture, fake HTTP provider, or served-count-only proof cannot satisfy this physical MLX acceptance step.

## Freshness and trust checks

- Feed freshness uses the existing signed-feed policy and must be reported as `fresh`, `stale`, `fallback`, or `unavailable`.
- Signer identity must match the trusted keyring and release binding. A trusted key for a different release does not satisfy artifact authority.
- The candidate catalog hash in the artifact feed must match the selected candidate release bytes.
- A feed that omits artifact size or publishes `size_bytes: null` is not preparation authority for this MVP. The CLI must report the measured-size blocker and keep prepare/adopt unavailable.

## Audit gate after implementation

Before PR handoff, run three independent native `gpt-5.6-sol` audit lanes over the full diff from the base before this MVP branch to HEAD:

- code review;
- security review;
- architecture/contracts review.

Each lane must report structured findings with severity, evidence, consequence and required correction. Implementation is not handoff-ready until all Critical, High and Medium findings are fixed or the lane explicitly reports none. Low/Info findings may be carried with rationale.

## Qualification report template

The final MVP acceptance report must include:

- implementation PR and dependency PRs;
- exact commits tested;
- local test commands and results;
- physical staging journey result or explicit blocker;
- hardware qualification status;
- production qualification status (`not activated` unless separately authorized);
- unresolved blockers and follow-up slices.

## Provider correlation rule

Physical acceptance requires all of the following in the same redacted bundle: gateway request id; route/provider id; provider-side `receipt_issued`/receipt-audit or equivalent log line containing that request id, provider id, model id and receipt metadata; local provider `/status` JSON before and after with `model_hash` and `weights_manifest_sha256` matching the prepared artifact; and verified settlement evidence referencing the same request/provider/model. If the current active-request tracker does not carry the gateway request id, implementation must pass the audit request id into request tracking or use receipt audit as the normative evidence source.
