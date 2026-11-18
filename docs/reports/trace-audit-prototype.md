# Trace audit prototype (lab pilot, campaign #2419)

Status: prototype on `campaign/trace-audit-pilot`, built and unit-tested on the
M5. It has run once against Qwen2.5-7B-Instruct-4bit on an Apple M5; see
"Measurements" (one run, under a Mac that was not idle; the prompt-cache and
native-MTP cases were not exercised).
Spec: SPEC-036 §5B (FR-27 to FR-31). Design basis: `keryx-watch`
`research/RESULTS-v2.md`.

## Design as built

| Piece | File |
|---|---|
| Leaf encoding, RFC 6962 tree (streaming root, FR-31 multiproof and its check), FR-29 draw rule, residual store, forward row map | `phase3-binary/Sources/MacProviderCore/TraceAudit.swift` |
| MLX capture hook, request lifecycle, drain to the store | `phase3-binary/Sources/macprovider-cli/TraceAuditLabCapture.swift` |
| Provider-side opening (`trace_opening_v1` lab file) | `phase3-binary/Sources/macprovider-cli/TraceAuditLabOpening.swift` |
| `macprovider-cli trace-audit-lab open` and `trace-audit-lab measure` | `phase3-binary/Sources/macprovider-cli/TraceAuditLabCommand.swift` |
| Verifier (checks 1 to 6) | `phase3-binary/scripts/trace-audit-lab-verify.py` |
| Measurement driver | `phase3-binary/scripts/trace-audit-lab-measure.sh` |
| Unit tests | `phase3-binary/Tests/MacProviderCoreTests/TraceAuditTests.swift` |

**Switches.** All capture code compiles only into `DEBUG` and
`MACPROVIDER_LAB_HARNESS` builds; a release build carries none of it.
Inside a lab build it runs only with `MACPROVIDER_TRACE_AUDIT_LAB=1`; with the
flag off, each call site reads one static Bool. No config key was added: the
flag is environment-only in the prototype. The release-build `submit` gains
one forwarding call (`submit` -> `submitScheduled`); nothing else changes. The
decode-path digest was regenerated (`scripts/decode_path_digest.py --write`)
because `ContinuousBatchScheduler.swift` and `PagedKVRuntimeBridge.swift` are
manifest files.

**Store settings** (environment): `MACPROVIDER_TRACE_AUDIT_LAB_DIR` (default
`~/Library/Caches/macprovider/trace-audit-lab`; refused if it lies inside the
KV disk tier directory), `..._MAX_BYTES_PER_REQUEST` (default 2 GiB),
`..._MAX_TOTAL_BYTES` (default 8 GiB, FR-30), `..._WINDOW_SECONDS` (default
600, FR-30). A committed trace is deleted on release, after its opening, or
when its window ends, 10 minutes after the commitment (a timer at commitment
plus a sweep at every finalize). When a new write would pass the total cap,
the store first deletes expired traces; if the cap is still exceeded, the
request gets `storage` and serving continues. On start the store deletes
every file in its directory.

**Leaf, order, tree.** As FR-28: `"mp.trace.leaf.v1\0" || u32le kind ||
u32le block || u32le position || payload`, leaf index `p * (L + 2) + j`,
RFC 6962 split at the largest power of two below `n`, no odd-node promotion.
The streaming builder keeps a stack of perfect subtrees (O(log n) memory) and
folds it right to left at the end; a test checks it against the RFC recursion
for 1 to 130 leaves.

**Positions.** Absolute position = the row's committed KV length before the
forward plus the column (prefill chunk) or plus the step index (lockstep
decode window). `TraceAuditForwardRow.rows(...)` builds this per forward from
the backend's own inputs, so it follows rows that join, leave or change order
between sessions. A request commits `prompt_positions + n - 1` positions (n =
raw generated tokens, stop token included); positions a lockstep window ran
past the stop are cut at finalize.

