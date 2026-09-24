# AC-25 API lifecycle — Studio evidence, 2026-09-24

Phase B of [`continuous-batching-ac25-m2-plan.md`](continuous-batching-ac25-m2-plan.md)
(M2 of #1646). Lane I only; see "Lane L" below for why the live lane was not run.
Raw, sanitized JSON: [`data/cb-ac25-m2-2026-09-24/`](data/cb-ac25-m2-2026-09-24/)
(final pass at the top level, the confirming second pass under `rerun/`).

**Headline: the batched serve path produces wrong output and occasionally
hangs.** Four defects from three root causes, all fixed on this branch. D-1..D-3
were confirmed in the binaries tested: signed 176 (which served CB canary on
this tuple), candidate 181 and `main` @ `57022da8`; earlier canary binaries
(172, 175) were not tested. D-4 is in `main`'s delivery code, which Phase A did
not touch.
The lifecycle cases below were collected on the fixed build. The earlier
CB throughput and exact-token evidence is invalidated; see "What this
invalidates".

## Header

- **Date:** 2026-09-24 (UTC 2026-09-23T23:18Z–23:31Z for the final pass)
- **Binary:** campaign branch `campaign/ac25-m2-api-lifecycle` @ `93527038`, Swift release
  build on the box, sha256 `4a61ac36…6b2d`, run from its own directory with
  `mlx.metallib` sha256 `84e48718…dbaf` (byte-identical to live 181's; mlx-swift
  pins are identical between `32ea1bd0` and this branch)
- **Launch:** `serve --no-join`, `credential_store: protected_file`, port 18080.
  Serving pid executable path and sha256 asserted before every case
  (`*.binary.txt`); no case ran against a different binary.
- **Hardware / model tuple:** Mac Studio M3 Ultra 256 GB, macOS 26.4.1;
  `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` @ `6e302ea6`, artifact sha256
  `10adb5da…`; paged KV attached (`KVCacheSimple`, fp16, MoE isolation proven)
- **Lane I config:** `continuous_batching: canary`, `max_concurrency_override: 1`,
  `continuous_batch_queue_limit: 1`, `continuous_batch_queue_wait_timeout_ms: 3000`,
  plus a `continuous_batching_accepted_tuples` entry for this tuple
  (`config.sanitized.yaml`). Without that entry a #1672 build serial-routes every
  request with `tuple_acceptance_coverage_unavailable`; the first pass of this
  campaign ran that way and was discarded.
- **Live serve:** `live.malibu.provider` on 8080 untouched (candidate 181,
  `qwen/qwen3.6-27b`). No live config change, no restart.
- **Receipts:** direct HTTP carries no settlement metadata and the lab instance
  has no keypair, so every response logs `receipt_omitted` (`no_keypair` /
  `streaming_request`). Settlement disposition is therefore **not** evidenced by
  this bundle; see the ledger.

## Serve-path defects found and fixed

| # | Defect | Evidence | Fix |
| --- | --- | --- | --- |
| D-1 | **Compiled decode replays a frozen KV offset.** The serve backend ran decode under `MLX.compile`. A replayed step never re-runs `KVCacheSimple.update`'s Swift offset and grow logic, so every step after the trace writes the same KV slot at the same RoPE position. Greedy rows loop on the prompt within a few tokens. | Same prompt, temperature 0, serial vs batched: serial "The capital of France is Paris."; batched "The capital of France's capital of France's capital of France's…". Identical degenerate output on signed **176** (`b0bb4034`), candidate **181** (`304b9974`) and `main`. A build with only `compiledDecode: false` changed is coherent. | `compiledDecode: false` on the serve path (`ModelRuntime.makeContinuousBatchScheduler`). |
| D-2 | **256-token wall** (same root cause). The traced KV buffer is seed + one 256-token growth step and never grows, so every batched row fails `continuous_batching_invalid_cache_layout` → `continuous_batching_forward_failed` after exactly 256 generated tokens, streaming or not, contended or not. The 2026-09-21 "long stream passes on 176" check used `max_tokens=256`, one token short of the wall. | 4/4 solo requests with `max_tokens` 260–1024 stopped at 256 content frames then errored. Fixed build: 1024-token rows complete on both paths (`c12n`/`c12s` row A, `parity-batched-1024.json`). | Same as D-1. |
| D-3 | **Batched rows ignore the model's end of turn.** Stop sequences came only from the buyer's `stop` strings, never from the model EOS set, so every batched row ran to `max_tokens` and emitted text past the answer ("Paris.\nHuman: What is the capital…"). | Visible once D-1 was off. Fixed build: batched and serial both return 7 completion tokens, `finish_reason: stop`, same model hash, streaming and non-streaming. | Model EOS ids join the stop sequences; a trailing EOS is dropped before usage and cache accounting, as on the serial path. Harmony `<|return|>`/`<|call|>` stop the row but are not dropped (the parser reads and counts them, as on serial). |

**Buyer exposure.** Live 181 serves `qwen/qwen3.6-27b`, whose paged-KV parity
probe returns nil, so live traffic is 100% serial today and nothing is exposed
now. While the Studio served Qwen3-Coder with CB canary on under 176 (and
likely 172 / 175, untested; canary from 2026-09-20T23:01Z until the Qwen3.6
switch), any greedy, tool-free,
keyed-first-turn or keyless-with-`X-Request-ID` request that the scheduler
admitted was affected by D-1..D-3. The Pearl ledger has no routing-path
column, so the batched subset cannot be counted; most Studio traffic was
serial-routed (`request_local_state_unrepresented` is the dominant reason in the
live log).

**Throughput cost of the fix.** Batched 7-token answer: 207 ms vs 62 ms serial.
The compiled path's speed came from doing less attention work, not from
batching. No throughput claim is made here.

## What this invalidates

These were measured on the D-1 compiled path and must not be cited as
activation or promotion evidence:

- MSB-02 / MSB-04 lockstep wins (1.44× / 1.94×) —
  `continuous-batching-scheduler-lockstep-window-evidence-2026-09-20.md`,
  `continuous-batching-scheduler-compiled-evidence-2026-09-20.md`.
- MSB-03 ragged 1.73× and the "temp-0 exact token match fail at index 9 …
  compiled-graph numeric tolerance, not cross-row leak" decision —
  `continuous-batching-frcb15-leftovers-evidence-2026-09-20.md`. The divergence
  was D-1, not tolerance.
- The 2026-09-21 live-176 long-stream e2e (stopped exactly at the D-2 wall).

With compiled decode off, exact greedy parity holds for the short "capital of
France" prompt; the factorial prompt diverges in wording at about token 5
("to calculate" vs "that calculates") with coherent output, and the two
1024-token prompts diverge early with coherent output. Whether that residual is
paged-gather accumulation-order tolerance needs a fresh review on the fixed
path; the old decision does not carry over.

## Lifecycle cases (final build `4a61ac36`)

| # | Overlay clause | Result | Observed |
| --- | --- | --- | --- |
| 1 | Queue full before admission (backpressure half) | **pass** | Third request with the slot and queue occupied: 503 `continuous_batching_stream_backpressure` in 18–26 ms on both paths. `retryable: true`, `inference_ran: false`, `settlement_ran: false`. Non-stream `Retry-After: 3`; stream `retry_after: 3` in the SSE error body. |
| 2 | Queue wait timeout | **pass** | Queued request: 503 `continuous_batching_queue_wait_timeout` after 3.02 s (non-stream) / 3.21 s (stream), distinct from backpressure, crash and unsupported-tuple codes. Same retry guidance and flags as case 1. The active row completed 1024 tokens. |
| 3 | Unsupported tuple, strict mode | **pass** | `continuous_batching: on`: stderr `continuous_batching_local_capability_unavailable`, `provider startup preflight failed: ExitCode(rawValue: 2)`, exit 2, no listener. |
| 4 | Permissive/canary serial route | **pass** | `temperature: 0.7` with `X-Request-ID`: 200, serial, `reason=request_local_state_unrepresented`. No `X-Request-ID`: 200, serial, `reason=stable_request_id_unavailable`. Keyed greedy control: 200 with no serial-route line (`c4.serve-events.txt`). |
| 5a | Duplicate ID before acceptance | **pass (API)** | Two concurrent identical POSTs, same `X-Request-ID`: both 200 with identical 64-token usage in 0.78–0.84 s. With `max_batch: 1` two independent inferences would serialize (~2×); the second attached. Single settlement owner is the scheduler contract (`testDuplicateSuccessfulWaitersHaveExactlyOneSettlementOwner`), not evidenced here (no receipts on direct HTTP). |
| 5b | Duplicate ID, mismatched body | **pass** | 409 `continuous_batching_duplicate_request_mismatch` in 1 ms, `inference_ran: false`. |
| 5c | Duplicate after acceptance, within retention | **pass** | Resend returns the cached terminal result in 1 ms with identical usage; no second completion event. |
| 5d | Retention rolled | **pass** | 17 completed fillers (terminal cache 16 at queue limit 1), then resend: 409 `continuous_batching_idempotency_window_expired` in 1 ms. |
| 7a | Cancel before first token | **pass** | Socket reset 0.16 s into an ~18k-token prefill, no visible token delivered. Probe on the single slot served in 0.40 s (a leaked 1024-token row would hold it ~18 s). |
| 7b | Cancel after first token | **pass** | Reset right after the first visible token. Probe on the single slot served in 0.17 s. |
| 9 | Usage finalization | **pass (usage)** | Stop-terminated and length-terminated rows report the same `prompt_tokens` / `completion_tokens` / `macprovider_model_hash_observed` as serial. Receipt half not evidenced (no receipts on direct HTTP). |

## D-4 — batched requests hung when a token raced the drain exit (fixed)

The final pass had one batched request with no response for 600 s and no log
line. A dedicated soak reproduced it, and a lab-only lifecycle trace
(`MACPROVIDER_CB_TRACE=1`) located it:

| Soak (same workload, fresh request ids per iteration) | Binary | Requests | Stalls |
| --- | --- | --- | --- |
| Treatment, untraced | `4a61ac36` | 1040 | **4** (all after ~700 requests) |
| Treatment, traced | `6b3ecffd` | 1040 | **1** |
| Fixed, untraced | `c33c1748` (`c05a7217`) | 2015 | **0** |

The stalled request's trace stops at `sch_complete status=stop waiters=1`
with no terminal-delivery step; the healthy request before it continues
`sch_ftd delivered=true` → `sch_resumed` → `http_runtime_returned`
(`soak/trace/stalled-vs-healthy.cbtrace.txt`).

Cause: `ContinuousBatchTokenDelivery`'s drain task saw an empty queue and
released the lock before clearing `draining`. An `offer()` in that gap appended
the next token and started no drain, because `draining` was still true. The
terminal `finish(afterDraining:)` then waited on a drain that never ran, and its
timeout could not fire because `drainGeneration` was already nil. The request
got no response, and the slot was already free. Fix: `finishDrain` re-checks the queue
under the same lock that clears `draining`. The regression test
`testOfferRacingDrainExitIsDeliveredAndTerminalCompletes` lands the offer in
that gap through a test seam: it fails on the old code (completion never fires,
racing token stranded) and passes on the fix. At the pre-fix rate (0.38%), zero
stalls in 2015 requests has probability ≈ 5 × 10⁻⁴.

A control arm (`main` + D-1..D-3 fix, no Phase A) was started for attribution
and stopped: its first long row spent the run CPU-bound in
`PagedKVCache.physicalLayerBlocks` host-side KV recording and never exercised
the hang. D-4 is attributed from the code instead: the delivery class is
unchanged by Phase A.

## Lane L

Not run. The plan put cases 4 and 9 on live 8080 because they need no Phase A
code. Live has since moved to candidate 181 serving `qwen/qwen3.6-27b`, where
paged KV is unavailable and every request serial-routes. Nothing on live can
batch, so a live request cannot show a *reason-coded divergence from a batching
path* (case 4) or batched usage finalization (case 9). Both ran on Lane I instead,
against the tuple that actually batches. That avoids buyer-serving traffic and
keeps one evidence class (Phase A build) for the whole bundle.

## Ledger

Proven on the packaged-shape lab build (direct HTTP): cases 1 (backpressure
half), 2, 3, 5a (API attach), 5b, 5c, 5d, 7a, 7b, 9 (usage half).

Open, AC-25 does **not** close:

- Case 6, reconnect/replay through the relay with settlement disposition.
- Case 1's `:614` retry guidance to the buyer through the gateway: the provider
  emits it; the three Go forwarding gates still drop it.
- 5a / 9 settlement halves: single owner and receipt parity need the relay path.
- Cases 8a / 8b: fixture-only by decision (no fault-injection hook).
- Case 10: warm-swap drain.

The enable-gate API lifecycle row stays unchecked.

## Do not

- Re-enable CB canary on any Qwen3-Coder or other paged-KV-eligible tuple on a
  binary without D-1..D-3 fixed. That is every signed or candidate binary to date.
- Cite the invalidated evidence above for activation, slot raises or MoE promotion.
- Treat this bundle as receipt or settlement evidence.

## Secrets redaction check

Case JSON holds status codes, error codes and flags, token counts, timings and
lab request ids. Content is recorded only as SHA-256 and length
(`parity-*.json`). The on-box model path is replaced with the catalog id; lab
paths are `<lab>/`. No provider or buyer tokens, keys or bearer headers.
