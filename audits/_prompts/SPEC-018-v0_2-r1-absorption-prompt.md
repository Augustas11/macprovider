# SPEC-018 v0.2.1 — r1 Absorption Prompt

## Your task

Absorb 22 round-1 audit findings into `specs/SPEC-018-agentic-tool-calling.md`, bumping the SPEC to v0.2.1. The §10c v0.1.3-locked invariant amendment (item 1 below) is the load-bearing change; everything else follows.

**Lock discipline:** v0.2.1 is the FIRST time we explicitly amend a previously-locked SPEC-018 invariant. The change-log entry MUST narrate this amendment honestly with rationale. Future SPEC-018 versions may invoke the same pattern; v0.2.1 sets the precedent.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — current v0.2.0 SPEC to amend.
2. `specs/SPEC-018-v0_2-r1-audit.md` — round-1 audit narrative with all findings + absorption plan.
3. Per-lane audit files:
   - `specs/SPEC-018-v0_2-architect-r1-audit.md`
   - `specs/SPEC-018-v0_2-code-r1-audit.md`
   - `specs/SPEC-018-v0_2-security-r1-audit.md`
   - `specs/SPEC-018-v0_2-product-design-r1-audit.md`
4. `specs/SPEC-018-v0_2-design-synthesis.md` — original v0.2 design source.
5. Live repo for code-citation accuracy.

## Path B decision recorded

User chose **Path B** for the §10c model-hash invariant tension: explicitly amend the locked invariant in v0.2.0 to defer model-hash registry to v0.3. NOT a silent scope cut. The change-log entry for v0.2.1 must:
- Name the amendment ("§10c v0.1.3-locked clause re v0.2 model-hash registry is amended in v0.2.0/v0.2.1 to defer registry to v0.3").
- State the rationale ("narrow v0.2 scope makes registry curation strategically premature; binary-baked stub registry doesn't add real security value without curation governance").
- Note the precedent ("locked invariants are NOT immutable but require an explicit named amendment with rationale; this is the first such amendment in SPEC-018").
- Note that minimal v0.2 mitigations are added in lieu of the registry: minimal prompt-echo guard (item 4) + tightened §8.4.2 final-close (item 2).

## 22 absorptions

### Load-bearing edits

**1. §10c v0.2.0 amendment (Path B).** In change-log, name the amendment. In §10c body, add a sentence at the end: "AMENDED v0.2.0/v0.2.1: the v0.1.3-locked clause requiring v0.2 to enforce unknown-model_hash fail-closed via a registry is amended to defer registry to v0.3. Rationale: narrow v0.2 scope (Cline drop-in) made the curation work strategically premature. v0.2 mitigates via §3.8 minimal prompt-echo guard + §8.4.2 tightened final-close + AC-46 minimal model-hash binding observation. Full registry is v0.3 §10a #2."

Add AC-46: provider response MUST include `usage.macprovider_model_hash_observed: <hex>` field (additive, non-canonicalized) for v0.2 observation — provides forward-compat for v0.3 registry by letting buyers passively log the served `model_hash` against the modelID-declared family. (This is observation-only in v0.2; v0.3 will enforce.)

**2. §8.4.2 final-close tightening (closes Security C-1 + Code Q-1).** Final-close validator MUST require ALL of:
- Every opened `tool_calls[].index` has a terminal accumulated argument string (no partial-open at end-of-stream).
- The stream emitted `finish_reason: "tool_calls"` for the choice.
- The transport reached its normal completion marker (`data: [DONE]` for HTTP SSE; provider relay `complete` for WS-backed forwarding).
- No provider disconnect, timeout, relay error, authentication failure, truncation, or missing terminal marker occurred after incremental-open.

Absence of ALL four = final-close failure = `FaultBreakerQualifying` flag + zero provider-positive credits + no receipt for the turn + no sticky-route success write.

Cite live-repo paths: `phase4-coordinator/internal/buyer/server.go:2239-2255` (existing WS post-commit disconnect handling), `:2476-2487` (existing direct-HTTP post-commit disconnect), `:2469-2471` (existing direct-HTTP clean EOF — note current behavior may need patching for v0.2 final-close discipline).

Add new ACs: AC-47 (provider EOF after incremental-open without terminal markers → zero credits, terminal SSE error if possible, FaultBreakerQualifying recorded) for both `forwardWSStreaming` and `forwardStreaming` paths.

