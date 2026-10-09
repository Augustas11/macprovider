# Trusted Pool production launch (SPEC-043) — turnkey operator checklist

Ordered, push-button steps to take a single-operator Trusted Pool from
pre-announce to a promoted production pool. This is the launch sequence; the
policy, fail-closed semantics, and emergency controls live in
[`trusted-pool-creator-launch.md`](trusted-pool-creator-launch.md) — read that
first. Issue: https://github.com/Augustas11/macprovider/issues/1233.

Buyer-facing wording is **Trusted Pool**. Do not call it a Privacy Pool,
coordinator-blind, anonymous, ZK, or regulated-compliance product. Executing
this runbook is a deliberate launch decision that exits the pre-announce pilot
policy; do not run it as a routine operation.

## 0. Decision gate (before any step)

Confirm all of the following, or stop:

- A named operator owns this launch and the on-call rotation.
- The creator is an approved single-operator creator (SPEC-043-R001), membership
  is the creator's own admitted Macs only, buyers are on dedicated
  pool-authorized accounts, and distribution is reviewed-only.
- Settlement is `enforce`: pool requests settle through SPEC-022 R-12 with
  v0.4 pool-authorized receipts, and a policy core with a non-empty
  `runtime_allowlist` must be `enforce` (SPEC-042-R001). There is no creator
  revenue split: `split_execution_status` remains `declared_not_executed`.
  Before launch, a settled enforce-mode pool journey (receipt `verified`,
  provider ledger credit) must exist on the production build; on 2026-10-06
  it did not (#1690 BUG-1/BUG-2).
- An operator-internal pool that never leaves `launch_environment:
  candidate` does not use this runbook; follow
  [`trusted-pool-m1-activation-plan.md`](trusted-pool-m1-activation-plan.md).
- You accept the residual launch blockers still open on #1233 (full R006
  re-verification, unresolved SPEC-042 rows) or have an explicit written
  decision to carry them.

The coordinator admin surface is served on the **provider port** (`:8444`),
authenticated with the coordinator `OPERATOR_KEY`. On Pearl the operator key
lives in `/etc/macprovider/coordinator.env`; run admin CLI/HTTP from the host so
the key never leaves it. The examples below use `coordinator-cli`
(`--admin-url http://127.0.0.1:8444`, `--operator-key-env MACPROVIDER_OPERATOR_KEY`).

## 1. Mint and register the on-call operations authority

The on-call authority key follows the production-release key custody model: only
the public half is committed; the private half lives solely in the GitHub
`production-release` environment secret. The committed keyring
`security/spec-043-oncall-authority-ed25519-keyring.json` ships empty and
fail-closed.

1. Generate an Ed25519 key you control and provision the private half into the
   `production-release` environment secret
   `MACPROVIDER_SPEC043_ONCALL_AUTHORITY_SIGNING_KEY_PEM` — mirror
   `scripts/provision-spec043-production-release-key.sh` (generate in a
   mode-0700 tmp dir, pipe the private PEM straight into `gh secret set`, keep
   only the public half). **Never commit or log the private key.**
2. Register the public half and capture the deploy digest:

   ```bash
   python3 scripts/register-spec043-oncall-authority-key.py \
     --public-key <operator-public-key.pem> \
     --valid-from <UTC start> \
     --valid-until <UTC end>
   # prints MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256=<digest>
   ```

   Commit `security/spec-043-oncall-authority-ed25519-v1.pem` and the updated
   keyring through review. `--check` re-derives the digest and fail-closes if no
   key is registered.
3. Set `MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256=<digest>` in the
   coordinator launch environment (Pearl `/etc/macprovider/coordinator.env`) and
   restart the coordinator so it allowlists the key.

## 2. Sign and store the on-call readiness record

Signing happens in CI so the private key never reaches an operator shell.

1. Dispatch `.github/workflows/build-signed-oncall-readiness.yml` from `main`
   (manual dispatch, `production-release` environment) with the launch
   environment id, record version, operator contacts, break-glass path,
   compromise channel, agreement-notification ack, creator emergency mechanism,
   and `confirmation_ttl_seconds` (≤ 7776000 / 90 days). The workflow runs the
   keyring `--check`, `verify-github-release-posture.sh`, signs with the env
   secret, verifies the signed record binds the registered key digest, and
   uploads `oncall-readiness.signed.json`.
2. Download the artifact and store it with the operator key:

   ```bash
   coordinator-cli trust-pool-oncall upsert \
     --admin-url http://127.0.0.1:8444 \
     --json-file oncall-readiness.signed.json
   coordinator-cli trust-pool-oncall get \
     --admin-url http://127.0.0.1:8444 \
     --launch-environment-id <launch_environment_id>
   ```

Missing or expired on-call fail-closes operator production promote
(`on_call_readiness_rejected`, 409). Re-confirm on every on-call rotation change;
the record expires at `last_confirmed_at + confirmation_ttl`. An upsert
republishes the routing registry immediately, so a shortened or replaced record
takes effect on the next request (a failed republish returns
`registry_refresh_failed` and disables pool routing until the refresher
succeeds).

## 3. Enable production activation config

Configure `trusted_pools` on the production coordinator (requires
`coordinator.require_gateway_context=true`):

```yaml
trusted_pools:
  enabled: true
  refresh_interval_s: 30
  manifest_acceptance_witness_path: /var/lib/macprovider/trustpool-manifest-witness.json
  production_activation:
    allowed_launch_environments: ["<non-candidate launch env>"]
    evidence_sha256: "<lowercase sha256 of the signed launch evidence>"
    root_custody_hashes: ["<lowercase sha256 root-custody disclosure hash>"]
    root_custody_classes:
      "<same hash>": "<hsm | mpc | other>"
```

Every approved custody hash needs a class. `software` is rejected until a
signed-exception path exists. A coordinator with `production_activation` set
never promotes or routes a pool whose root `launch_environment` is `candidate`.

`production_activation` is default-blocked: absent or mismatched config keeps the
fail-closed `launch_environment_not_candidate` behavior. Restart the coordinator
after the config change. On a coordinator that already has accepted manifests,
add `manifest_acceptance_witness_path` only through §3a.

### 3a. Bootstrap the manifest-acceptance witness (coordinator with accepted manifests)

`manifest_acceptance_witness_path` is startup-only (a SIGHUP that changes it is
rejected). When the file is missing while `coordinator.db` already holds
accepted-manifest high-water (Pearl has accepted pool manifests), startup does
**not** crash: `loadTrustedPools` logs `trusted pools durable migration failed;
pool support disabled` and the coordinator keeps serving with **every trusted
pool disabled** while `/healthz` still answers. So write the first witness
explicitly, then prove pools still route after the restart.

