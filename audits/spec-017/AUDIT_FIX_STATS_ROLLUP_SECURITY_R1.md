# Security Audit Prompt — Stats Rollup Wave 7 R1

Review the current branch in `/Users/augstar/macprovider-stats` for security and abuse-resilience regressions in the Wave 7 stats/rollup/rate-limit changes.

Scope:
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/cmd/coordinator/partnerkeys.go`
- `phase4-coordinator/internal/stats/ratelimit.go`
- `phase4-coordinator/internal/stats/mux.go`
- `phase4-coordinator/internal/stats/handlers.go`
- `phase4-coordinator/internal/stats/store/store.go`
- `phase4-coordinator/internal/stats/store/leaderboard.go`
- `phase4-coordinator/internal/stats/rollup/runner.go`
- `phase4-coordinator/internal/stats/rollup/rebuild.go`
- `phase4-coordinator/internal/stats/rollup/incremental.go`
- `phase4-coordinator/internal/buyer/streaming_downgrade.go`
- `phase4-coordinator/internal/buyer/streaming_timing.go`
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`
- `phase4-coordinator/dist/nginx-snippets/cors-429.conf`
- `specs/SPEC-017-network-stats-api.md`

Security invariants:
- Rate-limit client IP identity resolves to the true originator, not the last proxy hop, when trusted proxies are configured.
- Invalid trusted-proxy CIDRs cannot be silently accepted at startup.
- Rate-limit memory remains bounded regardless of unique-source cardinality.
- Rollup scheduler cannot be silently disabled by a single tick panic.
- Per-provider stats are returned only to a bearer bound to that provider.
- Browser-visible broad partner-key paths are explicitly deprecated and do not create a new secret-distribution requirement.
- Unauthenticated preflights cannot force unbounded DB scans.
- Streaming metric maps have bounded memory and scrape latency.

Return findings only, ordered by severity with file/line references. Security lane bar is `0 LOW`; include low-risk issues if present. If clean, say `0 C/H/M/L findings`.
