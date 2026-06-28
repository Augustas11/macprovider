# SPEC-018 v0.1 — Code-lane round-1 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- SPEC location: §N or AC-N
- Code location: file:line-range (actual)
- What the SPEC claims:
- What the code does:
- Drift summary: 1-2 sentences
- Recommended fix to SPEC body (or QUESTION if code change is the right resolution):

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable.

Stay in code lane. Do not produce architecture-altitude or security-attack-surface findings — those have their own lanes.

## Final prompt

# SPEC-018 v0.1 — CODE-lane audit

You are the **code** lane of a four-lane audit (architect / code / security / product-design) of `specs/SPEC-018-agentic-tool-calling.md` v0.1. Stay narrowly in your lane.

The code lens cares about: file:line citation accuracy against the as-built source, acceptance-criterion mechanical verifiability, source-vs-SPEC drift, exact-value claims, parser behavior fidelity.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1 (commit `77c0ec5`)
- This is a **post-hoc ratification SPEC** of cf2f135 + c823a96 + 7b8b1be. The code-lane job: every "Source: file:NNN-MMM" reference and every behavioral claim is verified against the actual code on this branch.

## Code-lane scope (apply each; stay in lane)

### CODE-1. Source citation accuracy
For every `Source:` line in the SPEC (§2.1, §3, §4, §5, §6, §7, §8, and inline), open the cited file at the cited line range and verify:
- The file exists.
- The line range actually contains the cited behavior.
- The line range is tight (not pointing at a 200-line block to "find it somewhere in there").

