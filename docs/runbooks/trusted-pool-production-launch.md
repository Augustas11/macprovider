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
- You accept the residual launch blockers still open on #1233 (custody-class
  recording, full R006 re-verification, unresolved SPEC-042 rows) or have an
  explicit written decision to carry them.

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
the record expires at `last_confirmed_at + confirmation_ttl`.

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
```

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
before the mapped promote runs. In-process `Store.PromotePool` still does not
consult these rows; that mapped-`validatePromotion` wiring is deferred and needs
a fresh signed candidate recapture window.

## 8. Verify and roll back

- Confirm `get-pool` shows the intended lifecycle and that authorized buyer chat
  for the `pool_id` behaves as expected while unauthorized/unknown lookups stay
  non-enumerating (`Cache-Control: no-store`).
- Keep the emergency pause/rollback path from
  [`trusted-pool-creator-launch.md`](trusted-pool-creator-launch.md) ready:
  `trust-pool-admin set-lifecycle` to `paused` fails buyer chat closed without
  touching global traffic; `revoke-provider`, `upsert-creator` (suspend), and
  the root-compromise freeze remain available.

## Still open after this runbook (do not skip)

Executing this runbook does not by itself close #1233. Custody-class recording
from the R002 registration, full R006 re-verification before reactivation, the
mapped-`validatePromotion` wiring, and any unresolved SPEC-042 conformance rows
remain launch blockers or explicit-accept decisions. Do not announce a live
external creator from isolated-candidate CONFORMANCE.