**Capture path.** Per forward: the hooks keep references to the block inputs
(lazy MLX arrays); after the model call the capture stacks them to
`[rows, T, L+1, H]` float16, keeps only rows being captured, and queues an
`asyncEval`. Older queued forwards are copied to disk while the next step
runs; every backend operation (prefill group, decode window) ends with a
drain, so a request's residuals are on disk before the scheduler finalizes
it. The residual file has a fixed stride (`(L+1) * H * 2` bytes per
position), written with `pwrite`, so a re-run position (serial fallback after
a rejected shared prefill, window overshoot) overwrites in place. While
capture is on, the compiled decode step is not used (serving already runs
uncompiled: `compiledDecode: false` on the serve path).

**Root.** Built at finalize on a background queue by streaming the residual
file through the incremental builder (constant memory), not during decode.
This keeps the capture path to one memcpy per row and makes overwrites and
the window cut trivially correct. Cost: the root is ready some time after the
response; the measurement records that delay (FR-28 allows 10 s). The same
pass writes `<key>.tokens` (u32le input, served per position), `<key>.lh`
(leaf hashes, for openings) and `<key>.meta.json`. Files are mode 0600,
deleted on release, at window end, on a marker, and every leftover file is
deleted when the store starts (FR-30).

**Storage cap.** On exceeding the per-request or total cap the request is
marked `storage`, its files are deleted and it gets no root (the marker
replaces it, FR-28 "exactly one of root and unavailable").

**Opening** (`TraceAuditLabOpening.write`). FR-31 content: for each block
point and the block-0 point, the committed block-`l` inputs at `0..p`, the
next leaf at `p` and the provider's internal leaves; for each output point,
only the final residual at `p`; plus the block-0 leaf of every prompt position
and the token-pair leaf of every position. Layout: `MPTRACEOPEN1\n`, u64le
JSON length, a JSON header (`request`, `draws`, `leaves` = the sorted opened
leaf indices, `proof` = one multiproof as `[level, index, hash]` nodes, each
once), the raw leaf payloads in index order, then the internal leaves. A node
`(level, index)` is the RFC 6962 subtree of size at most `2^level` starting at
leaf `index * 2^level`; every subtree of the split rule starts at such a
boundary, so the name is unique. The multiproof is the minimal node set: the
walk emits a subtree hash wherever no opened leaf lies below it. The checker
refuses a missing, duplicate or unused node. The cap is 160 MiB; the
measurement records `over_cap` per opening. The provider's internal leaves
are recomputed in float32 (dequantized weights, Accelerate `sgemm`); they are
inputs to check 3 only.

**Draws.** FR-29 step 3 exactly: `min(k, L * N)` block points
(a duplicate of an earlier block point is drawn again), one block-0 point over
the prompt positions (it may coincide with a block point), then `min(k, n)`
output points without repeats over the emitting positions `P-1 .. N-1`. A
Swift test pins one draw vector computed independently with Python integers;
the verifier re-derives the points from `nonce_1` and compares.

**Verifier** (`trace-audit-lab-verify.py`), per FR-31:

1. Recomputes the root from the multiproof over all opened leaves, checks
   that every required leaf is present, and checks the draws against
   `nonce_1`.
2. Runs mlx-lm's own block module in float16 over the committed inputs
   `0..p`. Passes when `‖rec − next‖ / (‖rec − input‖ + 2^-14) ≤ 2e-2`.
3. Draws one element per internal kind from `nonce_2`. At that element it
   applies the one operation in float64 to the provider-supplied (or
   committed) inputs and compares with the round-2 normalisers:
   - norms from the committed input or the provider's mid residual;
   - matmuls from the provider's source vector;
   - attention from the provider's q, rotated at `p`, against K and V that
     the verifier recomputes from the committed inputs.

   This check locates a failure inside a block; check 2 decides the block.
4. Token chain: `served[p] = input[p+1]` for `p = P-1 .. N-2`. In the lab,
   the manifest's token ids stand in for tokenizing the request.