Citations to verify (non-exhaustive — find them all):
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:776-828` (§2 response shape)
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:566-615` (§2)
- `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:16-38` (§2)
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:451-491` (§3 family table — verify Llama 3.3 detection)
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:77-123` (§3 Qwen coding-tuned Python-style)
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:266-448` (§3 ambiguous-key rejection)
- `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:125-159` (§3 locked tests)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:481-603` (§4 streaming)
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:433-556` (§4 SSE)
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:387-509` (§4)
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-27` (§3 fallback, §5 fallback)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839` (§3 declared-tools check)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:909-940` (§5 unsupported_tool_choice, unsupported_tool_messages)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:920-940` (§6 limitation)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:451-465`, `567-590` (§5 max_tokens behavior)
- `phase4-coordinator/internal/buyer/server.go:2940-3007` (§5 invalid_tools)
- `phase4-coordinator/internal/buyer/server.go:1236-1240`, `1982-2195`, `2320-2473`, `2482-2605` (§6, §8.4)
- `phase4-coordinator/internal/buyer/server_internal_test.go:70-103` (§8.4 commit-signal)
- `phase4-coordinator/internal/ws/relay.go:525-581`, `583-722`, `211-250` (§8.3)
- `phase4-coordinator/internal/ws/messages.go:199-225` (§8.3 frame shape)
- `phase5-gateway/internal/config/config.go:123-127`, `:183`, `:361-373`, `:462-475` (§7 timeout config)
- `phase5-gateway/cmd/gateway/main.go:81-95` (§7 timeout wiring)
- `phase5-gateway/internal/router/chat_proxy.go:237-516`, `:652-717` (§8.5)
- `phase5-gateway/internal/router/server_test.go:2516-2580` (§8.5 tests)
- `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:53-97`, `99-155`, `124-155`, `223-262` (§5, §6, §8.1 tests)

For each bad citation: CRITICAL if it leads to a wrong normative claim; HIGH if it points at the wrong file; MEDIUM if the line range is loose; MINOR if off by ≤5 lines.

### CODE-2. Exact-value drift — §7 gateway timeout
§7 states: "the current as-built gateway default is 300 seconds and validation requires the coordinator header timeout to be at least the coordinator request timeout."

c823a96's commit body says the raise was 10s → 60s. SPEC-018 says current is 300s.

Open `phase5-gateway/internal/config/config.go` and report the actual current default value for `coordinator_header_timeout_seconds` (and the `coordinator_request_seconds` cross-check). If the SPEC's "300" is wrong, this is a CRITICAL drift between SPEC and code.

### CODE-3. AC-17 — receipt-canonicalization claim
AC-17: *"Receipt canonicalization includes canonicalized `tool_calls[]` in the output object when tool calls are emitted."*

Open the receipt code path:
- `phase3-binary/Sources/macprovider-cli/` — find the receipt issuance code (likely references SPEC-015 / `RFC8785JCS.swift`).
- Verify whether `output_hash` / receipt content actually includes `tool_calls[]` today.

If receipts DO include tool_calls today: cite the file:line and the AC stands. If they do NOT: AC-17 is asserting behavior that doesn't exist — that's a CRITICAL drift (a SPEC ratification claiming behavior the as-built does not perform).

### CODE-4. ID-generation scheme exactness
§2.1: "uses Swift `UUID().uuidString`, removes hyphens, lowercases the result, and prefixes it with `call_`."

Verify the exact 4-step scheme against `ToolCallParser.swift` and `OutputCanonicalizer.swift`. If the as-built uses a different code path (e.g. different prefix, different normalization), report drift.

AC-4: "Response `tool_calls[].id` values start with `call_`, contain a lower-case hyphenless UUID suffix, and do not collide within the same response." Verify each property mechanically.

### CODE-5. §3 family-table fidelity
For each of the 3 declared families (Qwen native, Qwen coding-tuned, Llama 3.3 MLX), open `ToolCallParser.swift` and confirm:
- The exact detection pattern (sentinel string + modelID substring matches).
- The body grammar (JSON vs Python-style).
- The argument-field name (`arguments` vs `parameters`).

Specifically: SPEC says Qwen coding-tuned uses Python-style `<tool_call>name(key=value)</tool_call>`. Verify this against the parser. Is the same `<tool_call>` sentinel used for both Qwen native AND Qwen coding-tuned? If yes, how does the parser disambiguate?

The 7b8b1be commit added 344 lines to the parser. Walk that diff and check no family-specific behavior was missed in §3.

### CODE-6. Detection priority — "Llama before Qwen"
§3: "the v0.1 detector checks Llama 3.3 before Qwen." Verify the actual ordering in `ToolCallParser.swift` source. If the source checks Qwen first, this is a normative claim that contradicts the code — CRITICAL.

### CODE-7. Streaming-failure path
§4 last line: "If tool parsing fails in a tool-enabled streaming request, the provider emits plain content after generation completes and uses the non-tool finish reason (`stop` or `length`)."

Trace this path in `ModelRuntime.swift` and `HTTPServer.swift`. Confirm whether the buyer-observable stream shows partial-tool-call attempt deltas before falling back, or whether the buffered-to-end approach masks the failure entirely.

If the stream emits content deltas while parsing is still being decided, AC-10 ("`delta.content` and `delta.tool_calls` do not appear in the same SSE event") may be at risk depending on event boundaries.

### CODE-8. Error-code names
§5 declares two response-side error codes:
- `unsupported_tool_choice` — verify exact code string in `ModelRuntime.swift:909-940`.
- `unsupported_tool_messages` — verify exact code string in `ModelRuntime.swift:920-940`.

§5 also references `invalid_tools` from the coordinator (`phase4-coordinator/internal/buyer/server.go:2940-3007`). Verify the code string.

If any string differs (e.g. `unsupported_tool_role` vs `unsupported_tool_messages`), report MEDIUM.

### CODE-9. Acceptance-criterion verifiability
For each AC-1 through AC-18:
- Can a test author write a single test that returns pass/fail mechanically against the as-built?
- Are the inputs and expected outputs concrete enough?
- AC-15: "Live gateway configuration for tool-call workloads sets `timeouts.coordinator_header_timeout_seconds >= 60`" — this is a configuration assertion, not a code property. Is it verifiable from CI, or does it require operator inspection of live YAML?
- AC-18: production deployment AC. Is this verifiable in CI without hitting live infra? If not, mark how it gets verified.

### CODE-10. Out-of-scope claims that touch real code
§10 reserves "Token-incremental streaming verification and promotion" for v0.2+. Does the as-built code currently contain any *partial* token-incremental streaming for non-tool-call paths that contradicts the "buffered-to-end" framing of §4? (I.e., if regular streaming is incremental but tool-streaming is buffered, the SPEC must say that, not blanket "buffered-to-end".)

## Output format

Return a single audit report:

```
# SPEC-018 v0.1 — Code-lane round-1 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- SPEC location: §N or AC-N
- Code location: file:line-range (actual)
- What the SPEC claims:
- What the code does:
- Drift summary: 1-2 sentences
- Recommended fix to SPEC body (or QUESTION if code change is the right resolution):

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable.

Stay in code lane. Do not produce architecture-altitude or security-attack-surface findings — those have their own lanes.

## Raw output

