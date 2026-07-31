# SPEC-018 — Agentic tool calling (provider-side response synthesis)

**Version:** 0.2.7 (2026-07-31, Qwen3-Coder function-XML tool-call grammar amendment)
**Depends on:** SPEC-001 v1.6, SPEC-002 v1.5.5, SPEC-006 v0.9, SPEC-008 (Pillar A model-hash trust layer — referenced by §10a), SPEC-011 v0.5 (warm-swap heartbeat `model_hash` — referenced by §10a), SPEC-015 v0.3 (receipts canonical output binding — see AC-17)
**Status:** **LOCKED** at v0.2.7 by the Qwen3-Coder function-XML tool-call grammar amendment (documents the `<function=…><parameter=…>` XML body that Qwen3-Coder emits as a Qwen-row §3.1 body-grammar alternative, with OpenAI/MCP name charset; pending IMPL/conformance already landed on branch `fix/qwen3coder-toolcall-parse`); previously LOCKED at v0.2.6 by #784 C2b admission-timeout reconciliation — v0.2.4 spec PR #202 and IMPL PR #209 both landed (multi-turn acceptance, token-incremental streaming, `tool_call_id` validation, 1 MiB/2 MiB byte caps). v0.2.5 adds gpt-oss/OpenAI Harmony response parsing as a pending implementation/conformance gap. codex 4-lane r4 0/0/0; Claude blind-spot r2 0/0/0. SPEC-019 already depends on this as "LOCKED". The former "LOCK CANDIDATE pending PR" line was never flipped after merge. (Resolved gap, 2026-07-14, runbook item 15: AC-45's `X-MacProvider-Streaming-Mode` header — set by the coordinator on streaming `200` responses — was stripped by the public gateway's blanket `X-MacProvider-*` filter, making the "header absent" fail condition live on `api.streamvc.live`. Fixed by adding the header to the SPEC-006 v0.9.9 § 5.4 response-pass-through allowlist and un-stripping it at the gateway, validated against AC-45's closed enum. Chosen over scoping AC-45 to the coordinator surface because buyers hit the gateway, so scoping would have left AC-45's buyer-visible promise unmet. AC-45's normative text is unchanged; this is a documentation reconciliation, not a lock amendment. Residual: the coordinator currently emits the diagnostic only on the streaming success path — non-streaming AC-45 emission is a separate coordinator-side completeness item, out of scope for the gateway-strip fix.)

## Quick orientation

SPEC-018 is the **provider-side response synthesis contract** for OpenAI-wire tool-call compatibility. It tells provider Macs how to translate native LLM tool-call markup (Qwen3/Llama-3.3 family sentinels) into the OpenAI `tool_calls[]` JSON shape that buyer-side SDKs and agentic-coding frameworks expect.