5. Every prompt block-0 leaf matches its embedding row within 1e-3.
6. The verifier's own float16 teacher-forced forward over the committed ids.
   At each output point the argmax must equal the served token. A
   disagreement with a logit gap below 0.05 is `inconclusive:near_tie`.
7. Recorded only: for every opened residual leaf, the L2 share against the
   same forward.

Lab dependencies: mlx, mlx-lm, numpy. None of them are provider dependencies.

## Hook mechanism and the mlx-swift-lm fork

No fork change and no new tag. `Module.update(modules:)` replaces, on a loaded
`Qwen2Model` or `LlamaModel`:

- every block's `input_layernorm` (`@ModuleInfo`, its input is the block's
  input residual) with `TraceAuditCaptureNorm: RMSNorm`, sharing the loaded
  weight array and calling the stock `MLXFast.rmsNorm`;
- the last block's `post_attention_layernorm` and `mlp.down_proj` with
  capturing subclasses (`QuantizedLinear` or `Linear`, same arrays, stock
  kernel). The final residual is `h + mlp(...)`, rebuilt from their input and
  output with the same float16 addition the block performs. The fork's
  `Qwen2ModelInner.norm` and `layers` are plain `let`s, so the final norm
  cannot be swapped without a fork change; this route avoids one.

The hooks keep references only; kernels, shapes and evaluation order of the
forward are the stock ones. With capture off (measurement "off" mode) the
original modules are restored. Models other than Qwen2/Llama, and activations
other than float16, get `uncalibrated`.

What would have to land in the fork for production: nothing for Qwen2/Llama.
A fork-native hook (an optional per-layer residual sink in
`Qwen2ModelInner`/`LlamaModelInner`) would avoid the class swap and the
final-residual rebuild, and would be needed for model families whose blocks
are not `@ModuleInfo`-swappable.

## Request rules

| Case | Rule as built | Marker |
|---|---|---|
| Relay-blind / privacy class (`ingestProvenance == .privacy`) | never captured or stored | `privacy_class` |
| Prompt-cache reuse (`cachedPromptTokens > 0`, a retained paged-KV sequence, or a prompt snapshot installed), or a first captured position above 0 | cached positions were not computed in this request and no residuals are kept next to cache entries | `prefix_cache` |
| Native MTP: a row that prefills for a drafter, rides decode for drafter columns, or enters propose/verify, or whose final decode path is native | excluded | `native_mtp` |
| Architecture not qwen2/llama, activation not float16 | excluded | `uncalibrated` |
| Byte cap, failed write, missed position | files deleted | `storage` |
| Failed or cancelled request with no response | nothing committed | none (`discarded`) |

Native MTP, from the code: verification runs the target model over the
current column plus the proposals in one forward (`verifyNativeMTPPackedGroup`),
so block inputs of accepted positions are produced by the target model, and
the rejected columns are staged and trimmed at `finalizeNativeMTPPackedRound`.
Capture of the accepted prefix is well-defined (capture the staged columns,
commit only `committedInputTokenCount` of them at finalize), but it is not
built: the spec pins `native_mtp`, and the verify forward goes through a
different call site. Qwen2.5 has no MTP head; exercising this needs a native
MTP model served with its drafter (the GLM-5.3-Flash nextn head or a Qwen
3.5/3.6 MTP checkpoint), and those are not qwen2/llama, so they would be
`uncalibrated` in the pilot anyway.

Quantized KV: the CB paged-KV path stores only 16-bit KV (`PagedKVDType` has
`fp16` and `bf16`), so `quantized_kv` cannot occur on the captured path.
`kv_bits` exists only on the serial route; a serial request whose iterator
runs with `kvBits` or whose conversation cache the path quantizes is
`quantized_kv`.

## Serial route

Serial requests commit like CB requests, through the same module swap.
`ModelRuntime` creates a `TraceAuditLabSerialRequest` in each serial entry:
`completeWithServedSnapshotMarked`, `streamPrepared`, and the draft-model
speculative path `collectSpeculativeText`, which finds it through the
request's `RequestTimeline`. The entry's `close()` finalizes it.

