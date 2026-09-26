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
| Acceptance coverage | On a build containing #1672, the tuple is declared in `continuous_batching_accepted_tuples` and the declaration matches the runtime-measured identity exactly. Record the declared entry alongside the measured tuple. An undeclared tuple is the `tuple_acceptance_coverage_unavailable` serial route, not an enable. From SPEC-038 v0.2.5 (#1716), each entry also carries `metallib_sha256` and `kernel_identifier`: the runtime revision the evidence was measured on, printed at serve start on the `[paged-kv] runtime-identity` line. Declare the entry only after that exact packaged build meets the FR-PKV13 overhead ceiling. A new candidate with a different metallib or kernel serial-routes until it is re-measured and re-declared. |
| Production serving path | The batched path that will serve real traffic is identified and measured. If gather-feeds-SDPA is used only as parity scaffold, record the actual shared-forward path; if gather-every-step is used, prove it meets the SPEC-039 overhead ceiling. Also record the FR-PKV13 define-and-record obligations for this tuple: the sizing table apportioning the unified-memory envelope across model weights, per-request activation, and the paged block pool; the minimum model/context envelope the paged path serves that the stock contiguous path cannot (null or negligible is an acceptable honest value); and the overhead ceiling itself. A throughput number measured on a worktree build is scaffold evidence — the ceiling check that gates enable must be re-recorded on the packaged RC. |
| Keyless scheduler 200 | A local loopback and relay-shaped keyless request with stable request ID enters the scheduler path and returns HTTP 200 / terminal success from batching, not serial fallback and not `continuous_batching_prefill_failed`. |
| Keyed first-turn scheduler 200 | A Pearl-shaped request with a conversation key, stable request ID, and `cached_prompt_tokens = 0` enters the scheduler (no `serial_routed reason=conversation_key_rollout_unavailable`) and returns HTTP 200. Keyless loopback is not a substitute. |
| Sticky/cross-turn scope | First-turn keyed traffic may batch. A positive-`cached_prompt_tokens` turn batches only when all three hold: `continuous_batching_cached_turns` is on, the lease carries a usable retained FR-PKV10 handoff (on a hybrid tuple such as Qwen3.6, plus a recurrent checkpoint), and the accepted-tuple entry covering this exact runtime revision records `cached_turns_accepted: true` (SPEC-038 v0.2.9). Otherwise it serial-routes in canary and fails closed in `on`, logging `reason=cached_turns_not_accepted` when only the grant is missing and `reason=sticky_cache_handoff_unavailable` otherwise. |
| Sticky retained-KV proof (AC-26) | Run this on the packaged build before setting `cached_turns_accepted: true` on its accepted-tuple entry, and record it next to that entry. Drive a sticky/cross-turn request through the gateway/relay path, reattach same-conversation paged KV via FR-PKV10, prove mid-block LCP/trim correctness, and verify usage, billing, receipt, and settlement fields. For a hybrid tuple, include a checkpoint-resumed turn whose `cached_prompt_tokens` equals the checkpoint length. During the proof run, enable `continuous_batching_cached_turns` (env `MACPROVIDER_CONTINUOUS_BATCHING_CACHED_TURNS`, CLI `--[no-]continuous-batching-cached-turns`, default off) with the grant set on an isolated, non-live provider. On a live provider, turn the flag on only after the grant is recorded for that exact revision; a new metallib or kernel needs a new proof. Serve start prints `event=batching_cached_turns action=enabled mode=...`, or `action=inert` while batching is off. Record that line. |
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

Gate A5 may establish eligibility for a future reviewed package/feature release.
It never authorizes production-default `on` or an OPoI-driven provider/model
tier transition. Any eventual `on` rollout is a separate reviewed release and
configuration decision. Before that decision, Gate A5 evidence must show:

- `sku-econ` is green for the tier;
- sustained provider upside is material — throughput ratios versus the serial
  path are necessary but not sufficient; A5 asks for provider economics, so the
  bundle must convert measured aggregate TG into tier earnings terms;
