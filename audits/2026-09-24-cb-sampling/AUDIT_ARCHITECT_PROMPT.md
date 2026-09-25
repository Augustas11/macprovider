# Codex audit: batched sampled rows (SPEC-038 v0.2.6 AC-6b), #1646 follow-up

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-cb-sampling`. Branch:
`campaign/1646-cb-sampling`, stacked on the already-audited #1716 head
(`30e634eb`; Codex gate met there). Review the new diff:
`git diff 30e634eb..HEAD -- ':!docs' ':!audits'`.

What it does: continuous batching previously admitted only greedy requests
(`temperature 0`, `top_p 1`, no penalties). Now each batched row samples with
the serial path's own sampler, `GenerateParameters(temperature:topP:seed:).sampler()`
(argmax, nucleus or categorical), on that row's logits only. Key pieces:

- `ContinuousBatchRowSampler`, a new file:
  - `supports(temperature:topP:)`;
  - `requestSeed(requestID:)`, which takes the first 8 bytes of
    SHA-256(request ID);
  - `stepSeed`, splitmix64 over (seed, step);
  - `sample(logits:rows:)`, which keeps the batched argmax fast path when
    every row is greedy.
- `PagedKVRuntimeBridge.performDecode`: both decode paths use the row sampler
  with `samplerStep + stepIndex`. The greedy filter is replaced by
  `supportsRowSampling`.
- `ModelRuntime.requestStateRepresentable`: the greedy gate is replaced by
  `ContinuousBatchRowSampler.supports`. Tools, structured output, logit_bias
  and logprobs still serial-route. Both scheduler submit sites pass
  `samplerSeed: requestSeed(schedulerRequestID)`; before this, every row had
  seed 0.
- Presence and frequency penalties are ignored, because the serial path's
  `makeServeGenerateParameters` never passes them to MLX.
- SPEC-038 v0.2.6 FR-CB6 and AC-6b; tests.

Lab evidence (Studio, Qwen3.6):
`docs/runbooks/continuous-batching-sampled-rows-evidence-2026-09-24.md`.
- Sampled traffic runs 1.52× faster batched than serial.
- There were 0 forward failures and no leak signal.
- A request's output is identical as a lone row and among concurrent rows.
- Against the serial sampler, differences appear only at accumulation-order
  and exact-bf16-tie positions.

This change is intended to ship to the live Studio provider, which serves
buyers on Qwen3.6 with `canary` and 8 seats.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: ARCHITECTURE (spec conformance, rollout)

Check:
- The SPEC-038 v0.2.6 FR-CB6 and AC-6b text against the code.
- Whether "equal in distribution" plus neighbour independence is a sound,
  testable contract.
- Ignoring penalties: whether that is consistent with the serial path, and
  what happens if the serial path starts honoring them.
- `CONFORMANCE.json` and the spec index.
- Rollout safety on a live canary: a signed candidate and revision-bound
  acceptance, which are unchanged.