**3. §8.4.3 forbid `finish_reason: "tool_calls"` on final-close failure (closes Security H-3).** Add explicit MUST NOT: terminal-error SSE event MUST NOT carry `finish_reason: "tool_calls"`. Buyer SDKs (openai-python v2.44.0+, openai-node, etc.) MUST surface the terminal error frame as an exception/failed stream, NOT a successful assistant message with dispatchable tool_calls. Add AC-48: post-final-close-error stream, with openai-python v2.44.0 reader + Cline integration, no assistant message with dispatchable tool_calls is delivered to the framework's tool-execution boundary.

**4. Minimal v0.2 prompt-echo guard (closes Security H-2).** New section §3.9 (or §3.8.1 sub-section of new §3.8 below — your choice for placement consistency): if the COMPLETE native tool-call sentinel+body+close sequence appears VERBATIM in any request `messages[].content` or `role:"tool".content`, parser-side synthesis MUST fail closed to plain content. This is NOT the full incremental detector deferred to v0.3 — only exact-verbatim full-block match. Define byte-exact match semantics (case-sensitive, no normalization, full sequence not partial). Add AC-49: Cline-shaped request where a tool result contains a complete native Qwen tool-call block → model echoes verbatim → expected: no `tool_calls[]`, plain content fallback.

**5. §10d.1 failure-table canonicalization (closes Architect H-3 + Code H-2 + Security m-1).** In §10d.1 request-side failure mode table, change "`role:"tool"` missing `tool_call_id`" row error code from `invalid_request` to `invalid_tool_call_id` so the table matches §10d.6 + AC-32. Keep `content:null` → `invalid_request` for content-shape errors (different domain).

### Editorial / mechanical edits

**6. AC-14 v0.2 applicability note (closes Architect H-2).** Add a note immediately before AC-25 (and a back-reference at AC-14): "AC-14 is the v0.1.x ratification criterion (`role:"tool"` + assistant-history `tool_calls[]` fail with `unsupported_tool_messages`). For v0.2.0+, AC-14 is SUPERSEDED by AC-26/AC-27 (accept + render). The v0.1.x error path is no longer the desired behavior; the v0.2.0 success path is. AC-14 remains in the SPEC for historical lock-discipline." Do NOT renumber AC-14.

**7. §4 / AC-8 v0.2 streaming applicability override (closes Architect M-2).** Add a note in §4 (and at AC-8/AC-9): "§4 and AC-8/AC-9 describe v0.1.x buffered-to-end streaming behavior. For v0.2.0+, §10d.4 and AC-40 through AC-45 are authoritative for tool-call streaming. The §4 buffered behavior remains the v0.1.x ratification language."

**8. §10d v0.2 reader note (closes Architect H-1 + PD M-1).** Add a leading note at start of §10d: "**v0.2.0 reader note:** §10d supersedes §10a's earlier seven-item v0.2 target list for v0.2.0 scope determination. Deliverables #2 (model-hash registry), #3 (prompt-echo guard full version), and #5 (structured `malformed_tool_call` signal) are deferred to v0.3 per §10c v0.2.0/v0.2.1 amendment and the narrow Cline drop-in v0.2.0 product scope. §10a is preserved as v0.1.5 locked-content historical reference. §11 Q1 is RESOLVED by §10d (anchor framework = Cline)."

**9. Duplicate §3.7 → §3.8 (closes Architect M-1 + PD minor-1).** Renumber the v0.2 additive tool-prompt-template-profile section from §3.7 to §3.8. Locked §3.7 "Adding a new family" stays at §3.7. Update §10d.1 and any other cross-reference from "§3.7" (v0.2 sense) to "§3.8". Add a note: "v0.2.0/v0.2.1 renumbers the additive tool-prompt-template-profile section to §3.8 to avoid heading collision with locked §3.7."

**10. AC-23s alias (closes Architect M-3).** In §10d.4 add the sentence: "Note: in design notes (`specs/SPEC-018-v0_2-design-synthesis.md`) this is referred to as `AC-23s`. In this SPEC body, the streaming forward-compat regression extension is encoded as AC-43."

**11. Code citation regen (closes Code H-3).** Update line citations in v0.2 sections only (do NOT touch v0.1.5 citations):
- `ModelRuntime.swift:344` → `:353`
- `ModelRuntime.swift:395` → `:403`
- `server.go:2119` → `:2103` (function start), and add `:2149` for the actual WS byte-write
- `server.go:1234` → `:1241-1245`

Verify each citation by reading the live repo before encoding.

**12. §3.8 family-renderer byte-specifiable (closes Code H-1).** Add Qwen3 and Llama-3.3 prompt-template golden fixtures to §3.8. For each:
- Input: OpenAI `messages[]` array (one user message + one assistant tool_call + one role:tool result + one user message).
- Output: exact rendered prompt-template bytes the renderer MUST produce for that family.
- Required rejection: if no family profile maps for a given modelID, render MUST fail with HTTP 400 `unsupported_modelID_for_multi_turn` (or similar — name the code).

