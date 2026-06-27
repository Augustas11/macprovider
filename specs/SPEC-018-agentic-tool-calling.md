# SPEC-018 — Agentic tool calling (provider-side response synthesis)

**Version:** 0.1.5 (2026-06-27, code-lane round-5 polish — fixes §10c residual "v0.1.2-baseline parser" drift to "v0.1.3-baseline parser" for consistency with AC-23 v0.1.4 rework)
**Depends on:** SPEC-001 v1.6, SPEC-002 v1.4.1, SPEC-006 v0.9, SPEC-008 (Pillar A model-hash trust layer — referenced by §10a), SPEC-011 v0.5 (warm-swap heartbeat `model_hash` — referenced by §10a), SPEC-015 v0.3 (receipts canonical output binding — see AC-17)
**Status:** Draft — ratifies as-built behavior + 2 normative IMPL deltas (§3.2 modelID-match-required, §8.4 commit-worthy validator) pending IMPL absorption; codex four-lane converged in 3 rounds; Claude blind-spot pass absorbed in v0.1.3.

## Change log

- **v0.1.5 (2026-06-27, code r5 polish — 1M absorbed):** Code lane round-5 caught the single residual MEDIUM from v0.1.4's AC-23 baseline-version alignment: §10c at line 440 still said "v0.1.2-baseline parser" while AC-23 at line 396 had been correctly updated to "v0.1.3-baseline parser pinned by `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`." This was precisely the baseline-version drift v0.1.4 set out to close — surgical s/v0.1.2-baseline parser/v0.1.3-baseline parser/ at §10c + cross-reference to the pin file. Code r5 verified all r4 absorptions otherwise CONFIRMED (M-1 AC-23 obligation clear; M-2 §1.1 #4 model_hash overclaim closed; m-1 stale mixed-sentinel reference dropped; m-2 §8.4 v0.1.2 → v0.1.3 cleaned). v0.1.5 is the codex code-lane lock candidate.

- **v0.1.4 (2026-06-27, code r4 + critic r2 polish — 2M + 3m absorbed):** Code lane round-4 caught two MEDIUMs introduced in v0.1.3: (M-1) AC-23 referenced a `tools/version-pins/openai-python-spec-018-v0_1_2-baseline.txt` file that does not exist in the repo — v0.1.4 commits the file as an IMPL-prompt obligation enumerated in §1.2, removing the mechanical-verifiability gap. (M-2) §1.1 #4 parenthetical overclaimed v0.1 model_hash protection — "model_hash is verified by SPEC-008, so a malicious provider cannot advertise a tool-capable family while serving different weights" — but v0.1 does NOT bind model_hash to parser family (that's v0.2 §10a #2). v0.1.4 reworded §1.1 #4 to clarify SPEC-008 verifies the loaded weights but does NOT yet gate parser family selection in v0.1; the closure of the malicious-provider case is a v0.2 deliverable. Three MINORs absorbed: §10a #5 dropped stale "mixed sentinels" from the parse-failure category list (the rule was dropped in v0.1.3 per H-3); §8.4 source-citation block now says "v0.1.3 IMPL prompt" not "v0.1.2"; AC-23 baseline-pin filename updated to `openai-python-spec-018-v0_1_3-baseline.txt` for consistency with §10c's v0.1.3 wire-shape protection. Critic r2 + Security r4 + (revised) Code r4 collectively READY TO LOCK. Round narratives: `specs/SPEC-018-critic-r2-audit.md`, `specs/SPEC-018-code-r4-audit.md`, `specs/SPEC-018-security-r4-audit.md`.

**v0.1.3 buyer-visible deltas (read this if you're skimming):**
- §3.6 mixed-sentinel rule **dropped entirely** — was a buyer-prompt DoS vector for any Qwen-Coder workflow discussing Llama tokenizer; §3.2 modelID-match-required closes the cross-family bypass on its own
- §1 OpenAI-wire framework list corrected — removed Claude Code (speaks Anthropic Messages API natively) and Cursor IDE chat (proprietary backend), keeps the 5 actually-OpenAI-wire frameworks
- AC-23 forward-compatibility regression test reworked to actually test the §10c invariant (was a tautology in v0.1.2)
- AC-24 added — coordinator request-side pass-through verification at the WS frame layer
- §10a #2 model-hash override clause hardened — requires buyer-consent header + mandatory response field; operator-only overrides without buyer consent are non-compliant

- **v0.1.3 (2026-06-27, Claude blind-spot absorption — critic 3H + 5M + narrative 5m + Qs):** Critic adversarial-verifier lane found 3 lock-blocking HIGH issues codex's four lanes missed. **H-1 absorbed:** AC-23 was a tautology (replayed v0.1.2 fixtures with v0.1.2 parser → couldn't fail). Reworked to capture vN.M responses and parse with v0.1.2 parser. **H-2 absorbed:** §1 named "Claude Code, Cursor" as OpenAI-shape frameworks; both speak proprietary / Anthropic wires. Removed across §1, §1.1, §10a #1, §11 Q1 + replaced with accurate 5-framework list. **H-3 absorbed:** §3.6 mixed-sentinel rule was a DoS vector — any prompt containing `<|python_tag|>` would suppress legitimate Qwen tool calls. Dropped §3.6 mixed-sentinel pre-detection, AC-22, IMPL delta #2 (mixed-sentinel). §3.2 modelID-match-required closes the cross-family bypass on its own. **5 MEDIUMs absorbed:** M-1 JSON depth/byte cap in §8.4 + §3.4 (DoS via 100k-deep nested objects); M-2 operator-override loophole in §10a #2 replaced with buyer-consent header + mandatory response field; M-3 §6 pass-through MUST gets AC-24 verification at WS frame layer; M-4 §10c id value format protection (call_ prefix); M-5 §2.3 sorted-keys recursive at every depth (SPEC-015 receipts binding). **Narrative 5 MINORs absorbed:** m-1 change log gets buyer-visible bullets at top; m-2 Status line gets descriptive parenthetical; m-3 §3.2 rationale gains "modelID is self-declared; model_hash is verified" sentence; m-4 §3 "family-family priority" typo fixed; m-5 §1 IMPL-prompt scaffolding moved to new §1.2. **Critic Qs pinned:** AC-16b "passes" verb (Q-1); `null` vs missing arguments distinction (Q-2); §3.6 dropped per H-3 (Q-3). **Narrative Q absorbed:** §10a #2 v0.2-MUST clause relocated to §10c as v0.1.3-locked v0.2 invariant (Narrative Q-1). Round-narrative: `specs/SPEC-018-critic-blindspot-audit.md`, `specs/SPEC-018-product-narrative-blindspot-audit.md`. Next: re-fire codex code + security lanes only against v0.1.3 (architect / PD already lock-ready and unchanged by these edits).
- **v0.1.2 (2026-06-27, round-2 audit polish):** Round-2 returned 0 CRITICAL + 0 HIGH across all 4 lanes; product-design + security both READY TO LOCK; architect + code returned 5 MEDIUMs that v0.1.2 absorbs. §3.1 Qwen2.5/Qwen3-native and Qwen-coding-tuned rows collapsed into one "Qwen (2.5 / 3 / coder variants)" row with predicate `modelID` substring `qwen2.5` OR `qwen3` — closes Arch M-1 table-order ambiguity AND Code Q-3 Qwen3 detection gap. §2.3 "SDKs MUST JSON-parse and schema-validate before execution" removed — that obligation is SPEC-018's external-client concern, not response-synthesis (Arch M-2); buyer-side validation guidance lives in §1 + AC-20 only. §1 enumerates 3 IMPL deltas (§3.2 modelID-match, §3.6 mixed-sentinel fallback, §8.4 commit-worthy validator). §3.6 mixed-sentinel now in §1's IMPL-delta list (Code M-1). §7 lowercase informative voice (Arch m-1). §8.4 + AC-21 tighten `function.arguments` to "JSON-object string" not just parseable (Sec m-1); citation relabeled as "current commit-signal path to patch" (Code M-3). §5 disambiguated — `function.arguments` cap is §10a #7 v0.2-gating, `max_tool_calls` is §10b future (Sec m-2). §10a #2 citation corrected to `provider.go:132-133` + `:1001-1052` (Code M-2), buyer-facing sentence added (PD m-2), v0.2 unknown-hash fail-closed requirement added (Sec Q-1). §10 adds additive v0.2 invariant (PD Q-1). §1 narrowly defines "certificate" as AC-16a + AC-16b evidence (PD m-1). §11 Q1 reframed as v0.2 product decision (PD Q-2). Round-2 narrative: `specs/SPEC-018-r2-audit.md`; per-lane: `specs/SPEC-018-{architect,code,security,product-design}-r2-audit.md`.
- **v0.1.1 (2026-06-27, round-1 audit absorption):** Re-scoped from "Ring-1 product" to "first-turn OpenAI tool-call wire-shape compatibility certificate" after PD C-1 + Architect M-3 found Ring-1 framing did not survive turn 2 of any real agent session. §3 detection grammar tightened to require `modelID` substring match (Security C-1 (a)) — content-sentinel-only detection is no longer normative. §1 adds buyer-side validation obligation (Security C-1 (b)). §10 split into §10a "Required for full Ring-1 product (v0.2 targets)" — multi-turn provider acceptance, model-hash → family registry leveraging the live SPEC-008/SPEC-011 `model_hash` infrastructure, prompt-echo guard, token-incremental streaming promotion, structured `malformed_tool_call` signal — and §10b "Future enhancements" — structured output, prefix-cache signaling (SPEC-006 header-allowlist allocation required, no concrete header reserved), `max_tool_calls` cap, SDK examples. §7 made informative; gateway YAML normative authority returned to SPEC-002 / SPEC-006. §8.4 adds commit-worthy delta minimal-shape validation (Security H-1). Multiple AC reshuffles (split, parametric, scope). Round narrative: `specs/SPEC-018-r1-audit.md`; per-lane findings: `specs/SPEC-018-{architect,code,security,product-design}-r1-audit.md`.
- **v0.1 (2026-06-27, initial draft):** Post-hoc ratification of cf2f135, c823a96, and 7b8b1be as the network's tool-calling baseline. Superseded by v0.1.1 round-1 absorption.

