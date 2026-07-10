# DESIGN_SPEC_018_v0_2 — Deliverable #1: Multi-turn provider acceptance

## Context

You are designing **SPEC-018 v0.2**, building on locked **SPEC-018 v0.1.5** (`specs/SPEC-018-agentic-tool-calling.md`). v0.1 is the "first-turn OpenAI tool-call wire-shape certificate." v0.2 must turn macprovider into an actual usable agentic-coding product.

**Anchor framework decision (locked):** v0.2 release-gate is **Cline** (VS Code AI coding extension, ~1M+ installs, heavy multi-turn tool-call workload — `read_file`/`write_to_file`/`execute_command`/`list_files`/`search_files`/`browser_action` per turn). A single Cline coding session = 20–50 multi-turn iterations. Other §1-listed frameworks are best-effort observation; expansion is v0.3+.

**v0.1.5 baseline you must respect:**
- §10c forward-compat invariant — v0.2+ MUST preserve v0.1.3 non-streaming wire shape including the `call_` ID prefix
- §10c buyer-consent header override semantics for fail-closed registry decisions
- §2.3 sorted-keys recursive canonicalization (SPEC-015 v0.3 receipts binding)
- §8.4 commit-worthy validator DoS bounds (32 depth / 256 KiB)
- Money-path: malformed pre-commit tool deltas → HTTP 502 + `FaultBreakerQualifying` → zero provider credits (`phase4-coordinator/internal/buyer/billing_recorder.go:176` + `formula.go:112`)

## This deliverable: §10a #1 — multi-turn provider acceptance (closes AC-14)

**Current state:** The phase3 provider rejects:
- Buyer requests with `role:"tool"` messages → `unsupported_tool_messages`
- Buyer requests with assistant-history `tool_calls[]` (echoing the provider's prior synthesized response back) → same rejection

**Required v0.2 state:** Both shapes accepted. A complete Cline coding session (turn 1 → tool execution → turn 2 → tool execution → … → turn N) completes successfully against a v0.2 phase3 provider connected through coordinator/gateway.

## Design questions to answer

1. **Where exactly does the provider reject today?** Identify the code path in `phase3-binary/Sources/macprovider-cli/` (likely an input validation layer or chat-template adapter) that emits `unsupported_tool_messages`. Cite line numbers.

2. **MLX chat-template threading**: How should `role:"tool"` content be threaded into the MLX model's chat template? Different model families (Qwen2.5/Qwen3, Llama-3.3) have different multi-turn tool-call template conventions. Should the parser-family registry (§3.1) own the inverse: "given family X, render tool messages using template Y"? Or should the chat template be carried out-of-band per modelID?

3. **assistant-history `tool_calls[]` echo**: When buyer sends a `messages[]` array where some `assistant` entries contain `tool_calls[]` (the buyer is replaying the conversation back), what does the provider do? Options: (a) treat as plain assistant message with structured fields ignored, (b) re-render into the model's native tool-call markup so the model "sees" its prior calls correctly, (c) reject if `model_hash` doesn't match the family that originally minted those IDs.

4. **Tool-result content size**: Cline `read_file` can return a 100KB+ file's contents as a `role:"tool"` message. What's the v0.2 fail-closed cap on individual tool-result size? Should oversize tool results truncate (with explicit marker), reject the whole request, or pass through (relying on the model's context window to fail naturally)?

5. **Receipt canonicalization across multi-turn**: SPEC-015 v0.3 binds receipts to canonicalized output. Multi-turn means input `messages[]` is longer; output is still one assistant turn. Does receipt canonicalization need to change to bind input-multi-turn-shape too? Or does v0.2 keep receipts output-only and rely on the existing canonicalization?

6. **Empty/invalid tool messages**: `messages[]` with `role:"tool"` but `content: ""`, `content: null`, `tool_call_id` missing, `tool_call_id` referencing an ID the provider never minted in this session (cross-session reuse). What's the fail mode for each?

7. **Session statefulness**: Is the provider stateless across turns (relies on buyer to replay full `messages[]` each turn — the OpenAI default), or does v0.2 introduce session-scoped state (e.g., a registry of "tool_call_ids this provider has minted this session")? Stateless is simpler and matches OpenAI. Stateful gives stronger validation (closes deliverable #6) but creates new concurrency/cleanup work.

8. **Cline session pass criteria for AC-25**: What's the minimum recorded Cline session that constitutes evidence the release is ready? Define: N turns, M tool calls, K file edits, must include browser_action or not, must include error/recovery turns or not. This is the v0.2 lock evidence.

## Output format

Produce a normative design recommendation covering all 8 questions, with:
- Specific code locations to modify (cite paths and line numbers from the live repo)
- Failure modes enumerated with proposed HTTP/error responses
- Cline session pass criteria as a numbered checklist
- Tradeoffs flagged where you chose one option over another
- v0.1.5 forward-compat impact analysis (does this break anything in §10c?)

Be concrete. v0.2 needs to ship; this is not exploratory design.
