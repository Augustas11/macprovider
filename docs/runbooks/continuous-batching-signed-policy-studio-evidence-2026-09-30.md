# Signed continuous-batching policy: Studio evidence, 2026-09-30 (#1778)

## Verdict

The isolated Mac Studio campaign is a **partial pass and release hold**.

- `qwen/qwen3.5-27b`: PASS.
- `qwen/qwen3.5-35b-a3b`: PASS.
- `qwen/qwen3.8-27b`: FAIL CLOSED, reproduced twice.
- explicit emergency `off`: PASS.

This evidence does not authorize a production policy entry or close #1778.

## Boundary and provenance

- Host: `1deMac-Studio.local`, `Mac15,14`, Apple M3 Ultra, 256 GiB, arm64,
  macOS 26.4.1.
- Source revision: `7a3c3a26b7be841bf8df0a0a92bf407c08979498`.
- Binary SHA-256:
  `9d6f50945b2caea5bd17b4315f72df65093e311b4b09c96493dd9700974fda4f`.
- Ad-hoc executable CDHash: `a95af38126ea35ac91a20ccbd0a04e337aed10ae`.
- Metallib SHA-256:
  `84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf`.
- Signed policy SHA-256:
  `bcb8cac677c7d9b36411a06667996fadf1d039311e0b19f9b261480735568d4c`.
- Candidate digest:
  `f4977d19a0e09f488f9bb9f7f0f34b919aee76d0421b9a2ea4f289ce7c7510ab`.
- Policy signer: trusted `streamvc-autotune-static-v4`; the private key was
  verified only by deriving its public key in memory and comparing it with the
  committed keyring.
- Isolation: loopback feed on 18088, providers on 18091-18093, `--no-join`.
  The live provider on `127.0.0.1:8080` remained PID 30562 and was never
  restarted or replaced.

The executable was source-built and ad-hoc signed, not a packaged release
asset. Three lab-only guards were required: redirect signed feeds to loopback,
derive build identity only for the lab path, and run signed catalog preflight
while remaining `--no-join`. Therefore this campaign validates signed bytes,
tuple matching, on-device local proof, scheduler execution, and HTTP behavior;
it does not validate Malibu buyer routing, billing, receipts, settlement,
release packaging, notarization, standalone/Malibu byte identity, or updater
behavior.

## Results

| Model | Signed policy | Local proof | HTTP exercise | Result |
| --- | --- | --- | --- | --- |
| `qwen/qwen3.5-27b` | `live_verified`, authorized canary, `mixed`, paged KV attached | parity established; 16 layers; 1,024 gather calls; two-row isolation proven | four concurrent 200s, 96 completion tokens each, four `scheduler_admitted` events, maximum batch depth 4 | PASS |
| `qwen/qwen3.5-35b-a3b` | `live_verified`, authorized canary, `mixed`, paged KV attached | parity established; 10 layers; 640 gather calls; MoE two-row isolation proven | four concurrent 200s, 96 completion tokens each, four `scheduler_admitted` events, maximum batch depth 4 | PASS |
| `qwen/qwen3.8-27b` | signature and runtime provenance verified | shared-forward parity established, then isolation failed twice with `crossRowDivergences=1` and `challengeDistinguishing=false` | scheduler never activated; status reported `local_proof_result=failed`, `decision_reason=local_identity_unavailable`, mode `off` | FAIL CLOSED |

The Qwen3.8 result was deterministic across two clean process starts. The gate
did the safe thing: no policy authorization, no paged-KV attach, and no batch
scheduler.

## Emergency override

Starting Qwen3.8 with explicit `continuous_batching: off` kept the authentic
policy visible but reported `emergency_off_override=true`,
`decision_reason=emergency_off`, `local_proof_result=not_run`, paged KV
disabled, and scheduler depth zero. A serial HTTP request returned 200 with the
expected model hash.

## Remaining closure gates

1. Resolve and rerun the reproducible Qwen3.8 batched-isolation failure.
2. Build and test a reviewed, signed, notarized packaged candidate without lab
   identity or catalog-trust shims.
3. Prove standalone/Malibu embedded CLI byte identity and the updater path from
   the previous stable release.
4. Run the required real coordinator/buyer, receipt, billing, settlement, and
   warm-swap/rollback campaign with an explicitly authorized released candidate.
5. Publish a nonempty signed policy only after all exact packaged tuples pass.
