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
declaring success. **TBD after first M0-5/M1-6 deploy**: the exact timing of
this poll loop, and any retry/sleep tweaks discovered in practice.

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

**TBD after first M0-5/M1-6 deploy**: confirm the `.prev` filename layout
matches the script (the path was inferred from `deploy-pearl-vps.sh`
comments; the first real deploy should leave a `gateway.prev` artifact that
either confirms or amends this section).

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

The coordinator and gateway currently share an operator key:
`auth.operator_key` in both `coordinator.yaml` and `gateway.yaml` (the
gateway uses it as the bearer when calling coordinator `/internal/*`
endpoints). M3-2 will split these; until then, a rotation is a coordinated
edit:

1. Generate a fresh key:
   `head -c 32 /dev/urandom | base64`
2. Edit `/opt/macprovider/coordinator.yaml` and
   `/opt/macprovider/gateway.yaml` on Pearl — set the new key in both.
3. `sudo systemctl reload macprovider-coordinator` (SIGHUP re-reads).
4. `sudo systemctl restart macprovider-gateway` (gateway re-reads on
   start).
5. Verify: `curl -s -H "Authorization: Bearer $NEW_KEY"
   http://127.0.0.1:8444/poolz` returns the pool snapshot.

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
it as `auth.provider_token: <token>` in their `macprovider.yaml` (and
`chmod 0600 macprovider.yaml`), then restart the provider.

Stranger-tier (curl|bash open-onboarding) — currently **gated on Open
Question 2** from the audit. Two branches:

- **Operator-issued strangers:** `install.sh` prompts for a token or reads
  `MACPROVIDER_PROVIDER_TOKEN` from env.
- **Self-serve provisional:** the coordinator mints a provisional token on
  first admission and returns it via `auth_response`; the installer writes
  it back to config.

PR [#44](https://github.com/Augustas11/macprovider/pull/44)
(`feat/m1-1-self-serve-provisional-tokens`) implements the self-serve
path. Until it merges, only the pinned-tier path is documented as
production-ready. Decision log entry pending.
