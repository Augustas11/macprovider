# RESEARCH_SWEEP_WORKLOAD_CLASS_PROMPT

**Purpose:** research + SPEC-drafting prompt for extending the context×concurrency
sweep search space to a third axis — **workload class** — so autotune produces
per-class winners rather than one compromise config across all traffic shapes.

**Status:** research-round, pre-SPEC.

**Author:** drafted 2026-07-05 by Claude Opus 4.7 session (opus-4-7).

**Why it matters now.** SPEC-028 (speculative decoding, v0.2 audited on `origin/main`
at `a1be007`) is landing chain speculative on the provider serve path. Draft-token
acceptance rate is workload-dependent: shard's 2026-07-03 report shows +49% on
reasoning cells vs. chain-wins on code/RAG/long-ctx. Without a class-aware sweep,
SPEC-028 ships with a single `--num-draft-tokens N` chosen as a compromise across
workloads — leaving materially throughput on the table on the classes it under-fits.
**This SPEC is the multiplier that makes SPEC-028 land at full strength.**

**Verified state (2026-07-05).**
- `beta/workloads.py` has 6 named classes (`short_chat, medium_with_system, long_context, code_completion, agent_style, streaming_check`) with a `_WORKLOAD_CORPUS_MAP` category mapping.
- `beta/report.py::summarize_per_workload` groups results per class.
- `beta/DECISION_CRITERIA.md` §B/§C explicitly requires per-workload metrics ("Median tok/s per workload", "Stop-token leak rate per workload").
- **But the sweep grid** (per `.omc/logs/context-throughput-sweep-impl-notes.md`) **is 7 contexts × 4 concurrency = 28 cells — shape-only, class-blind.** Buyer-harness stratifies output; knob-search doesn't.

---

# Codex session: research + SPEC workload-class sweep for macprovider-poc

## Context

The buyer harness reports per-workload; the sweep search space does not. This SPEC extends the sweep to `(context × concurrency × workload_class)` (or a class-filter over the existing grid — decide which) so autotune produces per-class knob winners publishable to `phase3-binary/dist/static/autotune-candidates.json` (or a class-partitioned sibling).

## Scope — hard limits

- **Read-only research + SPEC drafting.** No code changes to sweep, harness, autotune, or `autotune-candidates.json`. No PRs against `origin/main`.
- Do **not** modify SPEC-013 (CLI autotune, LOCK candidate) or SPEC-028 (speculative decoding) — this SPEC is a companion, not a modification.

## Read first

1. `CLAUDE.md`, `AGENTS.md`, `HANDOFF.md`.
2. `beta/workloads.py`, `beta/report.py::summarize_per_workload`, `beta/DECISION_CRITERIA.md`.
3. `.omc/logs/context-throughput-sweep-impl-notes.md` (28-cell grid rationale).
4. `beta/sweep.py` on branch `spike/context-throughput-sweep`.
5. `specs/SPEC-013-*` (CLI autotune) — where the new axis surfaces to operators.
6. `specs/SPEC-028-*` (speculative decoding) — the drafter's `num_draft_tokens` axis interacts with class; sweep must accommodate both.
7. `phase3-binary/dist/static/autotune-candidates.json` — the ship surface.

## Questions to answer (cite files:lines)

### A. Search-space shape
- Class as a third grid dimension (28 × K cells) vs. class as a filter over the existing grid (K parallel 28-cell sweeps): which is correct? Cite runtime cost, storage impact on `runs.sqlite`.
- Which of the 6 workload classes belongs in the sweep? Are any (e.g., `streaming_check`) infrastructure-shape rather than content-shape and should be excluded?

### B. Winner-picking under SPEC-028
- With chain spec-decode, a knob winner is a tuple `(kv_bits, max_context, max_batch, num_draft_tokens)`. Is `num_draft_tokens` per-class or shared across classes? Cite tradeoff.
- How does per-class tie-breaking work when two classes want conflicting knobs? Which class dominates? (Suggested: buyer-weighted, per the observed traffic mix in `runs.sqlite`.)

### C. Autotune-candidates.json shape
- Extend the existing schema with a `per_class` map, or ship a sibling file (`autotune-candidates-per-class.json`) with the class dimension? Backward-compat with existing autotune-recommend consumers?
- Static-sign implications (`phase3-binary/dist/static/keys/autotune-static-v3.public.base64`): does the class-partitioned candidate set need a new key, or can it reuse v3?

### D. Runtime routing
- When a buyer request lands, how does the provider (or coordinator) classify it into a workload class at request-time? The classes exist in `workloads.py` for corpus sampling; is there a request-time classifier, or would this SPEC introduce one?
- If a classifier is needed: does it live in the provider (fast, potentially gameable) or the coordinator (adds RTT)? Which is right?
- If class routing turns out to require a new classifier component: **that is out of scope for this SPEC** — restrict this SPEC to producing per-class winners as data. A follow-up SPEC handles serving them.

### E. Interaction with existing sweep artifacts
- `.omc/logs/context-throughput-sweep-impl-notes.md` documents 28-cell design decisions (feasible gate at `n_err == 0`, `ttft_p95_ms <= 8000`, no `stop_token_leak`). Do these gates need to be class-parameterized? (e.g., long-context class may need a higher TTFT gate.)
- Do the existing sweep reports (`beta/reports/sweep-*.html`) need re-generation with class stratification, or can they stay as-is with new class-aware reports alongside?

## Deliverables

Branch `research/sweep-workload-class` off `origin/main`, three artifacts:

1. **`docs/research/sweep-workload-class-2026-07.md`** — research memo answering §A–E with citations.
2. **`specs/SPEC-XXX-sweep-workload-class-stratification.md`** v0.1-draft — normative FRs, non-goals, open questions, acceptance criteria.
3. **`.omc/logs/sweep-workload-class-open-questions-2026-07.md`** — maintainer-input list.

## Definition of done (this research session)

- Every §A–E question answered with a code citation.
- SPEC draft passes self-review round.
- Open questions list ≤5 items, all genuinely blocked on human decision.
- No code changes. No PR beyond this branch.

## Do NOT

- Modify sweep code, harness, autotune, or `autotune-candidates.json`.
- Introduce a request-time workload classifier in this SPEC — call the seam, defer.
- Modify SPEC-013 or SPEC-028.
