# Handoff: #1770 native MTP (paused 2026-10-02)

You are resuming the native MTP track for Qwen3.5/3.6. The operator paused it on 2026-10-02 after the formal R015 run. Read these first:
- `AGENTS.md`;
- this file;
- the body of draft PR #1832, especially its "Resume here" checklist;
- `specs/SPEC-048-*.md` (native MTP serving) and SPEC-023 R024.

Native MTP is merged and **default-off**. Nothing is signed or activated.

## State

| Item | Where | Status |
| --- | --- | --- |
| Runtime: batched, load-gated native MTP | PR #1820, merged `b29b7b8f5` | On main, default-off. Fork pin `Augustas11/mlx-swift-lm` `ef4ff856`. |
| CB per-step streaming | PR #1828, merged `f096d7320` | On main. Non-hybrid CB no longer streams in 16-token bursts. |
| Formal R015 + unsigned sidecar + journey | **Draft PR #1832**, branch `campaign/native-mtp-formal`, head `bd8200db5` | R015 PASS; journey blocked at step-07; not merge-ready |
| Fused MoE kernels for A3B | Draft PR #1829, branch `lab/a3b-fused-moe`; fork draft `Augustas11/mlx-swift-lm#2`, branch `perf/a3b-fused-moe` `d9df6aa` | Lab result; not productized |
| Negative-result kernel labs | Branches `lab/qmv-smallm`, `lab/moe-smallm`, `lab/mtp-verify-profile`, `lab/mtp-mlx-0323` (pushed, no worktrees) | Reference only |

Do **not** rebase `campaign/native-mtp-formal`. Its frozen R015 policy, sha256 `30934c07e5b6ca6dfa569505bbfdb2fd118be719cba81ddf99193a4ebe72d581`, binds provider commit `cb708b58c`. Any code change requires a new policy freeze and a new R015 run.

## Measured facts (M3 Ultra 256 GB Mac Studio)

**First tuple:** Qwen3.6-35B-A3B 4-bit (`3fed776d…`) with the MTP-4bit drafter. `max_native_active_rows` = 1, `max_prompt_tokens` = 4096, `qualified_slots` = 8.
- **Formal R015 (stock kernels).** At 1 slot, decode is 1.22–1.28× ordinary (Holm lower bound 0.20–0.26). The gated s2 and s8 cells are non-inferior (TTFT upper bound ≤ 0.03). The 1800 s sustained window passes. Parity, fallback and error counts are 0.
- **Native MTP wins only at 1 active row.** The limit is MLX small-M quantized matmul plus A3B MoE launch latency. At 2 slots the gain was 1.09–1.13×, below the 0.15 bar. Bound 2 failed gated TTFT by +7.8%.
- **Fused MoE (#1829) speeds up ordinary A3B decode at 1 slot by +40%** (101 → 142 tok/s in decode-bench). On that faster baseline, native MTP's lead is only about **+14% at 1 slot** and +8% at 2, and it turns slightly negative from 4 slots. It would likely fail the 0.15 lower-bound gate there.
- **27B dense:** 1.23–1.34× at 1 slot. Not a priority, since A3B is the main model.

## Blockers and next actions, in order

1. **Decide the baseline before any signing.** If fused MoE ships (#1829 production slice: fork reduction, pin + `Package.resolved` + `KVBuildIdentity` bump, SPEC note on bf16 near-tie logit changes), re-derive the A3B tuple on it. That means re-running the reduced R015 matrix of about 1 hour. If MTP misses 0.15 there, the tuple does not ship. Do not sign a tuple measured on stock kernels while fused kernels are headed to main.
2. **Journey step-07/08 (mixed 8-row batch).** Ordinary CB greedy output depends on arrival timing (SPEC-048 §6 batched numerics), so an exact native-vs-ordinary oracle is invalid. The fix is either deterministic batch composition in the harness or a kernel-matched oracle. Other open journey steps:
   - step-06: the EOS case never reached EOS;
   - step-05: state digest;
   - step-09: boundary cancellations;
   - warm swap, accounting, and the coordinator SPEC-031-R033 canary (isolated loopback);
   - redaction.
3. **R015 gaps:** the post-gateway eligibility replay (at least 10% of requests and completion tokens eligible), and lower-RAM tiers if any are advertised.
4. **Operator signing.** Agents never sign. The exact commands are in the PR #1832 body: the R024 sidecar via `scripts/native_mtp_admission_sidecar.py` plus the static-feed key, the challenge bank, and JOURNEY-NATIVE-MTP-SERVING / -RELEASE.
5. **Release and activation:** one signed CLI cut, then R014 isolated-loopback revalidation, then controlled activation.
6. **Audit carry.** On #1832 the architecture lane's round-4 Medium and all round-4 Lows were fixed in `bd8200db5` but not re-audited (cap reached). At the next freeze, re-run only that lane.

## Studio (`ssh macstudio`, user `a1`)

- **Lab lock:** before pausing live, run `mkdir ~/.lab-window.lock`. If it already exists, another session holds the Studio, so wait. Remove it after live is resumed and `Provider is ready`. On 10-01 a check-then-launch race and a foreign session breaking the lock each voided a window.
- **Live:** `~/macprovider/macprovider-cli serve` (v1.8.207, LaunchAgent `live.malibu.provider`). Pause it only for lab windows, then restore it and confirm the Pearl buyer-runner is active.
- **Kept for resume:**
  - `~/macprovider-mtp-formal` (build tree);
  - `~/macprovider-mtp-r015`;
  - `~/mtp-r015-a3b-formal-v2` (formal run records; S01 contaminated records are in `contaminated/`);
  - `~/mtp-journey-a3b`;
  - `~/mtp-r015-*` (exploratory runs);
  - `~/lab-cb-sampling`;
  - `~/.cache/macprovider-mtp-e2e` (fixture artifacts);
  - `~/a3b-fused-lab` (fused MoE raw logs `w4..w7`).
  Everything else stale was deleted on 2026-10-02.

## Working rules the operator set for this track

- **Agent roles:** opus subagents write code, sonnet subagents research and verify, and Codex is used only for the three-lane audits.
- **Audits:** three lanes (code, security, architecture), gate 0 Critical / 0 High / 0 Medium, cap 3–4 rounds. Re-run only the lanes that reported findings; a clean lane stays accepted.
- **Benchmarks:** run the reduced matrix and measure first. Change the spec afterwards. No multi-day benchmark matrices and no redesign theatrics.
- **Hardware campaigns:** one draft PR per campaign, audited once at freeze.
- **Merges:** PR reviews come from the `antfleet-ops` account. The operator runs the approval themselves with `! GH_TOKEN=$(gh auth token -u antfleet-ops) gh pr review <N> --approve`, because auto mode denies self-approval.
- **R015 throughput is decode-only.** TTFT is excluded from the throughput gate and gated separately.
- **Do not re-try deferred drafter seeding.** It regressed A3B 8192 decode from 1.14 to 1.02 and was reverted in `f8a3087b5`.
