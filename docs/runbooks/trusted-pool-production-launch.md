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
- Settlement stays observe/labels-only (`split_execution_status` remains
  `declared_not_executed`) for the MVP.
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
after the config change.

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
candidate/offline run — those do not count):

```bash
python3 scripts/measure-pool-rejection-timing-floor.py \
  --environment production --allow-production \
  --base-url https://<production gateway base url>/v1 \
  --pool-id <id> \
  --unknown-pool-id <nonexistent> \
  --authorized-account <authorized> \
  --unauthorized-account <unauthorized>
```

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

## 9. External-runtime pools (#1690): rollout and rollback order

SPEC-022-R012 (R-12.8) is normative; this is the operator sequence.

Rollout, in this order (the R-12.8 order: coordinator, gateway, CLI, then v2
allowlists):

0. Drain ledger recovery on the OLD coordinator immediately before step 1:
   let the startup/nightly ledger recovery run to completion (or trigger it)
   and confirm no request is missing its ledger row. Provider identity rows
   written before this release carry no recorded `runtime_source`, so the new
   coordinator's recovery treats a still-missing ledger row as possibly
   loopback and fails closed: 0 credit, quarantined as
   `loopback_runtime_not_settlement_eligible`. A native row caught this way is
   released with `force_credit` after review. Draining first keeps that window
   empty.
1. Pause every pool, deploy the coordinator that implements SPEC-022 v0.2.2
   (the `pool_operator_attested` usage source and negotiated settlement
   trailers), confirm `/healthz` reports it and the updater transaction
   committed, then resume the pools. The still-old gateway does not advertise
   `X-MacProvider-Internal-Settlement-Trailers`, so the new coordinator answers
   it in the pre-#1690 order: non-streaming attempts are recorded before the
   write and their finality travels in headers, which that gateway reads.
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
   `mlxlm_loopback` in an `allowed_runtime_sources`. From that release on, a
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
   pin on every one of its 200s would be held.
4. Roll back in the reverse of the rollout order: withdraw v2 allowlists (a
   policy core with an empty `runtime_allowlist`), then the CLI, then the
   gateway only if it must go (below), then the coordinator. The coordinator
   rollback needs nothing more from the gateway: a v0.2.2 gateway reads an
   older coordinator's header finality. It does need a feed the older
   coordinator can load (E2E-F11): before replacing the coordinator binary,
   run the feed check below.
4a. Feed check before the coordinator rollback. A coordinator older than
   this release strict-decodes the catalog artifact feed and exits at
   startup on `json: unknown field "file_path"` (a gguf artifact with a
   `huggingface_revision` source) or on `runtime_format "mlx_safetensors" may
   not allow runtime source "mlxlm_loopback"`, which would leave no
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
       hits = body.count('"file_path"') + body.count("mlxlm_loopback")
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
   [ "$code" != 200 ] || grep -c -e '"file_path"' -e mlxlm_loopback /tmp/served-catalog-artifacts.json
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
      `mlxlm_loopback` from every `allowed_runtime_sources`. Leave
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
      `curl -s https://coordinator.malibu.tech/v1/catalog-artifacts | grep -c -e '"file_path"' -e mlxlm_loopback`
      prints `0`.
   Then roll back the coordinator binary and confirm it started (`/healthz`
   reports the older version and `/v1/catalog-artifacts` answers 200).
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
4. Export every row written after that snapshot's timestamp from `accounts`,
   `account_identities`, `api_keys`, `api_key_events`, `quota_reservations`,
   `usage_events`, `demo_usage_events`, and the `wallet_session*` tables
   (their `created_at`, `settled_at` or equivalent timestamp is after the
   snapshot's). These are the buyer debits and account state the restore
   would lose.
5. Run the printed recipe's restore steps with the named snapshot and binary,
   up to and including the snapshot install and its `PRAGMA
   integrity_check`, but leave out its final `systemctl start
   macprovider-gateway` and `/healthz` lines: the gateway stays stopped.
6. Re-apply the exported rows to the restored database with `sqlite3`,
   reconcile daily quota totals for the affected accounts, then start the
   older gateway and check `/healthz`. Buyer traffic stays blocked at nginx
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
       --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml'
   echo "exit: $?"
   ```

   These are the paths the `macprovider-coordinator` unit runs with (live
   config, Pearl overlay, env file for the `env:` credentials the config
   names); `/etc/macprovider/coordinator.yaml` does not exist on Pearl.

   Exit 0 means every pool route snapshot has a closed verdict or is past its
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
