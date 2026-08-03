# Continuous Batching Enable Gate

Continuous batching is **default-off and inert** after the SPEC-038
implementation merge. Do not enable `continuous_batching: canary` or
`continuous_batching: on` for buyer traffic from CI, a worktree build, a unit
test pass, or a local `swift build`.

This runbook is the operator gate for enabling one exact
hardware/model/quantization/KV/runtime tuple. It is intentionally narrower than
a release checklist: it proves whether the already-packaged provider runtime may
serve real traffic with continuous batching for that tuple.

## Scope

The first enableable scope is keyless fresh-conversation decode only:

- keyless requests may enter the batch after the runtime bridge gate opens;
- under `canary`, any request carrying a conversation key is conservatively
  serial-routed until the runtime can prove that it has no reusable
  sticky/cross-turn state;
- sticky-cache-eligible or cross-turn requests must be serial-routed with
  reason-coded `batching_unsupported` telemetry under `canary`, or rejected
  fail-closed under strict `on`, until issue #887 lands;
- no batched cross-turn cache reuse may serve before the SPEC-039
  contiguous-cache runtime bridge exists;
- no buyer receipt, usage, billing, model identity, settlement, or API schema
  field may change.

The activation predicate is local descriptor membership: the requested tuple
must be admitted by the SPEC-039 paged-KV capability descriptor. A reviewed
upstream `mlx-swift-lm` batch revision is historical context only and is not an
enable path.

## Scheduler Safety Contract

The merged scheduler core is deliberately not a production runtime bridge. Any
future bridge must preserve these boundaries rather than bypass them:

- admission rejects oversized request identifiers, prompt/output context,
  stop-sequence state, queue count, and aggregate queued-token retention before
  retaining the request;
- one successful waiter is the sole settlement-eligible owner of an idempotent
  request; concurrent duplicates and terminal replays are explicitly
  non-settling, and failed delivery is never settlement-eligible;
- cancellation and delivery timeout expose only a non-settling failure at the
  hard deadline; a cancellation-insensitive sink may return later, but its live
  delivery-task slot remains quarantined until actual exit and no late delivery
  can become settlement-eligible;
- a model generation may change only after `drain()` returns a permit that the
  same scheduler validates as quiescent. A timeout or cancellation returns no
  permit, so catching a drain error is not authority to swap weights;
- decode cleanup attempts every prepared handle even if one lease cleanup
  fails, while the scheduler fails closed against new work.

These are local safety invariants, not promotion evidence. They do not satisfy
the packaged-runtime, live-model, receipt, or real-hardware gates below.

## Stop Conditions

Stop and roll back to `continuous_batching: off` if any item below is true:

- the provider is not running a packaged release-candidate install;
- `serve` resolves to a worktree/debug binary or `default.metallib` is missing;
- the SPEC-039 runtime bridge required for the tested path is unavailable;
- the requested tuple is absent from the local SPEC-039 capability descriptor;
- any sticky-cache or cross-turn request enters batching before #887 is closed;
- any token, stop condition, cancellation, usage field, receipt field, or
  request-log terminal state is attributed to the wrong request;
- a batch failure and serial retry produce stitched buyer-visible output or a
  settlement receipt;
- warm swap serves a request under one model hash and receipts it under another;
- peak RSS exceeds the recorded bound or swap/thermal state invalidates the run;
- any evidence collection would print provider tokens, buyer tokens, private
  keys, bearer headers, or raw secrets.

## Required Evidence

Record all evidence in an append-only bundle named by date, provider id, package
version, hardware tuple, and model tuple. The bundle must contain sanitized logs
only.

| Gate | Required proof |
| --- | --- |
| Package identity | Installed RC version, binary path, package provenance, `default.metallib` presence, and standalone/Malibu byte-identity proof when the RC ships both artifacts. |
| Hardware tuple | Mac model, chip, RAM, macOS build, power state, thermal state, swap state, and Entry 110 `max_concurrency_override`. |
| Model tuple | served model id, model SHA-256, tokenizer/template identity when present, cache class, KV dtype, `kv_bits` absence, MoE requirement, metallib SHA-256, kernel identifier, parity label, and pool epoch. |
| Local descriptor | SPEC-039 descriptor showing the exact tuple is admitted; unsupported tuples must show fail-closed or reason-coded serial routing. |
| Fresh-conversation scope | Requests used for the batched proof carry no conversation key; separate keyed/sticky/cross-turn requests show canary serial routing or strict rejection with `sticky_cache_bridge_unavailable` or an equivalent #887-gated reason. |
| MSB-01..05 | Full harness output for MSB-01 single-stream baseline plus MSB-02, MSB-03, MSB-04, and MSB-05. Aggregate TG is total decoded tokens over common wall-clock, warm-up excluded; per-stream and aggregate TG stay separate. |
| MoE promotion | A descriptor-admitted MoE tuple still fails closed in strict mode (or reason-coded serial-routes in canary) until the representative AC-23 correctness fixture and live-model MSB-04 evidence have landed in a separately reviewed activation change. |
| Usage/receipt attribution | Concurrent distinct requests prove correct `prompt_tokens`, `output_tokens`, `cached_prompt_tokens`, stop reason, cancellation state, request id, receipt model hash, and settlement inputs with zero cross-request attribution. |
| Deterministic parity | Temperature-0 output for each tested request matches serial path both alone and as one row in a batch. |
| Failure isolation | One-row cancellation, request-local block-extension failure, and whole-batch forward failure clean up rows/block tables without duplicate terminal output or stitched receipts. |
| Warm swap | Active prompt rows, active decode rows, and accepted queued work drain, cancel, or fail under the old served snapshot before the model changes; no receipt is bound to the wrong model hash. |
| Observability | Non-receipt telemetry records mode, reason-coded unsupported handling, active rows, waiting queue depth, batch fill, aggregate TG, per-stream TG, and local capability state without changing coordinator routing semantics. |