## 1. Scope

SPEC-018 defines OpenAI-compatible tool-calling wire compatibility for provider-side response synthesis on the macprovider network.

**v0.1 product surface: a first-turn OpenAI tool-call wire-shape compatibility certificate.** "Certificate" here is defined narrowly: AC-16a + AC-16b first-turn-parse evidence. It is NOT a certification of full agent-framework integration or multi-turn agent loop completion. A buyer MAY point an OpenAI-shaped client at the buyer-side gateway and receive a single assistant tool-call response that the client can parse without macprovider-specific response adapters. v0.1 does NOT certify full multi-turn client-side agent loops; the current phase3 provider rejects `role: "tool"` messages and assistant-history `tool_calls[]` with HTTP 400 `unsupported_tool_messages` (AC-14). Full client-side agent loop support — what users running OpenAI-wire-native frameworks like Cline, Aider, OpenCode, Continue, Vercel AI SDK, LangChain (`ChatOpenAI`), LlamaIndex (`OpenAI` LLM), Pydantic-AI (`OpenAIModel`), or n8n (OpenAI node) actually need — is the v0.2 deliverable per §10a. **Not included** in v0.1 or v0.2's wire surface: Claude Code (speaks the Anthropic Messages API natively — `/v1/messages` with `content` blocks and `tool_use`), Cursor IDE chat (proprietary backend), Zed AI assistant (proprietary), or any framework whose tool-calling wire is not OpenAI `chat/completions` with `tool_calls[]`.

The agent loop runs on the buyer's machine. The model runs on the seller. The network is the marketplace and transport.

A macprovider seller MUST emit OpenAI-wire-compatible `tool_calls[]` when a supported model output grammar produces tool calls under the §3 detection rules and a request supplies enabled tools.

A macprovider seller MUST NOT execute tools on behalf of the buyer. The seller's job ends at emitting the `tool_calls[]` array.

**Buyer-side validation obligation (Security C-1 (b)):** Emitted `tool_calls[]` reflect the underlying model's output as parsed by §3 detection grammars. macprovider does NOT semantically validate `tool_calls[].function.name` or `function.arguments` against the buyer's tool policy or intent. Buyer-side agent frameworks MUST validate emitted tool calls against agent policy before executing them. Treat emitted tool calls with the same trust posture you would apply to a model running on local hardware: parsed output, not provider-verified intent.

The following products are out of scope for SPEC-018 entirely:

- Ring 2: provider-side agent execution, where a provider runs the agent loop locally with sandbox, filesystem, shell, or network egress authority. That product is reserved for SPEC-019.
- Ring 3: provider-hosted MCP servers reachable from the model's tool loop. That product is reserved for SPEC-020.

