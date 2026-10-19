# Preregistration: R015 v2 for the GLM-5.3-Flash native-MTP tuple

Frozen before any warmup or measured request of this run. `policy.json` is not
modified after the run starts; a changed policy is a new preregistration. The
1.8.256 policy (`../glm53-flash-v1.8.256/`, `14741db0…`) stays frozen with its
FAIL.

- Policy: `policy.json`, SHA-256
  `5ca7e3b34a7eec5163a136782d85551cd57f6da0da0b02c808355ba02a67cfab`. It is the
  1.8.256 policy with two fields changed: `provider_commit`
  (`916faf3b7faedc815d864987a185c1464e5c4962`, the fix below) and `seed`
  (`20261019`, a fresh counterbalanced order). The tuple, matrix, gated cells,
  sustained window, methodology and every threshold are unchanged.
- Binary: a lab-harness release build of `provider_commit` with the signed
  1.8.256 `mlx.metallib` (`3d9b4a74…`); the fix changes no kernel. The
  window script refuses any other `macprovider-cli` than
  `R015_HARNESS_SHA256`:
  `0ac0606b71cf501277cb2f243dc57da715c8101c478b9ddc43a8dbafce9a8e59`, built on
  the Studio from `provider_commit` (`swift build -c release --product
  macprovider-cli --build-path .build-lab-harness -Xswiftc
  -DMACPROVIDER_LAB_HARNESS`, 2026-10-19T00:00Z).
- Environment: as in the 1.8.256 preregistration (`Mac15,14`, Apple M3 Ultra,
  256 GB, macOS `26A434`, Swift 6.3.3 from the Command Line Tools), re-read on
  the Studio on 2026-10-19.

## Why a new run (AGENTS.md hard rule 2)

Existing evidence: window 2026-10-18T13:38Z, JSONL `eb8cd460…` (167 records),
`analysis.json` `224b18b0…`, harness `26b075b4…`. Its one-active-row decode
passes in every cell (+16.9% to +20.9% lower bound, acceptance 0.78-0.81);
it fails the 4096-token TTFT bound and every gated-cell gate.

Decode-path lines changed since that evidence (commits `ada2ecb96`..`916faf3b7`):

- `ContinuousBatchScheduler.selectRaggedPrefillGroup`: a native prompt row is
  a ragged-group candidate when
  `ContinuousBatchSchedulerConfiguration.nativeMTPPromptRowsJoinRaggedPrefill`
  holds, which `ModelRuntime` sets from
  `PagedKVSharedForwardBackend.prefillsGroupedRowsAlone` (SPEC-038 v0.3.22
  FR-CB2): no two-row shared prefill forward fits the backend's
  flattened-token cap at the smallest chunk that may group (glm5_next: 8
  tokens against 144). Every grouped GLM row already prefills alone on the
  serial path, so the change moves when a native row's chunk runs, not a
  forward's shape. Backends without such a cap (Qwen3.6 A3B) are unchanged.
  The gated failure was this schedule, not a decode cost: no native round
  ran in a gated cell (`mtp_forwards` 0), the inter-token gap p50 equalled
  the ordinary arm's (34.2 ms at s2), and the end-to-end ratio was 0.988
  (s2) and 0.994 (s4). Kept out of the group, the native row prefilled alone
  and got its first token about 1 s before the ordinary arm's first row
  (6.5 s against 7.5 s at s2); the later rows' prefill then fell inside its
  decode window, which the windowed decode rate (first first-token to last
  end) and TPOT charge.
- `NativeMTPBenchRunner.runCell` (lab only): every block's prompts are sized
  before the first timed run, and sizing bisects the salt count
  (`NativeMTPBenchPrompts`, same texts, `deterministic_synthetic_unique_v2`).
  In the failed run the first run of each 4096-token block measured about
  2.4 s more TTFT on both paths (ordinary 16.2 s against 13.8 s, native
  16.9 s against 14.5 s; also s4 and the sustained window), and the
  counterbalanced order made the paired ratio bimodal: medians +4.7% /
  +8.4%, corrected bound +22%. The Qwen3.6 A3B R015 run
  (`../evidence-2026-10-06-a3b-amended-gates-quiet-26a434`) shows no such
  order effect. The native path's own TTFT cost is the same-position
  difference: +3.7% at 1536 tokens, +5% at 4096.

## Expectation (not a gate)

One-row cells keep their decode gain. The 4096-token TTFT bound falls near
the same-position +5%. The gated cells' native and ordinary arms run the
same prefill schedule, so their decode, TTFT and TPOT ratios fall near 1.

## Decision rule

`scripts/native_mtp_r015_analyze.py` on the run's JSONL and this policy gives
the verdict: PASS only when every cell passes every gate. The admission entry
binds the resulting `analysis.json`; a FAIL leaves GLM on ordinary decode.
