# OPS.md — MacProvider production operations

> **Audience:** the on-call operator. This is the canonical operations doc for
> the live `streamvc.live` stack. Phase-1 runbooks (`RUNBOOK.md`,
> `CONTINUE_RUNBOOK.md`) are superseded — see banners on those files.
>
> **Authoring note (M2-8):** several sections below depend on procedures
> introduced by M0-5 (version-stamped builds + `.prev` rollback) and M1-6
> (scripted gateway deploy + mandatory C2 check). Those PRs are merged but
> the operator has not yet run them in production. Lines marked
> `**TBD after first M0-5/M1-6 deploy**` will be tightened against observed
> behaviour after the first real deploy on each script. Until then they
> describe the procedure as documented in the deploy-script comments and the
> `beta/DECISION_CRITERIA.md` decision log.

## 1. Production topology (Pearl VPS)

Both Go services are co-hosted on one DigitalOcean-style VPS named **Pearl**
(`/etc/hostname`: `pearl`; reachable via the operator's stored SSH key).

| Hostname | Bind | Backend | systemd unit | Audit refs |
|---|---|---|---|---|
| `coordinator.streamvc.live` | `127.0.0.1:8444` (provider port) | `phase4-coordinator` | `macprovider-coordinator.service` | nginx-coordinator.streamvc.live.conf |
| `api.streamvc.live` | `127.0.0.1:9443` | `phase5-gateway` | `macprovider-gateway.service` | nginx-api.streamvc.live.conf |
| n/a (loopback) | `127.0.0.1:8443` (buyer port) | `phase4-coordinator` | (same unit) | reached only from gateway over loopback |
| `console.streamvc.live` | static (Cloudflare Pages) | none | n/a | static `frontdoor/console/` build |
| `portal.streamvc.live` | static (`/var/www/portal/`) + nginx reverse-proxy to coordinator | n/a (static + proxy) | n/a (nginx-only) | `frontdoor/provider-portal/dist/nginx-portal.streamvc.live.conf` (decision-log Entry 86) |

Provider Macs connect outbound to `wss://coordinator.streamvc.live/ws/provider`.
Buyers hit `https://api.streamvc.live/v1/*`. Operator endpoints (`/poolz`,
`/admin/*`, `/ledger/*`) are reachable only via SSH tunnel into the VPS — they
are not exposed on the public `api.streamvc.live` nginx site (the SSL config
deliberately allowlists public paths).

External monitor: a Python `macprovider-monitor.py` runs on the same VPS as a
`systemd` timer, alerting via Gmail SMTP (see §5).

## 2. Safe coordinator restart

The scripted path is `phase4-coordinator/dist/deploy-pearl-vps.sh`. Two
guards prevent a footgun restart:

1. **Pre-deploy config drift gate (M1-6 cross-service / M0-5 phase 2).**
   Step 0 of the script runs `check-deploy-config.sh` against both
   `coordinator.yaml` and `gateway.yaml`. It HARD-fails on:
   - placeholder `operator_key`,
   - `heartbeat_miss_threshold_s < heartbeat_interval_s` (would reap live
     providers),
   - C2 violation: coordinator `routing.request_timeout_s` must be strictly
     **below** the gateway `timeouts.coordinator_request_seconds` (else a
     gateway-timeout cancel races the coordinator's relay-timeout and a slow
     non-streaming provider can escape breaker attribution).
2. **Connected-provider guard.** The script reads `/poolz` (authenticated
   with the operator key) and refuses to restart if any providers are
   currently connected, **unless** `FORCE_RESTART=1` is set in the env. The
   rationale: a coordinator restart drops every WS session and the
   `air8gb`-class flapping incident (2026-04-XX, decision-log entry 38)
   showed providers can take 60–90s to re-converge.

Procedure:

```bash
ssh pearl
cd /opt/macprovider/coordinator
sudo -u macprovider bash deploy-pearl-vps.sh        # safe path
# … or, if you accept the buyer-error window: FORCE_RESTART=1 …
```

Post-restart: the script polls `/healthz` and asserts the deployed `version`
field matches the freshly built binary (M0-5 phase 2 provenance check). A
mismatch implies the systemd unit started a stale binary; the script exits
non-zero and the operator's responsibility is to investigate **before**
declaring success.

Observed timing from the first M0-5/M1-6 production deploy (2026-06-11,
v1.3.0-24-g87b3a6b -> v1.3.1-5-gba04cd4): there is no retry loop. Step 7
does `systemctl restart` -> `sleep 3` -> `systemctl is-active` (active on
first check). Step 8 does `sleep 2` -> a single `curl --max-time 10` GET
on `https://coordinator.streamvc.live/healthz`. Total window between
restart command and the provenance assert is about 5 seconds; `/healthz`
responded immediately at `uptime_s=12` with the version field set. No
tweaks were needed.

## 3. Safe gateway restart

The scripted path is `phase5-gateway/dist/deploy-pearl-vps.sh` (added in
M1-6). Mirrors the coordinator pattern:

- **Step 0:** mandatory C2 cross-check via the shared
  `check-deploy-config.sh` (now enforced — the pre-M1-6 path treated a
  missing input as a warning, which was a real gap). `SKIP_C2_CHECK=1`
  exists as an explicit override but should not be the default path.
- **Steps 1–2:** verify the freshly built `dist/gateway-linux-amd64` and the
  systemd unit file.
- **Step 3:** snapshot the live `/opt/macprovider/gateway` binary as
  `gateway.prev` so rollback is `cp gateway.prev gateway && systemctl restart`.
- **Steps 4–7:** copy, restart, poll `/healthz`, assert version.
- **Step 8:** remote backup of `gateway.db` to the operator's stored S3-like
  bucket (M1-6 added this; without it the WAL file was unbacked).

**Rollback procedure:**

```bash
ssh pearl
cd /opt/macprovider/gateway
sudo -u macprovider cp gateway.prev gateway
sudo systemctl restart macprovider-gateway
curl -s http://127.0.0.1:9443/healthz   # confirm OK + version reflects .prev
```

Confirmed by the first M0-5/M1-6 production deploy (2026-06-11): both
services maintain a single `.prev` artifact that is overwritten on each
deploy. The coordinator deploy script (#244 R4+R5) now installs the
coordinator binary + .prev as `root:macprovider 0750` (was
`macprovider:macprovider 0755`) so a compromised daemon UID can no
longer rewrite the previous binary. The gateway deploy script has
NOT yet been hardened the same way — `gateway.prev` is still
`macprovider:macprovider 0755` until a parallel fix lands.

- `/opt/macprovider/coordinator.prev` — `root:macprovider 0750`
- `/opt/macprovider/gateway.prev` — `macprovider:macprovider 0755` (TODO: harden in parallel PR)

For the coordinator, the deploy script additionally writes a timestamped
config backup at `/opt/macprovider/coordinator.yaml.bak-<UTC>` (UTC stamp
in `YYYYMMDDTHHMMSSZ` form) before overwriting the live config. These
accumulate across deploys; operators who want to free disk should reap the
older ones after confirming a successful run.

### 3.1 Gateway DB archive-rotate (M2-4 Part C / PERF-1)

The gateway's 9 `RAISE(ABORT) BEFORE DELETE` triggers
(`phase5-gateway/internal/storage/sqlite/migrate.go:184-251`) keep the 8
event tables + `concurrency_reservations` append-only forever per the Q4
ruling (`beta/DECISION_CRITERIA.md` Entry 77, design at
`audits/2026-06-10/Q4_ARCHIVE_ROTATE_DESIGN.md`). Disk pressure on Pearl
is handled out-of-band by a rotation job that ships a clean snapshot of
`gateway.db` to cold storage on a size or age threshold, then prunes old
rows (rows older than `GATEWAY_ARCHIVE_PRUNE_DAYS`, default 7) from the
live DB while temporarily dropping + recreating the per-table
`*_no_delete` triggers inside a single `BEGIN IMMEDIATE; ... COMMIT;`
transaction.

All 9 tables are in scope. `concurrency_reservations` keeps a narrower
prune predicate (`status <> 'active'`): non-active rows older than the
cutoff are dropped, active rows are NEVER touched regardless of age.
M2-4 Part B's per-row `DeleteTerminalQuotaReservations` on
`quota_reservations` runs independently and unchanged — it handles the
quota table, which has no BEFORE-DELETE trigger.

**Files (shipped):**

- `phase5-gateway/dist/archive-rotate.sh` — the rotation script. Uses
  SQLite's `VACUUM INTO` for the snapshot (single-file, no WAL
  artifacts), compresses with `zstd` (or `gzip` if zstd is missing),
  drops a `.sha256` sidecar, optionally uploads to S3 if
  `GATEWAY_ARCHIVE_S3_BUCKET` is set and `aws-cli` is on PATH, then
  prunes the live DB. Exit codes: `0` success, `2` below threshold (no
  rotation needed — timer treats as success), `3` rotation attempted but
  live DB did not shrink (loud alert), `4` pre-flight failure.
- `phase5-gateway/dist/archive-restore.sh` — forensic-restore path.
  Verifies the `.sha256` checksum, decompresses, runs `PRAGMA
  integrity_check`, refuses if the archive's `schema_migrations` max
  version exceeds the binary's expected version (currently 3 — after
  #196 made `usage_events` PK composite and #210 made
  `demo_usage_events` PK composite), and
  installs to a tempfile target (default `/tmp/gateway-restored-<ts>.db`).
  `--to-live` does the destructive replace-the-live-DB path; requires
  `ASSUME_YES=1`. Snapshots the existing live DB to a `.pre-restore.<ts>`
  sibling before swapping.
