# RESEARCH_232 RUN — Continuous batching on Apple Silicon (execution wrapper)

**Carry this in a fresh session.** Self-contained. This is the *execution wrapper*
for RESEARCH_232; the research payload it drives is
`audits/_prompts/RESEARCH_232_MULTISTREAM_BATCHING_PROMPT.md` (Parts 1–6, the
four-approach evaluation A–D, the MSB bench scenarios). Read that payload in full —
this wrapper adds only what it can't know: current runtime-surface confirmations,
the RESEARCH_233 pivot-gate it must resolve, execution discipline, and the
landing lesson learned the hard way on RESEARCH_233.

## What this produces

One decision-grade memo, `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md`
(~500–900 lines), picking ONE primary approach (of A–D) for true multi-stream /
continuous batching on macprovider's MLX stack, with fallback, explicit no-go, MSB
bench scenarios, the integration touch-point map, and a 12-month milestone sketch.
**Research only — no runtime changes, no normative SPEC edits, no GitHub issues.**
The memo may *recommend* a follow-up SPEC/BUILD_SPEC; that is drafted separately later.

## Why this is the priority now

RESEARCH_224 pegged buyer USD to market price, so the only remaining *provider-earnings*
lever is per-machine aggregate throughput: earnings = per-token payout × sustained TPS.
Today providers do **parallel single-stream decode** (`AsyncSemaphore` + `--max-batch`),
not a shared per-step forward pass. True continuous batching is the main path to raise
aggregate TG without new hardware (oMLX claims up to ~4.14× at 8× concurrency —
treat as a hypothesis to replicate, not a fact).

## Grounding — the payload is dated 2026-07-09; here is what's still true (verified)

The payload's "concurrency today" background is **current** — confirm, don't re-derive:

1. **Runtime gate unchanged:** `ModelRuntime.swift` still gates with `AsyncSemaphore`
   sized by `maxBatch` (default 1) — see `inferenceGate` / `maxBatch` around
   lines 348–349, 401, 421–422. No `BatchGenerator`, no paged batch scheduler. ✓
2. **Engine pin:** `mlx-swift-lm` 3.31.4 (`phase3-binary/Package.swift` / `Package.resolved`).
   Re-confirm the pin before citing batch-API presence/absence; the Part-2.4 gap
   analysis (which mlx-lm batch primitives lack Swift ports) hinges on the exact tag.
3. **Slot policy is Entry 110 (2026-07-06), still live:** `max_concurrency_override`
   derived by chip class — M-base/M-Pro = 1, M-Max ≥48GB = 2, M-Ultra ≥96GB = 3,
   ≥128GB = 4; honored via `--max-batch`; coordinator learns it through heartbeat
   `slots_total`. Part-4 "compatibility with Entry 110 slot policy" and Part-5
   "batch depth → advertised slots" must map onto THESE numbers.
4. **Historical trap to state correctly:** an older DECISION_CRITERIA entry (2026-05-27,
   mlx-swift 2.29.1) recorded that concurrent inference *crashed the Metal command buffer*,
   forcing `max_concurrency = 1` across all tiers in v1. That is **v1 history, now
   superseded** by 3.31.4 + the Entry 110 multi-slot policy — the memo must NOT present
   "concurrency is impossible on Apple Silicon" as the current state. What's absent today
   is *continuous batching* (shared forward pass), not *parallel decode*.
5. **SPEC-028 speculative decoding exists** (v0.2-draft, greedy-gated, wired into the
   serve path). Part-2.5 (can draft-model spec-decode coexist with batching?) is a **live**
   design question, not hypothetical — answer it against the real SPEC-028 surface.

## The RESEARCH_233 pivot-gate — this memo MUST resolve it

RESEARCH_233 shipped (memo on `origin/main`, commit `d6881b14`,
`docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md`). Its recommendation is
Approach A (a KV disk-tier behind `ConversationCache`) **"persistence-first,
conditionally"** — with an explicit **pivot gate: batching/paged-KV goes FIRST if
contiguous KV restore proves layout-bound.** This memo is the other side of that gate.

**Required:** in Part 2 (KV cache layout — paging vs contiguous), state explicitly
whether the recommended batch scheduler *requires or forces a paged-KV layout* that
would constrain or invalidate RESEARCH_233's contiguous-block disk-tier design. Give a
clear verdict:
- **Independent:** 233's Approach A can be built on the current contiguous layout
  regardless of which batching approach lands → the two tracks proceed in parallel.
- **Layout-bound:** batching mandates paged KV → 233's disk-tier design must be authored
  against that paged layout, so **232 sequences before the 233 SPEC**.
