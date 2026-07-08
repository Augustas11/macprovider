# Proof of Weights — Session B implementation runbook

**Track:** Session B (Proof of Weights)  
**Out of scope:** Session A OPoI explicit WS frames, Session C MALIBU emission, Session D mining policy  
**Pearl overlay:** `/etc/macprovider/coordinator.pearl-overlays.yaml` (merged with `/opt/macprovider/coordinator.yaml`)

---

## Phase map

| Phase | Deliverable | Config gate | Routing impact |
|-------|-------------|-------------|----------------|
| **W1** | Catalog artifact bind inventory | — (audit) | Existing tier2 hash exclude |
| **W2** | Autotune hello capacity ceiling | `proof_of_weights.require_autotune_hello_gate` | Rejects over-tier hello |
| **W3** | Model-class canary probes | `pool.model_class_challenges` | Reuses canary degrade/ban |
| **W4** | Telemetry drift alerts (observe-only) | `proof_of_weights.telemetry_drift.enabled` | **None** — logs only |
| **W5** | PoM audit endpoint (non-gating) | TBD | **None** — research track |

Inventory: [`docs/research/proof-of-weights-w1-inventory.md`](../../docs/research/proof-of-weights-w1-inventory.md)

---

## §3 — W1 catalog artifact bind

**Status:** Audit complete. Routing exclude + settlement quarantine already enforced.

Optional metric (LOW): `model_hash_mismatch_total` Prometheus counter on coordinator when a provider transitions to `hash_mismatch`.

Operator catalog pin workflow:

1. Edit signed tier-2 catalog + rate-card rows (operator PR).
2. Deploy coordinator catalog path / SIGHUP reload.
3. Providers run `macprovider-cli autotune --recommend --apply` so manifest hash matches pinned row.
4. Hello carries `model_hash`; coordinator verifies via `tier2.VerifyProviderHash`.
5. Mismatch → no buyer traffic; settlement quarantine if hash diverges at payout.

---

## §4 — W2 autotune hello gate

**Package:** `phase4-coordinator/internal/autotune/` (`catalog.go`, `gate.go`, `evidence.go`)

```yaml
proof_of_weights:
  require_autotune_hello_gate: true
  autotune_evidence_ttl_days: 30
```

**Requires:** signed autotune-candidates feed + onboarding Postgres (`hardware_verification_jobs` verified evidence).

**Reject reasons:** `autotune_model_cap_exceeded`, `autotune_evidence_missing`, `autotune_evidence_stale`, `autotune_bench_gate_failed`, `autotune_thermal_throttle`.

**Pearl smoke (2026-07-08):**

- Lab provider `mac`: verified 30B bench evidence; `/poolz` shows `max_admitted_model_class: qwen3-coder-30b-a3b-instruct`.
- Unit gate: 8B evidence allows 8B hello, rejects 30B with `autotune_model_cap_exceeded` (`internal/autotune/gate_test.go`).

---

## §5 — W3 model-class OPoI probes

Extends Session A canaries with per-model banks and optional latency gates. See also [`opoi-challenge-implementation.md`](./opoi-challenge-implementation.md) §2.3.

```yaml
pool:
  canary_enabled: true
  model_class_challenges:
    qwen3-coder-30b-a3b-instruct:
      - prompt: What is the code {nonce}? Reply with only the code.
        expected: '{nonce}'
        max_ttft_ms: 3500
        min_sustained_tps: 20
```

**Export:** `model_class_opoi_pass` on `/poolz` when a model-class bank was used.

**Pearl smoke (2026-07-08):**

- Normal gates: `provider canary passed`, `model_class_opoi_pass: true`.
- Induced fail: temporary `max_ttft_ms: 1` → `provider canary failed` with `canary_ttft_ms: 1124` (latency gate path). Overlay reverted to `max_ttft_ms: 3500`.

Full downgrade cheat smoke (30B claim + 8B serve) requires a dedicated lab provider loading the wrong weights; latency gates exercise the same sanction path.

---

## §6 — W4 telemetry drift alerts

**Package:** `phase4-coordinator/internal/pow/drift.go`  
**Event:** `pow_telemetry_drift_detected` (structured warn log, per-signal cooldown)

```yaml
proof_of_weights:
  telemetry_drift:
    enabled: true
    tps_ratio_threshold: 0.70
    tps_min_absolute: 5.0
    hash_alert_on_status: [hash_mismatch, hash_invalid]
    hash_alert_on_artifact_drift: true
    opoi_pass_rate_window: 10
    opoi_pass_rate_threshold: 0.80
    alert_cooldown_s: 900
```

**Signals:** `tps`, `hash_status`, `hash_artifact`, `opoi_pass_rate`

**Pearl smoke (2026-07-08):**

- Startup: `proof-of-weights telemetry drift alerts enabled`
- Live alerts on idle lab provider (expected under low idle TPS + uncatalogued hash vs verified artifact):
  - `signal: tps` — live ~0.09 vs baseline ~45.9
  - `signal: hash_artifact` — live manifest prefix ≠ verified artifact sha256

Staging overlay example: `phase4-coordinator/coordinator.pow-w4-staging.yaml`

---

## §7 — W5 PoM audit endpoint (future)

Non-gating audit export for Proof-of-Model research. **Do not gate routing on Mac** per microbench findings. Not started.

---

## Pearl deploy procedure

1. Build: `cd phase4-coordinator && bash scripts/build-linux.sh`
2. Backup + install binary:
   ```bash
   scp -i ~/.ssh/pearl_operator_ed25519 dist/coordinator-linux-amd64 root@159.223.165.194:/tmp/
   ssh pearl 'cp /opt/macprovider/coordinator /opt/macprovider/coordinator.prev-$(date +%Y%m%d%H%M)
     install -o root -g macprovider -m 0750 /tmp/coordinator-linux-amd64 /opt/macprovider/coordinator'
   ```
3. Merge overlay keys into `/etc/macprovider/coordinator.pearl-overlays.yaml` (preserve W2/W3/W4 blocks).
4. Validate:
   ```bash
   ssh pearl 'set -a; source /etc/macprovider/coordinator.env; set +a
     /opt/macprovider/coordinator --config /opt/macprovider/coordinator.yaml \
       --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml --validate-config'
   ```
5. Restart: `systemctl restart macprovider-coordinator`
6. Verify: `curl -sf https://coordinator.streamvc.live/healthz`, `/poolz` on WS port 8444 with operator bearer.

**Rollback:** restore backup binary; remove overlay keys; restart.

---

## Operator verification checklist

- [x] W2 hello gate enabled; `max_admitted_model_*` populated on connected providers
- [x] W3 model-class canaries pass under production gates
- [x] W3 latency gate fails under induced strict TTFT (smoke)
- [x] W4 drift alerts emit on Pearl (observe-only)
- [ ] W5 PoM audit endpoint
- [x] Optional `model_hash_mismatch_total` metric (PR pending merge)
- [ ] `beta/DECISION_CRITERIA.md` Session B closure entry
