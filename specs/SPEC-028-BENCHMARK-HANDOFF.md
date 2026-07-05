# SPEC-028 benchmark handoff

Date: 2026-07-05

## Summary

SPEC-028 speculative decoding is present in the macprovider binary but remains
operator-gated by `draft_model`. Without a configured draft model, the runtime
does not load a draft model and all chat completions continue through the
target-only generation path.

Local M5 / 32 GB testing found one real throughput-positive pair:
Qwen2.5-Coder 7B target with Qwen2.5-Coder 1.5B draft. That pair improved
median and sustained throughput, but first-token latency regressed enough that
it should not be globally enabled yet.

The Qwen2.5-Coder 32B / 7B pair needs a larger Apple Silicon host before it
can be judged. On the 32 GB local host, it did not complete even a bounded
16-token smoke run within the session window.

## What changed in this handoff

- Added `spec028-benchmark`, a local CLI benchmark harness that runs baseline
  and speculative paths against SPEC-028 fixtures.
- Added recommendation gates for:
  - median speculative / baseline TPS ratio
  - p95 total latency ratio
  - p95 TTFT ratio
  - speculative acceptance rate
  - sustained TPS ratio when a sustained window is requested
- Relaxed tokenizer artifact matching for same-vocabulary fast-tokenizer
  snapshots:
  - ignore top-level `chat_template` in `tokenizer_config.json`
  - when `tokenizer.json` exists, do not treat redundant `vocab.json` /
    `merges.txt` packaging differences as incompatibility
  - when `tokenizer.json` is absent, keep `vocab.json` / `merges.txt` binding
    for slow-tokenizer layouts

## Local benchmark environment

- Host: Apple Silicon M5
- RAM: 32 GB unified memory
- Binary: release build of `macprovider-cli`
- Context cap used: 8192 tokens for the completed matrix
- Logs: `/tmp/spec028-release-matrix-20260705214654`

## Completed local matrix

| Pair | Fixture | Baseline TPS | Spec TPS | TPS ratio | Sustained ratio | Acceptance | Recommendation |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Llama 3.2 3B / 1B | `spec028-small-air-short-chat-v1` | 56.12 | 51.46 | 0.917x | 0.871x | 54.5% | Do not enable |
| Llama 3.2 3B / 1B | `spec028-small-air-streaming-check-v1` | 52.15 | 44.84 | 0.860x | 0.832x | 54.1% | Do not enable |
| Qwen2.5-Coder 7B / 1.5B | `spec028-code-iso8601-v1` | 24.74 | 31.42 | 1.270x | 1.322x | 96.5% | Throughput win, TTFT fail |

Qwen2.5-Coder 7B / 1.5B details:

- `tpsRatio`: 1.2698843002639708
- `sustainedRatio`: 1.3220061447492875
- `acceptanceRate`: 0.9645390070921985
- `p95LatencyRatio`: 0.7948502457691152
- `ttftP95Ratio`: 1.5052631578947369
- `recommendEnable`: false
- reason: `p95 TTFT ratio 1.505 > 1.000`

## 32B / 7B findings

Two blockers were found:

1. The initial `draft_model_tokenizer_mismatch` was our policy being too
   strict, not a real vocabulary mismatch. The 32B and 7B local snapshots had
   identical `tokenizer.json`, `vocab.json`, `added_tokens.json`, and
   `special_tokens_map.json`. The difference was a redundant `merges.txt` in
   the 7B snapshot.
2. After fixing that policy, the 32B / 7B run no longer failed immediately, but
   it did not produce benchmark JSON on the 32 GB local host. A 16-token smoke
   was also stopped after several minutes with an empty output file.

Local model footprint:

- Qwen2.5-Coder 32B 4-bit snapshot: about 17 GB
- Qwen2.5-Coder 7B 4-bit snapshot: about 4.0 GB
- Combined weights alone: about 21 GB before MLX runtime memory, KV cache,
  Metal buffers, allocator overhead, and OS pressure

Conclusion: 32B / 7B is not a measured loss. It is not locally benchmarkable on
the 32 GB host without a narrower diagnostic run or larger Apple Silicon RAM.

