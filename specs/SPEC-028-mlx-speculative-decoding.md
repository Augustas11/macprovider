# SPEC-028 — MLX Speculative Decoding for Provider Serve

**Version:** 0.2-draft
**Status:** Draft (research round; not locked; implementation MUST NOT begin before human review)
**Date drafted:** 2026-07-05
**Revision history:**
- v0.1 (2026-07-05): initial research-round draft.
- v0.2 (2026-07-05): greedy-only gate confirmed for v0.1; draft-model hash explicitly out of scope (no SPEC-011 amendment); gpt-oss waived from v0.1 compatibility; AC-10 reframed as ratio over measured baseline plus a sustained-thermal window; FR-4 gains a `ProviderCapacity` headroom refresh; FR-9 gains a counter-reset on warm-swap boundary.
**Depends on:** SPEC-001 v1.6 (`macprovider-cli serve`, OpenAI-compatible HTTP, heartbeat/status), SPEC-010 v1.5 (`supported_models[]` semantics), SPEC-011 v0.5 (warm-swap state machine and target `model_hash` heartbeat), SPEC-013 v0.3 (`autotune` serving knobs and static candidate catalog), SPEC-015 v0.4.2 (locked settlement receipt usage schema), `mlx-swift-lm` 3.31.4.

SPEC-028 is provider-side only. With no draft model configured, provider behavior MUST be byte-identical to the existing non-speculative serve path. SPEC-028 MUST NOT change the buyer API, the SPEC-015 v0.4 receipt tuple, settlement verifier behavior, or coordinator routing policy.

---

## 1. Mission

MacProvider serves MLX models from Apple Silicon contributors. The current Phase 3 binary calls `mlx-swift-lm` directly from Swift and generates tokens through `TokenIterator` plus `generate` in `ModelRuntime.swift`. The pinned Swift dependency already exposes speculative decoding, where a smaller compatible draft model proposes tokens and the target model verifies them.

SPEC-028 defines the first locked surface for wiring that primitive into `macprovider-cli serve` as an opt-in operator performance feature.

Non-normative motivation: the 2026-07-03 leyten/shard technical report measured a large draftable-text throughput gap on consumer hardware. That result is not the same mechanism as MLX linear speculative decoding, but it is enough evidence to justify a MacProvider-native research and benchmark track.

---

## 2. Scope

### In scope

- New provider `serve` config for target/draft speculative decoding.
- Draft model compatibility validation.
- Greedy-only v0.1 request gating.
- Provider aggregate acceptance-rate telemetry.
- Warm-swap lifecycle rules for draft models.
- Autotune/candidate-catalog extension points.

### Non-goals

- No buyer API field, flag, or routing parameter.
- No SPEC-015 v0.4 receipt tuple change.
- No settlement verifier schema change.
- No coordinator routing preference change.
- No tree-verification or shard-style multi-branch algorithm.
- No stochastic speculative decoding until a later SPEC defines canary/equivalence policy.
- No gpt-oss draft-model support in v0.1. `mlx-community/gpt-oss-20b-MXFP4-Q8` continues to serve non-speculatively. A same-tokenizer, license-clean smaller draft candidate is a follow-up SPEC concern and MUST NOT block v0.1 LOCK.
- No `draft_model_hash` field in heartbeat or receipts in v0.1. Draft-model *ID* plus acceptance counters (FR-8) is sufficient; adding a hash would require a SPEC-011 amendment and is deferred until a future coordinator routing SPEC needs it.

---

## 3. Normative Requirements

### FR-1. Disabled-mode baseline

When `draft_model` is unset after config resolution, the provider MUST keep using the existing non-speculative generation path:

- Non-streaming: `TokenIterator(input:model:cache:parameters:)` followed by `generate`.
- Streaming: the same non-speculative iterator/generate path.
- No spec-decode telemetry fields are emitted except where this SPEC explicitly requires a nullable/false disabled value on `/v1/status` or heartbeat after the feature is implemented.

No buyer-visible JSON response, SSE frame, token count, receipt tuple, or error envelope may change in this disabled mode.

### FR-2. CLI flags

`macprovider-cli serve` MUST add:

| Flag | Type | Default | Validation |
|---|---|---|---|
| `--draft-model <id-or-path>` | string | unset | Non-empty when present. May be HuggingFace ID or local path, matching `--model` resolution style. |
| `--num-draft-tokens <N>` | integer | `3` when `draft_model` is set | `1 <= N <= 16`; invalid values fail serve preflight with exit code 2. |

