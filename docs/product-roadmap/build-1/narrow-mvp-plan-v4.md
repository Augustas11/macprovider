<!-- SUPERSEDED/REJECTED DRAFT: retained only as review history. Use narrow-mvp-plan-v6.md and narrow-mvp-test-spec-v6.md as the authoritative approved Build 1 narrow MVP artifacts. -->
# Build 1 narrow MVP implementation plan v4

Branch: `codex/build1-mvp-narrow`
Base for this plan: dependent on unmerged PR #1510 (`codex/build1-v2-storage-projection` at `6a90f39bfd4b8917ae10169b3c760e03cd2dfd91`). PR #1510 is based on `origin/main` `50b647960cda1cfc794f870f5685c2615b838f5c` and is still open/review-required at the time of this plan. PR #1481 (`feat/byom-v02-slice5-intake-pipeline`) is merged and is treated as landed only through `origin/main` ancestry, not as a separate assumption.

Source roadmap: `/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md` was present and read. It is historical scope evidence; current decisions below are grounded in the code and branch state inspected on this worktree.

## MVP target

Make Product Build 1 shippable through one constrained, physically testable path:

- Supported catalog key: `meta-llama/llama-3.2-3b-instruct`.
- Served model/runtime identity: `mlx-community/Llama-3.2-3B-Instruct-4bit`, MLX safetensors, `mlx_cache`, primary artifact `mlx-4bit`.
- Signed catalog tuple from current generated catalog: revision `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e`, snapshot-manifest hash `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90`, min RAM 4 GB, bandwidth tier C, runtime status `recommendable`.
- Rate-card row: `meta-llama/llama-3.2-3b-instruct`, prompt `13500` credits/Mtok, cached prompt `3375` credits/Mtok, completion `27000` credits/Mtok, provider share `9000` bps, global multiplier `1000000` ppm, `usd_per_million_credits = 1.0`.
- Provider surface: standalone `macprovider-cli` on a physical Apple Silicon Mac; Malibu app/portal copy is a follow-up after this path is qualified.
- Coordinator surface: one isolated non-production staging coordinator/gateway path with `verified_model_settlement_mode=enforce` only inside that staging environment, because current BYOM route eligibility requires enforce mode for settlement-capable route snapshots. Rewards, payout jobs, production endpoints, production enforcement, production rewards, and public economic activation remain disabled/out of scope.

A request is accepted for this MVP only when all authorities agree at the same time: signed catalog/feed identity, local prepared artifact integrity, running MLX runtime identity, coordinator admission state, route-time model binding under isolated staging enforce mode, provider-side request-id-bearing receipt/audit correlation, and verified settlement output. Local preparation alone never grants paid admission, trusted identity, pricing authority, or settlement eligibility.

## Current implementation classification

| Requested outcome | State | Evidence | Implication for MVP |
| --- | --- | --- | --- |
| Signed static candidate/rate feed consumption | Landed for candidate/rate/demand, partial for artifact feed | `AutotuneStaticInputs.loadRecommendationInputs` loads signed recommendation inputs; `AutotuneCatalog.generated.swift` embeds candidate/rate/demand data and sets `bakedArtifactFeedBase64 = nil`; `AutotuneArtifactFeed.swift` defines strict artifact-feed decode/bind rules; `ModelsCatalogEconomicsCommand` reports artifact-feed warnings. | MVP must fail closed or fetch/verify `/v1/catalog-artifacts` for artifact-derived actions. A safe baked fallback cannot imply artifact authority when no baked artifact feed is embedded. The current source artifact list uses `size_bytes: null`; that source is not an acceptable preparation authority until an operator-published artifact-bound release contains measured positive `size_bytes` values accepted by the existing validators. |
| Artifact-feed production/distribution | Partial / operator configured | Coordinator `internal/buyer/autotune_feeds.go` and `catalog_artifacts_feed.go` serve `/v1/catalog-artifacts` only when configured with a bound signed feed pair; runbooks note activation requirements. | MVP requires a staging release that actually serves the artifact feed for the chosen catalog release, or it remains blocked at artifact-authority acceptance. |
| Durable artifact storage | Landed foundation, partial public action | `DurableModelArtifactStore.swift` and `ModelPreparationPrivateStore.swift` support managed roots, root validation, hostile-file rejection and private inventory; PR #1510 projects v2 private inventory into economics storage internally. | Use the existing durable store contracts; expose only one MVP preparation action after plan approval. Do not invent a parallel cache or trust a raw Hugging Face path. |
| Public executable model actions | Partial | `ModelsSubcommand.swift` exposes `discover`, `evaluate`, `offer`, `admission`, `catalog-economics`, `switch`, `adopt-recommendation`; there is no public `models prepare` transaction for catalog artifacts, and public `catalog-economics` emits v1. | Add a narrow CLI journey for the MVP path. Default public behavior must remain compatible unless the operator asks for the MVP action/profile explicitly. |
| Catalog economics truthfulness | Partial | `ModelCatalogEconomics.swift` has action/state wiring and v2 encode-only surface; PR #1510 keeps v2 internal and public v1 unchanged. `scripts/byom_journey_evidence.py` defines allowed action/state vocabulary. | MVP must publish readiness/economics states that distinguish local prepared, coordinator admitted, catalog priced, settlement-capable, and production-not-activated. |
| Admission/probe authority | Partial | `ModelsOfferCommand` and `BYOMModelAdmissionClient` can submit/status offers; SPEC-047 states admission is coordinator-authoritative and settlement-capable paid traffic requires receipt key and rate path. | MVP must use coordinator status and runtime probe evidence. Preparation/provider assertions cannot promote a candidate to `settlement_capable`. |
| Correctly settled request | Partial in fixtures, not physically accepted for this MVP | Integration harness has settlement fixtures around `mlx-community/Llama-3.2-3B-Instruct-4bit`, request log, receipt and settlement outputs; roadmap says real MLX/hardware acceptance was not freshly run. | MVP acceptance requires a physical Mac running actual MLX inference through staging and a recorded verified settlement result; fixture tests are supporting evidence only. |

