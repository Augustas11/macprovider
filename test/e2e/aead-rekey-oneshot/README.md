# #540 AEAD rekey one-shot harness

This directory contains a fail-closed evidence runner for the two remaining
physical gates in issue #540. It exercises the existing SPEC-008 v0.5
same-WebSocket rekey protocol; it does not implement another rekey path.

The live runner is intentionally narrow:

- it accepts only loopback buyer, `/poolz`, and `/healthz` URLs on the isolated
  coordinator host;
- it requires exactly one dedicated provider and records its `provider_id`,
  `assigned_id`, `connected_at`, and CLI version from `/poolz`;
- it validates the exact coordinator base and startup overlay named on the
  running coordinator process, plus the exact gateway config, both executable
  digests, and the PIDs that own all three loopback listener ports;
- it requires an isolated SQLite `request_log`, generates its own external
  request IDs, and proves the logged internal trigger ID is the one on
  `aead_rekey` while a distinct admitted sentinel drains before commit;
- it requires gateway `retry_503.enabled: false` and consumes each gate-specific
  approval once in a mode-0600 local ledger before buyer traffic begins;
- it requires the operator-approved coordinator/gateway executable SHA-256
  values plus exact provider CLI version and compatibility-set ID, and rejects
  any observed identity mismatch before buyer traffic;
- it permits at most 100 requests, 300 seconds, eight workers, and 128 output
  tokens per request (the defaults are smaller);
- it performs one HTTP attempt per buyer request, follows no redirects, stops
  new dispatch on the first buyer/pool/event failure, and never retries a full
  probe;
- it writes `evidence.json` plus issue-comment-ready `evidence.md` and returns
  nonzero unless every required invariant passes. The JSON is minimized: raw
  response bodies, full `/poolz`/`healthz` objects, process argv, config paths,
  and unrelated logs are not written.

The two overlays keep the non-target threshold above the one-shot cap. Both
thresholds are startup-only, so use the matching overlay at coordinator start;
do not attempt to apply it with SIGHUP.

Run the hermetic analyzer tests:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 \
  test/e2e/aead-rekey-oneshot/test_aead_rekey_oneshot.py
```

Evaluate a captured fixture without network or physical actions:

```bash
python3 test/e2e/aead-rekey-oneshot/aead_rekey_oneshot.py \
  --gate request_threshold \
  --dry-run-fixture /path/to/capture.json \
  --output-dir /tmp/rekey-dry-run
```

Live invocation and the mandatory approval/isolation checklist are in
`ops/runbooks/540-aead-rekey-oneshot.md`.

The harness is an operational continuity proof, not a replacement wire-protocol
test. Sequence-0 proof reservation, sequence-1 cutover, bidirectional AEAD, and
adversarial proof handling stay covered by
`phase4-coordinator/internal/ws/relay_test.go` and
`phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`.