- tail latency and rejection rate are acceptable;
- focal row-zero OPoI false-positive rate is below 5%, measured by the offline
  `scripts/measure_gate_a5_opoi_false_positives.py` counter described below;
- the tuple still passes the same descriptor, usage, receipt, warm-swap, and
  rollback evidence after any package or model change.

Gate A5 is normative (SPEC-038 FR-CB15, §8 G5) and is a **separate gate**, not
a byproduct of the evidence rows above. Track it as its own item: a checklist
that carries only the serving-path and lifecycle proofs is incomplete.

### Gate A5 OPoI false-positive measurement

The input is schema-v4 durable JSON or JSONL. It embeds the exact canonical,
signed pre-window PLAN envelope and declares one campaign/provider/
run, one exact hardware/model/quantization/KV/runtime/binary tuple, packaged
artifact and runtime-bundle SHA-256 values, canonical evaluator and challenge-
bank revisions, a half-open UTC window no longer than 3,600 seconds, and a pair
gap no greater than 60 seconds. The schema is closed and strictly typed at every
object level. Duplicate JSON keys, Boolean versions, strings longer than 4,096
characters, nesting deeper than 12 levels, more than 4,096 pairs, completed
JSON/JSONL input above 4 MiB, raw-event bundles above 8 MiB, JSONL lines above
256 KiB, non-regular input paths, and reports above 16 MiB fail closed. Stdin
is byte-bounded by the same 4 MiB completed-input limit.

Before the window opens, the reviewer controls and commits the selection seed,
then the plan author signs the complete PLAN envelope. It binds campaign,
tuple, artifact, evaluator, window, gap, a closed canonical candidate frame,
its digest/revision, the seed, and schedule. The counter ranks the whole frame
without replacement, requires every scheduled focal challenge to equal the
derived selection, and derives arm order from the within-stratum ordinal plus
seed/stratum. Both orders must be balanced within every stratum (difference at
most one). This custody and pre-signing commitment is a manual reviewer control;
the counter cannot prove that the reviewer did not seed-shop. An
independent reviewer then signs a receipt binding the plan SHA-256 and a
pre-window time; retain it in reviewer-controlled append-only storage. It contains
60 to 4,096 scheduled pairs and globally unique pair, challenge-issuance,
request, and event identities for both measured arms and all companions. Every
scheduled pair must be present exactly once; unscheduled, extra, replayed, or
missing observations fail the whole measurement. Both arms must occur within
the declared pair gap of their signed scheduled time and in the predeclared
strict order: `batch_then_serial` requires batch time before serial time, while
`serial_then_batch` requires serial time before batch time. Equal times fail.
The reviewer-controlled receipt store and its append timing are also external
manual trust assumptions.

Each raw source capture is a closed bounded record with a unique stable locator,
actual challenge payload and digest, actual response transcript and digest, a
closed evaluator output (`pass` or `fail`) and evaluator revisions, runtime
mode/forward/full membership, artifact/runtime/campaign provenance, identities,
and observed time. The counter derives normalized `opoi_pass` solely from this
closed output; normalized duplicates are not trusted.
The batching capture must record `continuous_batching` execution with one globally
unique measured forward, the declared row count, distinct event/request IDs and
row indexes, the measured row, and every predeclared companion. Every companion
source capture must bind the same campaign, tuple, artifact, evaluator, pair and
challenge issuance; its own predeclared challenge, workload, request, event and
`batch_companion` arm; its own execution row index; and the identical complete
membership record. Derived companion `opoi_pass` is semantically ignored by the
paired numerator and denominator. Serial evidence
records one row, no shared forward, and row index zero. The counter reads the
bounded raw bundle, recomputes its exact file digest and derived events, requires
the source identity set to equal the complete predeclared set, and requires
each completed observation to equal its derived event. It never accepts a
precomputed `false_positive` value.