- **v0.1.5 LOCKED** (`9e6f089` 2026-06-27): first-turn OpenAI tool-call wire-shape certificate. 9 OpenAI-wire frameworks listed as expected-compatible.
- **v0.2 SHIPS NOW**: Cline drop-in works. Anchor framework = Cline (https://github.com/cline/cline, ~1M+ VS Code marketplace installs). 4 deliverables: multi-turn provider acceptance, token-incremental streaming, `tool_call_id` validation, raised byte cap (1 MiB per-call / 2 MiB per-response).
- **v0.3 DEFERRED**: model-hash -> family registry (curation governance), full prompt-echo guard (whitespace-normalized + tool-scope-complete + self-DoS-tested), structured `usage.macprovider_malformed_tool_call` signal, framework-compatibility matrix beyond Cline.

**Lock-amendment precedent**: v0.2 deliberately amends 2 invariants via explicit named change-log entries with rationale (see §10c.1). v0.2 ships narrow + honest, not silently scope-cut.

**Money-path**: all v0.2 changes preserve v0.1.5 settlement protection (`FaultBreakerQualifying` + zero credits on malformed streams via `billing_recorder.go:176` + `formula.go:112`).

## Change log

**v0.2.7 buyer-visible deltas (read this if you're skimming):**
- v0.2.7 documents the `<function=NAME><parameter=key>value</parameter></function>` XML tool-call body as a recognized alternative body grammar for the §3.1 Qwen row. Qwen3-Coder emits this native XML form (not the `<tool_call>{json}` Hermes form) for many tool calls; the parser already handled it via the shared function-XML path, but §3.1 previously described only JSON/Python bodies for Qwen, so the grammar path was undocumented (and thus non-compliant under §3/§3.7).
- Function names and XML `<parameter=…>` property names in this grammar follow the OpenAI/MCP tool-name charset (`[A-Za-z0-9_-]`, ASCII), NOT Python identifiers. This unblocks MCP-namespaced tool names such as `buzz-dev-mcp__shell` (hyphens), which previously failed the Python-identifier check and leaked the tool call as plain assistant text. The §3.3 Python-identifier rule now applies only to Python-style call bodies.
- Streaming safety (§3.5) is preserved: the incremental tool-call emitter now enforces the declared-tool allowlist, so an undeclared function name is never surfaced as a streamed `tool_calls` delta before the final fail-closed check.
- No new buyer-visible error code, no gateway/coordinator error-taxonomy change, and no change to Llama-3.3 / Harmony byte behavior.

- **v0.2.7 (2026-07-31, Qwen3-Coder function-XML grammar amendment):** Amends the §3.1 Qwen row to add the `<function=…><parameter=…>` XML body grammar (shared with Nemotron) as an accepted body alternative, and §3.3 to scope the Python-identifier rule to Python-style bodies while function-XML names use the OpenAI/MCP charset. Adds AC-62 (hyphenated-name XML parse), AC-63 (streaming undeclared-name fail-closed), and AC-64 (XML hyphenated parameter name). The change is deliberately narrow: it documents an already-implemented parser path plus a name-validation bug fix and a streaming allowlist hardening; it does not reorder §3.1 rows, does not add a modelID trigger (Qwen row predicate unchanged), does not introduce a buyer-visible error code, and does not change Llama/Harmony byte behavior. This is an **additive** §3.1 grammar addition (a new body-grammar alternative on the existing Qwen row), following the v0.2.5 Harmony-row additive precedent — NOT a §10c.1 lock-amendment: no previously-LOCKED MUST is changed or removed. The existing Qwen JSON/Python body grammar and the §3.3 Python-identifier rule are preserved verbatim; function-XML is added alongside them, so §10c.1's (a)–(d) amendment-log bookkeeping does not apply.

**v0.2.6 buyer-visible deltas (read this if you're skimming):**
- v0.2.6 reconciles SPEC-018's informative gateway timeout co-requirement and AC-15a with SPEC-002 FR-P11a C2/C2b after #760/#784: gateway `coordinator_header_timeout_seconds` remains 300 by default, but deploy validation now requires effective `non_stream_request_seconds > coordinator routing.request_timeout_s` and rejects `coordinator_header_timeout_seconds < max(coordinator_admission_seconds, effective non_stream_request_seconds)`. No tool-call wire-shape change.

**v0.2.5 buyer-visible deltas (read this if you're skimming):**
- v0.2.5 adds gpt-oss/OpenAI Harmony as a §3.1 parser family keyed by `modelID` substring `gpt-oss`.
- Harmony response parsing is token-ID based, not decoded-marker regex based: hidden `analysis` and non-tool `commentary` channels are suppressed from `message.content`; only `final` channel body tokens can become assistant content.
- Valid declared `commentary to=functions.<name>` JSON calls terminated by the Harmony call token become OpenAI `tool_calls[]`. Malformed or undeclared Harmony calls fail closed using existing `malformed_tool_call_final_json`; no hidden-channel content or successful tool call may be emitted.
- Harmony `usage.completion_tokens` counts only final-channel content token IDs. A tool-call-only Harmony completion therefore reports zero completion tokens under #743 AC-60.

- **v0.2.5 (2026-07-26, #743 Harmony governance amendment):** Appends the gpt-oss/OpenAI Harmony family row to §3.1 without reordering existing rows, updates §3.2 so token-ID sentinels alone cannot trigger parsing without a matching `modelID`, adds §3.10 for token-ID response parsing, and adds AC-57 through AC-61. The amendment is deliberately narrow: it does not introduce a new buyer-visible error code, does not widen gateway/coordinator error taxonomy, and does not change Qwen/Llama byte behavior.

**v0.2.4 buyer-visible deltas (read this if you're skimming):**
- v0.2.4 is the SPEC PR candidate.
- AC-44 timing evidence keeps the 100 ms NTP-anchored skew bound and skew-corrected p95 calculation, but no longer cites SPEC-006 as the source of that prerequisite. NTP on provider Macs and gateway hosts is a v0.2 prerequisite for AC-44 measurability.
- AC-56 and `prompt_aggregate_too_large` are deleted. Aggregate prompt admission remains bounded by AC-50 raw request body cap, AC-51 aggregate tool-result cap, AC-52 aggregate assistant-history arguments cap, AC-53 message count, AC-54 total tool calls, and AC-55 linear validation.
- §3 now carries a local subsection-order note and an explicit §3.9 deleted stub pointing to §10c.1 Amendment 2.
- §10c.1 now states that v0.2.4 treats locked-content amendments and in-flight draft-content revisions under the same amendment discipline, with governance refinement deferred to v0.3.

- **v0.2.4 (2026-06-27, r4 polish):** Absorbs five non-blocking r4 polish findings after all r4 audit lanes returned READY TO LOCK. AC-44 removes the fabricated SPEC-006 NTP inheritance citation and makes NTP on provider Macs and gateway hosts a self-contained v0.2 prerequisite. AC-56 and its `prompt_aggregate_too_large` error code are deleted because the 6 MiB decoded-prompt cap was unreachable under the 4 MiB raw-body cap. §3 adds a subsection-order note and a local §3.9 deleted breadcrumb. §10c.1 adds a governance note that v0.2.4 applies the same (a)-(d) amendment discipline to locked-content amendments and in-flight draft-content revisions, while v0.3 may refine that distinction.

**v0.2.3 buyer-visible deltas (read this if you're skimming):**
- v0.2.3 is the codex-converged + Claude-blind-spot-absorbed lock candidate.
- v0.2.3 deletes the v0.2.1 minimal prompt-echo guard (§3.9) and ships WITHOUT prompt-echo mitigation; v0.3 owns the full guard. This is deliberate Path (a): the minimal guard was net-negative because whitespace bypass, tool-scope incompleteness, and SPEC-018 self-reading false positives made it worse than no guard.
- §10c.1 now names the lock-amendment discipline rule and amendment log. Silent scope cuts of locked invariants are non-compliant.
- Cline terminal-error coverage is split from openai-python coverage: AC-48a gates the openai-python ecosystem; AC-48b gates Cline v4.0.0 through `@ai-sdk/openai-compatible` (Vercel AI SDK) at `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`.
- Streaming auto-downgrade is per-(buyer, provider), bounded by a 3-malformed-streams / 5-minute threshold and 10-minute clean recovery; one adversarial buyer cannot downgrade other buyers on the same provider.
- Aggregate prompt admission now has a 6 MiB total decoded prompt cap (`prompt_aggregate_too_large`), and AC-44 timing evidence is NTP-skew-corrected.

- **v0.2.3 (2026-06-27, blind-spot absorption):** **Load-bearing amendment:** v0.2.3 amends §3.9 (v0.2.1-introduced minimal prompt-echo guard) — DELETED. v0.2.3 ships WITHOUT prompt-echo mitigation. Residual risk: a same-family model may emit a tool call whose markup appears verbatim in untrusted prompt content (for example, `role:"tool"` content from a `read_file` of a file containing native tool-call markup). v0.3 delivers the full guard with whitespace normalization, tool-description scope coverage, Cline-shaped false-positive testing, and proven absence of self-DoS via SPEC-018-self-reading case. Rationale: the v0.2 minimal guard had three exploitable defects (whitespace bypass on single newline, scope-incomplete around `tools[]` / `function.parameters` / `function.arguments`, self-DoS on legitimate Cline `read_file` of SPEC-018.md). Shipping the minimal guard was strictly worse than not shipping a guard. Path (a) precedent: when a defense feature is found to be net-negative under realistic conditions, delete it and document residual risk explicitly. **Second load-bearing edit:** §10c.1 promotes lock-amendment discipline to a named rule and amendment log. **Mechanics:** splits AC-48 into AC-48a/AC-48b for openai-python vs Cline/Vercel AI SDK, bounds AC-45 auto-downgrade by buyer/provider attribution and recovery, skew-corrects AC-44 timing, adds total decoded prompt cap + AC-56, reframes AC-46 as buyer-side type assertion plus provider self-test, adds the quick orientation and §10a reader note, preserves AC-number stability, and updates AC-25a for SPEC-018 self-reading coverage.

**v0.2.2 buyer-visible deltas (read this if you're skimming):**
- AC-46 now requires `usage.macprovider_model_hash_observed` on every v0.2 provider response, using a `null` sentinel when the provider has no known served model hash and lowercase SHA-256 hex when known.
- `prompt_echo_blocked` is an internal plain-content fallback/log reason in v0.2, not a buyer-visible HTTP/SSE error-envelope code.
- Aggregate request-cap and linear-validation release gates are now explicit in AC-50 through AC-55: raw body, aggregate tool-result content, aggregate assistant-history arguments, message count, total assistant tool calls, and O(messages[] + tool_calls[]) cross-message validation.

- **v0.2.2 (2026-06-27, r2 absorption):** Absorbs the seven round-2 findings. AC-46 and §10d.0.1 now use a single unknown-hash contract: every v0.2 response includes `usage.macprovider_model_hash_observed`, with `null` when no provider hash is known and lowercase 64-character SHA-256 hex when known; AC-25a release evidence captures the value while Cline remains required to ignore it. `prompt_echo_blocked` is removed from the buyer-visible v0.2 error-envelope table and remains only an internal log code for plain-content fallback. Mechanical edits update the live hash-routing citation, add AC-50 through AC-55 for aggregate request caps and linear validation, explain §10d's deliverable-numbered subsections, note why §3.8 physically precedes locked §3.7, and document that `invalid_tools` is inherited from SPEC-001 / SPEC-002 request validation.

**v0.2.1 buyer-visible deltas (read this if you're skimming):**
- v0.2.1 explicitly amends the §10c v0.1.3-locked clause requiring v0.2 unknown-`model_hash` registry fail-closed behavior: registry curation is deferred to v0.3, with rationale and precedent recorded instead of a silent scope cut.
- Minimal v0.2 mitigations replace the deferred registry for this narrow Cline drop-in slice: exact-verbatim prompt-echo blocking, tightened final-close settlement gating, and passive `usage.macprovider_model_hash_observed` observation.
- Streaming final-close is now protocol-complete: accumulated arguments, `finish_reason:"tool_calls"`, normal transport terminal marker, and no post-open disconnect/error are all required before provider-positive settlement.
- Terminal streaming failures use structured v0.2 error envelopes and MUST NOT report `finish_reason:"tool_calls"`; SDK exceptions/failed streams are expected on error paths.
- Cline release evidence is split into CI-amenable transcript fixtures and a manual VS Code extension smoke; tool coverage is expressed by categories with legacy/ClineCore name mapping.
- Buyers get a non-negotiating diagnostic `X-MacProvider-Streaming-Mode` response header on every v0.2 response.
- v0.2 request/streaming DoS bounds now include aggregate request caps, linear validation, and coordinator streaming-accumulator budgets.

- **v0.2.1 (2026-06-27, r1 absorption):** Absorbs the 22 round-1 audit findings. **Load-bearing amendment:** the "§10c v0.1.3-locked clause re v0.2 model-hash registry is amended in v0.2.0/v0.2.1 to defer registry to v0.3." Rationale: narrow v0.2 scope (Cline drop-in) makes registry curation strategically premature, and a binary-baked stub registry does not add real security value without curation governance. Precedent: locked invariants are NOT immutable, but they require an explicit named amendment with rationale; this is the first such amendment in SPEC-018. In lieu of the registry, v0.2.1 adds the §3.9 minimal prompt-echo guard, tightens §8.4.2 final-close, and adds AC-46 passive model-hash binding observation. **Second explicit lock amendment:** the duplicate v0.2 additive §3.7 heading is renumbered to §3.8 so locked §3.7 "Adding a new family" remains unambiguous. **Money path:** final-close failure now includes missing terminal argument state, missing `finish_reason:"tool_calls"`, missing transport completion marker, or any provider disconnect/timeout/relay/auth/truncation after incremental-open; all such paths are `FaultBreakerQualifying`, zero provider-positive credits, no receipt, and no sticky-route success write. **Streaming safety:** terminal error SSE events MUST NOT carry `finish_reason:"tool_calls"` and SDKs are expected to raise/failed-stream rather than deliver dispatchable tool calls. **Mechanics:** canonicalizes missing `tool_call_id` to `invalid_tool_call_id`, scopes AC-14/AC-8/AC-9 to v0.1.x, adds §10d reader/Cline rationale notes, updates v0.2 code citations, makes renderer fixtures implementation-verifiable against upstream Qwen3/Llama-3.3 chat templates, replaces placeholder SSE IDs, splits AC-25, instruments AC-44, adds `X-MacProvider-Streaming-Mode`, thickens v0.2 error envelopes, adds aggregate request/streaming budgets, and clarifies buyer-fabricated history as prompt data rather than provider provenance.

**v0.2.0 buyer-visible deltas (read this if you're skimming):**
- v0.2 is the narrow "Cline drop-in works" release: Cline is the release-gate framework; other OpenAI-wire frameworks remain expected-compatible observation, not release blockers.
- AC-14 transitions from provider-side `unsupported_tool_messages` error path to success path: valid `role:"tool"` messages and assistant-history `tool_calls[]` are accepted and rendered into the model's native tool prompt template.
- §8.4 gains a v0.2 split for token-incremental streaming: incremental-open permits buyer-visible streaming; final-close gates money-path settlement; no withdrawal to plain content is allowed after a tool-call delta is emitted.
- Response-side `function.arguments` caps rise from the v0.1.5 256 KiB DoS bound to 1 MiB per call and 2 MiB per response, with UTF-8 byte counting on the final unescaped argument string.
- Streaming is default for Cline-targeted compatible models, with an operator kill switch forcing buffered-to-end behavior and per-provider auto-downgrade on malformed incremental streams.
- Multi-turn `tool_call_id` validation is format-only and stateless: provider-emitted IDs keep `^call_[a-f0-9]{32}$`; request-accepted IDs use `^call_[A-Za-z0-9]{16,64}$` plus in-request cross-message consistency.
- v0.3 candidates are explicitly deferred: model-hash registry, prompt-echo guard, and structured `usage.macprovider_malformed_tool_call` exposure.

- **v0.2.0 (2026-06-27, narrow Cline-drop-in draft):** Adds the minimum surface required for "point Cline at macprovider and complete a real multi-turn coding session" on top of locked v0.1.5. **Multi-turn:** AC-14 is closed by requiring the phase3 provider to accept `role:"tool"` messages and assistant-history `tool_calls[]`, preserve `tool_call_id` / `tool_calls` through request parsing, validate the in-request graph, and render prior assistant tool calls plus tool results into the selected model family's native chat-template markup. Current rejection paths are `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:909`, call sites `:353` and `:403`, with exact rejects at `:924` and `:931`; `ChatCompletionRequest.swift:194` / `:202` already validate the structured shapes but `ChatMessage` at `:175` must preserve fields that are currently lost before `request.messages.map { $0.mlxMessage }` at `ModelRuntime.swift:374`, `:428`, and `:513`. **Family renderer:** adds a v0.2 tool prompt-template profile for the input render direction, separate from §3.1 output parser-family selection; v0.2 keys it by modelID-match per §3.2, while the v0.3 registry candidate will move it to verified `model_hash`. **Request caps:** `role:"tool"` content is capped at 256 KiB UTF-8 bytes per message with HTTP 413 `tool_result_too_large`; assistant-history `function.arguments` is capped at 1 MiB with HTTP 413 `tool_call_arguments_too_large`. **Receipts:** no schema change; `PromptCanonicalizer.swift:5` already canonicalizes `messages`, including `tool_call_id` and `tool_calls` at `:31`, but v0.2 requires regression tests proving `prompt_hash` changes when those fields change. **Streaming:** promotes token-incremental OpenAI-style `tool_calls[].function.arguments` deltas, keyed by `index`, with first delta carrying `id` / `type` / `function.name` and later deltas carrying argument fragments. §8.4 is extended with incremental-open, final-close, and no-withdrawal rules; the current coordinator validator at `phase4-coordinator/internal/buyer/server.go:2674` is incompatible with OpenAI incremental fragments and must be replaced for both `forwardWSStreaming` (`server.go:2103`, buyer byte write at `:2149`) and `forwardStreaming` (`server.go:2279`). **Money path:** buyer-visible streaming commit happens at incremental-open, while provider-positive settlement commits only after final-close; mid-stream cap-cross or final-close failure remains `FaultBreakerQualifying` with zero provider-positive credits through existing `phase4-coordinator/internal/buyer/billing_recorder.go:176` and `phase4-coordinator/internal/billing/formula.go:112`. **Argument caps:** replaces the v0.1.5 response-side 256 KiB DoS bound with public v0.2 constants `1_048_576` bytes per call, `2_097_152` bytes per response, and depth `32`, identical at parser and coordinator. **Forward compatibility:** extends AC-23 with AC-23s streaming regression using `openai==2.44.0`, and adds §10c cap invariants that future v0.2.x may raise but not lower the caps or change the inclusive UTF-8 unescaped counting domain. **Deferred:** model-hash registry, prompt-echo guard, and structured `usage.macprovider_malformed_tool_call` remain v0.3 candidates only; v0.2 may use internal failure reasons for logs and terminating SSE error frames but does not expose the v0.3 usage schema.

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

**Subsection note**: §3 numbering is non-sequential (§3.1–§3.6, then §3.8, then §3.7) by intentional v0.2.1 lock-amendment (§3.8 inserted before §3.7 to avoid moving locked v0.1.5 content). §3.9 (v0.2.1-introduced minimal prompt-echo guard) was DELETED in v0.2.3 — see §10c.1 Amendment 2.

### 3.1 Family table

| Family | `modelID` match (required) | Body grammar | Argument field | Source |
|---|---|---|---|---|
| Qwen (2.5 / 3 / Coder variants) | `modelID` substring contains `qwen2.5` OR `qwen3` (case-insensitive) | ONE OF: `<tool_call>{...}</tool_call>` JSON body; `<tool_call>name(key=value, ...)</tool_call>` Python-style call; OR (v0.2.7) the `<function=name><parameter=key>value</parameter></function>` XML body (Qwen3-Coder native form, shared with Nemotron; may appear with or without an enclosing `<tool_call>` wrapper). The parser tries JSON body first, then Python-style, then function-XML. | `arguments` preferred for JSON body; `parameters` accepted as JSON-body fallback; keyword args for Python-style body; `<parameter=…>` keys for function-XML body | `ToolCallParser.swift` `parseDelimited`/`parseJSONCall`/`parsePythonStyleCall` (JSON + Python), `parseBareNemotronCalls`/`parseNemotronXMLCall`/`nemotronParameterObject` (function-XML) |
| Llama 3.3 MLX | `modelID` substring contains `llama-3.3` (case-insensitive) | `<\|python_tag\|>{...}<\|eom_id\|>` JSON body, OR `<\|python_tag\|>name(key=value)<\|eom_id\|>` Python-style body (JSON body parsing tried first) | `parameters` preferred for JSON body; `arguments` accepted as JSON-body fallback; keyword args for Python-style body | `ToolCallParser.swift:451-491` |
| gpt-oss / OpenAI Harmony | `modelID` substring contains `gpt-oss` (case-insensitive) | OpenAI Harmony response frames parsed from generated token IDs: channel/header/body spans are delimited by Harmony structural tokens, not by decoded sentinel-text search. Only `final` channel bodies become assistant content; valid `commentary to=functions.<name>` frames terminated by the Harmony call token become OpenAI tool calls. | JSON object body of a declared `commentary to=functions.<name>` call; no `arguments` / `parameters` wrapper is inferred. | `HarmonyResponseParser.swift` |

Note: production Qwen-coding SKUs (e.g. `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`, `mlx-community/Qwen3-32B-4bit`) match the Qwen family row via `qwen2.5` or `qwen3` substring. There is no separate "coding-tuned" row in §3.1 — coding-tuned variants advertise as Qwen2.5/Qwen3 derivatives and select the same family; body-grammar disambiguation is performed by the parser per the OR rule above.

### 3.2 modelID match required (Security C-1 (a))

Family detection MUST require a `modelID` substring match against §3.1. Content-sentinel detection alone (the presence of `<tool_call>` or `<|python_tag|>` in raw model output without a matching `modelID`) is NOT a normative trigger in v0.1. Harmony token-ID sentinel detection alone (the presence of Harmony structural token IDs without a `gpt-oss` `modelID` match) is likewise NOT a normative trigger in v0.2.5. Output containing recognized text sentinels or Harmony structural token IDs but no §3.1 family match MUST be emitted as plain assistant content through the non-matching path; no `tool_calls[]` are synthesized.

A request with a **missing, empty, or whitespace-only `modelID`** MUST be treated as no §3.1 family match for §3.2 purposes; the response falls back to plain assistant content per §3.5. (SPEC-001 normally requires the field at request validation; §3.2 pins the defensive default in case validation is loosened.)

Rationale: the v0.1 design closes the prompt-injection vector identified in Security C-1 / Q6, where a model could be prompted to echo `<tool_call>{"name":"declared_tool",…}</tool_call>` and the parser would synthesize a legitimate-looking tool call. v0.2.5 applies the same boundary to Harmony structural token IDs: token-ID framing is only meaningful for a declared Harmony-capable `gpt-oss` model family, and decoded marker-looking bytes are data outside that family. With `modelID` match required, a provider that has not advertised a tool-call-capable family does not synthesize tool calls regardless of model output content. (modelID is a self-declared string the provider chooses freely. v0.1 still trusts the provider's modelID assertion; the residual case — a tool-call-capable model echoing hostile content, OR a malicious provider lying about modelID while serving different weights — is closed in v0.3 via the §10a model-hash → family registry binding on top of the SPEC-008 Pillar A `model_hash` infrastructure, plus the prompt-echo guard.)

### 3.3 Body parsing

For JSON bodies, the body MUST parse as a JSON object with a non-empty string `name`. For Python-style bodies, the body MUST parse as `name(key=value, ...)` where `name` and keys are Python identifiers and values are supported string, boolean, null, integer, or decimal literals.

For function-XML bodies (v0.2.7), the `<function=NAME>` name and every `<parameter=KEY>` name MUST match the OpenAI/MCP tool-name charset — ASCII `[A-Za-z0-9_-]`, with function names 1–64 characters and parameter (property) names 1–128 characters — and NOT the Python-identifier rule above. Rationale: `NAME` is an OpenAI function name and `KEY` becomes a JSON-Schema property key in `function.arguments`; both legitimately contain hyphens (e.g. MCP-namespaced `buzz-dev-mcp__shell`), which are not Python identifiers. A name outside this charset (or over length) is a parse failure and falls back to plain assistant content per §3.5. The declared-tool allowlist (§3.5) remains the security boundary: a well-formed function-XML name that is not in the request's enabled tools still fails closed.

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

### 3.8 Tool prompt-template profile (multi-turn input rendering, v0.2 additive)

**v0.2.0/v0.2.1 numbering note:** this additive tool-prompt-template-profile section is renumbered to §3.8 to avoid a heading collision with locked §3.7 "Adding a new family." This is an explicit v0.2.1 lock amendment; no other §3 locked numbering is changed.

**Editorial note:** §3.8 (v0.2 additive) physically precedes §3.7 (locked v0.1.5 "Adding a new family") in document order. This is intentional to avoid moving locked v0.1.5 content. Logical reading order is §3.7 first (family-table additions), then §3.8 (prompt-template profile for multi-turn render direction).

v0.2 adds a separate tool prompt-template profile for the **input render direction**: OpenAI `messages[]` history, including assistant-history `tool_calls[]` and `role:"tool"` results, MUST be rendered into the selected model family's native chat-template markup before inference.

This profile is intentionally separate from the §3.1 parser-family registry. §3.1 handles the **output parse direction** (native model markup → OpenAI `tool_calls[]`). The v0.2 tool prompt-template profile handles the inverse **input render direction** (OpenAI `messages[]` → native model markup). Implementations MUST NOT assume that adding an output parser row automatically defines correct multi-turn input rendering for that family.

In v0.2, the prompt-template profile is keyed by the same family selection rule as §3.2: `modelID` substring match against §3.1 table predicates, with §3.6 table-order priority. A request with no matching family MUST NOT render assistant-history `tool_calls[]` into native tool-call markup. The v0.2 profile-key rule is a compatibility bridge only; the v0.3 registry candidate will move profile selection to verified `model_hash`.

For a matched family, the renderer MUST preserve conversation order and MUST render:

- user, system, and plain assistant messages according to the model's ordinary chat template;
- assistant-history `tool_calls[]` as that family would have emitted them in model-native tool-call markup, preserving each `id`, `type`, `function.name`, and `function.arguments` value after request validation;
- each `role:"tool"` message as the family-native tool-result block associated with the exact `tool_call_id`;
- empty `role:"tool"` `content` as an empty tool-result payload, not as missing content.

The renderer MUST run only after §10d.6 request-side `tool_call_id` validation succeeds. It MUST NOT use session-scoped state to decide whether to render a request-side ID. Cross-session Cline resume and buyer-fabricated but internally consistent IDs are accepted per §10d.6.

Source obligation for v0.2 IMPL: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:194` already validates assistant `tool_calls[]` and `:202` validates tool messages, but `ChatMessage` at `:175` currently stores only `role` and `content`; v0.2 must preserve `toolCallID` and `toolCalls` through request parsing and replace `request.messages.map { $0.mlxMessage }` at `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:374`, `:428`, and `:513` with a renderer that sees the full OpenAI message objects.

#### 3.8.1 Renderer fixture input and family structures

The v0.2 IMPL MUST add golden tests for Qwen3 and Llama-3.3 family rendering. If upstream tokenizer chat templates provide byte-exact tool-call/tool-result rendering for the selected model artifact, the fixture output MUST be byte-exact against that upstream template. Where upstream documentation is not directly byte-stable in this SPEC, the fixture MUST at minimum enforce the normative structure below and record the exact upstream tokenizer-config commit or artifact digest used by the implementation. Implementation references: Qwen3 tokenizer config at `https://huggingface.co/Qwen/Qwen3-32B/blob/main/tokenizer_config.json`; Llama-3.3 tokenizer config at `https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct/blob/main/tokenizer_config.json`.

Common fixture input:

```json
[
  {"role": "user", "content": "Read README.md"},
  {
    "role": "assistant",
    "content": null,
    "tool_calls": [
      {
        "id": "call_0123456789abcdef0123456789abcdef",
        "type": "function",
        "function": {
          "name": "read_file",
          "arguments": "{\"path\":\"README.md\"}"
        }
      }
    ]
  },
  {
    "role": "tool",
    "tool_call_id": "call_0123456789abcdef0123456789abcdef",
    "content": "{\"content\":\"hello\\n\",\"path\":\"README.md\"}"
  },
  {"role": "user", "content": "Now summarize it"}
]
```

Qwen3 renderer fixture structure:

- ordinary turns use the Qwen3 chat-template user/assistant turn boundaries from the selected upstream tokenizer config;
- the assistant-history call is rendered as a complete Qwen-native tool-call block using `<tool_call>` and `</tool_call>` framing;
- the rendered tool-call body preserves `name = "read_file"` and the exact validated OpenAI `function.arguments` bytes as the native argument object content;
- the tool result is rendered as the Qwen-native tool-response block associated with `call_0123456789abcdef0123456789abcdef`;
- the final user turn follows the tool-result block without dropping or reordering any prior turn.

Llama-3.3 renderer fixture structure:

- ordinary turns use the Llama-3.3 chat-template role/header/end-token boundaries from the selected upstream tokenizer config;
- the assistant-history call is rendered as a complete Llama-native tool-call block using the family tool-call markup selected by the Llama-3.3 tokenizer config, including the `<|python_tag|>` / `<|eom_id|>` tool-call boundary where that template requires it;
- the rendered tool-call body preserves `name = "read_file"` and the exact validated OpenAI `function.arguments` bytes mapped to the template's native argument field;
- the tool result is rendered as the Llama-native tool-result block associated with `call_0123456789abcdef0123456789abcdef`;
- the final user turn follows the tool-result block without dropping or reordering any prior turn.

If no §3.8 family profile maps for the request `modelID`, a multi-turn request containing assistant-history `tool_calls[]` or `role:"tool"` messages MUST fail before inference with HTTP 400 `unsupported_modelID_for_multi_turn`. It MUST NOT silently render the structured fields as plain text or drop them.

### 3.7 Adding a new family

A new model family's tool-call grammar MUST land via a SPEC-018 version bump that updates §3.1 and §3.2. Parser PRs MUST NOT mutate this table silently. A parser change that adds a new detector, sentinel, modelID match, or grammar path without a corresponding SPEC-018 §3 update is non-compliant.

**Row-ordering invariant.** New rows MUST be appended at the end of §3.1. New-row `modelID` predicates MUST be disjoint from all existing predicates — a new predicate that is a substring of an existing predicate (or vice versa) would silently change which family selection applies to existing modelIDs and requires a **major** SPEC-018 version bump, not a minor or patch bump.

### 3.9 [DELETED v0.2.3]

The v0.2.1-introduced minimal prompt-echo guard was DELETED in v0.2.3. See §10c.1 Amendment 2 for rationale (minimal guard had three exploitable defects: whitespace bypass, scope-incomplete, self-DoS via Cline reading SPEC-018.md). Full echo guard is a v0.3 deliverable.

### 3.10 gpt-oss / OpenAI Harmony token-ID response parsing (v0.2.5 additive)

Harmony response parsing is token-ID parsing. A compliant implementation MUST preserve generated token IDs through response synthesis for `gpt-oss` modelIDs and MUST NOT infer Harmony channels by searching decoded text for marker-looking strings.

The v0.2.5 Harmony structural token IDs are:

| Meaning | Token ID |
|---|---:|
| channel marker | `200005` |
| start marker | `200006` |
| end marker | `200007` |
| message marker | `200008` |
| constrain marker | `200003` |
| return marker | `200002` |
| call marker | `200012` |

Normative rules:

1. **Visible content:** `choices[0].message.content` is the concatenation of completed `final` channel body token spans only, except for the narrow visible-final truncation case defined in rule 5. `analysis` channel bodies and all non-tool `commentary` channel bodies MUST NOT appear in `message.content`, streaming `delta.content`, logs intended as buyer-visible response data, receipts, or usage-visible content accounting. A Harmony response with tool calls and no final-channel content uses the existing OpenAI tool-call content behavior (`message.content = null`).
2. **Structured tool calls:** A completed `commentary` frame whose header contains exactly one recipient of the form `to=functions.<name>`, whose `<name>` is declared in the request's enabled tools, whose body is a valid JSON object, and whose terminator is the Harmony call token MUST be converted into one OpenAI `tool_calls[]` entry with `type:"function"`, `function.name = <name>`, and `function.arguments` equal to the JSON object string after validation. The generated `id` MUST continue to satisfy §2.1. The body is the argument object itself; Harmony parsing MUST NOT require or synthesize an `arguments` or `parameters` wrapper.
3. **Fail closed:** Malformed Harmony framing, duplicate or invalid tool-call JSON, a function recipient not declared in request tools, a function-recipient frame not terminated by the Harmony call token, or a call-token terminator in `analysis` or non-function `commentary` is a final-close failure. The buyer-visible error code MUST reuse existing retryable `malformed_tool_call_final_json`; v0.2.5 does not define a new buyer-visible error code. On this path no hidden-channel content and no successful `tool_calls[]` may be emitted, and the implementation MUST NOT fall back to raw decoded Harmony text because that would leak hidden channels.
4. **Streaming parity and marker leakage:** Streaming Harmony parsing MUST operate over generated token IDs, either incrementally or from cumulative snapshots, and expose only complete visible units allowed by rules 1 and 2. Partial structural prefixes, channel headers, hidden-channel bodies, constrain labels, and Harmony markers MUST NOT leak into SSE `delta.content` or terminal error bodies. For a successful completion, the final non-streaming response and the accumulated streaming response MUST agree on visible final content and `tool_calls[]` semantics.
5. **Token accounting and visible-final truncation:** For Harmony responses, buyer API `usage.completion_tokens` MUST count only token IDs in `final` channel body spans that become buyer-visible assistant content. Structural Harmony tokens, `analysis` body tokens, `commentary` body tokens, tool-call JSON body tokens, constrain/header tokens, and call/end/return markers MUST NOT contribute to API `completion_tokens`. This buyer-visible usage rule does not redefine receipt or settlement accounting: receipt/settlement `tokens_out` remains the actual generated output token count per SPEC-015 and the settlement profile. A Harmony completion that emits only tool calls and no final-channel content therefore has API `completion_tokens = 0` while receipt/settlement `tokens_out` records the generated Harmony tokens. If generation ends by `length` or request stop while already inside a `final` channel body, the implementation MAY expose the filtered final-body prefix generated so far and count only those emitted final-body tokens in API usage; this exception does not apply to hidden `analysis`, `commentary`, role/header, constrain, or function-call JSON spans, which remain fail-closed as `malformed_tool_call_final_json` when structurally incomplete. If a request stop is observed inside the visible final-body prefix, later Harmony frames and tool calls MUST be suppressed.
6. **Non-Harmony byte identity:** If the request `modelID` does not match the §3.1 Harmony row, the Harmony parser MUST be bypassed. Non-Harmony decoded output bytes and existing Qwen/Llama parser behavior MUST remain byte-identical to v0.2.4 for the same generated text and token IDs.

## 4. Streaming Wire Shape

When `stream = true`, the buyer-visible response MUST use OpenAI-style SSE chat-completion chunks.

The v0.1 as-built streaming behavior is buffered-to-end for tool-enabled requests. It is not token-incremental for tool calls. v0.2 promotes token-incremental streaming per §10a.

**v0.2 applicability note:** §4 describes v0.1.x buffered-to-end streaming behavior. For v0.2.0+, §10d.4 and AC-40 through AC-45 are authoritative for tool-call streaming. The §4 buffered behavior remains the v0.1.x ratification language, including AC-8 and AC-9.

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

c823a96 raised the default to 60 seconds; the current as-built gateway default is 300 seconds with validation requiring `coordinator_header_timeout_seconds >= max(coordinator_admission_seconds, effective non_stream_request_seconds)` and deploy validation requiring effective `non_stream_request_seconds > coordinator routing.request_timeout_s`.

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

#### 8.4.1 Incremental-open validator (v0.2 token-incremental streaming)

For v0.2 token-incremental streaming, the v0.1.5 commit-worthy validator above is split. Before emitting or forwarding **any** SSE chunk containing `choices[].delta.tool_calls[]`, the provider and coordinator streaming paths MUST run an incremental-open validator.

The incremental-open validator MUST verify:

- the model family is verified for v0.2 tool-call streaming under the active family-selection rule;
- `function.name` is non-empty and declared in the request's enabled tools;
- `index` is stable for the tool call accumulator and is an integer ≥ 0;
- `id` has been minted for provider-emitted calls and matches the provider-emitted `^call_[a-f0-9]{32}$` domain;
- `type == "function"`;
- the first `function.arguments` value is a JSON-string fragment that can be concatenated into the eventual OpenAI `function.arguments` string.

Passing incremental-open permits buyer-visible streaming commit: the provider may start emitting OpenAI-style `tool_calls[].function.arguments` fragments keyed by `index`. It does **not** commit provider-positive settlement.

The current complete-JSON validator around `phase4-coordinator/internal/buyer/server.go:2674` is incompatible with OpenAI incremental fragments and MUST be replaced for streaming with the incremental-open / final-close pair in §8.4.1 and §8.4.2. This applies to both `forwardWSStreaming` (`phase4-coordinator/internal/buyer/server.go:2103`, buyer byte write at `:2149`) and `forwardStreaming` (`phase4-coordinator/internal/buyer/server.go:2279`).

#### 8.4.2 Final-close validator (v0.2 token-incremental streaming)

At end-of-stream, before provider-positive settlement is finalized, the provider and coordinator MUST run a final-close validator over the accumulated tool-call state.

The final-close validator MUST verify:

- every opened `tool_calls[].index` has a terminal accumulated argument string and no partial-open tool call remains at end-of-stream;
- each concatenated `function.arguments` value parses as a JSON object;
- decoded JSON depth is ≤ 32;
- each call's final unescaped `function.arguments` UTF-8 byte length is ≤ 1_048_576 bytes;
- the sum of all final unescaped `function.arguments` UTF-8 byte lengths in the response is ≤ 2_097_152 bytes;
- the stream emitted `finish_reason: "tool_calls"` for the choice;
- the transport reached its normal completion marker: `data: [DONE]` for HTTP SSE, or provider relay `complete` for WS-backed forwarding;
- no provider disconnect, timeout, relay error, authentication failure, truncation, or missing terminal marker occurred after incremental-open.

Only final-close success permits money-path settlement commit. Absence of any one required final-close condition is final-close failure. Mid-stream cap-cross, malformed final JSON, non-object final arguments, depth overflow, per-call cap overflow, aggregate cap overflow, partial-open end state, missing `finish_reason:"tool_calls"`, missing normal completion marker, provider disconnect, timeout, relay error, authentication failure, truncation, or missing terminal marker after incremental-open is `FaultBreakerQualifying` and MUST settle zero provider-positive credits through the existing `phase4-coordinator/internal/buyer/billing_recorder.go:176` and `phase4-coordinator/internal/billing/formula.go:112` paths. These paths are unchanged by v0.2. Final-close failure MUST also produce no receipt for the turn and no sticky-route success write.

Existing coordinator paths already distinguish some post-commit transport failures: WS post-commit disconnect/timeout handling records `FaultBreakerQualifying` at `phase4-coordinator/internal/buyer/server.go:2239-2255`; direct-HTTP post-commit disconnect records it at `:2476-2487`; direct-HTTP clean EOF currently succeeds at `:2469-2471` and must be treated as clean for v0.2 tool-call streaming only if the final-close terminal conditions above are present.

#### 8.4.3 No withdrawal after streamed tool-call emission

OpenAI-style streaming has no primitive for withdrawing an already-emitted `tool_calls[]` delta. Once any `choices[].delta.tool_calls[]` chunk has been emitted to the buyer, the provider MUST NOT fall back to plain assistant content for that response.

If final-close fails after any tool-call delta has been emitted, the stream MUST terminate with an OpenAI-style `error` object on a terminating SSE event if the buyer connection can still be written, followed by `data: [DONE]`. The terminal-error SSE event MUST NOT carry `finish_reason: "tool_calls"`. The chunk that crosses a cap or violates final-close MUST NOT be forwarded. Buyer SDKs, including `openai-python` v2.44.0+ and openai-node, MUST surface the terminal error frame as an exception or failed stream, not as a successful assistant message with dispatchable `tool_calls[]`. v0.2 may include internal failure reasons in logs and the terminating error object, but it MUST NOT expose the v0.3 `usage.macprovider_malformed_tool_call` schema.

The buyer-visible streaming commit therefore happens at incremental-open; the settlement commit happens only at final-close. This preserves Cline-visible progress without allowing malformed or oversized provider output to earn provider-positive credits.

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

AC-8. Streaming tool-call responses emit one complete `delta.tool_calls[]` event after generation completes, followed by a terminator chunk with `finish_reason == "tool_calls"`. For v0.2.0+, this v0.1.x buffered behavior is superseded by §10d.4 and AC-40 through AC-45.

AC-9. Concatenating streamed `function.arguments` fragments by `index` reproduces the non-streaming `function.arguments` string byte-for-byte. In v0.1 this is a single-fragment concatenation. For v0.2.0+, §10d.4 and AC-40 through AC-45 define token-incremental streaming.

AC-10. `delta.content` and `delta.tool_calls` do not appear in the same SSE event.

AC-11. Coordinator WebSocket relay preserves provider-emitted `tool_calls[]` JSON across `InferenceResponseChunk.data` without stripping, reordering, or canonicalizing fields.

AC-12. Gateway non-streaming and streaming forwarding preserves provider-emitted `tool_calls[]` fields without semantic rewriting.

AC-13. `tool_choice` values other than omitted, `null`, or `"auto"` fail with HTTP 400 code `unsupported_tool_choice` at the current provider boundary.

AC-14. Current provider requests containing `role: "tool"` messages or assistant-history `tool_calls[]` fail with HTTP 400 code `unsupported_tool_messages`. (v0.1 ratifies this as the first-turn-only limitation; closed in §10a v0.2.) For v0.2.0+, AC-14 is superseded by AC-26 and AC-27; the v0.1.x error path is no longer the desired behavior, and the v0.2.0 success path is. AC-14 remains in the SPEC for historical lock discipline.

AC-15a. **Code default + validation (CI-verifiable).** Gateway default `coordinator_header_timeout_seconds` is 300; validation rejects configurations where `coordinator_header_timeout_seconds < max(coordinator_admission_seconds, effective non_stream_request_seconds)`, and deploy validation rejects configurations where effective `non_stream_request_seconds <= coordinator routing.request_timeout_s`. `coordinator_request_seconds` may exceed the header timeout only when `non_stream_request_seconds` is explicitly set to a shorter value covered by the header timeout and the cross-component coordinator wall remains ordered correctly. Verified by `phase5-gateway/internal/config/config_test.go:30-90` and `phase4-coordinator/dist/check-deploy-config.sh`.

AC-15b. **Live deploy evidence (release smoke / manual evidence).** Live tool-call workload deployments configure effective `timeouts.non_stream_request_seconds > coordinator routing.request_timeout_s` and `timeouts.coordinator_header_timeout_seconds >= max(coordinator_admission_seconds, effective non_stream_request_seconds)`. Verified by the deploy-gate script `phase4-coordinator/dist/check-deploy-config.sh` C2/C2b and an operator-recorded JSON artifact from the live gateway YAML.

AC-16a. **First-turn wire-shape smoke (CI-local).** An OpenAI Python SDK 1.x client pointed at the buyer URL parses the first assistant tool-call response for the canonical `get_weather`-style loop without response adapters. Covered by `test/integration/tool_calling/openai_tool_call_e2e.py:14-18`, `:147-165`.

AC-16b. **Framework-level smoke (release smoke / manual evidence).** When v0.1 is configured against at least one OpenAI-wire-native agent framework (one of: Cline, Aider, OpenCode, Continue, Vercel AI SDK), the framework's chat-completions client returns successfully from the first assistant tool-call response (i.e. the SDK's return-handling completes without raising; the framework's agent loop reaches the "decide whether to execute the tool" step) without macprovider-specific adapters. Per AC-14, the second turn is expected to fail; the framework-level smoke confirms first-turn shape parity reaches the framework's execute-decision boundary, not multi-turn loop completion. Claude Code, Cursor IDE chat, and other non-OpenAI-wire frameworks are explicitly NOT v0.1 compatibility targets (see §1).

AC-17. For non-streaming receipt-bearing responses, SPEC-015 v0.3 §5.1–§5.3 canonical output object includes canonicalized `tool_calls[]` when tool calls are emitted. (Streaming receipts are out of scope per SPEC-015 v0.3.)

AC-18. A non-streaming Qwen3-Coder-class tool-call response completes through any production gateway deployment satisfying the SPEC-002 / SPEC-006 timeout invariants. Marked as **release smoke / manual evidence**: the integration runner `test/integration/tool_calling/openai_tool_call_e2e.py` produces a JSON artifact recording the `OPENAI_BASE_URL`, model SKU, response shape, and completion latency. v0.1 does not pin a specific public deployment URL.

AC-19. **modelID-match-required (Security C-1 (a)).** A request with enabled tools whose `modelID` does NOT substring-match any §3.1 family row produces no `tool_calls[]`, even when the underlying model output contains recognized sentinel markup (`<tool_call>`, `<|python_tag|>`). The response is emitted as plain assistant content.

AC-20. **Buyer-side validation obligation visibility (Security C-1 (b)).** Public documentation (README, examples, AC-16a/AC-16b harnesses) MUST state that emitted `tool_calls[]` reflect model output, not provider-verified intent, and that buyer-side agent frameworks MUST validate before execution. macprovider MUST NOT semantically validate `tool_calls[].function.name` or `function.arguments` against the buyer's tool policy.

AC-21. **Commit-worthy delta minimal-shape validation + DoS bounds (Security H-1 + Critic M-1).** The coordinator commit-signal code path (§8.4) MUST validate that any `delta.tool_calls[]` event chosen as commit-worthy has integer `index`, non-empty `id` string, `type == "function"`, non-empty `function.name`, and `function.arguments` as a JSON string whose decoded value is a JSON object with nesting depth ≤ 32 and byte length ≤ 256 KiB. Malformed or oversized pre-commit deltas — including `[{}]` (empty tool-call object), `{"function":{"arguments":"[]"}}` (arguments decodes to non-object), and `{"function":{"arguments":"<256-KiB-of-nested-objects>"}}` (exceeds depth or byte cap) — MUST NOT commit the response or settle provider-positive usage. Verified by a new coordinator test on the commit-signal path that rejects all three forms and accepts the minimal valid shape.

AC-22 (formerly mixed-sentinel fallback): **REMOVED in v0.1.3.** v0.1.2 §3.6 mixed-sentinel rule was dropped per Critic H-3 (DoS vector against legitimate Qwen workflows). AC-22 is intentionally left as a placeholder so that downstream SPEC consumers tracking AC numbers do not silently re-index; AC numbers from AC-23 onward retain their v0.1.2 values. AC numbers are stable across SPEC-018 versions; once assigned, an AC number is never reused or renumbered, even if the AC content is amended.

AC-23. **Forward compatibility invariant (PD r2 Q-1, §10c) — reworked v0.1.3 to fix Critic H-1.** A v0.2-or-later regression test captures non-streaming tool-call response fixtures **from the candidate vN.M release** (with any new fields, deltas, or finish reasons enabled) and verifies that a **v0.1.3-baseline** client parser (OpenAI Python SDK pinned to the exact semver recorded in `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` — this file is committed as part of the v0.1.4 IMPL prompt obligation per §1.2, and is the externally-shipped baseline against which existing buyers integrate) successfully parses each response without raising on unknown fields and without rejecting due to schema validation. The v0.1.3-fixture-vs-v0.1.3-parser tautology direction that v0.1.2's AC-23 specified is explicitly NOT sufficient; the test MUST exercise the new-emission-shape-against-old-parser direction. Verified as a release gate for any SPEC-018 vN.M version that follows v0.1.3.

AC-24. **Coordinator request-side pass-through verification (Critic M-3 absorption).** Coordinator request-side `tool_calls[]` and `tool_call_id` pass-through fidelity is verified at the WebSocket frame layer by a unit test inspecting the outbound `InferenceRequest` frame for byte-equivalence with the buyer-supplied `tool_calls[]` and `tool_call_id` field bytes (after request validation per SPEC-001 / SPEC-002). The test does not require the provider to accept the request — it asserts that what the coordinator forwarded matches what the buyer sent. This closes the §6 normative-MUST-without-AC gap; AC-11 / AC-12 cover response-side fidelity, AC-24 covers request-side.

**v0.2.0+ AC applicability note:** AC-14 is the v0.1.x ratification criterion (`role:"tool"` + assistant-history `tool_calls[]` fail with `unsupported_tool_messages`). For v0.2.0+, AC-14 is SUPERSEDED by AC-26/AC-27 (accept + render). The v0.1.x error path is no longer the desired behavior; the v0.2.0 success path is. AC-14 remains in the SPEC for historical lock discipline.

AC-25a. **#1 Multi-turn end-to-end Cline release gate, CI-amenable fixture.** A headless Cline fixture using VS Code extension ID `saoudrizwan.claude-dev` / Cline v4.0.0 (or the exact version pinned in `tools/version-pins/cline-spec-018-v0_2_2.txt` if the marketplace patch version advances before IMPL lock), a pinned public test repo commit, and a pinned prompt runs through gateway → coordinator → v0.2 phase3 provider without a macprovider-specific Cline adapter. The fixture workspace MUST include `specs/SPEC-018-agentic-tool-calling.md` as a possible `read_file` target so the session can read content containing native tool-call markup without triggering any v0.2 prompt-echo self-DoS. The fixture MUST emit a machine-readable JSON session transcript with: Cline version, repo URL and commit, prompt SHA-256, ordered turns, raw OpenAI request/response or SSE transcript hashes, tool call IDs, tool categories, argument byte lengths, timing fields, provider/coordinator request IDs, streaming mode header, `usage.macprovider_model_hash_observed` value per provider response, and pass/fail summary. Automated assertions require ≥ 20 provider turns after the initial user request, ≥ 30 total tool calls/results, tool categories covering directory listing/search, file read, file edit (full-write or patch), and shell command, ≥ 3 file edits across ≥ 2 files, ≥ 2 shell command runs with at least one failing command followed by a successful recovery turn, ≥ 1 assistant-history `tool_calls[]` echo plus matching `role:"tool"` result after turn 1, Cline session success whether `usage.macprovider_model_hash_observed` is a known lowercase hex hash or `null`, no Cline branching on the value, and no `unsupported_tool_messages`, provider-side 5xx, malformed pre-commit tool delta, final-close failure, or missing `X-MacProvider-Streaming-Mode`. Fail condition: any criterion missing, transcript schema invalid, Cline behavior differs based on known-vs-unknown `usage.macprovider_model_hash_observed`, SPEC-018 self-reading breaks a legitimate follow-up tool call, or a macprovider-specific Cline adapter is required.

AC-25b. **#1 Multi-turn end-to-end Cline manual recorded smoke.** A human-recorded session against the actual Cline VS Code extension using the same pinned repo/prompt class completes the AC-25a workflow through gateway → coordinator → v0.2 phase3 provider. Evidence is a video or screenshot set plus transcript/log artifact and qualitative UX assessment. This is release evidence, not a CI gate.

Cline tool category mapping for AC-25a/AC-25b: legacy Cline VS Code extension names `list_files`, `search_files`, `read_file`, `write_to_file`, `execute_command`; ClineCore names `bash`, `editor`, `read_files`, `apply_patch`, `search`. The acceptance criteria require the categories, not a specific legacy or current tool name.

AC-26. **#1 `role:"tool"` accepted and rendered.** A request containing a valid `role:"tool"` message with string `content` and valid `tool_call_id` is accepted by the provider and rendered into the selected family-native tool-result markup before inference. Empty string content passes. Implementation MUST produce byte-equivalent output to the §3.8 Qwen3 and Llama-3.3 family fixtures where upstream templates are byte-specifiable, or structurally equivalent output with the exact upstream tokenizer-config artifact pinned where the SPEC uses structural fixture requirements. Fail condition: HTTP 400 `unsupported_tool_messages`, dropped `tool_call_id`, rendering that omits the tool result, or non-equivalence to §3.8 fixtures.

AC-27. **#1 Assistant-history `tool_calls[]` echo accepted and rendered.** A request replaying an earlier assistant message with valid `tool_calls[]` is accepted and rendered into native family tool-call markup so the model sees its prior calls. Implementation MUST produce byte-equivalent output to the §3.8 Qwen3 and Llama-3.3 family fixtures where upstream templates are byte-specifiable, or structurally equivalent output with the exact upstream tokenizer-config artifact pinned where the SPEC uses structural fixture requirements. Fail condition: structured fields are ignored, stripped by `ChatMessage`, rejected solely because they are assistant-history tool calls, or non-equivalence to §3.8 fixtures.

AC-28. **#1 Tool-result content request cap.** A `role:"tool"` message whose `content` is 256 KiB UTF-8 bytes or less is accepted if otherwise valid; a single `role:"tool"` `content` value larger than 256 KiB fails the whole request with HTTP 413, OpenAI-style error envelope, code `tool_result_too_large`, and `param: "messages[i].content"`. The provider MUST NOT truncate and continue.

AC-29. **#1 Multi-turn receipt prompt-hash regression.** Non-streaming receipt regression tests prove that changing a replayed `tool_call_id` or assistant-history `tool_calls[]` changes `prompt_hash`. Fixture: two otherwise identical multi-turn requests differ only in one `tool_call_id`, then only in one assistant-history `function.arguments`; both changes produce distinct prompt hashes. Fail condition: either change leaves `prompt_hash` unchanged.

AC-30. **#6 Provider-emitted ID format preserved.** Newly synthesized provider output IDs continue to match `^call_[a-f0-9]{32}$` and preserve the v0.1.5 `call_` prefix plus lowercase hyphenless UUID-hex suffix. Fail condition: provider emits mixed-case, punctuation, non-`call_` prefix, or shorter/longer IDs.

AC-31. **#6 Request-accepted ID format.** Request validation accepts assistant-history `tool_calls[].id` and `role:"tool".tool_call_id` values matching `^call_[A-Za-z0-9]{16,64}$`, including mixed-case alphanumeric OpenAI-style IDs, and rejects missing prefix, empty suffix, suffix shorter than 16, suffix longer than 64, `_`, `-`, `.`, `/`, `:`, whitespace, or non-ASCII. Failures return HTTP 400 code `invalid_tool_call_id`.

AC-32. **#6 Cross-message consistency.** Request validation enforces all seven §10d.6 cross-message rules before inference. Pass fixtures include one assistant tool call followed by one matching tool result, one assistant message with N distinct calls followed by N matching results in any order after that assistant, and a latest assistant call with no result. Fail fixtures include missing `tool_call_id`, malformed ID, unknown ID, tool result before assistant call, duplicate assistant `tool_calls[].id`, and duplicate tool results; failures use one of `invalid_tool_call_id`, `tool_call_id_not_found`, `duplicate_tool_call_id`, or `tool_call_result_out_of_order`.

AC-33. **#6 Cross-session Cline resume.** A recorded Cline conversation containing macprovider-emitted `call_[a-f0-9]{32}` IDs from one provider process is replayed through a fresh provider process or fresh WebSocket connection. The provider accepts the request and reaches inference without consulting or requiring a live minted-ID registry. Fail condition: rejection solely because the current process/session did not mint the ID.

AC-34. **#6 Buyer-fabricated ID acceptance.** A request with a buyer-fabricated assistant `tool_calls[].id` and matching `role:"tool".tool_call_id`, both matching `^call_[A-Za-z0-9]{16,64}$` and internally consistent, is accepted. The test asserts request acceptance only. Fail condition: rejection because the ID lacks provider provenance, or any retroactive settlement/receipt state is created for the fabricated prior event.

AC-35. **#7 Constants and parser/coordinator alignment.** Parser and coordinator tests assert identical public constants: per-call argument cap `1_048_576`, per-response aggregate cap `2_097_152`, and JSON depth cap `32`. Fail condition: either side is stricter or looser, or uses a different byte-counting helper for public v0.2 behavior.

AC-36. **#7 Per-call inclusive boundary.** A final unescaped `function.arguments` UTF-8 byte length of exactly `1_048_576` succeeds; `1_048_577` fails closed with per-call reason `byte_cap_exceeded`. Fixture should include a `write_to_file`-style JSON object and verify that the outer response JSON escaping overhead is not counted. Fail condition: exact-boundary rejection or +1 acceptance.

AC-37. **#7 Aggregate inclusive boundary.** Multiple tool calls whose summed final unescaped `function.arguments` UTF-8 byte length is exactly `2_097_152` succeed when each call is ≤ 1 MiB; aggregate `2_097_153` fails closed with reason `response_byte_cap_exceeded`. Fail condition: exact aggregate rejected, aggregate +1 accepted, or only per-call limits enforced.

AC-38. **#7 UTF-8 unescaped byte-counting domain.** Fixtures containing multi-byte Unicode and JSON-escaped characters are counted by UTF-8 bytes of the final unescaped `function.arguments` string obtained after JSON/SSE parsing and fragment concatenation, not Unicode scalar count and not outer escaped JSON bytes. Fail condition: a below-cap character count with above-cap UTF-8 byte length succeeds.

AC-39. **#7 Streaming cap-cross terminal path.** In streaming, if accepting the next decoded `function.arguments` fragment would exceed the per-call or per-response cap, the crossing chunk is not forwarded, the stream emits a terminating OpenAI-style SSE error object followed by `data: [DONE]`, and the coordinator marks `FaultBreakerQualifying` with zero provider-positive credits. The OpenAI-wire SDK ecosystem (`openai-python` v2.44.0+, openai-node, etc.) may surface the terminal SSE error frame as an exception or failed stream. AC-39 verifies this terminal-error behavior for the openai-python ecosystem. Fail condition: crossing bytes reach buyer, stream falls back to content, or credits settle positive.

AC-40. **#4 OpenAI incremental streaming shape.** Streaming tool-call output follows OpenAI wire shape under `openai==2.44.0`: accumulators are keyed by `tool_calls[].index`; first delta for an index carries `id`, `type:"function"`, and `function.name`; subsequent deltas may carry only `function.arguments` fragments. Fail condition: every fragment repeats full metadata as a required parser dependency, no stable index exists, or the SDK cannot accumulate the stream.

AC-41. **#4 Streaming/non-streaming byte-equivalence.** For the same model output and canonical output builder, non-streaming `tool_calls[i].function.arguments` bytes equal the concatenation of streaming fragments for the same `index` byte-for-byte. Fail condition: chunk boundaries, escaping, key ordering, or streaming canonicalization changes the accumulated argument string.

AC-42. **#4 §8.4 split enforced.** Tests prove incremental-open runs before any `tool_calls[]` chunk is emitted and final-close gates provider-positive settlement. A malformed first delta fails before buyer-visible commit; a stream that passes incremental-open but fails final-close terminates with SSE error + `[DONE]` and zero provider-positive settlement. Fail condition: settlement commits at incremental-open or final-close is skipped.

AC-43. **#4 AC-23s streaming forward-compat regression.** A release-gate test pins `openai==2.44.0`, mocks `/v1/chat/completions`, and serves the same request as both non-streaming response and streaming SSE response splitting the same `arguments` string. The pinned streaming reader accumulates without parse error; accumulated `id`, `type`, `name`, `finish_reason`, and `function.arguments` bytes match non-streaming, and unknown additive fields are tolerated. AC-43's no-parse-error requirement applies only to SUCCESSFUL streams. Terminal-error streams (AC-39) are expected to raise exceptions in the buyer SDK. Fail condition: old parser rejects the v0.2 successful stream or accumulated bytes differ.

AC-44. **#4 Cline large write streaming evidence.** In the AC-25a/AC-25b Cline evidence, at least one file-edit tool call has final `function.arguments` length ≥ 64 KiB and at least three argument deltas arrive before `finish_reason:"tool_calls"`. Provider-side timestamp instrumentation is REQUIRED: `t_tool_call_open_detected` (provider-internal native opening detected), `t_first_forwarded_sse_byte` (coordinator-side first forwarded SSE byte for that tool-call argument stream), and `t_first_gateway_byte` (gateway-side first byte delivered to the buyer connection). Timing measurements assume NTP-anchored clock skew `|t_provider - t_gateway| ≤ 100 ms` at request start, verified via heartbeat. Operators MUST run NTP on provider Macs and gateway hosts. v0.2 does NOT inherit this from another SPEC; it is a v0.2 prerequisite for AC-44 to be measurable. IMPL prompt will add `chrony` / `timesyncd` to the deployment checklist. Deterministic provider benchmark fixture: `qwen3-32b-4bit-mlx`, pinned prompt in the AC-25 fixture repo that induces a ≥64 KiB file edit, and recorded expected first-tool-call-open detection time for that model/hardware. Per-class hardware target is measured with skew correction: `t_first_gateway_byte - t_tool_call_open_detected - clock_skew_offset` p95 ≤ 1500 ms on M4, ≤ 3000 ms on M2/M3 in the deterministic provider fixture, where `clock_skew_offset` is measured at request start. Fail condition: missing timestamps, missing heartbeat skew verification, p95 above target after skew correction, or the large edit is buffered to one final delta when streaming is enabled.

AC-45. **#4 Operator kill switch, per-(buyer, provider) downgrade, and buyer-visible diagnostic.** Operator configuration can force buffered-to-end behavior for streaming requests without changing the public wire contract, and 3 malformed incremental streams from the same buyer to the same provider within a 5-minute window trigger automatic downgrade to buffered-to-end for that buyer's future requests to that provider only. The downgrade lifts after 10 minutes with no further malformed streams from that buyer to that provider. Every v0.2 response includes `X-MacProvider-Streaming-Mode` with one of `incremental`, `buffered_kill_switch`, or `buffered_provider_downgrade`. Fixtures cover all three values and assert correlation between the header, operator/provider/buyer tuple state, and request log. AC-45c adversarial-buyer fixture: one buyer repeatedly induces malformed streams from a provider; other buyers sticky-routed to the same provider continue to receive `incremental` unless their own tuple crosses the downgrade threshold. Fail condition: no kill switch exists, the kill switch changes request/response schema, one buyer's malformed incremental stream disables streaming for other buyers or globally for all providers, downgrade fails to recover after the clean interval, the header is absent, or the header value disagrees with operator/provider/buyer state.

AC-46. **#2 Minimal model-hash binding observation.** Every provider response in v0.2 includes additive, non-canonicalized `usage.macprovider_model_hash_observed`. Buyer-visible behavior is field-present plus JSON type-correct only: the value is `null | "^[a-f0-9]{64}$"`. This field is observation-only in v0.2 and MUST NOT drive v0.2 parser selection or settlement. It gives buyers and v0.3 registry work passive evidence to log the served `model_hash` against the modelID-declared family. Provider self-test: when the provider's own `model_hash` subsystem reports a known hash, the field MUST be that lowercase hex value; when unknown, the field MUST be `null`. AC-46 fixtures cover (a) buyer-side type assertion that every v0.2 response has the field present with type null or lowercase SHA-256 hex, and (b) provider-side log/release-gate assertion that known/unknown branches match the provider's local hash subsystem state. Fail condition: buyer-visible missing field, non-null non-hex value, inclusion in SPEC-015 canonical output binding, v0.2 enforcement based on a registry that §10c has explicitly deferred, or provider self-test mismatch against local `model_hash` state.

AC-47. **#4 Final-close terminal completeness on provider EOF/disconnect.** For both `forwardWSStreaming` and `forwardStreaming`, after incremental-open has emitted or forwarded any `tool_calls[]` chunk, provider EOF/disconnect/timeout/relay error/authentication failure/truncation/missing terminal marker before all §8.4.2 terminal conditions are satisfied results in zero provider-positive credits, `FaultBreakerQualifying` recorded, no receipt, no sticky-route success write, and a terminal SSE error if the buyer connection can still be written. Fail condition: clean EOF alone is treated as final-close success, credits settle positive, receipt is emitted, sticky success is written, or either coordinator path lacks coverage.

AC-48a. **#4 Post-final-close-error stream does not dispatch tools — openai-python ecosystem.** A fixture using `openai-python` v2.44.0+ streaming reader emits a valid incremental-open and partial accumulated arguments, then triggers final-close failure. The terminal-error stream MUST NOT deliver a successful assistant message with dispatchable `tool_calls[]` to the SDK accumulator, and the terminal-error SSE event MUST NOT carry `finish_reason:"tool_calls"`. This is the generic SDK-side gate for the openai-python ecosystem. Fail condition: the SDK exposes a successful assistant tool call after the terminal error.

AC-48b. **#4 Post-final-close-error stream does not dispatch tools — Cline integration.** A fixture using Cline VS Code extension v4.0.0 through its OpenAI-compatible provider path (`sdk/packages/llms/src/providers/vendors/openai-compatible.ts`, importing `@ai-sdk/openai-compatible` from the Vercel AI SDK) emits a valid incremental-open and partial accumulated arguments, then triggers final-close failure. The terminal-error stream MUST NOT deliver dispatchable `tool_calls[]` to Cline's `AgentRuntime`, and the terminal-error SSE event MUST NOT carry `finish_reason:"tool_calls"`. This is the Cline-specific money-path gate and is separate from AC-48a. Fail condition: Cline exposes or executes a successful assistant tool call after the terminal error.

AC-50. **#1 Aggregate raw request-body cap.** A request body whose raw byte length is greater than 4 MiB fails before inference with HTTP 413 `request_body_too_large` (or the SPEC-006 buyer-API aligned request-body-too-large code if SPEC-006 already owns that exact spelling). The provider/coordinator MUST NOT parse, truncate, or partially validate an over-cap body and continue. Fail condition: >4 MiB body reaches inference or returns a retryable/provider error instead of a non-retryable request-size error.

AC-51. **#1 Aggregate tool-result content cap.** The sum of all `role:"tool".content` UTF-8 byte lengths across `messages[]` greater than 1 MiB fails before inference with HTTP 413 `tool_results_aggregate_too_large`. The per-message 256 KiB `tool_result_too_large` cap remains independently enforced. Fail condition: aggregate >1 MiB succeeds, is silently truncated, or is reported only after provider inference starts.

AC-52. **#1 Aggregate assistant-history arguments cap.** The sum of all assistant-history `tool_calls[].function.arguments` UTF-8 byte lengths across `messages[]` greater than 2 MiB fails before inference with HTTP 413 `tool_call_arguments_aggregate_too_large`. The per-call 1 MiB `tool_call_arguments_too_large` cap remains independently enforced. Fail condition: aggregate >2 MiB succeeds, is silently truncated, or is reported only after provider inference starts.

AC-53. **#1 Maximum messages array length.** A request with `messages[]` array length greater than 256 fails before inference with HTTP 400 `messages_too_long`. Fail condition: 257 or more messages reach prompt rendering or provider inference.

AC-54. **#1 Maximum assistant-history tool calls.** A request whose assistant messages contain more than 128 total `tool_calls[]` entries across all messages fails before inference with HTTP 400 `too_many_tool_calls`. Fail condition: 129 or more assistant-history tool calls reach prompt rendering or provider inference.

AC-55. **#6 Linear cross-message tool_call_id validation.** Cross-message `tool_call_id` validation MUST be O(messages[] + tool_calls[]) using a linear-time profile such as one pass with maps/sets for seen assistant IDs and fulfilled tool results. Pass fixture: a request with 256 messages including 128 assistant tool calls, each with a unique ID and valid matching structure, completes validation in bounded linear time under the implementation's recorded operation counter or benchmark threshold. Adversarial fixture: 128 duplicate IDs fails with `duplicate_tool_call_id` and validation MUST NOT perform more than 256 × 128 pairwise comparisons or equivalent repeated scans. Fail condition: O(N^2) validation, unbounded runtime growth on the fixture, or duplicate IDs reported with a non-canonical code.

AC-57. **#743 Harmony final-channel filtering.** For a `gpt-oss` modelID with Harmony token IDs, completed `analysis` channel bodies and non-tool `commentary` channel bodies are suppressed, and `choices[0].message.content` / streaming `delta.content` expose only completed `final` channel body tokens except for the rule-5 visible-final truncation case. A fixture containing `analysis`, non-tool `commentary`, and `final` frames returns exactly the final body as assistant content. Length/request-stop fixtures that end inside a visible `final` body may return only the filtered visible prefix generated so far; equivalent truncation inside hidden, header, constrain, or function-call spans fails closed. Fail condition: hidden-channel text, channel headers, structural markers, non-tool commentary, or post-request-stop tool calls appear in buyer-visible content.

AC-58. **#743 Harmony structured tool-call conversion.** A fixture with `commentary to=functions.<declared_name>` plus a valid JSON object body terminated by the Harmony call token produces OpenAI `tool_calls[]` with a §2.1-compatible `id`, `type:"function"`, matching `function.name`, and validated JSON-object `function.arguments`; `message.content` is `null` when no final-channel content exists. Fail fixtures cover undeclared function names, malformed JSON, duplicate JSON keys, non-object JSON, a function-recipient frame lacking the call-token terminator, and a call-token terminator outside a declared function recipient. These failures use the existing retryable `malformed_tool_call_final_json` final-close code, emit no successful tool call, and leak no hidden-channel content.

AC-59. **#743 Harmony streaming parity and marker non-leakage.** Streaming Harmony parsing operates on generated token IDs, either incrementally or from cumulative snapshots, and never emits partial Harmony markers, channel headers, constrain labels, hidden bodies, or incomplete tool-call JSON as `delta.content` or successful `delta.tool_calls[]`. Successful streaming accumulation matches the non-streaming response's final-channel content and tool-call semantics for the same token-ID sequence. Fail condition: marker/header leakage, partial tool dispatch before the Harmony call token, or divergence between successful streaming and non-streaming accumulation.

AC-60. **#743 Harmony completion-token accounting.** Harmony `usage.completion_tokens` counts only token IDs from `final` channel body spans that become buyer-visible assistant content, including the rule-5 visible-final truncation prefix when that narrow exception applies. Tool-call JSON body tokens, `analysis` body tokens, non-tool `commentary` body tokens, structural markers, headers, constrain labels, and call/end/return markers are excluded. A tool-call-only Harmony response has `completion_tokens = 0`. Fail condition: any hidden/tool-call/structural token contributes to `completion_tokens`, or emitted visible final-channel tokens are omitted from the count.

AC-61. **#743 Non-Harmony byte identity.** For modelIDs that do not match the §3.1 Harmony row, enabling the Harmony parser changes no decoded response bytes, no Qwen/Llama parser-family selection, no `tool_calls[]` synthesis result, and no token accounting relative to SPEC-018 v0.2.4 for the same generated output. Regression fixtures cover plain text, Qwen tool-call markup, Llama tool-call markup, and decoded Harmony-marker-looking text under non-Harmony modelIDs. Fail condition: non-Harmony content bytes differ, existing parser behavior changes, or Harmony marker-looking decoded text alone synthesizes a tool call.

AC-62. **v0.2.7 function-XML hyphenated tool name.** For a Qwen modelID with enabled tool `buzz-dev-mcp__shell` and model output `<function=buzz-dev-mcp__shell><parameter=command>echo hi</parameter></function>` (with or without an enclosing `<tool_call>` wrapper), the non-streaming response contains `choices[0].message.tool_calls[0].function.name == "buzz-dev-mcp__shell"` and `function.arguments == "{\"command\":\"echo hi\"}"`. Fail condition: the hyphenated name is rejected under the old Python-identifier rule and the XML leaks as plain assistant content, or the tool call is dropped.

AC-63. **v0.2.7 streaming undeclared function-XML name fails closed.** For a Qwen modelID whose only enabled tool is `buzz-dev-mcp__shell`, incremental streaming of `<function=evil-dev-mcp__wipe><parameter=path>/</parameter></function>` emits NO `delta.tool_calls[]` for `evil-dev-mcp__wipe`; the undeclared name is fail-closed before any buyer-visible tool-call delta. A declared name under the same conditions DOES stream a `tool_calls[]` delta. Fail condition: a streamed tool-call delta carries a function name not among the request's enabled tools.

AC-64. **v0.2.7 function-XML hyphenated parameter name.** For a Qwen modelID with enabled tool `buzz-dev-mcp__shell` and model output `<function=buzz-dev-mcp__shell><parameter=work-dir>/tmp</parameter></function>`, the emitted `function.arguments` is a JSON object with key `work-dir` (`{"work-dir":"/tmp"}`). Fail condition: the hyphenated parameter key is rejected and the tool call is dropped or leaked as plain content.

## 10. Future versions — Required, then Enhancement

### 10a. Required for full Ring-1 product (v0.2 normative targets)

**Reader note**: §10a is locked v0.1.5 historical content. For v0.2.0+ active scope and the lock-amendment status of items listed here, see §10d.0 reader note + §10c.1 amendment log.

Each item below is a v0.2 deliverable that gates the "actual Ring-1 product" release. A user running Cline / Aider / OpenCode / Continue / Vercel AI SDK against macprovider for real coding work needs ALL of these, not just some:

1. **Multi-turn provider acceptance.** Provider accepts `role: "tool"` messages and assistant-history `tool_calls[]` without rejecting at the provider boundary. Closes AC-14 limitation. This is the gate between v0.1 wire-shape-certificate and v0.2 actual-product.
2. **Model-hash → family registry (closes Security C-1 path (c)).** Extends the live SPEC-008 Pillar A + SPEC-011 v0.5 `model_hash` infrastructure already plumbed end-to-end in production: the `ModelHash` + `HashStatus` fields on the coordinator's pool/provider struct (`phase4-coordinator/internal/pool/provider.go:132-133`), heartbeat-driven `model_hash` updates (`phase4-coordinator/internal/pool/provider.go:1001-1052`), hash-verification routing exclusion/eligibility (`phase4-coordinator/internal/buyer/server.go:3291-3324`; helper predicates at `phase4-coordinator/internal/buyer/server.go:3873-3913`), and the `/v1/status` `model_hash` block. v0.2 adds a registry mapping `model_hash` → tool-call grammar family on top of this infrastructure. The parser selects grammar from the verified loaded `model_hash`, not from the buyer-supplied `modelID` substring. **Buyer-facing impact:** prevents a provider from advertising a tool-call-capable model family while serving a different model or grammar. Design questions to resolve in v0.2 SPEC: where the registry lives (binary, coordinator-pushed catalog, community-signed root), curation model, and registry update frequency. Fail-closed semantics are pre-locked as a v0.1.3 invariant — see §10c.
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

**AMENDED v0.2.0/v0.2.1:** the v0.1.3-locked clause requiring v0.2 to enforce unknown-`model_hash` fail-closed via a registry is amended to defer registry to v0.3. Rationale: narrow v0.2 scope (Cline drop-in) made the curation work strategically premature. v0.2 mitigates via §8.4.2 tightened final-close + AC-46 minimal model-hash binding observation. Full registry is v0.3 §10a #2.

**AMENDED v0.2.3:** §3.9 (v0.2.1-introduced minimal prompt-echo guard) is DELETED. v0.2.3 ships WITHOUT prompt-echo mitigation. Residual risk: a same-family model may emit a tool call whose markup appears verbatim in untrusted prompt content (for example, `role:"tool"` content from a `read_file` of a file containing native tool-call markup). v0.3 delivers the full guard with whitespace normalization, tool-description scope coverage, Cline-shaped false-positive testing, and proven absence of self-DoS via SPEC-018-self-reading case. Rationale: the v0.2 minimal guard (deleted) had three exploitable defects (whitespace bypass on single newline, scope-incomplete around `tools[]` / `function.parameters` / `function.arguments`, self-DoS on legitimate Cline `read_file` of SPEC-018.md). Shipping the minimal guard was strictly worse than not shipping a guard. Path (a) precedent: when a defense feature is found to be net-negative under realistic conditions, delete it and document residual risk explicitly.

**v0.2.0 cap invariant.** SPEC-018 v0.2.0 establishes response-side `function.arguments` public baseline caps of 1_048_576 UTF-8 bytes per call and 2_097_152 UTF-8 bytes per response, counted on the final unescaped argument string with inclusive comparison. Future v0.2.x versions MAY raise either cap. Future v0.2.x versions MUST NOT lower either cap for default no-header behavior, MUST NOT change the inclusive boundary rule, and MUST NOT change the byte-counting domain. Lowering a cap requires a major SPEC-018 version bump or explicit buyer opt-in defined by a later SPEC.

This invariant gives buyers a stable platform: code written against v0.1.3 wire shape continues to work in v0.2 and beyond, and security guarantees the v0.1.3 SPEC commits to cannot be silently bypassed by the v0.2 implementer. AC-23 (reworked v0.1.3, baseline-pin filename corrected v0.1.4, baseline version aligned v0.1.5) verifies the additive invariant via a regression test that captures vN.M responses and parses them with a v0.1.3-baseline parser (semver pinned in `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`).

### 10c.1 Lock-amendment discipline

SPEC-018 v0.2 introduces and exercises a lock-amendment precedent: a previously LOCKED normative claim (introduced as MUST in a prior SPEC version) CAN be amended in a later version IF AND ONLY IF the change-log entry for that later version:

(a) Names the specific clause being amended (cite the original version + section).
(b) States the strategic rationale (why the amendment is needed; what scope or product decision drove it).
(c) Names the replacement mitigation OR explicitly documents the residual risk.
(d) Carries the amendment label "AMENDED v<X.Y.Z>" in the original clause's location (preserved as historical text + amendment paragraph).

Silent scope cuts of locked invariants are NON-COMPLIANT. Future SPEC-018 versions invoking this precedent MUST satisfy (a)-(d) AND enumerate the amendment in this section's amendment log. Future SPEC versions invoking this precedent for OTHER v0.2 invariants MUST satisfy the same (a)-(d) rules and add an enumerated entry. AC numbers are stable across SPEC-018 versions; once an AC is assigned a number, that number is never reused or renumbered, even if the AC content is amended.

Amendment log:
- Amendment 1 (v0.2.1): §10c v0.1.3-locked model-hash registry requirement → deferred to v0.3. Rationale: narrow v0.2 scope makes registry curation strategically premature. Mitigation: AC-46 model-hash observation channel + §8.4.2 final-close tightening.
- Amendment 2 (v0.2.3): §3.9 v0.2.1-introduced minimal prompt-echo guard → DELETED. Rationale: minimal guard had three exploitable defects making it net-negative vs. no guard (whitespace bypass; scope incomplete; self-DoS via Cline reading SPEC-018.md). Residual risk: same-family echo attack remains unmitigated in v0.2. Mitigation: deferred to v0.3 full guard.

Note: §10c.1 covers both locked-content amendments (e.g., Amendment 1 amended §10c which was v0.1.3-locked) AND in-flight draft-content revisions (e.g., Amendment 2 deleted §3.9 which was v0.2.1-introduced and not yet locked). v0.3 governance MAY refine this distinction; v0.2.4 treats both classes under the same (a)-(d) discipline.

Future SPEC-018 v0.X.Y versions exercising this precedent MUST add an enumerated entry here.

### 10d. v0.2 deliverables

v0.2.0 is the narrow Cline-drop-in release. It implements four deliverables: #1 multi-turn provider acceptance, #4 token-incremental streaming promotion, #6 multi-turn `tool_call_id` validation, and #7 response-side `function.arguments` byte caps. The v0.1.5 normative content remains locked; §10d adds behavior required after v0.1.5.

**v0.2.0+ reader note:** §10d supersedes §10a's earlier seven-item v0.2 target list for v0.2.0+ scope determination. Deliverables #2 (model-hash registry), #3 (prompt-echo guard full version), and #5 (structured `malformed_tool_call` signal) are deferred to v0.3 per §10c / §10c.1 amendments and the narrow Cline drop-in v0.2 product scope. §10a is preserved as v0.1.5 locked-content historical reference. §11 Q1 is RESOLVED by §10d (anchor framework = Cline).

Why Cline gates v0.2: Cline (https://github.com/cline/cline) is the v0.2 anchor framework because (a) ~1M+ VS Code marketplace installs make it the largest OpenAI-wire agentic-coding tool; (b) heavy multi-turn tool-call workload (`read_file`/`write_to_file`/`execute_command`/etc., 20-50 iterations per session) stress-tests the full agentic loop; (c) `write_to_file` arguments include full file contents, exercising the streaming UX and per-call byte cap; (d) open-source + active community enables real-session evidence collection for the v0.2 release gate. Other §1-listed OpenAI-wire frameworks are expected-compatible observation targets; their compatibility matrix is v0.3+.

§10d subsection numbers (§10d.1, §10d.4, §10d.6, §10d.7, plus pre-deliverable §10d.0 / §10d.0.1 and post-deliverable §10d.8) intentionally mirror the design-deliverable identifiers from `specs/design/spec-018/SPEC-018-v0_2-design-synthesis.md`. The non-sequential numbering is intentional. Reader convenience: §10d.1 = Multi-turn provider acceptance; §10d.4 = Streaming; §10d.6 = tool_call_id validation; §10d.7 = byte cap.

#### 10d.0 v0.2 error envelope

All v0.2-introduced HTTP and terminal SSE errors MUST use an OpenAI-style envelope with these minimum fields:

```json
{
  "error": {
    "type": "invalid_request_error | api_error | upstream_provider_error",
    "code": "<stable enum value>",
    "message": "<human-readable>",
    "param": "<optional JSON path>",
    "retryable": true,
    "request_id": "<UUID>",
    "inference_ran": false,
    "settlement_ran": false
  }
}
```

`param` MAY be omitted when no single request JSON path owns the failure. `retryable`, `inference_ran`, and `settlement_ran` are booleans. `request_id` MUST be the gateway/coordinator request identifier visible in logs.

The codes in this table are buyer-visible HTTP/SSE error envelope codes. Internal plain-content fallback reasons are NOT buyer-visible error codes in v0.2 — they manifest as the absence of synthesized `tool_calls[]` plus normal plain assistant content. v0.2.3 deletes the v0.2.1 minimal prompt-echo guard and therefore has no `prompt_echo_blocked` buyer-visible or internal guard-trigger code path. v0.3 will expose malformed-tool-call diagnostics as a structured `usage.macprovider_malformed_tool_call.reason` enum.

Stable v0.2 error codes:

| Code | Type | Retryable |
|---|---|---|
| `byte_cap_exceeded` | `upstream_provider_error` | false |
| `response_byte_cap_exceeded` | `upstream_provider_error` | false |
| `malformed_tool_call_final_json` | `upstream_provider_error` | true |
| `provider_stream_downgraded` | `api_error` | true |
| `request_body_too_large` | `invalid_request_error` | false |
| `tool_result_too_large` | `invalid_request_error` | false |
| `tool_results_aggregate_too_large` | `invalid_request_error` | false |
| `tool_call_arguments_too_large` | `invalid_request_error` | false |
| `tool_call_arguments_aggregate_too_large` | `invalid_request_error` | false |
| `messages_too_long` | `invalid_request_error` | false |
| `too_many_tool_calls` | `invalid_request_error` | false |
| `invalid_tool_call_id` | `invalid_request_error` | false |
| `tool_call_id_not_found` | `invalid_request_error` | false |
| `duplicate_tool_call_id` | `invalid_request_error` | false |
| `tool_call_result_out_of_order` | `invalid_request_error` | false |
| `unsupported_modelID_for_multi_turn` | `invalid_request_error` | false |

The code `invalid_tools` used in §5 and §10d.1 for malformed assistant `tool_calls[]` request-shape failures is INHERITED from pre-existing SPEC-001 / SPEC-002 request validation. It remains stable but is not enumerated in the v0.2.X-specific code table above to avoid duplicating cross-SPEC ownership.

#### 10d.0.1 Minimal model-hash observation

Every v0.2 provider response MUST include additive `usage.macprovider_model_hash_observed`. Buyer-visible validation is limited to field presence and JSON type `null | "^[a-f0-9]{64}$"`. Provider self-test MUST assert that the value is lowercase SHA-256 hex when the provider's local `model_hash` subsystem reports a known served model hash and `null` when that subsystem reports unknown. The field is non-canonicalized, observation-only, and MUST NOT affect v0.2 parser/profile selection, settlement, or SPEC-015 output binding. Its purpose is forward compatibility for the v0.3 registry: buyers can passively log the served `model_hash` against the modelID-declared family before registry enforcement exists. Cline and other OpenAI clients need not act on this field in v0.2; macprovider release evidence and logs capture it for diagnostics and v0.3 registry preparation.

#### 10d.1 Deliverable #1 — Multi-turn provider acceptance

Provider accepts full OpenAI `messages[]` replay each turn. The provider MUST remain stateless across turns: it validates only the in-request tool-call chain and MUST NOT require a session-scoped registry of IDs minted by the current provider process, WebSocket connection, or HTTP session.

Provider MUST accept `role:"tool"` messages with valid string `content` and valid `tool_call_id`. Empty string content MUST be accepted. `content:null` MUST fail request validation. Provider MUST accept assistant-history `tool_calls[]` and render them into the model's native chat template so the model sees its prior tool calls. This chooses the synthesis option (b): validate format + cross-message consistency, then re-render into native tool-call markup. Ignoring structured fields breaks multi-turn agent state; rejecting by original minting family or process breaks Cline conversation resume.

The §3.8 tool prompt-template profile owns multi-turn input rendering. It is separate from the §3.1 parser-family registry: §3.1 handles output parsing, while §3.8 handles input rendering. v0.2 keys the renderer by modelID-match per §3.2; the v0.3 registry candidate will move the profile key to verified `model_hash`.

`role:"tool"` `content` is capped at 256 KiB UTF-8 bytes per individual message. A larger value MUST reject the whole request with HTTP 413, OpenAI-style error envelope, code `tool_result_too_large`, and `param: "messages[i].content"`. The provider MUST NOT silently truncate because truncation changes the command/file output the model reasons over.

Assistant-history `tool_calls[].function.arguments` is capped at 1_048_576 UTF-8 bytes per call, in the same byte-counting domain as §10d.7. A larger value MUST reject the whole request with HTTP 413 and code `tool_call_arguments_too_large`.

Aggregate request-side caps for v0.2:

- Total raw request body cap: 4 MiB at the coordinator/provider boundary. Gateway deployments using SPEC-006 defaults may be stricter (`request_body_bytes: 1048576` in SPEC-006 §13.5, with request-body limit enforced before quota/admission per §7.4 and 413 semantics per §15.1).
- Total decoded `role:"tool"` content bytes across all messages: 1 MiB.
- Total assistant-history `function.arguments` bytes across all messages: 2 MiB, aligned with the §10d.7 per-response aggregate cap.
- Maximum `messages[]` array length: 256.
- Maximum total tool calls across all assistant messages: 128.

`messages[]` length greater than 256 returns HTTP 400 `messages_too_long`. This is user-actionable for Cline and other long-session clients: split or summarize long sessions before retrying.

The implementation MUST enforce raw-body caps before JSON parse where possible, decoded string caps during parse/validation, and cross-message `tool_call_id` validation before prompt rendering. Cross-message validation MUST be O(messages[] + tool_calls[]) using maps/sets for IDs; O(N^2) repeated scans across the conversation are non-compliant.

Request-side failure modes:

| Shape | v0.2 behavior |
|---|---|
| Raw request body > 4 MiB | HTTP 413 `request_body_too_large` |
| `role:"tool", content:""` | Accept. Empty command output is legitimate. |
| `role:"tool", content:null` | HTTP 400 `invalid_request`, `param:"messages[i].content"` |
| `role:"tool"` missing `tool_call_id` | HTTP 400 `invalid_tool_call_id`, `param:"messages[i].tool_call_id"` |
| `tool_call_id` failing format regex (see §10d.6) | HTTP 400 `invalid_tool_call_id` |
| `tool_call_id` no prior assistant `tool_calls[].id` in same request | HTTP 400 `tool_call_id_not_found` |
| Duplicate tool result for same ID | HTTP 400 `duplicate_tool_call_id` |
| Assistant `tool_calls[]` malformed (depth/shape) | HTTP 400 `invalid_tools` |
| Assistant-history `function.arguments` > 1 MiB | HTTP 413 `tool_call_arguments_too_large` |
| Aggregate assistant-history `function.arguments` bytes > 2 MiB | HTTP 413 `tool_call_arguments_aggregate_too_large` |
| `role:"tool"` content > 256 KiB | HTTP 413 `tool_result_too_large` |
| Aggregate `role:"tool"` content bytes > 1 MiB | HTTP 413 `tool_results_aggregate_too_large` |
| `messages[]` length > 256 | HTTP 400 `messages_too_long` |
| Total assistant-history `tool_calls[]` entries > 128 | HTTP 400 `too_many_tool_calls` |
| No §3.8 profile maps for a multi-turn `modelID` | HTTP 400 `unsupported_modelID_for_multi_turn` |

Coordinator validation MUST mirror these failures before provider dispatch. Existing coordinator request structs already preserve `tool_call_id` and `tool_calls` at `phase4-coordinator/internal/buyer/server.go:1241-1245`; validation additions belong near `phase4-coordinator/internal/buyer/server.go:3089`.

Receipt canonicalization has no schema change in v0.2. `PromptCanonicalizer.swift:5` already canonicalizes `messages`, including `tool_call_id` and `tool_calls` at `:31`. v0.2 IMPL MUST add regression coverage proving a multi-turn `prompt_hash` changes when `tool_call_id` or assistant-history `tool_calls[]` changes.

AC-14 transition: v0.1.5 ratified `unsupported_tool_messages` as an expected error path for `role:"tool"` and assistant-history `tool_calls[]`. v0.2.0 changes AC-14 to a success path for valid multi-turn requests. This is forward-compatible and additive under §10c because it expands accepted request shapes without changing the successful assistant tool-call response schema.

#### 10d.4 Deliverable #4 — Token-incremental streaming promotion

For Cline-targeted compatible models, v0.2 streaming defaults to token-incremental tool-call streaming. Operator configuration MUST be able to force buffered-to-end behavior as a kill switch. Auto-downgrade attribution is per-(buyer, provider) tuple, NOT per-provider for all buyers: 3 malformed streams from the same buyer to the same provider within a 5-minute window downgrade that buyer's future requests to that provider to buffered-to-end. The downgrade lifts after 10 minutes of no further malformed streams from the same buyer to the same provider. This configurability is operational and MUST NOT be exposed as a public wire negotiation surface in v0.2.

Streaming mode is exposed to buyers via the non-negotiating diagnostic response header `X-MacProvider-Streaming-Mode`. Values: `incremental` (default for v0.2 Cline-compatible models), `buffered_kill_switch` (operator-disabled), `buffered_provider_downgrade` (auto-downgraded due to malformed stream history for that buyer/provider tuple). The header is observation-only — buyers MUST NOT use it for negotiation in v0.2.

The Cline v4.0.0 anchor framework drives OpenAI-compatible chat completions through Vercel AI SDK (`@ai-sdk/openai-compatible`), not openai-python. Cline-specific terminal-SSE-error behavior is gated by AC-48b using `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`; openai-python ecosystem behavior remains gated separately by AC-39 and AC-48a.

Provider streams `function.arguments` incrementally per OpenAI wire format. The buyer accumulates deltas by `tool_calls[].index`. The first delta for each index carries the provider-minted `id`, `type:"function"`, and `function.name`; subsequent deltas carry additive `function.arguments` string fragments.

Example shape:

```text
data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef0123456789abcdef","type":"function","function":{"name":"write_to_file","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"content\":\""}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"<chunk>"}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\",\"path\":\"/tmp/demo.txt\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]
```

Streaming concatenation MUST equal non-streaming canonical output byte-for-byte. Provider implementations MUST use a single canonical output builder for both modes. Non-streaming is the full accumulated canonical byte string; streaming is transport chunking of prefixes/fragments of the same canonical byte string. Chunk boundaries are transport-only and MUST NOT affect final accumulated `function.arguments`.

§8.4 defines the commit split. Incremental-open runs before any `tool_calls[]` chunk is emitted and permits buyer-visible streaming commit. Final-close runs at end-of-stream and gates money-path settlement commit. If final-close fails after emission, the stream terminates with an OpenAI-style `error` object on a terminating SSE event followed by `data: [DONE]` if the buyer connection can still be written; the error event MUST NOT carry `finish_reason:"tool_calls"`. Provider-output malformed deltas, mid-stream cap-cross, missing `finish_reason:"tool_calls"`, missing transport terminal marker, provider disconnect/timeout/relay/auth failure/truncation after incremental-open, or any other final-close failure are `FaultBreakerQualifying` and settle zero provider-positive credits through existing `billing_recorder.go:176` and `formula.go:112` paths.

The coordinator MUST pass provider SSE bytes containing split `tool_calls[].function.arguments` to the buyer byte-identically for both `forwardWSStreaming` (`phase4-coordinator/internal/buyer/server.go:2103`, buyer byte write at `:2149`) and `forwardStreaming` (`phase4-coordinator/internal/buyer/server.go:2279`). This is the streaming-side analogue to AC-24. The current validator around `server.go:2674` requires complete JSON-object arguments and is incompatible with OpenAI incremental fragments; v0.2 replaces it with §8.4.1 and §8.4.2.

Concurrent streaming budget: maximum concurrent active tool-call streams per coordinator process is bounded by SPEC-006 buyer-API connection/concurrency limits for public traffic (SPEC-006 §2.4 and §7.1 default per-account concurrent requests = 2) plus coordinator deployment configuration. Where no stricter deployment cap exists, recommended coordinator process cap is 64 concurrent buyer streams. Total streaming accumulator memory budget = max_concurrent × 2 MiB. Per-buyer streaming-accumulator budget = 2 MiB × max_concurrent_per_buyer; `max_concurrent_per_buyer` is operator-configurable but MUST be ≤ 4 for v0.2.

AC-23s extends AC-23 for streaming forward compatibility. Note: in design notes (`specs/design/spec-018/SPEC-018-v0_2-design-synthesis.md`) this is referred to as `AC-23s`. In this SPEC body, the streaming forward-compat regression extension is encoded as AC-43. The release-gate regression MUST pin `openai==2.44.0`, mock `/v1/chat/completions`, return the same request as both non-streaming response and streaming SSE response splitting the same `arguments` string, accumulate with the pinned streaming reader, and assert byte-equivalence plus tolerated unknown additive fields. AC-43 is an OpenAI Python SDK regression and is NOT a Cline-stack regression; Cline-stack streaming behavior is gated by AC-48b.

#### 10d.6 Deliverable #6 — Multi-turn `tool_call_id` validation rule

v0.2 uses format-only stateless validation plus strict request-internal cross-message consistency. The provider MUST NOT require that an incoming `tool_call_id` was minted by the current provider process, current HTTP/WebSocket session, current provider identity, or current request.

Provider-emitted IDs, meaning newly synthesized assistant `tool_calls[].id` values, MUST continue to match:

```text
^call_[a-f0-9]{32}$
```

Request-accepted IDs, meaning assistant-history `tool_calls[].id` and `role:"tool".tool_call_id`, MUST match:

```text
^call_[A-Za-z0-9]{16,64}$
```

Rejected suffix characters include `_`, `-`, `.`, `/`, `:`, whitespace, non-ASCII, and empty suffixes. The wider request-accepted domain accepts OpenAI-style mixed-case alphanumeric IDs while preserving the v0.1.5 `call_` prefix.

The provider MUST validate the `messages[]` array as an ordered conversation graph before inference:

1. Every assistant-history `tool_calls[].id` MUST match the request-accepted regex.
2. Every `role:"tool"` MUST have non-empty `tool_call_id` matching the request-accepted regex.
3. `role:"tool"` MUST appear after the assistant message whose `tool_calls[]` contains the same ID.
4. Within a single request, each `tool_call_id` MUST appear in exactly one assistant `tool_calls[]` entry.
5. Within a single request, each assistant `tool_calls[].id` MAY have zero or one matching `role:"tool"` result.
6. A `role:"tool"` MUST NOT reuse a `tool_call_id` already used by an earlier `role:"tool"` in the same request.
7. A `role:"tool"` whose `tool_call_id` does not match an earlier assistant `tool_calls[].id` in the same request MUST be rejected.

Valid:

```json
[
  {"role": "user", "content": "Read package.json"},
  {
    "role": "assistant",
    "content": null,
    "tool_calls": [
      {"id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"package.json\"}"}}
    ]
  },
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "{\"ok\":true}"},
  {"role": "user", "content": "Now summarize it"}
]
```

Invalid because the tool result appears before the assistant tool call:

```json
[
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "{}"},
  {
    "role": "assistant",
    "tool_calls": [
      {"id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
    ]
  }
]
```

Invalid because one tool call has two results:

```json
[
  {
    "role": "assistant",
    "tool_calls": [
      {"id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
    ]
  },
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "first"},
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "second"}
]
```

Validation failures MUST fail fast with HTTP 400, OpenAI-style error envelope, and `type: "invalid_request_error"`. Normative codes:

- `invalid_tool_call_id` — ID missing or format invalid.
- `tool_call_id_not_found` — `role:"tool"` references no earlier assistant `tool_calls[].id`.
- `duplicate_tool_call_id` — the same ID appears in more than one assistant `tool_calls[]` entry, or more than one `role:"tool"` result.
- `tool_call_result_out_of_order` — a `role:"tool"` result appears before its assistant tool call.

These four failures are request-validation failures. They are NOT fault-breaker-qualifying, MUST NOT run inference, MUST NOT commit provider credits, and MUST NOT produce a receipt.

Cross-session reuse MUST be accepted. A Cline conversation saved after a successful macprovider tool-call turn can be resumed through a fresh provider process or fresh HTTP/WebSocket connection. The provider validates format and request-internal consistency, does not check a live minted-ID registry, and proceeds to inference. This is release-gating for v0.2.

Buyer-fabricated but internally consistent IDs MUST be accepted if they match the request-accepted regex. This is buyer-controlled prompt history; the model may believe it, and the buyer pays for inference, but it creates no provider provenance and no retroactive money-path implication.

Buyer-supplied assistant-history `tool_calls[]` and `role:"tool"` results are PROMPT DATA, NOT PROVIDER PROVENANCE. They MUST NOT create provider provenance, settlement entries, receipt output objects, or "provider emitted" audit claims for prior turns. Receipts for the current turn MAY bind the prompt hash that includes fabricated history, but MUST NOT attest that prior history was true or provider-minted.

#### 10d.7 Deliverable #7 — Per-call `function.arguments` byte cap

v0.2 public constants:

| Constant | Value | Meaning |
|---|---:|---|
| `SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP` | `1_048_576` | Maximum UTF-8 bytes for one final unescaped `function.arguments` string |
| `SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP` | `2_097_152` | Maximum summed UTF-8 bytes across all final unescaped `function.arguments` strings in one response |
| `SPEC018_ARGUMENTS_MAX_JSON_DEPTH` | `32` | Maximum decoded JSON nesting depth; unchanged from v0.1.5 |

The cap comparison is inclusive: byte length `<= cap` succeeds. Byte length is the UTF-8 byte length of the final unescaped `function.arguments` string value that an OpenAI client obtains after JSON/SSE parsing and fragment concatenation. It is not the byte length of the outer response JSON with string-escape overhead.

Parser-side runtime validation and coordinator §8.4 validation MUST use identical constants and an identical byte-counting function. A stricter parser or stricter coordinator is non-compliant for public SPEC-018 v0.2 behavior.

Both multi-call limits are enforced. Each individual `tool_calls[i].function.arguments` MUST be ≤ 1_048_576 bytes. The sum across all tool calls in the response MUST be ≤ 2_097_152 bytes. Per-call failure reason is `byte_cap_exceeded`; aggregate failure reason is `response_byte_cap_exceeded`.

For streaming tool calls, provider and coordinator MUST maintain per-call and per-response accumulators over decoded argument fragments. Before forwarding any SSE chunk that contains a `function.arguments` fragment, the component MUST compute whether accepting that fragment would exceed either cap. A cap-crossing chunk MUST NOT be forwarded. Settlement is finalized only at end-of-stream after every call closes and final-close validation passes.

v0.2 exposes no public configurability for these caps. They MUST NOT be buyer-negotiable and MUST NOT vary by public operator configuration on a deployment advertising SPEC-018 v0.2 compliance. Operators MAY run private experiments, but public v0.2 compliance requires the exact constants above.

Future v0.2.x MAY raise the caps but MUST NOT lower them, change the inclusive boundary, or change the UTF-8 unescaped byte-counting domain, as locked in §10c.

#### 10d.8 Out of v0.2 scope — v0.3 candidates

Three previously designed deliverables are deferred to v0.3 and MUST NOT be implemented as v0.2 public wire requirements beyond the explicit v0.2 amendments named below:

- Deliverable #2 model-hash → tool-call-family registry: verified-hash family/profile selection, designed in `specs/v0_3-design/02-registry.md`.
- Deliverable #3 prompt-echo guard full version: incremental/canonicalized parser-side defense against echoed tool-call markup from request prompts, designed in `specs/v0_3-design/03-echo-guard.md`. v0.2.3 deletes the v0.2.1 byte-exact full-block guard (§3.9) and ships without prompt-echo mitigation per §10c.1 Amendment 2.
- Deliverable #5 structured malformed-tool-call signal: buyer-visible `usage.macprovider_malformed_tool_call` schema, designed in `specs/v0_3-design/05-malformed-signal.md`.

The internal failure reasons used by v0.2 in §8.4 split validation, §10d.4 streaming termination, and §10d.7 caps are intentionally named so they can map cleanly to the v0.3 structured `usage.macprovider_malformed_tool_call.reason` enum. v0.2 does not expose that structured usage signal; internal logs and terminating SSE error objects are the only v0.2 surfaces for those reasons.

## 11. Open Questions

Q1. **RESOLVED in v0.2.0/v0.2.1.** Cline is the v0.2 anchor framework and release gate per §10d and AC-25a/AC-25b. Other §1-listed OpenAI-wire frameworks are expected-compatible observation targets; their compatibility matrix is v0.3+.

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
