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
it as `auth.provider_token: <token>` in their `macprovider.yaml` (and
`chmod 0600 macprovider.yaml`), then restart the provider.

Stranger-tier (curl|bash open-onboarding) — **self-serve provisional**
is the production path per SPEC-003 v0.8.x. The coordinator mints a
fresh `provider_token` on every tokenless provisional admission and
returns it in the v1 `hello_ack` and v2 `auth_response` frames; the
binary persists it atomically to `~/.config/macprovider/macprovider.yaml`
(mode 0600). Next reconnect carries it as `Authorization: Bearer`.
No operator action is required for the open-onboarding tier under
`auth.require_provider_tokens=false`. After the flag flip (FR-C9.5
compatibility cutoff), tokenless connects are rejected at the auth
gate before admission — only tokens already issued at that point
remain valid; new strangers must onboard before the flip.

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
