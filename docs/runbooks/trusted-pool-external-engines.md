# Serving a Trusted Pool with your own engine

For a provider who operates a SPEC-042 Trusted Pool and wants its Macs to
serve that pool's buyers with an inference engine other than Malibu's native
MLX runtime: llama.cpp, LM Studio, Ollama, `mlx_lm.server`, or oMLX.

Buyers pick an engine with `X-MacProvider-Engine-Select`; that side is in
[Choosing an inference engine](../using-macprovider-with-openai-sdk.md#choosing-an-inference-engine).
The first production activation of a pool with an external engine follows
[the M1 activation plan](trusted-pool-m1-activation-plan.md) and
[section 9 of the production launch runbook](trusted-pool-production-launch.md#9-external-runtime-pools-1690-rollout-and-rollback-order).

## What an external engine can and cannot do

- **It earns only inside a Trusted Pool.** A `macprovider-cli serve` session
  that fronts an external engine is sandboxed for global traffic (SPEC-032
  FR-HG8) and never reaches `settlement_capable` (SPEC-047-R003(iv)). It
  serves paid buyer requests only on the route of a pool whose signed v2
  policy core lists its engine in `runtime_allowlist`, whose member it is,
  and whose creator account owns the provider (SPEC-042-R004, R013). On the
  global network the same Mac serves nothing through that engine.
- **Usage is the pool operator's own, signed.** The CLI relays the engine's
  token counts, signs them in a v0.4 receipt for pool-authorized requests
  only, and the coordinator records them as `pool_operator_attested`
  (SPEC-022-R012), bounded by the SPEC-005 ceilings. It is administrative
  trust: the coordinator cannot see that the declared engine is the process
  running, that it loaded the file the CLI hashed, or that its counts are
  right. Declaring one engine and running another breaks your own signed
  policy.
- **The identity is the CLI's, never the engine's.** The CLI hashes the
  model file or MLX snapshot you name and reports that digest. The engine
  only has to show, at startup and before every request, that it serves
  that file (the binding column below). Any change to the file, or an
  engine that stops listing it, fails the request closed as
  `model_not_loaded`.
- **One `serve` process, one model, one engine.** Switching a Mac to another
  engine is a new offer (the old candidate is revoked as
  `runtime_identity_drift`), a new operator pricing decision, and a serve
  restart.

## Engines

| Engine | `--model` / `model:` | `runtime_source`, buyer value | Model identity | Serving-time binding | Extra operator env |
|---|---|---|---|---|---|
| llama.cpp `llama-server` | `llamacpp:<file stem>` | `llamacpp_loopback`, `llamacpp` | GGUF file, `macprovider.gguf-file.v1` | `GET /props` `model_path` is the file you pinned | `MACPROVIDER_LLAMACPP_MODEL_PATH` (one file) or `MACPROVIDER_LLAMACPP_MODEL_ROOT` |
| Ollama | `ollama:<tag>` | `ollama_loopback`, `ollama` | GGUF blob the tag's manifest names in `OLLAMA_MODELS` | the manifest in your Ollama store | `OLLAMA_MODELS` if not `~/.ollama/models` |
| LM Studio (0.4+, app server or headless `llmster`) | `lmstudio:<model key or --identifier>` | `lmstudio_loopback`, `lmstudio` | the one GGUF the name resolves to under your LM Studio models root, narrowed by the publisher and exact size of LM Studio's `GET /api/v1/models` entry when several match (never by a path LM Studio reports); several left is an error | `GET /api/v1/models`: one loaded instance answers the name, format `gguf`, with the file's publisher and exact size | `MACPROVIDER_LMSTUDIO_MODELS_ROOT` if not `~/.lmstudio/models` |
| `mlx_lm.server` | `mlxlm:<snapshot dir name>` | `mlxlm_loopback`, `mlxlm` | MLX snapshot, `macprovider.snapshot-manifest.v1` | `GET /v1/models` lists the snapshot's path | none when the server runs with a local `--model` path (auto-detected); `MACPROVIDER_MLXLM_MODEL_PATH` and `MACPROVIDER_MLXLM_ORIGIN` override |
| oMLX (`omlx serve`) | `omlx:<snapshot dir name>` | `omlx_loopback`, `omlx` | MLX snapshot, `macprovider.snapshot-manifest.v1` | `GET /v1/models/status`: one local `llm` entry whose `model_path` is the snapshot | `MACPROVIDER_OMLX_MODEL_PATH` (required), `MACPROVIDER_OMLX_ORIGIN` |

The CLI reaches the engine at `loopback_origin` (config key, or
`MACPROVIDER_LOOPBACK_ORIGIN`), which must be a loopback origin such as
`http://127.0.0.1:<port>` (any address in `127.0.0.0/8`) or
`http://[::1]:<port>`; every other origin is refused. Without it the CLI uses
the engine's usual port (llama.cpp and `mlx_lm.server` 8080, Ollama 11434,
LM Studio 1234, oMLX 8000). Malibu's own serve port is also 8080 by default,
so give either the engine or `serve` another port. For `mlx_lm.server` use
port 8081: the CLI looks there as well as on 8080.

**`mlx_lm.server` auto-detect.** When `MACPROVIDER_MLXLM_MODEL_PATH` is
unset, `models discover`, `evaluate`, `propose`, `offer` and `serve` ask
`loopback_origin` (serve only), else `MACPROVIDER_MLXLM_ORIGIN`, else
`127.0.0.1:8080` and `127.0.0.1:8081` for `GET /v1/models`, and use the one
local snapshot directory the server lists as its `--model` path. Malibu's
own serve lists catalog ids there and is never taken for `mlx_lm.server`, and
no command probes the provider's configured serve port, even when an origin
names it. Only an answer shaped like `mlx_lm.server`'s own is used: a Python
`http.server` (`Server: BaseHTTP/... Python/...`) whose model entries carry
exactly `id`, `object` and one shared `created` (another OpenAI-compatible
server, which sends `owned_by`, is ignored). The listed directory is used only when,
with symlinks resolved, it is inside the provider model store
(`~/Library/Application Support/macprovider/models`, or
`MACPROVIDER_MODEL_ARTIFACT_ROOT`) or is a Hugging Face hub cache snapshot
(`<hub>/models--*/snapshots/<revision>`); any other directory is refused with
an error naming it, and you set `MACPROVIDER_MLXLM_MODEL_PATH` to it to serve
it. A `MACPROVIDER_MLXLM_MODEL_PATH` that is not an absolute path is an error,
never treated as unset. The detected directory is hashed and bound exactly
like a declared one. A
server started with a Hugging Face repo id lists no path and is refused:
start it with `--model <path written by macprovider-cli models prepare>`.

A GGUF engine serves a catalog row's GGUF artifact, and the catalog release
must carry that artifact (`runtime_format: gguf`) with the engine in
`allowed_runtime_sources`. An MLX engine serves the row's MLX snapshot, and
the release-bound MLX artifact must list that engine itself: an artifact that
allows `mlxlm_loopback` admits nothing for oMLX, and the reverse (SPEC-010-R009,
SPEC-023 §3.7.4). A catalog release that lists `mlxlm_loopback` (v0.17.0)
or `omlx_loopback` (v0.20.0) must not be cut before every consumer reads it
(the generator's per-runtime-source consumer floor enforces this).

## Steps

1. **Start the engine on a loopback port**, serving exactly the model you
   will offer. Examples that have run in the #1690 lab:

   ```bash
   # llama.cpp
   llama-server -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 19130 -c 8192 -np 4 -ngl 99 --jinja
   # Ollama
   OLLAMA_HOST=127.0.0.1:19130 ollama serve     # then: ollama pull qwen2.5:0.5b
   # mlx_lm.server (a local snapshot path, not a repo id)
   mlx_lm.server --model /models/mlx/Qwen2.5-0.5B-Instruct-4bit --host 127.0.0.1 --port 8081
   # LM Studio (headless): the key, or a custom --identifier, is the served name
   lms server start --port 19130 --bind 127.0.0.1
   lms load qwen2.5-0.5b-instruct -c 8192 -y
   # oMLX: the model directory holds the snapshot as a subdirectory; no API key
   omlx serve --model-dir /models/omlx --host 127.0.0.1 --port 19130
   ```

   - llama.cpp needs `--jinja` for chat templates and tool calls.
   - LM Studio: the name must resolve to one `.gguf` under the models root
     (`<publisher>/<repo>/<file>.gguf`). When several quantizations of one
     repo match, the CLI narrows those locally name-matched files by the
     publisher and exact size of the loaded entry in `GET /api/v1/models`
     (never by a path LM Studio reports); if more than one file remains, it
     fails closed and names the files to remove. A model loaded with a custom
     `--identifier` is offered and served as `lmstudio:<identifier>`; the
     identifier maps to its entry's key, and chat requests name the
     identifier. LM Studio's list only narrows the files the name already
     matches; it never names a file.
   - oMLX: an API key (`--api-key`, `OMLX_API_KEY`) or a non-loopback bind
     closes its status endpoint to the CLI, so serving fails closed. A
     distributed (multi-Mac) deployment is not a local snapshot and is
     refused.

2. **Configure the provider.** In the provider's `config.yaml`:

   ```yaml
   model: llamacpp:qwen2.5-0.5b-instruct-q4_k_m   # the engine's --model value
   model_catalog_key: qwen2.5-0.5b-instruct        # the catalog row served
   model_catalog_model_id: mlx-community/Qwen2.5-0.5B-Instruct-4bit
   loopback_origin: http://127.0.0.1:19130
   enable_receipts: true
   ```

   plus the engine's extra env from the table.

3. **Serve, then offer the candidate.** Start `macprovider-cli serve`, then
   offer the same model reference:

   ```bash
   macprovider-cli models discover --json                # see the candidate and its identity_state
   macprovider-cli models offer llamacpp:qwen2.5-0.5b-instruct-q4_k_m --yes --json \
     --skip-ollama --skip-lmstudio --skip-openai-compatible --llamacpp-origin http://127.0.0.1:19130
   ```

   Use the matching `--*-origin` flag and skip the other adapters. oMLX is
   found through `MACPROVIDER_OMLX_*` instead of a flag; `mlx_lm.server` is
   auto-detected (see above) or set through `MACPROVIDER_MLXLM_*`. Expect `catalog_match_state: catalog_matched`.

4. **Pricing and the pool policy (operator and pool creator).** An operator
   records the candidate `catalog_priced` (`POST
   /admin/model-admission/decisions`), and the pool creator signs a v2
   policy core whose `runtime_allowlist` lists the engine, with settlement
   mode `enforce`:

   ```bash
   coordinator-cli trust-pool-admin sign-manifest ... --encoding 2 \
     --settlement-mode enforce --runtime-allowlist llamacpp_loopback
   ```

   The full command, keys, and event flow are in the
   [M1 activation plan, section 4](trusted-pool-m1-activation-plan.md#4-the-pool-manifest).

   Adding an engine to a pool is a loosening: it mints a new
   `manifest_version`. The provider must be a pool member and belong to the
   creator's account. Restart `serve` after the pricing decision so the
   session binds it.

5. **Check the member**, on the coordinator: `/poolz` shows the session with
   the engine's `runtime_source`, the identity algorithm from the table,
   `hash_status: hash_verified`, and `state: ready`.

6. **Send a buyer request** with `X-MacProvider-Pool-Select: <pool-id>` and
   `X-MacProvider-Engine-Select: <buyer value>`. The response carries
   `X-MacProvider-Engine: <runtime_source>` and a receipt, and the settlement
   records `pool_operator_attested` usage.

## Buyer disconnects

When a buyer disconnects mid-stream, the attempt ends `buyer_cancel`, and the
CLI signs the usage of exactly the delivered content when the engine lets it
state it (SPEC-015 §N.12 item 7):

| Engine | Completion tokens of the delivered part | Prompt tokens |
|---|---|---|
| llama.cpp | per-chunk `timings_per_token` | the same timings |
| Ollama, LM Studio | per-chunk `logprobs` token list (the CLI asks for it) | the engine's own count for the same request, asked once after the cancel |
| `mlx_lm.server`, oMLX | the served snapshot's tokenizer over the delivered text | the engine's own count, as above |
| any engine whose stream carries no per-chunk count (LM Studio with tools, an Ollama that ignores `logprobs`) | the tokenizer of the catalog model's prepared MLX artifact over the delivered text, used only when that artifact's digest equals the signed catalog row's | the engine's own count, as above |

The coordinator waits 2 s for the cancelled frame, so the CLI gives the
prompt count and the tokenizer count 1.25 s together and loads the tokenizer
when `serve` starts. If anything is late or fails (an engine busy with other
requests, no local tokenizer, a streamed tool call), the partial stream is
left unsigned: it is not billed to the buyer and not credited to you. It is
never billed wrong.

The tokenizer count counts the delivered visible text only. Reasoning text
and streamed tool-call arguments are not in it, so the signed completion
count can be lower than what the engine generated; the difference is in the
buyer's favour.

GGUF engines fall back on the catalog model's MLX artifact, so prepare it
(`macprovider-cli models prepare <key>`). The CLI looks for it where native
serving does: the verified model-artifact store first, then the snapshot
macprovider downloaded into the Hugging Face cache. It uses the first one whose
digest (every file in the directory, plain files only) equals the signed
catalog row's. A snapshot written by `huggingface-cli` or `hf download`, whose
files are symlinks into `blobs/`, is not used, because native serving does not
use it either.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `serve` exits with `upstreamNotRecognized(<runtime_source>)` | The engine is not reachable at `loopback_origin`, is a different engine, or does not list the declared file (llama.cpp `/props`, LM Studio key not loaded or another size, oMLX status without the snapshot, oMLX API key set). |
| `serve` exits with `artifactResolutionFailed` | No declared file or snapshot (missing env), an ambiguous LM Studio key (several GGUFs with the same publisher and size: remove the others from the models root, or load the model under a key naming one file), or a snapshot that changed while hashing. |
| Requests fail `503 model_not_loaded` | The engine stopped listing the bound file, or the file changed. Restart `serve` after restoring it. |
| Buyers get `503 engine_unavailable` | The pool's active policy does not list the engine, the Mac is not a current member, or no member of that engine serves the model right now. |
| Offer answers `runtime_source_not_allowed` | The catalog release's artifact for this model does not list the engine in `allowed_runtime_sources`. |
