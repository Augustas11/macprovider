# Phase 6 Engineering Build Report

Date: 2026-05-29

## Scope

Engineering robustness arc parallel to Phase 6 front-door work.

| Sub-phase | Status | Evidence |
|---|---|---|
| 6E1 gateway timeout parity | PASS locally | stream and non-stream gateway requests now share `CoordinatorTimeout` while remaining parented to buyer cancellation; tests cover hanging coordinator and buyer-cancel paths |
| 6E2 coordinator dead-WS fast-fail/failover | PASS locally, deploy manual | `routing.failover_enabled` and `routing.failover_timeout_s`; dead relay maps to `provider_disconnected`; one retry maximum; explicit provider/session pins do not fail over; streaming pre-first-byte can fail over and post-first-byte terminates SSE with `provider_disconnected` |
| 6E3 air5 keepalive investigation | PARTIAL/MANUAL | verbose keepalive logging added behind `MACPROVIDER_KEEPALIVE_DEBUG=1`; root-cause document filed; 24h partner observation still required |
| 6E4 fault-injection rig | PARTIAL locally | `internal/testfaults` contains build-tag-gated dead-WS relay, slow reader, and panic handler; buyer regression tests use local fault doubles for dead-WS, failover, pinning, and streaming paths; WS tests cover graceful disconnect and missed-heartbeat stale-close |

## Modified Areas

- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/server_test.go`
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/server_test.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/testfaults/`
- `phase4-coordinator/coordinator.yaml.example`
- `phase4-coordinator/dist/coordinator.yaml.example`
- `phase4-coordinator/dist/coordinator.yaml`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `specs/SPEC-002-coordinator.md`
- `specs/PHASE3_BINARY_KEEPALIVE_ROOT_CAUSE.md`
- `beta/DECISION_CRITERIA.md`

## Manual Gates

- Stage and locally smoke-test
  `phase3-binary/dist/macprovider-cli-v1.2.4-verbose-keepalive-darwin-arm64.tar.gz`.
- Operator coordinates air5 install and 24h log collection.
- Rebuild and deploy coordinator+gateway on Pearl.
- Keep G1+G2 defensive caps until Pearl smoke tests and journal watch pass.
