# Issue #1807 Mac Studio validation evidence

Date: 2026-10-01

## Scope

This evidence package covers issue #1807 steps 1 and 2 for the proposed
8GB/16GB trial allocation:

- 16GB candidate: `mlx-community/Qwen3.5-9B-4bit`
- 8GB candidate: `mlx-community/Ministral-3-3B-Instruct-2512-4bit`

Result:

- `mlx-community/Qwen3.5-9B-4bit`: PASS for the tested 16GB-class one-slot
  claim at 32K context.
- `mlx-community/Ministral-3-3B-Instruct-2512-4bit`: NO-GO for the proposed
  8GB catalog claim as written. The model loads and handles plain chat, SSE,
  cancellation recovery, and 8K over-context rejection, but fails strict
  JSON-mode output and does not emit normalized OpenAI `tool_calls`.

Do not sign a buyer-serving 8GB Ministral catalog row that advertises structured
output or tool support from this evidence. Either fix/revalidate that behavior
or deliberately scope the catalog/runtime claim to chat-only before signing.

## Host and runtime boundary

- Hardware host: `1deMac-Studio.local`
- Hardware model: `Mac15,14`
- Unified memory: `274877906944` bytes
- Runtime binary: `/Users/a1/macprovider/macprovider-cli --version` = `1.8.207`
- Live provider boundary: existing provider remained listening on
  `127.0.0.1:8080`; validation used separate loopback ports with `--no-join`.
- Local Air boundary: no hardware workload was run on `Augustas-Air.local`
  (`Mac17,3`).
- Evidence root on the Studio:
  `/Users/a1/issue-1807-validation/20261001T050717Z`

Validation command shape:

```text
macprovider-cli serve --no-join --model <candidate> --port <isolated-port>
  --max-context <validated-context> --max-batch 1
  --continuous-batching off --continuous-batch-queue-limit 2
  --no-idle-prewarm
```

## Qwen3.5-9B 16GB candidate

- Evidence file:
  `/Users/a1/issue-1807-validation/20261001T050717Z/qwen35_9b_16gb_trial.json`
- Model: `mlx-community/Qwen3.5-9B-4bit`
- Port: `18127`
- Context tested: `32768`
- Batch/concurrency tested: one slot, `--max-batch 1`
- Startup: `25.06s`
- Cache snapshot:
  `/Users/a1/.cache/huggingface/hub/models--mlx-community--Qwen3.5-9B-4bit/snapshots/8b2b98c00a6b4d291155e4890773ca8f769aee53`
- Cache size: `5977073303` logical bytes across `13` files
- RSS after ready: `11045056` KB
- RSS after request matrix: `11049568` KB

Validation matrix:

| Check | Result |
| --- | --- |
| `/v1/models` readiness | PASS |
| Non-streaming chat | PASS, HTTP 200 |
| Streaming chat | PASS, HTTP 200, `[DONE]` observed |
| `response_format: {"type":"json_object"}` | PASS, valid JSON content |
| Function tool payload | PASS, normalized OpenAI `tool_calls` emitted |
| Client-side stream cancellation | PASS |
| Post-cancellation follow-up request | PASS, HTTP 200 |
| Over-context rejection | PASS, HTTP 413 `context_length_exceeded`; no inference or settlement |

Qwen is eligible for the proposed 16GB trial row at the validated one-slot,
32K-context claim, subject to the signing session pinning the final catalog
artifact identity.

## Ministral 3 3B 8GB candidate

- Evidence files:
  - `/Users/a1/issue-1807-validation/20261001T050717Z/ministral3_3b_8gb_trial.json`
  - `/Users/a1/issue-1807-validation/20261001T050717Z/ministral3_3b_structured_retry.json`
- Model: `mlx-community/Ministral-3-3B-Instruct-2512-4bit`
- Port: `18128` for the main matrix, `18129` for structured-output retry
- Context tested: `8192`
- Batch/concurrency tested: one slot, `--max-batch 1`
- Startup after cache acquisition: `3.04s`
- Cache snapshot:
  `/Users/a1/.cache/huggingface/hub/models--mlx-community--Ministral-3-3B-Instruct-2512-4bit/snapshots/a962dcb09eee4169c890e544c9eb938f1113fdee`