SPEC-018 v0.1.3 ratifies the as-built response-synthesis behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`, `OutputCanonicalizer.swift`, `ModelRuntime.swift`, `HTTPServer.swift`, `InferenceRelay.swift`, coordinator relay pass-through, and gateway pass-through, with two normative deltas vs the as-built that the v0.1.3 IMPL prompt will patch (enumerated in §1.2). All other §2–§8 behavior is post-hoc ratification.

### 1.1 Known v0.1 limitations (single user-facing callout)

A buyer or operator reading this SPEC should know up front that v0.1 has the following user-visible limitations. These are not bugs; they are scope. Each is closed in §10a as a v0.2 deliverable.

1. **First-turn only.** `role:"tool"` messages and assistant-history `tool_calls[]` are rejected at the provider boundary (AC-14). A real agent session running Cline / Aider / OpenCode / Continue against macprovider will succeed on turn 1 and fail on turn 2.
2. **Buffered-to-end streaming for tool calls.** When streaming is enabled with tool-enabled requests, the tool-call SSE event fires only after generation completes. Users see a pause, then the complete tool call, instead of token-incremental `arguments` deltas (§4, Q1).
3. **No structured `malformed_tool_call` signal.** Parse failures fall back to plain assistant content (§5). Buyers cannot programmatically distinguish "normal model text" from "recognized tool-call parse failed."
4. **No model-hash-bound grammar selection.** v0.1 selects parser grammar by `modelID` substring match (§3, §10a v0.2 target). A provider whose advertised modelID matches a declared family is trusted at the modelID level; cryptographic binding of the loaded model hash to which parser family runs is a v0.2 deliverable. (modelID is a self-declared string the provider chooses freely. The SPEC-008 Pillar A + SPEC-011 v0.5 `model_hash` infrastructure already in production verifies the bytes of the loaded weights, but v0.1 does NOT yet bind that verified hash to which parser family is selected — a malicious provider can advertise a tool-call-capable Qwen modelID while loading entirely different weights whose `model_hash` SPEC-008 happens to register. v0.2 §10a #2 adds the `model_hash` → family registry on top of the existing infrastructure to close this; v0.1 mitigation is the buyer-side validation obligation in §1 + AC-20.)
5. **No prompt-echo guard.** A model that echoes hostile tool-call markup from a poisoned prompt is not rejected by the parser; the buyer-side validation obligation in §1 is the v0.1 mitigation, with a normative parser-side guard committed to §10a v0.2.

### 1.2 v0.1.3 IMPL prompt scope (author-facing, not buyer-facing)

This subsection enumerates the deltas between v0.1.3's normative content and the current as-built code — the v0.1.3 IMPL prompt MUST patch these before SPEC-018 v0.1 is considered ratification-equivalent.

**Two normative deltas vs the as-built:**

1. **§3.2 `modelID`-match-required.** As-built (`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:482-487`) uses OR-based detection (modelID substring match OR raw output sentinel). v0.1.3 normative: modelID match required; sentinel-only detection MUST fall back to plain content. AC-19. Tests in `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:46-57` will need updating alongside the parser patch.
2. **§8.4 commit-worthy delta validator.** As-built `hasOpenAIDeltaSignal` (`phase4-coordinator/internal/buyer/server.go:2482-2605`) commits on any non-empty `tool_calls[]` array. v0.1.3 normative: commit-worthy only if delta validates as minimal OpenAI shape AND `function.arguments` JSON nesting depth ≤ 32 AND byte length ≤ 256 KiB (per §8.4 / AC-21). New coordinator test required that rejects `[{}]`, `{"function":{"arguments":"[]"}}`, and 100k-depth nested objects, while accepting only the minimal valid delta. The §3.4 parser-side duplicate validator MUST apply the same depth / byte caps.

**AC-23 baseline-pin file obligation (v0.1.4 addition).** The IMPL prompt MUST commit `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` to the repo root, containing the exact `openai` Python SDK semver pinned as the v0.1.3 wire-shape baseline (the version current at v0.1.3 lock time). AC-23's forward-compatibility regression depends on this file being mechanically reproducible from the repo, not on tribal knowledge of "which OpenAI SDK version was current."

**AC-20 documentation obligations** — the IMPL prompt MUST add the buyer-side validation obligation phrase ("emitted `tool_calls[]` reflect model output, not provider-verified intent; buyer-side agent frameworks MUST validate before execution") to:
- `README.md`
- `examples/tool_calling_demo.py`
- `test/integration/tool_calling/README.md:38-53`
- `test/integration/tool_calling/openai_tool_call_e2e.py:78-85`

**New AC-24** (coordinator request-side pass-through verification) requires a new unit test at the WS-frame layer asserting byte-equivalence between buyer-supplied request-side `tool_calls[]` / `tool_call_id` field bytes and the coordinator's outbound `InferenceRequest` frame.

**Note (v0.1.2 → v0.1.3 delta):** v0.1.2 had a third IMPL delta — §3.6 mixed-sentinel fallback — that is **dropped in v0.1.3**. §3.6's mixed-sentinel pre-detection rule was a buyer-prompt DoS vector (any prompt containing `<|python_tag|>` would suppress legitimate Qwen tool calls); §3.2 modelID-match-required closes the cross-family bypass on its own without the false-positive cost. No parser change required for this category.

## 2. Response Wire Shape: Non-Streaming

When provider-side parsing produces one or more tool calls, the buyer-visible HTTP response MUST be an OpenAI chat-completions response.

The response MUST contain:

- `choices[0].message.role = "assistant"`.
- `choices[0].message.content = null` in the v0.1 as-built provider when any `tool_calls` are present.
- `choices[0].message.tool_calls`, an array of tool-call objects.
- `choices[0].finish_reason = "tool_calls"`.

Each `tool_calls[]` object MUST have:

- `id`: an opaque string.
- `type = "function"`.
- `function.name`: the parsed function name.
- `function.arguments`: a JSON-encoded string, not a JSON object.

This shape is implemented in `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:776-828`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:566-615`, and `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:16-38`.

### 2.1 ID Generation

For each parsed tool call, the provider MUST mint an ID of the form:

```text
call_<uuid-hex-lowercase-without-hyphens>
```

The v0.1 as-built implementation uses Swift `UUID().uuidString`, removes hyphens, lowercases the result, and prefixes it with `call_`.

IDs are non-deterministic (≥122 bits of entropy from the platform UUID generator). A retry of the same model output is not required to reproduce the same IDs. Implementations MUST NOT use an incrementing per-response scheme if that scheme can collide across calls in the same response.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:59-75` and `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:77-94`.

### 2.2 Multi-Call Ordering

When the underlying model output contains N recognized tool calls, the provider MUST preserve textual order. `tool_calls[0]` MUST correspond to the first recognized call in the model output, `tool_calls[1]` to the second, and so on.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:29-50`; locked by `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:21-30`.

### 2.3 `arguments` String Encoding

The provider MUST emit `function.arguments` as a string containing a JSON object.

The v0.1 canonicalization rules are:

