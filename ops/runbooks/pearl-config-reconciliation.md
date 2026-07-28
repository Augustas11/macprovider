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
  env key names, and manifest-classified overlay fields.
- `Inference`: live-only posture that the manifest classifies without mirroring
  secret or production-only values, such as registered/static provider rows.
- `Unknown`: unclassified drift. Treat any entry here as a stop condition for
  deploy; the tool exits non-zero.

To classify new drift, update `ops/pearl/config/source-of-truth.yaml` with the
owner, path, drift kind, and non-secret expected value or rationale. Keep PRs
scoped: this manifest classifies ownership only. Field-scoped migration from
live base config into `/etc/macprovider/coordinator.pearl-overlays.yaml` belongs
in the follow-up migration PR.

Never paste `/etc/macprovider/coordinator.env` values into issues, fixtures,
PR bodies, or runbooks. The reconciler prints key names only.
