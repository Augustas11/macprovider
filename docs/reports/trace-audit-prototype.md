# Trace audit prototype (lab pilot, campaign #2419)

Status: prototype on `campaign/trace-audit-pilot`, built and unit-tested on the
M5 without a model. Nothing here has run against a real model yet; every
number under "Measurements" is still to be taken in a booked exclusive slot.
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
`..._MAX_TOTAL_BYTES` (default 16 GiB; FR-30 says 8 GiB, to align),
`..._RETENTION_SECONDS` (default 3600; FR-30 says 10 minutes, to align).

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
`kv_bits` exists only on the serial route, which is not captured at all.
**Open point for the spec:** serial-route requests of a pilot provider get
neither a root nor a marker in this prototype, and no closed marker fits a
serial-route request without quantized KV.

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

## Measurements

| Item | Value |
|---|---|
| Decode tok/s, batch 1, capture off / on | not measured yet |
| Prefill tok/s, batch 1, capture off / on | not measured yet |
| Decode tok/s, 4 concurrent, off / on | not measured yet |
| Prefill tok/s, 4 concurrent, off / on | not measured yet |
| Decode tok/s, 8 concurrent, off / on | not measured yet |
| Prefill tok/s, 8 concurrent, off / on | not measured yet |
| Bytes stored per position | not measured yet |
| Root ready after response | not measured yet |
| Opening latency and size, p = 100 | not measured yet |
| Opening latency and size, p = 1000 | not measured yet |
| Opening latency and size, p = 4000 | not measured yet |
| Verifier pass rate, 50 drawn points (10 challenges) | not measured yet |
| Block recompute worst / median ratio | not measured yet |
| Prompt-cache-hit case: marker | not measured yet |
| Native MTP case | not measured yet (not exercisable with Qwen2.5) |

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
- Only the CB backend (`PagedKVSharedForwardBackend`) is instrumented; the
  serial route, the DeepSeek V4 backend and shard groups are not.