## User journeys

1. Provider runs `models catalog-economics --json` and sees the chosen Llama 3B row with honest state: discoverable/catalog-priced, preparation required or already prepared, admission state, settlement eligibility, and a banner that this is staging evidence and not production economic activation.
2. Provider runs a single MVP preparation command for the chosen row. The CLI discloses repository, pinned revision, expected identity hash, size when known, destination root, staging path, cancellation behavior, and that preparation does not grant admission or earnings.
3. Preparation stages the artifact, verifies the snapshot manifest digest against the signed artifact feed/candidate tuple, writes durable managed-v3 private inventory, then adopts only after integrity succeeds. Cancellation or failure preserves the previously active model.
4. Provider starts or reloads `macprovider-cli serve` on the prepared model. The CLI reports local readiness only when the running MLX runtime identity matches the prepared artifact and signed catalog tuple, and the acceptance driver captures provider-side correlation before and after the buyer request.
5. Provider submits or refreshes network model admission against staging. Coordinator status is the only source for `catalog_priced` / `settlement_capable`; the local CLI only reflects it.
6. A buyer sends one non-streaming request through the isolated staging gateway to the Llama 3B model. The response is correlated to the physical `macprovider-cli` process by provider binary/process identity, local provider `/status` JSON carrying `model_hash`/`weights_manifest_sha256`, route/provider id, and request-id-bearing `receipt_issued`/receipt-audit or equivalent provider log evidence. Served-count advancement may support the claim but is not sufficient alone. The gateway/coordinator produce a verified settlement record with the expected model/artifact/hardware context.
7. Provider inspects an acceptance bundle that separates local prep, staging admission, verified settlement, hardware context, and explicit production qualification blockers.

## Ownership boundaries

Primary implementation surfaces for this MVP:

