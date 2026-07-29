# AUTHOR SPEC-038 v0.2 — Continuous batching, reframed to a locally-owned paged engine

**For a fresh codex session.** Rewrite `specs/SPEC-038-continuous-batching.md` from **v0.1 (SUPERSEDED)** to **v0.2**, then drive it through the three-lane codex SPEC-audit to 0 C/H/M and open the PR. **SPEC only — no IMPL.** This is a **targeted reframe, not a from-scratch rewrite**: keep the surviving serving-safety half, delete the dead upstream-pin spine, and re-anchor the engine on the locally-owned paged engine (SPEC-039).

## Why v0.2 (self-contained)
SPEC-038 v0.1 was written on the original RESEARCH_232 memo's **falsified** framing: **Approach-A "pin a reviewed upstream `mlx-swift-lm` batch API"** (FR-CB10) + dense/contiguous KV. Verified this session:
- **Upstream will never deliver that API** — PR #263 is abandoned; its author (Layr-Labs) moved to a private paged fork. So FR-CB10's activation theory is permanently unsatisfiable.
- **The engine is paged and built in-house**, proven additively feasible with NO fork across dense + the live MoE model (spikes `e5ded571`, `acc30b1e`, `da21af53`; see `docs/research/SPIKE_PAGED_ATTN_PHASE*_RESULT_2026-07-29.md` and `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md`).

## What SURVIVES from v0.1 (keep, reaffirm — it passed a money-path three-lane audit)
The whole serving-safety / correctness layer is architecture-invariant — keep it:
- Feature-flag + **serial-fallback-identical** when off (default-OFF = today's behavior).
- **Per-request sampling/stop/cancel/usage/receipt isolation under a shared forward** (the money-path invariant).
- Single-owner **actor isolation** around mutable generator state.
- FCFS admission + bounded queues.
- Explicit rejection of unsupported cache/`kv_bits` modes.
- **SPEC-028 spec-decode mutual exclusion** in v1.
- The **MSB throughput-replication gate** (no unmeasured throughput claim ships).
- The telemetry/observability contract.
- The governance domain `continuous-batching-serving` + requirement scaffolding (renumber/extend as needed).

## What to DELETE (dead)
- **FR-CB10** "pin a reviewed upstream `mlx-swift-lm` batch API" and the entire version-pin / Approach-A-primary spine.
- The **dense-contiguous-KV** assumption ("does not mandate a paged allocator") — the engine is now paged.

## What to ADD / REFRAME
1. **Activation authority → locally-owned capability.** Replace the upstream-revision gate with: batching activates only when a **locally-owned batching engine capability exists** (the scheduler + the SPEC-039 paged engine). The `on` state fails closed with a reason that references the local capability, not an upstream pin. (PR #804's scaffold maps here — its guards/telemetry/flag survive; its `reviewedUpstreamBatchRevision` gate is replaced.)
2. **Depend on SPEC-039** (paged KV / paged-attention engine). SPEC-038 is the **scheduler / serving layer**; SPEC-039 is the **engine it consumes**. Define the boundary: the scheduler owns admission, preemption, and **per-request block tables**; SPEC-039 owns the paged KV storage + attention kernel. Do NOT redefine the paged engine here — reference SPEC-039.
3. **MoE expert-dispatch note.** Attention paging is orthogonal to MoE (proven), but a *continuous-batching* scheduler must handle **expert dispatch across batched sequences** for MoE models (per-token expert selection / load-balancing under batching). Record this as a scheduler concern (the live model `Qwen3-Coder-30B-A3B` is MoE).
4. **Scheduler normative surface** (the dominant remaining engineering piece): batched decode loop, per-request block-table management (over SPEC-039 blocks), admission/preemption, dynamic insert/remove between decode steps, per-request usage/receipt bookkeeping under the shared forward, and the serial-identical fallback.

## Acceptance criteria (as fixtures)
Keep v0.1's surviving criteria (per-request usage/stop/cancel correctness under shared forward; serial-fallback parity; unsupported-mode rejection). Add: activation gated on the local capability (not an upstream pin); scheduler admission/preemption correctness; MoE-batched expert-dispatch correctness placeholder; and the SPEC-039 dependency boundary.

## House rules
- **Fresh worktree off `origin/main`** (`git worktree add ../macprovider-spec038v2 -b spec/038-v0.2-reframe origin/main`); never the canonical checkout.
- **Same file** `specs/SPEC-038-continuous-batching.md`, bump `Version: v0.2`, remove the SUPERSEDED banner (v0.2 IS the current version), update `Decision source` to cite the addendum + the three spike results alongside the original memo.
- **Governance:** update the `SPEC-GOVERNANCE-DECLARATION` + `specs/CONFORMANCE.json` / `AUTHORITY.json` for the v0.2 requirement set (domain `continuous-batching-serving` stays; add a `depends`/reference to SPEC-039's domain). `spec-index/check` advisory; merge gate `ci-required` + 1 approval.
- **Three-lane codex SPEC-audit** (code/security/architect) to **0 C/H/M** — **money-path weighting** (per-request usage/receipt isolation under the shared forward is the load-bearing invariant). Lane prompts under `audits/2026-07-29/` (never `specs/`); findings in `specs/SPEC-038-v0_2-rN-audit.md`.
- **Merge:** author `Augustas11`; `antfleet-ops` approves; `Augustas11` squash-merges `--admin`. Classifier may gate — surface the commands.
- **Sequencing vs SPEC-039:** SPEC-038 v0.2 **references SPEC-039 by number** (039, verified free). If SPEC-039 hasn't merged yet, still reference it (a forward reference to a companion spec is fine); do not inline its content. Keep the two specs' boundary clean so they compose.
- **Decision-log:** leave `beta/DECISION_CRITERIA.md` for the IMPL.
- **Clean-room:** public sources only; **NEVER** `Layr-Labs/*` / `d-inference`.

## Definition of done
SPEC-038 bumped to v0.2: surviving serving-safety half kept, upstream-pin spine deleted, activation reframed to locally-owned capability, SPEC-039 dependency + boundary defined, MoE scheduler concern recorded; SUPERSEDED banner removed; three-lane audit 0 C/H/M (money-path weighted); governance-declared PR merged via `ci-required`. **No IMPL.** #804's scaffold reframe (activation gate) can follow as an IMPL-side change; do not modify #804 in this SPEC PR.