```text
# SPEC-018 v0.1 — Code-lane round-1 audit

## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 3  
MINOR: 0  
QUESTIONS: 3

## Findings

### M-1 — Family table misses JSON argument-field fallback
- SPEC location: §3
- Code location: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:52-74`, `:473-479`
- What the SPEC claims: Qwen JSON uses `arguments`; Llama JSON uses `parameters`.
- What the code does: JSON calls use the family-preferred key first, then fall back to `arguments`, then `parameters` for every JSON family: `object[argumentKey] ?? object["arguments"] ?? object["parameters"]`.
- Drift summary: The parser accepts more JSON argument field shapes than the §3 table ratifies. This is parser behavior fidelity drift, not a runtime bug.
- Recommended fix to SPEC body: Change the table to say JSON bodies prefer `arguments` for Qwen and `parameters` for Llama, but v0.1 also accepts either `arguments` or `parameters` as fallback.

### M-2 — Duplicate-key citation omits Python keyword duplicate rejection
- SPEC location: §3 duplicate-key paragraph
- Code location: actual Python duplicate rejection is `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:102-113`; JSON duplicate validator is `:266-448`
- What the SPEC claims: Duplicate JSON keys and duplicate Python keyword names fall back to plain assistant content.
- What the code does: Claim is true, but the cited source range `ToolCallParser.swift:266-448` only covers JSON duplicate validation. Python duplicate keyword rejection is outside the cited range.
- Drift summary: Citation is incomplete for one declared duplicate-key class.
- Recommended fix to SPEC body: Source should cite `ToolCallParser.swift:96-123` plus `ToolCallParser.swift:266-448`; keep the existing tests citation `ToolCallParserTests.swift:125-159`.

### M-3 — InferenceRelay pass-through citation misses non-streaming `data` forwarding
- SPEC location: §8.2
- Code location: actual non-streaming data send is `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:307-309`; streaming data send is `:425-459`; frame send helper is `:532-549`
- What the SPEC claims: InferenceRelay preserves generated OpenAI JSON/SSE payloads as `data` strings over the coordinator WebSocket relay.
- What the code does: Claim is true, but the cited ranges omit the non-streaming `sendChunk(... data: response ...)` path.
- Drift summary: Citation does not fully cover the behavior it is used to prove.
- Recommended fix to SPEC body: Add `InferenceRelay.swift:269-309` to §8.2 and keep `:387-509`, `:532-564`, `:566-650`.

### Q-1 — AC-15 mixes CI-verifiable code with live operator configuration
- SPEC location: AC-15
- Code location: `phase5-gateway/internal/config/config.go:183`, `:361-373`; deploy gate `phase4-coordinator/dist/check-deploy-config.sh:268-281`; tests `phase5-gateway/internal/config/config_test.go:22-55`
- What the SPEC claims: Live gateway config for tool-call workloads sets header timeout `>= 60`; current builds also satisfy header timeout `>= request timeout`.
- What the code does: Defaults are 300/300 and validation rejects header `< request`. Deploy script can verify YAML, but “live gateway configuration” requires an operator/deploy artifact.
- Drift summary: The code property is mechanically testable; the live config assertion is not CI-local unless tied to a deploy check artifact.
- Recommended fix to SPEC body: Split AC-15 into code default/validation and deploy/live evidence requirements.

### Q-2 — AC-18 is a live production smoke, not a CI-local AC
- SPEC location: AC-18
- Code location: `test/integration/tool_calling/openai_tool_call_e2e.py:14-18`, `:147-165`; runner docs `test/integration/tool_calling/README.md:15-23`
- What the SPEC claims: A non-streaming Qwen3-Coder-class response completes through `https://api.streamvc.live/v1` when header timeout is `>= 60`.
- What the code does: The runner can verify a public gateway with env-provided base URL, key, provider pin, and model, but this depends on live infra and credentials. Its default model is Qwen2.5, not Qwen3-Coder-class.
- Drift summary: Verifiable as a manual/release smoke artifact, not as normal CI.
- Recommended fix to SPEC body: Mark AC-18 as “release smoke/manual live evidence” and require the JSON artifact from the integration runner with explicit Qwen3-Coder-class env values.

### Q-3 — AC-4 collision invariant is probabilistic in code
- SPEC location: AC-4 / §2.1
- Code location: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:59-75`, `:77-94`
- What the SPEC claims: IDs start with `call_`, use lower-case hyphenless UUID suffixes, and do not collide within the same response.
- What the code does: It mints each ID via `UUID().uuidString`, removes hyphens, lowercases, and prefixes `call_`. There is no explicit per-response de-duplication loop.
- Drift summary: Shape is mechanically verified; non-collision relies on UUID uniqueness, not an enforced runtime check.
- Recommended fix to SPEC body: Either phrase AC-4 as “fresh UUID-derived IDs; observed IDs are unique in test response” or add a code-side collision guard if strict mechanical non-collision is required.

## Verdict
FIX REQUIRED

