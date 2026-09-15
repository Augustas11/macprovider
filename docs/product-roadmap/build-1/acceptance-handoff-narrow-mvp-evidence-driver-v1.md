# Build 1 narrow MVP evidence-driver handoff v1

Status: local implementation slice complete. This handoff covers the executable
redacted evidence collector for the Build 1 narrow MVP physical-staging path.

## Implemented

- Added `scripts/collect-build1-narrow-mvp-evidence.py`.
- The collector reads a redacted capture manifest with schema
  `macprovider.build1-narrow-mvp-evidence-capture.v1`.
- It digests every referenced source capture, redaction-scans those sources,
  rejects symlinked/reused source files, verifies each source payload against the
  corresponding manifest claim, computes route-snapshot and artifact-binding JCS
  SHA-256 values, assembles the validator-owned evidence shape, and runs
  `scripts/validate-build1-narrow-mvp-evidence.py` before writing acceptance
  evidence.
- It writes a blocker report when no capture manifest is supplied, so absent
  hardware/staging inputs cannot become a passing physical-staging bundle.

## Required capture manifest sections

The manifest must contain exactly these top-level sections:

- `schema_version`
- `capture`
- `source_captures`
- `staging_config`
- `hardware`
- `runtime`
- `artifact_feed`
- `preparation`
- `provider`
- `admission`
- `request`
- `route_snapshot_v1`
- `settlement`
- `settlement_verdict`

The `source_captures` section must reference redacted files beside the manifest
for: physical run log, request transcript, status before, status after, provider
receipt audit, coordinator route snapshot, coordinator settlement verdict, and
redaction report. The collector records only SHA-256 digests of those files in
the final evidence bundle.

Each referenced file must be a unique non-symlink JSON object using source
schema `macprovider.build1-narrow-mvp-source-capture.v1` with exactly:
`schema_version`, `capture_kind`, `source_tool`, `captured_at`, `event_id`,
`payload_jcs_sha256`, and `payload`. The route snapshot, settlement verdict,
request transcript, provider status captures, provider receipt audit, and
physical run summary payloads must exactly match the fields that the collector
assembles into the validated bundle. Payload-only placeholders, mismatched
request/provider/model claims, reused files, symlinks, bad payload digests, and
wrong source tools fail closed.

## Commands

Blocker report when prerequisites are absent:

```bash
python3 scripts/collect-build1-narrow-mvp-evidence.py \
  --root . \
  --blocker-output /path/to/blockers.json
```

Acceptance bundle assembly after a real isolated staging run:

```bash
python3 scripts/collect-build1-narrow-mvp-evidence.py \
  --root . \
  --redacted \
  --input-manifest /path/to/capture-manifest.json \
  --output /path/to/build1-narrow-mvp.redacted.json
```

The output is accepted only if the existing validator returns `schema-valid`.

## Non-activation boundary

The collector always writes these as false in both scope and production blocker
sections: production activation, production enforcement changes, production
rewards, payout jobs, payout execution, and release publication. It does not
read operator secrets, sign journey results, publish releases, mutate production
config, or enable rewards/payout paths.

## Remaining qualification blockers

- PR #1510 and PR #1512 remain unmerged dependencies for this stacked slice.
- A measured artifact-bound staging release for the approved Llama 3B tuple is
  still required.
- The physical Apple Silicon staging run is still required before Build 1 MVP
  physical acceptance can be claimed.
