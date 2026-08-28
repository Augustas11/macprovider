# MLX Speculative Decoding Integration Research

**Date:** 2026-07-05
**Branch:** `research/spec-decode-serve`
**Requested by:** `specs/RESEARCH_SPEC_DECODE_PROMPT.md` from `/Users/augstar/macprovider-poc-spec-decode-prompt`

## Summary

MacProvider's current provider runtime calls `mlx-swift-lm` directly from Swift. It does not shell out to `mlx_lm.server` or `mlx_lm.generate`. The integration point is therefore the Swift `ModelRuntime` generation path, not the Python server. The pinned Swift dependency is `mlx-swift-lm` 3.31.4 (`phase3-binary/Package.swift:20-23`, `phase3-binary/Package.resolved:13-19`), and that package already exposes `generate(... draftModel:draftCache:numDraftTokens: ...)` plus `SpeculativeTokenIterator` telemetry.

The safe v0.1 shape is provider-side, opt-in, and buyer-invisible:

- Add `malibu-cli serve --draft-model <id-or-path>` and `--num-draft-tokens <N>`.
- Thread both through the flat config/env/CLI pattern used by `kv_bits`, `max_context_override`, and `max_concurrency_override`.
- Load the draft model beside the target runtime container, fail loudly on tokenizer/cache incompatibility, and fall back only when the operator explicitly disables spec decode.
- Report acceptance rate as aggregate provider telemetry on `/v1/status` and coordinator heartbeat, not in SPEC-015 v0.4 settlement receipts.
- Keep default behavior byte-identical: no draft model means the existing `TokenIterator` path remains active.

## Sources Checked

Local code/spec anchors:

- CLI entry and serve flags: `phase3-binary/Sources/malibu-cli/MalibuCLI.swift:19-84`, `:131-153`.
- Config layering: `phase3-binary/Sources/MacProviderCore/Config.swift:19-74`, `:94-140`, `:309-357`, `:365-401`, `:427-469`.
- Runtime call site: `phase3-binary/Sources/malibu-cli/ModelRuntime.swift:1-8`, `:232-320`, `:667-790`, `:804-930`.
- Request temperature/top-p parse: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:42-55`.
- Provider capacity/status: `phase3-binary/Sources/malibu-cli/ProviderStatus.swift:12-39`, `:71-102`, `:149-168`.
- Heartbeat payload: `phase3-binary/Sources/malibu-cli/CoordinatorClient.swift:2059-2088`.
- Receipt/verifier strict usage schema: `phase3-binary/Sources/malibu-cli/ReceiptBuilder.swift:279-285`, `phase4-coordinator/internal/billing/settlement_verifier.go:35-49`, `:273-319`, `:348-354`, `:375-380`, `:511-519`.
- SPEC constraints: SPEC-001 `:167-193`, `:443-456`, `:1069-1096`, `:1316-1336`, `:1760-1820`, `:1933-1937`; SPEC-010 `:300-303`, `:333-369`, `:490-513`, `:861-879`; SPEC-011 `:110-125`, `:227-239`; SPEC-013 `:252-260`, `:927-929`; SPEC-015 `:1-5`, `:20-45`.
- Current static candidate catalog: `phase3-binary/dist/static/autotune-candidates.json:1`.
- Beta workload and Air configs: `beta/workloads.py:26-34`, `:88-240`; `beta/config-m1.yaml:7-23`; `beta/config-m4.yaml:7-21`; `beta/DECISION_CRITERIA.md:54-76`, `:254-264`.

External upstream anchors:

- Python server request fields: <https://raw.githubusercontent.com/ml-explore/mlx-lm/main/mlx_lm/SERVER.md> documents `draft_model` and `num_draft_tokens`.
- Python generator flags and algorithm: <https://raw.githubusercontent.com/ml-explore/mlx-lm/main/mlx_lm/generate.py>.
- Swift pinned implementation: <https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/3.31.4/Libraries/MLXLMCommon/Evaluate.swift>.
- Current upstream risk reports: <https://github.com/ml-explore/mlx-lm/issues/846>, <https://github.com/ml-explore/mlx-lm/issues/1423>, <https://github.com/ml-explore/mlx-lm/issues/1446>.

## A. Serve-Path Integration

### Current Call Graph

```text
malibu-cli serve
  -> ServeCommand options
     phase3-binary/Sources/malibu-cli/MalibuCLI.swift:19-84
  -> AppConfig resolution
     phase3-binary/Sources/MacProviderCore/Config.swift:309-357
     phase3-binary/Sources/MacProviderCore/Config.swift:365-401
     phase3-binary/Sources/MacProviderCore/Config.swift:427-469
  -> HTTPServer starts local OpenAI-compatible API
     phase3-binary/Sources/malibu-cli/HTTPServer.swift:27-57
  -> POST /v1/chat/completions
     phase3-binary/Sources/malibu-cli/HTTPServer.swift:144-160
  -> ModelRuntime.completeWithServedSnapshot or stream
     phase3-binary/Sources/malibu-cli/ModelRuntime.swift:667-790
     phase3-binary/Sources/malibu-cli/ModelRuntime.swift:804-930
  -> mlx-swift-lm TokenIterator + generate
     phase3-binary/Sources/malibu-cli/ModelRuntime.swift:737-738
     phase3-binary/Sources/malibu-cli/ModelRuntime.swift:891-893