- `phase5-gateway/dist/macprovider-archive-rotate.service` +
  `macprovider-archive-rotate.timer` — daily check at 04:00 UTC ±15 min
  jitter. Runs as `User=root` (needs `systemctl stop/start` on the
  gateway). `SuccessExitStatus=0 2` so below-threshold checks don't
  alert.
- `phase5-gateway/dist/test/archive_rotate_test.sh` — integration tests
  (T1–T6: below-threshold no-op, FORCE_ROTATE shrinks + preserves recent
  rows + leaves `concurrency_reservations` untouched, forensic-restore
  integrity, idempotent re-run, schema-mismatch refusal, append-only
  trigger restored post-prune).

**Operator install on Pearl (one-time):**

```bash
ssh pearl
# Install scripts to /usr/local/sbin (root-owned parent dir). Issue #244
# R4+R5 tightened /opt/macprovider to root:macprovider 0750 (was
# macprovider:macprovider 0755), so installing root-run scripts there
# would now actually be safe — but /usr/local/sbin is the conventional
# location for operator-installed root scripts, and the original
# audit-iter-2 reasoning (defense in depth) still applies.
sudo install -o root -g root -m 0755 archive-rotate.sh /usr/local/sbin/macprovider-archive-rotate.sh
sudo install -o root -g root -m 0755 archive-restore.sh /usr/local/sbin/macprovider-archive-restore.sh
sudo install -o root -g root -m 0644 macprovider-archive-rotate.service /etc/systemd/system/
sudo install -o root -g root -m 0644 macprovider-archive-rotate.timer   /etc/systemd/system/
# Archive dir is ROOT-owned 0700 — the gateway service (User=macprovider)
# must NOT be able to substitute or unlink compliance archives. The rotation
# job runs as root and writes here; the gateway never reads or writes it.
sudo install -d -o root -g root -m 0700 /var/lib/macprovider-gateway-archive
# /etc/macprovider/archive-rotate.env carries S3 credentials + bucket name +
# thresholds. Required keys for the default REQUIRE_REMOTE=1 mode:
#   GATEWAY_ARCHIVE_S3_BUCKET=macprovider-archives
#   AWS_ACCESS_KEY_ID=<key>
#   AWS_SECRET_ACCESS_KEY=<secret>
#   AWS_DEFAULT_REGION=<region>
# If the operator deliberately runs without cold storage (NOT recommended,
# defeats the "tamper-evident archive lives off-host" Q4 contract):
#   GATEWAY_ARCHIVE_REQUIRE_REMOTE=0
sudo install -o root -g root -m 0600 /dev/stdin /etc/macprovider/archive-rotate.env <<EOF
GATEWAY_ARCHIVE_S3_BUCKET=macprovider-archives
AWS_DEFAULT_REGION=us-east-1
# Set AWS creds here or via instance profile / IAM role.
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now macprovider-archive-rotate.timer
# Smoke-test (DRY_RUN=1 prints actions only — no service stop, no prune):
sudo DRY_RUN=1 GATEWAY_DB_PATH=/var/lib/macprovider/gateway.db \
  /usr/local/sbin/macprovider-archive-rotate.sh || true
# Verify the timer is scheduled:
sudo systemctl list-timers macprovider-archive-rotate.timer
# Tail the journal after the first natural fire (04:00 UTC + jitter):
sudo journalctl -u macprovider-archive-rotate -n 50 --no-pager
```

