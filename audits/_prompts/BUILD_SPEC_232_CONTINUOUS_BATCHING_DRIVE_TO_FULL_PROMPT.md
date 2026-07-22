# BUILD_SPEC — RESEARCH_232 continuous batching → SPEC + IMPL to full

You are a senior protocol/systems engineer on the macprovider repo (P2P Mac LLM
inference marketplace). Drive RESEARCH_232's landed decision from memo to a
merged, LOCK-ready normative SPEC **and** its implementation. Work autonomously
to completion; never end on "proceed or hold" — default is full scope in priority
order. Make design calls, record them, keep going.

## 0. What you are building (self-contained)

**Goal:** raise provider throughput (and thus earnings) by moving from today's
**parallel single-stream decode** to **continuous batching** — active decode rows
share one model forward and join/leave dynamically.

**Source of truth:** `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md`
(landed, commit `8d80f6c4`). Read it fully first. The decision is made — do not
re-open it; implement it.

**Current state:** `maxBatch` sizes an `AsyncSemaphore`; each permit runs an
independent `TokenIterator` (parallel single-stream, not continuous batching).
Entry 110 already ships parallel slots by machine class (M-Max ≥48 GB → 2,
M-Ultra ≥96 GB → 3, ≥128 GB → 4).

**Chosen approach — Approach A:** contribute, review, and pin an **upstream
`mlx-swift-lm` batch API** behind a macprovider feature flag, modeled on Python
`mlx-lm`'s proven `BatchGenerator` architecture (dense, contiguous, batch-aware
KV caches — **not** vLLM PagedAttention; no shared paged allocator required). The
relevant upstream WIP is PR #263 (unmerged; incomplete for quantized KV,
spec-decode, some cache subclasses). **Fallback — Approach B:** a narrow
macprovider-owned native Swift batch scheduler, only if the upstream path misses
the Q3 2026 calendar or a correctness gate; keep it close to upstream semantics.
**No-go:** Approach C sidecar and Approach D runtime swap (C stays a benchmark
oracle only, not production).

### Hard constraints the SPEC and IMPL MUST honor (from the memo — the 10-point contract)

1. FCFS admission with bounded queues.
2. Separate prompt-processing and decode batches.
3. One shared forward for active decode rows.
4. Dense, contiguous, batch-aware KV caches.
5. Dynamic insertion/removal between decode steps.
6. **Per-request** sampling, stop, cancellation, usage, and **receipt** state —
   correctness under a shared forward is the load-bearing invariant.
7. Single-owner **actor isolation** around mutable generator state.
8. Explicit rejection of unsupported cache types or `kv_bits` modes.
9. A serial fallback path **identical to today's behavior** (feature-flag off).
10. Version-pin to a reviewed upstream tag/revision.

Also normative: **SPEC-028 speculative decoding stays single-slot and mutually
exclusive with batching in the first release** (combined spec-batching deferred).
Reciprocal to RESEARCH_233 the verdict is **INDEPENDENT** — the contiguous-cache
scheduler needs no paged allocator, so 232 and 233 proceed in parallel.

**Throughput honesty:** every advertised multiplier (oMLX, vllm-mlx, Higgs, LM
Studio, llama.cpp) is an **unreplicated hypothesis** on macprovider hardware.
Gate any throughput claim behind replicating MSB-01–05 on real catalog models;
do not ship a number you haven't measured.

## 1. House rules — non-negotiable

- **Fresh worktree off `origin/main`** (`git worktree add ../macprovider-232 -b spec/232-continuous-batching origin/main`); never edit the canonical checkout.
- **Number reservation:** claim **SPEC-038** (SPEC-036 in flight; SPEC-037
  reserved for RESEARCH_233 running in parallel — do NOT take it). Verify at
  runtime and bump to next free only if 038 is taken, avoiding the 233 session's
  number.
- **Sensitive path → PR, not direct push.** Batching changes per-request usage
  accounting under a shared forward → receipt/usage adjacency + provider earnings.
  Full **three-lane codex audit** (code / security / architect) via `omc ask
  codex`, bar **0 C/H/M**, for SPEC and IMPL. Lane prompts under
  `audits/<YYYY-MM-DD>/` (never `specs/` — CI gate). LOW ships documented. Don't
  re-fire a passed lane.
- **Git identity is automatic** (`git push` routes to `Augustas11`). Merge:
  `antfleet-ops` approves → `Augustas11` squash-merges. Re-approve if a
  post-approval push dismisses it. Classifier may block review/merge — surface the
  exact commands for the user.
- **Governance:** `SPEC-GOVERNANCE-DECLARATION` (`spec-pr-governance-v1`) against
  `specs/CONFORMANCE.json` / `specs/AUTHORITY.json`; body edits don't re-trigger
  `check`; verify latest run per context.
- **Decision log:** append to `beta/DECISION_CRITERIA.md` (latest 180), merged
  **last**, reflecting shipped state.
- **No GitHub issues from audit findings.** Verify commit content before push.
  Backtick-heavy prompts → file + `cat`.
- **Upstream contribution note:** Approach A involves upstream `mlx-swift-lm`
  work. Do the upstream PR/review as its own track; the macprovider SPEC pins a
  reviewed revision behind the flag and does not block on merge — the fallback-B
  gate exists precisely for the calendar/correctness miss.

## 2. Phases

- **A — SPEC.** Write `specs/SPEC-038-continuous-batching.md`: the batch-serving
  architecture (the 10-point contract), the feature-flag + serial-identical
  fallback, the actor-isolation model, the explicit unsupported-cache/`kv_bits`
  rejection, the spec-decode mutual-exclusion, the version-pin policy, and the
  MSB-01–05 throughput-replication gate. Acceptance Criteria as fixtures
  (per-request usage/stop/cancel correctness under shared forward; join/leave
  mid-decode; serial-fallback parity; rejection paths).
- **B — SPEC audit loop** to 0 C/H/M (3 lanes); open + merge SPEC PR via governance.
- **C — IMPL.** Land the batch scheduler in `phase3-binary/` behind the flag
  (pinned upstream batch API or the Approach-B scheduler if the gate slipped),
  with per-request usage/receipt correctness, actor isolation, bounded FCFS
  queues, dynamic insert/remove, unsupported-mode rejection, and the
  serial-identical fallback. Replicate MSB-01–05; build + test green.
- **D — BUILD audit loop** to 0 C/H/M (3 lanes; correctness lane weighted on
  per-request usage/receipt isolation under the shared forward, and on the
  serial-fallback parity). Open + merge IMPL PR.
- **E — Decision-log entry** merged last; close-out with links, audit convergence,
  measured MSB-01–05 throughput vs the serial baseline, and residuals. No open loops.

## 3. Definition of done
- [ ] SPEC-038 written (Approach A, 10-point contract), spec-decode mutual-exclusion + MSB gate normative; SPEC audit 0 C/H/M; SPEC PR merged via governance gate.
- [ ] IMPL behind feature flag with **serial fallback identical to today**; per-request sampling/stop/cancel/usage/receipt correct under one shared forward; actor-isolated; unsupported cache/`kv_bits` rejected; version-pinned.
- [ ] MSB-01–05 replicated on real catalog models; throughput claim is measured, not borrowed; no throughput number shipped that wasn't measured.
- [ ] Independence from RESEARCH_233 preserved (no shared paged allocator introduced).
- [ ] BUILD audit 0 C/H/M; IMPL PR merged; decision-log entry merged last; worktree/branch cleaned; user briefed.
