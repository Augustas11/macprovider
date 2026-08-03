# Runbook: MALIBU emission Pearl deploy (Session C4)

**Version:** 0.1  
**Date:** 2026-07-08  
**Audience:** Operator  
**Parent:** [`malibu-bootstrap-emission.md`](./malibu-bootstrap-emission.md) §5  
**Prerequisite:** C1 (#480), C2 (#486), C3 (#487) merged to `main`

---

## 0. What this deploy does

| Changes | Does NOT change |
|---------|-----------------|
| Applies Postgres migrations `012_malibu_emission_ledger` + `014_malibu_trust_unlock` | `malibu_emission.enabled` (stays `false`) |
| Validates/restarts signed coordinator runtime with `writer_dsn` wired | Withdrawable MALIBU flow |
| Merges MALIBU overlay into Pearl `coordinator.pearl-overlays.yaml` | Base `/opt/macprovider/coordinator.yaml` |
| Mounts `GET /v1/provider/malibu-accrual` read API | Base nginx vhost (add `location = /v1/provider/malibu-accrual` per §4.4) |

**Operator stance (C4 staging):** accrual **read path** on, accrual **ticks** off until promotion.

---

## 1. Preconditions

- [ ] `main` includes `coordinator stats-migrate` + C3 accrual read mount
- [ ] Pearl SSH: `~/.ssh/pearl_operator_ed25519` (or `SSH_KEY`)
- [ ] Pearl host: `159.223.165.194` (`coordinator.streamvc.live`)
- [ ] `/etc/macprovider/coordinator.env` on Pearl
- [ ] OPoI canaries recommended (Session A) before enabling accrual ticks
- [ ] Prefer zero connected providers at restart, or `FORCE_RESTART=1`

### 1.1 Add Pearl env vars (one-time)

Append to `/etc/macprovider/coordinator.env` on Pearl:

```bash
# Admin DSN for stats-migrate (existing partner-keys admin role).
COORDINATOR_PARTNER_KEYS_ADMIN_DSN=postgres://...

# Runtime rewards_writer DSN (read API now; accrual worker when enabled).
MALIBU_EMISSION_WRITER_DSN=postgres://rewards_writer:...@127.0.0.1:5432/macprovider_stats?sslmode=disable

# Optional first-time login password for rewards_writer role:
MALIBU_EMISSION_WRITER_PASSWORD='generate-a-strong-password'
```

After first deploy with `MALIBU_EMISSION_WRITER_PASSWORD` set, rotate the password out of the env file (DSN already embeds the secret).

---

## 2. Quick deploy (scripted)

```bash
git checkout vX.Y.Z
cd phase4-coordinator
bash scripts/build-linux.sh
bash dist/deploy-malibu-emission-pearl.sh
```

Dry run:

```bash
DRY_RUN=1 bash dist/deploy-malibu-emission-pearl.sh
```

With providers connected:

```bash
FORCE_RESTART=1 bash dist/deploy-malibu-emission-pearl.sh
```

Migrations already applied:

```bash
SKIP_MIGRATE=1 bash dist/deploy-malibu-emission-pearl.sh
```

---

## 3. Manual steps (if not using script)

### 3.1 Production binary authority

Do not build, upload, or install coordinator binaries manually for production
MALIBU work. Production runtime bytes must come from the signed Pearl runtime
release/updater and then pass the guarded `deploy-pearl-vps.sh` provenance
checks. Manual steps below are overlay/migration reference only.

### 3.2 Apply migrations

```bash
ssh pearl 'set -a && . /etc/macprovider/coordinator.env && set +a \
  && /opt/macprovider/coordinator stats-migrate --admin-dsn "$COORDINATOR_PARTNER_KEYS_ADMIN_DSN" --check \
  && /opt/macprovider/coordinator stats-migrate --admin-dsn "$COORDINATOR_PARTNER_KEYS_ADMIN_DSN"'
```

Confirm `012_malibu_emission_ledger` and `014_malibu_trust_unlock` show `applied`.

### 3.3 Install overlay

Merge `coordinator.opoi-v0-staging.yaml` (or existing Pearl overlay) with `coordinator.malibu-emission-overlay.yaml`:

```bash
python3 dist/merge-yaml-overlay.py coordinator.opoi-v0-staging.yaml coordinator.malibu-emission-overlay.yaml \
  > /tmp/coordinator.pearl-overlays.yaml
scp /tmp/coordinator.pearl-overlays.yaml pearl:/etc/macprovider/
```

Install systemd drop-in from `dist/systemd/malibu-emission.conf.example`.

### 3.4 Validate + restart

```bash
ssh pearl '/opt/macprovider/coordinator \
  --config /opt/macprovider/coordinator.yaml \
  --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml \
  --validate-config'
ssh pearl 'systemctl daemon-reload && systemctl restart macprovider-coordinator'
```

---

## 4. Verification (C4 pass criteria)

### 4.1 Coordinator logs

```bash
ssh pearl 'journalctl -u macprovider-coordinator --since "5 min ago" --no-pager' \
  | grep -E 'malibu_emission|stats-migrate'
```

Expect: `malibu_emission DISABLED via config (default)` — read pool still opens when `writer_dsn` is set.

### 4.2 Accrual read API (provider bearer)

```bash
curl -sS -H "Authorization: Bearer $PROVIDER_TOKEN" \
  https://coordinator.streamvc.live/v1/provider/malibu-accrual | jq
```

Expect `200` with `accrued_malibu`, `trust_tier`, `trust_criteria_*`, `wallet_bound`.

### 4.3 Migration versions on Pearl Postgres

```bash
ssh pearl 'set -a && . /etc/macprovider/coordinator.env && set +a \
  && psql "$COORDINATOR_PARTNER_KEYS_ADMIN_DSN" -c \
  "SELECT version, name FROM schema_migrations_spec017 WHERE version IN (12, 14) ORDER BY version"'
```

### 4.4 Nginx allow-through (one-time)

`GET /v1/provider/malibu-accrual` lives on buyer port **8443**. Without an exact-match nginx location, the public URL returns **404**.

Install from repo template (or copy the `location = /v1/provider/malibu-accrual` block from `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`):

```bash
# On Pearl — merge block after /v1/provider/wallet, then:
nginx -t && systemctl reload nginx
```

Unauthenticated probe should return **401** (not 404):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://coordinator.streamvc.live/v1/provider/malibu-accrual
```

---

## 5. Promotion — enable accrual ticks (post-C4)

Only after §4 passes and operator accepts stance **(b) accrual-only**:

1. Edit `/etc/macprovider/coordinator.pearl-overlays.yaml` on Pearl: `malibu_emission.enabled: true`
2. `systemctl restart macprovider-coordinator`
3. Watch logs for `malibu_emission` subsystem ticks
4. Monitor `wallet_daily_malibu_emission` and provisional `withdrawal_hold_reason`

**Do not** enable withdrawable MALIBU until C1+C2 lab verification is complete on production data.

---

## 6. Rollback

### 6.1 Disable overlay (keep binary)

```bash
ssh pearl 'sudo rm /etc/systemd/system/macprovider-coordinator.service.d/malibu-emission.conf \
  && sudo systemctl daemon-reload && sudo systemctl restart macprovider-coordinator'
```

### 6.2 Freeze accrual ticks (keep read API)

Set `malibu_emission.enabled: false` in pearl overlay and restart.

### 6.3 Runtime rollback

Do not restore `/opt/macprovider/coordinator` by copying local or `.prev`
bytes. Use the signed Pearl runtime updater/rollback path for binary rollback,
then rerun the guarded deploy validation if a MALIBU overlay remains enabled.

---

## 7. Monitoring (post-promotion)

| Signal | Query / log |
|--------|-------------|
| Cap hits | `withdrawal_hold_reason = per_wallet_daily_cap` in `provider_rewards_ledger` |
| Wallet aggregate | `wallet_daily_malibu_emission` daily sums |
| Unlock rate | `provider_emission_state.trust_tier` transitions |
| Held accrual | `held_malibu` in accrual API vs withdrawable |

---

*End of runbook.*