The bootstrap is **trust-on-first-use of the live DB**: the witness records
whatever high-water `coordinator.db` holds at that moment. Run it only on the
live host, never after any `coordinator.db` restore (an updater rollback
included) until the restore's re-apply step in §9 "Carried risk: whole-database
rollback" is done, and only inside one locked step that also edits the config
and restarts. No manifest submission, pool admin write, updater run, or DB
restore may happen between the bootstrap and the restart: hold both Pearl locks
for the whole step, and be the only Pearl actor.

`manifest-witness-init` takes no DB path. It loads the same `--config` /
`--config-overlay` the coordinator unit uses, reads `storage.db_path` from it
(which must be absolute), opens that DB read-only, writes `--out` (absolute;
must not exist; must equal `trusted_pools.manifest_acceptance_witness_path` if
the config already sets it) with mode `0600`, and prints `db=`, `witness=`,
`pools=` and one line per pool with `manifest_version`, `operation_id`,
`accepted_at_utc` and a `manifest_core_digest` prefix. The subcommand ships
with the coordinator release that carries it; an older `coordinator-cli`
answers `unknown trust-pool-admin subcommand`.

Before the step, stage the new overlay at
`/etc/macprovider/coordinator.pearl-overlays.yaml.witness`: the live overlay
plus only `trusted_pools.manifest_acceptance_witness_path:
/var/lib/macprovider/trustpool-manifest-witness.json`, edited with a YAML tool
and reviewed with `diff`. Then, as one locked step:

```bash
ssh pearl sudo bash -s <<'WITNESS'
set -euo pipefail
exec 8</run/lock/macprovider-pearl-updater.lock
flock -n 8 || { echo "Pearl updater lock held; not mutating" >&2; exit 1; }
exec 9</opt/macprovider/.coordinator-deploy.lock
flock -n 9 || { echo "coordinator deploy lock held; not mutating" >&2; exit 1; }
cfg=/opt/macprovider/coordinator.yaml
live=/etc/macprovider/coordinator.pearl-overlays.yaml
staged=$live.witness
witness=/var/lib/macprovider/trustpool-manifest-witness.json
asmp() { sudo -u macprovider bash -c "set -a; . /etc/macprovider/coordinator.env; set +a; $*"; }
admin="/opt/macprovider/coordinator-cli trust-pool-admin"
adminf="--admin-url http://127.0.0.1:8444 --operator-key-env MACPROVIDER_OPERATOR_KEY"
# On any failure: before the swap, the key is not live, so remove the new
# witness; after the swap, put the pre-key config back and restart, and leave
# the witness (unused while the key is absent).
stage=pre-bootstrap
cleanup() {
  rc=$?
  [ "$rc" -eq 0 ] && return
  case "$stage" in
    bootstrapped) mv -f "$witness" "$witness.unused-$(date -u +%Y%m%dT%H%M%SZ)" ;;
    swapped) mv -f "$live.pre-witness" "$live"; systemctl restart macprovider-coordinator ;;
  esac
  echo "witness step failed at stage=$stage (rc=$rc); cleaned up" >&2
}
trap cleanup EXIT

# 1. Bootstrap from the live DB the running coordinator uses.
asmp "$admin manifest-witness-init --config $cfg --config-overlay $live --out $witness" > /root/witness-bootstrap.txt
[ -e "$witness" ] && stage=bootstrapped
cat /root/witness-bootstrap.txt
# 2. Compare: each pool's manifest_version must equal what the running
#    coordinator serves, and every pool list-pools reports with a manifest
#    must be in the witness.
asmp "$admin list-pools $adminf" > /root/witness-pools-before.json
python3 - /root/witness-bootstrap.txt /root/witness-pools-before.json <<'PY'
import json, re, sys
boot = dict(re.findall(r"^pool_id=(\S+) manifest_version=(\d+)", open(sys.argv[1]).read(), re.M))
pools = json.load(open(sys.argv[2]))["pools"]
live = {p["pool_id"]: str(p["manifest_version"]) for p in pools if p["manifest_version"]}
if boot != live:
    sys.exit(f"witness high-water {boot} != served {live}; stop")
print("high-water matches served manifests:", boot)
PY
curl -s http://127.0.0.1:8443/healthz > /root/witness-healthz-before.json
# 3. Validate the staged config, swap it in, restart.
asmp "/opt/macprovider/coordinator --config $cfg --config-overlay $staged --validate-config"
cp -p "$live" "$live.pre-witness"
stage=swapped
mv -f "$staged" "$live"
systemctl restart macprovider-coordinator
sleep 10
curl -sf http://127.0.0.1:8443/healthz > /dev/null
WITNESS
```

The `EXIT` trap handles every failure inside the step. If the bootstrap,
compare, `--validate-config` or backup fails, the key was never live: the trap
moves the new witness aside, so a retry bootstraps again. If the swap, restart
or health probe fails, the trap restores
`/etc/macprovider/coordinator.pearl-overlays.yaml.pre-witness` and restarts.
It leaves the witness in place, which is harmless while the key is absent.
Move it aside (`mv
/var/lib/macprovider/trustpool-manifest-witness.json{,.unused-<UTC>}`) before
the next attempt. A failing bootstrap that refuses an existing file means an
earlier attempt left one; move it aside the same way, then retry.

**Mandatory post-restart check.** All three must hold:

1. `journalctl -u macprovider-coordinator --since "<restart time>"` shows no
   `manifest acceptance witness` error and no `pool support disabled`.
2. `trust-pool-admin get-pool --pool-id <id>` for every pool that was active
   before shows `routeable: true` and the same `manifest_version`.
3. `curl -s http://127.0.0.1:8443/healthz` shows `pool_policy_ready` unchanged
   from `/root/witness-healthz-before.json` (after providers reconnect).

If any fails, roll back under both locks: `mv
/etc/macprovider/coordinator.pearl-overlays.yaml{.pre-witness,}`, restart, and
confirm pools route again. The witness can stay (unused without the key); move
it aside before the next attempt.

Limits. A manifest the coordinator accepts after the restart advances the
witness inside the acceptance transaction, before COMMIT. If that COMMIT then
fails, the witness is ahead of the DB and the next startup logs `pool support
disabled`: compare the witness against the DB high-water and, if the DB is the
truth, move the witness aside and re-run this section. Startup refuses a
missing witness, or one ahead of or inconsistent with the DB. The coordinator
process must be able to write the witness to advance it, so the `macprovider`
account (or anything running as it) can delete the file and re-bootstrap from
an older DB; this guard does not stop a compromised daemon or a host-level DB
restore. The independent WORM/transparency witness in §9 "Carried risk:
whole-database rollback" is still the real fix.

## 4. Create the production pool

Drive the admin surface (provider port, operator key) in order:

1. `trust-pool-admin upsert-creator --input <creator-approval.json>` — a full
   SPEC-043-R001 approval with `allowed_launch_environment` set to the
   production launch env, `status: enabled`, and future Creator Agreement
   expiry/grace timestamps.
