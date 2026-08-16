# BUILD_SPEC_018 — Agentic tool calling v0.1 (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-spec-018-tool-calling` (a worktree of `macprovider-poc` on branch `spec/018-agentic-tool-calling`). You have no memory of prior conversations. Read this prompt end-to-end before writing anything.**

Your job is to write `specs/SPEC-018-agentic-tool-calling.md` v0.1 — a normative spec for **OpenAI-compatible tool-calling wire compatibility: provider-side response synthesis** on the macprovider network.

## The product framing (read first — defines scope)

macprovider is a P2P inference marketplace. Buyers point an OpenAI-shaped client at the buyer-side gateway and pay per-token for inference served by an M-series Mac provider on the network.

The agentic-coding wave (Cline, Cursor, Aider, Claude Code, Continue, Zed, OpenCode, Vercel AI SDK, LangChain, LlamaIndex, Pydantic-AI, n8n, etc.) is the dominant tool-calling workload that exists today. Every one of those frameworks speaks the OpenAI `tool_calls` wire shape. SPEC-018 v0.1's product statement is:

> **A macprovider seller MUST emit OpenAI-wire-compatible `tool_calls` so that any OpenAI-shape agent framework treats the macprovider buyer URL as a drop-in inference endpoint. The agent loop runs on the buyer's machine. The model runs on the seller. The network is the marketplace + transport.**

Three rings of "agentic tool calling" exist as products. v0.1 covers **only Ring 1**, and §non-goals MUST name the other two by name so future PRs cannot quietly cement them into this surface:

| Ring | Product | v0.1 status |
|---|---|---|
| 1 | Drop-in OpenAI tool-calling wire for client-side agent frameworks (this SPEC) | IN scope |
| 2 | Provider-side agent execution (provider runs the agent loop locally: sandbox, fs, shell, network egress) | OUT — future SPEC-019 placeholder |
| 3 | Provider-hosted MCP servers reachable from the model's tool loop | OUT — future SPEC-020 placeholder |

## Why this exists (read second)

cf2f135 ("Prove OpenAI tool-call wire compatibility", merged via PR #143) + c823a96 ("Keep gateway timeouts from masking relay cleanup", PR #159, merged 2026-06-25 10:46Z) + 7b8b1be ("Recognize Qwen coding tool calls", follow-up) shipped Ring 1 to `origin/main` as a sprint, deferring SPEC writing. This is the post-hoc ratification SPEC.

The existing SPECs already cover the **request half** (a buyer can include `tools[]` and `tool_choice` in the chat-completions request, and history can include `role: "assistant"` with `tool_calls[]` and `role: "tool"` with `tool_call_id`):

- `specs/SPEC-001-phase3-binary.md` lines 958–992 (request shape, validation order) and lines 2550–2584 (extra response fields, error taxonomy including `malformed_tool_call`)
- `specs/SPEC-002-coordinator.md` lines 1083–1084 (value-typed pass-through fields including `tool_calls`, `function_call`) and lines 2289–2318 (request validation including assistant/tool message shapes)

SPEC-018 v0.1 owns **the response-synthesis half**: how a macprovider seller turns the underlying MLX model's output (which is plain text in a model-family-specific grammar like Qwen's `<tool_call>…</tool_call>`) into a wire-compatible `tool_calls[]` JSON array that an OpenAI-shape client will parse without modification. SPEC-018 ratifies the as-built behavior in the source files listed below.

## Repo conventions you MUST honour

1. **Naming.** `specs/SPEC-018-agentic-tool-calling.md`. Verify SPEC-018 is unused: `ls specs/SPEC-018-* 2>/dev/null` MUST return empty.
2. **Header format (mandatory, line 3 is version of record):**
   ```
   # SPEC-018 — Agentic tool calling (provider-side response synthesis)

   **Version:** 0.1 (2026-06-27, initial draft — post-hoc ratification of cf2f135 + c823a96 + 7b8b1be)
   **Depends on:** SPEC-001 vX.Y, SPEC-002 vA.B, SPEC-006 vC.D
   ```
   Look up the current locked versions from line 3 of each: `grep -m1 '^\*\*Version' specs/SPEC-001-phase3-binary.md specs/SPEC-002-coordinator.md specs/SPEC-006-buyer-api.md`.
