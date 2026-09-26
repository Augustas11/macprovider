# Build 1 historical Lane A Llama regression test spec v1

Status: retired from Build 1 acceptance on 2026-09-26.

This document preserves local regression expectations for the recovered Lane A
Llama plumbing. It authorizes no physical hardware campaign, staging execution,
buyer traffic, receipt or settlement evidence, release, or product acceptance.

Current acceptance is governed exclusively by
`build1-control-recovery-plan-v2.md` and the pinned private OrcaRouter tuple
`orcarouter/Qwen3.8-27B-Uncensored-MLX` at revision
`38d0ad4e02031658fadd3828634a0174e0b8a282`.

## Regression scope

Local and hermetic tests may continue to verify that the historical
Llama-specific path:

- accepts only its exact legacy tuple and rejects aliases or drift;
- validates signed artifact and release binding fail closed;
- verifies staged content before adoption;
- preserves the active model through cancellation and failure;
- rejects hostile durable-store inputs;
- exposes truthful preparation and status blockers;
- never converts local state into coordinator admission, settlement, rewards,
  payout, or production authority.

## Relevant local checks

```bash
cd phase3-binary && swift test --filter Build1LaneA
cd phase3-binary && swift test --filter ModelsPrepareCommandTests
cd phase3-binary && swift test --filter DurableModelArtifactStoreTests
cd phase3-binary && swift test --filter ModelPreparationPrivateStoreTests
cd phase3-binary && swift test --filter Build1LaneAStatusTests
```

Run broader Swift, Go, script, governance, and audit gates when the changed
surface requires them. A skipped, timed-out, zero-selected, fixture-only, or
operator-claimed run is never physical or product acceptance.

## Explicitly retired journey

Do not prepare or serve Llama on physical hardware for Build 1. Do not submit
Llama staging admission, send a Llama buyer request, capture a Llama receipt or
settlement, or assemble a Llama acceptance bundle. OrcaRouter M2-M6 define the
only current authority, implementation, physical, staging, receipt, and
settlement path.

## Historical provenance

Date: 2026-09-15. Original branch: `codex/build1-lane-a-provider-path`.
Original base: `origin/main` at `e7213fa1`. These references are historical
only and do not direct current execution.
