# Build 1 historical Lane A Llama plumbing PRD v1

Status: retired from Build 1 execution on 2026-09-26.

This document records the original design intent behind the recovered Lane A
Llama plumbing. It is retained for code archaeology and local regression
coverage only. It is not an executable provider-path PRD, hardware campaign,
staging plan, release plan, or acceptance authority.

The sole current Build 1 execution authority is
`build1-control-recovery-plan-v2.md`, using this pinned non-catalog tuple:

- catalog key: `orcarouter/qwen3.8-27b-uncensored`;
- repository: `orcarouter/Qwen3.8-27B-Uncensored-MLX`;
- revision: `38d0ad4e02031658fadd3828634a0174e0b8a282`;
- runtime source: `mlx_safetensors`;
- artifact scope: the complete pinned Hugging Face revision snapshot.

## Preserved design intent

The historical Lane A work established a narrow, fail-closed provider control
shape:

- exact tuple and artifact authority gates;
- verified staging before durable adoption;
- cancellation and failure that preserve the active model;
- private preparation inventory separated from public catalog state;
- local status correlation that cannot grant admission or economic authority;
- explicit separation of preparation, admission, settlement, and production
  activation.

The recovered implementation is still Llama-specific. M3 must extend that
shape to the exact OrcaRouter tuple without creating arbitrary repository
preparation or treating a private tuple as a public catalog row.

## Prohibited use

Do not use the historical Llama tuple for a physical Mac campaign, staging
admission, buyer request, receipt or settlement proof, evidence bundle, release
decision, or Build 1 acceptance. Local and hermetic regression tests are the
only permitted use of the Llama-specific path.

M2 must complete the OrcaRouter measured size, canonical snapshot-manifest
digest, staging release identity, signer identity, and fresh active-catalog
absence check before M3 implementation begins. M4-M6 then own the isolated
physical provider, staging request, receipt correlation, and settlement
evidence for OrcaRouter only.

## Historical provenance

Date: 2026-09-15. Original branch: `codex/build1-lane-a-provider-path`.
Original base: `origin/main` at `e7213fa1`.

Those branch references describe the superseded planning context and carry no
current execution authority.