3. **Change log section** at the top (newest first). v0.1 entry: "Initial draft — post-hoc ratification of cf2f135, c823a96, and 7b8b1be as the network's Ring-1 tool-calling baseline."
4. **Numbered sections** like every other SPEC. Mirror the section style of `specs/SPEC-017-network-stats-api.md` and `specs/SPEC-015-receipts.md`.
5. **Acceptance criteria** at the bottom: numbered `AC-1`, `AC-2`, … that an implementer (and the audit lanes) can mechanically verify against the source tree.
6. **House voice:** terse, normative, MUST/SHOULD/MAY per RFC 2119. No marketing prose. State invariants, not aspirations. Where a behavior is "as currently implemented in `<file>:<line-range>`", cite the path + range — this is a ratification SPEC.
7. **Per [[feedback-spec-audit-file-convention]]**, audit narrative does NOT live in the SPEC body. Round files (`specs/SPEC-018-rN-audit.md`) hold audit detail; the change log carries one-line pointers.

## What v0.1 MUST normatively pin (the as-built ratification)

### §1 Scope + non-goals

State the Ring-1 product framing above. Name Ring 2 and Ring 3 explicitly as **out of scope for SPEC-018 entirely** (not deferred to v0.2 — out of this SPEC family). Reserve `SPEC-019` and `SPEC-020` placeholders by name so future PRs can find them. State explicitly: "A macprovider seller MUST NOT execute tools on behalf of the buyer. The seller's job ends at emitting the `tool_calls[]` array."

### §2 Response wire shape (non-streaming)

The HTTP response from the buyer-side gateway, when the model produces tool calls, MUST be an OpenAI chat-completions response with:

- `choices[0].message.role = "assistant"`
- `choices[0].message.content`: nullable string (may be present alongside tool calls, may be null when only tool calls were emitted — per the OpenAI contract)
- `choices[0].message.tool_calls`: array of objects, each with `id` (string), `type = "function"`, `function: {name: string, arguments: string}` — where `arguments` is a JSON-encoded *string*, not a JSON object (this is the OpenAI quirk; preserve it)
- `choices[0].finish_reason = "tool_calls"` when any tool call was produced; otherwise per existing SPEC-001 / SPEC-002 rules

Pin exact rules for:

1. **`id` generation** — examine `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift` and `OutputCanonicalizer.swift` and ratify the as-built scheme (prefix, entropy source, uniqueness invariant). If the as-built is "incrementing per response" or "random UUID prefixed with `call_`", state that exactly. Reject any scheme that would collide across multi-call responses.
2. **Multi-call ordering** — when the model emits N tool calls, the array order MUST match the textual order in the underlying model output. State the invariant.
3. **`arguments` string encoding** — exact JSON canonicalization rules (key ordering, whitespace, escapes). The as-built behavior is in `ToolCallParser.swift`; ratify it. If the parser sorts keys, say so; if it preserves model output order, say so.
4. **Interleaving with `content`** — when the model emits prose *then* a tool call *then* more prose, define how the parser collapses this into `(content, tool_calls)`. Look at the as-built and state the rule.

### §3 Detection grammar (model-family table)

The provider does NOT receive structured tool calls from the underlying MLX model — it receives plain text and parses model-family-specific markers. Lock the as-built grammar table as a normative §3 sub-section:

| Family | Detection pattern | Source |
|---|---|---|
| Qwen2.5 / Qwen3 native | `<tool_call>…</tool_call>` JSON body | `ToolCallParser.swift` line ~458–486 |
| Qwen coding-tuned | (the additional pattern landed in 7b8b1be — read the diff and state it exactly) | `ToolCallParser.swift` (post-7b8b1be sections) |
| Llama MLX (per 7b8b1be commit message) | (state pattern exactly from the source) | `ToolCallParser.swift` |

