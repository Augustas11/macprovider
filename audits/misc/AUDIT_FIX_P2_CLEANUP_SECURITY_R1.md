# Audit Prompt: Fix P2 Cleanup Security R1

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

Security invariants:
- Non-streaming HTTP forwarding is covered by the same output-safety encoding guard as the WS-tunneled non-streaming path.
- Blocked Tier-2 output is not forwarded to the buyer and is not billed as a successful provider response.
- Invalid 2xx provider responses cannot be masked as successful harness requests.
- Scenario numeric config cannot survive validation with values that panic the harness or create unbounded/invalid behavior.
- Documentation changes do not instruct operators to use obsolete remote SSH controls for local chaos scenarios.

Report format:
- Findings first, ordered by severity.
- Use `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `INFO`.
- Include exact file and line references.
- End with counts by severity and a clear `ACCEPT` only if there are 0 `CRITICAL`, 0 `HIGH`, 0 `MEDIUM`, and 0 `LOW`.