These flags MUST follow the existing serve-knob override style used by `--kv-bits`, `--max-context`, and `--max-batch`.

### FR-3. Config and environment schema

The provider's flat config schema MUST add:

| YAML key | Env var | CLI override |
|---|---|---|
| `draft_model` | `MACPROVIDER_DRAFT_MODEL` | `--draft-model` |
| `num_draft_tokens` | `MACPROVIDER_NUM_DRAFT_TOKENS` | `--num-draft-tokens` |

Precedence MUST remain CLI over environment over YAML over default. `num_draft_tokens` without `draft_model` is accepted but inert; implementations SHOULD log one operator-facing warning at startup.

### FR-4. Runtime load and compatibility check

When `draft_model` is configured, serve startup MUST:

1. Load the target model exactly as today.
2. Load the draft model into a separate container/cache context.
3. Verify tokenizer compatibility before accepting buyer traffic.
4. Run a minimal speculative-generation probe at `temperature=0`, `max_tokens=1`, and `num_draft_tokens=1`.
5. Fail startup if the draft model cannot load, tokenizer compatibility cannot be proven, or the speculative probe fails.
6. Refresh `ProviderCapacity` effective headroom (max context, batch, working-set) to reflect the second resident model. The current default context — 20k on 8 GB machines — is set without knowledge of a second resident model (`ProviderStatus.swift:23-37`), so leaving it unchanged over-admits traffic. If the resulting refresh drops effective `max_context` below the SPEC-013 candidate row's minimum, serve preflight MUST fail with a `draft_model_capacity_shortfall` (or equivalent stable code).

The failure MUST be loud and local: nonzero process exit, structured error log, and no partial admission to the coordinator as spec-decode enabled.

### FR-5. Request gating

In v0.1, speculative decoding MUST run only when all conditions hold:

- `draft_model` is configured and compatibility-checked.
- The request's parsed `temperature` is exactly `0.0`.
- The request is not using a runtime feature the implementation cannot prove compatible with Swift speculative generation.

Requests with `temperature > 0.0` MUST use the existing non-speculative path. This is required because the buyer controls `temperature`, MacProvider currently defaults it to `1.0`, and v0.1 does not define stochastic equivalence.

### FR-6. Swift primitive

The implementation MUST use the pinned `mlx-swift-lm` speculative decoding API, not shell out to Python `mlx_lm.server` or `mlx_lm.generate`.

The implementation SHOULD use `generate(input:cache:parameters:context:draftModel:draftCache:numDraftTokens:)` or the equivalent `SpeculativeTokenIterator` pathway exposed by `mlx-swift-lm` 3.31.4.

### FR-7. Usage and receipt invariants

SPEC-028 MUST NOT add any field to SPEC-015 v0.4 settlement `usage`. The receipt tuple and verifier strict key sets remain owned by SPEC-015.

Spec decode accepted/drafted tokens are implementation telemetry, not billable usage. Billable and observed token counts continue to mean target input/output tokens only.

### FR-8. Provider aggregate telemetry

The provider runtime MUST aggregate speculative-decoding counters over the same provider metrics window used for request/tps heartbeat fields.

Required fields:

| Field | Type | Semantics |
|---|---|---|
| `spec_decode_enabled` | boolean | True when a compatible draft model is loaded and eligible for greedy requests. |
| `spec_decode_draft_model_id` | string or null | Configured draft model ID/path after resolution, or null when disabled. |
| `spec_decode_num_draft_tokens` | integer or null | Active draft-token count, or null when disabled. |
| `spec_decode_drafted_tokens_since_last` | integer | Draft tokens proposed in the current metrics window. |
| `spec_decode_accepted_tokens_since_last` | integer | Draft tokens accepted by target verification in the current metrics window. |
| `spec_decode_acceptance_rate` | number or null | `accepted / drafted` for the current metrics window; null when no draft tokens were attempted. |

These fields MUST appear on `/v1/status`. They MAY appear on heartbeat in the same implementation round; if heartbeat fields are included, they MUST use the exact names above.

### FR-9. Warm-swap lifecycle

When warm swap is disabled, the draft model lifecycle is bound to process startup and shutdown.

When warm swap is enabled:

