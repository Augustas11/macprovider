# CB streamed-window progress fix: release-build Studio e2e (2026-10-19)

Fix: `ContinuousBatchScheduler.applyStreamedDecodeStep` now bumps
`rowProgressEvents` per streamed token. Before it, a decode lockstep window
above 1 delivered every token through the streamed path, which never counted
as progress, so 64 healthy 16-step windows (~1024 tokens) tripped the
no-progress guard and every active row failed with
`continuous_batching_scheduler_no_progress` (CLI 1.8.253-1.8.256).

## Setup

- Host: Mac Studio M3 Ultra 256 GB, model `zai-org/glm-5.3-flash`
  (artifact sha256 `7299b6a7...48f9`), live provider paused for the window.
- Fixed binary: `swift build -c release` of source commit `5063fd895`
  (`macprovider-cli` sha256 `f4440f21...b30e`).
- Unfixed binary: the installed 1.8.256 `macprovider-cli`
  (sha256 `98578218...8ebd`).
- Both ran with the signed release `mlx.metallib` copied from the install
  (sha256 `3d9b4a74...261b`; `gather_mm_offsets` present).
- Lab serve: `serve --no-join --no-idle-prewarm` on loopback port 18097 with a
  copy of the live config (same model, artifact path, CB canary, paged KV,
  owner pin 4; coordinator, receipts and relay keys removed; native MTP off,
  as it is effectively off live: `tuple_not_admitted`). Both serves reached
  CB active, paged KV attached, self-check `granted`, served slots 4.
- Load: `cb_long_output_load.py` (deterministic filler prompt plus a
  counting task; temperature 0; serve has no `ignore_eos`).

## Results

| Case | Binary | Requests | Result |
|---|---|---|---|
| a: 4 concurrent, prompts 1118/2210/3302/3302 tok, max_tokens 4096 | fixed | 4 | all HTTP 200, 4096/4096/4096/4096 tokens, `length`, 288 s wall |
| b: 1 request, max_tokens 2048 | fixed | 1 | HTTP 200, 2048 tokens, `length`, 55.5 s |
| c: 1 streaming request, max_tokens 2048 | fixed | 1 | HTTP 200, 1998 content chunks, usage 2048 tokens, `length`, `[DONE]`, TTFT 2.1 s, 55.6 s |
| b: 1 request, max_tokens 2048 | unfixed 1.8.256 | 1 | HTTP 503 `continuous_batching_scheduler_no_progress` after 29.7 s |

- Fixed serve: 0 `continuous_batch_no_progress` lines; scheduler max batch
  depth 4, 521 shared forwards for the whole load.
- Unfixed serve: 1 line, `passes=64`, after exactly 64 shared forwards
  (64 windows x 16 = 1024 tokens).

## Files

- `timeline.txt` - window timeline (pause, lab legs, restore).
- `load-fixed.jsonl`, `load-unfixed-1.8.256.jsonl` - per-request results.
- `serve-events.log` - CB policy, served-slot and no-progress events.
- `identity.sha256` - binary and metallib hashes as run.
- `cb_long_output_load.py` - the load driver.
