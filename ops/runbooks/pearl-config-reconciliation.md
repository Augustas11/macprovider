# Pearl Config Reconciliation

Use this read-only check before Pearl coordinator deploys when `CONFIG_MODE` is
`preserve-live`, and before any reviewed config migration. It classifies live
Pearl config drift against the repo source-of-truth manifest without mutating
Pearl and without printing secret values.

```bash
python3 ops/pearl/config/reconcile_pearl_config.py --ssh-target pearl
```

Expected output has three sections:

- `Evidence`: exact tracked/live matches, manifest-declared drift, classified
  env key names, and manifest-classified overlay fields. Evidence means the
  path is either equal or explicitly classified by source-of-truth; it does not
  mean the reconciler has proved the live value is desirable.
- `Inference`: live-only posture that the manifest classifies without mirroring
  secret or production-only values, such as registered/static provider rows.
- `Unknown`: unclassified drift. Treat any entry here as a stop condition for
  deploy; the tool exits non-zero.

`Unknown > 0` blocks deploy because `CONFIG_MODE=preserve-live` keeps Pearl's
installed `/opt/macprovider/coordinator.yaml` in place. An unclassified path
means a deploy would either silently preserve unknown production state or
overwrite it only through an unsafe broad drift path. Classify the path in a
reviewed manifest update before deploying; do not use `ALLOW_CONFIG_DRIFT=1`.

To classify new drift, update `ops/pearl/config/source-of-truth.yaml` with the
owner, path, drift kind, and non-secret expected value or rationale. Keep PRs
scoped: this manifest classifies ownership only. Field-scoped migration from
live base config into `/etc/macprovider/coordinator.pearl-overlays.yaml` belongs
in the follow-up migration PR.

Never paste `/etc/macprovider/coordinator.env` values into issues, fixtures,
PR bodies, or runbooks. The reconciler prints key names only.

## PR C Ownership Classifications

PR C classifies the 55 paths that were `Unknown` after PR B's first live
read-only run:

| Paths | Classification | Owner |
| --- | --- | --- |
| `auth.credential_bootstrap_*` | intentional Pearl production posture | `base_product_defaults`; live base may omit the explicit YAML because `config.Default()` supplies the same bounded bootstrap limits. |
| `autotune.public_keys.streamvc-autotune-static-v5` | fleet/version-admission policy | `fleet_version_admission_policy`; admitting v5-signed static feeds remains an explicit fleet/version trust decision. |
| `coordinator.env.COORDINATOR_PARTNER_KEYS_ADMIN_DSN` | secrets/env-owned setting | `pearl_operator_secrets`; read by the deploy-side stats migration gate. |
| `coordinator.env.MALIBU_EMISSION_WRITER_PASSWORD` | secrets/env-owned setting | `pearl_operator_secrets`; optional first-time/rotation password for the Malibu emission writer role. |
| `coordinator.env.MAL_REFERRAL_HMAC_K1` | secrets/env-owned setting | `pearl_operator_secrets`; referral HMAC material. |
| `coordinator.env.X_API_BEARER_TOKEN` | secrets/env-owned setting | `pearl_operator_secrets`; optional referral social-verification bearer credential. |
| `production_overlay.pool.canary_*` and `production_overlay.pool.model_class_challenges.*` | overlay-owned Pearl production setting | `pearl_production_overlay`; live canary posture and prompt/challenge text stay in the Pearl overlay. |
| `production_overlay.malibu_emission.*` | overlay-owned Pearl production setting or secrets/env-owned setting | `pearl_production_overlay` owns campaign limits/timing; `malibu_emission.writer_dsn` is `pearl_operator_secrets` and classifies only as an `env:NAME` reference. |
| `production_overlay.proof_of_weights.*` | overlay-owned Pearl production setting | `pearl_production_overlay`; proof-of-weights TTL, gate, and telemetry drift thresholds are exact typed overlay paths. |
| `production_overlay.referrals.*` non-secret campaign fields | overlay-owned Pearl production setting | `pearl_production_overlay`; active referral campaign gates, URLs, timing, and use limits live in the Pearl overlay. |
| `production_overlay.referrals.hmac_keys.*` and `production_overlay.referrals.x_api_bearer_token` | secrets/env-owned setting | `pearl_operator_secrets`; these classify only when the overlay value is an `env:NAME` reference. Inline secret values remain `Unknown`. |
| tracked-only `referrals.*` default-off/base values | overlay-owned Pearl production setting or secrets/env-owned setting | Checked-in base config documents safe defaults; active Pearl referral campaign state is overlay/env-owned. |

As of PR C validation, live reconciliation reports:

```text
Evidence: 97
Inference: 1
Unknown: 0
```

No remaining path is intentionally deferred for operator decision in this PR.
Pearl production state is unchanged; this is a read-only classification update.
