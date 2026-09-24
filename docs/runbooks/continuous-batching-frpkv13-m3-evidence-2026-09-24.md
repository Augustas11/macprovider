# FR-PKV13 production serving path — Studio evidence, 2026-09-24 (M3 of #1646)

SPEC-039 FR-PKV13 (SPEC-039-R013) and the enable gate's "Production serving
path" row require: identify the batched path that actually serves traffic,
measure its overhead against the stock contiguous path, record a ceiling it
must meet, and record the sizing table and the servable-envelope delta. This
is lab-build evidence (Swift release built on the box, `--no-join`); the gate
requires the ceiling check to be re-recorded on the packaged RC.

Raw data: [`data/cb-frpkv13-m3-2026-09-24/`](data/cb-frpkv13-m3-2026-09-24/).

## Tuple

Mac Studio M3 Ultra 256 GB, macOS 26.4.1;
`mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` @ `6e302ea6` (artifact
`10adb5da…`, MoE), paged KV attached (`KVCacheSimple`, fp16),
`continuous_batching: canary`, `max_concurrency_override: 8`, queue limit 16.

## The production serving path

After #1716's D-1 fix the batched serve path is `PagedKVSharedForwardBackend`
with **uncompiled** decode: each decode window builds a `PagedKVBatchLayerCache`
per layer over the rows' `PagedKVCache`s and runs the model once per step
through `withPreparedCache`. Equal-length rows take the lockstep-concat path on
the batch tensors; ragged rows take the per-row `update` path with a padded,
per-row-masked attention (`makeMask` with post-update lengths, per-row RoPE
offsets). The gather-feeds-SDPA parity probe at startup is a scaffold, not
this path.

Two correctness bugs in that path were found and fixed while measuring
(`309b8a85`). Before them the path was not servable at 2+ concurrent ragged
rows, so no pre-fix throughput number is meaningful:

| Before `309b8a85` | Studio evidence |
| --- | --- |
| `packFromRows` set the lockstep offset to the minimum row length for ragged rows: the first step of every rebuilt batch had no mask and wrong RoPE positions | ragged concurrent greedy rows diverged in the first tokens or emitted EOS first |
| `syncRowsFromBatch` copied padded batch tensors over per-row state | `paged_kv_block_table_mismatch`, 11 of 12 requests failed at 4 concurrent rows |

After: zero forward failures at 1–8 concurrent rows; equal-length batches
match serial exactly; ragged rows are coherent and diverge from serial only
late and deterministically (padded, masked attention sums in a different
order), with no cross-row leakage signal (`crossrow-*.jsonl`).

## Sizing table (FR-PKV13)

| Component | Size | Source |
| --- | --- | --- |
| Model weights (4-bit MoE) | 16 GB | artifact on disk |
| KV per token, fp16 | 96 KiB (48 layers × 4 KV heads × 128 head dim × 2 × 2 B) | model `config.json` |
| Idle process resident set (weights + paged block pool + MLX buffers) | ≈ 84 GB | `ps` RSS, idle lab serve |
| Paged block pool (resident set − weights) | ≈ 68 GB ≈ 700k tokens | derived |
| Envelope | 256 GB unified memory | hardware |

The SPEC names a 32 GB envelope for "the live production 30B model"; this
tuple's envelope is 256 GB and the pool reservation is sized from it. On a
32 GB Mac the same model would not hold this pool; that tuple is not
measured here and inherits nothing from this table.

## Servable-envelope delta vs stock contiguous

Recorded as **null** for this tuple. Both paths serve the 200k-token context
configured here; the paged path buys concurrency, not a larger single-request
envelope. FR-PKV13 allows a null value; none is manufactured.

## Overhead: where the time went

Profile of the batched path at 2 concurrent rows (`309b8a85`,
`profile-eager-record-n2.excerpt.txt`): of 1,196 samples in
`decodeLockstepWindow`, 468 (~39%) were in `setRowState` →
`PagedKVRuntimeContiguousCacheBridge.record` → `physicalLayerBlocks`. After
every decode window this copied every layer's full KV history for the row to
host memory, as much time as the model forward itself. Nothing on the serve path reads
those bytes (retained handoff uses the live caches; only the FR-PKV10
materialize path and its tests do). `94285581` keeps the same guards without
the copy and builds the bytes on demand at materialize time.

## Overhead measurement (interleaved A/B)

Both builds loaded side by side and alternated for every (rows, repeat), so
they saw the same background load; the live provider's CPU was sampled during
every measurement and runs above 25% mean were excluded (7 of 48). Serial =
no `X-Request-ID` (serial route); batched = fresh `X-Request-ID`. 256
completion tokens per request, greedy, 3 repeats, clean-run medians (`ab/ab.jsonl`).
All 48 runs: zero errors, zero forward failures.

| Concurrent rows | Serial tok/s | Batched, eager record (`6634a1d1` / `309b8a85`) | Batched, lazy record (`505a5766` / `94285581`) | Lazy ÷ serial |
| --- | --- | --- | --- | --- |
| 1 | ~105 | 84.9 (0.82×) | **100.2** | **0.95×** |
| 2 | ~106 | 95.2 (0.89×) | **116.4** | **1.11×** |
| 4 | ~108 | 115.6 (1.07×) | **152.2** | **1.41×** |
| 8 | ~108 | 126.6 (1.16×) | **184.6** | **1.71×** |

Serial aggregate is flat (~108 tok/s) because the serial path serializes on
the model. Caveat: another session's `--no-join` lab instance (#1689, port
18180) was resident on the box during the run; the interleaving exposes both
builds to it equally.

**Do not reuse this layout.** Two ~84 GB lab serves (each Qwen3-Coder serve
reserves its paged pool) plus the live provider exhausted the VM compressor
during the first attempt: at 2026-09-24T04:32Z the kernel killed the live
buyer-serving provider (`vm-compressor-space-shortage`, exit -9; launchd
restarted it). Re-record this A/B one lab serve at a time, restarting between
builds.

## FR-PKV13 overhead ceiling (recorded)

For this tuple the batched serving path may carry real traffic only if, on
the packaged RC, against the serial path in the same window:

1. **one active row: batched ≥ 0.90× serial** (at most 10% single-row
   overhead, the cost a lone canary request pays for being eligible), and
2. **two or more concurrent rows: batched aggregate ≥ 1.0× serial**
   (batching must never lose throughput once it has company).

Lab result: `94285581` **meets** it (0.95×; 1.11×/1.41×/1.71×). `309b8a85`
**fails** clause 1 (0.82×) and clause 2 at two rows (0.89×). Every earlier
build fails outright: wrong output (D-1), and before `309b8a85` ragged rows
failed or diverged. The ceiling must be re-recorded on the packaged RC before
it gates an enable, per the enable gate.

## What this does not claim

No fleet capacity, earnings, or slot-raise claim. No exact-token parity for
ragged rows: they match serial within the padded-attention accumulation-order
tolerance (late, deterministic divergence; `crossrow-lazy.jsonl`), which needs
the reviewed tolerance decision the old compiled-path one no longer covers.
Positive cached-prompt tokens (AC-26) stay serial and were not exercised.