The metric is explicitly limited to the predeclared focal row-zero observation
in each shared forward. Companion outcomes are audit and membership evidence,
not observations in this metric. All-row promotion requires separate per-row
evidence and is outside this Gate A5 counter. The denominator is every
otherwise-valid focal pair whose serial control passes. A
batching pass counts only when its serial control also passes. The numerator is
the subset where batching fails and the serial control passes — the only
automatically batching-attributable false positive. Batch fail plus serial fail
is inconclusive/upstream and excluded from both counts. Batch pass plus serial
fail is also inconclusive; it cannot improve the rate. Any invalid or
inconclusive pair fails the complete measurement closed, as do duplicate pair
IDs, tuple/challenge mismatch, malformed or non-finite fields, observations
outside the window, excess pairing gap, and a zero denominator.

The threshold is strict: `numerator / denominator < 0.05`; exactly `0.05`
fails. At least 60 eligible pairs are required. In addition, the one-sided exact
Clopper-Pearson 95% upper confidence bound on the false-positive probability
must be below 5%. Thus a small cherry-picked sample cannot pass even when its
observed rate is zero.

Authenticity uses `/usr/bin/ssh-keygen -Y`. The plan author, independent reviewer,
and evidence custodian are separate principals with separate keys. The reviewer
controls the reviewer key and append-only receipt/source-review store; do not put
all keys in operator secret storage. Use strict one-line trust files; each line is exactly
`principal key-type base64-key`, without options, wildcard, principal list, or
comment. The counter records fingerprints and rejects equality across the three
roles. After collection the reviewer inspects source locators, payloads,
transcripts, evaluator outputs, runtime membership, provenance, and times, then
signs an `approved` source-review object binding plan and exact raw-file SHA-256
under its own namespace. The custodian signature covers that review object.
Reviewer custody, review quality, seed commitment, and append-only timing remain
manual external trust assumptions; counter success does not establish them and
does not alone satisfy Gate A5.

```bash
# Before the window, author standalone closed PLAN and receipt envelopes,
# extract their canonical payloads to new paths, and sign those exact bytes.
python3 scripts/measure_gate_a5_opoi_false_positives.py \
  gate-a5-opoi-plan-envelope.json \
  --prepare-plan-payload gate-a5-opoi-plan.json

ssh-keygen -Y sign \
  -f /path/to/plan-secret-key -n malibu-gate-a5-opoi-plan-v4 \
  gate-a5-opoi-plan.json

python3 scripts/measure_gate_a5_opoi_false_positives.py \
  gate-a5-opoi-receipt-envelope.json \
  --prepare-receipt-payload gate-a5-opoi-receipt.json
ssh-keygen -Y sign -f /path/to/reviewer-secret-key \
  -n malibu-gate-a5-opoi-plan-receipt-v4 gate-a5-opoi-receipt.json

# After collection, review and sign the source-review object first.
python3 scripts/measure_gate_a5_opoi_false_positives.py \
  gate-a5-opoi-completed.json --raw-bundle gate-a5-raw-events.json \
  --prepare-source-review-payload gate-a5-opoi-source-review.json
/usr/bin/ssh-keygen -Y sign -f /path/to/reviewer-secret-key \
  -n malibu-gate-a5-opoi-source-review-v4 gate-a5-opoi-source-review.json

# Then preflight the same raw bundle and sign completed evidence.
python3 scripts/measure_gate_a5_opoi_false_positives.py \
  gate-a5-opoi-completed.json --raw-bundle gate-a5-raw-events.json \
  --prepare-evidence-payload gate-a5-opoi-canonical.json

ssh-keygen -Y sign \
  -f /path/to/evidence-secret-key \
  -n malibu-gate-a5-opoi-evidence-v4 \
  gate-a5-opoi-canonical.json

python3 scripts/measure_gate_a5_opoi_false_positives.py \
  gate-a5-opoi-completed.json --raw-bundle gate-a5-raw-events.json \
  --plan-signature gate-a5-opoi-plan.json.sig \
  --plan-trust /path/to/plan-trust --plan-principal gate-a5-plan \
  --receipt-signature gate-a5-opoi-receipt.json.sig \
  --source-review-signature gate-a5-opoi-source-review.json.sig \
  --reviewer-trust /path/to/reviewer-trust --reviewer-principal gate-a5-reviewer \
  --evidence-signature gate-a5-opoi-canonical.json.sig \
  --evidence-trust /path/to/evidence-trust --evidence-principal gate-a5-evidence \
  --output gate-a5-opoi-report.json
```

