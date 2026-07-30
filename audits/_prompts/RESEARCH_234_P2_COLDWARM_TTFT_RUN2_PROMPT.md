# RESEARCH_234 RUN 2 — Complete the cold/warm TTFT matrix + calibration (campaign-first)

**Carry this in a fresh session.** Self-contained; assumes no memory of the P1/P2 sessions.
This is the SECOND attempt at RESEARCH_234. Run 1 built the instrument but never ran the
campaign, and both landing PRs died. Read the "Run-1 failure modes" section before doing
anything — every rule in it is paid-for.

## What already exists (do not rebuild)

- **The harness is built and 3×-approved.** It lives on branch
  `test/526-coldwarm-ttft-reland` under `test/e2e/coldwarm-ttft/`
  (`coldwarm-probe.mjs`, `cold-cycle.sh`, `mock-gateway.mjs`, `run-coldwarm.sh`,
  `CALIBRATION.md`, `README.md`, systemd/launchd units). Retained worktree:
  `/Users/augstar/macprovider-526-coldwarm-ttft`. Check `git status` there before
  reusing — do not clobber uncommitted state.
- **PR history:** #526 (original) closed stale — 3 ahead / **169 behind**, red CI.
  #668 (reland) closed **parked, not rejected**: 3 approvals from antfleet-ops, blocked
  by `phase3-binary (swift test)` → `ci-required` red, and parked because "merging the
  instrument does not close the calibration work." The parking comment says:
  *reopen/rebase #668's branch when ready — do NOT create a third parallel branch/PR.*
- **Background spec:** `audits/_prompts/RESEARCH_234_P2_COLDWARM_TTFT_MATRIX_PROMPT.md`
  (the original run-1 prompt — still the authority on the measurement design, the
  buyer-stream vs canary-nonstream regime split, and the three deliverables).
  Read it in full, then this file's deltas override it where they conflict.

## The mission (what run 1 never did)

The instrument is not the deliverable. The deliverables are the three outputs the matrix
feeds:

1. **Calibrated `max_ttft_ms` per model class** (`pool.model_class_challenges`) with a
   recommendation on which classes can return `canary_latency_enforcement` to `enforce`.
   Ships as an audited PR (three-lane codex, 0 C/H/M).
2. **Idle-prewarm policy recommendation** — prod runs `--no-idle-prewarm`, so every
   (re)connect cold-loads the 30B (~30–60 s of buyer unavailability). Quantify the
   cold→warm delta; recommend enable/threshold/battery-guard.
3. **Buyer-UX cold-start SLO** — a stated p99 worst-case first-request ceiling.

Run 2 is **campaign-first**: get the harness runnable, run the measurement campaign,
build the matrix, then land instrument + calibration together. Landing the harness on
green CI is a step, not the goal.

## Run-1 failure modes — hard rules for run 2

1. **Instrument-without-campaign.** Run 1 produced two PRs and zero samples. Rule: the
   first session milestone is *samples in the NDJSON store*, not a PR. Do not polish the
   harness before it has produced data.
2. **PR staleness.** #526 sat until it was 169 commits behind. Rule: rebase
   `test/526-coldwarm-ttft-reland` onto current `origin/main` at session start, and
   again immediately before opening/reopening the PR. An open PR here goes stale in
   days, not weeks — land promptly or keep the branch fresh.
3. **Fighting red CI blind.** #668 was blocked by a `phase3-binary (swift test)` failure
   even though the harness is additive under `test/e2e/`. Rule: after rebasing, run the
   **attribution check** first — does `swift test` fail identically on the base commit?
   If pre-existing on main, find/wait for the fix on main (check recent PRs) or document
   the attribution explicitly in the PR body; if it's green on today's main, the rebase
   fixes it for free. Never burn hours re-triggering CI without attribution, and never
   merge on red without a documented, user-authorized exception.
4. **The regime trap (the original 2026-07-09 incident).** The pool canary sends
   `stream:false`; its "TTFT" is a full non-streaming round-trip and swings 125 ms–7000 ms
   for the same healthy provider. The buyer path streams (~1200 ms warm true-TTFT).
   **Calibrate `max_ttft_ms` ONLY against the canary non-streaming regime's measured
   envelope.** Never against buyer streaming TTFT — that exact mistake banned a healthy
   provider 3-in-a-row and 503'd buyers. Keep `max_ttft_ms ≥ 7000` until the measured
   per-class envelope exists.
5. **Prod churn is an outage machine.** Never cold-cycle the prod `mac` provider
   (hour-long outage, 2026-07-09). Never restart the prod coordinator on the
   single-provider pool for this work (~5 h self-inflicted outage, 2026-07-10). Rapid
   coordinator restarts wedge the provider CLI's v2 proof-auth and empty the pool
   (issue #519) — if a wedge happens anyway, the recovery is kill+restart the CLI
   process. The harness README already refuses prod-base cold induction without an
   explicit override — keep that guard; never use the override.
6. **Cold is one sample per cycle.** The first request warms the model, so cold samples
   accumulate slowly (append-only NDJSON, `--build-matrix` later). Rule: fix the sample
   targets NUMERICALLY up front — e.g. ≥30 warm samples per regime per class, ≥15 cold
   cycles and ≥5 post-reboot cycles per class — and report progress against those
   numbers. "Enough data" is a count, not a feeling. Cold cycles can run on a
   timer/cron over days; set that up early so accumulation is passive.
7. **Parked work must be resumed, not restarted.** Reuse `test/526-coldwarm-ttft-reland`
   and reopen #668 (or open its direct successor from the same branch, linking the
   parking comment). A third parallel implementation is a bug.