- **Missing `arguments` or `parameters`** (key absent from the parsed object) MUST serialize as `{}` (empty-object string). This is the "model emitted a function call with no arguments" path.
- **Explicit `null` arguments** (key present, value is JSON `null`) MUST NOT produce a tool call; the response falls back to plain assistant content. (The distinction between key-absent and key-present-null is normatively meaningful: a model emitting `null` is treated as a parse failure, not as "empty arguments." A model that intends zero-argument calls SHOULD emit no `arguments` key.)
- JSON object arguments decoded from a structured object MUST be serialized with **keys sorted recursively at every depth** (nested objects' keys are also sorted), no insignificant whitespace, and without escaping `/`. The recursive sort is required for SPEC-015 v0.3 receipt canonical-output binding (per AC-17): a non-recursive sort would produce a wire bytestring that disagrees with the receipt's canonicalized hash for any tool call with nested-object arguments.
- JSON string arguments MUST be validated as a JSON object and MUST be emitted byte-for-byte as supplied by the model after validation. (Validation-only — not re-canonicalized. The buyer-side validation obligation in §1 + AC-20 covers downstream parsing and schema validation; SPEC-018 imposes no normative SDK requirement.)
- Python-style keyword arguments MUST be converted to a JSON object string with keys sorted recursively at every depth, no insignificant whitespace, and without escaping `/`.
- Non-object argument values (JSON arrays, scalars, etc.) MUST NOT produce a tool call; the response falls back to plain assistant content.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:238-264`, `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:96-123`, and `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:169-188`.

### 2.4 Content Interleaving

The parser can collect prose outside tool-call delimiters as cleaned content. The v0.1 provider runtime discards that cleaned content whenever at least one tool call is parsed and returns tool calls only. Therefore, when the model emits prose before, between, or after recognized tool calls, the buyer-visible non-streaming message MUST contain `content = null` and the parsed `tool_calls[]`.

Source: parser behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:29-50`; runtime discard in `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839`; response emission in `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:819-828`.

## 3. Detection Grammar

The provider does not receive structured tool calls from the underlying MLX model. It receives plain text and parses recognized model-family output grammars.

**§3 is the normative source of truth for v0.1 model-family tool-call grammars.** The implementation source is the implementation of this section. Any detector, sentinel, modelID match, grammar path, or multi-family priority not represented in §3 is non-compliant until a SPEC-018 version bump.

### 3.1 Family table

| Family | `modelID` match (required) | Body grammar | Argument field | Source |
|---|---|---|---|---|
| Qwen (2.5 / 3 / Coder variants) | `modelID` substring contains `qwen2.5` OR `qwen3` (case-insensitive) | EITHER `<tool_call>{...}</tool_call>` JSON body OR `<tool_call>name(key=value, ...)</tool_call>` Python-style call (the parser tries JSON body parsing first; on failure, falls back to Python-style parsing) | `arguments` preferred for JSON body; `parameters` accepted as JSON-body fallback; keyword args for Python-style body | `ToolCallParser.swift:77-123`, `ToolCallParser.swift:451-491` |
| Llama 3.3 MLX | `modelID` substring contains `llama-3.3` (case-insensitive) | `<\|python_tag\|>{...}<\|eom_id\|>` JSON body, OR `<\|python_tag\|>name(key=value)<\|eom_id\|>` Python-style body (JSON body parsing tried first) | `parameters` preferred for JSON body; `arguments` accepted as JSON-body fallback; keyword args for Python-style body | `ToolCallParser.swift:451-491` |

Note: production Qwen-coding SKUs (e.g. `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`, `mlx-community/Qwen3-32B-4bit`) match the Qwen family row via `qwen2.5` or `qwen3` substring. There is no separate "coding-tuned" row in §3.1 — coding-tuned variants advertise as Qwen2.5/Qwen3 derivatives and select the same family; body-grammar disambiguation is performed by the parser per the OR rule above.

### 3.2 modelID match required (Security C-1 (a))

Family detection MUST require a `modelID` substring match against §3.1. Content-sentinel detection alone (the presence of `<tool_call>` or `<|python_tag|>` in raw model output without a matching `modelID`) is NOT a normative trigger in v0.1. Output containing recognized sentinels but no `modelID` family match MUST be emitted as plain assistant content; no `tool_calls[]` are synthesized.

A request with a **missing, empty, or whitespace-only `modelID`** MUST be treated as no §3.1 family match for §3.2 purposes; the response falls back to plain assistant content per §3.5. (SPEC-001 normally requires the field at request validation; §3.2 pins the defensive default in case validation is loosened.)

Rationale: the v0.1 design closes the prompt-injection vector identified in Security C-1 / Q6, where a model could be prompted to echo `<tool_call>{"name":"declared_tool",…}</tool_call>` and the parser would synthesize a legitimate-looking tool call. With `modelID` match required, a provider that has not advertised a tool-call-capable family does not synthesize tool calls regardless of model output content. (modelID is a self-declared string the provider chooses freely. v0.1 still trusts the provider's modelID assertion; the residual case — a tool-call-capable model echoing hostile content, OR a malicious provider lying about modelID while serving different weights — is closed in v0.2 via the §10a model-hash → family registry binding on top of the SPEC-008 Pillar A `model_hash` infrastructure, plus the prompt-echo guard.)

### 3.3 Body parsing

For JSON bodies, the body MUST parse as a JSON object with a non-empty string `name`. For Python-style bodies, the body MUST parse as `name(key=value, ...)` where `name` and keys are Python identifiers and values are supported string, boolean, null, integer, or decimal literals.

### 3.4 Ambiguous duplicate argument keys

Ambiguous duplicate argument keys means any of the following:

- duplicate keys in the top-level JSON call object;
- duplicate keys in a nested JSON `arguments` or `parameters` object;
- duplicate keys in a JSON string supplied as `arguments` or `parameters`;
- duplicate keyword names in a Python-style call.

The v0.1 provider rejects ambiguous duplicate keys by abandoning tool-call synthesis and falling back to plain assistant content. It does not silently choose first-key-wins or last-key-wins.

**Parser-side DoS bounds (Critic M-1 absorption).** The §3.4 duplicate-key validator MUST reject any JSON whose nesting depth exceeds **32** or whose total byte length exceeds **256 KiB**, treating the rejection as a parse failure (fallback to plain assistant content per §3.5). This closes the parser-side DoS where an adversarial model emits multi-MB or deeply-nested `arguments` to exhaust provider memory before the §10a #7 v0.2 byte cap can apply.

Source: JSON duplicate validator in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:266-448`; Python keyword duplicate rejection in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:96-123`; locked by `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:125-159`. Depth + byte caps are a v0.1.3 IMPL delta per §1.2.

### 3.5 Fallback to plain content

If grammar detection fails, parsing fails, the function name is not declared in the request's enabled tools, or a value cannot be represented as a JSON-object `arguments` string, the provider MUST treat the model output as plain assistant content and MUST NOT emit `tool_calls[]`.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-27`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839`.

### 3.6 Multi-family priority

When the buyer-supplied `modelID` substring-matches more than one family row in §3.1, deterministic precedence is declared by table order: the first matching row in §3.1 selects the parser family. At v0.1.3, the two rows have disjoint predicates (`qwen2.5`/`qwen3` for Qwen; `llama-3.3` for Llama) so no `modelID` realistically matches both; the rule is normative for future family additions per §3.7.

**Cross-family sentinel safety (closure of v0.1.2's mixed-sentinel concern).** v0.1.2 §3.6 contained a mixed-sentinel rule requiring fallback when output contained sentinels from multiple families simultaneously. v0.1.3 drops that rule because:

1. §3.2 modelID-match-required already closes the cross-family bypass: a request with a Qwen-modelID always uses the Qwen parser, and Llama sentinels in the output are by definition data, not framing — the Llama parser never runs for that request. Symmetrically for Llama-modelID requests.
2. The mixed-sentinel pre-detection rule was a buyer-prompt DoS vector — any legitimate Qwen-Coder workflow whose `function.arguments` JSON contained the Llama sentinel literal as data (e.g. asking `code_search` to look up `"<|python_tag|>"`) would trigger the fallback and break the tool call. The fix added more attack surface than it closed.

Cross-family parser confusion is therefore handled exclusively by §3.2 + table-order priority; no pre-detection scan is required.

### 3.7 Adding a new family

A new model family's tool-call grammar MUST land via a SPEC-018 version bump that updates §3.1 and §3.2. Parser PRs MUST NOT mutate this table silently. A parser change that adds a new detector, sentinel, modelID match, or grammar path without a corresponding SPEC-018 §3 update is non-compliant.

**Row-ordering invariant.** New rows MUST be appended at the end of §3.1. New-row `modelID` predicates MUST be disjoint from all existing predicates — a new predicate that is a substring of an existing predicate (or vice versa) would silently change which family selection applies to existing modelIDs and requires a **major** SPEC-018 version bump, not a minor or patch bump.

## 4. Streaming Wire Shape

When `stream = true`, the buyer-visible response MUST use OpenAI-style SSE chat-completion chunks.

The v0.1 as-built streaming behavior is buffered-to-end for tool-enabled requests. It is not token-incremental for tool calls. v0.2 promotes token-incremental streaming per §10a.

The provider MUST emit an initial chunk with:

- `choices[0].delta.role = "assistant"`;
- `choices[0].delta.content = ""`;
- `choices[0].finish_reason = null`.

When one or more tool calls are parsed, the provider MUST then emit one SSE event containing `choices[0].delta.tool_calls[]`. That event fires only after underlying generation completes and provider-side parsing succeeds.

Each streamed tool call delta MUST contain:

- `index`: zero-based array index matching the non-streaming `tool_calls[]` order;
- `id`: the complete provider-minted call ID;
- `type = "function"`;
- `function.name`: the complete function name;
- `function.arguments`: the complete final `arguments` string.

The v0.1 stream does not split `function.arguments` into additive partial substrings. Concatenation across deltas for a given `index` is therefore a single-fragment concatenation and MUST reproduce the non-streaming `function.arguments` string byte-for-byte.

After the tool-call delta event, the provider MUST emit a terminator chunk with:

- `choices[0].delta = {}`;
- `choices[0].finish_reason = "tool_calls"`.

The provider MAY then emit a usage chunk with `choices = []` and MUST end the stream with `[DONE]`.

`delta.content` and `delta.tool_calls` MUST NOT appear in the same SSE event in v0.1.

If tool parsing fails in a tool-enabled streaming request, the provider emits plain content after generation completes and uses the non-tool finish reason (`stop` or `length`).

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:481-603`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:433-556`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:387-509`.

## 5. Error Taxonomy

SPEC-001 identifies `malformed_tool_call` as an adversarial workload name in its error-taxonomy acceptance coverage. SPEC-018 v0.1 does not ratify `malformed_tool_call` as a provider response-synthesis API error code; §10a promotes it to a structured signal in v0.2.

The v0.1 response-synthesis error behavior is:

- malformed recognized tool-call bodies fall back to plain assistant content;
- undeclared function names fall back to plain assistant content;
- duplicate JSON or Python argument keys fall back to plain assistant content;
- explicit `null`, non-object, or invalid JSON arguments fall back to plain assistant content;
- output containing recognized sentinels but no `modelID` family match falls back to plain assistant content (§3.2);
- output exceeding the §3.4 parser depth (32) or byte (256 KiB) caps falls back to plain assistant content;
- unsupported `tool_choice` values other than omitted, `null`, or `"auto"` produce HTTP 400 with code `unsupported_tool_choice`;
- current phase3 provider input containing `role: "tool"` or assistant history `tool_calls[]` produces HTTP 400 with code `unsupported_tool_messages`.

Source: fallback behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-27`; provider scope validation in `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:909-940`; tests in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:99-155`.

SPEC-018 v0.1 imposes no `max_tool_calls` limit and no per-call `function.arguments` byte cap. No `tool_call_limit_exceeded` error exists in v0.1.

Disambiguation of v0.2+ commitments:
- **`function.arguments` byte cap** is committed to v0.2 per §10a #7 with fail-closed semantics; it is a v0.2 gating item for full Ring-1 product release, not a §10b future candidate.
- **Structured `malformed_tool_call` signal** is committed to v0.2 per §10a #5.
- **`max_tool_calls` cap and `tool_call_limit_exceeded` error** remain §10b future-enhancement candidates with no committed version.

If the underlying model reaches `max_tokens` mid-tool-call and no complete tool call can be parsed, the provider MUST NOT emit a partial tool call. It emits plain assistant content with `finish_reason = "length"` when the token limit is reached.

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:451-465`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:567-590`.

Coordinator request validation for malformed assistant-history `tool_calls[]` remains governed by SPEC-001 and SPEC-002. The coordinator uses HTTP 400 with code `invalid_tools` for invalid request-side tool schema.

Source: `phase4-coordinator/internal/buyer/server.go:2940-3007`.

## 6. Multi-Turn Round Trip

SPEC-001 and SPEC-002 define the request half for assistant-history `tool_calls[]` and `role: "tool"` messages. SPEC-018 adds the response-side ID invariant.

The provider-minted `tool_calls[].id` is opaque. A buyer-side agent framework that sends a subsequent `role: "tool"` message MUST echo the exact ID in `tool_call_id`. Coordinator and gateway components MUST NOT rewrite, canonicalize, strip, or reorder provider-minted IDs.

The coordinator MUST treat request-side `tool_calls` and `tool_call_id` values as pass-through fields after validation. This ratifies SPEC-002's value-typed pass-through rule for `tool_calls`.

Source: request validation in `specs/SPEC-001-phase3-binary.md:950-979` and `specs/SPEC-002-coordinator.md:2280-2318`; coordinator implementation in `phase4-coordinator/internal/buyer/server.go:1236-1240` and `phase4-coordinator/internal/buyer/server.go:2940-3007`.

**v0.1 implementation limitation (closed in §10a v0.2):** the current phase3 provider rejects multi-turn tool-result messages at the provider boundary with `unsupported_tool_messages`. Therefore, SPEC-018 v0.1 ratifies response synthesis and transport pass-through, but it does not certify a full second-turn provider request after tool execution. This is the v0.2 deliverable — the gate between "wire-shape compatibility certificate" and "actual Ring-1 product release" — per §10a.

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:920-940`; test coverage in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:124-155`.

## 7. Gateway Timeout Co-Requirement (informative)

Tool-call buffered-to-end response synthesis (§4) creates first-header latency on non-streaming requests: headers do not arrive at the gateway until the provider finishes generation and response synthesis. For large coding-class models (Qwen3-Coder-30B-class on M4) first-response latency can exceed 10 seconds, which was the pre-c823a96 gateway `ResponseHeaderTimeout` default.

c823a96 raised the default to 60 seconds; the current as-built gateway default is 300 seconds with validation requiring `coordinator_header_timeout_seconds >= coordinator_request_seconds`.

§7 is **informative** in SPEC-018: the normative authority for gateway YAML configuration is SPEC-006 (buyer API gateway), and the normative authority for the coordinator-side request/header timeout ordering is SPEC-002 (coordinator). Compliant deployments of tool-call workloads need to satisfy the SPEC-002 / SPEC-006 timeout invariants — those SPECs hold the normative MUST. SPEC-018 records the rationale tying tool-call buffered-to-end synthesis to first-header latency so that a SPEC-006 amendment can absorb explicit tool-call-workload guidance.

Source for the current gateway timeout machinery: `phase5-gateway/internal/config/config.go:123-127`, `phase5-gateway/internal/config/config.go:183`, `phase5-gateway/internal/config/config.go:361-373`, `phase5-gateway/internal/config/config.go:462-475`, and `phase5-gateway/cmd/gateway/main.go:81-95`.

## 8. Coordinator and Gateway Pass-Through Invariants

Every transport component between provider runtime and buyer client MUST preserve tool-call fields opaquely unless this SPEC or an upstream SPEC explicitly authorizes validation.

### 8.1 Provider HTTP Server

The provider HTTP server emits the OpenAI non-streaming and streaming shapes. It MUST serialize `tool_calls[]` without raw model delimiters.

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:776-891`; shape tests in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:53-97` and `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:223-262`.

### 8.2 InferenceRelay

InferenceRelay MUST preserve the generated OpenAI JSON/SSE payloads as `data` strings when forwarding over the coordinator WebSocket relay. It MUST NOT parse, strip, reorder, or canonicalize `tool_calls[]`.

Source: non-streaming forward in `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:269-309`; streaming forward in `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:387-509`; frame send helpers in `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:532-564` and `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:566-650`.

### 8.3 Coordinator WebSocket Relay

The coordinator WebSocket relay MUST treat provider chunks as opaque payloads. It MUST route `InferenceResponseChunk.data` and `InferenceResponseEnd` frames by request ID and MUST NOT inspect tool-call fields.

Late encrypted frames for recently retired requests MUST be consumed according to c823a96 cleanup behavior and MUST NOT surface as spurious relay failures.

Source: `phase4-coordinator/internal/ws/relay.go:525-581`, `phase4-coordinator/internal/ws/relay.go:583-722`, `phase4-coordinator/internal/ws/relay.go:211-250`; frame shape in `phase4-coordinator/internal/ws/messages.go:199-225`.

### 8.4 Coordinator Buyer HTTP Forwarding

For WebSocket-backed non-streaming responses, the coordinator MUST write the provider response body bytes to the buyer without semantic rewriting. For WebSocket-backed streaming responses, it MUST write SSE chunks without rewriting `tool_calls[]`.

For direct provider HTTP streaming, the coordinator MAY inspect SSE events only to determine whether a response is commit-worthy. A `delta.tool_calls[]` event is **commit-worthy only if** the delta validates as minimal OpenAI tool-call shape AND passes the commit-validator DoS bounds:

- `index`: integer ≥ 0
- `id`: non-empty string
- `type == "function"`
- `function.name`: non-empty string
- `function.arguments`: present, a JSON string whose decoded value is a JSON object (an empty object `"{}"` is valid; arrays, scalars, or `null` are not)
- **`function.arguments` decoded JSON nesting depth ≤ 32** (Critic M-1 absorption)
- **`function.arguments` byte length ≤ 256 KiB** (Critic M-1 absorption)

Malformed or oversized pre-commit tool-call deltas — including `{"choices":[{"delta":{"tool_calls":[{}]}}]}` (empty tool-call object), `{"function":{"arguments":"[]"}}` (arguments decodes to non-object), and `{"function":{"arguments":"<256-KiB-of-nested-objects>"}}` (exceeds size or depth cap) — MUST NOT commit the response and MUST NOT settle provider-positive usage. This closes the Security H-1 commit-on-bogus-delta path AND the v0.1.3 Critic M-1 commit-validator DoS path (an adversarial provider sending arbitrarily deep nested JSON to exhaust the coordinator commit-signal goroutine's stack).

After commit, the coordinator MUST pass bytes through without rewriting `tool_calls[]`.

**Source (current commit-signal path to patch):** as-built `hasOpenAIDeltaSignal` at `phase4-coordinator/internal/buyer/server.go:2482-2605` currently accepts any non-empty `tool_calls[]` array (insufficient under v0.1.3). v0.1.3 IMPL prompt adds the minimal-shape validator + depth/byte-cap rejection to this code path and adds a new coordinator test that rejects `[{}]`, `{"function":{"arguments":"[]"}}`, and `{"function":{"arguments":"<256-KiB-of-nested-objects>"}}` while accepting only the minimal valid delta. Surrounding integration in `phase4-coordinator/internal/buyer/server.go:1982-2195`, `phase4-coordinator/internal/buyer/server.go:2320-2473`; existing commit-signal tests at `phase4-coordinator/internal/buyer/server_internal_test.go:70-103` (to be extended).

### 8.5 Gateway

The gateway MUST forward non-streaming response bodies and streaming SSE lines without semantic rewriting of `tool_calls[]`.

The streaming gateway MAY parse delta strings for token-estimate enforcement. It MUST count generated `function.arguments` string bytes and MUST NOT count `id`, `type`, or `name` strings as generated output.

Source: `phase5-gateway/internal/router/chat_proxy.go:237-516`, `phase5-gateway/internal/router/chat_proxy.go:652-717`; tests in `phase5-gateway/internal/router/server_test.go:2516-2580`.

## 9. Acceptance Criteria

AC-1. Given a request with enabled tool `foo`, `modelID` substring-matching `qwen2.5`, and model output `<tool_call>{"name":"foo","arguments":{"a":1}}</tool_call>`, the buyer-visible non-streaming response contains `choices[0].message.tool_calls[0].function.name == "foo"` and `choices[0].message.tool_calls[0].function.arguments == "{\"a\":1}"`.

AC-2. When any tool call is emitted, `choices[0].finish_reason == "tool_calls"`.

AC-3. For multiple recognized calls in one model output, response array order matches textual order.

AC-4. Response `tool_calls[].id` values start with `call_`, contain a lower-case hyphenless UUID suffix derived from a fresh ≥122-bit-entropy UUID, and are observed unique within the test response. (Non-collision is invariant by construction; no explicit per-response de-duplication loop is required.)

AC-5. Ambiguous duplicate argument keys produce no `tool_calls[]`; the response falls back to plain assistant content instead of first-key-wins or last-key-wins.

AC-6. Malformed recognized tool-call bodies produce no `tool_calls[]`; the response falls back to plain assistant content.

AC-7. Streaming tool-call responses contain no raw `<tool_call>`, `</tool_call>`, `<|python_tag|>`, or `<|eom_id|>` delimiters **at framing positions** — i.e., outside the JSON-escaped contents of `function.arguments` string values. (A legitimate tool call whose `arguments` discusses these tokens as data MUST succeed; the literal substring appearing inside an escaped JSON string value does NOT violate AC-7.)

AC-8. Streaming tool-call responses emit one complete `delta.tool_calls[]` event after generation completes, followed by a terminator chunk with `finish_reason == "tool_calls"`.

AC-9. Concatenating streamed `function.arguments` fragments by `index` reproduces the non-streaming `function.arguments` string byte-for-byte. In v0.1 this is a single-fragment concatenation.

AC-10. `delta.content` and `delta.tool_calls` do not appear in the same SSE event.

AC-11. Coordinator WebSocket relay preserves provider-emitted `tool_calls[]` JSON across `InferenceResponseChunk.data` without stripping, reordering, or canonicalizing fields.

AC-12. Gateway non-streaming and streaming forwarding preserves provider-emitted `tool_calls[]` fields without semantic rewriting.

AC-13. `tool_choice` values other than omitted, `null`, or `"auto"` fail with HTTP 400 code `unsupported_tool_choice` at the current provider boundary.

AC-14. Current provider requests containing `role: "tool"` messages or assistant-history `tool_calls[]` fail with HTTP 400 code `unsupported_tool_messages`. (v0.1 ratifies this as the first-turn-only limitation; closed in §10a v0.2.)

AC-15a. **Code default + validation (CI-verifiable).** Gateway default `coordinator_header_timeout_seconds` is 300; validation rejects configurations where `coordinator_header_timeout_seconds < coordinator_request_seconds`. Verified by `phase5-gateway/internal/config/config_test.go:22-55`.

AC-15b. **Live deploy evidence (release smoke / manual evidence).** Live tool-call workload deployments configure `timeouts.coordinator_header_timeout_seconds >= 60`. Verified by the deploy-gate script `phase4-coordinator/dist/check-deploy-config.sh:268-281` and an operator-recorded JSON artifact from the live gateway YAML.

AC-16a. **First-turn wire-shape smoke (CI-local).** An OpenAI Python SDK 1.x client pointed at the buyer URL parses the first assistant tool-call response for the canonical `get_weather`-style loop without response adapters. Covered by `test/integration/tool_calling/openai_tool_call_e2e.py:14-18`, `:147-165`.

AC-16b. **Framework-level smoke (release smoke / manual evidence).** When v0.1 is configured against at least one OpenAI-wire-native agent framework (one of: Cline, Aider, OpenCode, Continue, Vercel AI SDK), the framework's chat-completions client returns successfully from the first assistant tool-call response (i.e. the SDK's return-handling completes without raising; the framework's agent loop reaches the "decide whether to execute the tool" step) without macprovider-specific adapters. Per AC-14, the second turn is expected to fail; the framework-level smoke confirms first-turn shape parity reaches the framework's execute-decision boundary, not multi-turn loop completion. Claude Code, Cursor IDE chat, and other non-OpenAI-wire frameworks are explicitly NOT v0.1 compatibility targets (see §1).

AC-17. For non-streaming receipt-bearing responses, SPEC-015 v0.3 §5.1–§5.3 canonical output object includes canonicalized `tool_calls[]` when tool calls are emitted. (Streaming receipts are out of scope per SPEC-015 v0.3.)

AC-18. A non-streaming Qwen3-Coder-class tool-call response completes through any production gateway deployment satisfying the SPEC-002 / SPEC-006 timeout invariants. Marked as **release smoke / manual evidence**: the integration runner `test/integration/tool_calling/openai_tool_call_e2e.py` produces a JSON artifact recording the `OPENAI_BASE_URL`, model SKU, response shape, and completion latency. v0.1 does not pin a specific public deployment URL.

AC-19. **modelID-match-required (Security C-1 (a)).** A request with enabled tools whose `modelID` does NOT substring-match any §3.1 family row produces no `tool_calls[]`, even when the underlying model output contains recognized sentinel markup (`<tool_call>`, `<|python_tag|>`). The response is emitted as plain assistant content.

AC-20. **Buyer-side validation obligation visibility (Security C-1 (b)).** Public documentation (README, examples, AC-16a/AC-16b harnesses) MUST state that emitted `tool_calls[]` reflect model output, not provider-verified intent, and that buyer-side agent frameworks MUST validate before execution. macprovider MUST NOT semantically validate `tool_calls[].function.name` or `function.arguments` against the buyer's tool policy.

AC-21. **Commit-worthy delta minimal-shape validation + DoS bounds (Security H-1 + Critic M-1).** The coordinator commit-signal code path (§8.4) MUST validate that any `delta.tool_calls[]` event chosen as commit-worthy has integer `index`, non-empty `id` string, `type == "function"`, non-empty `function.name`, and `function.arguments` as a JSON string whose decoded value is a JSON object with nesting depth ≤ 32 and byte length ≤ 256 KiB. Malformed or oversized pre-commit deltas — including `[{}]` (empty tool-call object), `{"function":{"arguments":"[]"}}` (arguments decodes to non-object), and `{"function":{"arguments":"<256-KiB-of-nested-objects>"}}` (exceeds depth or byte cap) — MUST NOT commit the response or settle provider-positive usage. Verified by a new coordinator test on the commit-signal path that rejects all three forms and accepts the minimal valid shape.

AC-22 (formerly mixed-sentinel fallback): **REMOVED in v0.1.3.** v0.1.2 §3.6 mixed-sentinel rule was dropped per Critic H-3 (DoS vector against legitimate Qwen workflows). AC-22 is intentionally left as a placeholder so that downstream SPEC consumers tracking AC numbers do not silently re-index; AC numbers from AC-23 onward retain their v0.1.2 values.

AC-23. **Forward compatibility invariant (PD r2 Q-1, §10c) — reworked v0.1.3 to fix Critic H-1.** A v0.2-or-later regression test captures non-streaming tool-call response fixtures **from the candidate vN.M release** (with any new fields, deltas, or finish reasons enabled) and verifies that a **v0.1.3-baseline** client parser (OpenAI Python SDK pinned to the exact semver recorded in `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` — this file is committed as part of the v0.1.4 IMPL prompt obligation per §1.2, and is the externally-shipped baseline against which existing buyers integrate) successfully parses each response without raising on unknown fields and without rejecting due to schema validation. The v0.1.3-fixture-vs-v0.1.3-parser tautology direction that v0.1.2's AC-23 specified is explicitly NOT sufficient; the test MUST exercise the new-emission-shape-against-old-parser direction. Verified as a release gate for any SPEC-018 vN.M version that follows v0.1.3.

AC-24. **Coordinator request-side pass-through verification (Critic M-3 absorption).** Coordinator request-side `tool_calls[]` and `tool_call_id` pass-through fidelity is verified at the WebSocket frame layer by a unit test inspecting the outbound `InferenceRequest` frame for byte-equivalence with the buyer-supplied `tool_calls[]` and `tool_call_id` field bytes (after request validation per SPEC-001 / SPEC-002). The test does not require the provider to accept the request — it asserts that what the coordinator forwarded matches what the buyer sent. This closes the §6 normative-MUST-without-AC gap; AC-11 / AC-12 cover response-side fidelity, AC-24 covers request-side.

## 10. Future versions — Required, then Enhancement

### 10a. Required for full Ring-1 product (v0.2 normative targets)

Each item below is a v0.2 deliverable that gates the "actual Ring-1 product" release. A user running Cline / Aider / OpenCode / Continue / Vercel AI SDK against macprovider for real coding work needs ALL of these, not just some:

1. **Multi-turn provider acceptance.** Provider accepts `role: "tool"` messages and assistant-history `tool_calls[]` without rejecting at the provider boundary. Closes AC-14 limitation. This is the gate between v0.1 wire-shape-certificate and v0.2 actual-product.
2. **Model-hash → family registry (closes Security C-1 path (c)).** Extends the live SPEC-008 Pillar A + SPEC-011 v0.5 `model_hash` infrastructure already plumbed end-to-end in production: the `ModelHash` + `HashStatus` fields on the coordinator's pool/provider struct (`phase4-coordinator/internal/pool/provider.go:132-133`), heartbeat-driven `model_hash` updates (`phase4-coordinator/internal/pool/provider.go:1001-1052`), hash-verification routing eligibility (`phase4-coordinator/internal/buyer/server.go:3743-3764`), and the `/v1/status` `model_hash` block. v0.2 adds a registry mapping `model_hash` → tool-call grammar family on top of this infrastructure. The parser selects grammar from the verified loaded `model_hash`, not from the buyer-supplied `modelID` substring. **Buyer-facing impact:** prevents a provider from advertising a tool-call-capable model family while serving a different model or grammar. Design questions to resolve in v0.2 SPEC: where the registry lives (binary, coordinator-pushed catalog, community-signed root), curation model, and registry update frequency. Fail-closed semantics are pre-locked as a v0.1.3 invariant — see §10c.
3. **Prompt-echo guard.** Parser refuses to synthesize `tool_calls[]` whose entire markup (sentinel + body + close-sentinel) appears verbatim in the request prompt content. Closes the residual prompt-injection vector where a tool-call-capable model echoes hostile content from a poisoned user prompt.
4. **Token-incremental streaming promotion.** Tool-call streaming MAY emit `delta.tool_calls[].function.arguments` as additive partial substrings as generation proceeds. Release gate: SDK compatibility, byte-equivalence of concatenated deltas vs. non-streaming `arguments`, and parse-failure fallback tests pass. v0.1 ratifies buffered-to-end (§4); v0.2 promotes.
5. **Structured `malformed_tool_call` signal.** Parse failures (malformed body, duplicate keys, undeclared name, sentinel-without-modelID, depth/byte-cap exceeded) surface as a structured response-side signal — e.g. a `malformed_tool_call` field in the response object or a response header — so buyers can programmatically distinguish "normal model text" from "recognized tool-call parse failed." Replaces the current silent plain-content fallback observability gap (Security M-3).
6. **Multi-turn `tool_call_id` validation (Q3 closure).** Defines the buyer-side rule when a `role:"tool"` message echoes a `tool_call_id` that does not match any provider-minted ID — accept-and-treat-as-untracked, reject as `invalid_tool_call_id`, or behave per a SPEC-018-defined policy.
7. **`function.arguments` size cap (Q4 closure).** Defines a per-call and per-response cap on `function.arguments` byte length with fail-closed behavior. Closes the Security M-1 parser-DoS vector.

### 10b. Future enhancements (no committed version)

Items below are interesting but neither v0.2-gating nor on a named timeline:

- Structured output `response_format: {"type":"json_schema", ...}` response synthesis. (Same parser surface as tool calling; promoted when the wire contract for §10a #4 streaming-incremental stabilizes.)
- Prefix-cache request/response signaling. Requires SPEC-006 header-allowlist allocation (SPEC-006 owns the `X-MacProvider-*` namespace per its §2.X header-allowlist machinery); no concrete header name is reserved in SPEC-018.
- Per-call or per-response `max_tool_calls` cap.
- SDK examples or helper libraries (Python, TypeScript) for tool-call workloads. SDK packaging lives in SPEC-006 / a dedicated SDK SPEC, not in SPEC-018 — wire-shape is normative here, library packaging is downstream.
- Promotion of `id` minting from a per-response opaque UUID to a `(provider_id, request_id, choice_index)`-scoped identifier (Security M-2 v0.3+ candidate).

### 10c. Forward compatibility invariant (additive-only guarantee) + v0.1.3-locked v0.2 invariants

Future SPEC-018 versions (v0.2 and beyond) **MUST preserve the v0.1.3 non-streaming response shape** defined in §2 (`role`, `content`, `tool_calls[]` schema with `id`, `type`, `function.name`, `function.arguments`; `finish_reason = "tool_calls"`). A client that successfully parses a v0.1.3 non-streaming tool-call response MUST continue parsing the equivalent v0.2+ response without code changes.

**The `id` value format** defined in §2.1 (`call_<uuid-hex-lowercase-without-hyphens>` — fresh ≥122-bit-entropy UUID, lowercase hex without hyphens, `call_` prefix) is part of the protected shape (Critic M-4 absorption). Multiple OpenAI-shape SDK validators and downstream tooling have soft expectations that tool_call IDs begin with `call_`. Future ID rescope (§10b — promotion to a `(provider_id, request_id, choice_index)`-scoped identifier) MUST either preserve the `call_` prefix as a leading substring of the new format, or land via a **major** SPEC-018 version bump that explicitly retires §10c for the `id` field with operator notice.

Future versions MAY add new fields, new SSE delta shapes, or new finish reasons — but additions MUST NOT break existing parsing. Specifically:

- **Streaming improvements (§10a #4 token-incremental promotion)** MAY emit additive partial-string `function.arguments` deltas across multiple SSE events, but the concatenation of those deltas for a given `index` MUST reproduce the v0.1.3 byte-for-byte single-fragment behavior (AC-9).
- **Multi-turn (§10a #1)** MAY accept `role:"tool"` and assistant-history `tool_calls[]` request messages, but MUST NOT change the schema of the assistant tool-call response shape (§2) produced when a multi-turn request succeeds. (v0.2 promotion of AC-14's HTTP 400 error path to a success path is permitted under additive-only; the protection here is the shape of the successful response, not the error.)
- **Model-hash → family registry (§10a #2)** MAY change which providers are eligible to synthesize tool calls, but MUST NOT change the wire shape of synthesized calls.
- **Structured `malformed_tool_call` signal (§10a #5)** MAY add a new response field or header, but MUST NOT remove or rename existing v0.1.3 response fields.
- **`function.arguments` byte cap (§10a #7)** MAY cause a request to fail closed, but MUST NOT silently rewrite a tool call that would have succeeded under v0.1.3.

**v0.1.3-locked v0.2 invariant (Narrative Q-1 + Critic M-2 absorption — relocated from §10a #2).** The v0.2 model-hash → family registry MUST require unknown-or-unregistered `model_hash` to **fail closed** for tool-call synthesis: the response falls back to plain assistant content; no `tool_calls[]` are synthesized. v0.2 MUST NOT include a provider-operator-only override that bypasses this fail-closed semantics — operator-only overrides without buyer consent are non-compliant. A buyer-consent override IS permitted: the provider MAY perform tool-call synthesis under an unregistered `model_hash` if and only if (a) the buyer's request includes an explicit consent header (e.g. `X-MacProvider-Allow-Unregistered-Hash: <model_hash>`), AND (b) the response includes a mandatory field at `choices[0].message` scope indicating `model_hash_unregistered: true` so that downstream tooling can detect the consent path. The precise header name and response field name are deferred to the v0.2 SPEC; the buyer-consent invariant is locked here.

This invariant gives buyers a stable platform: code written against v0.1.3 wire shape continues to work in v0.2 and beyond, and security guarantees the v0.1.3 SPEC commits to cannot be silently bypassed by the v0.2 implementer. AC-23 (reworked v0.1.3, baseline-pin filename corrected v0.1.4, baseline version aligned v0.1.5) verifies the additive invariant via a regression test that captures vN.M responses and parses them with a v0.1.3-baseline parser (semver pinned in `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`).

## 11. Open Questions

Q1. **v0.2 release-readiness framework signal — product decision needed before v0.2 design.** v0.1 streaming is buffered-to-end for tool-enabled requests; promotion is committed to §10a #4 with a release gate. The product decision SPEC-018 v0.2 must answer: is v0.2 "Ring-1 release-ready" when (a) ONE primary agent framework (e.g. Cline) completes a multi-turn coding session against macprovider with incremental tool-call rendering, OR (b) a named OpenAI-wire compatibility matrix passes for ALL §1-listed frameworks (Cline, Aider, OpenCode, Continue, Vercel AI SDK, LangChain `ChatOpenAI`, LlamaIndex `OpenAI` LLM, Pydantic-AI `OpenAIModel`, n8n OpenAI node), OR (c) some middle ground (e.g. 3 named primary frameworks)? §1 names these frameworks as targets and explicitly excludes Claude Code (Anthropic Messages API) and Cursor IDE chat (proprietary backend) per the v0.1.3 framework-list correction; if the answer is (a), §1 should be reworded to name the primary framework explicitly and demote the others to "expected-compatible" status.

Q2. Should provider-minted tool-call IDs eventually be deterministic so retries reproduce the same IDs, or remain non-deterministic UUIDs? v0.1 is non-deterministic; §10b reserves a `(provider_id, request_id, choice_index)` rescope as a future enhancement.

Q5. How does SPEC-018 interact with SPEC-011 warm-swap if a model swap occurs mid-tool-call? Is the call invalidated, retried, or completed against the original model snapshot? This is a multi-SPEC design question that may need a SPEC-011 v0.6 amendment.

Q6. **RESOLVED in v0.1.1.** Content-sentinel-only detection is no longer normative (§3.2). Model-hash-bound grammar selection is committed to §10a #2. Prompt-echo guard is committed to §10a #3. Documented for change-log continuity.

Q7. Receipt canonicalization (SPEC-015 v0.3) covers canonicalized `tool_calls[]` in non-streaming output object. Does v0.4 need to additionally bind the raw model text (with delimiters) to detect parser-side rewriting, or is the canonicalized `tool_calls[]` binding sufficient evidence?

Q9. Should v0.2 or later preserve prose interleaved with tool calls as `message.content`, since the OpenAI contract permits content alongside `tool_calls[]`, or should macprovider continue discarding it (current §2.4)?

## 12. Non-Goals

Provider-side agent execution is not a SPEC-018 feature. A provider MUST NOT run buyer tools, shell commands, filesystem operations, network egress, MCP clients, or sandboxed agent loops under SPEC-018. That Ring-2 product is reserved for SPEC-019.

Provider-hosted MCP servers are not a SPEC-018 feature. A provider MUST NOT expose provider-local MCP servers to the model's tool loop under SPEC-018. That Ring-3 product is reserved for SPEC-020.

Buyer-side tool execution validation is not a SPEC-018 feature. macprovider transports `tool_calls[]`; it does NOT semantically validate them against the buyer's tool policy, the buyer's framework permissions, or any provider-side allowlist. The buyer-side agent framework is the authority on whether to execute (§1, AC-20).

Provider-side model-fingerprint validation (model_hash → family registry binding) is not a v0.1 feature; it is reserved for v0.2 per §10a #2.

Prompt-echo injection prevention is not a v0.1 feature; it is reserved for v0.2 per §10a #3.

SPEC-018 v0.1 does not define SDK convenience layers, structured-output `response_format`, prefix-cache headers, token-incremental tool-call streaming, or `max_tool_calls` rate caps. §10a names what v0.2 will add; §10b lists enhancements without a committed version.
