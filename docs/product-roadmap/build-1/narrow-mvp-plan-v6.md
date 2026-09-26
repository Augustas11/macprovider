# Build 1 historical Llama regression plan v6

Status: retired from Build 1 execution on 2026-09-26.

This document preserves the regression intent for the recovered, Llama-specific
provider plumbing. It is not a current MVP plan, hardware campaign plan,
acceptance plan, or release authority.

Current Build 1 execution and acceptance are governed exclusively by
`build1-control-recovery-plan-v2.md`. The selected model is the non-catalog
private tuple:

- catalog key: `orcarouter/qwen3.8-27b-uncensored`;
- repository: `orcarouter/Qwen3.8-27B-Uncensored-MLX`;
- revision: `38d0ad4e02031658fadd3828634a0174e0b8a282`;
- runtime source: `mlx_safetensors`;
- artifact scope: the complete pinned Hugging Face revision snapshot.

The catalog Llama tuple
`meta-llama/llama-3.2-3b-instruct` /
`mlx-community/Llama-3.2-3B-Instruct-4bit` remains only as local, hermetic
regression scaffolding. It must not receive a physical campaign, staging
admission run, buyer request, settlement claim, Build 1 evidence bundle, or
product-acceptance credit.

## Preserved regression contract

The recovered Llama-specific implementation may continue to prove these local
properties until the OrcaRouter M3 extension supersedes it:

- an exact tuple gate rejects aliases, other catalog rows, non-primary
  artifacts, unsupported runtime sources, and revision/hash drift;
- signed artifact authority fails closed for corrupt bytes, bad signatures,
  signer or release mismatch, stale material, missing artifacts, and
  non-positive or unmeasured size;
- preparation stages and verifies before adoption, writes managed private
  inventory, and preserves the active model after cancellation or failure;
- status output separates local preparation, coordinator admission, settlement
  capability, and production activation;
- local fixtures may validate request/accounting and demotion behavior but do
  not constitute physical or product acceptance.

No Llama-specific rate, catalog presence, or staging result can satisfy the
OrcaRouter milestones. M2 must first establish the OrcaRouter measured size,
canonical snapshot-manifest digest, staging release identity, signer identity,
and fresh public-catalog absence evidence. M3 then extends the guarded provider
path to that exact private tuple without enabling arbitrary repository
preparation.

## Local verification only

Relevant regression checks include:

```bash
cd phase3-binary && swift test --filter Build1LaneA
cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
cd phase3-binary && swift test --filter AutotuneArtifactFeedTests
cd phase3-binary && swift test --filter DurableModelArtifactStoreTests
cd phase3-binary && swift test --filter BYOMAdmissionTests
```

Skipped, timed-out, zero-selected, fixture-only, historical, or operator-claimed
runs must not be reported as OrcaRouter physical acceptance.

## Historical provenance

The superseded plan targeted a single catalog Llama path and depended on old PR
#1510 state. Those implementation assumptions remain useful only for regression
coverage and code archaeology. They must not guide an executor, operator, audit,
or release decision after this retirement notice.