2. `trust-pool-admin create-pool --pool-id <id> --creator-account-id <creator>
   --approval-record-id <approval> --operation-id <op>`.
3. Issue the root nonce, register the **signed** root (with the approved custody
   class), and accept the **signed** manifest:
   `trust-pool-admin issue-root-nonce`, `... append-event` /
   `... submit-policy` per the signed-root/manifest flow.
4. Admit the creator's own Macs (`trust-pool-admin admit-provider`) and authorize
   buyers on dedicated accounts (`trust-pool-admin authorize-buyer`). Keep the
   pool in a non-routeable lifecycle until promotion.
5. Runtime allowlist disclosure (SPEC-043-R013, #1690). Read the
   `runtime_allowlist` of the accepted policy core. A v1 core, or v2 with an
   empty list, is native MLX only. If the list is non-empty, confirm before
   promotion that `pool_policy.json`, the reviewed distribution artifact, and
   the announcement text each name exactly those runtimes and state that the
   pool operator attests the served weights and token counts. Also confirm
   that the policy declares settlement `enforce` and that every member
   serving an allowlisted runtime is owned by the creator account. Stop on
   any mismatch; loosening the list needs a new manifest version and a fresh
   review.

Confirm with `trust-pool-admin get-pool --pool-id <id>`.

## 5. Assign the production reviewed-artifact lifecycle owner

Production promote fail-closes (`reviewed_artifact_lifecycle_rejected`, 409)
unless the pool has a **current production** lifecycle owner whose
`next_review_due_utc` is in the future:

```bash
coordinator-cli trust-pool-artifact-lifecycle upsert \
  --admin-url http://127.0.0.1:8444 \
  --pool-id <id> --owner <owner> \
  --environment-class production \
  --next-review-due <UTC, in the future> \
  --operation-id <op>
coordinator-cli trust-pool-artifact-lifecycle get --pool-id <id>
```

This is separate from the digest-bound `reviewed-distribution-artifact` upsert.

## 6. Production timing-floor remeasure

Run the R007 rejection timing floor against the **production gateway** (not the
raw coordinator, which returns `401 Gateway context is required`, and not a
candidate/offline run — those do not count). Production gateways authenticate
buyers with `Authorization: Bearer <api key>`; pass the **names** of env vars
holding the keys, never key literals. `--base-url` is the gateway origin
without `/v1` (the script appends `/v1/chat/completions`).

Prepare, per class:

- `unknown`: `--unknown-pool-id`, a well-formed id no pool has.
- `unauthorized`: `--unauthorized-pool-id`, an existing pool the authorized
  buyer is **not** a buyer of. This lets one buyer account cover the class.
  Alternatively export a second, unauthorized buyer key and pass
  `--unauthorized-key-env`; it is then measured against `--pool-id`.
- `disabled`: `--pool-id`, a pool the authorized buyer **is** a buyer of, paused
  for the run.

```bash
export R007_AUTHORIZED_KEY=...   # from the operator secret store; never on argv
python3 scripts/measure-pool-rejection-timing-floor.py \
  --environment production --allow-production \
  --base-url https://<production gateway origin> \
  --pool-id <paused pool the buyer is authorized for> \
  --unauthorized-pool-id <existing pool the buyer is not authorized for> \
  --unknown-pool-id <nonexistent> \
  --authorized-key-env R007_AUTHORIZED_KEY \
  --samples 24
```

Class order is shuffled every round. All three classes must answer
`pool_unavailable`. The gateway refuses all three on one local lookup against
the coordinator's buyer-authorization projection, which omits non-active pools.
If `disabled` is slower than the other two, check that the coordinator build
omits non-active pools from `/internal/routing` `pools.account_pools`. A gateway with static `account_pools` grants
for the paused pool forwards it to the coordinator and fails this check. The
lab `--authorized-account` / `--unauthorized-account` (`X-MacProvider-Account`)
mode is for isolated harnesses only.

The floor must hold across unknown/unauthorized/disabled classes. Record the
result as an R012 launch artifact.

## 7. Promote

With on-call readiness current, the production reviewed-artifact lifecycle owner
assigned, the timing floor remeasured, and the signed launch/promotion evidence
in place, promote:

```bash
coordinator-cli trust-pool-admin set-lifecycle --pool-id <id> ...   # as required
coordinator-cli trust-pool-admin promote --pool-id <id> --operation-id <op>
```

The guarded operator promote wrapper re-checks on-call readiness and the
production reviewed-artifact lifecycle owner and **fails closed on any error**
before the mapped promote runs. In-process `Store.PromotePool` re-checks on-call
readiness inside its transaction and records the approved root custody class on
the promotion event (`get-pool` shows it as `root_custody_class`).

## 8. Verify and roll back

- Confirm `get-pool` shows the intended lifecycle and that authorized buyer chat
  for the `pool_id` behaves as expected while unauthorized/unknown lookups stay
  non-enumerating (`Cache-Control: no-store`).
- Keep the emergency pause/rollback path from
  [`trusted-pool-creator-launch.md`](trusted-pool-creator-launch.md) ready:
  `trust-pool-admin set-lifecycle` to `paused` fails buyer chat closed without
  touching global traffic; `revoke-provider`, `upsert-creator` (suspend), and
  the root-compromise freeze remain available.
- Retiring is two steps: `set-lifecycle --lifecycle paused` (or `draining`),
  then `--lifecycle retired`. An `active` pool cannot be retired directly
  (400 `invalid_event`). The transitions the coordinator accepts:

  | From | To | How |
  |---|---|---|
  | `created` | `active` | `promote` only |
  | `created` | `retired` | `set-lifecycle --lifecycle retired` |
  | `active` | `paused`, `draining` | `set-lifecycle` |
  | `paused` | `active` | `promote` only (re-runs the activation preflight) |
  | `paused` | `draining`, `retired` | `set-lifecycle` |
  | `draining` | `retired` | `set-lifecycle` |
  | `retired` | none | terminal |

  `active` never goes straight to `retired`: the coordinator answers 400
  `invalid_event` (`validLifecycleTransition`,
  `phase4-coordinator/internal/trustpool/durable_store.go`). `retired` also
  fails with `delivery_drain_pending` while the pool still has in-flight
  deliveries; retry once they finish.
- Reading the ledger for a pool route: `ledger_request_credits.usage_source`
  reads `provider_reported` on pool routes too. The attested source is
  recorded beside it, in `settlement_attempt_outputs.usage_source` and the
  gateway's `usage_events.token_source` (both `pool_operator_attested`), and
  in the closed verdict in `settlement_receipt_verdicts`. An audit that reads
  the ledger alone cannot tell a pool-attested credit from a global one, so
  join on `request_id` / `attempt_n` to one of those (#1750). The ledger
  vocabulary is unchanged.

## 9. External-runtime pools (#1690): rollout and rollback order

SPEC-022-R012 (R-12.8) is normative; this is the operator sequence.

Rollout, in this order (the R-12.8 order: coordinator, gateway, CLI, then v2
allowlists):

0. Drain ledger recovery on the OLD coordinator immediately before step 1
   and confirm no request is missing its ledger row. There is no admin
   trigger: the recovery runs at every coordinator start (the startup scan
   over `settlement.startup_reconcile_window_hours`, default 24, ending
   `recovery_grace_seconds` ago; it logs only on failure) and nightly at
   00:00 UTC. Confirm with this read-only check against the coordinator's
   `storage.db_path` (from `/opt/macprovider/coordinator.yaml` or the Pearl
   overlay), which must print `0`:

   ```bash
   sudo sqlite3 -readonly "$COORDINATOR_DB" "
   SELECT COUNT(*) FROM request_log rl
    WHERE rl.provider_assigned_id IS NOT NULL
      AND rl.status != 503
      AND rl.ts_utc >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-7 days')
      AND NOT EXISTS (
        SELECT 1 FROM ledger_request_credits lrc
         WHERE lrc.request_id = rl.request_id
           AND (rl.attempt_n IS NULL OR lrc.attempt_n = rl.attempt_n));"
   ```

   Above `0`: restart the old coordinator (its startup scan backfills rows
   inside its window) or wait for the nightly run, and re-run the check;
   rows older than the window need a review before step 1. Provider identity rows
   written before this release carry no recorded `runtime_source`, so the new
   coordinator's recovery treats a still-missing ledger row as possibly
   loopback and fails closed: 0 credit, quarantined as
   `loopback_runtime_not_settlement_eligible`. A native row caught this way is
   released with `force_credit` after review. Draining first keeps that window
   empty.
1. Pause every pool, deploy the coordinator that implements SPEC-022 v0.2.2
   (the `pool_operator_attested` usage source and negotiated settlement
   trailers), confirm `/healthz` reports it and the updater transaction
   committed, then resume the pools. Pause is `coordinator-cli
   trust-pool-admin set-lifecycle --pool-id <id> --lifecycle paused`; resume
   is `coordinator-cli trust-pool-admin promote --pool-id <id>
   --operation-id <op>` (paused to active). The still-old gateway does not advertise
   `X-MacProvider-Internal-Settlement-Trailers`, so the new coordinator answers
   it in the pre-#1690 order: non-streaming attempts are recorded before the
   write and their finality travels in headers, which that gateway reads.
   **#1816 pool models in this window.** A pool-model attempt (a
   `pool/<pool_id>/<slug>` id) and an attempt served by an R016 attested
   member are pinned to `spec022-route-snapshot-v2`, which a pre-#1816
   gateway cannot settle. The #1816 coordinator serves them only to a
   gateway that advertises
   `X-MacProvider-Internal-Settlement-Route-Snapshot-V2`: until the step 2
   gateway is live, a pool-model request answers
   `503 pool_model_requires_gateway_upgrade` before dispatch (no debit, no
   provider credit), and an R016 attested member is not selectable (its pool
   requests route to creator-owned members or fail closed). Catalog and other
   pool traffic is unaffected. Deploy the gateway right after the
   coordinator; the Pearl updater already does (it starts the new coordinator
   with the gateway stopped). A hold an earlier coordinator build left with
   `invalid_settlement_policy_version` is re-checked when the #1816 gateway
   starts (its startup catch-up ignores the reconcile backoff) and again once
   its hold deadline passes, and settles or refunds from the coordinator's
   finality.
2. Deploy the gateway (schema v14: accepts `pool_operator_attested` finality,
   advertises settlement trailers, verifies the finality MAC). From here the
   coordinator records non-streaming successes only after the buyer write and
   sends their finality as MAC'd trailers. On Pearl the gateway reaches the
   coordinator directly at `http://127.0.0.1:8443`; trailers cross no proxy.
   Until step 2a turns the pin on, this is not fail closed against a proxy
   on that hop. A proxy that drops only the trailer values (the `Trailer`
   declaration survives) makes the gateway hold the settlement as
   `missing_settlement_finality_trailer`. A proxy that strips the
   declaration too makes the response look like an older coordinator's:
   the gateway settles it from header finality, and a stream with none is
   debited the gateway's byte estimate (also when the buyer closes right
   after `[DONE]`, which is otherwise delivered usage), with no matching
   provider credit. Put nothing on that hop and keep the window between
   step 2 and step 2a short; step 2a closes it.
   The deploy's step 2c refuses a restart while buyer requests are in
   flight, counted from the live `gateway.db` (active, unheld, unexpired
   `quota_reservations`) when `/healthz` has no in-flight metric. That count
   is only a pre-check: buyer ingress stays open through the upload. A
   request admitted after it is protected by the graceful restart: the
   deploy restarts with `systemctl restart` (SIGTERM), the gateway refuses
   new connections at once and drains in-flight requests for up to 40 s
   (below the unit's `TimeoutStopSec=45`); only a request still running
   after that is cut. A reservation left by a crashed request counts until
   it expires. For a guaranteed quiet window, stop buyer traffic at nginx
   first (rollback step 1 shows how). `FORCE_RESTART=1` bypasses the
   pre-check and leaves an audit tombstone.
2a. Once the step 1 coordinator and the step 2 gateway are both confirmed
   (`/healthz` versions, updater transactions committed), set
   `coordinator.require_settlement_trailers: true` in the gateway config and
   restart the gateway. From then on the gateway holds any coordinator 200,
   streaming or non-streaming, that carries no signed finality as
   `missing_settlement_finality_trailer` instead of settling it from headers
   or legacy mode, so stripping the trailer declaration on the hop can no
   longer downgrade settlement. The coordinator signs every 200 it sends this
   gateway, including a `legacy` tuple for an attempt without a route
   snapshot (observe mode, a keyless provider), so those settle as before.
   A `missing_settlement_finality_trailer` hold after the restart means a
   stripped declaration or MAC; a stream whose receipt verdict is still open
   holds with its coordinator reason until the reconciler closes it. Watch
   both and the hold count.
3. Ship the provider CLI that signs pool-authorized loopback receipts
   (SPEC-015 0.4.10).
4. Only then accept a v2 policy core with a non-empty `runtime_allowlist`.
   The coordinator enforces this order for the gateway half (SPEC-022 v0.2.2
   R-12.8, E2E-F10): it selects an external-runtime member only for a
   request whose gateway advertised signed settlement finality, and answers
   any other caller 503 `byom_non_settlement_unavailable` ("External-runtime
   pool members serve only through a gateway that negotiates signed
   settlement finality") before dispatch. If that message shows up after
   this step, a pre-step-2 gateway is still serving; nothing was billed or
   credited.
   Record the first catalog release that publishes a gguf artifact with a
   `huggingface_revision` source (it carries `file_path`) or lists
   `mlxlm_loopback` or `omlx_loopback` in an `allowed_runtime_sources`. From that release on, a
   coordinator older than this release cannot start on the served feed; the
   coordinator rollback below has to replace the feed first.

Mixed versions are safe in both directions during steps 1-2 and during a
rollback, because the trailer order is negotiated per request:

- Old gateway, new coordinator: the gateway never advertises, so the
  coordinator keeps header finality recorded before the write. The old
  gateway never meets trailer-only finality it would ignore.
- New gateway, old coordinator: the old coordinator declares no trailers and
  sends header finality before the write; the new gateway reads it as before.
- The finality MAC key is the gateway service token, the bearer the gateway
  already sends. Rotate it on both sides together, as for the bearer itself.

An old CLI against the new coordinator, or the new CLI against an old
coordinator, fails closed: no pool-authorized receipt is signed and no
provider credit is created. A coordinator from this release on also refuses a database whose
`billing_compat_floor` is above its own contract, so a later downgrade onto a
binary that cannot read newer settlement rows fails closed at startup.

Rollback, in this order. Turning the pin off while buyer traffic runs would
let a stripped or unsigned response fall back to header or legacy
settlement, and a gateway database restore erases whatever it has not
settled, so traffic stops and holds drain first:

1. Stop buyer traffic at nginx while the gateway stays up. In every nginx
   server block that proxies to the gateway (`grep -l 9443
   /etc/nginx/sites-enabled/*`: `api.malibu.tech`, and any alias such as
   `api.streamvc.live`), replace the body of every `location` that
   `proxy_pass`es to `127.0.0.1:9443`, except `location = /healthz`, with
   `return 503;` (on `api.malibu.tech` today: `/v1/`, `/auth/`,
   `= /account`, `= /docs`, `= /privacy`). Then `sudo nginx -t && sudo
   systemctl reload nginx`, and verify from outside Pearl:
   `curl -s -o /dev/null -w '%{http_code}\n' -X POST
   https://api.malibu.tech/v1/chat/completions` prints `503`. The gateway
   keeps running on `127.0.0.1:9443`, so the reconciler and the operator
   endpoints stay reachable from Pearl itself (nginx never exposes `/admin/`
   publicly).
2. Drain settlement holds to zero with the reconciler, from Pearl:
   `curl -X POST -H "Authorization: Bearer $OPERATOR_KEY"
   http://127.0.0.1:9443/admin/settlement/reconcile`, repeated, until
   `SELECT COUNT(*) FROM quota_reservations WHERE status = 'active' AND
   settlement_hold = 1` returns 0. A hold the reconciler cannot resolve
   (`coordinator_404_held`) needs an operator decision here, before anything
   is rolled back.
3. Set `coordinator.require_settlement_trailers: false` and restart the
   gateway. A coordinator older than this release signs nothing, so with the
   pin on every one of its 200s is held as
   `missing_settlement_finality_trailer`. The reconciler's request-scoped
   finality lookup then settles each hold to the older coordinator's
   finality, normally within seconds (the #1690 VM e2e saw every such hold
   terminate correctly), so this is not money loss. It does put every
   request through a hold and a reconcile, and a reconciler outage would
   leave them held, so turn the pin off before the coordinator rollback.
4. Roll back in the reverse of the rollout order: withdraw v2 allowlists (a
   policy core with an empty `runtime_allowlist`), then the CLI, then the
   gateway only if it must go (below), then the coordinator. The coordinator
   rollback needs nothing more from the gateway: a v0.2.2 gateway reads an
   older coordinator's header finality. It does need a feed the older
   coordinator can load (E2E-F11): before replacing the coordinator binary,
   run the feed check below. It also needs a target that can replay the
   pool manifest history (step 4b): withdrawing an allowlist mints a new
   policy version, but every earlier `manifest_accepted` event stays in
   history, and a coordinator replays all of them at start. A target that
   cannot read one of them disables every pool.

   **Rollback precondition (#1690 M9 review M2).** The coordinator rollback
   target MUST be at or above the build that introduced every runtime class
   ever accepted in any pool's manifest history, it MUST read
   `manifest-snapshot/v2` if any v2 policy core was ever accepted, and it
   MUST implement every policy-core extension (SPEC-042 0.0.38,
   `pool_attested_members/v1` and `pool_model_entries/v1`, #1816) ever
   accepted: an older build rejects an unknown `extension_id` while
   replaying history and disables every pool. The builds, from the
   target's source commit:

   | Target tier | Target contains | Replays |
   |---|---|---|
   | `v1-only` | not `747557cc` (#1719) | v1 policy cores only |
   | `m8` | `747557cc`, not the #1754 merge | v2 cores listing `llamacpp_loopback`, `mlxlm_loopback`, `ollama_loopback` |
   | `m9` | the #1754 merge, not the #1816 merge | also `lmstudio_loopback` and `omlx_loopback`; no extensions |
   | `p1816` | the #1816 merge | also the `pool_attested_members/v1` and `pool_model_entries/v1` extensions |
   | `p1880` | the #1880 merge | also superseding policy windows (SPEC-042 0.0.42) and offers' `requested_pool_model_id` |

   Decide the tier with `git merge-base --is-ancestor 747557cc <target>` and
   the same check against the #1754, #1816 and #1880 merge commits.

   **#1880 downgrade blockers.** A target older than `p1880` rejects a later
   policy window that overlaps an earlier one (a SPEC-042 0.0.42
   supersession) while rebuilding a pool's history, which disables the pool,
   and it ignores a model-admission offer's `requested_pool_model_id`, so it
   could bind that offer to another pool with the same artifact. Step 4b
   below does not see either; `coordinator pool-rollback-preflight
   --target-tier <tier>` does, and it MUST exit 0 before any rollback to a
   target older than `p1880`. A superseded window never leaves a pool's
   history, so it can only be cleared by rolling forward. A live offer naming
   a pool entry is cleared by the provider withdrawing it
   (`macprovider-cli models admission withdraw <candidate> --yes --json`,
   then re-offering without `pool_model_id` if it should stay offered).

   **Carried risk: whole-database rollback (pre-existing, #1816 freeze audit
   R1 S-M5).** Trust-pool events, their projections, and the manifest
   acceptance high-water rows live in `coordinator.db`, so restoring an older
   copy of that file restores an older, internally consistent history: a
   member, delegation, attestation, or pool model entry revoked after the
   copy was taken is routable and payable again, and verification cannot tell.
   SPEC-042 lists tamper-evident full rollback protection as a launch
   blocker. A high-water mark kept beside the database is not a fix: the
   Pearl updater's own rollback restores its pre-update `coordinator.db`
   snapshot by design, so such a mark would refuse every legitimate rollback,
   and anyone able to restore the database can restore a file next to it. An
   independent witness (WORM or transparency storage) is the real fix and is
   not built. Until it is: after ANY restore of `coordinator.db` (an updater
   rollback included), list every `member_revoked`, delegation revocation,
   lifecycle change, and `manifest_accepted` the operator or creators made
   after the restored copy's timestamp (the admin audit log and the updater
   transaction record both carry times) and re-apply them before resuming
   buyer traffic. When step 4b says STOP,
   roll the coordinator forward instead: there is no supported way to drop
   an accepted manifest from history.
4a. Feed check before the coordinator rollback. A coordinator older than
   this release strict-decodes the catalog artifact feed and exits at
   startup on `json: unknown field "file_path"` (a gguf artifact with a
   `huggingface_revision` source; SPEC-023 v0.16.0, rollout recorded at
   v0.19.1) or on `runtime_format "mlx_safetensors" may not allow runtime
   source "mlxlm_loopback"` (v0.17.0) or `"omlx_loopback"` (v0.20.0), which
   would leave no
   coordinator. The check fails closed: it parses the config (YAML or JSON,
   quoted or not) instead of matching text, and any error, a missing
   `python3`/`yaml`, a relative or unreadable path, or no `VERDICT` line
   means STOP. It reads the live config and then the Pearl overlay (the
   overlay wins, as for the coordinator); a missing overlay is STOP. On Pearl:

   ```bash
   python3 - /opt/macprovider/coordinator.yaml /etc/macprovider/coordinator.pearl-overlays.yaml <<'PY'
   import os, sys
   try:
       import yaml
       path = None
       for config_path in sys.argv[1:]:
           with open(config_path) as f:
               cfg = yaml.safe_load(f)
           if cfg is None:
               cfg = {}
           if not isinstance(cfg, dict):
               raise ValueError(f"{config_path} is not a mapping")
           auto = cfg.get("autotune")
           if auto is None:
               auto = {}
           if not isinstance(auto, dict):
               raise ValueError(f"autotune in {config_path} is not a mapping")
           if "catalog_artifacts_path" in auto:
               path = auto.get("catalog_artifacts_path")
       if path is None or path == "":
           print("feed: none (autotune.catalog_artifacts_path unset)")
           print("VERDICT: no-feed")
           sys.exit(0)
       if not isinstance(path, str) or path != path.strip() or not os.path.isabs(path):
           raise ValueError(f"catalog_artifacts_path is not a clean absolute path: {path!r}")
       with open(path, encoding="utf-8") as f:
           body = f.read()
       hits = body.count('"file_path"') + body.count("mlxlm_loopback") + body.count("omlx_loopback")
       print(f"feed: {path}")
       print(f"older-coordinator blockers: {hits}")
       print("VERDICT: " + ("clean" if hits == 0 else "replace-feed"))
       sys.exit(0 if hits == 0 else 1)
   except Exception as e:
       print(f"feed check error: {e}")
       print("VERDICT: STOP")
       sys.exit(2)
   PY
   echo "exit: $?"
   code=$(curl -sS -o /tmp/served-catalog-artifacts.json -w '%{http_code}' https://coordinator.malibu.tech/v1/catalog-artifacts) || code=error
   echo "served: $code"
   [ "$code" != 200 ] || grep -c -e '"file_path"' -e mlxlm_loopback -e omlx_loopback /tmp/served-catalog-artifacts.json
   ```

   Read it strictly; anything not listed here is STOP (do not roll back the
   coordinator until it is resolved):
   - `VERDICT: no-feed`, `exit: 0` and `served: 404`: go to the coordinator
     rollback.
   - `VERDICT: clean`, `exit: 0`, `served: 200` and a served count of `0`:
     go to the coordinator rollback.
   - `VERDICT: replace-feed` (`exit: 1`), or a served count above `0`:
     replace the feed first (below).
   - `VERDICT: STOP`, no `VERDICT` line, a `served` code that disagrees with
     the verdict (`no-feed` with `200`, `clean` with anything but `200`), or
     `served: error`: STOP. Resolve the config or the served feed first; the
     path the coordinator logs at startup is the reference.

   To replace the served feed, use a signed release, never a hand edit:
   the feed is release-bound (same signer `key_id` as the candidate feed,
   `candidate_catalog_sha256` of the served candidate bytes), so stripping
   and re-signing the file alone does not load.
   1. In a fresh worktree off `origin/main`, edit
      `phase3-binary/catalog/autotune/autotune-artifacts-source.json`: delete
      every `gguf` artifact whose `source_ref.kind` is `huggingface_revision`
      (and repoint any `primary_artifact_id` that named one), and remove
      `mlxlm_loopback` and `omlx_loopback` from every
      `allowed_runtime_sources`. Leave
      `ollama_library_tag` gguf artifacts and `mlx_cache` as they are; the
      older coordinator accepts both.
   2. Cut the release exactly as `docs/runbooks/catalog-artifact-feed-release.md`
      describes (`scripts/catalog-release.py generate` with
      `--previous-release-dir` set to the release now live, signing, then
      `scripts/catalog-release.py verify`). If the generator refuses the
      removal (its cross-release binding checks), stop: roll the coordinator
      forward instead of back.
   3. Deploy that catalog release to Pearl through the normal catalog deploy
      and re-run the check above against the new
      `catalog_artifacts_path`; also confirm the served bytes:
      `curl -s https://coordinator.malibu.tech/v1/catalog-artifacts | grep -c -e '"file_path"' -e mlxlm_loopback -e omlx_loopback`
      prints `0`.
   Then run step 4b.
4b. Manifest-history check before the coordinator rollback (read-only). It
   reads every `manifest_accepted` event in the coordinator database
   (`storage.db_path`, as in step 0), decodes each manifest snapshot, and
   lists the policy-core encoding, every `runtime_allowlist` string, and
   every extension id it carries (a strict decode of the snapshot, not a
   search for known names);
   each snapshot holds its pool's whole accepted policy history. It fails
   closed: a target tier other than the five in the table, an unreadable
   database, an undecodable snapshot, a runtime class outside `CLASSES` or
   an extension outside `EXTENSIONS` (no known build replays it), an
   extension the target tier lacks, or no `VERDICT` line means STOP. Once
   any core with a #1816 extension is accepted, only a `p1816` target
   replays the history; for an older target, roll forward.
   The `m9` target tier is the build that carries SPEC-042 0.0.36's
   `omlx_loopback` manifest vocabulary and SPEC-023 v0.20.0's corresponding
   artifact-feed runtime source. The manifest history is the only coordinator state an older build
   decodes strictly at start with a runtime class in it. Other tables that
   store `lmstudio_loopback` or `omlx_loopback` strings (route snapshots,
   model admission events) either belong to a pool whose manifest allowlist
   this check already covers or are read leniently, so they need no check.
   On Pearl, with the tier of the rollback target:

   ```bash
   sudo python3 - "$COORDINATOR_DB" m8 <<'PY'
   import base64, json, os, sqlite3, sys
   CLASSES = ["llamacpp_loopback", "lmstudio_loopback", "mlxlm_loopback",
              "ollama_loopback", "omlx_loopback", "openai_compatible_loopback"]
   EXTENSIONS = ["pool_attested_members/v1", "pool_model_entries/v1"]
   ACCEPTS = {
       "v1-only": None,
       "m8": {"llamacpp_loopback", "mlxlm_loopback", "ollama_loopback"},
       "m9": {"llamacpp_loopback", "lmstudio_loopback", "mlxlm_loopback",
              "ollama_loopback", "omlx_loopback"},
       "p1816": {"llamacpp_loopback", "lmstudio_loopback", "mlxlm_loopback",
                 "ollama_loopback", "omlx_loopback"},
       "p1880": {"llamacpp_loopback", "lmstudio_loopback", "mlxlm_loopback",
                 "ollama_loopback", "omlx_loopback"},
   }
   ACCEPTS_EXTENSIONS = {"v1-only": set(), "m8": set(), "m9": set(),
                         "p1816": set(EXTENSIONS), "p1880": set(EXTENSIONS)}
   V1 = b"macprovider/spec042/manifest-snapshot/v1"
   V2 = b"macprovider/spec042/manifest-snapshot/v2"

   def allowlists(snap, tagged, event_id):
       # Strict decode of the snapshot (phase4-coordinator/internal/
       # poolmanifest/persist.go): every runtime_allowlist string and every
       # extension id of every accepted v2 policy core.
       pos = len(V2 if tagged else V1)
       def take(n):
           nonlocal pos
           if n < 0 or pos + n > len(snap):
               raise ValueError(f"event {event_id}: truncated manifest snapshot")
           pos += n
           return snap[pos - n:pos]
       u32 = lambda: int.from_bytes(take(4), "big")
       u64 = lambda: take(8)
       blob = lambda: take(u32())
       def boolean():
           if take(1) not in (b"\x00", b"\x01"):
               raise ValueError(f"event {event_id}: bad boolean in manifest snapshot")
       def signatures():
           for _ in range(u32()):
               blob(); blob()
       found, extensions = set(), set()
       blob(); blob(); blob(); blob()                 # identity core, root issuer key
       for _ in range(u32()):                         # authority log
           blob(); u64(); blob()
           for _ in range(u32()):
               blob(); blob()
           u64(); u64(); u64()
           for _ in range(u32()):
               u64()
           u64(); signatures()
       for _ in range(u32()):                         # accepted policies
           encoding = take(1)[0] if tagged else 0
           if encoding > 2:
               raise ValueError(f"event {event_id}: unknown policy core encoding {encoding}")
           blob(); u64(); blob(); u64()
           for _ in range(u32()):
               blob()
           blob(); blob(); boolean(); blob(); u64(); blob(); blob(); u64()
           blob(); boolean(); blob(); blob(); blob(); boolean(); u64(); u64()
           if encoding == 2:
               for _ in range(u32()):
                   found.add(blob().decode("utf-8"))
               for _ in range(u32()):                 # extensions: id, body
                   extensions.add(blob().decode("utf-8")); blob()
           signatures(); u64()
       if pos != len(snap):
           raise ValueError(f"event {event_id}: trailing bytes in manifest snapshot")
       return found, extensions
   try:
       db, tier = sys.argv[1], sys.argv[2]
       if tier not in ACCEPTS:
           raise ValueError(f"unknown target tier {tier!r}")
       if not os.path.isabs(db) or not os.path.isfile(db):
           raise ValueError(f"no database file at {db!r}")
       try:
           con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
           tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
       except sqlite3.OperationalError:
           # A WAL database with no -wal file (a stopped, checkpointed
           # coordinator) cannot be opened read-only; its main file is then
           # complete, so read it as immutable.
           if os.path.exists(db + "-wal"):
               raise
           con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
           tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
       if "trustpool_events" not in tables:
           print("manifests: 0 (no trustpool history)")
           print("VERDICT: replayable")
           sys.exit(0)
       rows = con.execute("SELECT id, pool_id, payload_json FROM trustpool_events "
                          "WHERE event_type = 'manifest_accepted' ORDER BY id").fetchall()
       v2, seen, exts = 0, set(), set()
       for event_id, pool_id, payload in rows:
           snap = base64.b64decode(json.loads(payload)["manifest_snapshot"], validate=True)
           if snap.startswith(V2):
               v2 += 1
           elif not snap.startswith(V1):
               raise ValueError(f"event {event_id}: unknown manifest snapshot format")
           classes, extensions = allowlists(snap, snap.startswith(V2), event_id)
           seen |= classes
           exts |= extensions
       unknown = sorted((seen - set(CLASSES)) | (exts - set(EXTENSIONS)))
       accepts = ACCEPTS[tier]
       blockers = sorted(seen) if accepts is None else sorted(seen - accepts)
       blockers += sorted(f"extension {e}" for e in exts - ACCEPTS_EXTENSIONS[tier])
       if accepts is None and v2:
           blockers.insert(0, "policy-core v2 snapshots")
       print(f"manifests: {len(rows)} (v2 snapshots: {v2})")
       print(f"runtime classes in history: {', '.join(sorted(seen)) or 'none'}")
       print(f"extensions in history: {', '.join(sorted(exts)) or 'none'}")
       if unknown:
           print(f"unknown runtime classes or extensions (no known build replays them): {', '.join(unknown)}")
       print(f"target tier: {tier}; cannot replay: {', '.join(blockers) or 'nothing'}")
       print("VERDICT: " + ("replayable" if not blockers else "STOP"))
       sys.exit(0 if not blockers else 1)
   except SystemExit:
       raise
   except Exception as e:
       print(f"manifest history check error: {e}")
       print("VERDICT: STOP")
       sys.exit(2)
   PY
   echo "exit: $?"
   ```

   `VERDICT: replayable` with `exit: 0` is the only go: roll back the
   coordinator binary and confirm it started (`/healthz` reports the older
   version, `/v1/catalog-artifacts` answers 200, and `/poolz` still lists
   the pools). `VERDICT: STOP` (exit 1 or 2), or no `VERDICT` line: do not
   roll back the coordinator; roll it forward. The check is exercised
   against lab databases by `scripts/lab/1690-e2e/check4b.sh`.
5. Resume buyer traffic: restore the nginx `location` bodies and reload.

Prefer rolling the gateway forward: v14 only widens the
`usage_events.token_source` CHECK. A gateway older than this release
(`maxKnownSchemaVersion` 13) refuses a v14 database at open, and its
`usage_events` CHECK rejects `pool_operator_attested`. The
`deploy-pearl-vps.sh` gateway deploy snapshots `gateway.db` at step 2d
(`sqlite3 .backup` to `gateway.db.pre-deploy.<UTC timestamp>`; the run prints
`db snapshot saved at <path>`) and copies the previous binary to
`/opt/macprovider/gateway.prev` at step 3. At the end of the run it only
prints a rollback recipe: every restore command in its "Rollback:" block
(script lines 761-797) is an `echo`, so the script itself never restores.
The printed recipe picks the newest snapshot (`ls -1t | head -1`), stops the
gateway, reinstalls `gateway.prev`, deletes `gateway.db-wal` and
`gateway.db-shm`, installs the snapshot over `gateway.db`, and then runs
`systemctl start macprovider-gateway` and a `/healthz` check. The restore
discards every gateway write since the snapshot, including anything only in
the WAL: accounts and API keys issued, quota reservations and their
settlement holds, usage (debit) rows, demo usage, and wallet-session state.
The gateway cannot run with its reconciler off (`settlement.reconcile_enabled:
false` fails config validation), so it stays stopped until the lost rows are
back. A gateway rollback therefore runs inside step 4 above, after traffic
stopped and holds drained, and only as:

1. Pre-check, with the gateway still up: `SELECT COUNT(*) FROM usage_events
   WHERE token_source = 'pool_operator_attested'`. Only a v14 gateway writes
   that source, and the older gateway's CHECK cannot hold it, so any such row
   makes a gateway rollback forbidden: roll the gateway forward instead.
   Continue only when the count is 0.
2. Stop the gateway (`sudo systemctl stop macprovider-gateway`), so nothing
   is written after the export.
3. Name the exact restore inputs; do not use the recipe's `ls -1t | head
   -1`. The snapshot is the path the v14 deploy printed as `db snapshot saved
   at ...` (the `gateway.db.pre-deploy.<UTC timestamp>` taken by that deploy,
   not a later one). The binary is the pre-v14 release: use
   `/opt/macprovider/gateway.prev` only if its sha256 matches that release's
   published gateway binary; if a later deploy replaced it, install the
   pre-v14 release binary explicitly.
4. Export every row written after that snapshot's timestamp from every
   gateway table that takes durable writes while it serves: `accounts`,
   `account_identities`, `api_keys`, `api_key_events`, `quota_reservations`,
   `usage_events`, `demo_usage_events`, `demo_session_events`,
   `wallet_identities`, the `wallet_session*` tables, `audit_events`,
   `signup_events`, `feedback_events`, `public_issuance_events`,
   `capacity_signal_events`, `relay_blind_replays` (replay protection),
   `runtime_config` (operator changes), `settlement_fallback_candidates` and
   `settlement_reconcile_attempts` (their `created_at`, `settled_at` or
   equivalent timestamp is after the snapshot's). These are the buyer
   debits, account state, audit trail, replay guards and reconcile bindings
   the restore would lose. Not exported: `schema_migrations` (the restore's
   own version must stay), and the short-lived `oauth_states`,
   `oauth_handoffs` and `concurrency_reservations`, which are empty or
   expired once traffic is stopped. Check the list against the gateway's
   `CREATE TABLE` statements (`phase5-gateway/internal/storage/sqlite/`)
   for both releases before the export: a table added since this runbook
   was written belongs in it too.
5. Run the printed recipe's restore steps with the named snapshot and binary,
   up to and including the snapshot install and its `PRAGMA
   integrity_check`, but leave out its final `systemctl start
   macprovider-gateway` and `/healthz` lines: the gateway stays stopped.
6. Re-apply the exported rows to the restored database with `sqlite3`,
   then start the older gateway and check `/healthz`. There is no separate
   quota total to fix: daily quota is computed from `usage_events` and
   `quota_reservations`, so re-applying those rows restores it. Buyer traffic stays blocked at nginx
   until step 5 of the rollback. Skipping the re-apply is only acceptable
   when step 4 exported nothing.

Rollback to a coordinator that predates SPEC-022 v0.2.0, once any pool route
has run on the new coordinator:

1. Stop new pool traffic: `trust-pool-admin set-lifecycle` every pool to
   `paused` (or disable the trusted-pool feature).
2. Run the gate with the **current** binary against the live database:

   ```bash
   sudo bash -c 'set -a; . /etc/macprovider/coordinator.env; set +a
     /opt/macprovider/coordinator pool-rollback-preflight \
       --config /opt/macprovider/coordinator.yaml \
       --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml \
       --target-tier m9'
   echo "exit: $?"
   ```

   `--target-tier` is the rollback target's tier from the step 4b table
   (`v1-only`, `m8`, `m9`, `p1816`, `p1880`; default `v1-only`, the oldest). The gate
   also strictly decodes the pool manifest history, as step 4b does: when the
   target cannot replay an accepted core (an extension or runtime class it
   lacks, or any v2 core for `v1-only`) it prints `STOP: ... cannot replay the
   pool manifest history (...)`, sets `rollback_blocked: true` and
   `manifest_history.cannot_replay`, and exits 3; waiting never clears it,
   roll forward. An undecodable snapshot prints `STOP` and exits 1. For a
   target older than `p1880` it also lists, in `manifest_history.superseded_windows`
   and `pool_selection.live_selector_offers`, every superseded policy window
   (roll forward) and every live offer naming a pool entry (withdraw it,
   then re-run), with a `STOP` line for each, and exits 3.

   These are the paths the `macprovider-coordinator` unit runs with (live
   config, Pearl overlay, env file for the `env:` credentials the config
   names); `/etc/macprovider/coordinator.yaml` does not exist on Pearl.

   Exit 0 means the target tier replays the manifest history and every pool
   route snapshot has a closed verdict or is past its
   pending deadline with no verdict. Exit 3 means a pool attempt can still
   reach receipt ingestion or a verdict update; the JSON line shows
   `open_pool_verdicts`, `in_window_pool_attempts_without_verdict`, and, when
   only in-window attempts block, `earliest_safe_unix_ms`.
3. Do not roll back while the gate exits non-zero. Wait and re-run, or roll
   forward instead. The old coordinator would leave those attempts
   unverifiable, pending, or quarantined. The running coordinator closes an
   open pending pool verdict within about a minute of its pending deadline
   (the expiry sweep, log line `expired pending pool settlement verdicts
   finalized`), including an attempt a gateway retry already refunded, so
   `open_pool_verdicts` normally reaches 0 without buyer traffic. If it stays
   above 0 more than a few minutes past the latest pending deadline, check
   the coordinator log for `pool settlement expiry sweep failed`; do not roll
   back.

A rollback between two coordinators that both implement SPEC-022 v0.2.0 needs
no gate. The Pearl updater's automatic rollback does not run this gate, and the
v0.2.0 coordinator writes the new route-snapshot labels on every pool route,
native MLX pools included. Keep every pool `paused` while the v0.2.0 coordinator
deploy runs, and resume pools only after the updater transaction has committed,
so an automatic rollback cannot strand a pool attempt.

## Still open after this runbook (do not skip)

Executing this runbook does not by itself close #1233. Full R006
re-verification before reactivation and any unresolved SPEC-042 conformance rows
remain launch blockers or explicit-accept decisions. Do not announce a live
external creator from isolated-candidate CONFORMANCE.