The serial forwards run inside `TokenIterator` / `SpeculativeTokenIterator`
(mlx-swift-lm), so the path cannot open and close each forward the way the
CB backend does. Instead the request binds the threads that build its
forwards:

- the prefill thread, from before the local chunked prefill until the
  iterator is built (its init runs the prefill and the first step);
- the decode executor thread, for the whole decode loop.

On a bound thread, the block-0 hook opens a one-row forward at the KV
cache's `offset`, which is the committed length before the forward. A
speculative trim rewinds that offset, so a rejected draft position is
overwritten by the accepted one, and anything past the response is cut at
finalize. The last block's down projection closes the forward.

| Case | Result |
|---|---|
| A request the serial entry hands to the CB scheduler | Registered by the scheduler only. The serial request registers on its first `attach`. |
| A reused conversation cache, or a recurrent/prompt-snapshot resume (prefill starts above 0) | `prefix_cache` |
| `kvBits` on the iterator, or a quantized conversation cache | `quantized_kv` |
| Vision (VLM model), DeepSeek V4 or another architecture | `uncalibrated` (the hook installs only on `Qwen2Model` / `LlamaModel`) |
| Privacy class | `privacy_class` |
| A speculative attempt that fails before output and falls back | The same request continues, and the fallback's forwards overwrite positions from 0. |
| No response (error, cancel) | `close()` finalizes it as not completed (`discarded`) |

The serial generate loop drops the stop token: mlx-swift-lm
`runSynchronousGenerationLoop` breaks before appending it, and the
speculative loop calls `discardGeneratedToken`. So on the serial route `n`
counts the returned tokens, and the position whose logits chose the stop
token is not committed. The CB route commits it.

Lab-only change to the speculative path: when capture is on and the caller
passed no main cache, the path creates one with
`model.newCache(parameters:)` so the hook can read its offset.

The measurement command drives the CB scheduler only. The serial route is
covered by its code path but is not part of the measurement run.

## Measurement command

Run in a booked exclusive M5 slot, provider paused:

```bash
phase3-binary/scripts/trace-audit-lab-measure.sh /path/to/trace-audit-m5.json \
  --model /path/to/mlx-community/Qwen2.5-7B-Instruct-4bit --build
```

It builds the lab-harness CLI, runs `trace-audit-lab measure` (4 rounds per
concurrency level, modes alternating off/on then on/off, 1024 prompt + 128
generated tokens per request), then the verifier, and writes one JSON with
the host facts. Residuals and openings are deleted at exit.

The script prints the load average at start and refuses the timed part
(exit 3) when the 1-minute value is above 4. The measure command checks
the same bound again and records the load average before every cell
(`load_average_by_mode`).

## Measurements

Source for everything below: `trace-audit-prototype.m5.json` (written by
`trace-audit-lab-measure.sh`, schema `macprovider.trace-audit-lab.measure.v1`
inside `macprovider.trace-audit-lab.result.v1`). One run, no repeat. The
numbers are medians or ranges over the rounds the JSON holds; where a value is
a derived figure, the text says how.

**Host and run.** `host.chip` Apple M5, `host.memory_bytes` 34,359,738,368
(32 GB), `host.macos` 27.0.1, `host.source_commit`
`fe18f3d629f1bb48b78781bbe6c76ce07521f481`. Model: Qwen2.5-7B-Instruct-4bit
(mlx-community), `measure.blocks` 28, `measure.prompt_tokens` 1024,
`measure.decode_tokens` 128, `measure.rounds` 4. Every request ended with
terminal `length` (`measure.cells[*].terminals`, all 24 cells).
`verify_exit_code` 0.

### Capture overhead (CB backend, capture off versus on)

Per concurrency level and mode there are 4 cells (one per round). Each value
is the median of those 4 cell values (the median of an even count is the mean
of the middle two). Overhead = `on / off - 1`; a negative number for tok/s is
a slowdown, a positive number for TTFT is a slowdown. TTFT per cell is the
median of that cell's per-request `ttft_s` values (1, 4 or 8 requests); the
table then takes the median over the 4 rounds.

