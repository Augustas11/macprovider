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
| `/opt/macprovider/coordinator` binary (linux/amd64) | `/opt/macprovider/coordinator.yaml` base file |
| `/etc/macprovider/coordinator.opoi-v0-staging.yaml` overlay | nginx / TLS / gateway |
| systemd drop-in with `--config-overlay` | Full `deploy-pearl-vps.sh` path |

Canaries enable via overlay only — rollback removes drop-in without editing production YAML.

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

From a clean checkout of `origin/main`:

```bash
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

### 3.1 Build binary (operator Mac)

```bash
cd phase4-coordinator
bash scripts/build-linux.sh
# → dist/coordinator-linux-amd64 @ <git describe>
```

Cross-compile only (no sidecars required for OPoI):

```bash
cd phase4-coordinator
VERSION="$(git describe --always --dirty --tags)"
GOOS=linux GOARCH=amd64 go build \
  -ldflags "-X main.version=${VERSION}" \
  -o dist/coordinator-linux-amd64 ./cmd/coordinator
```

### 3.2 Upload artifacts

```bash
SSH_KEY=~/.ssh/pearl_operator_ed25519
PEARL=root@159.223.165.194

scp -i "$SSH_KEY" dist/coordinator-linux-amd64 "$PEARL:/tmp/coordinator-linux-amd64"
scp -i "$SSH_KEY" coordinator.opoi-v0-staging.yaml "$PEARL:/etc/macprovider/"
scp -i "$SSH_KEY" dist/systemd/opoi-v0.conf.example "$PEARL:/tmp/opoi-v0.conf"
```

### 3.3 Install on Pearl

```bash
ssh -i "$SSH_KEY" "$PEARL" 'set -e
  # Binary snapshot for rollback
  if [ -x /opt/macprovider/coordinator ]; then
    install -o root -g macprovider -m 0750 \
      /opt/macprovider/coordinator /opt/macprovider/coordinator.prev
  fi
  install -o root -g macprovider -m 0750 \
    /tmp/coordinator-linux-amd64 /opt/macprovider/coordinator
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

Version should match local `git describe` from the build tree.

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

### 6.1 Disable canaries (keep new binary)

```bash
ssh pearl 'sudo rm /etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf \
  && sudo systemctl daemon-reload && sudo systemctl restart macprovider-coordinator'
```

### 6.2 Binary rollback

```bash
ssh pearl 'sudo install -o root -g macprovider -m 0750 \
  /opt/macprovider/coordinator.prev /opt/macprovider/coordinator \
  && sudo systemctl restart macprovider-coordinator'
```

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
