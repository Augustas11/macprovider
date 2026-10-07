# Runtime-agnostic engine qualification

This protocol supplies routing, pricing and disclosure measurements for #1690.
It does not grant receipt authority, model verification, settlement capability,
or global routing eligibility. The operator approved the capability-aware
Ollama amendment on 2026-10-07. Pool admission and paid-path acceptance still
require the applicable SPEC-010/022/042/046 identity, authorization, receipt and
ledger evidence.

The capability boundary is pinned to [Ollama v0.34.4's generate API](https://github.com/ollama/ollama/blob/v0.34.4/docs/api.md#generate-a-completion),
[request/response schema](https://github.com/ollama/ollama/blob/v0.34.4/docs/openapi.yaml),
and [runner implementation](https://github.com/ollama/ollama/blob/v0.34.4/llm/llama_server.go).
`raw` controls text templating, `num_predict` is a maximum, and final counters
expose observed caching. The runner enables prompt caching internally. The
public request does not offer arbitrary prompt-token-ID injection or a
cache-disable control. Generated-token logprobs exist, but do not score corpus
prompt tokens or supply a runtime perplexity API. Reassess this profile when
the runtime version or these capabilities change.

## Two measurement profiles

The strict comparative M0 profile remains unchanged for native MLX and
llama.cpp: actual identical prompt-token sequences, 1024 prompt tokens, 256
forced timed decode tokens, no prompt cache, c=1/4/8, one warmup and five timed
rounds per level. Corpus/evaluated-input/scored-target token hashes must match
for comparative perplexity. Native production serial throughput must not be
confused with a lab-only contiguous-batched baseline.

Ollama uses a separate capability-aware operational profile. It must never be
called strict M0, cache-free, forced-EOS decode, identical-native-token input,
or Ollama runtime perplexity. An unsupported capability is disclosed as
unsupported or unmeasured, not passed. Failure of an available positive check
still fails qualification; this is not a waiver of malformed responses,
artifact drift, missing samples or endpoint restrictions.

## Ollama positive checks

Run the hidden operator-only `msb-ollama-loopback --capability-aware` command
against an isolated loopback runtime on the designated Studio. Record the
source commit, CLI/runtime binary digests, runtime version, model manifest and
exact GGUF digest. The existing model resolver must verify that digest before
and after measurement. Filesystem identity is not cryptographic proof of the
running process's loaded weights.

Use raw text prompts, temperature zero, requested prompt count 1024, requested
maximum generation count 257, c=1/4/8, one warmup and five measured rounds per
level. Each completed request must report exactly 1024 prompt tokens and
between 2 and 257 evaluation tokens. EOS-shortened generation is allowed only
as an explicitly measured operational result; it is not a forced-decode pass.
Missing final counters, malformed or incomplete streams, errors, invalid
counts, nonfinite timings and out-of-order timestamps fail the run.

Retain actual per-request prompt/evaluation counters, cached-prompt counter
(including explicit unknown when absent), completion reason when available,
TTFT and request duration. A reported cache count must be within 0...1024.
Cache hits are measured and disclosed rather than silently discarded. No
cache-free assertion may be inferred from an absent counter. Keep prompt hashes
and numeric samples but omit prompt/completion contents, local paths,
credentials and endpoints from published reports.

Report c=1/4/8 end-to-end aggregate throughput using actual reported evaluation
tokens divided by the complete round wall time, plus TTFT p50/p95 and variation.
The legacy first-chunk-to-end throughput remains a proxy: subtracting one
reported token does not prove that the first streamed text chunk contains
exactly one token. Requested decode counts must not be represented as achieved
counts. Cached/EOS-shortened operational throughput must not be divided by the
strict native baseline as though the workloads were identical.

There is no speed superiority threshold. Completion requires all positive
checks, all 65 measured requests across the three levels, explicit limitations,
and independent evidence review. Throughput measurements must use a coordinated
quiet window; a contended run is diagnostic only. Restore serving state before
releasing the window. A local candidate must never join the live coordinator.

## Quality evidence

Where the Ollama API does not expose corpus logits, runtime perplexity remains
unmeasured. Perplexity may instead be measured by llama.cpp on the exact GGUF
referenced by the Ollama manifest, with explicit corpus and token-boundary
proofs. Label it **artifact quality measured by llama.cpp**, not Ollama runtime
quality. Different native/GGUF quantizations are artifact comparisons, not
isolated runtime effects. This satisfies the amended artifact-quality arm,
without inventing an unsupported runtime-quality measurement.

## Evidence status

The 2026-10-07 06:58:53Z strict-count attempt failed on 1023 reported cached
prompt tokens. Its original nonzero result remains unchanged. The approved
amendment does not retroactively make it pass: a complete fresh capability-aware
measurement is required. The 07:15:49Z quality capture already binds the exact
Qwen GGUF and corpus/evaluated-input/scored-target hashes; it is artifact-quality
evidence only. Signed paid-path evidence, release verification and mixed-version
rollout acceptance remain independent gates.