| Concurrency | Metric | Off | On | Overhead |
|---|---|---|---|---|
| 1 | Decode tok/s | 24.79 | 24.15 | -2.6% |
| 1 | Prefill tok/s | 737.1 | 597.7 | -18.9% |
| 1 | TTFT s | 1.39 | 1.85 | +33.0% |
| 4 | Decode tok/s | 16.52 | 16.13 | -2.4% |
| 4 | Prefill tok/s | 187.8 | 161.0 | -14.3% |
| 4 | TTFT s | 21.88 | 25.44 | +16.3% |
| 8 | Decode tok/s | 14.49 | 13.51 | -6.7% |
| 8 | Prefill tok/s | 192.2 | 161.7 | -15.9% |
| 8 | TTFT s | 31.03 | 37.41 | +20.5% |

Source: `measure.cells[*]` keys `capture`, `concurrency`, `round`,
`decode_tok_s`, `prefill_tok_s`, `ttft_s`. The terminals data
(`terminals`) holds only the finish reason, so there is no per-request tok/s;
the only per-request value is `ttft_s`. Computed from it, the TTFT median over
all per-request values pooled across the 4 rounds is 1.39 / 1.85 s (c=1),
21.88 / 25.44 s (c=4) and 31.51 / 40.39 s (c=8), off / on, which is +33.0%,
+16.3% and +28.2%. The c=8 pooled figure differs from the cell-median figure
(+20.5%) because round 0 on had one 49.5 s cell median.

**How firm these are.** The round-to-round spread is as large as the effect in
several rows. Per-round values (off then on, round 0 to 3):

| Concurrency | Decode tok/s off | Decode tok/s on | Prefill tok/s off | Prefill tok/s on |
|---|---|---|---|---|
| 1 | 27.45, 25.61, 23.96, 17.43 | 27.32, 25.16, 23.14, 19.04 | 801, 750, 724, 390 | 765, 760, 416, 436 |
| 4 | 16.70, 16.13, 16.33, 17.52 | 14.67, 15.93, 16.33, 17.20 | 256, 177, 168, 198 | 132, 158, 164, 179 |
| 8 | 12.85, 14.31, 14.66, 14.95 | 12.48, 13.47, 13.55, 13.95 | 170, 193, 193, 191 | 128, 153, 170, 180 |

Paired by round (on versus off in the same round), the per-round overhead is:

| Concurrency | Decode, rounds 0 to 3 | Prefill, rounds 0 to 3 |
|---|---|---|
| 1 | -0.5, -1.8, -3.4, +9.3 % | -4.5, +1.2, -42.5, +11.8 % |
| 4 | -12.2, -1.2, 0.0, -1.8 % | -48.3, -10.8, -2.2, -9.8 % |
| 8 | -2.9, -5.9, -7.6, -6.7 % | -24.6, -20.7, -12.0, -6.1 % |

Reading: at c=8 both metrics are slower with capture on in all 4 rounds
(decode -2.9 to -7.6%, prefill -6.1 to -24.6%), so the c=8 overhead is a
consistent sign with a wide range. At c=4, prefill is slower in all 4 rounds
and decode is slower or equal. At c=1 the sign changes between rounds
(decode -3.4 to +9.3%, prefill -42.5 to +11.8%, with one off cell at 17.4
tok/s decode and 390 tok/s prefill, load 3.65), so the c=1 numbers do not
separate the capture cost from run-to-run noise; the pooled median says about
-3% decode and -19% prefill, but two of four rounds for prefill are
within 5% of zero. The 4-round design cannot give a confidence interval; none
is claimed.

### Load average

| Item | Value |
|---|---|
| `host.load_average_at_start` (script, before the build) | 1/5/15 min = 2.97 / 5.70 / 5.45 |
| `measure.load_average_at_start` (measure command, before the first cell) | 3.22 / 5.71 / 5.45 |
| 1-min load at cell start, capture off (12 cells) | 3.16 to 6.86, median 4.06 |
| 1-min load at cell start, capture on (12 cells) | 3.09 to 9.05, median 4.21 |
| 5-min load at cell start, off / on | 4.64 to 6.21 / 4.95 to 6.64 |

