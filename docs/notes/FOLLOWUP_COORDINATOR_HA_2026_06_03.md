# Coordinator HA Follow-Up

Date: 2026-06-03
Source: `specs/FIX_SPEC_AUDIT_2026_06_03_V1_0.md` T1.9

## Current Blast Radius

The coordinator remains the in-memory authority for active provider sessions,
assigned IDs, routing pool state, in-flight request ownership, sticky session
state, warmup status, and circuit-breaker state. A coordinator restart drops
that memory. Connected providers must reconnect and re-register before new
buyer traffic can route. In-flight coordinator requests can fail during the
restart window; gateway quota and concurrency reservations must settle or refund
from the gateway side.

The gateway does not currently provide real multi-coordinator failover. The
gateway config must not advertise a dormant coordinator failover list until an
actual failover implementation exists.

## Tracked Work

1. Externalize coordinator provider/session/routing state, or introduce an
   active-standby coordinator design with explicit ownership transfer.
2. Add real gateway multi-coordinator failover only after the coordinator side
   exposes a durable state model that can make retries safe.
3. Add a staging restart exercise to the release checklist: connected providers
   must reconnect, re-handshake, pass warmup when required, and serve traffic
   after the coordinator restarts.

## Current Mitigations

- Provider binaries already re-enter the reconnect loop after coordinator drain;
  `CoordinatorClientTests.testPostDrainReconnectLoopReentersConnectPath` covers
  the local reconnect path.
- Provider connections now carry WebSocket ping traffic from the binary and TCP
  keepalive on the coordinator socket.
- The provider binary starts a local no-sleep assertion while a coordinator
  session is accepted.