**Exit-3 alert response.** If the rotation script logs `exit 3` (live DB did
not shrink despite passing the size/age threshold), the archive WAS written
to cold storage but the live DB is still oversize. Investigate before the
next daily fire — typical causes are (a) no rows older than
`GATEWAY_ARCHIVE_PRUNE_DAYS` (drop the threshold), (b) an unexpected table
holding the bulk of bytes, or (c) WAL/SHM not checkpointed (force a sqlite3
PRAGMA wal_checkpoint(TRUNCATE)).

**Exit-4 cold-storage failure.** If the script logs `exit 4` with "REQUIRE_REMOTE=1
but ..." the archive snapshot succeeded locally but cold-storage upload or
readback failed; the live DB was NOT pruned and the gateway was not stopped.
Restore S3 credentials / connectivity, then re-run with `FORCE_ROTATE=1`.

**Restore (forensic):**

```bash
# Inspect an archive locally without touching the live DB.
sudo /usr/local/sbin/macprovider-archive-restore.sh \
  /var/lib/macprovider-gateway-archive/gateway-YYYYMMDDTHHMMSSZ.db.zst \
  /tmp/forensic.db
sqlite3 /tmp/forensic.db 'SELECT COUNT(*) FROM usage_events;'
```

**Restore (destructive — replaces live DB):**

```bash
sudo ASSUME_YES=1 /usr/local/sbin/macprovider-archive-restore.sh --to-live \
  /var/lib/macprovider-gateway-archive/gateway-YYYYMMDDTHHMMSSZ.db.zst
# All rows written to the live DB since the snapshot was taken are lost.
# A copy of the pre-restore live DB is left at
# /var/lib/macprovider/gateway.db.pre-restore.<ts>.
```

Document any `--to-live` use as an incident entry in
`beta/DECISION_CRITERIA.md` per the Q4 design's restore-procedure
section.

## 4. Settlement

Billing settlement is handled by `phase4-coordinator/internal/billing`:

- **Hot path** (`buyer/server.go` write closure → `billing.Store.WriteHotPath`):
  per-request settlement happens inside the same atomic SQLite transaction
  as the request_log write. A failure quarantines the row in
  `request_log_failed` rather than dropping it.
- **Nightly reconcile** (`startNightlyReconcile`): scans for any
  non-settled requests older than the configured horizon and re-runs the
  ledger math. Runs at 03:00 UTC by default.
- **Weekly settlement** (`startWeeklySettlement`): emits the per-provider
  payout summary and (in production) signs and dispatches it to operator
  payout. Runs Sundays at 03:00 UTC by default.

To run settlement manually (one-off, e.g. after a recovered outage):

```bash
ssh pearl
sudo -u macprovider /opt/macprovider/coordinator-cli run-settlement \
  --config /opt/macprovider/coordinator.yaml \
  --as-of "$(date -u +%FT%TZ)"
```

What to check after a manual run:

- `journalctl -u macprovider-coordinator -n 200 | grep settlement` — no
  errors, expected provider count present.
- `/admin/ledger/snapshot` returns the settled rows; the per-provider
  totals match the previous unsigned snapshot ± deltas from the manual
  run window.

## 5. Monitor alert response

`phase4-coordinator/dist/monitor/macprovider-monitor.py` watches the live
stack and emits Gmail alerts. State machine (per the M0-4 fix):

| Transition | Meaning | First action |
|---|---|---|
| `OK → ALERTING` | A probe failed; SMTP send succeeded | `journalctl -u macprovider-monitor -n 100`; check `/healthz` for both services |
| `OK → ALERTING` then **state stays OK** | SMTP send failed; M0-4a preserves OK state so the next retry can fire (pre-M0-4 it incorrectly latched ALERTING) | check Gmail app-password validity; the next monitor tick will retry |
| `ALERTING → OK` | Recovery observed | confirm root cause; if unknown, capture `journalctl` window for postmortem |