- `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift` for the narrow CLI journey/action wiring.
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` and `AutotuneArtifactFeed.swift` only if live artifact-feed consumption needs a small consumer adapter; keep signer/release/freshness validation aligned with existing strict validators.
- `phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift`, `ModelPreparationPrivateStore.swift`, and `ModelCatalogEconomics.swift` only through existing contracts and PR #1510 projection seams.
- `scripts/` for an acceptance evidence driver that records commands/results without secrets.
- `test/integration/` only for staging/fixture proof helpers if needed; no production service changes unless the plan gate explicitly identifies a small coordinator staging endpoint gap.

Out of scope for this MVP:

- Malibu app/provider portal UI.
- General BYOM marketplace, non-primary artifacts, Ollama/LM Studio/llama.cpp/OpenAI-compatible loopback acceptance, arbitrary MLX repos, or all catalog rows.
- Production admission enforcement, production economic activation, payouts, rewards activation, or public release publishing.
- New operator secrets, new hardware procurement, or any change to `d-inference`.
- Build 2 private buyer UX, Build 3 compute observations, Build 4 Trusted Pool composition, Build 5 throughput engine.

## Dependency graph

1. PR #1510 or equivalent storage projection must land or remain explicitly included in this dependent branch.
2. Staging coordinator must serve a signed artifact-bound release for the chosen catalog tuple via `/v1/catalog-artifacts` and `/v1/catalog-artifacts.sig`, or the MVP cannot pass artifact-authority acceptance.
3. CLI artifact-preparation action depends on verified artifact identity and durable private-store adoption.
4. Local readiness depends on the running serve process reporting the chosen MLX model identity and prepared artifact digest.
5. Network admission depends on coordinator status, including catalog/rate binding, receipt key availability, and staging settlement enforce configuration for BYOM route eligibility.
6. Settled-request proof depends on the staging gateway/coordinator settlement path, not on provider-side claims.

## Normative contracts

- SPEC-023 artifact feed contracts apply to schema, signer identity, release binding, freshness, primary artifact consistency, and fail-closed behavior for artifact-derived actions.
- SPEC-044 preparation/economics contracts apply to action vocabulary, managed-v3 storage, cleanup/adoption safety, and truthfulness of earning states.
- SPEC-046 discovery/evaluation remains local inventory only and cannot grant routing/economic authority.
- SPEC-047 network model admission remains coordinator-authoritative; `settlement_capable` requires the coordinator's state and cannot be inferred from preparation or local runtime.
- SPEC-022 settlement evidence remains required for the accepted request; provider signatures alone are insufficient to prove physical computation.

## Phased implementation

### Phase A: MVP profile and projection truthfulness

Add a small, closed MVP profile definition for the single Llama 3B MLX tuple. Wire `models catalog-economics` to surface v2-like MVP readiness only behind an explicit flag or subcommand name that cannot change default v1 behavior. The output must include:

- catalog tuple and rate tuple;
- artifact authority state: `verified`, `unavailable`, `stale`, `release_mismatch`, `signature_invalid`, or `unsupported`;
- local preparation state: absent, staging, prepared, adopted, failed, cancelled;
- runtime readiness state: not running, running mismatch, running match;
- coordinator admission state and source;
- settlement qualification state: fixture-only, staging-enforce-verified, production-not-activated.

### Phase B: artifact feed consumer for the MVP action

Reuse existing strict artifact-feed decode/bind validation. Fetch from the configured coordinator only when the coordinator URL is explicitly supplied/configured for staging. Reject corrupt JSON, bad signatures, signer mismatch, cross-release feed, stale feed, missing primary artifact, unsupported runtime source, unsupported artifact id, unmeasured/non-positive `size_bytes`, and size/hash inconsistency. If live feed is unavailable, unmeasured, or no baked artifact feed exists, the action must be unavailable with a truthful blocker; fallback candidate/rate data may support recommendation copy but not preparation authority.

### Phase C: trusted preparation/adoption transaction

Implement one catalog-preparation transaction for the MVP tuple using existing durable-store primitives. The command must:

- disclose pinned model/revision/hash, expected runtime source, destination root, measured feed `size_bytes`, available disk check, and staging bytes before adoption;
- stage into a temporary managed-v3 location;
- verify snapshot manifest digest before publish;
- write a root-validated private inventory record;
- support cancellation and recovery without changing the active model;
- adopt only after verification and record the previous active model for rollback messaging;
- avoid raw private paths in public JSON except operator-local redacted diagnostics.

### Phase D: admission and staging settlement evidence

Add or update an acceptance driver that performs the MVP sequence against staging and writes a redacted evidence bundle:

1. signed feed verification capture;
2. preparation/adoption capture;
3. runtime readiness capture;
4. coordinator admission/status capture;
5. buyer non-streaming request capture through actual MLX inference, including provider-side request-id-bearing receipt/audit correlation;
6. verified settlement/receipt capture with model/artifact/hardware context, route/provider id, request id, and staging-enforce configuration proof;
7. negative-test captures for corrupt/cross-release/stale feed, cancellation, runtime mismatch, model drift, unsupported model, and admission demotion.

The driver must not read or print operator secrets, tokens, private keys, or payout material. It must mark unavailable Docker/staging/hardware prerequisites as blockers, not passes.

## Acceptance criteria

Implementation is locally complete when unit and integration tests prove:

- the MVP profile accepts only `meta-llama/llama-3.2-3b-instruct` with the exact signed MLX primary tuple and rejects all other catalog keys/artifacts/runtime sources;
- artifact feed verification fails closed for corrupt bytes, bad detached signature, wrong signer, cross-release candidate binding, stale feed, missing primary artifact, unmeasured/non-positive `size_bytes`, bad hash fields, and unsupported runtime source;
- preparation discloses size/trust state, stages safely, verifies integrity before adoption, persists managed-v3 inventory, and leaves the active model unchanged on cancellation or verification failure;
- `catalog-economics`/status states are truthful: local prepared is not admission, admission is not settlement, staging settlement is not production activation, and unsupported/non-primary models cannot show paid readiness;
- coordinator admission/rate drift or runtime model drift demotes readiness and prevents settlement-capable copy;
- fixture settlement proves request/accounting math for the chosen model, while physical acceptance remains separately recorded.

Product acceptance is complete only after a physical Mac evidence bundle shows:

- actual preparation/adoption of `mlx-community/Llama-3.2-3B-Instruct-4bit`;
- valid staging admission for the prepared/running identity;
- one real MLX non-streaming request routed through the isolated staging-enforce path;
- verified settlement output with matching model/artifact/hardware context, provider-side request-id-bearing receipt/audit correlation, and correct rate application;
- explicit statement that production economic activation, production enforcement, rewards, payout jobs, and payouts were not enabled.

## Negative tests

- Corrupt artifact-feed JSON and tampered signature.
- Artifact feed signed by a trusted but different release/signer than the candidate release.
- Stale feed and stale candidate/rate material.
- Candidate row points to one revision/hash while artifact feed primary points elsewhere.
- Cancel during staging, cancel after verification before adoption, crash/recovery during staging, and stale staging cleanup.
- Existing active model remains active after cancellation/failure.
- Running MLX serves a different model id or artifact digest than the prepared tuple.
- Coordinator reports `network_admitted_unsettled`, `catalog_priced`, `withdrawn`, or `revoked`; CLI must not present those as settlement-ready.
- Rate-card row changes or default fallback is used; MVP must not claim exact Llama 3B pricing unless the specific row is present and bound.
- Unsupported model/runtime/profile, including Llama free alias and non-primary artifacts.

## Migration, compatibility, rollback

- No data migration is required beyond writing new managed-v3 private-store records through existing versioned envelopes.
- Default `models catalog-economics --json` v1 output remains compatible unless the explicit MVP flag/subcommand is used.
- Existing prepared/private-store data must be read-only until the operator invokes the MVP preparation/adoption action.
- Rollback is to disable the MVP action/profile and retain existing v1 recommendation/admission behavior. Prepared artifacts remain local files and can be cleaned through managed-v3 cleanup once that action is separately exposed.

## Observability and evidence artifacts

- Store plan, verifier findings, implementation notes, commands, and acceptance reports under `docs/product-roadmap/build-1/` and `docs/product-roadmap/build-1/reviews/`.
- Store physical acceptance evidence in a redacted bundle path outside tracked source, with a tracked manifest that records hashes and omissions.
- Public CLI JSON must include machine-readable blockers and avoid raw private paths, bearer tokens, provider secrets, private keys, or wallet material.

## Hardware and external prerequisites

- Physical Apple Silicon Mac with at least 8 GB RAM is the intended floor for the chosen row's catalog min RAM 4 GB plus OS/runtime headroom; acceptance must record actual chip, RAM, OS, binary version, MLX version/context, measured artifact `size_bytes`, and storage availability. If the measured artifact-bound release is not available in staging, physical acceptance is blocked before preparation.
- Network access to fetch the pinned Hugging Face revision or preexisting cache with a verified snapshot manifest.
- Staging coordinator/gateway configured with the bound artifact feed, candidate/rate feed, admission path, verified-model settlement `enforce` mode for this isolated staging environment, settlement evidence retrieval, and test buyer/provider credentials. Rewards and payout jobs must be disabled, and production endpoints must not be changed.
- No production payout/reward activation and no production enforcement changes.

## Verification plan summary

- Swift unit tests for profile gate, feed validation, preparation state machine, cancellation, inventory projection, runtime `/status` digest binding, request-id audit correlation, and status truthfulness.
- Go integration tests or existing harness extension for chosen model settlement math and demotion semantics.
- Script tests for redacted evidence bundle schema and zero-selected/skipped-test rejection.
- Fresh local targeted tests, then broader Swift/Go checks appropriate to changed files.
- Native `gpt-5.6-sol` independent code, security, and architecture audit lanes over the complete implementation diff before PR handoff, with zero Critical/High/Medium findings.

## Roadmap outcome mapping

| Roadmap outcome | MVP implementation step | Verification method |
| --- | --- | --- |
| Discover appropriate model | Closed MVP profile + catalog-economics readiness for Llama 3B | Unit tests reject unsupported/non-primary rows; CLI JSON fixture. |
| Prepare artifact | Artifact-feed consumer + durable preparation/adoption transaction | Swift tests for success/cancel/failure; physical evidence bundle. |
| Obtain valid network admission | Coordinator status reflection only | Integration/staging captures for admission states and demotion. |
| Correctly priced and settled request | Staging request through actual MLX with verified settlement | Settlement fixture tests plus physical staging evidence requiring provider receipt/audit request-id correlation and local `/status` digest binding. |
| Executable provider UX | Single CLI path with truthful blockers/actions | CLI tests for JSON/action availability and human-copy snapshots if present. |
| No false authority | Explicit separation of local prep/admission/settlement/production activation | Negative tests for drift, stale feeds, unsupported model, unsettled states. |