For each family, normatively pin:
- The detection regex / sentinel
- What "ambiguous duplicate argument keys" means and how the parser rejects them (per 7b8b1be's commit body)
- Fallback behavior when detection fails (treat as plain content)

Future families (DeepSeek, Mistral, etc.) are added via SPEC-018 vN+1 deltas, not by unannounced parser PRs. State this as a normative rule: "A new model family's tool-call grammar MUST land via a SPEC-018 version bump, not via a parser PR that mutates the table silently." This closes the [[audit-cycles-are-design-discovery]] gap that 7b8b1be itself created.

### §4 Streaming (SSE) wire shape

The OpenAI streaming contract emits `tool_calls` as `choices[0].delta.tool_calls[]` with `index` discriminator and per-chunk `function.arguments` partial-JSON strings. Pin:

- When the first `tool_calls` delta MUST fire (relative to the underlying model token stream)
- How `index` is assigned and reused across deltas for the same call
- Partial-`arguments` semantics: each delta carries an *additive substring* of the eventual `arguments` JSON; concatenation across deltas MUST reproduce the non-streaming `arguments` string byte-for-byte
- Terminator: which delta carries `finish_reason: "tool_calls"`
- Interleaving: whether `delta.content` and `delta.tool_calls` may appear in the same SSE event (look at as-built and pin)

**Critical:** examine the as-built carefully. If cf2f135 actually buffers-to-end before emitting tool_calls (one of the suggested follow-ups was "Verify cf2f135 streaming-incremental — confirm tool-call argument deltas stream as tokens arrive, not buffered-to-end"), the SPEC MUST pin whichever behavior the code does today, and §11 (open questions) MUST surface the question: "is buffered-to-end the SPEC-018 v0.1 baseline, with token-incremental promoted to v0.2?" Do not silently promise streaming-incremental if the code doesn't deliver it.

### §5 Error taxonomy

`malformed_tool_call` already exists in SPEC-001 line 2584. Cite that. Add to SPEC-018:

- When `malformed_tool_call` fires (which parse failures trigger it vs. fall back to plain content)
- `tool_call_limit_exceeded` if the as-built enforces a max-calls-per-response; if not, state explicitly "v0.1 imposes no limit; v0.2 may add `max_tool_calls`"
- `finish_reason` ordering when the underlying model hits its `max_tokens` mid-tool-call — does the partial call ship as `malformed_tool_call`, or as plain `content` with `finish_reason: "length"`? Pin the as-built.
- Ambiguous duplicate argument keys (7b8b1be): which error code, which HTTP status, where it surfaces in the SSE stream

### §6 Multi-turn round-trip

Cross-reference SPEC-001 §request validation (lines 958–992) and SPEC-002 (lines 2289–2318) for the request half. SPEC-018 §6 MUST normatively state:

- `tool_call_id` echo invariant — the `id` the provider mints in §2 is the same `id` the buyer MUST round-trip in subsequent `role: "tool"` messages. Coordinator and gateway MUST NOT rewrite `id`s.
- Coordinator pass-through invariant — SPEC-002 line 1083 already lists `tool_calls` as a value-typed pass-through field. SPEC-018 ratifies that and adds the test obligation: the coordinator MUST NOT strip, reorder, or canonicalize `tool_calls` or `tool_call_id`.

### §7 Gateway timeout co-requirement (ratify c823a96)

c823a96 raised `ResponseHeaderTimeout` default from 10s to 60s because non-streaming Qwen3 tool-call first-response latency on M-series exceeded the old default. SPEC-018 §7 MUST:

- Cite c823a96 and `phase5-gateway/internal/config/config.go`
- State the operator obligation: live gateway YAML MUST set `timeouts.coordinator_header_timeout_seconds: >= 60` for tool-call workloads, with the rationale tied to non-streaming first-response latency
- State the AC: a tool-call response from a first-token-latency-bound model (e.g. Qwen3-Coder-30B on M4) MUST complete through the public gateway under the v0.1-pinned timeout

### §8 Coordinator + gateway pass-through invariants

Enumerate every component on the wire and state which fields each one MUST treat as opaque pass-through:

- Provider HTTP server (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift`) — emits
- InferenceRelay (`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`) — preserves
- Coordinator WS relay (`phase4-coordinator/internal/ws/relay.go`) — opaque pass-through for tool_calls fields
- Gateway (`phase5-gateway/cmd/gateway/main.go`) — opaque pass-through

For each, identify the file:lines that implement pass-through and the negative test that proves no field is silently stripped.

### §9 Acceptance criteria (AC-1 … AC-N)

Numbered, mechanical. Examples (write the actual list; these are seeds):

- AC-1: Given Qwen3-Coder MLX emits `<tool_call>{"name":"foo","arguments":{"a":1}}</tool_call>`, the buyer-side HTTP response contains `choices[0].message.tool_calls[0]` with `function.name == "foo"` and `function.arguments == "{\"a\":1}"` (note: arguments is a *string*).
- AC-2: `choices[0].finish_reason == "tool_calls"` when any tool call is emitted.
- AC-3: Multi-call response preserves textual order in array order.
- AC-4: Ambiguous-duplicate-key arguments yield `malformed_tool_call`, not silent first-key-wins.
- AC-5: Streaming SSE deltas reconstruct the non-streaming `arguments` byte-for-byte under concatenation.
- AC-6: Coordinator pass-through preserves provider-minted `id` across the WS hop.
- AC-7: Public-gateway e2e against api.malibu.tech succeeds for a non-streaming Qwen3-Coder tool-call response within `coordinator_header_timeout_seconds >= 60`.
- AC-8: An OpenAI-shape Python client (`openai==1.x`) pointed at the buyer URL completes the canonical "get_weather" tool-loop example end-to-end without modification.
- … extend as needed.

### §10 Reserved for v0.2+ (future versions, not v0.1)

State as a §future-versions section, normatively reserved:

- **Structured output / `response_format: {type: "json_schema", …}`** — same parser surface, different terminator. Out of v0.1.
- **Streaming-incremental verification + promotion** — if v0.1 ratifies buffered-to-end, v0.2 promotes to token-incremental. The verification step ("does cf2f135 stream incrementally?") informs the v0.1 baseline.
- **Prefix-cache reuse primitives** — `X-MacProvider-Context-Cache` header semantics. Out of v0.1.
- **Python and TypeScript SDK surfaces** — wrappers over §2 / §4. Out of v0.1.
- **Per-call rate limit / `max_tool_calls` cap** — out of v0.1.

### §11 Open questions (audit-loop targets — do not resolve in v0.1)

Surface at least these; add more if you find them while reading the as-built:

- Q1: Is the streaming behavior in cf2f135 actually incremental, or buffered-to-end? (Reading the source resolves this; whichever the answer is, it pins the v0.1 baseline.)
- Q2: Should the `id` minting scheme be deterministic (so retries reproduce the same `id`) or non-deterministic? As-built says X; the trade-off is …
- Q3: For multi-turn round-trips, what happens if the buyer sends a `tool_call_id` that does NOT match any `id` the provider minted? (Validation behavior on `role: "tool"` messages.)
- Q4: Is there a per-response cap on the total `arguments` string length? Memory safety / abuse vector.
- Q5: How does SPEC-018 interact with SPEC-011 (warm-swap) when a model swap happens mid-tool-call? Is the call invalidated, retried, or completed against the new model?
- Q6: Model-family detection currently keys on `modelID` substring matches (`localizedCaseInsensitiveContains("qwen2.5")`) AND on output content (`rawOutput.contains("<tool_call>")`). What happens for a model that matches the content sentinel but not the name? Is that intentional flexibility or a fingerprinting attack surface?
- Q7: How does v0.1 interact with SPEC-015 receipts? Does `output_hash` cover the canonicalized `tool_calls` JSON, the underlying raw model text, or both? (Likely a SPEC-015 v0.2 question, but flag here.)

### §12 Non-goals

Restate the Ring-2 and Ring-3 exclusions from §1 as a dedicated §non-goals section so any future PR that creeps in that direction has a clear reference to cite as out-of-scope.

## What you MUST NOT do

- **Do not invent design.** This is a post-hoc ratification SPEC. If the as-built is suboptimal, flag it in §11 (open questions) — do not silently fix it in §2–§8. Fixes happen in v0.2 after the audit loop and a separate impl PR.
- **Do not paste large code excerpts.** Cite `file:line-range` and let the reader open the file. SPECs are normative contracts, not code dumps.
- **Do not promise behavior the code does not deliver.** The README and DECISION_CRITERIA already contain past "vapor claim" footprints. SPEC-018 must be true at v0.1 ratification; future behavior goes in §10 reserved.
- **Do not collapse Ring 2 / Ring 3 into "future versions of SPEC-018".** They are separate SPECs (019, 020). Naming them as out-of-SPEC, not out-of-v0.1, is the load-bearing scope guard.

## Files you MUST read before writing

As-built source (the SPEC ratifies these — read all of them):

- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift` (491 lines — entire file)
- `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift` (94 lines — entire file)
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` (search for `tool_call`, `tool_calls`, `finish_reason`)
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` (search for tool_call / tool_calls emission paths)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (search for tool_call wiring)
- `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift` (the locked behavior surface)
- `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift` (cf2f135 added relevant cases)
- `phase4-coordinator/internal/ws/relay.go` (c823a96 added late-frame handling)
- `phase5-gateway/cmd/gateway/main.go` + `phase5-gateway/internal/config/config.go` (c823a96 raised default timeout)
- `test/integration/tool_calling/openai_tool_call_e2e.py` and `test/integration/tool_calling/README.md` (e2e harness)
- `examples/tool_calling_demo.py` (the public-facing demo)
- The three commits' full diffs: `git show cf2f135`, `git show c823a96`, `git show 7b8b1be`

Existing SPECs (for house style + cross-references):

- `specs/SPEC-001-phase3-binary.md` — request-shape validation around tool_calls (lines 958–992, 2550–2584)
- `specs/SPEC-002-coordinator.md` — coordinator pass-through (lines 1083–1084, 2289–2318)
- `specs/SPEC-006-buyer-api.md` — `X-MacProvider-*` header conventions (so your future v0.2 `X-MacProvider-Context-Cache` reservation does not collide)
- `specs/SPEC-017-network-stats-api.md` — most recent locked SPEC, use as house-style anchor
- `specs/SPEC-015-receipts.md` — the SPEC that will eventually consume `tool_calls` into `output_hash` (Q7)
- `specs/README.md` — version-of-record warning

Context / memory:

- `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-three-lane-codex-audits.md`
- `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-spec-audit-loop-before-pr.md`
- `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-spec-audit-file-convention.md`
- `~/.claude/projects/-Users-augstar-macprovider-poc/memory/audit-cycles-are-design-discovery.md` (the 7b8b1be precedent — exactly the failure mode SPEC-018 §3 closes)

## Audit-loop discipline (NON-NEGOTIABLE)

After writing v0.1, the human operator will dispatch **four parallel audit lanes** per the SPEC-017 v0.1.7 + house [[feedback-three-lane-codex-audits]] pattern:

1. **codex architect** — system-shape, cross-SPEC consistency, future-version reservation hygiene
2. **codex code** — file:line citation accuracy against the as-built, AC mechanical-verifiability
3. **codex security** — attack surface: model-fingerprint, `arguments` injection, `id` collision, malformed-JSON paths, multi-call ordering vulnerabilities
4. **Claude product-designer** — Ring-1 product fit: does the anchor example (point Cline / Cursor / Aider at the buyer URL) actually work end-to-end against the SPEC as written? Where does buyer expectation diverge from SPEC reality?

Plus a **Claude adversarial-verifier** lane that reads codex's findings and tries to refute each one (per [[audit-cycles-are-design-discovery]] — codex's blind spots are not closed by more codex rounds).

Convergence bar (per [[feedback-three-lane-codex-audits]]): **all five lanes return 0 CRITICAL + 0 HIGH + 0 MEDIUM** before v0.1 locks. Each round produces `specs/SPEC-018-rN-audit.md` (per-round narrative) and `specs/SPEC-018-<lane>-rN-audit.md` per-lane findings. Body change-log entries are one-line pointers per [[feedback-spec-audit-file-convention]].

Round target: ≤6 rounds to lock (SPEC-017 took 10; the post-hoc framing should converge faster since there's less open design space).

## Open questions to flag (do not resolve in v0.1)

Already enumerated in §11 above. The audit lanes WILL surface more — list them all, do not silently resolve.

---

**End of prompt. Begin by reading the as-built source files in `/Users/augstar/macprovider-spec-018-tool-calling`, then the existing SPECs, then write `specs/SPEC-018-agentic-tool-calling.md`.**
