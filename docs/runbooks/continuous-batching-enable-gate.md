# Continuous Batching Enable Gate

Continuous batching is **default-off and inert** after the SPEC-038
implementation merge. Do not enable `continuous_batching: canary` or
`continuous_batching: on` for buyer traffic from CI, a worktree build, a unit
test pass, or a local `swift build`.

> **Stop — 2026-09-24.** Signed 176, candidate 181 and `main` @ `57022da8`
> (the binaries tested; earlier canary binaries are unverified) produce wrong
> output on the batched path: compiled
> decode replays a frozen KV offset (greedy rows loop on the prompt and die at
> exactly 256 generated tokens), and batched rows ignore the model's end of
> turn (serial vs batched A/B on the Studio). Do not set `continuous_batching: canary` or `on` on any
> paged-KV-eligible tuple until a binary containing the fix on
> `campaign/ac25-m2-api-lifecycle` ships. Live 181 is unaffected only because
> `qwen/qwen3.6-27b` is not paged-KV eligible; switching the Studio back to
> Qwen3-Coder with canary on would re-expose buyers. The MSB-02/03/04
> throughput wins and the "temp-0 index-9 tolerance" decision were measured on
> the broken path and are invalid. Evidence: #1646.

This runbook is the operator gate for enabling one exact
hardware/model/quantization/KV/runtime tuple. It is intentionally narrower than
a release checklist: it proves whether the already-packaged provider runtime may
serve real traffic with continuous batching for that tuple.

## Scope

The first enableable canary scope is first-turn traffic, including Pearl
auto-prefix / buyer conversation keys on a cache miss:

- keyless requests may enter the batch after the runtime bridge gate opens;
- conversation-keyed **first-turn / cache-miss** requests (`cached_prompt_tokens
  = 0`) may enter the batch; a conversation key alone is not a serial-route;
- keyed requests with **positive** cached-token credit still serial-route
  until AC-26 packaged sticky/cross-turn proof, even if retained paged KV
  exists;
- #1477 sticky paths remain present as code, not as permission to credit
  sticky cache hits in canary;
- the SPEC-039 contiguous-cache primitive (FR-PKV10) already landed in
  #887 / #1476; that merge did **not** lift sticky cached-token credit;
- a keyless loopback 200 is not proof that Pearl-routed keyed traffic batched;
- no buyer receipt, usage, billing, model identity, settlement, or API schema
  field may change.

The activation predicate has two conjuncts (SPEC-038 FR-CB10). The requested
tuple must be admitted by the SPEC-039 paged-KV capability descriptor, **and**
the operator must have declared that tuple in
`continuous_batching_accepted_tuples`. Before #1672 only the first was
enforced, and the one acceptance-shaped gate was a global compiled constant
every Mac inherited. A build containing #1672 fail-closes: an undeclared tuple
serial-routes with reason `tuple_acceptance_coverage_unavailable`, and strict
`on` is rejected at startup. `v1.8.176` predates #1672.

A reviewed upstream `mlx-swift-lm` batch revision is historical context only
and is not an enable path.

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
- the tested path relies on gather-every-step paged KV for real serving and
  exceeds the SPEC-039 FR-PKV13 overhead ceiling; gather-feeds-SDPA parity is
  correctness evidence, not sufficient production-throughput evidence;
- the requested tuple is absent from the local SPEC-039 capability descriptor;
- the first keyless serving-path request admitted by the scheduler does not
  return HTTP 200 / `finish_reason=stop` through the scheduler path;
- any request with positive `cached_prompt_tokens` enters the batch before
  AC-26 packaged sticky/cross-turn proof, even if a retained paged-KV
  handoff exists;
- any token, stop condition, cancellation, usage field, receipt field, or
  request-log terminal state is attributed to the wrong request;
- a batch failure and serial retry produce stitched buyer-visible output or a
  settlement receipt;
