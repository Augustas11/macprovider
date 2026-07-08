# Runbook: OPoI Challenge Implementation (MacProvider Mining Program)

**Version:** 0.1  
**Date:** 2026-07-08  
**Audience:** Coordinator + macprovider-cli implementers  
**Spec:** `specs/SPEC-OPOI-CHALLENGE-WS.md`  
**Research:** `research/pouw-apple-silicon-mining-alternatives.md`

---

## 0. Executive path

MacProvider **does not need new PoW**. Implement **OPoI liveness** by:

1. **Ship OPoI v0** — enable and tune **existing pool canaries** (zero wire change).
2. **Ship OPoI v1** — optional explicit `opoi_challenge` WS frames + CLI handler.
3. **Ship OPoI v1.1** — tie rate-card tier multiplier to challenge pass streak (PR, money-path review).

PoM remains **audit-only** (see `research/pom-mlx-microbench/RESULTS.md`).

---

## 1. Preconditions

- [ ] Read `research/macprovider-pom-opoi-adoption.md` §11 (PoM fail)
- [ ] Read Keryx reference: `keryx-stratum-bridge` `client_handler.go:262-345`, `share_handler.go:419-477`
- [ ] Confirm branch: `feat/opoi-challenge-ws` from fresh `origin/main` (worktree)
- [ ] Coordinator money-path changes (tier multiplier) → **PR required**

---

## 2. Phase A — OPoI v0 (canaries only) — ~1 day ops + config

### 2.1 Verify canary code path exists ✅ (verified 2026-07-08, feat/opoi-v0-canaries)

| Component | Path | Lines (approx) |
|-----------|------|----------------|
| Sweep loop | `phase4-coordinator/internal/ws/server.go` | 1963+ |
| WS probe | `runWSCanaryProbeAttempt` | 2128 |
| HTTP probe | `runHTTPCanaryProbeAttempt` | 2163 |
| Nonce embed | `buildCanaryBodyFromRandom` | 2203 |
| Nonce validation | `buildCanaryBody` — errors if `{nonce}` absent | 2216-2217 |
| Sanctions | `RecordCanaryResult`, `CanaryTripDegraded/Unavailable` | 2052+ |

All `go test ./internal/ws/ ./internal/config/ ./internal/pool/ -run Canary` — **PASS** (10 tests, 2026-07-08).

### 2.2 Configure coordinator.yaml

**Config shipped in `feat/opoi-v0-canaries` (2026-07-08):**

| File | Change |
|------|--------|
| `phase4-coordinator/coordinator.yaml.example` | `canary_enabled: true`, challenge bank with 2 entries |
| `phase4-coordinator/dist/coordinator.yaml.example` | `canary_enabled: false` (production template), challenge bank commented for reference |
| `phase4-coordinator/coordinator.opoi-v0-staging.yaml` | New staging overlay — `canary_enabled: true` + full challenge bank |
| `phase4-coordinator/dist/coordinator.yaml` | Comment block near pool section; canaries **not** enabled on Pearl yet |

```yaml
pool:
  canary_enabled: true
  canary_interval_s: 300          # provisional; use 600 on production initially
  canary_timeout_s: 120
  canary_max_tokens: 16
  canary_failure_threshold: 3     # provisional → ban; pinned → degrade at 2
  canary_challenges:
    - prompt: "Reply with exactly: CANARY-{nonce}"
      expected: "CANARY-{nonce}"
    - prompt: "What is the code {nonce}? Reply with only the code."
      expected: "{nonce}"
```

**Rules:**

- Every challenge **must** include `{nonce}` in prompt and expected (`server.go:2216-2217`).
- Expected answer must be **exact** after trim (`canaryAnswerMatches`).
- Use **deterministic** short outputs (low `max_tokens`) to minimize MLX variance.

### 2.3 Model-specific banks (recommended)

Maintain per-model challenge entries if templates differ (tokenizer quirks). Start with one bank for 3B/8B instruct models.

### 2.4 Rollout

**Full Pearl procedure:** [`opoi-pearl-deploy.md`](./opoi-pearl-deploy.md) (build, systemd drop-in, scripted deploy).

1. Enable on **staging** coordinator with 1–2 lab providers.
2. Watch logs: `provider canary passed` / `provider canary failed`.
3. Confirm degraded provider drops out of `/poolz` routing (`RoutingEligible` false).
4. Enable production with `canary_interval_s: 600` initially.

**Pearl staging deploy commands** (operator — requires SSH access to Pearl VPS):

```bash
# 1. Copy overlay to Pearl (after PR merge + coordinator binary with --config-overlay)
scp phase4-coordinator/coordinator.opoi-v0-staging.yaml pearl:/etc/macprovider/

# 2. Validate merged config (no daemon start)
ssh pearl
/opt/macprovider/macprovider-coordinator \
  --config /etc/macprovider/coordinator.yaml \
  --config-overlay /etc/macprovider/coordinator.opoi-v0-staging.yaml \
  --validate-config

# 3. Update systemd unit to pass --config-overlay (or merge pool keys manually)
# Example ExecStart addition:
#   --config-overlay /etc/macprovider/coordinator.opoi-v0-staging.yaml
sudo systemctl daemon-reload
sudo systemctl restart macprovider-coordinator

# 4. Tail logs for canary events
journalctl -fu macprovider-coordinator | grep -E "canary (passed|failed|skipped)"

# 5. Promote to production: keep overlay in unit with canary_interval_s: 600
#    Only after staging validation per §2.5-2.6.
```

**Rollback:** remove `--config-overlay` from unit and restart (or set `canary_enabled: false` in overlay).

### 2.5 Operator verification