Key journals during an incident:

```bash
journalctl -u macprovider-coordinator -n 200 --no-pager
journalctl -u macprovider-gateway -n 200 --no-pager
journalctl -u macprovider-monitor -n 100 --no-pager
ss -ltnp | grep -E ':844[34]|:9443'      # check both services are bound
curl -s http://127.0.0.1:8444/healthz; echo
curl -s http://127.0.0.1:9443/healthz; echo
```

**Caveat:** the monitor runs on the **same VPS** as the services it watches
(see audit DEVE-2 / §3.1 item 4). A Pearl outage is structurally invisible
to it — alerts only fire while the VPS is up. An external uptime check is a
known M3 follow-up.

## 6. Key rotation

Post M3-2 (PR #73 + codex fixup), **three bearer-token classes** are in
play:

- `auth.operator_key` in `coordinator.yaml` — human-admin credential.
  Accepted by `/admin/blacklist`, `/admin/promote`, `/admin/reject`,
  `/admin/provisional`, `/poolz`, `/admin/ledger/*`,
  `/admin/explorer/*`. The codex PR #73 HIGH-1 fix scoped these to
  operator-key-only so a compromised gateway cannot pivot to
  human-admin power.
- `auth.gateway_service_token` in `coordinator.yaml` — service-to-service
  credential the coordinator accepts on `/internal/routing` and
  `/internal/sticky`. The operator key is ALSO accepted on those paths
  as a backward-compat fallback until the cutover gate is met (see
  `audits/2026-06-10/M3-2_LEGACY_FALLBACK_REMOVAL.md`).
- `coordinator.service_token` in `gateway.yaml` — outbound credential
  the gateway sends on upstream `/internal/*` calls.

Both coordinator-side fields support `env:NAME` indirection and now
fail closed on missing/empty env var (codex PR #73 MED fix); the
gateway side fails closed on the same pattern as of the same fix.

### Post-M3-2 cutover procedure (one-time per fleet)

1. Generate a fresh service token:
   `openssl rand -hex 32`
2. On Pearl, append it to `/etc/macprovider/coordinator.env` as
   `GATEWAY_SERVICE_TOKEN=<value>` (root:macprovider 0640) — see step
   6.1 below.
3. Push the same value to each gateway's `gateway.yaml`
   `coordinator.service_token` (also via env: indirection if the
   gateway uses systemd-environment plumbing).
4. `sudo systemctl restart macprovider-coordinator` so the coordinator
   reads `gateway_service_token` from startup auth config.
5. Restart each gateway so it sends the new service token upstream.
6. Watch the audit log on the BRIDGE paths only — `/internal/*`:
   ```
   journalctl -u macprovider-coordinator -f | \
     grep -E 'internal_bearer_accepted.*"path":"/internal/'
   ```
   Look for `"key":"service_token"` on every gateway-origin
   `/internal/*` hit. (The bridge paths are `/internal/routing` and
   `/internal/sticky`; they fire on buyer disclosure + sticky-route
   maintenance.)
7. After **24h of zero** `"key":"operator_key"` on gateway-origin
   `/internal/*` hits, rotate the legacy `operator_key` (steps below).
   Cutover-countdown one-liner:
   ```
   journalctl -u macprovider-coordinator --since "24h ago" | \
     grep -E 'internal_bearer_accepted.*"key":"operator_key".*"path":"/internal/' | \
     wc -l    # must be 0 before rotating
   ```
   Admin tooling needs the new operator key; gateways do not, since
   they are now on service token.

   **Note on `/poolz`:** the gateway polls `/poolz` every 10s for
   pool-state caching. `/poolz` is an admin-scoped endpoint (per
   codex PR #73 HIGH-1 fix) so its bearer is `operator_key` —
   forever. That is by design: `/poolz` audit-log lines with
   `"key":"operator_key","path":"/poolz"` are NOT cutover-blocking
   and must be excluded from the countdown grep above.

### Rotating `operator_key` (human admin)

1. Generate a fresh key:
   `openssl rand -hex 32`
2. Edit `/opt/macprovider/coordinator.yaml` (or
   `/etc/macprovider/coordinator.env` if env-resolved) — set the new
   key.
3. `sudo systemctl restart macprovider-coordinator`. SIGHUP reloads only
   selected Tier-2/billing config; auth material and provider-token bootstrap
   flags are read at process start.
4. Verify: `curl -s -H "Authorization: Bearer $NEW_KEY"
   http://127.0.0.1:8444/poolz` returns the pool snapshot.

### 6.1 `coordinator.env` permissions

`/etc/macprovider/coordinator.env` holds `OPERATOR_KEY` and (optionally)
`GATEWAY_SERVICE_TOKEN`. It is read by the coordinator unit (running
as root → drops to macprovider via `User=`) and by the de-rooted
monitor unit (running as macprovider). The required mode is **0640
root:macprovider**. The deploy script enforces this when the file is
present (codex PR #73 LOW fix). If you create the file by hand:

```bash
sudo install -o root -g macprovider -m 0640 /dev/null /etc/macprovider/coordinator.env
sudoedit /etc/macprovider/coordinator.env
```

For **provider tokens** (M1-1 pinned-tier path, audit XSEC-1): the
operator-issued tokens are stored hashed in the coordinator's `auth.tokens`
table. To revoke a compromised token:

```bash
ssh pearl
sudo -u macprovider /opt/macprovider/coordinator-cli revoke-token \
  --config /opt/macprovider/coordinator.yaml \
  --provider-id <ID>
# then ask the provider operator to re-install with a freshly issued token
```

## 7. Common incidents (from `beta/DECISION_CRITERIA.md`)

Each incident below has a corresponding decision-log entry; consult that
file for the full forensic trail.

| Symptom | Likely cause | First action |
|---|---|---|
| All providers stop heartbeating within ~35–90s of restart | Pre-M1-2 / pre-v1.1.7 coordinator kill timer (35s) or pre-v1.2.x gateway 120s timeout | Confirm coordinator + gateway versions via `/healthz`. v1.1.7+ coordinator + scripted-deploy gateway resolves this. |
| Single provider flaps (connect → 90s of silence → reap → reconnect) | "Machine sleep" or Wi-Fi NAT drop on the Mac side | `journalctl -u macprovider-coordinator -n 200 \| grep <provider_id>`. If pattern repeats, ask the operator to disable App Nap / set a `pmset noidle` on the provider Mac. |
| Coordinator OOM (Pearl is RAM-constrained) | A long admin query holding a SQLite handle | `sudo systemctl restart macprovider-coordinator` is the immediate mitigation; investigate the explorer/admin query that ran around the OOM time. M2-2 (swap-audit off the pool lock) and M2-5 (bounded seenModels) reduce the steady-state memory pressure. |
| Gateway restart drops in-flight chat requests | Buyer requests holding the HTTP server were not given grace | The scripted deploy uses a 10s shutdown context (`cmd/gateway/main.go`). For a planned restart, schedule during a quiet window observed via `monitor.py` request graph. |
| `/v1/usage` is slow during admin explorer load | Pre-M2-4 path: explorer + usage shared one capped DB handle | Confirm gateway is on M2-4-or-later (look for `read-only storage` log line at startup). If on older, restart during quiet window. |
| A provider that mints a self-serve token cannot reconnect; coordinator log shows `event=fr_c9_4_tofu_reject` or `event=fr_c9_4_self_heal` | FR-C9.4 TOFU gate fired on tokenless reconnect | See **§9. FR-C9.4 lockout recovery** below — the self-heal path is automatic in v0.8.3; the strict-reject path needs `coordinator-cli revoke-token`. |

## 8. Provider provisioning

Pinned-tier (operator-issued tokens — M1-1):

```bash
ssh pearl
sudo -u macprovider /opt/macprovider/coordinator-cli issue-token \
  --config /opt/macprovider/coordinator.yaml \
  --provider-id <ID>
# Capture the show-once token output; it is hashed in the DB and cannot be
# retrieved again.
```

Send the token to the provider operator over a secure channel; they place
it as top-level `provider_token: <token>` in their macprovider config
(normally `~/.config/macprovider/config.yaml`, mode 0600), then restart
the provider.

Stranger-tier (curl|bash open-onboarding) — **self-serve provisional**
is the production path per SPEC-003 v0.8.x. The coordinator mints a
fresh `provider_token` on the first tokenless provisional admission and
returns it in the v1 `hello_ack` and v2 `auth_response` frames; the
binary persists it atomically to top-level `provider_token:` in
`~/.config/macprovider/config.yaml` (mode 0600). Next reconnect carries
it as `Authorization: Bearer`.

Production public onboarding MUST run both:

```yaml
auth:
  require_provider_tokens: true
  allow_tokenless_provisional_bootstrap: true
```

`auth.require_provider_tokens=true` remains the closed baseline for
normal provider reconnects. `auth.allow_tokenless_provisional_bootstrap=true`
is the narrow public-onboarding exception that lets only the first
tokenless provisional connect reach the self-serve mint / TOFU path.
Pinned providers and provider IDs whose active token has already been
used still fail closed on tokenless reconnect. Invite-only or
operator-preprovisioned deployments may set the bootstrap flag to
`false`, but then clean public `curl|bash` installs will not join
without a manually issued token.

Per SPEC-003 v0.8.1, two tokens MUST NOT exist for the same
`provider_id` simultaneously. The v0.8.2 partial unique index
`idx_provider_tokens_one_active_per_provider` enforces this at the
DB layer. The v0.8.3 unused-token self-heal handles the deploy-gap
case automatically; the strict-reject case is documented in §9 below.

## 9. FR-C9.4 lockout recovery

A provider that fails to authenticate after a deploy or a manual
config change typically falls into one of two FR-C9.4 paths. The
coordinator log line is the canonical signal — `journalctl -u
macprovider-coordinator -n 200 \| grep fr_c9_4` shows which path
fired.

### 9.1 Self-heal path (v0.8.3+, in-band recovery)

**Log fingerprint:** `event=fr_c9_4_self_heal provider_id=<id>`,
message `FR-C9.4 self-heal: revoked existing unused token for this
provider_id; proceeding to mint a fresh one`.

**What happened:** the provider had a row in `provider_tokens` with
`last_used_at IS NULL` (never authenticated since issuance — the
deploy-gap shape). The coordinator atomically revoked it and minted
a fresh token in the same admission path. The binary's next
ack-frame carries the new token under `assigned_provider_token` and
persists it. No operator action required.

**When to investigate anyway:** if the same `provider_id` triggers
`fr_c9_4_self_heal` repeatedly across several connects, the binary
is NOT persisting the assigned token between connects. Check the
provider's `~/.config/macprovider/macprovider.yaml` — the top-level
`provider_token:` key must be present after a successful connect.
File permissions must be 0600 owned by the user running the binary.

### 9.2 Strict-reject path (v0.8.1+, operator action required)

**Log fingerprint:** `event=fr_c9_4_tofu_reject provider_id=<id>`,
message `FR-C9.4 TOFU: tokenless connect refused; an active USED
token already exists for this provider_id`. WS close code
`CloseInvalidToken` / reason `invalid_token`.

**What happened:** the provider had a row in `provider_tokens` with
`last_used_at IS NOT NULL` (the token has authenticated at least
once) AND the binary is presenting no `Authorization: Bearer` on
reconnect. This shape is INDISTINGUISHABLE from the codex MAJOR-1
credential-capture attack the v0.8.1 TOFU rewrite closed; the
coordinator MUST NOT mint a parallel token automatically. Operator
intervention is the trust signal that distinguishes the legitimate
provider from an attacker.

**Recovery (the legitimate-provider case):**

```bash
ssh pearl

# 1. Identify the active token. The output is a TSV row per
#    token — id, prefix, provider_id, name, created_at, status,
#    last_used. Find the prefix for the locked-out provider_id
#    where status=active.
sudo -u macprovider /opt/macprovider/coordinator-cli list-tokens \
  --db /var/lib/macprovider/coordinator.db | grep -F <provider_id>

# 2. Revoke the active row. The 12-hex prefix is enough; use the
#    same prefix shown in step 1.
sudo -u macprovider /opt/macprovider/coordinator-cli revoke-token \
  --db /var/lib/macprovider/coordinator.db \
  --token-prefix <12-hex-prefix>

# 3. Tell the provider operator to restart their macprovider service.
#    On their next connect, the FR-C9.4 gate sees no active row and
#    proceeds to FR-C9.1 mint — the binary writes the fresh token to
#    macprovider.yaml and uses it on the connect after that.

# 4. Verify on the coordinator side. The first connect after revoke
#    should log:
#      event=fr_c9_1_self_serve_mint provider_id=<id> ...
#    (self-heal does NOT fire because there is no active row at all,
#     not because the existing row was unused.)
journalctl -u macprovider-coordinator -n 50 -f | grep -F <provider_id>
```

**The attacker case:** the same shape can be an attacker declaring a
victim's `provider_id` on a tokenless connect to harvest a fresh
bearer. Do NOT run the recovery above if the operator cannot
out-of-band confirm the request to restart came from the actual
provider. Confirm via the contact channel established at admission
time (Slack DM, email reply chain, etc.). If unconfirmable, leave
the row in place and document the lockout — the legitimate provider
will eventually escalate.

**Fallback (CLI not yet on Pearl):** sqlite3 direct UPDATE is
equivalent to `revoke-token` semantically. Use ONLY if
`coordinator-cli` is not present on this Pearl host (which is the
case for any host that hasn't been redeployed since this milestone):

```bash
# Identify
ssh pearl "sudo -u macprovider sqlite3 /var/lib/macprovider/coordinator.db \
  \"SELECT id, token_prefix, provider_id, datetime(created_at), datetime(last_used_at) \
    FROM provider_tokens WHERE provider_id='<id>' AND revoked_at IS NULL;\""

# Revoke
ssh pearl "sudo -u macprovider sqlite3 /var/lib/macprovider/coordinator.db \
  \"UPDATE provider_tokens \
      SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') \
    WHERE provider_id='<id>' AND revoked_at IS NULL;\""
```

The sqlite3 path bypasses the CLI's prefix-uniqueness assertion; if
multiple active rows somehow exist for the same `provider_id` (which
should be impossible since v0.8.2's partial unique index), the
`UPDATE` will revoke them all in one statement, which is the
operator's intent.

### 9.3 Routine token hygiene

Two `coordinator-cli` subcommands belong on a quarterly hygiene
cycle (or any time the operator notices unused tokens accumulating):

```bash
# Dry-run: list candidate prunes (default cutoff 168h = 7 days)
sudo -u macprovider /opt/macprovider/coordinator-cli prune-tokens \
  --db /var/lib/macprovider/coordinator.db \
  --older-than 168h

# Apply (after reviewing the dry-run output)
sudo -u macprovider /opt/macprovider/coordinator-cli prune-tokens \
  --db /var/lib/macprovider/coordinator.db \
  --older-than 168h \
  --apply
```

Prune-tokens (per SPEC-003 v0.8.2 hardening) refuses cutoffs younger
than 24h without `--force` — a self-minted token is
`last_used_at IS NULL` until the binary completes its first
authenticated reconnect, which can be seconds to minutes after
issuance under bad-network conditions. A naive `--older-than 0s
--apply` during a settling window would brick the active
first-session provider.

`list-tokens` is read-only and safe to run any time; the output is
a TSV that pipes cleanly into `awk` / `grep` / `column`.

## 10. SPEC-017 Network Stats API — operator runbook

SPEC-017 v0.1.8 ships the public Network Stats API at
`https://stats.streamvc.live/v1/stats/{overview,leaderboard,health}`.
The handler is in-process (same `coordinator` binary), the rollup
runs on a per-table cadence, and nginx fronts the public surface
with rate-limit + cache directives per BUILD §2 Step 4.B.

### 10.1 Rotating a partner key

```bash
# Issue a successor. stdout is EXACTLY ONE raw mpk_* token line
# (AC-17 contract); the operator-facing metadata (`id=... label=...
# prefix=... ...`) lands on stderr. If invoking under
# systemd-run / journalctl, set `--token-out /tmp/partner-rotated.token`
# (mode 0600) instead and stdout will be empty.
#
# `--config` MUST be passed explicitly: a manual `sudo -u
# macprovider /opt/macprovider/coordinator ...` invocation does
# NOT inherit the systemd unit's WorkingDirectory or env file
# (see macprovider-coordinator.service); without `--config` the
# CLI looks for the relative path `coordinator.yaml` in the
# current working directory and fails to resolve the admin DSN.
#
# PRODUCTION issuance: the gate is CONFIG-DRIVEN, not flag-
# driven (ARCH r3 + CODE r3 closure). The deployed
# `coordinator.yaml` sets
# `stats.partner_keys.production_signoff_path: /opt/macprovider/spec017-signoff.txt`
# on the production Pearl deploy. The CLI reads that file
# before any INSERT and refuses issuance if the file is
# missing, empty, or malformed. Record the sign-off per §10.5
# below — the act of writing the file IS the gate. Staging
# deploys MUST NOT set production_signoff_path; the field
# absence is the staging signal.
sudo -u macprovider /opt/macprovider/coordinator partner-keys issue \
  --config /opt/macprovider/coordinator.yaml \
  --label "ACME inc rotated 2026-09-01" \
  --rotate-from 17

# Operator-decided overlap window (default suggestion: 7 days). After
# the partner confirms they've cut over, revoke the predecessor:
sudo -u macprovider /opt/macprovider/coordinator partner-keys revoke \
  --config /opt/macprovider/coordinator.yaml \
  --id 17 --reason "rotation completed"
```

The predecessor row stays `revoked_at = NULL` after the new issue —
revoking is a separate operator action. Both keys unlock the partner
projection until the revoke fires.

**If this fails:** if the `issue` command exits non-zero AFTER the
INSERT (e.g. operator's terminal closed during the stdout print, or
`--token-out` file write failed), the CLI's stderr names the orphan
row id and the exact `revoke` command to run before re-issuing. If
`revoke` itself fails, inspect via `coordinator partner-keys list`
to confirm the row state and re-run with the correct id.

### 10.2 Revoking a partner key in incident

```bash
# Takes effect on the next request (no in-memory cache).
# `--config` MUST be passed explicitly (see §10.1 note).
sudo -u macprovider /opt/macprovider/coordinator partner-keys revoke \
  --config /opt/macprovider/coordinator.yaml \
  --id 23 --reason "key suspected exposed in <PARTNER>'s GitHub repo"
```

The next request bearing this token returns 401 with the §5.9
`unauthorized` envelope. Existing in-flight requests complete.

**If this fails:** the CLI returns `no row with id=N` when the id
doesn't exist OR `id=N was already revoked at <ts>` if it had been
previously revoked — both are clean exits and require no further
action. If `revoke` returns a Postgres connection error, fix the
admin DSN / connectivity and re-run; the revoke is idempotent.

### 10.3 Restarting the rollup scheduler after a panic-restart loop

The Step 2 runner recovers per-tick panics in-place; the goroutine
continues at the next interval. A persistent panic surface indicates
a rollup-code bug; mitigation is to disable the offending component
via the `stats.rollup.<component>_interval = 0` config knob and
investigate before re-enabling.

```bash
# Check which component is panicking
sudo journalctl -u macprovider-coordinator -n 200 | grep stats_rollup_panic

# Disable the offending component, restart, file an issue
sudo nano /opt/macprovider/coordinator.yaml   # set the interval to 0
sudo systemctl restart macprovider-coordinator
```

**If this fails:** if the coordinator process itself crashed (not
just one rollup tick), systemd auto-restarts via the unit's
`Restart=on-failure` directive — confirm with `systemctl status
macprovider-coordinator`. If the unit enters a tight restart
loop, disable it (`systemctl disable --now macprovider-coordinator`)
and investigate offline before re-enabling.

### 10.4 Emergency provider-visibility revert (operator-only)

If a provider's `exact` visibility setting was clearly opted-in by
mistake (e.g. legal/safety incident), the operator may flip the row
back to `bucketed` with an audit trail:

```bash
# `--config` MUST be passed explicitly (see §10.1 note).
sudo -u macprovider /opt/macprovider/coordinator visibility revert \
  --config /opt/macprovider/coordinator.yaml \
  --id <provider_id> \
  --reason "incident IR-2026-09 — leaked exact $ via public scrape"
```

The CLI HARDCODES `new_mode='bucketed'` and `actor_kind='operator'`;
there is NO operator path to write `mode='exact'`. The
`bucketed → exact` direction is exclusively the SPEC-014 v0.9
provider-authenticated portal flow.

`coordinator visibility exact ...` hard-rejects with a clear
operator-redirect message. AC-20 CI assertion catches any
`new_mode='exact' AND actor_kind='operator'` row in
`provider_visibility_audit` on every PR.

**If this fails:** the CLI prints `no provider_visibility row for
id=<X>` when the provider has never opted into `exact` (default is
`bucketed` — nothing to revert) OR `id=<X> is already 'bucketed'
(nothing to revert)` for the same row twice. Both are clean exits
and write nothing. If `revert` fails with a Postgres error, fix
the admin DSN and retry — the whole revert runs in one
transaction, so no partial state exists.

### 10.5 Partner-key exact-dollar exposure — provider disclosure obligation

Per SPEC-017 §6.6.2 (v0.1.7-tightened to a hard launch-sequencing
MUST):

> Trusted partners with an operator-issued API key see every
> provider's exact earnings figures (`earnings_usd`,
> `earnings_work_usd`, `earnings_rewards_usd`), even when the
> provider's public mode is `bucketed`.

Providers MUST be informed of this exposure at onboarding time.
SPEC-014 v0.9 owns the in-portal disclosure; until that surface
ships, this OPS.md section is the authoritative copy.

#### Cutover-runbook gate (BLOCKING for first PRODUCTION partner-key issuance)

The operator MUST NOT issue any partner key against the production
coordinator until ALL THREE conditions are satisfied on
`portal.streamvc.live`:

1. SPEC-014 v0.9 has merged AND is deployed to
   `portal.streamvc.live`.
2. The §6.6.2 disclosure copy above is shown on the
   provider-account-creation page AND on a static portal page
   that every existing provider sees on their next portal login.
3. This runbook contains a signed-off entry naming the SPEC-014
   v0.9 commit SHA + the date both disclosure surfaces went live.

Staging keys against staging coordinators for AC fixtures or partner
integration dry-runs are EXEMPT. Staging keys MUST NOT be returnable
from a production coordinator response.

#### Sign-off template

```
PARTNER-KEY PRODUCTION ISSUANCE SIGN-OFF — SPEC-017 v0.1.8 §6.6.2

SPEC-014 v0.9 commit SHA       : <fill: 40-char SHA>
SPEC-014 v0.9 portal deploy date: <fill: YYYY-MM-DD>
Provider-creation disclosure live: <fill: YES/NO + date>
Existing-provider disclosure live: <fill: YES/NO + date>
Operator name + role            : <fill: e.g. "augstar — sole operator">
Signed off at                   : <fill: ISO 8601 UTC>
```

**Current status (2026-06-26): NOT YET SATISFIED.** SPEC-014 v0.9
disclosure deployment is the remaining cutover prerequisite before
any production partner-key issuance. The Step 4.C PR may merge
with this template in place; the live sign-off is the operator-side
gate executed AFTER the merge.

## 11. Operator-side provider watchdog (issue #189 / #191)

Every install of `macprovider-cli` via the public
`get.streamvc.live/install.sh` flow now ships an external LaunchAgent
that catches a class of silent half-open-TCP wedge originally tracked
in issue #189 (the in-process bounded send + Darwin.exit(1) liveness
watchdog landed in PR #204 prevents the wedge on fresh builds; this
external watchdog is the belt-and-suspenders insurance for operators
on older binaries and a long-tail catch for any future regression).

### What it does

`~/.local/share/macprovider-watchdog/watchdog.sh` runs every 60s via
launchd (label `live.streamvc.macprovider-watchdog`). It:

1. Reads the operator's `provider_id` from
   `~/.config/macprovider/config.yaml`.
2. Resolves `coordinator.streamvc.live` via dscacheutil (with `host`
   fallback).
3. Runs `netstat -an -p tcp` and looks for an ESTABLISHED outbound
   row to `<coord_ip>.443`.
4. If absent, runs
   `launchctl kickstart -k gui/$UID/live.streamvc.macprovider` to
   restart the provider LaunchAgent.

Healthy ticks are silent so the log file does not bloat. Detection
ticks and kicks write to `~/Library/Logs/macprovider/watchdog.log`.

### Recovery target

- **Detection latency**: ≤60s after a previously-armed connection
  drops (one tick interval). The watchdog stays disarmed until it
  has observed at least one healthy ESTABLISHED connection, so a
  cold-start install with a 10-20 min model load is NOT killed
  prematurely.
- **Post-kick grace**: ≥300s between kicks
  (`MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS`), so a launchd
  respawn that triggers a model reload is not re-kicked while it
  is still warming back up.
- **End-to-end recovery (wedge → ESTABLISHED again)**: typically
  ≤75s on a warm model (kick + launchd respawn + cached model load
  + reconnect). Cold-cache adds the full model-load window (often
  10-20 min); the grace period is sized to absorb that.
- **Known limitation**: the netstat check matches *any* local
  ESTABLISHED connection to `coordinator.streamvc.live.443`, not
  specifically the provider's process. A separate process (a
  browser tab on the portal, another shell with curl, etc.)
  holding a long-lived connection to the coordinator host can mask
  a wedged provider. Tightening this to the provider's PID via
  `lsof` is tracked as future work — for the current fleet a
  spurious 443 connection to coord is rare on operator macs.

### Install

Automatic via the public installer (`curl -fsSL get.streamvc.live/install.sh | sh`).
To install or re-install manually from the repo:

```bash
bash ops/macprovider-watchdog/install.sh
```

Set `MACPROVIDER_NO_WATCHDOG=1` on the main installer's env to skip
the watchdog (expert / debug override only).

### Inspect

```bash
launchctl list | grep live.streamvc.macprovider-watchdog
cat ~/Library/Logs/macprovider/watchdog.log
```

To force a tick out-of-cadence (useful for testing the kick path
without waiting 60s):

```bash
launchctl kickstart -k gui/$UID/live.streamvc.macprovider-watchdog
```

### Uninstall

The main provider uninstaller (`phase3-binary/dist/uninstall.sh`)
removes the watchdog alongside the provider. To remove the watchdog
alone (e.g. to disable it on a specific Mac without touching the
provider):

```bash
bash ops/macprovider-watchdog/uninstall.sh
```

### Failure modes the watchdog does NOT catch

- **Provider connected but silently dropped from the coordinator's
  `ready` pool.** Different failure mode: TCP is ESTABLISHED but the
  coordinator no longer routes inference. Polling
  `/v1/models` server-side from the watchdog was scoped out of #191
  pending evidence we see this happen in production; for now the
  in-process liveness watchdog (#189 / PR #204) is the primary
  detection path.
- **macprovider-cli process not running at all.** launchd's
  `KeepAlive` on the main service handles this; the watchdog only
  helps when the process is running but its WebSocket is wedged.