- RSS after request matrix: `4828464` KB

Initial acquisition note: the released CLI refused the uncached HF id with
`model load target must resolve to a local snapshot directory`. The snapshot was
then acquired with `huggingface_hub.snapshot_download`, after which the same
HF id loaded successfully.

Validation matrix:

| Check | Result |
| --- | --- |
| `/v1/models` readiness | PASS |
| Non-streaming chat | PASS, HTTP 200 |
| Streaming chat | PASS, HTTP 200, `[DONE]` observed |
| `response_format: {"type":"json_object"}` | FAIL, HTTP 502 `malformed_json_response` |
| Function tool payload | FAIL for OpenAI shape; response text contained `[TOOL_CALLS]...` and no `tool_calls[]` |
| Forced structured-output retry | FAIL, three stricter JSON prompts returned HTTP 502 |
| Forced `tool_choice` retry | FAIL, no normalized OpenAI `tool_calls` emitted |
| Client-side stream cancellation | PASS |
| Post-cancellation follow-up request | PASS, HTTP 200 |
| Over-context rejection | PASS, HTTP 413 `context_length_exceeded`; no inference or settlement |

Ministral is not ready for the proposed 8GB trial allocation unless the signed
catalog explicitly avoids structured-output and tool-capability claims, or the
runtime/model pairing is fixed and revalidated.

## Llama coverage floor

The trial must preserve the Llama compatibility floor from issue #1807:

- 16GB fleet: keep Llama 3.1 8B on 40% of the 16GB placement while testing
  Qwen3.5-9B on the other 60%.
- 8GB fleet: keep Llama 3.2 3B coverage for compatibility and existing buyers.
  Because Ministral failed the full validation gate, do not move 80% of the 8GB
  placement to Ministral yet.
- Do not add Qwen3 8B for this trial while its OpenRouter route is scheduled
  for 2026-10-09 deprecation.

## Allocation math

If and only if both candidate rows pass their validated runtime claims:

| Hardware class | Trial split | Runtime limit |
| --- | --- | --- |
| 16GB | 60% `Qwen3.5-9B-4bit`, 40% Llama 3.1 8B | one slot, 32K context |
| 8GB | 80% Ministral 3 3B, 20% Llama 3.2 3B | one slot, only validated 8K-16K context |

Current evidence supports the 16GB split but blocks the 8GB Ministral split as
written.

## Rollback path

Current repo catalog baseline:

- Release id: `published-2026-09-25-artifact-hash-correction-v1`
- `phase3-binary/catalog/autotune/autotune-candidates.json` SHA-256:
  `f4977d19a0e09f488f9bb9f7f0f34b919aee76d0421b9a2ea4f289ce7c7510ab`
- `phase3-binary/catalog/autotune/release.json` SHA-256:
  `a3cbed44f9de0fed738771dbe19e1a430f000738a860ddcfbc99dbdfb1240c12`

The signing session must confirm the live Pearl predecessor matches a release
ledger row before deploy. If a signed #1807 catalog commit is later produced,
deploy it through `docs/runbooks/catalog-release-decision-tree.md` content lane
only. Roll back through that runbook if candidate instability appears,
capabilities or context are over-advertised, provider downtime dominates the
comparison, catalog claims diverge from runtime behavior, or demand telemetry
cannot distinguish served, unmet, capacity-constrained, and substituted traffic.

## Telemetry readiness

Demand telemetry is landed in PR #1812 (`2be9975a6dff`) and documented in
`docs/runbooks/gateway-demand-telemetry.md` plus
`docs/runbooks/catalog-release-decision-tree.md` (`bd8a99a8dfb`). It records
attempted requests without prompt/completion content and can separate requested,
served, unmet, capacity-constrained, and substituted traffic for the #1807
observation window once the trial allocation is live.

## Stop condition

Step 2 is not fully green. The next safe catalog action is to sign only the
validated 16GB Qwen claim, or to fix/revalidate the 8GB Ministral structured
output/tool-call gap before signing the proposed 80% Ministral allocation.
