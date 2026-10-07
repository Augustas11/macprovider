# #1690 acceptance closeout — 2026-10-07

This is an in-progress evidence record, not an issue-completion or production
Creator-launch claim. Work continues in #1879. Existing coordinator v1.8.221
and signed member CLI v1.8.222 remain the production binaries.

## Fresh isolated journeys

Both captures ran on the designated Mac Studio (`Mac15,14`) from reviewed
source `eedd1c1456242afab775072bef622a68c3b634a0`, with isolated test storage and
HTTP handlers. No production activation or live-provider replacement occurred.

- Layer2: `MACPROVIDER_CAPTURE_TRUSTED_POOL_LAYER2=1 go test ./internal/buyer
  -run '^TestJourneyTrustedPoolLayer2MVPCandidate$' -count=1 -v` — PASS, 1.018 s.
  Redacted artifact: `journeys/evidence/trusted-pool-layer2-20261007T043021Z.redacted.json`.
  SHA-256: `5f89940ccaa13581e5bef8c14140f039ee724473b280245389f64e1d3391e83f`.
- Creator MVP: `MACPROVIDER_CAPTURE_TRUSTED_POOL_CREATOR_MVP=1 go test
  ./internal/trustpool -run '^TestJourneyTrustedPoolCreatorMVPCandidate$'
  -count=1 -v` — PASS, 8.458 s.
  Redacted artifact: `journeys/evidence/trusted-pool-creator-mvp-20261007T043959Z.redacted.json`.
  SHA-256: `7d3700d668ccd7caa086d2a29a70e2d3ebba119ddde8bf7595f41fdd6d2db664`.

These are unsigned captures until the protected main signing workflows run.
Neither capture fills production conformance or proves an external Creator launch.

## External-runtime capture correction

The private production capture `trusted-pool-external-runtime-20261007T053340Z`
stopped at the old `no-selector-no-pool` control: HTTP 200 disclosed
`mlx_cache`, a legitimate native global route for the same catalog model.
This is a failed capture, not signed journey authority or an external-engine
global bypass. Its original private responses are retained unchanged.
SPEC-006 and SPEC-042 permit that native route. The replacement negative is
`pool-native-selector`: selecting native on the llama.cpp-only M1 pool must
return 503 `engine_unavailable`, with zero route snapshots and ledger rows.
The corrected contract requires a new complete capture before signing.

## Production SPEC-043-R007 timing

Four runs used Pearl's public production gateway, the unchanged 150 ms server
floor, 200 samples per class, and class order shuffled each round. The llama.cpp
pool was paused only for each run and verified active/routeable after restoration.
Gateway-wide service and the Ollama pool were not paused. Credentials and pool
identities are absent from the retained numeric samples and evaluator outputs.

| UTC run start | Measurement client | p95 gap, ms | p99 gap, ms | Minimum U-test p | Result |
| --- | --- | ---: | ---: | ---: | --- |
| 04:29:13 | Original client, TLS context per request | 18.3721 | 0.4294 | 0.3883 | FAIL (p95 > 15 ms) |
| 04:33:03 | Same client with experimental shared TLS context | 0.3881 | 2.7482 | 0.3303 | PASS, diagnostic comparison only |
| 04:39:02 | Corrected repository tool, no context monkeypatch | 0.7843 | 1.7374 | 0.5286 | PASS, historical production remeasure |
| 05:24:07 | Corrected repository tool with fail-closed redirects | 1.0472 | 2.9109 | 0.0606 | PASS, current official production remeasure |

The comparison supports eliminating repeated client TLS setup as measurement
noise; it does not establish a universal absence of a timing oracle. All runs,
including the failure, are retained as `r007-<timestamp>.samples.json` and
`r007-<timestamp>.result.json`. The experimental result is explicitly
machine-marked `diagnostic_only` / `production_remeasure_complete: false`;
its original evaluator claim and original output SHA-256 are recorded without
treating that claim as authoritative. The official result binds its source
blob, tool SHA-256, sample SHA-256 and nonexperimental command shape.
Evaluation uses nearest-rank percentiles and
the unchanged thresholds: p95 <= 15 ms, p99 <= 25 ms, minimum two-sided
Mann–Whitney p >= 0.01. The final client requires exactly HTTP 503 and parsed
JSON `error.code == "pool_unavailable"`; each sample still opens a fresh HTTP
connection and rejects all redirects without forwarding credentials. The current
05:24:07 measurement tool SHA-256 is
`ab947c8dcb3a30992e1d80e10556c802858f348a83d5b17a5b051d2ca4238378`.
The earlier results retain their original source hashes as historical evidence.
A later tool hardening additionally requires fresh private class-precondition
proof before future production HTTP measurements.

Targeted regression command:
`PYTHONDONTWRITEBYTECODE=1 python3 -W error::ResourceWarning -m unittest
scripts.tests.test_pool_rejection_timing_floor` — 28 tests PASS.

## Still blocking completion

- Protected signatures for the fresh isolated captures and signed production
  external-runtime journey remain pending.
- R007 class-state binding is being tightened after review found that client
  labels alone do not prove unknown/unauthorized/disabled preconditions.
  Existing numeric runs are retained, but no issue-closeout authority is claimed
  until a fresh measurement binds those states and distinct inputs.
- Before operator-approved cleanup, the gateway had 20 global ACTIVE
  settlement-held reservations. The scoped
  released-binary relay-blind reconciler returned `held=1`, `errors=0` for the
  latest reservation; it did not refund or debit it. Ordinary release dry-runs
  proposed releasing 19 older holds with inconclusive finality. The operator
  explicitly approved those exact 19 releases. Rechecked and applied through
  the existing released gateway's audited endpoint: 17,433 reserved quota
  tokens returned, zero buyer debits/cash transfers, active backlog 20 -> 1.
  `historical-holds-approved-release-summary.json` records the bounded result;
  per-reservation dry-run/apply records remain in the private operator store.
  The newer relay-blind hold is excluded and remains held. The production
  journey's old global-zero hold check is broader than SPEC-022-R012 and
  SPEC-042-R013/R014: their forward acceptance requirements concern the
  pool requests' own finality, debit and ledger credit. Global draining is a
  separate rollback precondition. A versioned run-scoped check is being
  implemented; unrelated backlog remains explicit operational context, not
  a global-health or rollback-readiness claim. Financial SQL has not been
  manually rewritten.
- A carried #1863 MEDIUM concerned startup TPS trusting stream fragmentation
  rather than a trusted token count. The closeout patch uses the existing
  artifact-bound pinned tokenizer, with SPEC-001 v1.9.31 / SPEC-002 v1.6.9.
  `swift test --jobs 2 --filter OpenAICompatibleLoopbackRuntimeTests` on
  Studio exited 1 before running tests: the installed Command Line Tools
  toolchain lacks XCTest. Its generated lockfile change was restored. GitHub
  macOS/Xcode verification, combined review, and reviewed signed rollout
  remain pending; no unreviewed local binary has replaced a live provider.
- Formal mixed-version evidence and qualification for the current pool models
  remain pending. Public external Creator launch is a separate SPEC-043 scope;
  no named external operator or hardware-backed production root is fabricated.
