# RESEARCH_234 — P2 e2e harness: cold/warm TTFT matrix + prewarm-policy calibration

**Carry this in a fresh session.** Self-contained; assumes no memory of the P1 session.

## What this is
The second e2e testing harness for macprovider (P2). P1 — the **canary buyer probe** at
`test/e2e/canary-buyer/` — shipped and is running on Pearl (merged in PR #507, commit
`d429d0c`); it measures steady-state serving quality (TTFT p50/p95/p99, decode TPS,
KV-cache reuse, serviceability) from the buyer vantage. P2 attacks the ONE thing P1
doesn't: **cold-start behavior and the latency gates that depend on it.**

## Why P2, why now (the forcing function)
On 2026-07-09 a cold 30B model load produced a **30,827 ms** canary TTFT in prod. The
W3 canary latency gate `max_ttft_ms` had been hand-guessed (3500 → padded to 7000) with
no measured basis. Tightening it to 3500 (calibrated off the *streaming buyer* TTFT of
~1200 ms) sanctioned a healthy provider 3-in-a-row → provider banned → buyer 503s. The
fix shipped was to make the latency gates **observe-only** by default
(`pool.canary_latency_enforcement: observe`, PR #513) — a safety valve, not a
calibration. P2 produces the *real numbers* that let those gates be tightened back to
`enforce` safely, per model class.

### The critical subtlety P2 MUST get right (this is what bit us)
The pool canary sends `stream:false` (**non-streaming**). Its measured "TTFT" is the
full non-streaming round-trip and swings wildly (observed **125 ms … 7000 ms** for the
*same healthy provider*, depending on relay chunk timing). The **buyer path streams** and
shows the true first-token latency (~1200 ms warm). **These two numbers are NOT
interchangeable.** The `max_ttft_ms` gate is evaluated against the CANARY's non-streaming
measurement regime — so it must be calibrated against *that*, not against the buyer
streaming TTFT. P2's core deliverable is a matrix that measures **both regimes** side by
side (buyer-streaming TTFT AND canary-non-streaming TTFT), cold and warm, per model
class, so the gate can be set against the correct regime with headroom.

## Goal
Extend the harness with a scenario that deliberately drives a provider **cold** (model
unloaded / idle N minutes / provider reboot), then measures **cold TTFT vs warm TTFT per
model tier**, in both the buyer-streaming and canary-non-streaming regimes, including
**time-to-first-token after provider reboot** (a full cold model load — observed ~30–58 s
for a cold 30B).

### Outputs (the three deliverables from the original P2 proposal)
1. **Calibrated `max_ttft_ms` per model class** to replace the guessed 3500/7000 — set
   against the *canary non-streaming* regime with measured p95/p99 + headroom. Ships as a
   PR updating `pool.model_class_challenges` (and the staging overlay), and enables
   flipping `canary_latency_enforcement` back to `enforce` for classes with a stable
   measured envelope.
2. **A measured case for an idle-prewarm policy.** The prod mac provider CLI runs with
   `--no-idle-prewarm`, so every (re)connect cold-loads the 30B (~30–60 s of buyer
   unavailability). Prewarm telemetry already exists (commit `ed2f782`). Quantify the
   cold→warm delta and produce the recommendation (enable idle-prewarm? at what idle
   threshold? battery guard?).
3. **A buyer-UX SLO for the worst-case first request** (cold-start p99), so the product
   can state/monitor a real cold-start ceiling.

## What to build
A harness scenario in the same spirit as P1 (`test/e2e/canary-buyer/probe.mjs` — a
zero-dep Node script; read it first, reuse its structure, token handling, SSRF guards,
Prometheus/JSON output, and artifact rotation). For each model class + provider:
- **Warm baseline:** provider warm, measure buyer-streaming TTFT (real first token) and
  canary-style non-streaming round-trip TTFT, N samples → p50/p95/p99.
- **Induce cold** (see below), then measure the **first** request after cold: buyer
  cold-start TTFT (includes model load) and, separately, the canary's non-streaming
  measurement of the same cold provider.
- **Post-reboot:** time-to-first-token after a full provider process restart (cold load
  from disk).
- Emit the **matrix**: `{model_class, regime(buyer_stream|canary_nonstream), state(warm|cold|post_reboot), ttft_p50/p95/p99, decode_tps, sample_n}` → Prometheus textfile + JSON artifact, same as P1.

### How to induce "cold" — SAFELY (hard-won 2026-07-09 lesson)
- **Use a lab provider, NOT the prod `mac` provider**, for reboot/idle-unload cycles.
  Churning the prod provider caused an hour-long outage.
- **Do NOT stack coordinator restarts.** Rapid coordinator restarts wedge the provider
  CLI's v2 proof-auth (`auth_request proof rejected: type`) and empty the pool (issue
  #519). A single clean restart is fine; churn is not.
- Cold-induction levers, least-invasive first: (a) let the provider go idle past its
  model-unload threshold; (b) restart just the provider CLI process (not the coordinator);
  (c) full provider reboot for the post-reboot number.

## Operating model (same as P1)
Build it, then **carry it against a lab provider (and prod read-only where safe) to
accumulate the matrix over real cold/warm cycles**, then turn the findings into PRs:
the calibrated-gate PR, the prewarm-policy PR/decision, and the SLO doc. Do not block on
merging the harness PR while it's still accumulating data.

## Constraints (repo conventions — follow exactly)
- **Fresh worktree off `origin/main`** for all code work; never edit the canonical
  checkout. `git worktree add ../macprovider-p2-ttft -b feat/p2-coldwarm-ttft origin/main`.
- **Canary/latency config is a security sanction gate (money-path-adjacent).** Any change
  to `pool.model_class_challenges` / `canary_latency_enforcement` goes through a **PR +
  three-lane codex audit** (code / security / architect via `omc ask codex`) to **0
  CRITICAL / 0 HIGH / 0 MEDIUM** before merge. The harness scenario code itself
  (test-only) is lighter, but calibration changes are gated.
- **Never print the buyer token** to the transcript. It lives at
  `~/.config/macprovider/buyer-api-key`. Pass via env (`MACPROVIDER_BUYER_TOKEN`), never
  echo it.
- **Verify the runtime surface before designing** — read the current
  `pool.model_class_challenges` on Pearl and the live canary logs
  (`journalctl -u macprovider-coordinator | grep canary`) before proposing gate values.
- **Author PRs as Augustas11** so antfleet-ops can review (a PR authored by antfleet-ops
  cannot self-approve). Merge with `GH_TOKEN=$(gh auth token -u Augustas11)`.

## Key references
- **Prod:** coordinator `coordinator.streamvc.live` (Pearl VPS, systemd
  `macprovider-coordinator`), gateway `api.streamvc.live`. Provider `mac` serves
  `qwen3-coder-30b-a3b-instruct`.
- **P1 harness (build on this):** `test/e2e/canary-buyer/` (probe.mjs, run-canary.sh,
  canary-buyer.{service,timer}, README.md). Deployed on Pearl under
  `/opt/macprovider/canary-buyer/`.
- **Coordinator canary/latency gate:** `phase4-coordinator/internal/ws/canary_probe.go`
  (`evaluateCanaryProbe`, `challengeLatencyBreach`, `canaryMetricsFromTiming`),
  `phase4-coordinator/internal/config/config.go` (`CanaryColdStartGraceS`,
  `CanaryLatencyEnforcement`, `ModelClassChallenges`). Config examples:
  `coordinator.yaml.example`, `coordinator.opoi-v0-staging.yaml`. Runbook:
  `ops/runbooks/proof-of-weights-implementation.md` §5.
- **Cold-start grace (W3):** `pool.canary_cold_start_grace_s` waives wall-time gates for
  N s after connect — only in `enforce` mode. PR #512.
- **Autotune bench gates** (existing per-model TTFT targets to reconcile against):
  `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` — each model's
  `bench_gate.max_4k_ttft_ms` (e.g. 30B = 3500, gpt-oss-20b = 2500).
- **Prewarm:** provider CLI `--no-idle-prewarm` flag + `idle_prewarm.*` config
  (`phase3-binary`), telemetry commit `ed2f782`.
- **Related issues from the 2026-07-09 incident:** #513 (observe-only latency, merged),
  #519 (CLI wedge on restart churn), #520 (launchd double-spawn), #524 (heartbeat +
  operating mode).
- **The non-streaming-metric trap, in prose:** canary is `stream:false`; its TTFT/TPS are
  unreliable; keep `max_ttft_ms ≥ 7000` until P2 measures a real per-class envelope; never
  calibrate the gate off buyer-probe streaming TTFT.

## Definition of done
- Harness scenario built (reviewed like P1), measuring the cold/warm × buyer/canary ×
  per-model matrix, emitting Prometheus + JSON.
- Matrix accumulated over real cold/warm cycles on a lab provider.
- A calibration PR setting measured `max_ttft_ms` per model class (audit-looped to 0
  C/H/M), with a recommendation on whether/which classes can return to `enforce`.
- A prewarm-policy recommendation (enable idle-prewarm? threshold?) backed by the cold→warm
  delta.
- A stated buyer-UX cold-start SLO (p99 worst-case first request).