The canonical payload and report paths are create-only; choose new paths for a
rerun. Report success occurs only after the complete report is flushed, fsynced,
atomically linked at `--output`, and its directory fsynced. `--also-stdout` may
copy that durable report to stdout; a broken stdout pipe returns nonzero.

The report binds the canonical input, plan, receipt, raw-bundle digest, signed
source review, counter, four signatures, three trust snapshots/principals, and
key fingerprints. Preserve
them in append-only storage. Reviewers rerun the pinned counter, compare report
bytes, recompute its SHA-256, and publish that digest; mismatch is tamper evidence.

For JSON, the completed schema-v4 document has this top-level shape. The
embedded `plan` is the byte-identical signed PLAN envelope; each pair event must
equal the event independently derived from the separately supplied source capture:

```json
{
  "schema": "malibu.gate_a5_opoi_completed_evidence",
  "version": 4,
  "plan": {
    "schema": "malibu.gate_a5_opoi_plan",
    "version": 4,
    "campaign": "<closed campaign object>",
    "tuple": "<closed tuple object>",
    "artifact": "<closed artifact object>",
    "evaluator": "<closed evaluator object>",
    "window": "<closed UTC window object>",
    "max_pair_gap_seconds": 60,
    "sampling_design": "<closed seed, frame revision/digest, full candidate frame, strata, and methods>",
    "scheduled_pairs": ["<complete predeclared manifest>"]
  },
  "plan_sha256": "<64 lowercase hex>",
  "plan_receipt": {
    "schema": "malibu.gate_a5_opoi_plan_receipt",
    "version": 4,
    "plan_sha256": "<same plan digest>",
    "received_at": "<UTC time before plan.window.start>"
  },
  "raw_bundle_sha256": "<digest of exact raw-bundle file bytes>",
  "source_review": "<closed approved post-collection review object binding plan/raw SHA and reviewer identity>",
  "pairs": [
    {
      "pair_id": "probe-0001",
      "batching": "<closed normalized event derived from source capture>",
      "serial_control": "<closed normalized event derived from source capture>"
    }
  ]
}
```

This tool is offline campaign evidence for M6/manual release-quality feature
promotion review only. It does not call the coordinator or provider, change
live configuration, promote or demote a provider/model tier, or feed routing,
tiering, admission, degrade/sanction, payout, billing, receipt, settlement, or
other money logic. SPEC-032 FR-PW2/FR-TD1 remains the enforcement ceiling;
building this counter does not make OPoI weight-binding evidence and does not
claim A5 green.

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
Gate A5 focal row-zero OPoI rate / eligible count / exact 95% upper bound / window:
Gate A5 all-row evidence status (separate; outside this counter):
Gate A5 plan SHA-256 / reviewer-controlled seed commitment / receipt time and append-only location:
Gate A5 plan-author / independent-reviewer / evidence-custodian identities and key fingerprints:
Gate A5 raw-bundle location / SHA-256 / signed source-review disposition and signature:
Gate A5 manual reviewer custody / review-quality / append-only-timing confirmation:
Gate A5 canonical-input / report SHA-256 / byte-for-byte recomputation result:
Secrets redaction check:
Decision: canary / keep off / rollback
Follow-up:
```