Tie AC-26/AC-27 to these fixtures: "Implementation MUST produce byte-equivalent output to fixtures in §3.8 for Qwen3 and Llama-3.3 families given the fixture input."

If you cannot specify byte-exact bytes for Qwen3/Llama-3.3 native multi-turn tool-call templates from authoritative upstream sources, instead specify the template structure normatively (turn boundaries, role markers, tool-call markup format, tool-result markup format) and note that v0.2 IMPL must verify against the upstream model's chat template documentation. Cite Qwen3 chat-template doc (https://huggingface.co/Qwen/Qwen3-32B/blob/main/tokenizer_config.json) and Llama-3.3 chat-template doc (https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct/blob/main/tokenizer_config.json) for IMPL reference.

**13. §10d.4 SSE example concrete ID (closes Code M-1).** Replace `call_<32hex>` placeholder with `call_0123456789abcdef0123456789abcdef` (regex-valid for v0.1.5 §2.1 + §10d.6 provider-emitted regex `^call_[a-f0-9]{32}$`).

**14. AC-39 + AC-43 scope clarification (closes Code M-2).** Add a sentence to AC-39: "OpenAI SDKs (openai-python v2.44.0+, openai-node, etc.) may surface the terminal SSE error frame as an exception or failed stream. This is the intended behavior." Add a sentence to AC-43: "AC-43's no-parse-error requirement applies only to SUCCESSFUL streams. Terminal-error streams (AC-39) are expected to raise exceptions in the buyer SDK."

**15. AC-25 split + Cline tool mapping (closes Code H-4 + PD HIGH-1 + PD MEDIUM-3).** Split AC-25 into:
- **AC-25a (CI-amenable fixture):** pinned Cline version (specify), pinned repo (specify or describe), pinned prompt (specify), machine-readable session transcript schema (JSON with turns/tool_calls/timings), automated assertion of session-pass criteria. CI executable.
- **AC-25b (manual recorded smoke):** human-recorded session against actual Cline VS Code extension, video or screenshot artifact, qualitative UX assessment. Release evidence, not CI gate.

Tool requirements expressed as CATEGORIES, not specific names: directory listing/search, file read, file edit (full-write or patch), shell command. Add mapping table: "Cline VS Code extension legacy tool names: `list_files`, `search_files`, `read_file`, `write_to_file`, `execute_command`. ClineCore tool names: `bash`, `editor`, `read_files`, `apply_patch`, `search`. AC-25 categories cover both."

**16. AC-44 instrumented + benchmarked (closes PD HIGH-2).** Replace single 1500 ms TTFMO bound with:
- Provider-side timestamp instrumentation REQUIRED: `t_tool_call_open_detected` (provider-internal event), `t_first_forwarded_sse_byte` (coordinator-side), `t_first_gateway_byte` (gateway-side).
- Per-class hardware target: `t_first_gateway_byte - t_tool_call_open_detected` p95 ≤ 1500 ms on M4, ≤ 3000 ms on M2/M3 in a deterministic provider fixture (specify model: `qwen3-32b-4bit-mlx`; specify prompt; specify expected first-tool-call-open detection time per model).
- OR: replace fixed values with "TBD — measured baseline to be established in v0.2 IMPL benchmark commit". Note: this option defers a normative number but maintains the instrumentation requirement.

**17. AC-45 + buyer-visible streaming-mode header (closes Security M-3 + PD HIGH-3).** Add to §10d.4: "Streaming mode is exposed to buyers via the non-negotiating diagnostic response header `X-MacProvider-Streaming-Mode`. Values: `incremental` (default for v0.2 Cline-compatible models), `buffered_kill_switch` (operator-disabled), `buffered_provider_downgrade` (auto-downgraded due to malformed stream history). The header is observation-only — buyers MUST NOT use it for negotiation in v0.2."

AC-45 requires: header presence on every v0.2 response; correlation between header value and operator/provider state; AC fixture for each of the 3 values.

**18. v0.2 error envelope thicker (closes PD HIGH-4).** In §10d normative text, specify the v0.2 error envelope minimum fields for all v0.2-introduced errors:
```json
{
  "error": {
    "type": "invalid_request_error | api_error | upstream_provider_error",
    "code": "<stable enum value>",
    "message": "<human-readable>",
    "param": "<optional JSON path>",
    "retryable": true | false,
    "request_id": "<UUID>",
    "inference_ran": true | false,
    "settlement_ran": true | false
  }
}
```

