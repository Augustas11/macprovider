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
 6. **Non-Harmony byte identity:** If the request `modelID` does not match the §3.1 Harmony row, the Harmony parser MUST be bypassed. Existing Qwen/Llama parser behavior remains unchanged. Before computing a content delta or feeding decoded text to the incremental tool-call parser, the provider MUST hold back the longest trailing suffix that is a proper prefix of any deterministic `clean_up_tokenization_spaces` rewrite pattern (`" ."`, `" ?"`, `" !"`, `" ,"`, `" ' "`, `" n't"`, `" 'm"`, `" 's"`, `" 've"`, `" 're"`). The terminal flush releases the finalized text. Non-Harmony streaming content and tool-argument concatenations MUST therefore be byte-identical to the corresponding non-streaming decoded bytes for the same generated text and token IDs. The buyer-delivered concatenation remains the streaming output, structured-output terminal-validation, and settlement domain under SPEC-015 §N.5. Retaining a cleanup-deleted space is permitted only as bounded defensive fallback behavior for an unknown cleanup rewrite outside this fixed rule set; it MUST NOT apply to streamed tool arguments, and any such argument mismatch fails final-close. Harmony retains the exact parity rule in rule 4.
 
 ## 4. Streaming Wire Shape
 
 When `stream = true`, the buyer-visible response MUST use OpenAI-style SSE chat-completion chunks.
 
 The v0.1 as-built streaming behavior is buffered-to-end for tool-enabled requests. It is not token-incremental for tool calls. v0.2 promotes token-incremental streaming per §10a.
 
 **v0.2 applicability note:** §4 describes v0.1.x buffered-to-end streaming behavior. For v0.2.0+, §10d.4 and AC-40 through AC-45 are authoritative for tool-call streaming. The §4 buffered behavior remains the v0.1.x ratification language, including AC-8 and AC-9.
 
 The provider MUST emit an initial chunk with:
 
 - `choices[0].delta.role = "assistant"`;
 - `choices[0].delta.content = ""`;
 - `choices[0].finish_reason = null`.
 

hook: PostToolUse
hook: PostToolUse
hook: PostToolUse Completed
hook: PostToolUse Completed
hook: PreCompact
hook: PreCompact Completed
context compacted
hook: PostCompact
hook: PostCompact Completed
codex
Security review result: BLOCK. Two MEDIUM findings remain in the full combined diff.

- MEDIUM — External runtime allowlist does not prove an external provider is reachable.  
  File: [server.go](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6873), [multi_turn_test.go](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/multi_turn_test.go:644)  
  Failure scenario: a Trusted Pool has a non-empty external runtime allowlist but contains only native providers—or native and external candidates with no explicit engine selection. The gate is disabled solely because the allowlist exists, leaving native providers eligible. An unsupported model can receive tool history, return the provider-side 400 that collapses into a 502, and accumulate degradation failures. The current test explicitly permits this with an external allowlist and only a native member.  
  Fix: apply the gate per candidate/attempt. Exclude unsupported native candidates while retaining genuinely reachable external candidates. If none remain, return the pre-dispatch 400. Cover native-only and mixed-pool routing, including failover, and assert no provider-state mutation.

- MEDIUM — Model-class narrowing weakens the Trusted Pool model allowlist.  
  File: [server.go](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:7264), [server.go](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:7295), [server.go](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:9121)  
  Failure scenario: a pool allows Qwen3.6 but not Llama3.2, while a public model class contains both. A normal request correctly fails the “every class member must be allowed” policy. A tool-history request first narrows the class to Qwen3.6 and then passes the pool allowlist, effectively authorizing a class alias the pool policy rejected.  
  Fix: preserve the original resolved class for pool authorization checks. Use a separate narrowed class only for SPEC-018 eligibility and selection. Add a regression expecting `400 pool_model_not_allowed` for a partially allowed class with tool history.

- LOW — Accepted carry: the SPEC-018/SPEC-019 family predicate remains duplicated across coordinator enforcement, gateway advertisement, and readiness probing.  
  Files: [server.go](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6897), [openrouter_models.go](/Users/augstar/macprovider-or-features/phase5-gateway/internal/router/openrouter_models.go:389), [openrouter_readiness_probe.py](/Users/augstar/macprovider-or-features/scripts/openrouter_readiness_probe.py:138)  
  Failure scenario: a future family update reaches only some surfaces, causing false capability advertising or erroneous buyer rejection.  
  Fix: derive the predicates from one manifest or add cross-surface conformance coverage.

INFO:

- The R2 model-class provider-degradation bypass is fixed for global/native routing: mixed classes are filtered to profiled members.
- The public listing is Qwen3.6-only, paid-only, and exposes no provider identifiers or infrastructure details.
- Pre-dispatch rejection occurs before idempotency reservation. It creates a buyer-failure request log but no provider assignment, receipt, provider credit, or settlement subject.
- Targeted coordinator, gateway, and readiness-probe tests passed. Diff whitespace and `CONFORMANCE.json` validation also passed.

VERDICT: C=0 H=0 M=2 L=1.