1. Draft compatibility is bound to the target model.
2. While a new target is loading, new requests MUST run non-speculative unless a compatible draft for that target is already loaded and verified.
3. In-flight requests MUST keep using the target/draft pair associated with their captured runtime snapshot.
4. A draft-load failure during target swap MUST NOT roll back a successful target swap. The provider MUST continue serving the target non-speculatively and set `spec_decode_enabled=false`.
5. On every target-swap boundary the `spec_decode_drafted_tokens_since_last` and `spec_decode_accepted_tokens_since_last` counters MUST reset to zero, so `spec_decode_acceptance_rate` never blends pre-swap and post-swap draft populations. The heartbeat window immediately following a swap MAY report `spec_decode_acceptance_rate=null` if no draft tokens were attempted post-swap.
6. SPEC-011 target `model_hash` semantics remain unchanged. Draft model hash is not required by SPEC-028 v0.1.

### FR-10. Supported models and catalog posture

`supported_models[]` continues to describe target models the provider is willing to serve. It MUST NOT be overloaded to include draft model IDs.

If a future coordinator or UI needs draft capability discovery, it must read the explicit SPEC-028 telemetry fields, not infer from `supported_models[]`.

### FR-11. Autotune extension

SPEC-013 autotune MAY gain an outer-loop draft-pair selection step. It MUST NOT blindly multiply every existing context/concurrency/kv cell by every draft candidate.

Static candidate rows MAY add:

```json
"draft_candidates": [
  {
    "model_id": "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
    "default_num_draft_tokens": 3,
    "min_extra_ram_gb": 2,
    "workload_bias": ["code_completion", "agent_style"]
  }
]
```

The serving implementation does not depend on autotune shipping first.

---

## 4. Compatibility Matrix

The following candidate pairs are approved for benchmark exploration, not LOCKED production defaults:

| Family | Target | Drafts |
|---|---|---|
| Qwen2.5 Instruct | `mlx-community/Qwen2.5-7B-Instruct-4bit` | `mlx-community/Qwen2.5-1.5B-Instruct-4bit`, `mlx-community/Qwen2.5-0.5B-Instruct-4bit` |
| Qwen2.5 Coder | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit` |
| Qwen3 | `mlx-community/Qwen3-32B-4bit` | `mlx-community/Qwen3-1.7B-4bit`, `mlx-community/Qwen3-0.6B-4bit` |
| Qwen3 Coder | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `mlx-community/Qwen3-1.7B-4bit`, `mlx-community/Qwen3-0.6B-4bit` |
| Llama | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `mlx-community/Llama-3.2-3B-Instruct-4bit`, `mlx-community/Llama-3.2-1B-Instruct-4bit` |
| Llama small-Air | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `mlx-community/Llama-3.2-1B-Instruct-4bit` |

The current gpt-oss catalog row has no confirmed smaller same-family draft candidate. SPEC-028 remains draft until that is either resolved or explicitly waived.

---

## 5. Acceptance Criteria

**AC-1. Disabled baseline.** Start `serve` without `--draft-model`; a representative non-streaming and streaming request produces byte-identical response shape and usage fields compared with pre-SPEC-028.

**AC-2. Config precedence.** YAML `draft_model`, env `MACPROVIDER_DRAFT_MODEL`, and CLI `--draft-model` resolve in the standard CLI > env > YAML order. Same for `num_draft_tokens`.

**AC-3. Validation.** `--num-draft-tokens 0`, `--num-draft-tokens -1`, and `--num-draft-tokens 17` fail at serve preflight with exit code 2.

**AC-4. Tokenizer mismatch.** A known-incompatible target/draft pair fails before coordinator admission with `draft_model_tokenizer_mismatch` or an equivalent stable error code.

**AC-5. Greedy gate.** With a compatible draft configured, a request with `"temperature": 0` uses speculative generation and updates accepted/drafted telemetry. The same request with `"temperature": 0.7` completes through the non-speculative path and does not increment draft counters.

**AC-6. Receipt invariant.** With SPEC-015 receipts enabled, the settlement receipt `usage` object contains exactly the v0.4 five fields and no speculative counters.

**AC-7. Status telemetry.** `/v1/status` includes all FR-8 fields with correct disabled, enabled/no-window, and enabled/after-request values.

**AC-8. Heartbeat telemetry.** If the implementation emits FR-8 fields on heartbeat, a mock coordinator accepts them without changing routing behavior.

**AC-9. Warm-swap target coupling.** During a warm swap, requests started before the swap finish on their captured target/draft pair; requests accepted while the new draft is not ready run non-speculatively.

**AC-10. First performance canary (ratio + thermal window).** On air5 or equivalent 16 GB Apple Silicon, with target `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, draft `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit`, workload `code_completion`, seed prompt `spec028-code-iso8601-v1`, `temperature=0`, `max_tokens=240`, `num_draft_tokens=3`:

1. **Ratio floor (not absolute tok/s).** Immediately before the spec-decode run, capture the median non-spec generation throughput over 5 warm runs at the same target/prompt/params (`baseline_tps`). Median spec-decode throughput over 5 warm runs MUST be at least `1.4 * baseline_tps`. This replaces v0.1's absolute 24 tok/s floor, which drifts across mlx-swift-lm releases and macOS updates.
2. **Acceptance floor.** `spec_decode_acceptance_rate` MUST be non-null and at least 0.30 over the same 5 runs.
3. **Sustained thermal window.** After the paired 5-run comparison, run the spec-decode configuration back-to-back for at least 5 minutes of continuous generation. Median throughput measured over the *last minute* of that window MUST remain at least `1.2 * baseline_tps`. This guards against acceptance-driven token throughput heat-soaking the device into thermal throttle — a failure mode the short warm-run measurement will not surface.

If target model availability blocks this exact canary, the implementing PR MUST record the substituted Qwen2.5 Coder 7B-compatible target/draft pair and keep the same ratios and window unless a maintainer approves a change.

**AC-11. Small-Air canary.** On M1 8 GB, target `mlx-community/Llama-3.2-3B-Instruct-4bit` plus draft `mlx-community/Llama-3.2-1B-Instruct-4bit` MUST complete `short_chat` and `streaming_check` at `temperature=0` without Metal OOM or process crash.

---

## 6. Open Questions

### Resolved in v0.2

- **~~gpt-oss draft candidate~~** — waived from v0.1 (see §2 Non-goals). Follow-up SPEC only.
- **~~Greedy-only v0.1 gate~~** — confirmed: FR-5 restricts spec decode to `temperature == 0.0`. Stochastic support belongs to a later SPEC with its own equivalence canary.
- **~~SPEC-011 draft-hash amendment~~** — confirmed not required for v0.1: heartbeat/status carry `spec_decode_draft_model_id` plus counters (FR-8); no `draft_model_hash` field is added.
- **~~AC-10 absolute-tok/s threshold~~** — replaced by the ratio-plus-thermal-window formulation now written into AC-10.

### Still open (do not block LOCK on these unless flagged)

1. Which model-card license approvals are required before publishing Qwen/Llama draft recommendations in the static catalog? (Blocks SPEC-013 `draft_candidates[]` publication, not SPEC-028 LOCK.)
2. Should the first LOCK gate add a stricter plain-vs-spec token-equivalence canary for Qwen3, given current upstream MLX-LM divergence issues? Default posture: keep Qwen3 out of the AC-10 canary until upstream issues 846/1423/1446 resolve or a MacProvider-side equivalence test lands.

---

## 7. Implementation Notes for Future Build Prompt

Implementation will likely touch:

- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- `phase3-binary/Sources/MacProviderCore/Config.swift`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- tests for config precedence, runtime gating, status/heartbeat telemetry, receipts, and warm-swap lifecycle.

Those edits are out of scope for this research branch.

## 8. Implementation Sequencing (recommended, non-normative)

Implementation is proposed as three bundled PRs to keep the three-lane codex audit surface tight per PR. A single-PR implementation is acceptable if audit lanes stay green.

**PR-A — Plumbing (FR-1..FR-4, FR-6, FR-7, FR-10; AC-1..AC-4, AC-6, AC-11).**
CLI/env/YAML config, target+draft load, tokenizer compatibility check, `ProviderCapacity` headroom refresh (FR-4.6), Swift primitive wiring, disabled-mode byte-identity, receipt invariant, `supported_models[]` non-overload. Small-Air load canary (AC-11). Audit focus: precedence, load-failure loudness, disabled-mode identity, receipt schema.

**PR-B — Telemetry and greedy gate (FR-5, FR-8; AC-5, AC-7, AC-8, AC-10).**
`temperature==0` gate, `/v1/status` fields, aggregate counters. Heartbeat fields SHOULD ship behind an operator opt-in flag until a coordinator-side SPEC accepts them, to avoid a schema-compat drift on `CoordinatorClient` heartbeat. AC-10 ratio-plus-thermal-window canary lives here. Audit focus: counter arithmetic under mixed greedy/stochastic traffic, `null` semantics, buyer-response non-mutation.

**PR-C — Warm-swap lifecycle (FR-9; AC-9).**
Draft lifecycle coupled to target snapshot, in-flight pair pinning, counter reset on swap boundary. Highest state-machine risk. Audit focus: swap-boundary races, in-flight-request affinity, `spec_decode_enabled` transitions.

FR-11 (autotune `draft_candidates[]`) is a separate SPEC-013 amendment, not part of this SPEC's implementation.