```bash
# Provider should remain StateReady when passing
curl -sS -H "Authorization: Bearer $ADMIN" https://coordinator:8443/admin/poolz | jq '.providers[] | {id:.provider_id, state:.state}'

# After forced fail (wrong model), expect state degraded or disconnect
```

### 2.6 Success criteria (v0)

- [ ] Canary runs on interval for bearer-validated WS providers
- [ ] Nonce embedded in prompt (check coordinator logs / packet capture)
- [ ] 3 failures → provisional ban or pinned degrade
- [ ] Recovery pass clears sanction (`deleteCanarySanction` path)

---

## 3. Phase B — OPoI v1 explicit WS — ~1–2 eng-weeks

### 3.1 Coordinator tasks

| Task | File(s) | Notes |
|------|---------|-------|
| Add `OPOIChallenge` / response structs | `internal/ws/messages.go` | Mirror spec §6 |
| Pending challenge map per session | `internal/ws/server.go` | Mutex; one active |
| Issue `opoi_challenge` frame | new `issueOPoIChallenge()` | Reuse `buildCanaryBody` internals |
| Handle `opoi_challenge_response` | `handleProviderFrame` switch | Verify nonce/id |
| Feature flag | `config.Pool.OPoIExplicitWS bool` | Default false |
| Metrics | prom / zerolog counters | pass/fail/timeout |

**Reuse:** Call same sanction path as `runCanaryProbe` after verify — do not duplicate degrade logic.

### 3.2 Provider CLI tasks

| Task | File(s) | Notes |
|------|---------|-------|
| Handle `opoi_challenge` | `CoordinatorClient.swift` | Dispatch to ModelRuntime |
| Send `opoi_challenge_response` | same | Include latency_ms |
| Respect deadline | same | Cancel if over |
| Feature flag | config yaml | Match coordinator |

### 3.3 Wire compatibility

- v0 canaries **continue** when `opoi_explicit_ws: false` (default).
- v1 enabled: canaries may be disabled OR run as fallback — **pick one** (recommend: explicit WS replaces implicit dispatch when flag on).

### 3.4 Tests

- Extend `internal/ws/canary_test.go` patterns for nonce mismatch
- CLI unit test: mock challenge → response JSON

### 3.5 Success criteria (v1)

- [ ] Explicit frame round-trip on lab provider
- [ ] Replay rejected (wrong nonce)
- [ ] Timeout triggers same sanction as v0 fail
- [ ] Buyer inference not permanently blocked (slots recover)

---

## 4. Phase C — OPoI v1.1 tier multiplier — PR + review

### 4.1 Design

Link **rate-card tier multiplier** to liveness streak:

| Streak | Multiplier |
|--------|------------|
| ≥7 passes / 24h | 1.0× |
| 1 fail | 0.5× until next pass |
| Trip unavailable | 0× (existing ban) |

### 4.2 Implementation sketch

- Table: `provider_liveness (provider_id, pass_streak, last_fail_at, multiplier_bps)`
- Hook: `billing/formula.go` `ComputeCredits` — multiply `provider_credits` by `multiplier_bps/10000`
- **PR** with audit loop (money-path)

### 4.3 Success criteria

- [ ] Failed challenge reduces **new** earnings, not retroactive payable credits
- [ ] spec022 payable view unchanged for already-verified rows

---

## 5. Parallel tracks (optional)

| Track | Owner | When |
|-------|-------|------|
| PoQ evaluator for disputes | Research | After v1 stable |
| PoM audit endpoint (non-gating) | Research | Low priority |
| Autotune cap enforcement at hello | Coordinator | With v0 |

---

## 6. Rollback

| Phase | Rollback |
|-------|----------|
| v0 | `canary_enabled: false`; restart coordinator |
| v1 | `opoi_explicit_ws: false`; providers ignore unknown frames |
| v1.1 | multiplier fixed at 10000 bps via config |

---

## 7. Monitoring

| Signal | Action |
|--------|--------|
| `provider canary failed` spike | Check model swap / OOM |
| High skip rate | `SlotsFree==0` — tune interval |
| False fails (MLX drift) | Widen template or normalize match |
| Degraded pinned providers | Ops review; manual sanction clear |

---

## 8. Decision log entry (template)

Append to `beta/DECISION_CRITERIA.md`:

> **Entry N — OPoI v0 for mining liveness (2026-07-08)**  
> PoM tier gating failed Apple Silicon microbench (~4× @ 75% held). Adopt Keryx **OPoI liveness shape** via existing pool canaries (v0), explicit WS (v1), tier multiplier (v1.1). PoM audit-only.

---

## 9. File checklist (PR)

```
phase4-coordinator/internal/config/config.go          # OPoIExplicitWS, intervals
phase4-coordinator/internal/ws/messages.go            # opoi_* types
phase4-coordinator/internal/ws/server.go              # handler + schedule
phase4-coordinator/internal/ws/opoi_test.go         # new
phase4-coordinator/coordinator.yaml.example           # canary bank docs
phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
docs/ or specs/SPEC-OPOI-CHALLENGE-WS.md              # normative
ops/runbooks/opoi-challenge-implementation.md         # this file
```

---

## 10. FAQ

**Q: Is this Pearl/cuPOW?**  
A: No. Pearl is L1 GEMM PoUW. This is coordinator liveness only.

**Q: Why not PoM?**  
A: See `research/pom-mlx-microbench/RESULTS.md` — insufficient penalty on unified memory.

**Q: Do we already have this?**  
A: **Yes ~80%** — pool canaries are OPoI v0. This runbook formalizes and extends.

**Q: Chain needed?**  
A: No.

---

*End of runbook.*