- queue-full, queue-timeout, cancellation, duplicate request ID, reconnect, or
  replay behavior produces duplicate inference, duplicate terminal events,
  missing retry guidance where required, or duplicate settlement;
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
| Acceptance coverage | On a build containing #1672, the tuple is declared in `continuous_batching_accepted_tuples` and the declaration matches the runtime-measured identity exactly. Record the declared entry alongside the measured tuple. An undeclared tuple is the `tuple_acceptance_coverage_unavailable` serial route, not an enable. |
| Production serving path | The batched path that will serve real traffic is identified and measured. If gather-feeds-SDPA is used only as parity scaffold, record the actual shared-forward path; if gather-every-step is used, prove it meets the SPEC-039 overhead ceiling. Also record the FR-PKV13 define-and-record obligations for this tuple: the sizing table apportioning the unified-memory envelope across model weights, per-request activation, and the paged block pool; the minimum model/context envelope the paged path serves that the stock contiguous path cannot (null or negligible is an acceptable honest value); and the overhead ceiling itself. A throughput number measured on a worktree build is scaffold evidence — the ceiling check that gates enable must be re-recorded on the packaged RC. |
| Keyless scheduler 200 | A local loopback and relay-shaped keyless request with stable request ID enters the scheduler path and returns HTTP 200 / terminal success from batching, not serial fallback and not `continuous_batching_prefill_failed`. |
| Keyed first-turn scheduler 200 | A Pearl-shaped request with a conversation key, stable request ID, and `cached_prompt_tokens = 0` enters the scheduler (no `serial_routed reason=conversation_key_rollout_unavailable`) and returns HTTP 200. Keyless loopback is not a substitute. |
| Sticky/cross-turn scope | First-turn keyed traffic may batch. Any positive `cached_prompt_tokens` stays serial until AC-26 packaged proof, even with a retained FR-PKV10 handoff. |
| Sticky retained-KV proof | Before sticky/cross-turn batching with positive `cached_prompt_tokens` can enter canary, drive a sticky/cross-turn request through the gateway/relay path, reattach or materialize same-conversation paged KV via FR-PKV10, prove mid-block LCP/trim correctness, and verify usage, billing, receipt, and settlement fields. |
| Durable replay authority | Stable relay request identity is mapped into scheduler replay keys, settlement disposition is propagated through usage/receipt code, and duplicate inference or duplicate settlement is rejected after local terminal-result retention rolls. `ContinuousBatchRuntimeReplayAuthority` is **already durable**: a file-backed claim store in a `0700` directory holding `request_id_sha256` + `fingerprint_sha256` records, wired to the inbound `X-Request-ID`, and #1500 closed that prerequisite. Only the `inMemoryForTests` variant is non-durable, and only it is disqualified. The outstanding gap is packaged proof that reconnect/replay after a terminal result carries the correct settlement disposition through usage/receipt code — not the existence of the authority. |
| MSB-01..05 | Full harness output for MSB-01 single-stream baseline plus MSB-02, MSB-03, MSB-04, and MSB-05. Aggregate TG is total decoded tokens over common wall-clock, warm-up excluded; per-stream and aggregate TG stay separate. |
| MoE promotion | Production `moePromotionEvidenceAvailable` is true after [`continuous-batching-moe-activation-2026-09-20.md`](continuous-batching-moe-activation-2026-09-20.md). Descriptor membership still does not promote a MoE tuple by itself. Studio 176 is the live serving canary; fleet CB stays off. Do not set `on`. |
| Usage/receipt attribution | Concurrent distinct requests prove correct `prompt_tokens`, `output_tokens`, `cached_prompt_tokens`, stop reason, cancellation state, request id, receipt model hash, and settlement inputs with zero cross-request attribution. |
| Deterministic parity | Temperature-0 output for each tested request matches serial path both alone and as one row in a batch. |
| Failure isolation | One-row cancellation, request-local block-extension failure, and whole-batch forward failure clean up rows/block tables without duplicate terminal output or stitched receipts. |
| API lifecycle | Through the packaged HTTP/relay serving surface, prove the whole of SPEC-038 AC-25: queue-full backpressure with retry guidance, queue-timeout rejection, **unsupported-tuple strict failure**, **permissive/canary serial-route telemetry**, duplicate request ID before/after acceptance, reconnect/replay after terminal result, cancellation before/after first buyer-visible output, post-admission scheduler failure before/after side effects, **successful usage finalization**, and warm-swap/operator-disable drain. Each case must show exactly one terminal outcome, the correct settling/non-settling disposition, and no duplicate receipt. In-process scheduler unit fixtures cover these cases today; they are not AC-25 evidence, which requires the HTTP surface. |
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
launchctl bootout gui/$(id -u)/live.malibu.provider-watchdog
launchctl bootout gui/$(id -u)/live.malibu.provider
```

After the proof or rollback, restore the provider and watchdog through the
installed launchd units and verify serving health without printing tokens or
authorization headers.

## Canary Enable

No `canary` or `on` buyer traffic is currently enableable from implementation
presence alone. #1477 landed retained paged-KV consumer code and #1500 is the
production observation / durable-replay prerequisite. Operators still need a
packaged release-candidate tuple whose local descriptor admits the
requested path, whose runtime derives `schedulerBackendAvailable: true` from
a **measured** identity (not an injected test tuple), and whose durable replay
authority is wired to stable relay request identity plus usage/receipt
settlement disposition. That wiring landed in #1500 — the runtime authority is
file-backed and keyed on the inbound `X-Request-ID`, so the open item is
packaged settlement disposition across reconnect/replay, not the existence of
the authority. Until those packaged proofs exist for the exact tuple, strict
`on` is rejected before provider readiness and `canary` serial-routes.

2026-09-20 Studio 172 attempt: paged-KV attach and MoE isolation passed;
keyless canary then 503'd `continuous_batching_prefill_failed` after scheduler
admission and was rolled back. See
[`continuous-batching-canary-172-enable-2026-09-20.md`](continuous-batching-canary-172-enable-2026-09-20.md).

2026-09-21 Studio 175: same keyless live-8080 probe returned HTTP 200 after
the serve-path prefill fix. Canary is on for that Studio tuple only. See
[`continuous-batching-canary-175-enable-2026-09-21.md`](continuous-batching-canary-175-enable-2026-09-21.md).
Do not promote `canary` to `on`. Do not canary other Macs.
Any other tuple must still prove scheduler-path HTTP 200 on a packaged
candidate and green API lifecycle evidence before canary traffic.

Use `canary` only when every required proof above is present for the exact
tuple. Leave `continuous_batch_queue_limit` unset unless the evidence bundle
selects a lower bounded queue for that tuple:

```yaml
continuous_batching: canary
```

If set, `continuous_batch_queue_limit` may be raised only within the measured
Entry 110 tier. Queued work never increases advertised capacity; `slots_total`
remains the validated Entry 110 value.

Do not promote `canary` to production-default `on` until Gate A5 is also green:

- `sku-econ` is green for the tier;
- sustained provider upside is material — throughput ratios versus the serial
  path are necessary but not sufficient; A5 asks for provider economics, so the
  bundle must convert measured aggregate TG into tier earnings terms;
- tail latency and rejection rate are acceptable;
- OPoI false-positive rate is below 5%. **No implementation computes this
  number today.** The OPoI v0 signal exists (coordinator canary probes plus
  `phase4-coordinator/internal/pow/drift.go`), but nothing counts
  CB-attributable false positives against a defined denominator, and the `< 5%`
  figure entered the gate from a research prompt rather than a measured series.
  Before A5 can be claimed, define the numerator (canary/drift failures
  attributable to batching on the enabled tuple), the denominator, and the
  measurement window, then build the counter. Per SPEC-031 / SPEC-032 the OPoI
  signal stays observability-only: it may gate this promotion decision, and it
  must never gate routing, tiering, sanctions, or payout;
- the tuple still passes the same descriptor, usage, receipt, warm-swap, and
  rollback evidence after any package or model change.

Gate A5 is normative (SPEC-038 FR-CB15, §8 G5) and is a **separate gate**, not
a byproduct of the evidence rows above. Track it as its own item: a checklist
that carries only the serving-path and lifecycle proofs is incomplete.

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
Production serving path and FR-PKV13 overhead ceiling:
FR-PKV13 sizing table (weights / activation / block pool within envelope):
FR-PKV13 minimum servable envelope delta vs stock contiguous (null allowed):
Evidence class of each proof below (packaged RC / isolated lab worktree):
Acceptance-coverage declaration vs measured tuple (#1672 builds):
Keyed first-turn scheduler HTTP 200 proof (packaged):
#887 FR-PKV10 primitive status (landed #1476; not an enable signal):
#1477 sticky/AC-19 consumer status (landed #1489; not an enable signal):
#1500 production observation / durable replay status:
Fresh-conversation scope proof:
Keyless scheduler HTTP 200 proof:
Sticky retained-KV / mid-block trim proof:
MSB-01:
MSB-02:
MSB-03:
MSB-04:
MSB-05:
Usage/receipt attribution proof:
Deterministic parity proof:
Failure isolation proof:
API lifecycle proof:
Queue-full / Retry-After proof:
Queue-timeout proof:
Cancellation proof:
Duplicate request ID / reconnect replay proof:
Warm-swap proof:
Peak RSS / swap / thermal proof:
Unsupported-mode telemetry proof:
Unsupported-tuple strict-failure proof:
Successful usage-finalization proof:
Gate A5 `sku-econ` result:
Gate A5 provider upside in tier earnings terms:
Gate A5 tail latency / rejection rate:
Gate A5 OPoI false-positive rate (numerator / denominator / window):
Secrets redaction check:
Decision: canary / keep off / rollback
Follow-up:
```
