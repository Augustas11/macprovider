# Phase 3 Binary Keepalive Root Cause

Status: investigation staged; partner observation pending.

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
