# SPEC-018 v0.1.5 — LOCKED

**Lock date:** 2026-06-27
**Lock commit:** `eb5bdde`
**Branch:** `spec/018-agentic-tool-calling`
**Worktree:** `/Users/augstar/macprovider-spec-018-tool-calling`

## Convergence trajectory

| Round | Tally (C/H/M/m/Q) | Verdict | Lanes |
|---|---|---|---|
| r1 | 2 / 5 / 13 / 5 / 7 | FIX REQUIRED | architect + code + security + product-design (codex) |
| r2 | 0 / 0 / 5 / 5 / 6 | FIX REQUIRED | architect + code + security + product-design (codex) |
| r3 | 0 / 0 / 0 / 1 / 0 | READY TO LOCK (codex 4-lane) | architect + code + security + product-design (codex) |
| Claude blind-spot | 0 / 3 / 5 / 4 / 3 (critic) + 0 / 0 / 0 / 5 / 2 (narrative) | Critic FIX REQUIRED | Claude critic + Claude analyst |
| r4 | 0 / 0 / 2 / 2 / 0 (code) + 0 / 0 / 0 (sec) + 0 / 0 / 0 (critic r2) | Code FIX REQUIRED | code (codex) + security (codex) + critic (Claude) |
| r5 | 0 / 0 / 1 / 0 / 0 (code) | Code FIX REQUIRED | code (codex) |
| r6 | 0 / 0 / 0 / 0 / 0 (code) | **READY TO LOCK** | code (codex) |

5 codex rounds + 1 Claude blind-spot pass to lock. SPEC-017 took 10 rounds.

## Why the Claude blind-spot pass mattered

Codex 4-lane converged in 3 rounds. Claude critic found 3 HIGH issues codex missed:

- **AC-23 tautology** — replayed v0.1.2 fixtures with v0.1.2 parser; couldn't fail. The §10c forward-compatibility invariant was unverified. Reworked to capture vN.M responses + parse with v0.1.3 baseline.
- **Claude Code / Cursor overclaim** — §1 named both as OpenAI-shape frameworks. Claude Code speaks Anthropic Messages API natively; Cursor IDE chat is proprietary. Removed; replaced with accurate 9-framework OpenAI-wire list.
- **Mixed-sentinel DoS** — v0.1.2 §3.6 mixed-sentinel rule was a buyer-prompt DoS vector. Any Cline workflow asking Qwen-Coder to discuss `<|python_tag|>` (legitimate code-assist query) would suppress the tool call. Dropped entirely; §3.2 modelID-match-required closes the cross-family bypass on its own.

## Final SPEC-018 v0.1.5 shape

**Product framing (§1):** First-turn OpenAI tool-call wire-shape compatibility certificate. Not a full agent-loop product (multi-turn is v0.2 per §10a #1).

**OpenAI-wire framework compatibility:** Cline, Aider, OpenCode, Continue, Vercel AI SDK, LangChain `ChatOpenAI`, LlamaIndex `OpenAI` LLM, Pydantic-AI `OpenAIModel`, n8n OpenAI node. Explicitly NOT: Claude Code, Cursor IDE chat, Zed AI assistant.

**Three IMPL deltas vs as-built (§1.2):**
1. §3.2 modelID-match-required (parser change in `ToolCallParser.swift:482-487`)
2. §8.4 commit-worthy delta validator (coordinator change in `phase4-coordinator/internal/buyer/server.go:2482-2605`)
3. AC-20 docs + AC-24 coordinator request-side WS-frame test + AC-23 baseline-pin file (`tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`)

**Security boundary:** v0.1 trusts provider modelID assertion; buyer-side validation obligation in §1 + AC-20; v0.2 §10a #2 closes the malicious-provider case via `model_hash` → family registry on top of live SPEC-008 Pillar A + SPEC-011 v0.5 infrastructure.

**Forward compatibility (§10c):** v0.2+ MUST preserve v0.1.3 non-streaming wire shape including `call_` id prefix; AC-23 regression gate.

**v0.2 deliverables (§10a, 7 items):** multi-turn provider acceptance, model-hash → family registry, prompt-echo guard, token-incremental streaming, structured `malformed_tool_call`, multi-turn `tool_call_id` validation, `function.arguments` byte cap. v0.2 is the "actual Ring-1 product" release.

## Artifacts on the worktree

Normative SPEC + IMPL prompt: `specs/SPEC-018-agentic-tool-calling.md` (the SPEC body)

Round-narrative + per-lane round files:
- `specs/SPEC-018-r{1,2,3}-audit.md` — round narratives
- `specs/SPEC-018-{architect,code,security,product-design}-r{1,2,3}-audit.md` — per-lane findings
- `specs/SPEC-018-{code,security}-r4-audit.md`, `specs/SPEC-018-code-r{5,6}-audit.md` — followup rounds
- `specs/SPEC-018-critic-blindspot-audit.md`, `specs/SPEC-018-critic-r2-audit.md` — Claude critic findings
- `specs/SPEC-018-product-narrative-blindspot-audit.md` — Claude narrative findings

Audit prompts (codex): `specs/AUDIT_SPEC_018_*_PROMPT.md` (r1 + r2 + r3 + r4 + r5 + r6)
Audit prompts (Claude blind-spot): `specs/AUDIT_SPEC_018_CRITIC_BLINDSPOT_PROMPT.md`, `specs/AUDIT_SPEC_018_PRODUCT_NARRATIVE_BLINDSPOT_PROMPT.md`, `specs/AUDIT_SPEC_018_CRITIC_BLINDSPOT_R2_PROMPT.md`

## Next steps

1. **Write `BUILD_SPEC_018_IMPL_PROMPT.md`** — implementation prompt for codex covering the 3 IMPL deltas:
   - §3.2 parser patch + test updates
   - §8.4 commit-validator patch + new test
   - AC-20 documentation updates (README, demo, integration runner)
   - AC-24 new coordinator WS-frame test
   - `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` creation
2. **Audit-loop the IMPL prompt** through the same 4-lane codex pattern until 0/0/0 (per [[feedback-build-audit-loop.md]]).
3. **Open SPEC-018 v0.1.5 PR** — net-new SPEC ships alone per [[feedback-bundle-spec-impl-one-pr.md]]. IMPL bundles separately after IMPL audit loop.
