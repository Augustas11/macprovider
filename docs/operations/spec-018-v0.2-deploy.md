# SPEC-018 v0.2 Deployment Checklist

SPEC-018 v0.2 streaming latency evidence depends on clock-aligned hosts.

- Provider Macs must run an NTP-synchronized clock service before benchmark
  capture. Use `chrony` where available, or macOS `timed`/system time sync.
- Coordinator and gateway hosts must run NTP via `chrony` or `systemd-timesyncd`.
- Request-start heartbeat evidence must show provider/gateway skew within
  `|t_provider - t_gateway| <= 100 ms`.
- AC-44 latency reports must use skew-corrected
  `(t_first_gateway_byte - t_tool_call_open_detected) - skew_offset`.