Source: `host.load_average_at_start`, `measure.load_average_at_start`,
`measure.load_average_by_mode.{off,on}` (each cell: 1, 5, 15-min values).

The run passed the script's gate (1-min load 2.97, under 4) but was not on an
idle Mac: the 5- and 15-min averages were 5.7 and 5.45 from earlier jobs, and
the 1-min load at the start of 6 of 12 off cells and 8 of 12 on cells is above
4. Off and on alternate within each round (off/on in rounds 0 and 2, on/off in
rounds 1 and 3), so the medians of the two modes sit close together (4.06
versus 4.21). They are comparable in aggregate, not cell by cell: at c=1 the
pairs are within 0.5 of each other (3.09 to 3.65 in both modes), but at c=4
round 2 was 6.86 off against 5.25 on and round 3 was 6.00 off against 9.05
on, and the highest-load cell (9.05) is a capture-on cell. The JSON cannot
tell how much of the c=4 and c=8 load is the benchmark's own earlier cells and
how much another process, so the c=4 and c=8 overhead figures are rough, and
the c=1 figures are the best-controlled but least conclusive. The overhead is
not yet a clean measurement; a rerun on an idle Mac would replace it.

### Bytes stored per position and root

| Item | Value |
|---|---|
| Bytes stored per position, measured | 207,872 in all 52 capture-on requests |
| Expected, (blocks + 1) x hidden_size x 2 | 29 x 3,584 x 2 = 207,872 |
| Difference | 0 |
| Verification set | 5 requests: 4 x 575 positions + 1 x 4,095 positions = 6,395 positions |
| Total bytes of the verification set (derived) | 6,395 x 207,872 = 1,329,341,440 B (1.33 GB); 575 positions = 119,526,400 B, 4,095 positions = 851,235,840 B |
| Leaves per position | 30 (`leaf_count` 17,250 / 575 = 30; 122,850 / 4,095 = 30), i.e. L + 2 with the token pair |
| Root ready after response, c=1 / 4 / 8 | median 0.14 / 0.91 / 2.12 s; range 0.12 to 0.21 / 0.25 to 1.72 / 0.38 to 4.22 s |

Source: `measure.bytes_per_position_measured` (52 values, one per capture-on
request: 4 rounds x (1 + 4 + 8)), `measure.blocks` (28),
`measure.verification_set_commitments[*].{positions,leaf_count}`,
`measure.cells[*].root_ready_after_response_s` (capture-on cells, one value per
request). The JSON has no hidden_size field; 3,584 is the value that makes the
measured number equal (28 + 1) x H x 2 (207,872 / 58), and it matches
Qwen2.5-7B's published hidden size. The token pair leaf is the 30th leaf of a
position, but `bytes_per_position_measured` counts only the residual store
(it equals the residual stride with no extra bytes), so the token pair's
bytes are not in that number. The layout above keeps tokens in a separate
`.tokens` file (two u32 per position); the JSON holds no measured size for it,
so it is not measured. The derived total is positions x bytes per position,
not a stored measurement. The longest root delay seen, 4.22 s (c=8), is under
the 10 s FR-28 allows.

### Openings at fixed positions

| p | Bytes | Leaves opened | Proof nodes | Tree s | Recompute s | Total s | `over_cap` |
|---|---|---|---|---|---|---|---|
| 100 | 32,657,422 (32.7 MB) | 8,288 | 23,817 | 0.085 | 0.333 | 3.71 | false |
| 1,000 | 39,303,030 (39.3 MB) | 9,188 | 26,291 | 0.093 | 0.244 | 2.65 | false |
| 4,000 | 61,462,702 (61.5 MB) | 12,188 | 34,541 | 0.107 | 0.420 | 3.19 | false |

