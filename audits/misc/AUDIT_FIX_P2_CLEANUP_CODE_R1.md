# Audit Prompt: Fix P2 Cleanup Code R1

Review branch `fix/deepsec-p2-cleanup` against `origin/main`.

Scope:
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase5-gateway/internal/storage/interfaces.go`
- `test/network-harness/internal/buyer/loadgen.go`
- `test/network-harness/internal/scenario/schema.go`
- `test/network-harness/README.md`
- `test/network-harness/scenarios/05_mid_stream_drop.yaml`
- `test/network-harness/scenarios/06_cold_start_race.yaml`
- `test/network-harness/scenarios/07_sustained_throughput.yaml`
- `test/network-harness/scenarios/09_streaming_ttft_distribution.yaml`

Audit objective:
- Find correctness bugs, regression risks, missing tests, and behavior mismatches introduced by this cleanup.
- Verify the coordinator non-streaming HTTP path applies the same Tier-2 non-streaming output encoding guard as the WS-tunneled path and does not leak blocked provider output.
- Verify IPv4 and IPv6 coordinator bind addresses are formatted with `net.JoinHostPort`.
- Verify harness invalid 2xx JSON/wrong-shape responses cannot count as success and are visible in metrics.
- Verify scenario numeric validation rejects values that would be nonsensical or panic at runtime.
- Verify the docs and scenario YAML edits describe current harness behavior.

Report format:
- Findings first, ordered by severity.
- Use `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `INFO`.
- Include exact file and line references.
- End with counts by severity and a clear `ACCEPT` only if there are 0 `CRITICAL`, 0 `HIGH`, and 0 `MEDIUM`.