```

The provider imports `MLX`, `MLXLLM`, `MLXHuggingFace`, and `MLXLMCommon` directly (`ModelRuntime.swift:1-8`). It creates `GenerateParameters` in Swift (`ModelRuntime.swift:710-716`, `:860-866`), then instantiates `TokenIterator` and calls `generate` (`:737-738`, `:891-893`). That means the SPEC should target `mlx-swift-lm`, not the Python `mlx_lm.server` surface.

### Upstream Primitive Shape

The Python server now exposes request fields `draft_model` and `num_draft_tokens` in OpenAI-style requests. The Python CLI also exposes `--draft-model` and `--num-draft-tokens`; the generator has `speculative_generate_step(prompt, model, draft_model, num_draft_tokens=2, ...)` and rejects non-trimmable prompt caches.

The pinned Swift API has the native shape MacProvider needs:

- `SpeculativeTokenIterator(input:mainModel:draftModel:mainCache:draftCache:parameters:numDraftTokens:...)`.
- `generate(input:cache:parameters:context:draftModel:draftCache:numDraftTokens:...)`.
- `GenerateInfo.speculativeDecodingTelemetry`, including accepted/drafted counts.

The v0.1 implementation should use the Swift primitive because the repo is pinned to `mlx-swift-lm` 3.31.4 (`Package.swift:20-23`) and the runtime is already a Swift wrapper.

### Minimal Thread-Through

The new config should mirror existing serving knobs:

| Surface | Existing pattern | Spec-decode addition |
|---|---|---|
| CLI | `--kv-bits`, `--max-context`, `--max-batch` in `MalibuCLI.swift:77-84` | `--draft-model <id-or-path>`, `--num-draft-tokens <N>` |
| YAML | flat keys parsed in `Config.swift:332-341` | `draft_model`, `num_draft_tokens` |
| Env | `MACPROVIDER_KV_BITS`, `MACPROVIDER_MAX_CONTEXT_OVERRIDE` in `Config.swift:378-380` | `MACPROVIDER_DRAFT_MODEL`, `MACPROVIDER_NUM_DRAFT_TOKENS` |
| Runtime | `GenerateParameters(... kvBits: kvBitsOverride ...)` at `ModelRuntime.swift:710-716` | Load draft container, pass `draftModel`, `draftCache`, `numDraftTokens` to Swift speculative generate |
| Telemetry | `ProviderStatus.finishRequest` rolls request/tps windows at `ProviderStatus.swift:149-168` | Add accepted/drafted target-verified counters to the same provider aggregate window |

Preflight should follow the serve-knob fail-loud style in `MalibuCLI.swift:131-153`: reject `num_draft_tokens < 1`, reject draft-model equal to empty string, and reject configured draft model if it cannot be loaded with a compatible tokenizer/cache.

## B. Draft Model Compatibility

### Current Supported Targets

The current static autotune catalog contains:

- `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`, min RAM 28 GB.
- `mlx-community/gpt-oss-20b-MXFP4-Q8`, min RAM 24 GB.
- `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit`, min RAM 16 GB.
- `mlx-community/Qwen3-32B-4bit`, min RAM 48 GB.
- `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`, min RAM 48 GB.

The beta Air providers add real deployed targets:

- M1 8 GB: `mlx-community/Llama-3.2-3B-Instruct-4bit` (`beta/config-m1.yaml:7-13`).
- M4 16 GB: `mlx-community/Qwen2.5-7B-Instruct-4bit` (`beta/config-m4.yaml:7-8`).

### Compatibility Matrix

Memory estimates are intentionally coarse. They use 4-bit weight-size heuristics plus KV/cache/headroom; the implementing PR must measure resident memory and Metal working-set pressure.

| Family | Target | Draft candidate | Air fit estimate | License posture | Risk |
|---|---|---|---|---|---|
| Qwen2.5 Instruct | `mlx-community/Qwen2.5-7B-Instruct-4bit` | `mlx-community/Qwen2.5-1.5B-Instruct-4bit` | M4 16 GB likely fits; M1 8 GB not recommended | Qwen license family; maintainer must confirm model card | Good first canary |
| Qwen2.5 Instruct | `mlx-community/Qwen2.5-7B-Instruct-4bit` | `mlx-community/Qwen2.5-0.5B-Instruct-4bit` | M4 16 GB fits; M1 8 GB possibly fits but target 7B is not the M1 baseline | Same as above | Lower acceptance but lower memory |
| Qwen2.5 Coder | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` | 48 GB+ only | Qwen license family; maintainer must confirm | Strong code workload candidate |
| Qwen2.5 Coder | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit` | 48 GB+ likely fits with more headroom | Same as above | May under-draft complex code |
| Qwen3 | `mlx-community/Qwen3-32B-4bit` | `mlx-community/Qwen3-1.7B-4bit` | 48 GB+ only | Qwen3 model-card confirmation required | Public MLX-LM issues report Qwen spec-decode divergence |
| Qwen3 | `mlx-community/Qwen3-32B-4bit` | `mlx-community/Qwen3-0.6B-4bit` | 48 GB+ only | Same as above | Lower memory, lower likely acceptance |
| Qwen3 Coder | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `mlx-community/Qwen3-1.7B-4bit` | 32 GB may be tight; catalog min RAM is 28 GB before draft | Same as above | Tokenizer compatibility must be proven |
| Qwen3 Coder | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `mlx-community/Qwen3-0.6B-4bit` | 32 GB likely safer than 1.7B; M4 16 GB not recommended | Same as above | Acceptance unknown |
| Llama | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | M4 16 GB likely fits; M1 8 GB tight | Meta Llama license family; maintainer must confirm | Good general-chat canary |
| Llama | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `mlx-community/Llama-3.2-1B-Instruct-4bit` | M4 16 GB fits; may fit 8 GB with smaller context | Same as above | Lower acceptance |
| Llama | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `mlx-community/Llama-3.2-1B-Instruct-4bit` | M1 8 GB best small-Air canary | Same as above | Lower absolute speedup because target is already small |
| gpt-oss | `mlx-community/gpt-oss-20b-MXFP4-Q8` | none confirmed | Catalog min RAM 24 GB before draft | OpenAI model license terms must be reviewed | Human-blocking open question |

The Qwen and Llama rows satisfy the "two viable pairs per family" research bar. gpt-oss does not: no smaller same-family draft candidate was confirmed from local catalog evidence or upstream MLX naming. That must block LOCK or be explicitly waived.

### Air Variant Fit

The M1 8 GB provider uses a 3B 4-bit Llama target (`beta/config-m1.yaml:7-13`). It should only test `Llama-3.2-3B` plus a 1B draft at modest context. The first failure mode is unified-memory pressure and KV growth, not raw weight size; `ProviderCapacity` gives 8 GB machines a 20k default context (`ProviderStatus.swift:23-37`), which may be too optimistic once a second model is resident.

The M4 16 GB provider uses Qwen2.5 7B (`beta/config-m4.yaml:7-8`). It is the best first proving target: Qwen2.5 7B + 0.5B/1.5B draft should fit with enough memory to run the existing short, medium, code, agent, and streaming workloads (`beta/workloads.py:88-240`). Thermal pressure is still a real risk because accepted drafts increase generated-token throughput, so sustained high acceptance can heat-soak faster than baseline.

The 32B/30B catalog rows are not Air-class v0.1 canaries. They belong on 48 GB+ hosts because the static catalog already sets 28-48 GB floors before adding a draft (`autotune-candidates.json:1`).

### Tokenizer Compatibility

Python MLX-LM explicitly checks draft tokenizer vocabulary size and raises when it differs; the Swift API documents that the draft model must share a tokenizer. The MacProvider SPEC should require an implementation-side load check before accepting traffic:

- Load target tokenizer and draft tokenizer.
- Compare vocabulary size and canonical tokenizer identity if exposed by `swift-transformers`.
- Run a deterministic prompt through both processors and assert identical token IDs.
- If any check fails, `serve` exits nonzero with `draft_model_tokenizer_mismatch`.

This belongs at startup, not first buyer request, because `ServeCommand.runServingKnobsPreflight` already validates operator knobs at startup (`MalibuCLI.swift:131-153`).

## C. Losslessness Posture

MLX speculative decoding verifies drafted tokens with the target model and accepts only matching target tokens in the implementation. Swift also uses `ArgMaxSampler` when `temperature == 0` in `GenerateParameters.sampler()`. In theory, that makes greedy speculative decoding token-exact compared with normal greedy decoding.

MacProvider exposes buyer-controlled `temperature` and `top_p`: parse defaults and ranges are in `ChatCompletionRequest.swift:47-55`, and generation forwards them into `GenerateParameters` in both non-streaming and streaming paths (`ModelRuntime.swift:710-716`, `:860-866`). Because buyer temperature defaults to `1.0`, speculative decoding must not silently alter non-greedy output in v0.1.

Recommended v0.1 gate:

- Enable spec decode only when `request.temperature == 0.0` unless an operator sets an explicit future `--allow-stochastic-spec-decode` flag.
- Keep stochastic requests on the existing non-spec `TokenIterator` path.
- Add a coordinator-issued or local canary follow-up: run paired plain/spec requests at `temperature=0`, compare token IDs, and separately run a sampling-distance test before any stochastic enablement.

The canary should be a follow-up, not a v0.1 core requirement. Current upstream MLX-LM issues report Qwen skipped-token behavior, greedy divergence, and non-trimmable prompt-cache failures. Those are enough to keep the first SPEC conservative even if the pinned Swift API is cleaner than Python server behavior.

## D. Acceptance-Rate Visibility

SPEC-015 v0.4 settlement receipts are a bad home for acceptance counters. The settlement verifier requires a strict usage object with exactly:

- `billable_input_tokens`
- `billable_output_tokens`
- `delivered_output_bytes`
- `observed_input_tokens`
- `observed_output_tokens`

The strict key set appears in `settlement_verifier.go:45-49`, unknown keys cause `usage_shape_invalid` at `:378-380`, and the receipt builder emits only those five fields (`ReceiptBuilder.swift:279-285`). Adding `speculative_accepted_tokens` to settlement `usage` would break v0.4 verification.

Concrete field proposal:

| Field | Type | Semantics | Surface |
|---|---|---|---|
| `spec_decode_acceptance_rate` | JSON number in `[0,1]` or `null` | Rolling aggregate `accepted_draft_tokens / drafted_tokens` for completed provider requests in the current metrics window; `null` when disabled or no draft tokens were attempted | `/v1/status` and coordinator heartbeat |
| `spec_decode_drafted_tokens_since_last` | integer | Draft tokens proposed during the current heartbeat/status window | `/v1/status` and coordinator heartbeat |
| `spec_decode_accepted_tokens_since_last` | integer | Draft tokens accepted by target verification during the current heartbeat/status window | `/v1/status` and coordinator heartbeat |
| `spec_decode_enabled` | boolean | Runtime has a loaded draft model and is eligible to spec-decode greedy requests | `/v1/status` and coordinator heartbeat |
| `spec_decode_draft_model_id` | string or null | Configured draft model identifier; null when disabled | `/v1/status` and coordinator heartbeat |

The buyer should not see these fields per request. The existing OpenAI `usage` response shape in `HTTPServer.swift:1125-1132` should stay token/accounting focused. Operator/provider aggregates match the current heartbeat metrics style in `CoordinatorClient.swift:2059-2088`.

## E. Warm-Swap Interaction

Current warm-swap keeps one active target model and one current container in `ModelRuntime` (`ModelRuntime.swift:242-248`). It captures a request snapshot before inference (`:515-531`) and uses that snapshot for receipt binding (`:667-689`). Warm swap is opt-in and dormant by default per SPEC-011's lock-preserving gate (`SPEC-011:110-125`), and coordinator observation is heartbeat-based (`SPEC-011:227-239`).

Safe v0.1 behavior:

- Draft model is coupled to the target model.
- When target swap begins, new requests should run non-spec until the matching draft for the new target is loaded and compatibility-checked.
- The old target + old draft pair remains pinned for in-flight requests that already captured the old target snapshot.
- Failed draft load must not fail the target swap; it should leave the new target serving without spec decode and report `spec_decode_enabled=false` plus a draft-load error in local/operator logs.

If the coordinator needs both target and draft hashes, SPEC-011 is impacted. v0.1 should avoid requiring `draft_model_hash` for routing or settlement and should report only draft model ID + acceptance metrics. Model-hash settlement remains tied to the target container that served the request, as required by SPEC-015.

## F. Autotune Interaction

Speculative decoding is two decisions, not one flat axis:

1. Outer loop: choose a target/draft pair that is compatible and fits memory.
2. Inner loop: tune `num_draft_tokens` and existing serving knobs for that pair.

SPEC-013 already scopes autotune around a chosen target model and existing axes (`--kv-bits`, `--max-batch`, optional `--max-context`) (`SPEC-013:252-260`). Its output maps recommended knobs to config keys (`SPEC-013:927-929`). Spec decode should extend that model:

- Add optional candidate metadata to `autotune-candidates.json`: `draft_candidates[]` with `model_id`, `min_extra_ram_gb`, `default_num_draft_tokens`, and `workload_bias`.
- Treat draft choice as an outer filter over candidates, not as a full multiplication of every context/concurrency cell.
- For the chosen pair, evaluate a small `num_draft_tokens` axis, e.g. `{2,3,4,6}`, and stop early if acceptance falls below threshold or TPS regresses.

This avoids multiplying a 28-cell context/concurrency grid by every draft model and token count. Runtime cost is high because every draft candidate has a load/fetch/prewarm cost and doubles resident model memory. The static JSON should advertise draft-tuned candidates because the current file already carries model IDs, min RAM, benchmark gates, and notes in one operator-curated row (`autotune-candidates.json:1`).

## G. Coordinator Routing

Spec decode should not surface to the buyer API in v0.1. It is a provider-side throughput optimization, like KV-cache quantization and serving knob autotune. Buyer-visible output, token usage, receipts, and error envelopes should be unchanged.

The coordinator should learn about it through heartbeat/status telemetry, not buyer API fields:

- `spec_decode_enabled`
- `spec_decode_draft_model_id`
- `spec_decode_acceptance_rate`
- `spec_decode_drafted_tokens_since_last`
- `spec_decode_accepted_tokens_since_last`

Routing should not change in v0.1. A future coordinator SPEC could prefer spec-decoding providers for workload classes known to have high acceptance, especially `code_completion`, `agent_style`, and repeated long-context flows. The current workload taxonomy is already explicit in `beta/workloads.py:26-34`; the v0.1 SPEC should only define enough telemetry for later routing analysis.

## Risk Register

| Risk | Why it matters | Mitigation in SPEC-028 |
|---|---|---|
| 8 GB Air memory ceiling | M1 8 GB target+draft+KV may exceed unified-memory headroom before model weights alone fail | Require canary on Llama 3.2 3B + 1B only; require measured resident memory and fail-closed load |
| Tokenizer mismatch | Spec decode correctness requires target/draft token IDs to match | Startup compatibility check; fail before serving |
| Non-trimmable cache | Upstream speculative decode can reject caches that cannot rewind after rejected tokens | AC requires fallback/non-spec path and explicit load/probe failure |
| Qwen divergence | Public MLX-LM issues report Qwen skipped tokens and greedy divergence | v0.1 gates to `temperature=0` and requires plain-vs-spec token canary before LOCK |
| Warm-swap race | Draft may not match target after swap | Couple draft lifecycle to target snapshot; disable spec during load |
| Receipt schema break | SPEC-015 v0.4 usage schema is strict | Keep spec-decode counters out of receipt `usage` |
| Thermal pressure | High acceptance increases sustained token throughput and heat | Report aggregate acceptance/TPS; autotune must measure under workload windows, not one short run |

## Recommended SPEC-028 v0.1 Shape

1. Operator opt-in only; no default behavior change.
2. New flat config keys: `draft_model`, `num_draft_tokens`.
3. New env vars: `MACPROVIDER_DRAFT_MODEL`, `MACPROVIDER_NUM_DRAFT_TOKENS`.
4. New CLI flags: `--draft-model`, `--num-draft-tokens`.
5. Greedy-only v0.1 enablement unless a later canary validates stochastic equivalence.
6. Provider aggregate telemetry on `/v1/status` and heartbeat.
7. No SPEC-015 v0.4 receipt tuple change.
8. No buyer API or coordinator routing behavior change.

## Self-Review

- Wire-shape break: avoided for buyer API and SPEC-015 receipts; proposed fields are heartbeat/status additions only.
- Ambiguous FR risk: SPEC draft must define config precedence, validation ranges, and disabled-mode behavior explicitly.
- Undocumented dependencies: SPEC draft must cite SPEC-001, SPEC-010, SPEC-011, SPEC-013, SPEC-015, and pinned `mlx-swift-lm` 3.31.4.
- Warm-swap state: draft lifecycle must be coupled to target lifecycle; no persistent stale draft across target swaps.
- Acceptance-rate field: aggregate-only, not request usage; strict types and null behavior required.
- Open questions: gpt-oss draft candidate, stochastic gating policy, SPEC-011 amendment boundary, license confirmation, benchmark threshold.
