# Handoff — Ship #816 server-side fixes (coordinator + gateway), park the CLI fix, then re-test 30B on Goose

**Created:** 2026-07-30 · **Umbrella issue:** https://github.com/Augustas11/macprovider/issues/816
**Sub-issues (sequenced):** #817 coordinator (do 1st) · #818 gateway (do 2nd) · #819 provider-cli (deferred)

## Mission (in order)
Issue **#816** documents why a large/slow single-slot provider (Qwen3-Coder-30B) gets evicted from buyer routing **while it is actively and successfully decoding**: the provider's heartbeat is starved by inference running on Swift's cooperative concurrency pool, so the coordinator's staleness gate drops a provably-alive provider. Buyers see intermittent `503 no_provider_available`; streaming clients (Goose) also trip the gateway's `decode_idle` deadline.

#816 lists three fixes. **This session ships the two server-side ones** (no fleet CLI release needed), deploys them to Pearl, parks the provider-CLI fix, then re-tests the 30B on Goose.

1. **#817 — coordinator** (`phase4-coordinator`, Go): treat an in-flight request as implicit liveness — do NOT evict a provider on stale heartbeat while it has an active request on a slot.
2. **#818 — gateway** (`phase5-gateway`, Go): make the `decode_idle` stream deadline adaptive to the model's expected tok/s instead of a flat timeout.
3. **Release + deploy** both to Pearl (server-side; no CLI version, no fleet auto-update); close #817 and #818.
4. **Park #819** (provider CLI, fix #1) — the root-cause fix, deferred to the next `macprovider-cli` release. Leave #816 (umbrella) + #819 open.
5. **Re-test the 30B on Goose** end-to-end.

## Ground rules (this repo — see CLAUDE.md)
- Work in a **fresh worktree off `origin/main`**; do not edit the canonical checkout.
- Coordinator/gateway are money-path-adjacent → **PRs, not direct push.** Each PR: fill the `SPEC-GOVERNANCE-DECLARATION` block, get **`ci-required` green + 1 approving review**, then squash-merge (`GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge …`).
- Every slice passes the **3-lane Codex audit loop** (code/security/architect) to **0 C/H/M** before merge.
- **Release verification:** workflow-green is not production proof. After deploy, verify the running service on Pearl (healthz + the specific behaviors below).
- **Pearl access:** `ssh pearl` (159.223.165.194). Services: `macprovider-coordinator.service`, `macprovider-gateway.service`. Deploy via the repo's Pearl deploy tooling (find `deploy-pearl-vps` / ops runbooks; mind the healthz-version blind spot).

## Root cause recap (evidence — already gathered)
- **Not memory:** a clean 150-token 30B decode at 12k did **zero swap-outs** (`Swapouts` unchanged), decode finished cleanly. Not capacity-bound.
- **Provider:** inference dispatched via `Task.detached` on the cooperative pool — `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:779`; heartbeat is a cooperative `Task` — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:246–250` (Issue #189 comment explicitly names *"cooperative-task starvation"*, mitigated only by a respawn watchdog).
- A legitimate ~7s decode (`decode_ms=6797`) hogs the pool far longer than the ~**1500 ms** heartbeat window → heartbeat goes stale.
- Coordinator staleness threshold hint: `phase4-coordinator/tools/mockprovider/main.go:298` ("coordinator only warns on stale (>1.5x) gaps").
- Observed: coordinator `provider heartbeat stale gap=1551..2528 threshold=1500` during decode; gateway `deadline_phase=decode_idle decode_ms=0 flush_ms=10003` → "Provider timed out during streaming"; buyer effect `503 no_provider_available`.

## Fix #2 — coordinator: in-flight = liveness
**Goal:** the coordinator must not drop a provider from the routable set (or mark it degraded/unavailable) for a stale heartbeat **while it has ≥1 active in-flight request on a slot**. A provider mid-inference is alive.
**Where to look** (grep `phase4-coordinator`): heartbeat-staleness detection + the routing candidate filter that excludes stale/unready providers (`heartbeat`, `stale`, `routing_decision`, `candidate_count_before_filters`, provider readiness/eviction state). The coordinator already receives `slots_free`/`slots_total` in heartbeats — reconcile with active-request tracking.
**Design:** while the provider has an active/assigned request (`slots_busy > 0`), suppress stale-heartbeat eviction; optionally scale the threshold by the model's expected per-token latency. **Keep genuine dead-provider detection intact** — an *idle* provider with a stale heartbeat should still be evicted.
**Tests:** provider with in-flight request + stale heartbeat stays routable; idle provider + stale heartbeat gets evicted. Use `tools/mockprovider` for an integration test.
**Acceptance:** no eviction / no `no_provider` for a provider that is actively decoding.

## Fix #3 — gateway: adaptive decode_idle
**Goal:** the gateway's inter-token (`decode_idle`) deadline should adapt to the served model's expected decode rate, not a flat value a slow 30B trips.
**Where to look** (grep `phase5-gateway`): `decode_idle`, `deadline_phase`, the streaming-proxy inter-chunk/idle timeout.
**Design:** derive the idle deadline from a per-model expected tok/s (or per-model-class config) with a sane floor/ceiling. **Do not remove the protection** — a genuinely hung provider must still be cut.
**Tests:** a slow-but-steady stream (multi-second gaps within the model's expected range) is NOT aborted; a truly idle stream still hits the deadline.
**Acceptance:** a warm 30B stream completes through the gateway without a false `decode_idle` abort.

## Release + deploy
- One PR per service (or bundled if deploy is coupled), governance declarations filled, audits clean, `ci-required` green + approval, squash-merge.
- Deploy new coordinator + gateway to Pearl. **Verify on Pearl:** services active, healthz OK, and the two behaviors above (busy provider not evicted; no false `decode_idle`).

## Park the CLI fix (#819)
Close **#817** and **#818** when their PRs merge + deploy to Pearl (reference the PR links + deploy date). Comment on the umbrella **#816** that both server-side fixes shipped and **#819 (provider `macprovider-cli`** — move inference off the cooperative pool, `ModelRuntime.swift:779`) is **DEFERRED** to the next CLI release (build → notarize → fleet auto-update). Leave **#816** and **#819** open.

## Then: re-test 30B on Goose
Goose is installed (`/opt/homebrew/bin/goose`), config at `~/.config/goose/config.yaml` (provider `openai`, `OPENAI_HOST: https://api.streamvc.live`, `GOOSE_MODEL: mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`). Buyer key: `~/.config/macprovider/buyer-api-key` (never print it).