Codes enumerated: `byte_cap_exceeded`, `response_byte_cap_exceeded`, `malformed_tool_call_final_json`, `provider_stream_downgraded`, `tool_result_too_large`, `tool_call_arguments_too_large`, `invalid_tool_call_id`, `tool_call_id_not_found`, `duplicate_tool_call_id`, `tool_call_result_out_of_order`, `unsupported_modelID_for_multi_turn`, `prompt_echo_blocked`. Each tagged retryable: yes/no.

**19. Aggregate request caps + linear validation (closes Security M-1).** Add to §10d.1:
- Total request body cap (raw bytes): 4 MiB (or aligned with SPEC-006 buyer-API body limit; cite the SPEC).
- Total decoded `role:"tool"` content bytes across all messages: 1 MiB.
- Total assistant-history `function.arguments` bytes across all messages: 2 MiB (aligned with §10d.7 per-response cap).
- Max `messages[]` array length: 256.
- Max total tool calls across all assistant messages: 128.
- Cross-message tool_call_id validation MUST be O(messages[] + tool_calls[]) via maps/sets, NOT O(N²).

**20. Buyer-fabricated history provenance language (closes Security M-2).** Add to §10d.6 (after the buyer-fabricated ID acceptance paragraph): "Buyer-supplied assistant-history `tool_calls[]` and `role:"tool"` results are PROMPT DATA, NOT PROVIDER PROVENANCE. They MUST NOT create provider provenance, settlement entries, receipt output objects, or 'provider emitted' audit claims for prior turns. Receipts for the current turn MAY bind the prompt hash that includes fabricated history, but MUST NOT attest that prior history was true or provider-minted."

**21. "Why Cline gates v0.2" paragraph (closes PD MEDIUM-2).** Add a paragraph at the start of §10d before the deliverable subsections: "Why Cline gates v0.2: Cline (https://github.com/cline/cline) is the v0.2 anchor framework because (a) ~1M+ VS Code marketplace installs make it the largest OpenAI-wire agentic-coding tool; (b) heavy multi-turn tool-call workload (`read_file`/`write_to_file`/`execute_command`/etc., 20–50 iterations per session) stress-tests the full agentic loop; (c) `write_to_file` arguments include full file contents, exercising the streaming UX and per-call byte cap; (d) open-source + active community enables real-session evidence collection for the v0.2 release gate. Other §1-listed OpenAI-wire frameworks are expected-compatible observation targets; their compatibility matrix is v0.3+."

**22. Aggregate streaming budget Q (closes Security Q-1).** Add to §10d.4: "Concurrent streaming budget: maximum concurrent active tool-call streams per coordinator process is bounded by SPEC-006 buyer-API connection limits (cite specific clause if it exists; otherwise: 'configured via coordinator deployment, recommended 64 concurrent buyer connections per process'). Total streaming accumulator memory budget = max_concurrent × 2 MiB. Per-buyer streaming-accumulator budget = 2 MiB × max_concurrent_per_buyer; max_concurrent_per_buyer is operator-configurable but MUST be ≤ 4 for v0.2."

## Version bump + change-log

- Header `**Version:**` line: bump to `0.2.1 (2026-06-27, r1 absorption — §10c amendment + Security C-1 final-close tightening + 19 other findings absorbed)`.
- Header `**Status:**` line: keep `Draft`.
- Add v0.2.1 change-log entry at top, BEFORE v0.2.0 entry.
- v0.2.1 change-log MUST narrate item 1 (§10c amendment + Path B precedent) prominently as the load-bearing change.
- Include a buyer-visible delta bullet list (read this if skimming).

## Additional output

Write `specs/SPEC-018-v0_2_1-DRAFT-NOTES.md` listing all 22 absorptions, each with: finding ID, what changed, location, any loose interpretation, any open follow-up.

## Constraints

- Do NOT alter locked v0.1.5 content (§1-§10b, AC-1 through AC-24) except where this prompt explicitly directs (e.g., item 6 AC-14 applicability note placement, item 7 §4 applicability note, item 8 §10d reader note).
- Item 9 (renumber §3.7 → §3.8) IS a lock-amendment; consistent with Path B; document in change-log.
- Item 1 (§10c amendment) IS a lock-amendment; consistent with Path B; document in change-log.
- These are the ONLY lock-amendments in v0.2.1. All other absorptions are additive in v0.2 sections.
- Money-path settlement protection MUST be preserved through all absorptions.

## What this produces

A v0.2.1 draft ready for round-2 4-lane audit. If round 2 returns 0/0/0 across all lanes, proceed to Claude blind-spot pass. If not, loop r3.
