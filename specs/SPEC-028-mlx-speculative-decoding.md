# SPEC-028 — MLX Speculative Decoding for Provider Serve

**Version:** 0.2-draft
**Status:** Draft doc — but IMPLEMENTED IN CODE. Speculative decoding shipped via PR-C (#399) and benchmark-evidence work (#402) on 2026-07-05+ (`--draft-model`/`--num-draft-tokens`, `CompiledDecode`, `spec028-canary`/`spec028-benchmark` subcommands, spec-decode heartbeat telemetry). The v0.2 "implementation MUST NOT begin before human review" gate was overtaken by events; this document needs a post-implementation revision to become the normative record of what actually shipped.
**Date drafted:** 2026-07-05
**Revision history:**
- v0.1 (2026-07-05): initial research-round draft.
- v0.2 (2026-07-05): greedy-only gate confirmed for v0.1; draft-model hash explicitly out of scope (no SPEC-011 amendment); gpt-oss waived from v0.1 compatibility; AC-10 reframed as ratio over measured baseline plus a sustained-thermal window; FR-4 gains a concrete `ProviderCapacity` headroom refresh and fixed plain-vs-spec equivalence fixture; FR-5 gains a v0.1 request-feature allowlist; FR-8 gates heartbeat telemetry behind an operator opt-in until a coordinator SPEC consumes it; FR-9 gains a counter-reset on warm-swap boundary; FR-12 defines fail-closed runtime speculative error handling.
**Depends on:** SPEC-001 v1.6 (`macprovider-cli serve`, OpenAI-compatible HTTP, heartbeat/status), SPEC-010 v1.5 (`supported_models[]` semantics), SPEC-011 v0.5 (warm-swap state machine and target `model_hash` heartbeat), SPEC-013 v0.3 (`autotune` serving knobs and static candidate catalog), SPEC-015 v0.4.2 (locked settlement receipt usage schema), `mlx-swift-lm` 3.31.4.

SPEC-028 is provider-side only. With no draft model configured, provider behavior MUST be byte-identical to the existing non-speculative serve path. SPEC-028 MUST NOT change the buyer API, the SPEC-015 v0.4 receipt tuple, settlement verifier behavior, or coordinator routing policy.

In this document, "v0.1" means the first implementation profile of SPEC-028, not the draft-document version number.

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
| `--draft-model <id-or-path>` | string | unset | Non-empty when present. May be HuggingFace ID or local path, matching `--model` resolution style, subject to the draft artifact provenance guard in FR-4 before coordinator admission. |
| `--draft-model-artifact-sha256 <hex>` | string | unset | Optional for local-only non-coordinator smoke runs; required for coordinator-joining or settlement-capable serve unless an explicit signed/static draft-candidate allowlist supplies the same binding. Must be lowercase hex SHA-256 when present. |
| `--num-draft-tokens <N>` | integer | `3` when `draft_model` is set | `1 <= N <= 16`; invalid values fail serve preflight with exit code 2. |
| `--publish-spec-decode-telemetry` | boolean | `false` | When false, SPEC-028 fields remain local to `/v1/status` and MUST NOT appear on heartbeat. When true, heartbeat MUST include FR-8 fields after coordinator compatibility is verified. |

These flags MUST follow the existing serve-knob override style used by `--kv-bits`, `--max-context`, and `--max-batch`.

### FR-3. Config and environment schema

The provider's flat config schema MUST add:

| YAML key | Env var | CLI override |
|---|---|---|
| `draft_model` | `MACPROVIDER_DRAFT_MODEL` | `--draft-model` |
| `draft_model_artifact_sha256` | `MACPROVIDER_DRAFT_MODEL_ARTIFACT_SHA256` | `--draft-model-artifact-sha256` |
| `num_draft_tokens` | `MACPROVIDER_NUM_DRAFT_TOKENS` | `--num-draft-tokens` |
| `publishes_spec_decode_telemetry` | `MACPROVIDER_PUBLISHES_SPEC_DECODE_TELEMETRY` | `--publish-spec-decode-telemetry` |

Precedence MUST remain CLI over environment over YAML over default. `num_draft_tokens` without `draft_model` is accepted but inert; implementations SHOULD log one operator-facing warning at startup.

### FR-4. Runtime load and compatibility check

When `draft_model` is configured, serve startup MUST:

1. Load the target model exactly as today.
2. Resolve and verify draft model artifact provenance before coordinator admission. When serve is running in a coordinator-joining or settlement-capable mode that requires target artifact verification, the draft model MUST be loaded from a verified local snapshot whose computed SHA-256 matches `draft_model_artifact_sha256`, or from an explicit signed/static draft-candidate allowlist tied to the target model that supplies the same artifact binding. If the current implementation has no signed draft-candidate allowlist, the only compliant v0.1 path is a verified local draft snapshot plus `draft_model_artifact_sha256`. Startup MUST fail with `draft_model_unverified_artifact` if the draft artifact provenance is unavailable or weaker than the target-model provenance required for the same serve mode. This guard is internal preflight state only; it does not add a `draft_model_hash` heartbeat or receipt field in SPEC-028 v0.1.
3. Load the draft model into a separate container/cache context.
4. Verify tokenizer compatibility before accepting buyer traffic.
5. Run a minimal speculative-generation probe at `temperature=0`, `max_tokens=1`, and `num_draft_tokens=1`.
6. Fail startup if the draft model cannot load, tokenizer compatibility cannot be proven, or the speculative probe fails.
7. Refresh `ProviderCapacity` effective headroom (max context, batch, working-set) to reflect the second resident model. The current default context — 20k on 8 GB machines — is set without knowledge of a second resident model (`ProviderStatus.swift:23-37`), so leaving it unchanged over-admits traffic. The deterministic v0.1 rule is:
   - `requested_context_tokens = resolved.max_context_override ?? ProviderCapacity.defaultForRamTier`. If the helper does not exist in code yet, the implementing PR MUST add it as a pure function returning the existing tier defaults from `ProviderCapacity.init` (8 GB -> 20000, 16 GB -> 50000, 32 GB -> 120000, 64 GB+ -> 200000).
   - `draft_context_cap = 8192` on 8 GB tier, `20000` on 16 GB tier, `50000` on 32 GB tier, and `120000` on 64 GB+ tier.
   - `effective_max_context_tokens = min(requested_context_tokens, draft_context_cap)`.
   - `effective_max_batch = 1` for all draft-enabled v0.1 providers, regardless of any higher `max_concurrency_override`, because current production history already treats concurrent MLX inference as unsafe.
   - `/v1/status`, heartbeat, coordinator auth admission, legacy coordinator hello admission, and local preflight MUST advertise/enforce the effective values, not the unrefreshed defaults.
   - Serve preflight MUST fail with `draft_model_capacity_shortfall` when the operator explicitly requested `max_context_override` above the effective cap. v0.1 has no override for this downshift. This avoids silently advertising a larger context window than target+draft can safely host.
   - Serve preflight MUST fail with `draft_model_capacity_shortfall` when the operator explicitly requested `max_concurrency_override > 1`. Default or unspecified concurrency still downshifts to `effective_max_batch = 1`.
8. Run a plain-vs-spec token-equivalence canary for the configured target/draft pair before coordinator admission. The implementing PR MUST add the fixed fixture at `phase3-binary/Tests/Fixtures/spec028/equivalence-smoke-v1.json` with this exact request content:

   ```json
   {
     "fixture_id": "spec028-equivalence-smoke-v1",
     "messages": [
       {
         "role": "system",
         "content": "You are a deterministic coding assistant. Answer with concise plain text only."
       },
       {
         "role": "user",
         "content": "Write a Swift function named iso8601DayPrefix that returns the first 10 characters of an ISO-8601 timestamp if present, otherwise returns nil."
       }
     ],
     "temperature": 0,
     "top_p": 1.0,
     "max_tokens": 64,
     "stream": false,
     "response_format": { "type": "text" }
   }
   ```

   The canary MUST load the fixture bytes rather than synthesize a prompt, MUST run with no conversation-cache reuse, no tools, no structured response format, and no streaming, and MUST compare generated token IDs, not decoded text. If the token ID sequence differs, serve startup MUST fail with `draft_model_equivalence_failed` and MUST NOT fall back silently to spec-decode-enabled serving.

The failure MUST be loud and local: nonzero process exit, structured error log, and no partial admission to the coordinator as spec-decode enabled.

### FR-5. Request gating

**Temporary production safety override (2026-08-09):** upstream
`mlx-swift-lm` issue #424 shows that rejection rollback may corrupt state after a
rotating/sliding KV cache wraps. Until a tagged upstream fix and the real
cache-wrap token/settlement parity canary pass, production `serve` MUST report
speculative decode disabled and route every request through ordinary target-only
decode, even when the v0.1 conditions below hold. A dedicated future
boundary-crossing parity harness tracked in #377 must produce exact token,
settlement, stop-reason, and artifact-provenance evidence before the production
gate can reopen; existing benchmark/canary commands remain inside the safe cache
window and are not production enablement paths.

In v0.1, speculative decoding MUST run only when all conditions hold:

- `draft_model` is configured and compatibility-checked.
- The request's parsed `temperature` is exactly `0.0`.
- The request is in the v0.1 allowlist:
  - no top-level `tools` entries;
  - no top-level `tool_choice` other than absent/null/default none; explicit `"auto"` is outside the v0.1 allowlist even when `tools` is absent;
  - no prompt messages with role `tool`;
  - no assistant prompt messages containing `tool_calls`;
  - parsed `responseFormat` is plain text; absent `response_format` and explicit `{"type":"text"}` are allowed, JSON object/schema formats are not;
  - no logprobs/top-logprobs output request; `logprobs` may be absent, null, or false, and `top_logprobs` must be absent or null;
  - `logit_bias` is absent or null;
  - no presence or frequency penalty other than `0.0`;
  - `top_p == 1.0`;
  - no conversation-cache reuse for the first implementation PR unless the implementation also adds a plain-vs-spec equivalence canary that exercises the cached path.

Requests outside that allowlist MUST use the existing non-speculative path and MUST NOT increment spec-decode drafted/accepted counters. This is required because the buyer controls `temperature`, MacProvider currently defaults it to `1.0`, and v0.1 does not define stochastic equivalence.

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
| `spec_decode_draft_model_id` | string or null | Public HuggingFace model ID or a non-reversible redacted local alias for the configured draft model, or null when disabled. Raw local filesystem paths and basename-derived local aliases MUST NOT be emitted on `/v1/status` or heartbeat. Local aliases MUST use at least 128 bits of digest entropy, such as `local:<first-32-hex-of-sha256(canonical-path)>`, or a keyed/salted non-reversible equivalent. |
| `spec_decode_num_draft_tokens` | integer or null | Active draft-token count, or null when disabled. |
| `spec_decode_drafted_tokens_since_last` | integer | Draft tokens proposed in the current metrics window. |
| `spec_decode_accepted_tokens_since_last` | integer | Draft tokens accepted by target verification in the current metrics window. |
| `spec_decode_acceptance_rate` | number or null | `accepted / drafted` for the current metrics window; null when no draft tokens were attempted. |

These fields, and only these SPEC-028 fields, MUST appear on `/v1/status` as provider-status observability, not as a buyer API extension. SPEC-028 telemetry MUST NOT include buyer prompt/output content, account identifiers, request IDs, raw receipt material, receipt-sensitive state, or per-request rows. Heartbeat emission is opt-in in v0.1: the fields MUST NOT appear on heartbeat unless the operator enables `--publish-spec-decode-telemetry` / `publishes_spec_decode_telemetry` and a coordinator compatibility check has accepted the extra keys. When that flag is enabled and the compatibility check passes, heartbeat emission of all FR-8 fields is REQUIRED; if the compatibility check fails, serve preflight MUST fail with `spec_decode_heartbeat_incompatible` rather than silently run with the requested publish flag ignored. The v0.1 compatibility predicate is an implementation test against the current coordinator heartbeat decoder/state-update path if it is available in this repository; otherwise it MUST use a fixture generated from the current coordinator heartbeat JSON schema, not an invented parser. The test MUST decode a heartbeat containing the FR-8 fields as an unknown-key-tolerant JSON object, preserve the provider session, preserve existing heartbeat metrics, and make no routing/trust/settlement/admission transition from those fields. No runtime negotiation or coordinator ACK is required in SPEC-028. Until a future coordinator-side SPEC consumes these fields, the coordinator MUST NOT make routing, trust, settlement, or admission decisions from them; they are self-reported observability only.

### FR-9. Warm-swap lifecycle

When warm swap is disabled, the draft model lifecycle is bound to process startup and shutdown.

When warm swap is enabled:

1. Draft compatibility is bound to the target model.
2. While a new target is loading, new requests MUST run non-speculative unless a compatible draft for that target is already loaded and verified.
3. In-flight requests MUST keep using the target/draft pair associated with their captured runtime snapshot.
4. A draft-load failure during target swap MUST NOT roll back a successful target swap. The provider MUST continue serving the target non-speculatively and set `spec_decode_enabled=false`.
5. Spec-decode counters MUST be tagged internally by the target/draft generation captured at request start. On every target-swap boundary the current-window `spec_decode_drafted_tokens_since_last` and `spec_decode_accepted_tokens_since_last` counters MUST reset to zero, so `spec_decode_acceptance_rate` never blends pre-swap and post-swap draft populations. Late completions from the old generation MUST NOT increment the new current-window counters; they MAY be recorded in an internal closed-generation bucket that is not emitted on heartbeat/status. The heartbeat window immediately following a swap MAY report `spec_decode_acceptance_rate=null` if no draft tokens were attempted post-swap.
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

### FR-12. Runtime speculative error handling

After startup admission, a speculative-generation error for an allowlisted request MUST fail closed:

1. If the error occurs before any buyer-visible token, SSE frame, receipt state, or request-log terminal state is emitted, the provider MAY retry the request once on the existing non-speculative target path. That retry MUST use the same request snapshot target model/hash and MUST NOT carry over partial draft cache state.
2. If the error occurs after any buyer-visible token or SSE frame is emitted, the provider MUST NOT retry or stitch output across speculative and non-speculative paths. It MUST terminate through the existing SPEC-001 error/streaming terminal path for inference errors.
3. Spec-decode drafted/accepted counters MUST NOT be incremented for failed speculative attempts unless the target verification completed and the implementation can attribute counters without mixing failed/retried output. v0.1 implementations SHOULD count only successful final completions.
4. SPEC-015 receipts, when enabled, MUST bind only the final target-generated output and the existing v0.4 five-field usage object. A request MUST NOT emit a settlement receipt for output assembled across a failed speculative attempt and a fallback retry.

---

## 4. Compatibility Matrix

The following candidate pairs are approved for benchmark exploration, not LOCKED production defaults:

| Family | Target | Drafts |
|---|---|---|
| Qwen2.5 Instruct | `mlx-community/Qwen2.5-7B-Instruct-4bit` | `mlx-community/Qwen2.5-1.5B-Instruct-4bit`, `mlx-community/Qwen2.5-0.5B-Instruct-4bit` |
| Qwen2.5 Coder small-Air | `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` | `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit`, `mlx-community/Qwen2.5-Coder-0.5B-Instruct-4bit` |
| Qwen2.5 Coder | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit` |
| Qwen3 | `mlx-community/Qwen3-32B-4bit` | `mlx-community/Qwen3-1.7B-4bit`, `mlx-community/Qwen3-0.6B-4bit` |
| Qwen3 Coder | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `mlx-community/Qwen3-1.7B-4bit`, `mlx-community/Qwen3-0.6B-4bit` |
| Llama | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `mlx-community/Llama-3.2-3B-Instruct-4bit`, `mlx-community/Llama-3.2-1B-Instruct-4bit` |
| Llama small-Air | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `mlx-community/Llama-3.2-1B-Instruct-4bit` |

The current gpt-oss catalog row has no confirmed smaller same-family draft candidate. v0.2 explicitly waives gpt-oss from v0.1 spec-decode support; gpt-oss providers continue serving non-speculatively until a future SPEC names a compatible draft.

48 GB+ target/draft acceptance canaries are deliberately deferred from SPEC-028 v0.1. The 30B/32B pairs above are benchmark-exploration candidates only until a later implementation or SPEC-013 amendment adds large-host acceptance evidence.

---

## 5. Acceptance Criteria

**AC-1. Disabled baseline.** Start `serve` without `--draft-model`; a representative non-streaming and streaming request produces byte-identical response shape and usage fields compared with pre-SPEC-028.

**AC-2. Config precedence.** YAML `draft_model`, env `MACPROVIDER_DRAFT_MODEL`, and CLI `--draft-model` resolve in the standard CLI > env > YAML order. Same for `draft_model_artifact_sha256`, `num_draft_tokens`, and `publishes_spec_decode_telemetry`.

**AC-3. Validation.** `--num-draft-tokens 0`, `--num-draft-tokens -1`, and `--num-draft-tokens 17` fail at serve preflight with exit code 2.

**AC-4. Tokenizer/equivalence mismatch.** A known-incompatible target/draft pair fails before coordinator admission with `draft_model_tokenizer_mismatch` or an equivalent stable error code. A tokenizer-compatible pair whose `phase3-binary/Tests/Fixtures/spec028/equivalence-smoke-v1.json` token IDs diverge between plain and spec generation fails before coordinator admission with `draft_model_equivalence_failed`.

**AC-5. Greedy and feature gate.** With a compatible draft configured, a request with `"temperature": 0`, `top_p: 1.0`, no top-level tools/tool choice, no prompt `tool` role or assistant `tool_calls`, plain text response format, no logprobs/top-logprobs output request, no `logit_bias`, no penalties, and no conversation-cache reuse uses speculative generation and updates accepted/drafted telemetry. The same request with `"temperature": 0.7`, non-default `top_p`, tools/tool choice/tool-call history, explicit `tool_choice: "auto"` even without `tools`, JSON response format, `logprobs: true`, non-null `top_logprobs`, non-null `logit_bias`, penalties, or cache reuse completes through the non-speculative path and does not increment draft counters.

**AC-6. Receipt invariant.** With SPEC-015 receipts enabled, the settlement receipt `usage` object contains exactly the v0.4 five fields and no speculative counters.

**AC-7. Status telemetry.** `/v1/status` includes all FR-8 fields with correct disabled, enabled/no-window, and enabled/after-request values.

**AC-8. Heartbeat telemetry.** By default, heartbeat omits FR-8 fields. When the operator enables the SPEC-028 heartbeat telemetry flag, the current coordinator heartbeat decoder/state-update path, or a fixture generated from its current heartbeat JSON schema when that path is unavailable to the binary test target, accepts the extra fields without changing routing behavior, trust state, settlement state, or admission state. With the flag enabled and compatibility accepted, `CoordinatorClient.sendHeartbeat` or its test seam MUST emit all FR-8 fields; with the flag disabled, it MUST emit none of them.

**AC-9. Warm-swap target coupling.** During a warm swap, requests started before the swap finish on their captured target/draft pair; requests accepted while the new draft is not ready run non-speculatively.

**AC-9a. Runtime speculative failure.** A harness-injected speculative error before first output may retry once non-speculatively and must emit counters/receipt only for the final non-spec output. A harness-injected speculative error after the first streaming chunk must not retry or stitch output; it must terminate through the existing streaming error path and must not emit a settlement receipt for mixed output.

**AC-10. First performance canary (ratio + thermal window).** On air5 or equivalent 16 GB Apple Silicon, intentionally using the Qwen2.5 Coder pair rather than the current generic Qwen2.5 beta config, with target `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, draft `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit`, workload `code_completion`, seed prompt `spec028-code-iso8601-v1`, `temperature=0`, `max_tokens=240`, `num_draft_tokens=3`:

1. **Fixture.** `spec028-code-iso8601-v1` is a checked-in workload fixture containing the ISO-8601 parser prompt currently used as the `code_completion` fallback in `beta/workloads.py`; the implementing PR MUST add the stable fixture before running this AC, and MUST NOT use the time-varying corpus sampler for this canary.
2. **Ratio floor (not absolute tok/s).** Immediately before the spec-decode run, capture the median non-spec generation throughput over 5 warm runs at the same target/prompt/params (`baseline_tps`) in the same process shape used for the spec-decode run: target and draft are resident, but generation is forced down the non-speculative path for the baseline. Median spec-decode throughput over 5 warm runs MUST be at least `1.4 * baseline_tps`. This replaces v0.1's absolute 24 tok/s floor, which drifts across mlx-swift-lm releases and macOS updates.
3. **Acceptance floor.** `spec_decode_acceptance_rate` MUST be non-null and at least 0.30 over the same 5 runs.
4. **Sustained thermal window.** After the paired 5-run comparison, run the spec-decode configuration back-to-back for at least 5 minutes of continuous generation. Median throughput measured over the *last minute* of that window MUST remain at least `1.2 * baseline_tps`. This guards against acceptance-driven token throughput heat-soaking the device into thermal throttle — a failure mode the short warm-run measurement will not surface.

If target model availability blocks this exact canary, the implementing PR MUST record the substituted Qwen2.5 Coder 7B-compatible target/draft pair and keep the same ratios and window unless a maintainer approves a change.

AC-10 is a benchmark canary only. It does not require a SPEC-013 static catalog amendment or make Qwen2.5 Coder a production catalog dependency.

**AC-11. Small-Air canary.** On M1 8 GB, target `mlx-community/Llama-3.2-3B-Instruct-4bit` plus draft `mlx-community/Llama-3.2-1B-Instruct-4bit` MUST complete stable checked-in `short_chat` and `streaming_check` fixtures at `temperature=0` without Metal OOM or process crash. The implementing PR MUST pin these fixtures rather than using the time-varying corpus sampler.

**AC-12. Draft-enabled capacity canary.** Before a draft-enabled provider advertises a tier's FR-4 effective context cap through `/v1/status`, heartbeat, coordinator auth admission, legacy coordinator hello admission, or local preflight, the implementing PR MUST prove target+draft residency plus KV growth near that cap on representative hardware for that RAM tier. The canary MUST:

1. Run with target and draft resident, `effective_max_batch = 1`, and the exact effective context cap advertised for the tier.
2. Exercise a checked-in long-context fixture that reaches at least 90% of the advertised cap before generation, then generate at least 32 target-verified output tokens at `temperature=0`.
3. Record peak resident memory, whether Metal OOM occurred, and the final advertised effective cap.
4. Fail the implementation PR for that RAM tier if the run OOMs, crashes, or cannot generate the output tokens.

For the first implementation profile, the 8 GB tier MUST use a pinned long-context fixture based on the existing `long_context` workload shape. The 16 GB tier MUST add a pinned fixture or synthetic checked-in generator that reaches at least 18k input tokens before advertising the 20k draft cap. If a tier cannot be tested in the implementation PR, that tier MUST either keep speculative decoding disabled or advertise the largest lower cap that has passed this AC on that hardware class.

---

## 6. Open Questions

### Resolved in v0.2

- **~~gpt-oss draft candidate~~** — waived from v0.1 (see §2 Non-goals). Follow-up SPEC only.
- **~~Greedy-only v0.1 gate~~** — confirmed: FR-5 restricts spec decode to `temperature == 0.0`. Stochastic support belongs to a later SPEC with its own equivalence canary.
- **~~SPEC-011 draft-hash amendment~~** — confirmed not required for v0.1: heartbeat/status carry `spec_decode_draft_model_id` plus counters (FR-8); no `draft_model_hash` field is added.
- **~~AC-10 absolute-tok/s threshold~~** — replaced by the ratio-plus-thermal-window formulation now written into AC-10.
- **~~FR-4 capacity threshold ambiguity~~** — replaced by deterministic v0.1 draft context caps and an explicit operator-request downshift rule.
- **~~Plain-vs-spec equivalence guard~~** — added as a startup gate in FR-4 and AC-4 for every enabled target/draft pair.
- **~~Runtime speculative failure semantics~~** — FR-12 and AC-9a define when pre-output fallback is allowed and when post-output failures must terminate without stitching outputs or receipts.

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

**PR-A — Plumbing (FR-1..FR-4, FR-6, FR-7, FR-10, FR-12 startup portions; AC-1..AC-4, AC-6, AC-11, AC-12).**
CLI/env/YAML config, target+draft load, draft artifact provenance preflight, tokenizer compatibility check, `ProviderCapacity` headroom refresh (FR-4), Swift primitive wiring, disabled-mode byte-identity, receipt invariant, `supported_models[]` non-overload. Small-Air load canary (AC-11) is a load/minimal-generation proof with the draft resident; request-gating, acceptance-rate, and telemetry proof remain in PR-B. Draft-enabled capacity canary (AC-12) must pass before PR-A advertises the reduced effective caps for any RAM tier. Audit focus: precedence, load-failure loudness, disabled-mode identity, receipt schema, capacity-admission evidence.

**PR-B — Telemetry, greedy gate, and runtime fallback (FR-5, FR-8, FR-12 request-path portions; AC-5, AC-7, AC-8, AC-9a, AC-10).**
`temperature==0` gate, request-feature allowlist, `/v1/status` fields, aggregate counters, and fail-closed speculative runtime errors. Heartbeat fields SHOULD ship behind an operator opt-in flag until a coordinator-side SPEC accepts them, to avoid a schema-compat drift on `CoordinatorClient` heartbeat. AC-10 ratio-plus-thermal-window canary lives here. Audit focus: counter arithmetic under mixed greedy/stochastic traffic, `null` semantics, buyer-response non-mutation, no stitched outputs across fallback.

**PR-C — Warm-swap lifecycle (FR-9; AC-9).**
Draft lifecycle coupled to target snapshot, in-flight pair pinning, counter reset on swap boundary. Highest state-machine risk. Audit focus: swap-boundary races, in-flight-request affinity, `spec_decode_enabled` transitions.

FR-11 (autotune `draft_candidates[]`) is a separate SPEC-013 amendment, not part of this SPEC's implementation.