## Research and infrastructure plan

Generic cloud or VPS is not sufficient for the main decision because this work
tests MLX / Metal behavior on Apple Silicon. A Linux VPS or NVIDIA GPU box can
only validate the algorithm in another stack; it cannot validate macprovider's
real runtime path.

Recommended rented infra:

- Apple Silicon Mac Studio or Mac Pro
- Minimum: 64 GB unified memory
- Preferred: 128 GB unified memory
- Ideal: 192 GB or 256 GB unified memory

Candidate provider categories checked:

- MacStadium dedicated Apple Silicon Mac cloud
- MacWeb Mac Studio rental listings, including high-memory M2/M3 Ultra tiers
- MacinCloud dedicated/on-demand Mac servers

Run the same harness on rented Apple Silicon hardware, not on generic Linux
VPS. The goal is to test the exact `mlx-swift` and Metal execution path that
the product uses.

## Proposed rented-host matrix

Run release `macprovider-cli` with generated production resources.

Required pairs:

- Qwen2.5-Coder 7B target / 1.5B draft
- Qwen2.5-Coder 32B target / 7B draft
- Llama 3.2 3B target / 1B draft as a known negative control

Optional pairs if local snapshots and canary pass:

- Qwen3 32B / compatible smaller Qwen3 draft
- Qwen3-Coder 30B-A3B / compatible Qwen draft

Suggested command shape:

```bash
./macprovider-cli spec028-benchmark \
  --fixture phase3-binary/Sources/macprovider-cli/Resources/spec028/spec028-code-iso8601-v1.json \
  --target /path/to/target \
  --draft /path/to/draft \
  --max-context-tokens 8192 \
  --baseline-runs 5 \
  --spec-runs 5 \
  --sustained-seconds 60 \
  --last-window-seconds 30 \
  --max-p95-ttft-ratio 1.0
```

For first 32B smoke on rented hardware:

```bash
jq '.request.max_tokens=16' \
  phase3-binary/Sources/macprovider-cli/Resources/spec028/spec028-code-iso8601-v1.json \
  > /tmp/spec028-code-iso8601-16tok.json

./macprovider-cli spec028-benchmark \
  --fixture /tmp/spec028-code-iso8601-16tok.json \
  --target /path/to/Qwen2.5-Coder-32B-Instruct-4bit \
  --draft /path/to/Qwen2.5-Coder-7B-Instruct-4bit \
  --max-context-tokens 1024 \
  --baseline-runs 1 \
  --spec-runs 1 \
  --sustained-seconds 0 \
  --last-window-seconds 1
```

## Continuation plan

1. Keep SPEC-028 disabled by default.
2. Use this PR to preserve the benchmark harness, stricter recommendation
   gates, tokenizer policy fix, and evidence.
3. Rent or access a 128 GB+ Apple Silicon host.
4. Run the matrix above and attach raw JSON outputs to the follow-up PR.
5. If Qwen2.5-Coder 7B / 1.5B keeps its throughput win but TTFT still fails,
   investigate first-token mitigation:
   - warm draft and target prefill
   - defer speculative decoding until after the first token
   - cache/reuse prompt preparation where safe
6. If Qwen2.5-Coder 32B / 7B works on 128 GB+ and beats baseline, gate
   SPEC-028 by model pair and RAM tier instead of enabling globally.

## Tests run

```bash
swift test --package-path phase3-binary \
  --filter Spec028PlumbingTests/testTokenizerArtifactFingerprintBindsTokenizerFiles \
  --filter Spec028PlumbingTests/testSpec028BenchmarkEvaluationGatesTTFTRegression
```

Result: passed.

```bash
swift build --package-path phase3-binary -c release --product macprovider-cli
```

Result: passed with existing Swift concurrency/deprecation warnings.

## Current recommendation

SPEC-028 was not oversold in principle: Qwen2.5-Coder 7B / 1.5B showed a real
throughput improvement and high acceptance locally. The current implementation
is not ready for default enablement because TTFT regressed and larger model
pairs require Apple Silicon hardware with more unified memory.
