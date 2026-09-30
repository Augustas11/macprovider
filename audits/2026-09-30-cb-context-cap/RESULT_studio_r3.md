# Studio R3 isolated-loopback acceptance

Date: 2026-09-30

Verdict: PASS for the provider-runtime hardware gate at source commit
`275c1cffc17eab0dae3c3f3c6b442fa9af163b5e`.

Rebase traceability: the source commit's stable patch ID
`3c23c768b9d67b90f68a631d92c8877df5ce50ce` is carried by reachable squash
commit `9eb1553bc5c10c13e3053894b6802ba7858587e0` (#1806).

## Boundary proof

- Host: `1deMac-Studio.local`, Mac Studio `Mac15,14`, Apple M3 Ultra,
  256 GB.
- Campaign snapshot: `/Users/a1/campaign/cb-context-cap-r3`.
- Release binary SHA-256:
  `9f98615dee35f7ddec5807d294b249a1e82518ec68b9597c39ff5b580039514e`.
- Candidate listener: isolated `127.0.0.1:18083` with `--no-join`,
  `--credential-store protected_file`, and `--isolate-lifecycle`.
- Live provider PID 30562 on the installed binary remained running and was
  never signalled, replaced, or rebound. Port 8080 was untouched.
- The plain SwiftPM release product used the installed version-matched
  `mlx-swift_Cmlx.bundle` beside the candidate binary. Runtime identity logged
  metallib SHA-256
  `84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf`.

## Runtime proof

The candidate loaded `qwen/qwen3.6-35b-a3b` with a 512-token served-context
test cap, completed paged-KV parity and MoE row-isolation self-tests, and logged
`event=batching_admitted action=scheduler_admitted` for all three completion
requests below.

| Case | Request shape | Result |
| --- | --- | --- |
| Omitted `max_tokens` | internal output cap 8 | HTTP 200, `completion_tokens=8`, `finish_reason=length` |
| Explicit `max_tokens=64` | internal output cap 8 | HTTP 200, `completion_tokens=8`, `finish_reason=length` |
| Streaming, omitted `max_tokens` | internal output cap 8, usage requested | HTTP 200, final `completion_tokens=8`, `finish_reason=length` |
| Prompt beyond served context | internal output cap 8 | HTTP 413 `context_length_exceeded`, `inference_ran=false`, `settlement_ran=false` |

This proves the real Qwen3.6 continuous-batching scheduler composes the
authenticated dispatch budget with both omitted and explicit body limits and
rejects an over-context prompt before inference.

## Scope and cleanup

The isolated provider was stopped after evidence capture and port 18083 no
longer had a listener. The live provider remained PID 30562.

This lab run directly proves provider-runtime enforcement on real hardware.
Gateway-to-coordinator metadata propagation, HTTP/WS/Tier-2 preservation,
buyer 413 normalization, receipt hashing, and settlement behavior remain
covered by the branch's targeted tests and GitHub CI; the isolated provider
had no receipt keypair, so it intentionally logged `receipt_omitted`.
