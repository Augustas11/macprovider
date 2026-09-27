# Build 1 historical Llama regression test specification v6

Status: retired from Build 1 acceptance on 2026-09-26.

This specification covers local, hermetic regression tests for the recovered
Llama-specific provider plumbing only. It authorizes no physical hardware
campaign, staging execution, buyer request, settlement evidence, or Build 1
acceptance claim.

Build 1 acceptance follows `build1-control-recovery-plan-v2.md` and the pinned
non-catalog private tuple:

- `orcarouter/qwen3.8-27b-uncensored`;
- `orcarouter/Qwen3.8-27B-Uncensored-MLX`;
- revision `38d0ad4e02031658fadd3828634a0174e0b8a282`;
- native MLX safetensors from the complete pinned revision snapshot.

## Allowed evidence

- Swift and Go unit tests that exercise contracts without external services.
- Deterministic local coordinator, gateway, and settlement fixtures.
- CLI JSON fixtures that prove truthful blockers and state transitions.

These are regression evidence only. They cannot be promoted to physical,
staging, settlement, release, or product-acceptance evidence.

## Required regression properties

| Area | Positive regression | Required failures |
| --- | --- | --- |
| Legacy tuple gate | The exact historical Llama tuple remains recognizable by recovered code | Aliases, other rows, non-primary artifacts, unsupported runtime sources, and revision/hash drift are rejected |
| Artifact authority | A correctly bound signed fixture unlocks only the local test transition | Corrupt JSON, tampered signature, wrong signer, release mismatch, stale data, missing artifact, and non-positive/unmeasured size fail closed |
| Preparation | Fixture stages, verifies, publishes, adopts, and writes managed private inventory | Cancellation, crash recovery, digest mismatch, insufficient disk, and hostile files cannot change the active model |
| Status truthfulness | Local prepared, admitted, settlement-capable, and production-active remain distinct states | Local claims cannot mint coordinator or economic authority |
| Fixture settlement | Request/accounting fixtures retain model and rate binding | Replay, model drift, digest substitution, missing receipt, and default-rate fallback are rejected or demoted |
| Evidence hygiene | Test artifacts redact secrets and label fixture provenance | Skipped, zero-selected, or fixture runs cannot be labeled physical acceptance |

## Commands

```bash
cd phase3-binary && swift test --filter Build1LaneA
cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
cd phase3-binary && swift test --filter AutotuneArtifactFeedTests
cd phase3-binary && swift test --filter DurableModelArtifactStoreTests
cd phase3-binary && swift test --filter BYOMAdmissionTests
cd test/integration && go test -run 'Settlement|Llama|ModelAdmission|Build1' -count=1
cd phase5-gateway && go test ./internal/router -run 'Settlement|Models|Rate|Llama' -count=1
```

When executable code changes, also run the relevant broader Swift/Go gates and
`git diff --check`. A blocked or unavailable command must be recorded as a
blocker, never as a pass.

## Explicitly retired journey

Do not run a Llama physical staging journey. Do not prepare or serve Llama on a
Mac for Build 1, submit Llama admission, send a Llama buyer request, or assemble
a Llama acceptance bundle. The OrcaRouter M2-M6 milestones define the only
current authority, implementation, physical, staging, receipt, and settlement
path.