Read the 233 memo's Part-5/Part-7 sequencing section before writing this — the two
verdicts must be reciprocal, not contradictory.

## Execution discipline (repo conventions — follow exactly)

- **Codex authors the memo, not a Claude subagent.** Prepare a grounded prompt (payload +
  a short grounding addendum with the five confirmations above + the 233 pivot-gate
  instruction), then invoke codex via the `/ask` skill (`omc ask codex`). Single call, or
  twice with different models to cross-check. Claude's role: ground, run codex, review, land.
- **Backtick shell-quoting trap:** the payload contains backticks and `$()`-shaped spans.
  Do NOT hand-assemble `omc ask codex "$(cat …)"`. Invoke via the `/ask` skill or pass a
  prompt-file path so backticks in the file aren't shell-evaluated.
- **Fresh worktree off `origin/main`**; never edit the canonical checkout (mid-merge —
  leave it alone). `git worktree add ../macprovider-232-batching-memo -b research/multistream-batching origin/main`
- **Memo goes in `docs/research/`; the payload prompt stays in `audits/_prompts/`**
  (a CI gate rejects research prompts outside `audits/_prompts/`). Do not move the payload.
- **Conservative > optimistic.** Flag every aspirational vendor throughput number
  (oMLX 4.14×, vllm-mlx claims) as unreplicated hypothesis; separate "what you verified"
  from "what the vendor claims" per the payload's Part-1 requirement.

## Landing — DIRECT-PUSH, do NOT open a PR (hard lesson from RESEARCH_233)

A standalone research-memo **PR cannot pass this repo's `spec-index` governance gate.**
That gate runs on every PR and requires a `SPEC-GOVERNANCE-DECLARATION` with
`behavior_change` ∈ {none, yes}: `none` is allowed **only** for governance-plumbing paths
(`specs/`, `schemas/spec-`, `beta/DECISION_CRITERIA.md`, `docs/spec-governance-foundation.md`,
etc.) — `docs/research/` is NOT on that allowlist — and `yes` requires specs + requirement
IDs + authority domains + a `CODE_BUG`/`SPEC_BUG` arbitration verdict a pure research memo
cannot honestly supply. RESEARCH_233 wasted a PR-open-then-close cycle on this.

Therefore: **land the memo by direct-push to `origin/main`**, the same way the run-wrapper
prompts landed. This is docs/non-money-path content, allowed by the ruleset admin bypass.
Do NOT fabricate a governance declaration to force a PR green. Concretely:
```
# in the memo worktree, memo committed:
git fetch origin && git rebase origin/main    # main moves fast; avoid non-ff reject
git push origin HEAD:main                       # docs/non-money-path direct push
```
If the direct push is classifier-blocked in your session (protected-branch guard), STOP
and hand the exact `git push origin HEAD:main` one-liner to the user — do not force, do not
fall back to a PR. After it lands: remove the worktree + branch.

## Execution order

1. **Preflight:** read the payload + `ModelRuntime.swift` (semaphore/maxBatch seam) +
   the SPEC-028 spec-decode surface + Entry 110 in `beta/DECISION_CRITERIA.md` + the
   RESEARCH_233 memo's sequencing section. Confirm the mlx-swift-lm pin.
2. **Ground:** write a grounding addendum (five confirmations + the 233 pivot-gate
   instruction) to prepend to the codex invocation.
3. **Run codex** (`/ask` skill) → memo draft.
4. **Review as Claude:** primary approach chosen with engineer-month + TG-multiplier +
   risk for all of A–D? MSB-01..05 defined with pass thresholds? Integration touch-point
   map present (Part 5)? **233 pivot-gate resolved with an explicit independent-vs-layout-bound
   verdict?** SPEC-028 coexistence answered? Vendor claims flagged as unreplicated? For any
   real gap, re-run codex on that gap — do not hand-write memo content.
5. **Land** by direct-push (above); clean up worktree/branch.

## Definition of done

- `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md` on `origin/main` (~500–900
  lines, exec summary ≤12 bullets) — landed by DIRECT-PUSH, no PR.
- ONE primary approach (A–D) + fallback + no-go, each with engineer-months / TG multiplier
  / risk / receipt-warm-swap-spec-decode impact / Entry 110 compatibility.
- MSB-01..05 bench scenarios with pass thresholds; Part-5 integration touch-point map;
  Part-6 12-month milestone sketch with go/no-go gates.
- **Explicit RESEARCH_233 pivot-gate verdict** (batching independent of, or layout-binding
  for, the 233 KV disk-tier), reciprocal with the 233 memo's sequencing call.
- Vendor throughput claims labeled unreplicated; authored via codex, not a Claude subagent;
  no PR opened, no GitHub issues filed.
