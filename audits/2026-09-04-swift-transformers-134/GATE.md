# swift-transformers token-exact gate — issue #966

Date: 2026-09-04
Scope: `phase3-binary` provider CLI tokenizer dependency.
Verdict: **PASS** — advance the exact pin to `1.3.4`; no token-ID blockers.

## Context correction

Issue #966 was written to gate a deliberate `1.0.0 → 1.3.3` token-exact
migration. That bump had **already landed on `main`** via Dependabot
consolidation PR #1336 (`4e54ea64`), treated as a low-risk bump and verified
only with `swift build` + Go tests — the #966 token-exact corpus gate was never
run. The bump is **not yet in any released tag** (`git tag --contains
4e54ea64` = 0; not an ancestor of `v1.8.118`), so this gate runs before it can
reach the fleet.

Upstream has since cut `1.3.4` (2026-09-02). Its changelog carries **no
tokenizer/BPE/pre-tokenizer changes** vs `1.3.3` (revision support, `Hub.Repo`
Sendable, jinja→2.4.2, and a fix to swift-transformers' own sampler for
vocab > 65 536 — a path macprovider does not use since MLX samples). Tokenizer
bytes are therefore identical `1.3.3 == 1.3.4`; this gate validates the full
`1.0.0 → 1.3.4` delta and lands at `1.3.4`.

## Method

Minimal SwiftPM harness (`harness/`) importing only `Tokenizers`, built at
`1.0.0` and `1.3.4` (same source, no API break), loading each model's real
`tokenizer.json` and encoding a fixed 20-row Unicode corpus (`corpus.json`)
covering ASCII, emoji/grapheme clusters, combining marks, CJK/Japanese
(incl. voiced + half-width kana), code, JSON, and model special tokens.
Comparison is on **token IDs** (not decoded text). Temperature is irrelevant —
tokenization is deterministic. Raw per-model outputs are in `token-parity/`.

## Result matrix

| Model (catalog family) | tokenizer type | 1.0.0 → 1.3.4 token IDs | Notes |
|---|---|---|---|
| Qwen3-8B | BPE + NFC | **IDENTICAL** | token-exact |
| Qwen2.5-Coder-7B | BPE + NFC | **IDENTICAL** | token-exact |
| Llama-3.2-3B | BPE (byte-level) | **IDENTICAL** | token-exact |
| GPT-OSS-20B | BPE (o200k byte-level) | **IDENTICAL** | token-exact |
| Gemma-4-26B | BPE + Replace/metaspace | **5 / 20 rows changed** | all intended Unicode corrections (below) |
| Nemotron-3-Nano-30B | BPE (`TokenizersBackend`) | **n/a** | 1.0.0 cannot load it (`unsupportedTokenizer`); 1.3.4 loads — new capability |

Every catalog tokenizer is byte-level/BPE. None traverse the Unigram /
SentencePiece / Bert-NFD normalizer paths that 1.3.3's Japanese-voiced-kana and
NFD fixes target, which is why the byte-level families are unaffected.

## Gemma delta classification (all intended corrections)

| Row | category | 1.0.0 → 1.3.4 tokens | decoded text | classification |
|---|---|---|---|---|
| emoji_zwj_family | emoji | 46 → 19 | identical | 1.0.0 over-fragmented ZWJ sequence into byte fallbacks; 1.3.4 correct |
| combining_stacked | combining | 20 → 12 | identical | over-fragmentation corrected |
| cjk_japanese_halfwidth | cjk | 47 → 19 | identical | half-width voiced-kana fragmentation corrected |
| emoji_skin_tone | emoji | 30 → 9 | **1.0.0 DROPPED trailing 👌🏻** | 1.0.0 data-loss bug; 1.3.4 preserves the grapheme |
| combining_marks | combining | 20 → 14 | **1.0.0 leaked `▁` metaspace** (`vs▁café`) | 1.0.0 artifact bug; 1.3.4 clean |

No delta preserves a decoded-text regression. Two rows fix genuine 1.0.0 bugs
(dropped emoji, leaked metaspace). Per #966 these are allowed as intended
upstream corrections — old Unicode bugs are not preserved for parity.

**Cache-identity consequence:** Gemma prefill/KV caches keyed on 1.0.0 token IDs
for Unicode-heavy inputs are incompatible and must be invalidated (they encode
the corrected token stream under 1.3.4). Byte-level families (Qwen, Llama,
GPT-OSS) are unaffected — their cache identity is unchanged.

**Billing consequence:** Gemma prompt/completion token *counts* shift only for
Unicode-heavy inputs, and only downward (1.0.0 over-counted). Since 1.3.x has
not shipped, no in-flight receipts assumed 1.0.0 Gemma counts.

## Long-input tokenizer latency (best of 20, 237 KB input)

| Model | 1.0.0 | 1.3.4 | change |
|---|---|---|---|
| Qwen3-8B | 578 ms | 298 ms | ~1.9× faster |
| Gemma-4 | 1826 ms | 93 ms | ~20× faster |

Confirms 1.3.2's BPE/pre-tokenizer performance work. No latency regression.

## Dependency-graph note (pre-existing, out of scope here)

`main`'s committed `Package.resolved` (from Dependabot #1336) carries 15
orphaned pins — `async-http-client`, `swift-xet`, the swift-nio-ssl/http2/extras
/transport-services stack, `swift-certificates`, `swift-log`,
`swift-distributed-tracing`, `swift-service-lifecycle`, etc. Nothing in the
current graph references them; `swift package resolve` prunes them all. They are
inert lockfile cruft, unrelated to the tokenizer version. This PR keeps them
untouched (minimal, tokenizer-scoped diff, matching #1336's lockfile style); a
separate hygiene PR can prune them and decide on `swift-huggingface` 0.9.0→0.10.0.

## Reproduce

```bash
cd audits/2026-09-04-swift-transformers-134/harness
# fetch tokenizer.json + tokenizer_config.json for each model into toks/<name>/
TOKPARITY_TRANSFORMERS_VERSION=1.0.0 swift build -c release && \
  .build/release/tokparity toks/<name> corpus.json out/<name>-1.0.0.json
rm -rf .build Package.resolved
TOKPARITY_TRANSFORMERS_VERSION=1.3.4 swift build -c release && \
  .build/release/tokparity toks/<name> corpus.json out/<name>-1.3.4.json
```
