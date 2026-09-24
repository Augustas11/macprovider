codex
Architecture audit: no Critical, High, or Medium findings.

The implementation conforms to FR-CB6/AC-6b:

- `ContinuousBatchRowSampler` applies the serial sampler to each row’s own logits with request/step-local seeds (`ContinuousBatchRowSampler.swift:25-68`).
- Both decode paths use `samplerStep + stepIndex` (`PagedKVRuntimeBridge.swift:835-880`).
- Unsupported row state remains serial-routed (`ModelRuntime.swift:3350-3372`).
- Penalties are currently ignored consistently: `makeServeGenerateParameters` does not pass them to MLX (`ModelRuntime.swift:1286-1302`). If serial generation later honors penalties, admission must first reject/serial-route penalized requests or add equivalent batched processors; otherwise outputs would diverge. This is a future maintenance condition, not a current finding.
- “Equal in distribution” plus neighbor independence is sound and testable through deterministic request/step seeds, identical-logit sampler fixtures, lone-vs-concurrent hardware comparisons, and leak checks. The contract correctly does not require token identity against unseeded serial runs.
- `CONFORMANCE.json` and `specs/README.md` correctly identify SPEC-038 v0.2.6 as draft, pending reconciliation, and not deployed.
- Runtime acceptance remains bound to model, hardware, cache/KV configuration, Metal SHA, and kernel identifier (`ContinuousBatching.swift:144-155`). No rollout bypass was introduced. The isolated lab evidence does not itself authorize live canary; promotion still requires the signed candidate and exact revision-bound acceptance tuple.

Validation:

- `ContinuousBatchRowSamplerTests`: passed; 4 Metal-gated tests skipped.
- `ContinuousBatchSchedulerTests`: 79 passed, 4 skipped.
- `PagedKVRuntimeBridgeTests`: 31 passed, 15 skipped.
- `ServingKnobsConfigTests`: 98 passed, 1 skipped.
- Spec index, lint, governance, and diff checks passed.
- No malformed payloads were constructed.

VERDICT: PASS