```bash
OPENAI_API_KEY=$(cat ~/.config/macprovider/buyer-api-key) goose run -t "reply with exactly one word: online"
```
Before the fixes this returned intermittent `503 no_provider_available` and `Provider timed out during streaming`. **Success = Goose gets a completion reliably.**

### IMPORTANT — there are TWO independent gates on the 30B
- **Gate A — stale-heartbeat eviction:** fixed by **#2** above.
- **Gate B — `missing_benchmark` / PoW telemetry drift:** SEPARATE. The prior session **hand-edited** this Mac's 30B config (`max_context_override → 12000`, enabled `idle_prewarm`) **without re-running autotune**, creating `pow_telemetry_drift_detected: missing_benchmark`, which ALSO gates the 30B out of buyer routing. To get a clean test you must ALSO clear Gate B:
  - (a) **Re-run autotune locally on this Mac** to submit fresh hardware evidence for the current config (keychain is fine locally). This was blocked earlier by an evidence-submission **HTTP 429** rate-limit — retry (it likely cleared). Example:
    `macprovider-cli autotune --recommend --candidate-models mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit --target-context 12000 --max-context-axis 12000 --max-batch-axis 1 --submit-hardware-evidence --apply --recover-hardware-admission --max-duration 1500` (drains the provider ~15–25 min; `--recover-hardware-admission` restores it), **or**
  - (b) revert the provider to a config that already has valid evidence.
  - Confirm cleared: `curl -s -H "Authorization: Bearer $(cat ~/.config/macprovider/buyer-api-key)" https://api.streamvc.live/v1/models` shows the 30B present with `max_context_tokens`, and Pearl coordinator logs show no `pow_telemetry_drift_detected` for provider `mp-26592d710fc97aa7c07b260665c67cf6`.
- Keep `idle_prewarm` enabled (low TTFT).

### Fleet state at handoff (2026-07-30)
- **This Mac** (`mp-26592d710fc97aa7c07b260665c67cf6`): 30B, `max_context_override=12000`, concurrency 1, `idle_prewarm` enabled — **hand-edited / drifted**.
- **air5** (`mp-90542c0bcf7c4d303795cd10bda3830d`, `admin@192.168.8.24`, key `~/.ssh/macprovider_prebeta_newmac_ed25519`): Qwen3-8B hand-edited to 12k — also drifted. **air5 autotune must be run from air5's GUI** (headless SSH can't unlock its login keychain — `keychainReadFailed`).
- Same-day related issue: **#815** (gpt-oss-20b autotune SIGTRAP + a fail-unsafe drain that strands the provider).

## Done when
1. Coordinator + gateway fixes merged (audits clean) **and deployed to Pearl**, verified on the box.
2. #816 commented and parked for the CLI (fix #1).
3. 30B answers **reliably** through Goose via `api.streamvc.live` (both gates clear), captured as evidence.
