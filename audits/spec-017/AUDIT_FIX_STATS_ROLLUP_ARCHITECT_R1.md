# Architecture Audit Prompt — Stats Rollup Wave 7 R1

Review the current branch in `/Users/augstar/macprovider-stats` for architecture, API-contract, and operational-fit issues in the Wave 7 stats/rollup/rate-limit changes.

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
- Spec/API drift between implementation, nginx, config, and SPEC-017.
- Migration/backward-compatibility risks around `partner_keys.provider_id`.
- Operational issues in the nginx/deploy snippet path.
- Rollup locking or scheduler design tradeoffs that could block future operation.
- Test matrix gaps that should block merge.

Return findings only, ordered by severity with file/line references. If clean, say `0 C/H/M findings` and list residual low-risk gaps.
