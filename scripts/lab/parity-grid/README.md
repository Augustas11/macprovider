# Parity grid: our runtime vs stock mlx-lm

Campaign goal: no grid cell where our provider decodes slower than stock Python
mlx-lm by more than measured noise, with identical greedy output.

Grid (`grid.json`): model x output length (128, 512, 2048, 4096) x context
(short ~200, ~4k, ~16k tokens) x rows (1 and N concurrent; default N = 4).
A context is skipped when `ctx + output` exceeds the model's
`max_position_embeddings` (or `--max-context`). Model name and path are
always given on the command line; `grid.json` holds placeholders only.

## Files

| file | runs under | what it does |
|---|---|---|
| `prompts.py` | both sides | deterministic chat messages per (context, prompt row); cell keys; grid expansion |
| `reference_mlxlm.py` | python with `mlx_lm` | `mlx_lm.load` + `stream_generate`, greedy (`temp=0`), chat template from the tokenizer |
| `reference_mlxvlm.py` | python with `mlx_vlm` | the same with mlx-vlm's `stream_generate` (GLM-5.3-Flash, MiniMax M3.1-Flash); `--refusal-ablation SNAPSHOT_DIR` applies the runtime refusal-direction projection that snapshot's config names (`--model-path` = the unmodified base) |
| `reference_omlx.py` | stdlib python + an oMLX install | starts an oMLX server (loopback port, MTP/DFlash off), drives the reference jobs through `provider_client.run_request`, stops it; for builds no stock Python runtime decodes (GLM-5.3-Flash oQ) |
| `sanity.py` | stdlib python | sanity gate: flags a reference whose output is degenerate (`REFERENCE_SUSPECT`) |
| `provider_client.py` | stdlib python | streaming `/v1/chat/completions` client, N concurrent rows by threads |
| `route_status.py` | stdlib python | batching warm-up gate before the first cell; `ROUTE` line and `grid.json` route record per status snapshot |
| `compare.py` | stdlib python | grid table, JSON summary, ratio / gates / slope checks, exit code |
| `margin.py` | python with `mlx_lm` | explains text mismatches: reference top-5 logits at the first differing token; `--json` writes records for `compare.py --margins` |
| `run-grid.sh` | bash | one lab window for one model: provider (serve + client), then reference, then compare |

## Running a window

Nothing may listen on 8080: the wrapper refuses to start otherwise, and it
refuses a busy `--port`. It starts `macprovider-cli serve --no-join
--autotune-candidate` on a loopback port, waits for `/v1/status`
`model_loaded: true`, waits for the batching warm-up (below), runs the client,
then stops only the serve PID it started.

```bash
scripts/lab/parity-grid/run-grid.sh \
  --model-path "$MODEL_DIR" --model-name llama31-8b-4bit \
  --bin-dir "$BUILD_DIR" --out-dir "$OUT" \
  --python "$MLX_VENV/bin/python" \
  --cb off                      # off | on | canary | auto (auto = flag omitted)
  # --rows 1,4 --trials 3 --port 18340 --floor 0.03
  # --serve-env "MACPROVIDER_X=1 OTHER=2"
  # --skip-reference           (reuse $OUT/reference.jsonl)
  # --expect-route batched     (production batches this model: a serial route fails, exit 10)
  # --warmup-stall-s 1200 --warmup-poll-s 10
  # --seed-self-check FILE     (a stored cb-self-check.json from an earlier serve of the same build)
  # --text-fallback-reason "..."
  # --margins margins.json --tie-steps 2   (tie-aware text gate, see below)
```

Outputs in `$OUT`: `grid.json` (the grid run, with `route.start` and
`route.end`), `reference.jsonl`, `provider.jsonl`, `summary.md`,
`summary.json`, and `serve/` (config, serve logs, binary sha256 and three
`/v1/status` snapshots: `status-ready.json` at load, `status.json` after the
warm-up, `status-end.json` after the last cell).
Exit code is compare's: 0 all cells pass, 1 a cell fails, 2 unusable input;
7 when the client failed, after the compare table is printed; 10 when compare
passed or only failed cells but `--expect-route batched` saw a serial route;
5 when the serve exited during the warm-up.

