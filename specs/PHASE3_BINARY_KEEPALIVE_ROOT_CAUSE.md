# Phase 3 Binary Keepalive Root Cause

Status: **RESOLVED 2026-05-29 — the disconnects were server-side, not a
phase3-binary keepalive defect. No client (v1.2.5) change was required.**

## Resolution (2026-05-29, post-Pearl-deploy live investigation)

After deploying the Phase 6 coordinator + gateway to Pearl and exercising
the live money path, the "provider disconnects / failed inference" symptom
was root-caused to **two independent server-side causes**, both fixed
without any partner binary update:

1. **Coordinator 35s heartbeat-miss kill (Phase 6 regression).** The Phase 6
   `monitorHeartbeat` closed a provider WebSocket when no *heartbeat* arrived
   within `heartbeat_interval_s + failover_timeout_s` (= 35s). A provider
   doing single-threaded MLX inference cannot heartbeat while its one slot is
   busy generating, so any generation longer than ~35s was killed mid-request.
   **Fixed** (SPEC-002 v1.1.7): liveness is now measured from the last inbound
   frame of ANY type (in-flight `inference_response_chunk` frames count as
   activity), and the threshold is a dedicated `pool.heartbeat_miss_threshold_s`
   (default 90s) decoupled from `failover_timeout_s`. Verified live: a healthy
   provider (air5, Qwen-7B) completed an 800-token / 40.5s streaming generation
   cleanly (HTTP 200) where pre-fix it would have died at 35s.

2. **Gateway 120s upstream timeout (config drift).** The deployed
   `gateway.yaml` had `timeouts.coordinator_request_seconds: 120`, while the
   template and the coordinator's `routing.request_timeout_s` are both 300.
   The gateway's upstream HTTP client to the coordinator therefore aborted at
   exactly 120s (observed `wall_ms=120096`, error `coordinator_unavailable`),
   tearing down the in-flight relay. Affected slow providers whose full
   non-streaming response exceeded 120s (e.g. the 8GB augustass box at
   ~0.59 tps + cold model load). **Fix: realign live gateway.yaml to 300s.**

The original NAT-idle hypothesis was disproven: idle providers (air5)
stayed connected for hours; the failures occurred only during/after long
inference, consistent with the two server-side timeouts above.

## Original investigation notes (superseded)

## Local Evidence

- `phase3-binary` v1.2.4 sends coordinator heartbeats at the interval
  supplied by `hello_ack.heartbeat_interval_s`.
- The production coordinator default is 30 seconds, which is below the
  expected 3-5 minute consumer-router NAT idle window.
- This build adds `MACPROVIDER_KEEPALIVE_DEBUG=1`, which logs WebSocket
  resume, receive errors, inbound frame types, outbound frame types, and
  heartbeat cadence to stderr with centisecond timestamps. The resume log
  redacts URL userinfo, query, and fragment fields.

## Hypotheses

| Hypothesis | Current status | Evidence needed |
|---|---|---|
| NAT idle timeout | Unproven | air5 log showing no local close frame and a receive error near 3-5 minutes despite 30s heartbeats |
| Client heartbeat cadence too long | Locally unlikely | air5 log showing coordinator advertises an interval above 240s or heartbeats are not emitted |
| Coordinator heartbeat threshold race | Possible | Pearl log showing `provider heartbeat stale` immediately before air5 close while air5 kept sending heartbeats |
| TLS/proxy stickiness | Possible | air5 receive error plus nginx/coordinator logs showing no matching application close |

## Observation Plan

1. Build and stage
   `phase3-binary/dist/macprovider-cli-v1.2.4-verbose-keepalive-darwin-arm64.tar.gz`.
2. Operator gives the staged tarball to the air5 partner and runs the
   binary with `MACPROVIDER_KEEPALIVE_DEBUG=1`.
3. Collect the partner log after 24 hours and align it with Pearl
   coordinator journal timestamps.

## Interim Conclusion

No SPEC-001 normative change is filed yet. The implementation already
uses a 30 second application heartbeat when connected to the current
coordinator defaults. The next decision depends on partner logs: if the
client is not emitting heartbeats, fix the client; if heartbeats continue
but the socket dies, add lower-level TCP keepalive or proxy-specific
mitigation; if the coordinator closes first, fix coordinator heartbeat
threshold handling.

The current verbose logging is sufficient to align client-side frame
cadence and receive errors with Pearl journal timestamps, but it is not a
root-cause conclusion by itself. Close-source attribution remains a manual
observation gate.