Source: `measure.fixed_openings[*]` (`bytes`, `leaves_opened`, `proof_nodes`,
`tree_seconds`, `recompute_seconds`, `total_seconds`, `over_cap`; each opens
one block point and one block-0 point at position p). Size grows with p, as
expected: 61.5 MB at p = 4,000 against the FR-31 estimate of about 86 MB. Time
does not: p = 100 took the longest (3.71 s) and p = 1,000 the shortest
(2.65 s). The JSON does not say why (order of the runs, cache state); tree
build is 0.09 to 0.11 s and recompute 0.24 to 0.42 s, so most of the total is
neither. What the total includes beyond those two is not broken down in the
JSON. The JSON does not name the request these three openings came from; the
leaf counts (8,288 to 12,188, above 8,185 = 4,090 + 4,095) fit the 4,090-token
prompt request. All three are far under the 160 MiB cap (167,772,160 B).

### FR-29 challenges and verifier

10 challenges (2 per request on the 5 verification requests: 8 on the
575-position requests, 2 on the 4,095-position request), each with 5 drawn
points (2 block, 1 block-0 "prompt", 2 output) = 50 drawn points.

| | 8 openings on 575 positions | 2 openings on 4,095 positions | All 10 |
|---|---|---|---|
| Size, MB | 6.3 to 13.2 (median 9.4) | 62.1 and 64.9 | 6.3 to 64.9 (median 10.6) |
| Leaves opened | 1,270 to 2,207 | 12,250 and 12,632 | 1,270 to 12,632 (median 1,861) |
| Proof nodes | 3,735 to 5,901 | 32,637 and 32,975 | 3,735 to 32,975 (median 4,567) |
| Tree s | 0.015 to 0.025 | 0.150 and 0.204 | 0.015 to 0.204 (median 0.020) |
| Recompute s | 0.078 to 0.214 | 0.296 and 0.480 | 0.078 to 0.480 (median 0.135) |
| Provider total s | 1.59 to 2.90 (median 2.74) | 5.33 and 5.73 | 1.59 to 5.73 (median 2.84) |
| Verifier s | 2.47 to 3.11 (median 2.95) | 20.07 and 21.43 | 2.47 to 21.43 (median 2.99) |
| `over_cap` | false | false | false for all 10 |

Source: `measure.challenges[*]` (`bytes`, `leaves_opened`, `proof_nodes`,
`tree_seconds`, `recompute_seconds`, `total_seconds`, `over_cap`) and
`verify.results[*].seconds` (the verifier's float16 forward is 2.25 to 2.83 s
on 575 positions and 19.0 to 19.6 s on 4,095, `forward_seconds`). Grouping by
575 versus 4,095 positions is by `verify.results[*].positions`; the medians per
group are mine. The cost scales with the request, not with the draw: the two
long-request openings are about 7 times larger in bytes and verifier time than
the median short one.

**Pass rate.** `verify.summary`: 10 of 10 openings verdict `pass`
(`verdicts` = `{pass: 10}`, none `fail` or `inconclusive`) and `points_block_pass`
30 of 30. The 30 are the 20 block points and 10 block-0 points of the draws;
the other 20 drawn points are output points, checked by `output_binding`
below.

**Block recompute ratio** (`‖rec - next‖ / (‖rec - input‖ + 2^-14)`, tolerance
`calibration.tol_block` 2e-2): over the 30 block and block-0 points, worst
1.22e-3 (`verify.summary.block_ratio_worst`) and median 4.49e-4
(`block_ratio_median`). That is 16.4 times and 44.6 times below the
tolerance. Over only the 20 block points the worst is the same 1.22e-3 and the
median 4.85e-4. Per opening, `checks.block.worst` is 4.0e-4 to 1.22e-3.

**Check by check** (`verify.results[*].checks`, 10 openings):

