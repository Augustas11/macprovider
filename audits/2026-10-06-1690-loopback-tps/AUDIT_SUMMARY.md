# #1690 M1 fix audit — loopback startup throughput + BYOM nginx route

Branch `fix/1690-loopback-startup-throughput`. Three-lane Codex audit (code,
security, architect), `omc ask codex`, anchored rounds, capped at 3 rounds.

| Round | Code | Security | Architect | Fix commit |
|---|---|---|---|---|
| R1 | C0 H1 M3 L2 | C0 H0 M1 L1 | C0 H0 M3 L2 | `9fb880247` |
| R2 | C0 H0 M0 L1 | C0 H0 M1 L0 (+ 2 out-of-scope, see note) | C0 H0 M1 L2 | `beeb86b51` |
| R3 | C0 H0 M0 L1 | C0 H0 M1 L0 | C0 H0 M1 L3 | — (cap reached) |

R2 note: the security lane's Pearl-updater HIGH (bare `sqlite3` PATH) and
MEDIUM (snapshot retention) came from a stale two-dot diff that showed main's
#1861 (`c1c637a1e`) in reverse. This branch does not touch `ops/pearl-updater`;
R3 audited the three-dot diff (`git diff origin/main...HEAD`) only.

## Carried (round cap reached)

- **MEDIUM (security R3) / MEDIUM (architect R3), same line, opposite pulls.**
  The loopback probe counts `min(upstream completion tokens, content deltas)`.
  Security: SSE delta count is not token evidence (a local upstream can split a
  token across deltas). Architect: the cap undercounts an honest engine that
  emits several tokens per delta, so loopback can rank below native.
  Bound on both: the probe requests 8 tokens, a claim above `max_tokens` fails
  closed, a usage-only reply is rejected, and the value only
  gates routing quality (`min_provider_throughput_tps`, fast ordering), never
  billing or receipts. Inflation is limited to at most 8 tokens over the real
  request time; undercount errs low. A real fix needs a trusted tokenizer at
  probe time (the SPEC-047/#1690 M5 tokenizer path), tracked as a follow-up.
- LOW (code): no URLProtocol/`URLSession.AsyncBytes` streaming test of the probe.
- LOW (architect): metadata events (finish/usage/[DONE]) sit inside the timing window.
- LOW (architect): serve dispatches the probe by downcasting to the concrete runtime.
- LOW (architect, new in R3): tool-call deltas count toward `contentDeltaCount`.

## Real-engine evidence (Mac Studio, llama.cpp b11149, Llama-3.2-3B Q4_K_M)

| Build | Probe | `/v1/status` |
|---|---|---|
| `a25ee8514` | `outcome=ok tps=146.32` (decode window) | `146.3 startup_probe` |
| `9fb880247` | `outcome=ok tps=16.72` (total elapsed, native semantics) | `16.7 startup_probe` |
| `beeb86b51` | `outcome=ok tps=23.96` | `24.0 startup_probe` |

Production floor `min_provider_throughput_tps: 1.0`; pre-fix loopback reported 0.
