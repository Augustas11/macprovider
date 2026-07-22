# RESEARCH_236 P4 cache-reuse gate — RESUME NOTE

Branch: `research/236-p4-cache-regression`
Worktree: `/Users/augstar/macprovider-p4-cache` (off origin/main @ 55d298ba)
Task prompt: `audits/_prompts/RESEARCH_236_P4_CACHE_REGRESSION_PROMPT.md` (on origin/main)

## Status: implementation + calibration + arming DONE; audit R5 in flight; PR NOT yet opened.

### Deliverables
- D1 scenario `test/network-harness/scenarios/16_sticky_cache_reuse.yaml` — DONE (sticky_cache pattern, single buyer, divergent prompts, armed).
- D2 capture cached_prompt_tokens in buyer.Result + loadgen.go — DONE (+ presence flags, unit tests).
- D3 B8/B9 invariants in benchmark.go — DONE (B8 armed gate; B9 record-only). SPEC §3.5/§4.5/§5 rows. Unit tests.
- D4 baseline + calibrate + arm — DONE.

### Measured baseline (2026-07-22, prod api.streamvc.live, 30B-Coder, all 8 req ok)
- **Reuse median = 0.725** over 7 warm turns (min=mean=median=0.725, deterministic). Corroborates #376 ~0.64-0.70.
- B9 record-only latency: cached p50 ~2.1s vs uncached ~10s (ratio ~0.21).
- Evidence artifacts: `audits/2026-07-22/RESEARCH_236_baseline/`.
- KEY FINDING: earlier "0 reuse" was a `nothing_new` artifact (identical warm prompts). Fixed by divergent per-turn prompts. Pool is healthy (~0.72 reuse on both 8B and 30B-Coder).

### Thresholds set (calibrated from 0.725)
- B8 floor CacheReuseTarget = 0.50, bare-min 0.30. `cache_gate_armed: true` in scenario 16.
- B9 record-only (always SKIP; not armed by design).

### Sticky routing liveness (verified 2026-07-22)
gateway routing.sticky_enabled=true + MACPROVIDER_KEY_HASH_SECRET set; coord routing.sticky_enabled=true; /v1/models sticky_affinity.enabled=true ttl 1800.

### Audit (three-lane codex via `omc ask codex`; prompts in audits/2026-07-22/)
- Security: PASSED R2 (0 C/H/M) — do not re-run.
- Code: R1 3M, R2 3M, R3 2M, R4 0/0/0(2 LOW). R5 in flight.
- Architect: R1 4H, R2 4H, R3 1H, R4 1H (nothing_new), R5 in flight.
- All prior C/H/M resolved in commits 5fbde8c5, 441428f5, 1ae026e2, 6222a418.

### NEXT STEPS (for a fresh session)
1. Read R5 audit results: `scratchpad/r5-code.out` / `scratchpad/r5-arch.out` (each line = artifact path in `.omc/artifacts/ask/`; read the tail). Bar = 0 C/H/M. Fix any C/H/M, re-audit that lane, else proceed.
2. Rebase on origin/main (`git fetch origin && git rebase origin/main`); resolve; `go test ./...` under test/network-harness.
3. Open PR as **Augustas11** (so antfleet-ops can review): `GH_TOKEN=$(gh auth token -u Augustas11) gh pr create --base main --head research/236-p4-cache-regression` with body from `scratchpad/pr-body.md`. Do NOT merge — hand to user.

### Commands
- Build/test: `cd test/network-harness && go test ./...`
- Baseline re-run (prod, ~3 min): build harness, strip db_ssh lines from scenario, `BUYER_TOKEN=$(cat ~/.config/macprovider/buyer-api-key) harness run <scenario> --out <dir>`. NEVER print the token.
