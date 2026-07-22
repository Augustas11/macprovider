# AUDIT_235 R3 — re-audit after R2 fixes (thermal-soak instrument)

Branch `research/235-thermal-soak` (macprovider). R2 findings were all fixed.
RE-VERIFY, in your lane, that each is resolved AND introduced no regression.
Report CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line. Merge bar: 0 C /
0 H / 0 M. Read CURRENT files. `go build/test/vet` green in `test/network-harness`.

## R2 fixes to verify

### Security / code / architect — prod-reachability (was the R2 HIGH on all lanes)
The R1 streamvc.live DENYLIST was bypassable (trailing root dot, IDNA/full-width
separators, uppercase, and it was skipped when `benchmark.enabled=false`). R2
replaces it with a POSITIVE lab-host ALLOWLIST:
- `LabHostAllowed(host)` in `internal/scenario/schema.go` accepts ONLY loopback /
  RFC1918-private / link-local IPs or `"localhost"` (host canonicalized:
  lowercased, trailing dot trimmed). Every public host — prod, subdomain, apex,
  trailing-dot, full-width/ideographic-dot, arbitrary FQDN — is rejected.
- The guard runs whenever the scenario declares `B10`, **regardless of
  `benchmark.enabled`** (`BenchmarkHasB10()`), because the sustained buyer load
  runs even when scoring is off.
- `loadgen.go` sets `CheckRedirect` for B10 scenarios so a lab gateway cannot
  3xx-redirect the soak to a non-lab host.
- Regression test `TestB10_LabOnly_RejectsProdHost` covers loopback/localhost/
  private/ipv6 ok; prod apex/subdomain/uppercase/trailing-dot/full-width/
  ideographic-dot and arbitrary public host rejected; disabled-benchmark still
  guarded; non-B10 still allowed to target prod.
  Verify: is there ANY remaining value (URL form, env expansion, redirect,
  userinfo, IP-encoding trick like decimal/hex/IPv4-mapped-IPv6) by which a B10
  scenario reaches a public host? Confirm the allowlist has no false-negative
  that would reject a legitimate loopback/LAN lab, and no new regression.

### Architect / code — thermal join B10 parity + stale skew
- `join-thermal.py` `streaming_tps()` now mirrors B10's success filter
  (`outcome == "ok"` and `http_status < 400`), so a failed stream with partial
  usage no longer contributes a TPS point (overlay matches the scored
  population). Verify field names match `per_request.jsonl` (`outcome`,
  `http_status`, `stream`, `start_utc`, `ttft_ms`, `completion_tokens_received`,
  `last_byte_utc`).
- `nearest_thermal` now returns `(None, None)` beyond `--max-skew-seconds` (null
  skew), matching the docstring + README. pmset/powermetrics still matched
  independently with per-channel skew.

### Architect — envelope wording + SPEC example
- README and `15_thermal_soak.yaml` now say scenario 15 is ONE stress point and
  the safe-load envelope needs a D3 sweep (was: "produces the envelope").
- SPEC §5 artifact example now shows `scenario: 15_thermal_soak`,
  `duration_seconds: 3600` (a <600s run SKIPs with zero windows, so the old
  07/300s example with nonzero `sustained_tps` was impossible).

## Carried LOW (documented, not blocking)
- `join-thermal.py` loads both inputs fully into memory / rescans each channel
  per bin — a local operator post-processing tool run on the operator's own
  files; acceptable for the parked campaign.

Focus your lane: are the R2 fixes resolved, and did any create a NEW C/H/M?
