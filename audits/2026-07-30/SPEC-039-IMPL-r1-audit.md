# SPEC-039 paged-KV engine IMPL — audit record (r1)

Date: 2026-07-30
Branch: `impl/039-paged-engine` (rebased on `origin/main` @ a6d6a4a6)
Scope: full combined IMPL diff as it lands (foundation + parity core), reviewed as one whole.

## Lanes run
Five independent lanes on the full combined working-tree diff:
- Codex code / security / architect (`omc ask codex`, gpt-5.5, reasoning=high). Raw transcripts under `.omc/artifacts/ask/` and `audits/2026-07-30/RESULT-codex-*.log` (untracked).
- Claude adversarial verificator (code-reviewer, opus) and product/release critic (critic, opus).

## Verdict: 0 real CRITICAL / 0 real HIGH
Every HIGH raised by the three codex lanes and the product critic's C1/H1 was a **stale-base artifact**, not an IMPL change: the branch was based on `a1bdab03`; `origin/main` had advanced 2 commits (`a6d6a4a6` bump to 1.8.67, `d55cd650` installer retry-dead-end fix) touching `install.sh`, `CoordinatorClient.swift`, and the upgrade tests. The audit snapshot diffed against the newer main, so main's own advances appeared as "reverts." Verified directly: `git diff HEAD` for those paths was empty — the IMPL never touched them. **Resolved by rebasing onto `origin/main`** (binaryVersion back to 1.8.67, install.sh guard restored). The adversarial verificator independently diagnosed the same stale-base cause and hand-traced the gather round-trip to confirm losslessness.

Overclaim check (codex-architect + verificator): **clean** — no code/decision-log claim of runtime enablement, packaged metallib (AC-9), servability sizing (AC-16), or GPU-pool-resident serving. DECISION Entry 213 lists these as deferred.

## Real findings and dispositions
| Lane | Sev | Finding | Disposition |
|---|---|---|---|
| code | MEDIUM | Parity assertion only `>0` / `>=2` blocks | FIXED: exact `gatherKernelCalls == nLayers*nNew*2`, `maxLogicalBlocks >= 3` |
| security | MEDIUM | Metal seam unguarded; `precondition`/`fatalError` crash paths | FIXED (Swift side): overflow-checked arithmetic, pre-launch rank/dim/range validation, crash paths → controlled guard-and-return. Kernel-side (Metal) bounds guards documented as a REQUIRED before-runtime-enable gate item (seam is inert this merge). |
| architect | MEDIUM | FR-PKV10 surface is byte materialization, not a standalone `KVCache` handoff | FIXED (honest scoping): doc'd as neutral byte extraction only; standalone contiguous `KVCache` handoff deferred to the runtime bridge (FR-PKV10 not yet a complete extraction contract). |
| verificator | LOW | `paged_kv` YAML shape-error suppressed under env/CLI override | FIXED: always surfaces + disables paged mode. |
| verificator | LOW | Parity evidence not CI-enforced | Carried: parity is a hardware-capability run; AC-1 log attached to PR. |

## Post-fix validation
- Focused suite: `swift test --filter PagedKV/Config/ServingKnobs/PagedKVEngine` → 168 executed, 0 failures, 3 skipped (env-gated real-model parity). One test (`ServingKnobsConfigTests`) rewritten to assert the new fail-closed YAML semantics.
- AC-1 dense parity re-run under the strengthened exact assertion:
  `[AC-1] Llama-3.2-3B-Instruct-4bit: PARITY PASS 40/40 tokens; gatherKernelCalls=2240; maxLogicalBlocks=4; nonIdentityPermutation=true`
- `git diff --check` clean.

## Carried before-runtime-enable gate items (not merge blockers; feature is default-off/inert)
1. Kernel-side (Metal) bounds guards on `block_ids`/`physical` indexing before `engineBridgeAvailable` is flipped.
2. AC-3 MoE parity run on a headroom (>32 GB, prod-drained) machine — fixture authored + env-gated; spike-proven.
3. AC-9 packaged-metallib Metal execution; AC-16 servability/sizing table; GPU-pool-resident serving (the real request bridge, incl. the full FR-PKV10 KVCache handoff).