### Batching warm-up and route

A `serve --no-join` lab serve has no catalog trust, so it never loads the
signed continuous-batching policy (`continuous_batching_policy
action=resolved status=absent_empty_off_fallback`). A
`continuous_batching_accepted_tuples` entry in `--config-extra` only adds
coverage (the cached-turns grant), never authorization. Batching turns on in
the lab only when the on-device self-check (SPEC-038 FR-CB10) grants it; a live
provider reaches the same state through its signed provisional grant and then
the same self-check. The check runs once the serve has been idle for 10 s.
Under traffic it waits for an admission hold and yields to any request that
waits 20 s behind it (`deferred reason=cancelled`), so a grid that starts right
after load keeps it from deciding and every multi-row cell is served one row
at a time.

So run-grid.sh sends no inference request after load until `route_status.py
gate` sees a verdict (`granted`, `no_net_gain`, a row divergence, ...) and the
served slots equal the verdict's, or sees that no check can run for this serve
(the tuple cannot batch, the serial-only route, a draft model, an autotune
child). It prints `CB_WARMUP` at every change and `CB_WARMUP_DONE` at the end.
The only bound is `--warmup-stall-s` without any change in the self-check
report or log lines (`CB_WARMUP_STALL`; the grid then runs and the route line
shows what served). The verdict is stored in `serve/cb-self-check.json` and
reused by a later serve of the same binary, model, Metal library, OS build and
hardware; `--seed-self-check` copies one in before start.

After the warm-up and after the last cell, `route_status.py record` prints

```
ROUTE batching=<active|serial> slots=<n> reason=<...> phase=<start|end> mode=... self_check=... verified_k=... small_m_route=... max_observed_batch_depth=...
```

and stores the fields in `grid.json` under `route.<phase>`. With
`--expect-route batched`, a serial route prints `ROUTE_FAIL ...`; the grid
still runs and the window exits 10 at the end.

`--autotune-candidate` makes the serve an autotune child, which always takes
the row-invariant small-row route; a production serve does not run that way.
`--no-autotune-candidate` drops the flag. `window.sh` runs several models and
routes in one window: `default` (autotune flag, batching auto: row-invariant),
`stock` (no autotune flag, batching auto: the production route, stock order
unless native MTP may activate), `serial` (batching and native MTP off, no
autotune flag: serial-only) and `cb` (batching on). Each route prints the
`small_m_route` the serve reported in `serve/status.json`.
JSONL files are appended to, so use a fresh `--out-dir` per window.

The pieces also run alone:

```bash
python reference_mlxlm.py --model-path DIR --model-name NAME --out ref.jsonl
python3 provider_client.py --port 18340 --model DIR --model-name NAME --out ours.jsonl
python3 compare.py --ref ref.jsonl --ours ours.jsonl --json summary.json
```

## Prompts

`prompts.build_messages(ctx_tokens, row)` returns one user message of
`ctx_tokens * 4` characters (`CHARS_PER_TOKEN = 4.0`, a rough English-prose
estimate; no tokenizer on the client side). The message starts with a row tag,
so concurrent rows differ right after the chat-template preamble and do not
share a prefix-cache entry. Filler text is derived from SHA-256, so it is the
same on every machine and Python version. The message asks for a 6000-word
story without stopping, so 4096 tokens are normally reached before EOS.
Every result line records the real `prompt_tokens`.

## Measurements

Both sides write one JSON line per row per trial with `cell`, `prompt_tokens`,
`completion_tokens`, `decode_tps`, `ttft_s`, `text`, `sha256` and `finish`
(`length` = max tokens, `stop` = EOS).

- `decode_tps = (completion_tokens - 1) / (t_last - t_first)`, where t_first
  and t_last are the times of the first and last token (reference) or the
  first and last generated delta (provider). A delta is `content` or
  `reasoning_content`, so a model that streams everything as reasoning still
  gets a first-token time and a tok/s. `text` is content only;
  `reasoning_text` holds the reasoning deltas.