## Same-Hardware RC Safety

Run the real-serve proof on the exact hardware tuple that will be enabled,
preferably a non-production test provider with more than 32 GB RAM. The provider
`serve` path self-re-execs into the installed binary, and a worktree
`swift build` does not package the runtime metallib; worktree proof is not
valid enable evidence.

If testing on the development Mac, remember it runs the live production
provider. Use narrow process inspection and graceful launchd control. Do not use
broad process-kill commands.

Command templates in this section are intentionally not executed as part of this
documentation patch because they target a live provider. Substitute the actual
labels and paths from the test host, and capture sanitized output.

```bash
pgrep -af 'macprovider|Malibu'
launchctl bootout gui/$(id -u)/live.streamvc.macprovider-watchdog
launchctl bootout gui/$(id -u)/live.streamvc.macprovider
```

After the proof or rollback, restore the provider and watchdog through the
installed launchd units and verify serving health without printing tokens or
authorization headers.

## Canary Enable

No `canary` or `on` buyer traffic is currently enableable. The merged
SPEC-039 foundation deliberately reports `engineBridgeAvailable: false`, and
the scheduler backend therefore remains unavailable. Before collecting the
proofs in this runbook, a separately reviewed SPEC-039 runtime-bridge change
must install safe `PagedKVCache` injection, kernel bounds validation, request
leasing, handle release/retain, stop-token holdback, bounded token delivery
outside scheduler isolation, a hard delivery deadline and scheduler-wide
delivery-task cap that fail closed without settlement, backend cancellation
acknowledgement, and a durable request-log replay authority that atomically
claims a non-secret request fingerprint for the settlement replay horizon. The
runtime must then
derive both the requested tuple and
`schedulerBackendAvailable: true` from that installed state. Until then,
strict `on` is rejected before provider readiness and `canary` serial-routes.

After that prerequisite lands, use `canary` only when every required proof
above is present for the exact tuple. Leave `continuous_batch_queue_limit`
unset unless the evidence bundle selects a lower bounded queue for that tuple:

```yaml
continuous_batching: canary
```

If set, `continuous_batch_queue_limit` may be raised only within the measured
Entry 110 tier. Queued work never increases advertised capacity; `slots_total`
remains the validated Entry 110 value.

Do not promote `canary` to production-default `on` until Gate A5 is also green:

- `sku-econ` is green for the tier;
- sustained provider upside is material;
- tail latency and rejection rate are acceptable;
- OPoI false-positive rate is below 5%;
- the tuple still passes the same descriptor, usage, receipt, warm-swap, and
  rollback evidence after any package or model change.

## Rollback

Rollback is configuration-first:

1. Set `continuous_batching: off`.
2. Restart or reload through the same installed provider control path used for
   the test host.
3. Verify `slots_total` / `slots_free`, response schemas, receipts, and
   request-log terminal states match the serial path.
4. Confirm sticky/cross-turn requests no longer emit batching telemetry.
5. Preserve the failed evidence bundle and add the stop condition that triggered
   rollback.

Rollback must not delete evidence, mutate signed release assets, rotate secrets,
or patch an immutable public release in place.

## Evidence Template

Use this shape for the enable record:

```text
Date:
Operator:
Provider id:
Installed RC:
Binary path:
Hardware tuple:
Model tuple:
Entry 110 slots_total:
SPEC-039 descriptor hash / tuple admission:
#887 bridge status:
Fresh-conversation scope proof:
MSB-01:
MSB-02:
MSB-03:
MSB-04:
MSB-05:
Usage/receipt attribution proof:
Deterministic parity proof:
Failure isolation proof:
Warm-swap proof:
Peak RSS / swap / thermal proof:
Unsupported-mode telemetry proof:
Secrets redaction check:
Decision: canary / keep off / rollback
Follow-up:
```
