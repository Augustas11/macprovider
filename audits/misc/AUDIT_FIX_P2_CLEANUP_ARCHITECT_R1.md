# Audit Prompt: Fix P2 Cleanup Architect R1

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

Architecture review goals:
- Verify the Tier-2 guard integration reuses existing coordinator concepts instead of introducing a parallel policy path.
- Verify request-log, billing, and fault-breaker side effects remain consistent with existing provider-error handling.
- Verify the harness response parser is strict enough to prevent false success metrics but not so strict that it rejects valid supported chat-completion shapes.
- Verify scenario validation remains centralized in the schema layer.
- Verify docs changes match the current local/live harness boundary and do not broaden the operational model beyond this cleanup.

Report format:
- Findings first, ordered by severity.
- Use `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `INFO`.
- Include exact file and line references.
- End with counts by severity and a clear `ACCEPT` only if there are 0 `CRITICAL`, 0 `HIGH`, and 0 `MEDIUM`.
