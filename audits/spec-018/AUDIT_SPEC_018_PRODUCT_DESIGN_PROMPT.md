# SPEC-018 v0.1 — PRODUCT-DESIGN-lane audit

You are the **product-design** lane of a four-lane audit (architect / code / security / product-design) of `specs/SPEC-018-agentic-tool-calling.md` v0.1. Stay narrowly in your lane.

The product-design lens cares about: anchor-example fidelity (does the user's actual workflow work end-to-end against the SPEC as written?), where buyer expectation diverges from SPEC reality, scope-creep risk in §10, overclaim/underclaim language, the "user can grok this from §1" test.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1 (commit `77c0ec5`)
- This is a **post-hoc ratification SPEC** of cf2f135 + c823a96 + 7b8b1be. Product-design lane: does the ratified surface actually deliver the Ring-1 product, or does it ship a half-product wearing the Ring-1 label?

## The anchor example you're auditing against

A developer (your representative user) opens Cline (or Cursor, Aider, Claude Code, Continue, Zed, OpenCode — any OpenAI-shape agent framework). They configure:

```bash
export OPENAI_BASE_URL=https://api.malibu.tech/v1
export OPENAI_API_KEY=<buyer-token>
```

They pick model `qwen3-coder` (or similar). They tell the agent: "refactor this file, run the tests, commit the result."

The agent runs N turns: read file → suggest edit → apply edit → run test → read failure → suggest next edit → ... The agent loop runs on the user's laptop. The model runs on an M-series Mac on the macprovider network. macprovider is the inference marketplace + transport.

**Your audit question: does SPEC-018 v0.1, as written, deliver THIS workflow?**

## Product-design-lane scope (apply each; stay in lane)

### PD-1. Multi-turn limitation vs. agent-loop reality
§6 + AC-14 + AC-16's footnote ratify that the current phase3 provider **rejects** multi-turn tool-result messages with `unsupported_tool_messages`. A second turn (after the agent executes the tool and tries to send the result back) fails at the provider boundary.

**This is the load-bearing question for the anchor example.** An agent loop is, by definition, multi-turn: assistant emits tool_call → user (framework) executes → user sends `role: "tool"` message with result → assistant emits next tool_call. The current provider fails on step 3.

- Does the SPEC's Ring-1 product framing in §1 ("drop-in OpenAI tool-calling wire for client-side agent frameworks") survive AC-14? Or does §1 overclaim a working product when the as-built only delivers turn 1?
- Cline/Cursor/Aider users would discover this on the second tool call of EVERY session. Is the SPEC honestly representing a "first-turn-only" product as Ring-1 complete?
- If the SPEC v0.1 is "first-turn-only", should §1 say so explicitly ("v0.1 enables single-turn tool-call responses; full agent loops require v0.2 per AC-14's promotion") OR should v0.1 not lock until the provider supports multi-turn?
- Is the right product-design move to:
  - (a) ratify v0.1 as-is, ship the multi-turn fix in v0.2 fast,
  - (b) hold v0.1 until multi-turn lands,
  - (c) re-scope v0.1 to a strict "tool-call wire-shape compatibility certificate" without claiming Ring-1 product delivery?

Take a position. This is the most important finding the product-design lane can make.

### PD-2. Buffered-to-end streaming vs. agent UX
§4 ratifies buffered-to-end streaming for tool calls. A Cline user watching their agent work expects to see *streaming* progress (the tool-call indicator appears, the arguments stream in, the call fires). Buffered-to-end means the user sees a long pause, then a complete tool call.

- For the AI-coding workflow, is buffered-to-end a noticeable UX regression vs. OpenAI / Anthropic APIs (which stream tool-call deltas)? Frame the actual user impact.
- Q1 reserves the promotion to v0.2. Is "v0.2 will fix it" credible product positioning, or a vapor promise without a concrete v0.2 timeline in §10?
- Does the SPEC need a "what users will observe" sub-section in §1 (or §4) calling out this difference vs. OpenAI baseline?

### PD-3. Anchor example coverage — does AC-16 actually verify the product?
AC-16: "An OpenAI Python SDK 1.x client pointed at the buyer URL can parse the first assistant tool-call response for the canonical `get_weather`-style loop without response adapters. SPEC-018 v0.1 does not certify the second provider turn after tool execution because AC-14 ratifies the current provider limitation."

- Is "first turn only" verification adequate? In real agent frameworks, the second turn is where most failures happen (history shape, tool_call_id echo, tool result formatting).
- AC-16 picks a `get_weather`-style demo. Real users run Cline against real code. Should AC-16 (or a new AC) require an end-to-end test against an actual agent framework (Cline / Aider) rather than a hand-rolled OpenAI SDK call?
- §1 promises drop-in compatibility with named frameworks: Cline, Cursor, Aider, Claude Code, Continue, Zed, OpenCode, Vercel AI SDK, LangChain, LlamaIndex, Pydantic-AI, n8n. AC-16 only covers raw OpenAI SDK. Does the SPEC need ≥1 AC per major framework, or is the wire-shape AC sufficient (i.e. "if wire matches OpenAI, all frameworks work by transitivity")?

### PD-4. Model family table — Qwen3-Coder mention
§1 names `qwen3-coder` in the framing. §3 lists Qwen2.5 / Qwen3 native and Qwen coding-tuned. Verify these match the actual model the user would pick.

- If the network actually serves `qwen3-coder-30b` (or similar specific SKU), is the SPEC vague about which exact model SKUs are tool-call-capable in v0.1?
- For an AI-coding-tool user, "which model do I pick" is the load-bearing question. Does §3 give them an answer, or does it require code-reading?
- Should §1 (or a new sub-section) include an explicit "model SKU compatibility table" naming which model IDs the SPEC commits to supporting at v0.1?

### PD-5. Open Questions risk — what gets through to v0.1 users
Of the 9 open questions, which ones will users hit FIRST?
- Q1 (buffered streaming) — every session
- Q3 (multi-turn) — every multi-turn session (i.e., every real session)
- Q6 (content-sentinel detection) — security issue, but invisible to most users
- Q5 (warm-swap mid-tool-call) — rare but data-loss-class

Should §1 or the change log have a "Known v0.1 limitations" callout that names the user-visible items (Q1, Q3) so a SPEC reader knows what they're buying?

### PD-6. The "name a v0.2 release date" question
§10 reserves a long list for v0.2+ (structured output, streaming-incremental, prefix-cache, SDKs, max_tool_calls, malformed_tool_call promotion, second-turn).

If v0.2 is unbounded, §10 is a wishlist. Is there a forcing function — a customer commitment, a public deployment milestone — that anchors v0.2? If not, does the SPEC need an explicit v0.2 roadmap section calling out at least the gating items (multi-turn, streaming)?

### PD-7. §1 product framing — does it match the as-built?
§1 reads: "A buyer MAY point an OpenAI-shaped client at the buyer-side gateway and receive assistant tool-call responses that the client can parse without macprovider-specific response adapters."

Word-by-word audit:
- "receive assistant tool-call responses" — yes, first turn only.
- "without macprovider-specific response adapters" — yes, the wire shape is OpenAI.
- "client" — singular response. The framing avoids saying "agent loop." Is this honest hedging, or is the SPEC framing itself a quiet acknowledgment that Ring-1 v0.1 doesn't actually do the full agent loop?

If the framing is hedged, should §1 be even more explicit ("v0.1 enables agent frameworks to receive their first tool call from a macprovider provider; full multi-turn agent loops are a v0.2 deliverable") so the SPEC doesn't have to be parsed line-by-line for users to understand they're getting a 50% product?

### PD-8. Cross-comparison with industry baseline
Users will compare macprovider to OpenAI, Anthropic, Together, Fireworks, Bedrock for tool-call workloads.

- OpenAI: full multi-turn, token-incremental streaming, native `response_format: json_schema`, parallel tool calls (multiple in one response).
- Anthropic: similar parity, plus computer-use tool, prompt caching.
- Together / Fireworks: model-family-specific support, varies.

What does macprovider v0.1 deliver vs. these baselines?
- ✅ wire-shape parity (first turn)
- ❌ multi-turn
- ❌ token-incremental streaming
- ❌ response_format json_schema
- ❌ prompt caching
- ✅ "your own M4" cost story
- ✅ P2P-marketplace differentiation

Is this an honest competitive position to ratify as "Ring-1 complete," or is the SPEC mislabeling a v0 product as Ring-1?

### PD-9. Scope creep watch in §10
§10's wishlist includes "Promotion of response parse failures from plain-content fallback to a structured `malformed_tool_call` error" and "Full provider-side acceptance of second-turn tool-result request messages."

These are user-visible behaviors that the user-facing product needs. Bundling them in §10 alongside "Python and TypeScript SDK wrappers" (which is convenience) suggests the SPEC treats critical and nice-to-have as equivalent v0.2 items.

Recommend §10 be split into:
- §10a — "Required for full Ring-1 product" (multi-turn, token-incremental streaming, malformed_tool_call promotion)
- §10b — "Reserved for future enhancement" (structured output, prefix-cache, SDKs, max_tool_calls cap)

Does this re-organization help users + roadmap, or is it premature?

### PD-10. The "user-visible upgrade contract"
When v0.2 ships, will an existing v0.1 user's agent framework code keep working? §2 + §3 + §4 are normative; §6 is a partial ratification. Is the SPEC clear that v0.2 changes (e.g. enabling multi-turn) are PURELY additive — i.e. a v0.1 user is not broken by v0.2?

If the answer is yes: state it explicitly as an invariant. If unclear: this is a product-stability question that should be resolved before v0.1 locks.

## Output format

Return a single audit report:

```
# SPEC-018 v0.1 — Product-design-lane round-1 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- User impact: who hits this, when, what they see
- SPEC location: §N or AC-N
- Current SPEC framing:
- Reality from anchor example:
- Recommended fix to SPEC body (specific edits):

## Verdict
[READY TO LOCK | FIX REQUIRED]

## Anchor-example walk-through
A user opens Cline. Configures the buyer URL. Issues "refactor this file."
Walk through the first 3 turns of that session against SPEC-018 v0.1 as written.
At which step does it work? At which step does it break or surprise the user?
Conclude with a 2-3 sentence honest assessment of whether v0.1 delivers Ring-1.
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable.

Stay in product-design lane. Code-citation accuracy + security attack surface + architectural altitude all belong to other lanes. Your job: does the user get the product the SPEC promises?