| Check | Result | Note |
|---|---|---|
| `merkle` (root from multiproof, draws match `nonce_1`) | 10 / 10 pass | `missing` 0, `draws_match_nonce_1` true in all |
| `block` | 10 / 10 pass | worst 4.0e-4 to 1.22e-3 against 2e-2 |
| `prompt_binding` (block-0 leaf against embedding row) | 10 / 10 pass | `worst` 0.0 in all 10 (tolerance `tol_embedding` 1e-3) |
| `tokens` (token chain, `against_request`) | 10 / 10 pass | |
| `output_binding` (argmax equals served token) | 10 / 10 pass | all 20 output points: argmax equals served, `gap` 0.0, `near_tie` false |
| `internal` (recorded only) | 10 / 10 `pass` true | worst element error per opening 5.4e-4 to 4.2e-3, always the attention kind (`att`); `tol_attention` is 5e-2 |
| `forward_consistency` (recorded only) | no pass flag | per-opening worst 2.5e-3 to 6.5e-2 (median over openings 1.7e-2), median of medians 9.2e-4; the 6.5e-2 is opening 9, on the 4,095-position request |

`internal` and `forward_consistency` do not decide the verdict (`recorded_only` is
true in the JSON); they are listed as recorded. `forward_consistency` has
no tolerance in `calibration`, so no pass or fail is claimed for it, and its
worst value on the long request (6.5e-2) is the largest recorded number in
the run.

### Cases not measured

| Item | Result | Why (from the JSON) |
|---|---|---|
| Prompt-cache-hit case: marker | not measured | `measure.prompt_cache_case.exercised` is false. The harness scheduler retained no cache for turn 1, so there was no cached prefix for a later turn to hit and nothing to mark `prefix_cache`. The marker path exists in code and is unit-tested, but this run did not reach it. |
| Native MTP case | not measured | `measure.native_mtp_case.exercised` is false. The measure command builds the plain CB backend with no drafter, and Qwen2.5 has no MTP head, so no row could enter prefill, propose or verify for a drafter. A `native_mtp` marking is unit-tested only, not run here. |

Both stay gaps. Closing them needs a build that retains a conversation cache
for turn 2 (prompt-cache) and a native-MTP model with its drafter (native
MTP); the latter would be `uncalibrated` in this pilot anyway (see "Request
rules").

### Summary of the measured outcome

On Qwen2.5-7B-Instruct-4bit (mlx-community), M5, CB backend: capture costs
about 2 to 7% decode tok/s and 14 to 19% prefill tok/s at 1, 4 and 8
concurrent requests, with the sign only consistent from c=4 up (the c=1 rows
sit inside run-to-run noise) and under a Mac that was not idle. Residual
storage is exactly 207,872 B per position. Openings are 6 to 13 MB at 575
positions and 61 to 65 MB at 4,095 positions, all under the 160 MiB cap, and
take 1.6 to 5.7 s on the provider side. All 10 openings verify, 30 of 30
block points with a worst ratio 16 times under tolerance, and all 20 output
points match the served tokens. The prompt-cache marker and native MTP are
not measured.

## Known limits

- An opening on a 4,090-token prompt carries up to about 29 MB of block
  inputs per block or block-0 point plus about 29 MB of prompt block-0 leaves
  (the block-0 point shares those). FR-31 estimates about 86 MB at p = 4,000.
  The measurement records the real size and `over_cap` (160 MiB) per opening.
- The capture stacks every block input of a forward (`[rows, T, L+1, H]`);
  a 4-row, 512-token prefill chunk at 7B holds about 425 MB more until it
  is copied out.
- The commitment frame (`trace_commitment_v1`: `attempt_n`,
  `receipt_tuple_sha256`, signature, WebSocket delivery) and the coordinator
  side are not built; the prototype stops at the root, the meta file and the
  opening.
- The FR-31 `too_long` release (more than 4,096 positions, or a worst-case
  opening `(block_points + 1) * N * hidden_size * 2` above 150 MiB) is a
  coordinator decision and is not built; at 7B and N = 4,096 the bound is
  about 88 MB, so every measured response qualifies.
- The CB backend and the serial route are instrumented. DeepSeek V4 and shard
  groups are not; they are not qwen2/llama, so they would be `uncalibrated`.
