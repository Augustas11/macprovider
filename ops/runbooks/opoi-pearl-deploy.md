# Runbook: OPoI v0 Pearl deploy (Session A)

**Version:** 0.1  
**Date:** 2026-07-08  
**Audience:** Operator  
**Prerequisite:** PR [#478](https://github.com/Augustas11/macprovider/pull/478) merged to `main` (`--config-overlay`, `--validate-config`)  
**Parent:** [`opoi-challenge-implementation.md`](./opoi-challenge-implementation.md) §2.4–2.6

---

## 0. What this deploy does

| Changes | Does NOT change |
|---------|-----------------|
| OPoI overlay and systemd drop-in | `/opt/macprovider/coordinator.yaml` base file |
| `/etc/macprovider/coordinator.opoi-v0-staging.yaml` overlay | nginx / TLS / gateway |
| systemd drop-in with `--config-overlay` | Coordinator/runtime binaries |

Canaries enable via overlay only — rollback removes drop-in without editing production YAML.
Production binary bytes must come from the signed Pearl runtime updater and the
guarded `deploy-pearl-vps.sh` path, not this retired overlay runbook.

---

## 1. Preconditions

- [ ] `main` includes `LoadWithOverlay` + CLI flags (merged #478)
- [ ] Pearl SSH key: `~/.ssh/pearl_operator_ed25519` (or set `SSH_KEY`)
- [ ] Pearl host: `159.223.165.194` (`coordinator.streamvc.live`)
- [ ] `/etc/macprovider/coordinator.env` present on Pearl (secrets)
- [ ] **1–2 lab providers** ready to observe (Malibu on your Mac counts)
- [ ] Prefer **zero connected providers** at restart, or set `FORCE_RESTART=1`

---

## 2. Quick deploy (scripted)

From a clean checkout of the exact coordinator release tag:

```bash
git checkout vX.Y.Z
cd phase4-coordinator
bash scripts/build-linux.sh
bash dist/deploy-opoi-v0-pearl.sh
```

Dry run:

```bash
DRY_RUN=1 bash dist/deploy-opoi-v0-pearl.sh
```

With providers connected (drain will run):

```bash
FORCE_RESTART=1 bash dist/deploy-opoi-v0-pearl.sh
```

---

## 3. Manual deploy (step-by-step)

### 3.1 Production binary authority

Do not upload or install `dist/coordinator-linux-amd64` manually for production
OPoI work. Production coordinator, coordinator-cli, gateway, and sidecar bytes
must already be installed from the signed Pearl runtime release/updater; direct
deploys only restart/validate those bytes after release provenance gates pass.

Dev-only cross-compile (not production deployable):

```bash
cd phase4-coordinator
ALLOW_NON_RELEASE_COORDINATOR_BUILD=1 \
VERSION="$(git describe --always --dirty --tags)"
GOOS=linux GOARCH=amd64 go build \
  -ldflags "-X main.version=${VERSION}" \
  -o dist/coordinator-linux-amd64 ./cmd/coordinator
```

### 3.2 Upload overlay artifacts only

```bash
SSH_KEY=~/.ssh/pearl_operator_ed25519
PEARL=root@159.223.165.194

scp -i "$SSH_KEY" coordinator.opoi-v0-staging.yaml "$PEARL:/etc/macprovider/"
scp -i "$SSH_KEY" dist/systemd/opoi-v0.conf.example "$PEARL:/tmp/opoi-v0.conf"
```

### 3.3 Install overlay on Pearl

```bash
ssh -i "$SSH_KEY" "$PEARL" 'set -e
  install -o root -g macprovider -m 0640 \
    /etc/macprovider/coordinator.opoi-v0-staging.yaml \
    /etc/macprovider/coordinator.opoi-v0-staging.yaml
  install -d -m 0755 /etc/systemd/system/macprovider-coordinator.service.d
  install -m 0644 /tmp/opoi-v0.conf \
    /etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf
'
```

### 3.4 Validate config (no daemon start)

```bash
ssh -i "$SSH_KEY" "$PEARL" \
  '/opt/macprovider/coordinator \
    --config /opt/macprovider/coordinator.yaml \
    --config-overlay /etc/macprovider/coordinator.opoi-v0-staging.yaml \
    --validate-config'
# expect: config: ok
```

### 3.5 Restart

```bash
ssh -i "$SSH_KEY" "$PEARL" \
  'systemctl daemon-reload && systemctl restart macprovider-coordinator && systemctl is-active macprovider-coordinator'
```

---

## 4. systemd drop-in reference

File: `/etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf`

```ini
[Service]
ExecStart=
ExecStart=/opt/macprovider/coordinator \
  --config /opt/macprovider/coordinator.yaml \
  --config-overlay /etc/macprovider/coordinator.opoi-v0-staging.yaml
```

Source template: `phase4-coordinator/dist/systemd/opoi-v0.conf.example`

Base unit (unchanged): `phase4-coordinator/dist/macprovider-coordinator.service`

---

## 5. Verification (§2.5–2.6)

### 5.1 Health + version

```bash
curl -sS https://coordinator.streamvc.live/healthz | jq '{version, pool_size}'
```

Version should match the exact checked-out release tag (`vX.Y.Z`).

### 5.2 Canary logs (wait up to `canary_interval_s` = 300s)

```bash
ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 \
  'journalctl -u macprovider-coordinator --since "10 min ago" --no-pager' \
  | grep -E 'canary (passed|failed|skipped)'
```

### 5.3 Pool state (operator bearer)

```bash
# OPERATOR_KEY from /etc/macprovider/coordinator.env on Pearl
curl -sS -H "Authorization: Bearer $OPERATOR_KEY" \
  http://127.0.0.1:8444/admin/poolz \
  | jq '.providers[] | {id: .provider_id, state: .state}'
```

Pass criteria:

- [ ] Canary runs on interval for WS providers with free slots
- [ ] Log shows nonce embedded in probe (coordinator-side)
- [ ] 3 consecutive fails → degrade/ban; provider drops from routing
- [ ] Recovery pass clears sanction

### 5.4 Promote to production tuning

After 24–48h staging observation, edit overlay on Pearl:

```yaml
pool:
  canary_interval_s: 600   # 10 min production cadence
```

Then `systemctl restart macprovider-coordinator` (no binary change needed).

---

## 6. Rollback

### 6.1 Disable canaries

```bash
ssh pearl 'sudo rm /etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf \
  && sudo systemctl daemon-reload && sudo systemctl restart macprovider-coordinator'
```

### 6.2 Runtime rollback

Do not restore `/opt/macprovider/coordinator` by copying local or `.prev`
bytes. Use the signed Pearl runtime updater/rollback path for binary rollback,
then rerun the guarded deploy validation if an overlay remains enabled.

See `OPS.md` §2 and `audits/2026-06-10/ROLLBACK_PROCEDURE.md`.

---

## 7. Troubleshooting

| Symptom | Check |
|---------|-------|
| `config: unknown flag --config-overlay` | Binary predates #478 — rebuild and redeploy |
| `config: pool canary_challenges must not be empty` | Overlay missing or not loaded — check drop-in |
| No canary logs | Provider `SlotsFree==0` (skipped) or not `RoutingEligible` |
| False fails | MLX output drift — widen template or normalize match (§7 parent runbook) |
| Deploy refused exit 4 | Providers connected — use `FORCE_RESTART=1` or wait for idle window |

---

*End of runbook.*
