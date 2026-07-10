# RESEARCH_CPU_TIME_INSTRUMENTATION_PROMPT

**Purpose:** research + SPEC-drafting prompt for adding per-request CPU-time
instrumentation to the buyer harness DB, so future sweeps can distinguish
CPU-bound vs. GPU-bound stage time on Apple Silicon.

**Status:** research-round, pre-SPEC.

**Author:** drafted 2026-07-05 by Claude Opus 4.7 session (opus-4-7).

**Why it matters now.** SPEC-028 (speculative decoding, v0.2 on `origin/main` at
`a1be007`) adds CPU work per verify round (drafter forward pass, acceptance
sampling). Without CPU-time instrumentation, the next sweep re-run under
SPEC-028 will produce winner knobs that are uninterpretable — you won't be able
to tell whether a knob's win came from better compute utilization or from
adjacent unrelated variance. **Ship this before or in the same cycle as the
class-aware sweep to keep future perf work honest.**

Also opens a first-principle positioning claim: shard's 2026-07-03 report argues
consumer-hardware fleets are CPU-bound. If that generalizes to Apple Silicon
(plausible given unified memory + strong CPU cores), it's a defensible marketing
claim — but only if measured.

**Verified state (2026-07-05).** `grep -rEln "cpu.time|cpu_time|cpu.util|gpu.util|stage.timing|per.stage.timing"` returns one spec-doc hit and zero code hits. No instrumentation today.

---

# Codex session: research + SPEC per-request CPU-time instrumentation

## Context

Add per-request CPU-time measurement to the buyer harness, persist as a new column in `beta/runs.sqlite`, surface in `beta/report.py` as a CPU-vs-wall ratio per workload class per hardware target. Not a perf win on its own — a diagnostic gate that makes every future perf decision correctly-informed.

## Scope — hard limits

- **Read-only research + SPEC drafting.** No code changes to harness, sweep, or DB schema. No PRs against `origin/main`.
- Do NOT scope any perf action based on projected findings. This SPEC is measurement-only.

## Read first

1. `CLAUDE.md`, `AGENTS.md`, `HANDOFF.md`.
2. `beta/harness.py` — where per-request rows are written.
3. `beta/runs.sqlite` schema — probe with `.schema` (do not modify).
4. `beta/report.py` — how per-workload aggregation surfaces today.
5. `beta/config-m1.yaml`, `beta/config-m4.yaml` — the hardware targets the sweep runs against.
6. `specs/SPEC-028-*` (speculative decoding) — the specific reason CPU-time visibility matters now.
7. Any prior `.omc/logs/*context-throughput*` notes referencing thermal or CPU load.

## Questions to answer (cite files:lines)

### A. Measurement mechanism
- On Apple Silicon (M1/M2/M3/M4), what is the correct measurement primitive for **per-process CPU time consumed for this request**? Options: `psutil.Process().cpu_times()` deltas, `os.times()`, `resource.getrusage(RUSAGE_THREAD)`, macOS `task_info`. Cite tradeoffs — accuracy, thread-attribution correctness, overhead.
- Wall time vs. CPU time on a unified-memory chip: what does "GPU-bound" mean here empirically? Apple Silicon has no discrete GPU-side accounting; MLX runs on the same package. Propose an operational definition — e.g., `cpu_time / wall_time < X → GPU-bound`; `> Y → CPU-bound`; `X..Y → mixed`.
- If MLX exposes any GPU-side timing (Metal command buffer timestamps), can the harness read it? Cite mlx-python API surface.

### B. Schema change
- New column(s) in the `runs` table (name, type, nullable, default). Propose exact SQL.
- Backfill semantics: existing rows have no CPU-time value. Should reports treat NULL as "unknown" or "not measured"? Cite.
- Migration path: additive schema change, no destructive migration. Verify against `beta/harness.py::__init__` and any existing migration.

### C. Harness integration
- Where in `beta/harness.py` does the request loop live? Cite exact function.
- The measurement must bracket the actual model-forward-pass work, not the SSE decode loop or the network wait. Propose the bracketing points.
- Overhead budget: the probe must add <1% wall time. Show measurement-of-the-measurement plan.

### D. Report surface
- `beta/report.py::summarize_per_workload` — how does the new CPU-share metric surface? Suggested: `cpu_share_median, cpu_share_p95` per workload class.
- Does the existing HTML report template need extension, or a sibling class-report file?
- What decision-support text belongs in DECISION_CRITERIA.md if the answer comes out CPU-bound? (Draft a stub — actual criteria update is a follow-up.)

### E. Cross-run reproducibility
- CPU-time measurement is thermal-dependent. Two identical sweeps at different thermal states produce different absolute CPU times. Propose normalization or protocol (e.g., "3 runs, take median; annotate cold vs. warm start").
- Interaction with SPEC-028: chain spec-decode adds CPU per verify. Should the CPU-share metric split "target CPU" vs. "draft CPU" when spec-decode is on? Deferred to a v0.2 or in scope? Suggest scope.

### F. Publishing the finding
- Is `cpu_share` publishable in the buyer-facing docs, or is it internal-only? Cite.
- If publishable: does it live in a receipt (SPEC-015 v0.4 usage field extension) or in fleet-wide telemetry? Same decision surface as SPEC-028's acceptance-rate visibility question.

## Deliverables

Branch `research/cpu-time-instrumentation` off `origin/main`, three artifacts:

1. **`docs/research/cpu-time-instrumentation-2026-07.md`** — research memo answering §A–F with citations.
2. **`specs/SPEC-XXX-cpu-time-instrumentation.md`** v0.1-draft — normative FRs (schema change, measurement protocol), non-goals, open questions, acceptance criteria.
3. **`.omc/logs/cpu-time-instrumentation-open-questions-2026-07.md`** — maintainer-input list.

## Definition of done (this research session)

- Every §A–F question answered with a code citation.
- Concrete SQL migration proposed.
- Overhead budget quantified.
- Reproducibility protocol proposed.
- SPEC draft passes self-review round.
- No code changes.

## Do NOT

- Modify `beta/runs.sqlite` schema or `beta/harness.py`.
- Introduce dependencies on Xcode/Metal instrumentation frameworks that would break Air-only providers.
- Assume the outcome — do not pre-write "CPU-bound on Apple Silicon confirmed" text.
