# Code Audit Prompt — Stats Rollup Wave 7 R1

Review the current branch in `/Users/augstar/macprovider-stats` for code correctness regressions in the Wave 7 stats/rollup/rate-limit changes.

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

Look for:
- Broken route dispatch, rate-limit accounting, refund paths, or nil dereferences.
- Rollup scheduler/rebuild/incremental correctness bugs.
- Streaming metric retention or scrape bugs.
- Config default/validation mistakes.
- Missing or misleading tests for changed behavior.

Return findings only, ordered by severity with file/line references. If clean, say `0 C/H/M findings` and list residual low-risk gaps.
