# Throughput — explicit non-adopts

**Date:** 2026-07-07  
**Source:** T0-03 egress profile + exploration classifier  
**Status:** ACTIVE unless live PERF_TRACE returns YELLOW/RED

| Item | Bucket | Reason | Re-open trigger |
|------|--------|--------|-----------------|
| #479 NWConnection transport | C | No serial outbound pipeline; `BlockingChunkBuffer` + direct `sendFrame` | T0-03 live trace RED (>15% egress) |
| #480 ChunkBatcher / AsyncStream bypass | C | Inbound AsyncStream only; chunks not on outbound AsyncStream | Same |
| #476 shutdown actor hop | C | Structure not present | — |
| #475 serial WS outbound | C | Not present | — |
| v0.6.26 TCP_NODELAY | C | Requires NWConnection | #479 adopted |
| #483 DH precompute | B (N/A) | Session HKDF already (`Tier2ProviderSession.swift:79-100`) | — |
| bf16 weight cast | — | Net-negative on M5 (`audits/2026-06-30/perf-mlx-engine.md`) | New hardware evidence |
| Layr-Labs fork submodule | — | Clean-room; use ml-explore pins | Never by default |

**T0-03 verdict:** MAINTAIN DEFER for NWConnection cluster (structural GREEN, medium-high confidence).