## Operating constraints (repo conventions — follow exactly)

- **Worktree discipline:** all code work in a worktree, never the canonical checkout
  (`/Users/augstar/macprovider-poc` — currently mid-merge; don't touch it). Reuse the
  retained `/Users/augstar/macprovider-526-coldwarm-ttft` worktree for the harness
  branch.
- **Verify the runtime surface before designing gate values:** read the live
  `pool.model_class_challenges` and enforcement mode from the Pearl coordinator config,
  and scan live canary behavior (`journalctl -u macprovider-coordinator | grep canary`)
  before proposing numbers. Also reconcile against the per-model autotune
  `bench_gate.max_4k_ttft_ms` values in
  `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`.
- **Check for active ops before touching Pearl.** #668 was parked partly because
  Entry 172 / Air5 ops were active. Warm measurements against prod are read-only buyer
  traffic (fine); anything else on Pearl (deploying the canary-side matrix collector,
  config changes) must first check for in-flight release/ops work and stay out of its
  way.
- **Config deploys:** the rate-card precedent is SIGHUP hot-reload. Verify which of
  `pool.model_class_challenges` / `canary_latency_enforcement` hot-reload before
  planning the calibration deploy; do NOT plan around a coordinator restart (rule 5).
- **Cold cycles need a lab provider.** Use a lab Mac (local dev machine running the
  provider CLI against a staging coordinator, e.g. the `coordinator.opoi-v0-staging.yaml`
  overlay, or `mock-gateway.mjs` for harness plumbing tests — but real cold-load numbers
  need a real model load on real Apple Silicon). The prod `mac` provider contributes
  ONLY warm-regime and passively-observed samples.
- **Money-path-adjacent gating:** the calibration PR (any change to
  `pool.model_class_challenges` / `canary_latency_enforcement`) goes through PR + the
  three-lane codex audit loop (`omc ask codex`: code / security / architect) to
  0 CRITICAL / 0 HIGH / 0 MEDIUM before merge. The harness-only PR is lighter (it was
  already reviewed 3×). Never edit the worktree while a codex lane is running in it —
  lanes silently clobber in-flight edits; wait for all lanes, then grep to confirm your
  edits survived.
- **Secrets:** buyer token lives at `~/.config/macprovider/buyer-api-key`; pass via
  `MACPROVIDER_BUYER_TOKEN` env, never echo/print it.
- **PR mechanics:** author PRs as Augustas11 (antfleet-ops reviews; merge with
  `GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge ...`). After each squash-merge:
  `git checkout main && git fetch origin && git reset --hard origin/main`.
- **Decision log:** append the calibration + prewarm decision as a
  `beta/DECISION_CRITERIA.md` entry; that PR merges LAST, after the shipped state is
  final.

## Execution order

1. **Preflight:** read the run-1 prompt + harness README + `CALIBRATION.md` + PR #668
   thread. Check the retained worktree's `git status`. Rebase the branch onto
   `origin/main`; run the CI-attribution check (rule 3). Read the live Pearl gate
   config + canary logs (read-only).
2. **Get samples flowing (same day):** stand up the lab provider rig; run the warm
   baseline against prod (read-only buyer + canary-style probes) and start timed cold
   cycles on the lab rig. Passive accumulation from here on.
3. **Land the harness** on green CI by reopening/superseding #668 from the same branch
   (it already has 3 approvals; re-request review after rebase).
4. **Accumulate to the numeric targets** (rule 6). Interleave other work; check the
   store periodically rather than babysitting.
5. **Build the matrix** (`--build-matrix`), sanity-check regime separation (canary
   non-stream numbers must be ≥ buyer-stream numbers; cold ≥ warm; if not, investigate
   the harness before trusting anything).
6. **Ship the three deliverables:** audited calibration PR (per-class `max_ttft_ms`
   against the canary regime + per-class enforce/observe recommendation), prewarm-policy
   recommendation (PR or decision entry), cold-start p99 SLO doc. Decision-log entry
   merges last.

## Definition of done

- Harness merged to `main` on green CI (attributed, not forced).
- NDJSON store meets the numeric sample targets per class; matrix artifact built and
  committed/archived with the campaign dates.
- Calibration PR merged after 0 C/H/M three-lane audit, with measured p95/p99 + headroom
  per class and an explicit enforce/observe verdict per class.
- Prewarm recommendation delivered with the measured cold→warm delta.
- Cold-start p99 SLO stated in a committed doc.
- `beta/DECISION_CRITERIA.md` entry appended (merged last).
- No prod provider cold-cycled; no prod coordinator restart; zero buyer-visible
  incidents attributable to the campaign.