- Provider `completion_tokens` is the usage frame's
  `macprovider_generated_completion_tokens` when present, else
  `usage.completion_tokens`; `generated_completion_tokens`, `cached_prompt_tokens` and
  `macprovider_generation_ms` are recorded alongside. The client sends
  `stream_options: {"include_usage": true}` (`--no-stream-options` drops it);
  a stream without a usage frame is recorded as an error.
- Reference `completion_tokens` excludes the EOS token (mlx-lm counts it in
  `generation_tokens`, recorded as `mlxlm_generation_tokens`).
- Provider rows also record `start_offset_s` and `t_last_offset_s` (request
  start and last delta, seconds from the trial's first request start) and
  `queue_ms` (`usage.macprovider_queue_ms`: time the request waited for a
  serving slot).
- The provider writes one `aggregate` line per trial:
  `aggregate_tps = sum(completion_tokens) / (max t_last - min start)` over the
  concurrent rows, the tok/s a buyer sending them all at once gets. Also:
  `wall_s`, `decode_overlap_rows` (most rows decoding at the same instant; 1
  means the rows were served one after another), `serial_service`,
  `queue_s_max`, `queue_s_median`, `per_row_queue_ms` and `decode_span_tps`
  (the earlier first-token-to-last-token figure, kept for comparison only).
- Warm-up: both sides decode a short request on prompt row 9999 first.

The reference runs prompt row 0 for every cell (`--trials` times) and, for a
cell with N rows, prompt rows 1..N-1 single-row (`--extra-row-trials`, default
1) so every concurrent row has its own single-row reference text.

- `request_tps = completion_tokens / (t_last - t0)`, t0 the request start:
  request-level output tok/s, whose two parts are TTFT and decode tok/s. Its
  sum over concurrent rows is no throughput: rows served one after another
  each count their own queue-shortened window, so four serial rows summed to
  about 2x one row while the real aggregate was 0.90-1.02x. compare.py uses
  `aggregate_tps` for rows > 1 and shows the median per-request tok/s as a
  separate column, never gated.
- Each reference run starts with a `kind: meta` line: package versions (and
  for mlx-vlm the wired limit and ablation parameters).

`run-grid.sh --reference mlx-vlm` runs `reference_mlxvlm.py`; `--ref-arg ARG`
passes arguments to the reference, `--ref-model-path` points it at another
snapshot, `--outputs` / `--contexts` cut the grid, `--model-id` with
`--model-sha256` serves the snapshot under its catalog id, `--config-extra`
appends serve-config lines (e.g. a CB accepted tuple), `--skip-compare` stops
after the client, and `--trials-by-rows 4=1` sets the provider's trial count
for one row count (a serially served model's 4-row cells only queue).

### oMLX reference (`--reference omlx`)

Stock mlx-vlm 0.7.11 loads the GLM-5.3-Flash oQ4e DFlash2 build but decodes
garbage, so it is no reference for it. `--reference omlx` runs
`reference_omlx.py` under `/usr/bin/python3` (default `--python`) against an
existing oMLX install: `--ref-arg --omlx-dir --ref-arg DIR`, where DIR holds
`omlx-venv/bin/{python,omlx}` and `omlx-src/` (`OMLX_COMMIT` or a git checkout).
It refuses when 8080 or its `--port` (default 18350) listens or another
`omlx serve` runs, checks `omlx serve --help` for every flag it uses, writes a
fresh state dir (HOME, caches and the oMLX base path, so nothing lands in the
real home), pins the one model with MTP, VLM MTP, DFlash, SpecPrefill,
TurboQuant KV and expert offload off, starts `omlx serve --headless --no-cache
--no-hf-cache --memory-guard off --max-concurrent-requests 1
--sse-keepalive-mode off` in its own process group, waits for `/health`
`healthy` with 1 model loaded (bounded; failures print the server log tail),
checks `/v1/models` and the saved model settings, runs the same jobs as the
other references one request at a time, then stops its process group and
checks the port closed. Requests are the provider client's (same messages,
`temperature 0`, `stream_options.include_usage`) plus explicit neutral
`top_p`/`top_k`/`min_p`/penalties. `--chat-template-kwargs JSON` adds
template kwargs (none by default; for a template with an `enable_thinking`
switch pass `{"enable_thinking":false}`, which is how our provider renders
it). Every failure ends with one `OmlxReferenceError: ...` line, which
run-grid.sh reports as `REFERENCE_FAIL`.

Formulas: token counts come from the usage frame, never from chunk counts.
`ttft_s` = first content/reasoning chunk - request start, as for our provider.
oMLX streams bursts of several tokens per chunk, so `decode_tps =
(completion_tokens - F) / (last chunk - first chunk)` with F =
`--first-chunk-tokens`, default 1: at the pinned oMLX commit the decode burst
ends at a request's first output, so the first chunk carries one token and
the formula equals our provider's `(completion_tokens - 1) / (last token -
first token)`. Each row also records oMLX's own `time_to_first_token`,
`time_to_first_visible_token` and `generation_tokens_per_second`, `chunks`
and `tokens_per_chunk`; a visible TTFT above the model TTFT means a first
chunk of several tokens (decode_tps then reads slightly high). The meta line
states the formula, and baseline.md prints its note under the table.

### Sanity gate

After any reference that exits 0, `sanity.py` checks its text (reasoning +
content) row by row: whitespace fraction > 0.40, characters per token < 2.5,
share of non-space characters in letter runs of 2+ < 0.50. Two of the three
make a row degenerate; more than half degenerate rows in any context make the
reference suspect: `REFERENCE_SUSPECT <model> <reason>`, rows moved to
`reference.suspect.jsonl`, compare runs as for a failed reference, exit 9.
Calibrated on the 2026-11-17 runs (garbage mlx-vlm GLM reference: every row
fires two signals; our GLM provider and the mlx-lm Qwen3.8-27B reference: no
row fires any).

### Reference only

`--reference-only` (no `--bin-dir`) runs only the reference into an OUT that
already holds a provider run's `provider.jsonl` (and `grid.json`, reused when
neither `--outputs` nor `--contexts` is given), then compares. `job.sh`
wraps it as `REFERENCE_ONLY=<run id>`.

The provider side runs before the reference. A reference that fails prints
`REFERENCE_FAIL <model> <error line> (rc=N)`; compare still writes the table
and JSON for every provider cell (reference columns empty, `reference_failed`
set) and the window exits 8. For `glm5_next` checkpoints, `reference_mlxvlm.py`
installs a loader shim for per-tensor mixed-precision Hugging Face layouts that
stock mlx-vlm cannot load (see its docstring); the meta line records it.

## Provider vs provider (`compare.py --baseline`)

```bash
python3 compare.py --baseline main/provider.jsonl --ours candidate/provider.jsonl [--subset]
```

Gate for a candidate build: every (cell, trial, row) equals the baseline's
trial-0 row of that cell and prompt row in `text`, `reasoning_text` and
`completion_tokens`; any difference, error or missing cell exits 1
(`--subset`: baseline cells the candidate did not run are only listed). The
table gives per cell the request tok/s (rows > 1: `aggregate_tps`) delta against the baseline with both
runs' trial spread, plus decode tok/s and TTFT; speed is not gated.

## Checks (compare.py)

Noise rule, per cell, with 3 trials per side by default:

```
noise(xs) = (max(xs) - min(xs)) / median(xs)            # one side's trials
band      = max(floor, noise(ours), noise(ref))         # floor = --floor, default 0.03
FAIL ratio when median(ours) < median(ref) * (1 - band)
```

A band above 0.10 is reported as a "noisy cell" note: rerun that cell.

- **score**: `ratio = median(ours) / median(ref)` output tok/s. One-row cells
  score decode tok/s. Multi-row cells score `aggregate_tps` (recomputed from
  the row lines) against the reference's single-row request tok/s (stock
  mlx-lm serving requests one at a time). The table's `service` column labels
  multi-row cells `batched (N)` or `SERIAL (queued)` from the decode overlap,
  with a note for serial cells. Per-request tok/s, queue wait (max) and TTFT
  excluding queue wait are separate columns, for one-row cells too; they are
  not gated.
- **gate 1, bytes**: every row's text must equal the single-row reference text
  for the same prompt. A mismatch fails the cell and reports the first
  differing UTF-8 byte offset. When byte identity cannot hold for a known
  reason (e.g. batched kernels reorder float sums), the caller passes
  `--text-fallback-reason "..."`: the mismatch and reason are recorded as a
  note and gate 2 decides.
- **tie (optional, `--margins FILE --tie-steps N`, default 2)**: a differing
  row is text status `tie`, not a failure, when a margins record covers it and
  `margin_steps <= N`. Records come from `margin.py --json`, which examines the
  first differing token of each mismatching prompt-row-0 cell and records the
  reference top-5 logits, the top1-top2 margin, the logits dtype and
  `margin_steps = margin / spacing`, where spacing is the float spacing of that
  dtype at the top logit's magnitude (float16 at 16..32 is 0.0156, bfloat16 is
  0.125): a margin of 0 to 2 steps is rounding, not a decoding bug.
  **Mapping rule:** a row-0 mismatch of context `ctx` whose first differing
  UTF-8 byte offset `b` satisfies `common_prefix_bytes <= b <=
  common_prefix_bytes + diff_span_bytes` of a record with that `ctx_target` is
  covered by it (ties between overlapping windows: the larger
  `common_prefix_bytes`). `common_prefix_bytes` is the byte length of the
  agreed text before the differing token, so every output length of one context
  that branches at the same token shares one record. Rows other than 0, a
  different branch point, or no record stay `fail`; without `--margins`
  nothing changes. A covered tie also exempts that row from gate 2, because
  the texts branched and the counts can legitimately differ; prompt tokens are
  still checked. The table shows `tie (margin M steps)` and `summary.json`
  lists `ties` plus per-cell `ties` with `margin_steps`.
- **reasoning-only output**: when our row has `reasoning_text` and empty
  content, speed is compared as usual and text is `not_comparable` (reason in
  the cell's `text_reason`; it does not fail the cell). Reasoning text is not
  matched against the reference's raw text. Gate 2 still applies.
- **gate 2, tokens**: every row's `completion_tokens` must equal the
  reference's. Fewer tokens (and more) fail.
- **prompt**: `prompt_tokens` must equal the reference's; otherwise the two
  sides did not see the same prompt and the cell fails.
- **slope**: per (model, context, rows), for consecutive output lengths a < b:
  `FAIL when ours(b)/ours(a) < ref(b)/ref(a) * (1 - band)`, band taken over
  both cells and both sides. Ours may fall with length only as much as stock
  mlx-lm does. A past bug decoded 83 / 58 / 38 tok/s at 128 / 512 / 1024
  tokens against a flat reference; that shape fails here.
- Cells in the reference but absent from the provider run (e.g. reference run
  with outputs 128/512/2048/4096, provider with 128/512) are listed once as
  "Not run" (`not_run` in `summary.json`) and excluded from pass/fail. A cell
  in the provider run with no reference fails.

## margin.py

```bash
python margin.py --model-path DIR --ref reference.jsonl --ours provider.jsonl --json margins.json
scripts/lab/parity-grid/run-grid.sh ... --skip-reference --margins margins.json
```

Prints, per mismatching cell, the first differing token index and the
reference top-5 logits (existing output) and writes `{"records": [...]}` with
`ctx_target`, `max_tokens`, `token_index`, `ref_token`, `our_token` (null when
ours ended), `top_ids`, `top_logits`, `margin`, `dtype`, `margin_steps`,
`common_prefix_bytes`, `diff_span_bytes`. Cells are examined once per
(ctx, token index).

## Tests

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_parity_grid
```

The unit tests cover compare.py on synthetic JSONL, the prompt builder, the
client's SSE parsing against an in-process fake server, the sanity gate,
reference_omlx.py's record mapping and server lifecycle against a fake oMLX
install, and run-grid.sh's failed-reference and reference-only paths with
fake references, route_status.py's states, gate and record, run-grid.sh's
warm-up and `--expect-route` against a fake serve whose self-check decides
after a delay, and the aggregate metric on one real serially served 4-row
trial (timings only). Real model loads (`reference_mlxlm.py`, a real oMLX) run only
in a lab window.
