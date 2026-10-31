# SPEC-048 — Native Multi-Token Prediction Serving

**Version:** 0.1.66

```json
{
  "spec_id": "SPEC-048",
  "title": "Native Multi-Token Prediction Serving",
  "version": "0.1.66",
  "path": "specs/SPEC-048-native-mtp-serving.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["native-mtp-serving"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-005", "SPEC-010", "SPEC-011", "SPEC-015", "SPEC-018", "SPEC-019", "SPEC-022", "SPEC-023", "SPEC-024", "SPEC-028", "SPEC-030", "SPEC-031", "SPEC-032", "SPEC-033", "SPEC-036", "SPEC-037", "SPEC-038", "SPEC-039", "SPEC-041"],
  "implementation_status": "partial",
  "production_status": "pending-verification",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/1770",
    "rationale": "Issue #1770 has a branch-local native target-local MTP implementation with signed admission parsing, default-off selection, row-local transactions, status diagnostics, tuple revocation, provider self-test, and coordinator canary plumbing. Conformance and production remain pending until the frozen diff completes CI, Mac Studio hardware evidence, three-lane audits, and signed journey evidence. MXFP8 remains independently unqualified."
  }
}
```

## 1. Purpose and scope

SPEC-048 defines a third provider-local decode path, `native_mtp`, in which a
model's own multi-token-prediction component proposes tokens and the same
target model verifies them. Its outcome is higher sustained provider decode
throughput without changing generated token IDs, terminal behavior, buyer API
shape, usage, receipts, billing, rewards, trust, routing, or settlement.

The closed decode-path enum is:

```text
decode_path = ordinary | classic_draft_spec | native_mtp
```

`classic_draft_spec` is SPEC-028 target-plus-external-draft decoding.
`native_mtp` is not a draft-model configuration and is never inferred from,
represented by, or counted through SPEC-028's `draft_model`,
`num_draft_tokens`, `spec_decode_*`, single-slot flag, or external-draft
artifact contract.

The v0.1 production outcome is not a serial demonstration. It is a
text-only, multi-row path for greedy rows and, on tuples signed for it, seeded
sampled rows (MTP-4/MTP-5), that preserves isolated ordinary-decode semantics
while different rows propose and accept different token counts in one
continuous-batching round. The serial path is a required correctness oracle
and diagnostic milestone, not issue completion or production enablement.

Issue #1770 also requests MLX-native MXFP8. SPEC-048 does not own a general
quantization format, model-fit policy, signed catalog schema, or autotune
policy. Those remain SPEC-023 and SPEC-010 authority. This spec defines only
the native-MTP conditions that an independently qualified MXFP8 artifact must
satisfy before the combined `native_mtp + mlx_mxfp8` tuple may be enabled.
Loader success, an `FP8` name, or an upstream benchmark is not qualification.

Accepted journey id: `JOURNEY-NATIVE-MTP-SERVING`.

### In scope for v0.1

- immutable native-MTP capability and artifact binding;
- the operator-owned MLX fork dependency tuple (MTP-3) with stable
  row-mapped transaction primitives;
- exact greedy, and seeded sampled, token and terminal parity against
  ordinary decode;
- per-row proposal, verification, prefix commit, discard, and rewind;
- mixed ordinary/native-MTP continuous batches with bounded memory and fair
  scheduling;
- paged-KV and hybrid recurrent-state transaction correctness;
- fail-closed request-feature selection and pre-output fallback;
- bounded provider-local observability and safe warm-swap reset;
- independent MLX-native MXFP8 qualification before any combined admission;
- signed catalog/autotune and real-hardware evidence consumed through the
  owner specs; and
- a release-quality hardware campaign including a 256 GB Mac Studio and each
  hardware/RAM tier advertised for the admitted tuple.

### Explicit non-goals

- enabling, weakening, or treating as fixed SPEC-028 classic speculation or
  upstream `mlx-swift-lm#424`;
- training or converting an MTP head;
- probabilistic (rejection-sampling) speculative acceptance; sampled rows are
  verified only by target-sample exact match (MTP-5);
- grammar-constrained tools, structured output, logprobs, penalties,
  conversation-cache reuse, or disk-cache reuse on the v0.1 native-MTP path;
- vision or image inputs, even when an admitted artifact originated from a
  vision-language model;
- custom MXFP8 Metal kernels or a second inference runtime;
- buyer-visible MTP fields or changes to provider compensation; and
- connecting an unreleased, locally built, unsigned, or ad-hoc-signed provider
  binary to the live Malibu coordinator.

## 2. Dependencies and authority

SPEC-048 owns `native-mtp-serving`: native-MTP capability, decode-path
selection, proposal/verification semantics, row-local state transactions,
native-MTP request eligibility, fallback and stickiness, MTP-specific
observability, and the combined native-MTP production gate.

It consumes, and does not redefine, these owner contracts:

- **SPEC-001** owns provider configuration, status, heartbeat, streaming, and
  provider wire schemas. Native-MTP heartbeat fields remain unshipped until
  SPEC-001 admits them.
- **SPEC-005** owns billing, settlement, and rewards. Native MTP changes no
  price, usage formula, or credit rule.
- **SPEC-010** owns canonical model and artifact identity.
- **SPEC-011** owns warm-swap lifecycle and snapshot identity.
- **SPEC-015** owns receipt fields and receipt verification.
- **SPEC-018** and **SPEC-019** own tools and structured-output semantics;
  native MTP consumes their request classification only to remain ineligible.
- **SPEC-022** owns route-time verified-settlement prerequisites.
- **SPEC-023** owns signed catalog/autotune policy, artifact-feed fields,
  quantization admission, model-fit policy, and evidence-backed recommendation.
- **SPEC-024** owns conversation-cache isolation and cached-token accounting.
- **SPEC-028** owns only classic target-plus-external-draft speculation.
- **SPEC-030**, **SPEC-031**, and **SPEC-036** own losslessness,
  canary/sanction, and compute-integrity evidence. Native MTP supplies an
  owner-compatible greedy canary instead of diverting every integrity probe to
  ordinary decode.
- **SPEC-032** owns hardware-evidence admission and proof-of-weights
  boundaries.
- **SPEC-033** owns hardware-evidence verification.
- **SPEC-037** owns persistent KV. Its codec-v3 amendment permits complete
  GLM prompt snapshots, including paired native-MTP head state, under the
  identity, privacy, exactness and memory gates in MTP-9; other speculative
  state remains excluded.
- **SPEC-038** owns continuous-batching admission, fairness, row lifecycle,
  capacity advertisement, and release-quality economics gates.
- **SPEC-039** owns paged-KV layout, allocator, block-table lifecycle, and
  cache-engine capability.
- **SPEC-041** owns relay-blind content confidentiality. Native MTP adds no
  plaintext fields and treats timing and burst shape as observable metadata.

If this spec and an owner spec conflict, the owner spec governs its domain and
`native_mtp` remains disabled until the conflict is resolved by amendment.

## 3. Terms and state model

| Term | Meaning |
|---|---|
| Native MTP | Target-local prediction components propose one or more next-token candidates that the target verifies. |
| Proposal depth | Maximum candidate count requested for one row in one MTP round. |
| Verification span | The proposal positions plus any documented target bonus-token position evaluated in one target verification operation. |
| Accepted prefix | Longest contiguous verified proposal prefix before the first rejection or terminal boundary. |
| Bonus token | At most one target-selected token emitted under the qualified upstream algorithm after the accepted prefix. |
| Pre-round checkpoint | Exact row-local target KV, MTP state, recurrent/hybrid state, offsets, and terminal-detector state before proposal begins. |
| Staged state | State produced during proposal/verification that is not yet visible to later rounds or persistence consumers. |
| Committed state | The exact prefix of staged state corresponding to tokens the ordinary-decode oracle retains at the same boundary. |
| NativeMTPCapability | Immutable load-time description binding model identity, MTP tensors, family adapter, depth, cache/state support, request-feature support, quantization, and runtime revision. |
| Path sticky | After the first native proposal/target-state mutation (and therefore before any possible buyer-visible output), execution cannot switch between native MTP and ordinary decode. |
| Qualified tuple | Exact hardware, OS/toolchain, provider release, MLX runtime, model/artifact, quantization, cache mode, MTP depth, slot-count, and native active-row bound combination covered by evidence. |
| Native active-row bound | Signed per-tuple `max_native_active_rows`, `1 <= bound <= qualified_slots`: the largest number of concurrently active decode rows, native and ordinary together, at which the tuple's native-eligible R015 cells show native MTP beating ordinary decode. Gated cells above it prove only safety and non-inferiority and never justify or raise it. |

The request path state machine is closed:

```text
unselected
  |-> ordinary_selected
  |-> classic_draft_spec_selected
  `-> native_mtp_selected

native_mtp_selected + pre-output recoverable failure
  -> ordinary_selected only after exact pre-request state restoration

native_mtp_selected + first native proposal/target-state mutation
  -> native_mtp_sticky

native_mtp_sticky + failure
  -> terminal_error

ordinary_selected | classic_draft_spec_selected | native_mtp_selected
  -> terminal_success | terminal_error | terminal_cancelled
```

There is no transition from `native_mtp_sticky` to ordinary decode and no
output stitching across paths.

## 4. Normative requirements

Normative terms use RFC 2119 meanings. Requirement IDs are permanent
conformance units.

### MTP-1 — closed path identity and selection (SPEC-048-R001)

The provider MUST represent `ordinary`, `classic_draft_spec`, and `native_mtp`
as distinct decode paths selected before inference work that can escape the
request. `native_mtp` MUST NOT set, consume, or increment SPEC-028
configuration, telemetry, capacity, or fallback state. A request MUST execute
on at most one selected accelerated path. If classic draft speculation is
configured, its SPEC-028 single-slot and production-safety rules remain
unchanged. When a non-empty `draft_model` is configured, native MTP is
ineligible and `classic_draft_spec` has precedence for requests SPEC-028 admits;
all other requests use ordinary decode. The two accelerated paths MUST NOT be
resident/selected simultaneously for one served snapshot.

Native MTP MUST be default-off until every gate in SPEC-048-R014 passes for
the exact qualified tuple. Absence or rejection of native-MTP capability MUST
leave ordinary decode available when ordinary decode is otherwise valid.

### MTP-2 — immutable capability and fail-closed artifact binding (SPEC-048-R002)

At model load, the provider MUST construct `NativeMTPCapability` from verified
artifact bytes, parsed model configuration, the qualified upstream loader
result, and the signed SPEC-023/SPEC-010 identity. The capability MUST bind:

- exact model identifier, revision, artifact digest, and tokenizer identity;
- model family and family-adapter identifier;
- MTP tensor-manifest digest and source layout, including in-checkpoint
  `mtp.*`, configuration-declared next-N layers, or a separately bound MTP
  artifact;
- prediction-layer count and allowed proposal depths;
- hidden-state, embedding/head sharing, cache, and recurrent-state interfaces;
- target and MTP tensor quantization modes;
- cache/state classes proven stageable and rewindable;
- supported request-feature matrix;
- exact MLX runtime (fork) revision used for qualification; and
- the provider revision and SPEC-023 `live_executable_cdhash` CodeDirectory
  identity of the signed provider executable that qualified the tuple, as
  recorded provenance that does not gate capability (0.1.27).

Capability construction MUST fail closed for a missing, extra, duplicate,
silently filtered, wrong-shape, wrong-dtype, unexpectedly quantized,
unmanifested, or digest-mismatched required tensor; an unsupported cache/state
class; a family-adapter mismatch; or a runtime revision outside the signed
evidence tuple. Model-name matching alone MUST NOT establish capability.

For the v0.1 `separate_artifact` Qwen 3.5 adapter, the signed `manifest`
artifact MUST be the exact regular file `config.json` directly inside the
captured MTP artifact directory. The digest MUST match the bytes parsed by the
capability observer and then consumed by the upstream loader. The signed
tokenizer artifact MUST likewise be the exact `tokenizer.json` directly inside
the captured target directory used by the target tokenizer loader. An
independent or merely descriptive manifest, tokenizer from another directory,
or path alias MUST fail closed.

The observer MUST accept exactly the configuration and tensor grammar the
pinned loader consumes and reject everything else. Quantization metadata is
read only from the top-level config `quantization` object
(`BaseConfiguration`); the `quantization_config` copy mlx-lm also writes is
never read, and a config carrying only that copy fails closed. `mode` is a
case-sensitive MLX `QuantizationMode` raw value; an absent `mode` is affine,
as in the loader, and `quant_method`, `quantization_mode`, and `linear_class`
carry no meaning. Global `bits` and `group_size` use exactly those keys. A
quantized module is the module whose `<path>.scales` tensor exists, with zero
points in `<path>.biases`; no other scale or bias spelling is read.

For MLX affine 4-bit artifacts, the observer MUST treat config
`"quantization": {"mode":"affine","bits":4,"group_size":G}` (or the same
object without `mode`) as `mlx_affine_4bit`, with `G` limited to `32`, `64`,
or `128`, and MUST record the per-tensor observed `bits_per_value` and
`group_size`. The observer MUST preserve per-module config overrides and
`false` unquantized config entries so SPEC-023's
`representation_manifest_sha256`, `per_layer_exceptions`, and
`unquantized_exceptions` can be recomputed from the observed target/MTP pair.
Override and `false` keys are matched only against the exact post-sanitize
module path the loader's quantize pass looks up: for qwen3_5 / qwen3_5_moe
targets, `model.language_model` becomes `language_model.model` and any other
key lacking `language_model.` gains that prefix; for standalone drafters,
every key not already under `mtp.` gains that prefix. A key the loader would
not apply (for example a bare drafter `fc` override, which the loader ignores
in favour of the global width) fails closed as unmatched, as does a `false`
entry that names no consumed floating module or names a module that has
packed weights. Overrides are admitted only for `4`, `5`, `6`, or `8` bits
(SPEC-023 v0.22.27; `4` or `8` before 0.1.36), group sizes `32`, `64`, or
`128`, and an absent or exactly `affine` mode. A packed override tensor's
last dimension times 32 MUST divide exactly by its width, and the quotient is
the module's logical input width. The observed
affine representation MUST match the signed SPEC-023 quantization object
exactly before native MTP is admitted. A SPEC-023 `base` admission likewise
requires both artifacts observed as unquantized bfloat16 with no overrides or
`false` entries and the signed digest recomputed from them; any other kind
the observer cannot recompute never admits.

MLX never quantizes rank-1 floating tensors or rank-3 `*.conv1d.weight`
tensors. The pinned Qwen35 loader discards every target key with the prefix
`vision_tower` or `model.visual`; the observer drops exactly the dotted
`vision_tower.*` / `model.visual.*` namespaces the same way and fails closed
on any other name that discard predicate would silently swallow (for example
`vision_tower_evil.weight`). A vision-language-origin target remains
admissible for v0.1 text-only serving under §8 when the signed target artifact
and processor contract prove no image-input buyer path is admitted. A rank-2
language-model weight without a scale pair still fails closed unless the
config explicitly declares that module unquantized. No tensor is excluded by
name (optimizer, moment, or otherwise): the loader keeps every remaining key
and verifies it against the model, so the observer inspects them all, and a
target key whose loader path is not under `language_model.model.` or
`language_model.lm_head.` fails closed.

For standalone drafter artifacts, the accepted tensor namespace is exactly
`fc|layers|norm|pre_fc_norm_embedding|pre_fc_norm_hidden`, optionally under an
`mtp.` prefix, matched case-sensitively, matching the pinned fork's
`qwenMTPSanitizeWeights` `standaloneCheckpoint` path. Qwen3.6 target configs with `model_type`
`qwen3_5` or `qwen3_5_moe` use the same `qwen3_5_mtp_v1` adapter and
`separate_artifact` layout with the matching
`mlx-community/Qwen3.6-*-MTP-4bit` drafter artifacts.

**GLM-5-Next embedded layout (0.1.35).** A target whose `config.json` has
top-level `model_type` `glm5_next`, `architectures` exactly
`["Glm5NextForConditionalGeneration"]`, `text_config.model_type`
`glm5_next_text`, and `text_config.num_nextn_predict_layers` exactly `1` uses
the `glm5_next_mtp_v1` adapter with `source_layout` `checkpoint_mtp`
(0.1.36: the catalog key is `zai-org/glm-5.3-flash`). The entry's adapter
string determines the layout: `glm5_next_mtp_v1` is `checkpoint_mtp` and every
other adapter keeps `separate_artifact`. Any other
`num_nextn_predict_layers`, or a `glm5_next` config naming another
architecture, fails closed. The Qwen rules above (prefix rewriting, the
`vision_tower` / `model.visual` discard, the standalone drafter namespace)
do not apply to this adapter; these do:

- *One artifact.* The next-N layer ships inside the target artifact. The
  signed `mtp` artifact is the captured target directory itself, with the
  same content-addressed path and snapshot-manifest SHA-256 as `target`; the
  signed `manifest` artifact is the exact regular file `config.json` directly
  inside that directory, and `tokenizer` is the exact `tokenizer.json` in it.
  No second copy of the next-N layer is captured, fetched, or loaded, and
  admitting native MTP leaves the target `artifact_hash` unchanged. A
  projection whose `mtp` path or digest differs from `target`'s fails closed.
- *Tensor grammar.* The MTP namespace is exactly `language_model.mtp.0.`
  (prediction layer 0). Every other consumed key is under
  `language_model.model.` or `language_model.lm_head.`. The observer fails
  closed on `language_model.mtp.<n>.` with `n != 0`; on a bare `mtp.` or
  `model.mtp.` key; on any `model.language_model.` key (an alternative layout
  the loader would merge into the same module paths); and on a DeepSeek-style
  next-N key `language_model.model.layers.<i>.` with
  `i >= text_config.num_hidden_layers`, which the loader would silently remap
  into `mtp.*` or drop, including its `shared_head.head.` and `embed_tokens.`
  keys.
- *Vision.* The pinned `GLM5NextWeights` loader drops keys beginning with
  `vision_model.`, `vision_tower.`, `visual.`, or `model.visual.`. The
  observer drops exactly those dotted namespaces and no others. The text-only
  boundary of §8 applies: no image-input buyer path is admitted.
- *Post-sanitize layout only (0.1.36).* The pinned `GLM5NextWeights.sanitize`
  rewrites raw Hugging Face names (`.hc_attn_` / `.hc_ffn_` renames, the
  forget-gate move under `forget_gate.`, per-projection `q_conv1d` /
  `k_conv1d` / `v_conv1d` concatenation, `.mlp.experts.<e>.` stacking into
  `.mlp.switch_mlp.`, the `kv_b_proj` split into `embed_q` and `unembed_out`,
  and router-gate dequantization when `.mlp.gate.scales` exists). The
  observer admits only a checkpoint already in the post-sanitize layout, on
  which that mapping is the identity, so tensor names, override keys, and
  `false` keys are the loader's module paths as written. Any tensor name the
  sanitizer would rewrite fails closed: one containing `.hc_attn_`,
  `.hc_ffn_`, `.mlp.experts.`, `.kv_b_proj.`, `.q_conv1d.`, `.k_conv1d.`,
  `.v_conv1d.`, `.mlp.gate.scales`, `.mlp.gate.biases`, or a forget-gate part
  (`A_log`, `dt_bias`, `f_a_proj`, `f_b_proj`) directly under `.self_attn.`.
  The admitted artifact is in this layout.
- *Floating parameters.* The loader quantizes a module only when its
  `<path>.scales` tensor exists. Besides rank-1 tensors and rank-3
  `conv1d.weight` kernels, the observer admits exactly these unpaired
  floating tensors, which the model holds as plain parameters or unquantized
  layers: `.attn_hc.fn`, `.ffn_hc.fn`, `.mlp.gate.weight`,
  `.indexer.index_kpool_compress_ape`, `.indexer.index_kpool_compress_gate`,
  and `language_model.mtp.0.eh_proj.weight`. Any other rank-2 floating weight
  without a scale pair fails closed unless the config declares it `false`.
- *Quantization.* Only the top-level `quantization` object is read; the
  artifact's `quantization_config` copy is ignored as for every adapter. The
  global width is affine 4-bit, group 32, 64, or 128, and per-module
  overrides follow the rule above (`4`, `5`, `6`, or `8` bits). Because target and MTP
  share one config, each override is recorded once, as `target/<module>`
  (`target/language_model.mtp.0.…` for next-N modules); no `mtp/` exception is
  emitted, and the representation manifest's `mtp` object is byte-equal to
  its `target` object.
- *Drafter.* The adapter proposes at most one token per round (drafter
  maximum block size 2: the last committed token plus one proposal, so
  `max_proposal_depth = 1`), shares the target's last sparse-attention top-k
  selection as the model config's `index_share_for_mtp_iteration` requires,
  and admits `request_feature_profile =
  "native_mtp_greedy_text_v1"` or `"native_mtp_sampled_text_v1"`. The sampled
  profile uses the existing R005 row/position-keyed target-sample exact-match
  verifier, following mlx-vlm `e9af376626b04ba0cdad23b1476fd7a4a583d721`
  (`_mtp_acceptance_walk`, positioned target sampling); it does not replace
  the ordinary sampler or relax seeded token parity. (0.1.43) A `glm5_next_mtp_v1` tuple signs
  `max_native_active_rows` 1, as the first Qwen3.6 tuple does: on the M3
  Ultra (provider native path, packed verification in continuous batching,
  depth 1, greedy, 256 tokens) one native row decoded at 1.27x ordinary
  (48.4 vs 38.2 tok/s, acceptance 0.889), while four native rows decoded at
  0.79x ordinary continuous batching (51.5 vs 65.6 tok/s, acceptance 0.870).
  (0.1.59) The adapter's implementation ceiling is four native active rows;
  the sidecar loader and generator accept only integer bounds from one through
  `min(4, qualified_slots)`. This capability is not qualification: the current
  signed deployment bound remains one. Publishing any larger bound requires
  a new frozen R015 policy and passing native-eligible evidence for every
  requested row count through that bound, including exact token/state parity,
  packed mixed-row verification and the existing throughput gates. Gated cells
  and source tests cannot raise the signed bound. Rows above the actual signed
  bound still take ordinary decode under the R007 load gate. R004, R012,
  R014, and R015 apply unchanged.
- *Provider load and admission (0.1.40).* The provider builds the drafter
  inside the loaded target: a parameterless model created from the target's
  `config.json` through the drafter type registry, which resolves the
  target's `mtp[0]` layer, embeddings, and lm_head at each call. It never
  loads the target's weight files a second time. The allowed (adapter,
  `source_layout`) pairs are exactly `(qwen3_5_mtp_v1, separate_artifact)` and
  `(glm5_next_mtp_v1, checkpoint_mtp)`. A `glm5_next_mtp_v1` capability is
  admitted only when all of these hold, else it fails closed with
  `admission_capability_unsupported` and the target serves ordinary decode:
  the loaded target carries its next-N weights; its runtime cache topology
  is exactly the SPEC-039 FR-PKV12 `glm5_next` topology (`MambaCache` on every
  `linear_attention` layer, `pagedMLA(kpool: index_kpool)` on every
  `deepseek_sparse_attention` layer); the SPEC-039 v0.1.19 8-token forward
  bound is in force; one row's verification (`max_proposal_depth + 1`
  tokens) fits inside it. Packed verification runs KDA rows through
  `MTPPackedMambaBatchCache` and `pagedMLA` rows through a paged equivalent of
  `GLM5NextLatentCacheBatch` that stages each row on a copy and commits
  exactly the first `1 + accepted` columns per row by exact trim (SPEC-039
  FR-PKV15); a dropped row keeps its pre-round state. Admission remains
  bound to the signed sidecar, R015, and the qualification evidence like
  every native tuple.

**Multi-model projection manifest (0.1.35).** When one admission sidecar
carries entries for more than one `model_key`, the release's single
`native-mtp-artifact-manifest.json` is
`{"schema_version":"macprovider.native-mtp-artifact-projection.v2","models":{"<model_key>":{"target":…,"mtp":…,"tokenizer":…,"manifest":…}}}`:
one closed artifact object per `model_key` the sidecar names, each with the v1
`{path, sha256}` members, and no other key. Every entry's
`artifact_manifest_sha256` is the SHA-256 of that one file, and a consumer
selects the object under the selected entry's `model_key`; a missing or extra
model key fails closed. A sidecar whose entries all share one `model_key` keeps
the v1 form (`macprovider.native-mtp-artifact-projection.v1`, one
`artifacts` object), so a single-model release is byte-identical to the
pre-0.1.35 output. Consumers MUST read both forms. A v1-only consumer rejects
the v2 form and stays ordinary for every model, so a release MUST NOT publish
the v2 form before the provider CLI that reads it is the released CLI.
The same ordering applies to a sidecar that carries a 5- or 6-bit override or
more than 256 exceptions (SPEC-023 v0.22.27): a CLI that predates 0.1.36
rejects the whole sidecar. R014 item 10 makes this a release gate.

The observer MUST inspect every `.safetensors` file that the R003-authorized
mlx-swift-lm loader can consume. At the R003 mlx-swift-lm revision
(`baec1724…`; `safetensorWeightURLs` is unchanged from `3.32.3-macprovider.6`)
the loader takes the files named by
`model.safetensors.index.json`, which may sit in subdirectories, else the
top-level conventional names, plus files the model declares as additional
weights; the observer inspects every `.safetensors` file under the snapshot
root recursively, a superset of that set. Each fork rebase MUST re-establish,
under the per-rebase acceptance gate, that every file the rebased loader can
consume is in the observer's set; a loader that can reach a file the observer
does not inspect blocks the rebase. The observer MUST reject symlinked or
hidden weight files, scan every parsed tensor name before representation filters, and reject
every target tensor the family sanitizer would silently discard, including any
target name containing the `mtp.` namespace when `source_layout` is
`separate_artifact`.

Artifact resolution and parsing MUST reject path traversal, symlink escape,
unexpected local or network references, malformed safetensors metadata,
integer overflow, declared-size/actual-size mismatch, decompression bombs, and
allocation requests above the predeclared loader bound before loading tensor
bytes. A separately stored MTP artifact MUST resolve inside the verified
snapshot or through a content-addressed SPEC-023 member; arbitrary URLs and
absolute paths are forbidden. Negative fixtures MUST prove each rejection and
that rejection cannot expand ordinary-decode trust.

Verification and MLX loading MUST consume one captured immutable byte source.
Resolution uses descriptor-relative no-follow opens under the verified snapshot
root and accepts only regular files with expected owner/mode, but direct MLX
loading from that model-store descriptor is forbidden: an open descriptor fixes
inode identity, not contents. The loader MUST either hash the exact immutable
memory buffer MLX consumes or copy through the descriptor into a private
same-volume staging file created exclusively below a `0700` directory, close
every write handle, remove write permission, then hash and load only that
staged inode. Lazy or mapped reads MUST retain the private staged inode until
model teardown. The loader compares device/inode/size/mtime before and after
copy, hash, and load and rejects hardlink escape, symlink/path swap, rename
replacement, truncation, same-size rewrite, timestamp restoration, or mutation;
reopening an already validated model-store pathname is forbidden. Race fixtures
MUST attempt each swap and in-place mutation between validation, hash, and load.

Diagnostics MUST NOT expose raw local paths, model-private tensor values,
credentials, or unbounded tensor-name lists.

### MTP-3 — qualified upstream transaction interface (SPEC-048-R003)

Production implementation MUST resolve the exact, immutable dependency tuple
authorized below, never a floating branch, a version range, or a movable
reference. A compile-tested qualification artifact MUST exercise
stable operations for proposal, target verification, stage, contiguous-prefix
commit, rejected-tail discard, and exact rewind with explicit row and position
maps. The production adapter MUST use only interfaces covered by that artifact.
A high-level serial iterator alone is insufficient evidence.

The qualification MUST include the fork's MTP and cache tests, Swift strict
concurrency diagnostics, supported macOS deployment target, dependency/license
review, and cache-boundary rejection tests.

**Fork model.** MacProvider's production MLX runtime is three operator-owned
forks under `Augustas11`: mlx-swift-lm, mlx-swift, and MLX core. They are the
permanent production runtime, not a temporary exception awaiting an upstream
release. MacProvider does not contribute these patches upstream and does not
wait for upstream to carry them. Each upstream release MacProvider adopts is
taken by rebasing every fork's patch stack onto the new upstream tag, cutting
new fork tags, and passing the per-rebase acceptance gate in
`docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md`. A fork tag is immutable once
pinned: a change is a new tag and a new SPEC revision naming it, never a moved
tag.

The authorized dependency tuple is exact:

| Repository | Fork tag | Revision | Upstream base |
|---|---|---|---|
| `https://github.com/Augustas11/mlx-swift-lm.git` | `3.32.3-macprovider.13` | `5ee4333a8c052d9d0afc58db66b8976ea5fa398e` | `ml-explore/mlx-swift-lm` `3.32.3` (`3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`) |
| `https://github.com/Augustas11/mlx-swift` | `0.32.3-macprovider.11` | `c774cb0934c7503bc3fe1c3d1afbe44c728e8891` | `ml-explore/mlx-swift` `0.32.3` (`19601207e9a0de51e03ee6ec0c3c5f3784275075`) |
| `https://github.com/Augustas11/mlx` | `v0.32.4-macprovider.6` | `51edbb37620aef7c860ab5d7cdb7bf5b14333da2` | `ml-explore/mlx` `v0.32.4` (`36969c094354086e15d2a327a9c50feb20b9cf11`) |
| `https://github.com/Augustas11/mlx-c` | `v0.6.0-macprovider.2` | `2b1ff2b5b5129a6115771da32e1bac3b6b01ab01` | `ml-explore/mlx-c` pinned base (`ebc88f10caa1b625e6b581437a8dea6df8a70085`) |

`3.32.3-macprovider.13` is one commit on `3.32.3-macprovider.12`
(`f75f92b0e85958a3219d295e1906a1a0889e6702`): GPT-OSS attention passes its
per-head sinks to a cache that conforms to `KVCacheSinkAttentionProtocol`,
so a batched cache attends rows at different key offsets each over its own
keys (SPEC-038 FR-CB2) instead of the model calling SDPA over the padded
batch. Caches that do not conform, and every other model, keep the previous
path.

`3.32.3-macprovider.12` added LFM2 MoE reference-prefill arithmetic to the previously pinned
mlx-swift-lm `3.32.3-macprovider.10.15.1`
(`36d24585f9373c2661f61f5e5b485c8d66c43a2b`). The LM change opts only
LFM2 MoE model-owned linear projections into the reference route. The Swift
and C layers carry an explicit default-false setting; the existing C entry
point retains its ABI and default behavior. Core selects vendor prefill
arithmetic using each row's sequence length while covering all flattened
rows. Single-token decode and projections without the opt-in retain the
previous batch-invariant route. The Swift fork pins both the core and C
forks by full submodule revision; mlx-c's standalone core fetch uses the same
core revision. The existing nine-argument Python binding calls the C++
primitive with the opt-in false, preserving its route and public arity.
This is a bounded arithmetic correction, not an upstream rebase.

The LFM correction requires ordinary-serving exact token parity against the
reference and cached-turn/shared-row acceptance. It does not qualify an LFM
native-MTP tuple or expand Qwen/GLM qualification scope. Existing LFM evidence
establishes 256-token exactness at 1k/8k/32k prompts, row isolation and a
four-row scheduler gain of 26.43%. These are ordinary-serving observations,
not signed production admission. GLM/Qwen exact-output engine-matrix checks
remain required on the designated Studio.

For previously qualified Qwen/GLM MTP tuples, MTP-13 governs reuse when review
establishes that their draft/verify/commit behavior, artifacts, request profile,
hardware and serving bounds are unchanged. A dependency identity change alone
MUST NOT relabel historical results as measurements of this tuple. Original
measurement source, runtime identity and benchmark-policy `provider_commit`
remain unchanged; a changed signed runtime/digest binding requires a separate
authenticated identity-only reuse record under MTP-13. Immutable tags MUST
exist and resolve to the exact row revisions before a production build.

The parent is the immutable combined fork tag `3.32.3-macprovider.10.15`
(commit `3905a1b0499f0f38c0f94a008034a0362b9e3dca`, branch `campaign/2144-native-mtp`). It preserves
both the GLM candidate `3.32.3-macprovider.10.13` (`b128c37f…`) and the Prism
loader `3.32.3-macprovider.10.14` (`9b2766ee…`), each based on
`3.32.3-macprovider.10.5` (`c8be0f61…`). Following oMLX packed same-depth
verification, it shares GLM indexer projections only through the existing
vector-stable kernel when that kernel covers the shape. Normalization, attention,
unsupported projections and cache rollback remain row-local. This accommodation
is required because MLX fallback attention can change its numerical reduction
route when its batch shape changes. Single-row and ordinary decode retain their
routes. The eight-flattened-token exactness bound remains intact.
The campaign tested the existing `GLM5NextMTPDraftModel.chainPacked` head
at depth two following SGLang `ad950cd` positive-depth tuning. All four two-row
profiles preserved exact parity but reached only 0.795–0.860× ordinary CB.
The product adapter was removed: GLM retains its registered depth-one drafter
and seed-only proposal path. Neither tested multi-row design meets the goal
throughput floor, so the native active-row bound remains one. Tag `.10.13`
retains copied-chain regressions for accepted-prefix lengths zero, one and two;
those tests do not grant deeper serving admission.
The `.10.13` GLM candidate's changed verifier requires fresh GLM token/state
parity and R015 qualification before admission; a fork tag is not qualification
evidence. MTP-13 governs any source-equivalence identity-only rebind from the
measured candidate to the combined tag.
The Prism additions are the schema-2 signed-Hadamard VLM loader, owned
full-artifact snapshots, lazy vision loading and row-safe attention masks.
The `.10.14` source tree is identical to the parity-qualified `bd5f45f1…`
baseline. Custom Hadamard and convolution experiments without established
end-to-end throughput gains are excluded. These additions do not admit a catalog
model, change a signed batching/MTP policy, or claim 8 GB or vendor quality
qualification.

`3.32.3-macprovider.10.5` consists of `3.32.3-macprovider.10.4` (`676a62a4…`) plus batched DeepSeek-V4 attention,
compressor/indexer projections and per-row rotary offsets, keys-only windows
and geometric pool storage (0.1.55, Related: #2111). The prior tag adds
row-owned continuous batching to the serial DeepSeek-V4 port on the epic
#2029 tag `3.32.3-macprovider.10.1` (`87dc5159…`, `glm53/tuple-0324`).
`phase3-binary/Package.resolved` resolves the new revision exactly.
`3.32.3-macprovider.10.2` remains an unrelated GLM candidate outside the tuple.
A production build MUST NOT resolve an untagged mlx-swift-lm revision;
`scripts/check-upstream-throughput-blockers.sh` verifies that the row's tag
resolves to the row's revision on the fork.

Each link pins the next by full revision: `phase3-binary/Package.swift` pins
the mlx-swift-lm fork, that fork's manifest pins the mlx-swift fork, and the
mlx-swift fork's `Source/Cmlx/mlx` submodule commit pins the MLX core fork.
The `Source/Cmlx/mlx-c` submodule stays at upstream mlx-swift `0.32.3`'s
commit. `phase3-binary/Package.resolved` MUST resolve the mlx-swift-lm and
mlx-swift revisions above, and `scripts/read_swiftpm_pins.py` fails closed
when the resolved mlx-swift-lm revision differs from
`SPEC048_MLX_SWIFT_LM_REVISION`. The KV cold-tier build identity
(`KVBuildIdentity.mlxSwiftLMRevision`) and the native-MTP bench's runtime
revision bind to the same mlx-swift-lm revision.

Authorized surface:

- mlx-swift-lm fork: `MTPKVCacheStorage`, `MTPKVCacheTransaction`,
  `MTPKVCacheTransactionPosition`, `MTPKVCacheTransactionCommit`, and
  `reconcileMTPSharedKVState`; `MTPPackedVerificationCache`,
  `MTPPackedVerificationRowMap`, `MTPPackedVerificationRowState`,
  `MTPPackedVerificationOutput`, `MTPPackedVerificationError`, and
  `verifyMTPPackedTargets`, including the strict `requireContinuationState`
  overload for row-local multi-round continuation;
  `MTPDrafterContainer.perform(nonSendable:_:)` for serialized movement of
  caller-owned drafter state without model-global mutation or unsafe
  `Sendable` capture; standalone Qwen 3.5 MTP checkpoint normalization,
  `MTPPackedMambaBatchCache`, `MTPPackedMambaRowTransaction` (including the
  deferred-evaluation `stageCommit(retaining:)`), and the
  `mtpPackedCheckpointIndex` contract for row-isolated commit across hybrid
  attention/Mamba verification; the `mtpPackedHostBatchOffsets` host offset
  mirror the packed facade validates instead of reading `batchOffset` back
  from the device; `MTPPackedStatefulDrafterModel`,
  `MTPPackedDrafterAdvanceRow`, `MTPPackedDrafterAdvanceResult`,
  `MTPPackedDrafterError`, and the Qwen 3.5 `advanceAndProposePacked`
  implementation; the Qwen3.5/3.6 sparse-MoE fused small-token path
  (`MLX_LM_QWEN35_FUSED_MOE`), eligible only for the exact stock module types
  (`SwitchGLU`, `QuantizedSwitchLinear`, `QuantizedLinear`; any subclass such
  as a rotation or adapter keeps the stock path) with the exact affine
  quantization layout and exact dtype/shape of every packed weight, scale, and
  bias the kernels index, with per-call scratch, overlapping-call safety,
  chunked evaluation above seven flattened tokens, and stock fallback for rows
  longer than seven tokens; `gatedDeltaUpdateCheckpointed`, bit-identical to
  two split `gatedDeltaUpdate` calls; packed verification leaving recurrent
  caches unprepared when no row is right-padded; the compiled Qwen 3.5 MTP
  verification step (kill switch `MLX_LM_QWEN35_COMPILED_VERIFY`),
  bit-identical to the general path; and compile state declared for every
  Qwen 3.5 trace, including the fused GDN input projection (upstream #631,
  cherry-picked), so no trace reads a model array as a tape constant.
- mlx-swift-lm fork, DeepSeek-V4 continuous batching (0.1.55, Related: #2111):
  `DeepseekV4Model.decodeBatch(_:rowCaches:)` accepts one token for each of
  1...8 independently prefetched rows. Embedding, hyper-connections, attention
  projections, output projections and MoE share a batched forward. On CPU,
  the small hyper-connection mixes use row-local arithmetic to preserve exact
  serial rounding; GPU keeps its fused row-independent path. Attention uses
  each row's own window offset, compression pools and indexer. Compressor and
  indexer projections run once over all rows; ragged histories are masked to
  the longest row. Homogeneous dense or sparse rows use one batched attention
  body. Mixed dense/sparse rows use two batched bodies to preserve serial
  sparse normalization and exact tokens. Windows retain keys only; pools grow
  geometrically and update row-owned slices. Rows may
  join, leave and reorder without transferring cache identity. Per-row
  `prepare` retains 2048-token chunks and a final one-token forward. The
  incomplete multi-token `DeepseekV4PoolCache.accumulateWindows` continuation
  copies only newly appended tokens after its retained prefix. These caches
  are not paged K/V and do not add a native-MTP adapter or admission. The
  provider's signed CB policy remains deployment state, with exact token
  parity and measured campaign gain required before activation.
- mlx-swift fork: the core submodule moved to the MLX core fork, and the
  compiled-function erase documented for the per-thread cache. No API change.
- mlx-swift-lm fork, GLM-5-Next (0.1.35, epic #2029; batched rows 0.1.37;
  MTP-1 target and drafter 0.1.38; #622 trim gating 0.1.39):
  the `glm5_next` / `glm5_next_text` model (`GLM5Next.swift`,
  `GLM5NextWeights` sanitizer), its `GLM5NextAttentionCache` (MLA latent plus
  pooled indexer keys, with exact `trim` of up to `maxTrim` tokens), the
  `GLM5NextLatentCache` / `GLM5NextBatchedLatentCache` protocols and
  `GLM5NextLatentCacheBatch` (batched rows: projections run on every row
  together and each row attends against its own latent cache, bitwise equal
  to its serial decode for qualified fused shapes while a forward carries
  at most 8 flattened tokens). This bound is not qualification for arbitrary
  fallback shapes; every served artifact still requires R005/R015 parity.
  the fused decode kernels for rows of up to 8 tokens (`GLM5NextDecodeKernels.swift`: KDA step,
  hyper-connection decode, MoE routing and expert kernels, DSA token selection,
  multi-qmv projections with explicit thread layout), the per-channel gated
  delta update, and the two-input `SwitchGLU` activation. The T3 parity
  evidence (`docs/evidence/glm53-flash-t3-parity-2026-10-16/`) covers the
  ordinary path. From 0.1.38 the fork also carries the MTP-1 target side and
  drafter: a verification forward (`mtpCacheCheckpointIndexKey`) runs every
  column as a one-token decode step, so each verified column's logits equal
  the serial decode of that token; a rejected proposal rewinds in place (sparse
  layers trim exactly, KDA restores the checkpoint the verify pass saved;
  `SpeculativeCacheRewindModel` depth 1); the emit flag returns the
  pre-final-norm hidden state and the last sparse layer's latent
  (`GLM5NextLatentCache.validLatent`); and `GLM5NextMTPDraftModel`
  (`GLM5NextMTP.swift`, parameterless, block size 2, greedy only, one
  `GLM5NextAttentionCache` of `maxTrim` 1, packed advance over right-padded
  rows) with `GLM5NextMTPRegistration`. From 0.1.39 the latent cache reports
  its exact rewind depth as `maxTrimCount`, so the upstream #622 per-layer
  gate (`canTrimPromptCache(_:numTokens:)`) never asks it for an inexact
  trim. From 0.1.40 it verifies packed GLM-5-Next rows inside continuous
  batching: `GLM5NextLatentCacheBatch` is an `MTPPackedVerificationCache`
  that writes only working copies of its rows and returns one
  `GLM5NextLatentRowTransaction` per row (`commit(retaining:)` keeps the
  first `retaining` columns by exact trim; an uncommitted row is unchanged);
  a right-padded column attends nothing and writes no latent, and a KDA layer
  keeps a padded column's recurrent and convolution state. From 0.1.41 a
  2...8-token GLM-5-Next forward routes its affine projections through
  `glm5NextQMVBatch` (each threadgroup reads its weight rows once for every
  vector; each output bitwise equal to MLX's one-vector quantized matmul at
  4/5/6/8 bits), and an MTP verify runs every column of every row in one KDA
  dispatch (`glm5NextKDAVerifyStep`, state written after the checkpoint
  column, each row stopped at its valid token count). From 0.1.42 the fork
  drafts and verifies GLM-5-Next MTP up to depth D (at most 7) with in-place
  rollback: a depth-D verify saves the KDA state after each kept prefix
  (`MambaCache.saveSpeculativePrefixes`, `restoreSpeculativeCheckpoint(rewinding:)`;
  the single-checkpoint depth-1 path is unchanged), sparse layers trim
  exactly, and `GLM5NextMTPDraftModel` caps its drafts at `maximumDepth`
  (default 1), so the iterator and continuous-batching serving run depth 1;
  deeper only when a caller asks. The shared `MTPSpeculativeTokenIterator`
  takes an optional `MTPAdaptiveDepth` controller (nil keeps the fixed
  depth) that times each depth's measured rounds after a warm-up, picks the
  depth with the best measured tokens per second, re-measures the least
  recently measured depth every probe interval, and parks only against a
  caller-measured plain step; the provider's native-MTP path does not use it.
  MLXVLM's Qwen2-VL vision tower attends within each image (and each video
  frame group) instead of across all of a request's images (#2035).
  The provider's `glm5_next_mtp_v1`
  serving surface (next-N state transactions over KDA and `pagedMLA` state in
  the paged backend, and the native-MTP capability gate) is not part of this
  row; it joins only through a later revision.
- MLX core fork: small-M quantized matmuls route batch-invariantly (`qmv`
  below the vector limit, `qmm` without split-K at or above it, no
  `qmv_wide`), so a continuously batched row matches its serial result; the
  routing exceptions that remain are bounded in the runbook. A freed compiled
  function is erased from every thread's compile cache, so a later function
  allocated at the same address never replays a dead trace. Every internal
  call inside a stream-taking op passes the caller's stream, and primitive
  vjp/jvp rules use the primitive's stream (#2028, carried onto v0.32.4 in
  `v0.32.4-macprovider.4`; `scripts/check_mlx_core_streams.py` enforces it).

Review gate for a tuple: the fork tests for every touched surface; the
per-rebase acceptance gate in `docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md`
(startup batched-isolation probes with the fused MoE path on and off,
continuous-batching enable-gate rows, cross-thread model reload with zero
stale trace replays, fused-layout eligibility and fallback, and compile-state
ownership); native-MTP R015 only when a named decode-path line changed how
the qualified tuple drafts, verifies, or commits tokens since the last R015
evidence (MTP-13 identity-only rebind rule); and a three-lane freeze audit
with zero Critical, High, or Medium findings. Native-MTP R015 gates signing and activation of a native
tuple (R007, R015), never the ordinary path.

Review record for the #2028 tuple (2026-10-16; mlx-swift-lm
`3.32.3-macprovider.9` / mlx-swift `0.32.3-macprovider.8` / MLX core
`v0.32.2-macprovider.5`): the stream-propagation fix with a three-lane freeze
audit at 0 Critical, 0 High, 0 Medium (`audits/2026-10-16-2028-gptoss-decode/`).
The campaign mlx-swift-lm tag `3.32.3-macprovider.10.3` (`baec1724…`) is
`3.32.3-macprovider.10.1` (`87dc5159…`) plus the DeepSeek-V4 commits described
in the 0.1.52 changelog entry; `3.32.3-macprovider.10.1` sits on
`3.32.3-macprovider.10` (`b4077dcb…`): that tuple's `dbe8bcb3…`, the MLX
core v0.32.4 pin (`da234b2`), and the upstream #622 fix (exact prefix rewinds
in `RotatingKVCache`, `KVCache.maxTrimCount` gating each layer's rewind). Above
that it adds the GLM-5-Next files and model and drafter registration, and one
shared change: `MTPSpeculativeTokenIterator` reads a greedy round's drafts and
verify tokens in one host sync (same tokens and state; other samplers keep the
per-column path), and from 0.1.42 depth-D rollback in `MambaCache` (a
depth-1 rewind still restores the single checkpoint), the optional
`MTPAdaptiveDepth` controller in that iterator, and the Qwen2-VL per-image
vision attention fix (#2035). The provider's native-MTP path uses neither
that iterator nor the controller. The tag's last commit over the revision
the T4 evidence in `docs/evidence/glm53-flash-t4-2026-10-17/` ran on only
validates the GLM-5-Next configuration at load (indexer sizes,
per-layer types, routed-expert counts) and changes no decode-path line.

Review record for the earlier tuple (2026-10-10, `@Augustas11`;
mlx-swift-lm `3.32.3-macprovider.6` / mlx-swift `0.32.3-macprovider.2` / MLX
core `v0.32.2-macprovider.2`): Mac Studio startup batched-isolation probes
pass with the fused MoE path on and off, continuous batching attaches, and
native-MTP R015 passed on the compile-state fix
(`docs/research/mlx-swift-lm-3.32.3/`). `3.32.3-macprovider.6` changed no
decode math relative to the R015 build's mlx-swift-lm fork (fused-MoE
eligibility restricted to exact stock types, tests, and the manifest tools
version), so R015 was not rerun. The freeze audit and its fixes are in
`audits/2026-10-10-mlx-swift-lm-332/`.

Review record for this tuple (mlx-swift-lm `3.32.3-macprovider.10.3`):
**PENDING** (epic #2029). Two items remain: the
`JOURNEY-NATIVE-MTP-SERVING` run on the final tagged tuple and the GLM R015
record. The record then names the per-rebase acceptance gate results on the
MLX core `v0.32.4` rebase (startup batched-isolation probes with fused MoE on
and off, continuous-batching attach, cross-thread reload, fused-layout
eligibility, compile-state ownership) and the campaign freeze audit. It also records whether the MLX
core `v0.32.4` rebase changed a Qwen decode-path line, and so whether the
existing Qwen native-MTP R015 reruns under the rule above. The mlx-swift-lm
GLM-5-Next delta is new files, pure additions to `GatedDelta.swift` and
`SwitchLayers.swift`, and model registration.

Earlier tuples, the 3.31.4-based fork revisions up to `ca8c384c…`, and their
review records are in the changelog and are superseded by this tuple. No
other fork URL, revision, API, or transitive source substitution is
authorized. This authorization qualifies dependency boundaries only. It does
not make a model/artifact tuple eligible, satisfy the serial or multi-row
parity gates, admit MXFP8, or enable production serving.

### MTP-4 — v0.1 request eligibility and fallback boundary (SPEC-048-R004)

**v0.1.53 (Related: #2107):** A request with an active tool-call or structured
output grammar mask MUST use ordinary serial or continuous-batching decode.
Native MTP MUST be disabled for that row before draft/verify begins: draft
proposals and acceptance currently do not preserve the target sampler's
request-local grammar state. Unconstrained rows retain existing eligibility.
This exclusion is not a throughput qualification or a live policy change.

Native MTP v0.1 accepts only the chat-completions request profile below. Values
are tested after ordinary request parsing/default resolution (an absent
`temperature` resolves to the ordinary default `1.0` and is therefore a
sampled request). Sampling is eligible in one of two forms. A greedy row has
`temperature == 0` and `top_p == 1`; every admitted tuple accepts it. A
sampled row has any other `temperature`/`top_p` pair that the ordinary
continuous-batching row sampler supports (`0 <= temperature <= 2`,
`0 <= top_p <= 1`, finite); it is eligible only when the selected signed
SPEC-023-R024 entry carries `request_feature_profile =
"native_mtp_sampled_text_v1"`, and on a `native_mtp_greedy_text_v1` tuple it
selects ordinary with reason `sampling`. The remaining generation-affecting
allowlist is: absent/default `top_k`, absent/zero `min_p`, zero frequency and
presence penalties, absent/default-one repetition penalty, `n == 1`, no logit
bias, no `logprobs` or `top_logprobs`, plain-text response format, no Harmony
protocol, and text-only messages. For `glm5_next_mtp_v1`, only the signed
`native_mtp_sampled_text_v1` profile also admits ordinary-parser-supported
`reasoning_effort`, tool definitions, tool-call history (including assistant
reasoning content), and unconstrained `tool_choice`
`auto`/`none`. Omitted or true `parallel_tool_calls` is supported. Explicit false
remains ordinary: the native transaction currently finalizes before the
serial-tool output observer detects the first complete call. Required/named
tools and any active grammar mask remain ordinary. The GLM greedy profile keeps
its prior plain-text scope, including its no-tools/history/reasoning boundary,
until a signed sampled profile is selected; a new binary alone does not widen
that profile. Other adapters retain their no-tools/history/reasoning boundary.
Unknown chat-template kwargs remain ordinary. GLM uses the same rendered prompt,
row-position target sampler and
ordinary output parser as non-native decode, following oMLX
`78fa08bc1aef7290c93c83bb70811547763ebf33` (rendered-prefix processing and
first-stop handling). Tool/reasoning markers themselves do not disable drafting;
only the target-verified prefix is emitted, with ordinary token stop handling.
No mutable grammar processor is advanced by discarded drafts. The allowed transport or
limit keys are `model`, `messages`, `max_tokens`, `max_completion_tokens`,
`stream`, `stream_options` containing only `include_usage`, `stop`, and `user`;
they retain ordinary validation. A `seed` is eligible only where the ordinary
path treats it as a documented no-op (the continuous-batching row sampler
seeds from the scheduler request identity, not the buyer `seed`). Legacy completions, `echo`,
`suffix`, an unknown top-level key, or any generation-affecting key/value not
explicitly admitted above routes ordinary. A nonempty `conversation_key` also
routes ordinary unless the coordinator marked it cache-only (SPEC-004 v0.3.6
`conversation_cache_only`); a cache-only key is resolved by R009. Prompt length is bounded only by the selected SPEC-023-R024
entry's signed `max_prompt_tokens`; a longer prompt selects ordinary with
reason `capability_mismatch`. A prompt longer than one prefill chunk is
prefilled in chunks with per-chunk drafter seeding (MTP-6), and the prefill
chunk size is not an eligibility bound. The request additionally requires an admitted
capability, a supported cache/state class, and enough capacity for the next
complete verification round. Streaming and non-streaming are eligible only
after their respective acceptance fixtures pass.

The provider MUST make decode-path selection before output and record exactly
one closed selector reason. `eligible` selects `native_mtp` only after every
request, tuple, sidecar, revocation, state, capacity, and load gate passes; each
other reason selects ordinary:
`eligible|mode_off|classic_draft_configured|sampling|multiple_completions|tools|
structured_output|logprobs|logit_controls|reasoning_or_template|unknown_request_field|
conversation_key|multimodal|unsupported_processor|unsupported_state_cache|
insufficient_verification_capacity|capacity_above_native_bound|capability_mismatch|
tuple_not_admitted|tuple_revoked|revocation_state_unavailable`.
`capacity_above_native_bound` is the R007 load gate: an otherwise eligible
request selects ordinary when the served runtime already holds at least
`max_native_active_rows` other in-flight requests.
Reason strings are local diagnostics, at most 48 ASCII bytes, and do not enter
buyer, receipt, or coordinator wire surfaces.

Current gateway reality is explicit: the authenticated paid gateway assigns an
auto-prefix conversation key to ordinary user-message traffic. Through 0.1.25
that made most paid traffic ineligible; from 0.1.26 such a key arrives marked
cache-only and R009 lets a cache miss run native without changing its cache
outcome. R015 MUST measure eligibility from post-gateway provider-bound
requests with their real key state and marker; a synthetic keyless corpus
cannot satisfy the production-eligibility floor. This spec does not discard
that key or forgo its possible SPEC-024 discount to inflate MTP coverage.

A recoverable native-MTP failure MAY fall back once before buyer-visible
output only after restoring exact pre-request state and proving that no SSE
frame, response bytes, receipt state, usage state, request-log terminal state,
or cache state escaped. After buyer-visible output, the provider MUST terminate
through the existing inference-error path without retry, reconstruction, or
stitching.

The practical fallback window ends before the first native proposal or target
state mutation, which is earlier than buyer visibility and applies equally to
streaming and non-streaming. Capacity and capability failures expected to
trigger ordinary fallback resolve before that point; later proposal failures
use in-path depth reduction or request-local failure and MUST NOT be repaired
by an ordinary retry.

### MTP-5 — authoritative verification and token semantics (SPEC-048-R005)

The target model is authoritative. For each row and round, the implementation
MUST accept only the longest contiguous verified proposal prefix; no proposal
after the first rejected position may be emitted or committed. The algorithm
MAY add at most one target-selected bonus token under one documented convention
bound to the qualified runtime revision.

For a sampled row the target-selected token at verification position `i` is
the draw the row's own ordinary sampler makes at sampler step `s + i` from the
target logits at that position, where `s` is the row's committed generated
token count. The ordinary continuous-batching row sampler is a pure function
of the request seed, the step, the sampling parameters, and the row logits
(no carried RNG state), so a draw at a position after the first mismatch is
discarded without affecting any later draw. A proposal is accepted iff it
equals the target-selected token at its position; at the first mismatch that
token is emitted, and after a fully accepted prefix the bonus position's
draw is emitted. Greedy rows are the same rule with the argmax as the draw.
Probabilistic `min(1, p/q)` acceptance is not used: it preserves the output
distribution but not seeded token identity. The drafter stays greedy; it only
proposes and never selects an emitted token.

For the serial deterministic acceptance corpus, native MTP MUST produce the
exact token-ID sequence, ordering, decoded bytes, completion-token count, and
terminal reason produced by isolated ordinary decode with the same sampling
parameters and request seed on the same model snapshot and request (greedy
decode for a greedy row). The preregistered corpus MUST contain at least 200
prompts, at least 20 per short/1.5k/4k/8k/near-boundary stratum, and at least
6,400 compared generated positions, including all/none/partial acceptance,
stop/EOS/max-token terminals, and deliberately near-tied logits. No prompt is
excluded by observed margin: any token-ID divergence is a hard tuple failure.

The numerical oracle for both serial and multi-row tests is teacher-forced:
for every emitted prefix, run that row's ordinary path on the same served
snapshot and prefix, cast both target-logit vectors to float32, and compare the
next-token result before advancing. Top-1 token ID MUST be exact; for a
sampled row the seeded draw at that step MUST also be exact. Maximum
absolute target-logit difference MUST be `<= 0.05`, and the ordinary top-1
versus runner-up gap is recorded for every position. On any token divergence,
comparison stops for that row, the tuple fails, and later positions are not
claimed. Multi-row evidence additionally runs the same emitted prefixes in
the qualified ordinary SPEC-038 batch to detect cross-row state, but it does
not reuse FR-CB6's load-time runner-up allowance. A token equal to another
row's argmax is cross-row corruption, not tolerated numerical drift.

Proposed, verified, rejected, and discarded tokens are internal work. Only
tokens that the ordinary-decode oracle would emit count as committed or buyer
usage tokens.

### MTP-6 — row-local transactional state (SPEC-048-R006)

Every native-MTP round MUST begin from a row-local pre-round checkpoint and
stage all target KV, MTP state, offsets, and recurrent/hybrid state until the
accepted prefix and terminal boundary are known. If the verification inputs are
`[last_committed, p1...pN]`, the staged target positions correspond only to
`p1...pN`; `commit(k)`, `0 <= k <= N`, retains exactly the first `k` accepted
proposal positions. A target-selected bonus token may be emitted after that
prefix, but its target KV/state is not falsely committed from the verification
window: it becomes `last_committed` and is materialized by the next target
step, or by an explicit qualified bonus-state operation. Terminal truncation
before that operation emits no bonus. Every rejected or terminally truncated
position MUST be discarded or rewound to exact oracle state.

MTP auxiliary state is compared against deterministic recomputation from the
same committed prefix using the qualified MTP adapter; ordinary decode is the
target-KV/logit oracle, not an oracle for a head it does not execute. The state
digest specifies component order, dtype, shape, logical length, and canonical
byte encoding. The target-oracle state is what a later forward reads plus
the rewind headroom every committed round keeps. For a `glm5_next` paged MLA
layer that is the latent to `offset`, the pooled indexer keys, the partial pool
window's raw keys and gates, and the last `maxTrim - kpool` folded raw keys and
gates: an exact rewind of rejected proposals keeps a shorter suffix of the same
folded keys than one-token decode keeps (15 of 19 at `kpool` 4 after a reject
that undoes a pool window), no forward reads them, and the next completed pool
window refills them. Recurrent (KDA/GDN) and KV state compare whole. The lab
oracle compares this digest at the ordinary decode-window ends that a native
round lands on, and every such comparison MUST match. The bridge numbers each
row's committing finalize rounds 0, 1, 2, ... and every after-finalize record
carries its round number; the records MUST carry exactly that sequence, with
strictly increasing token counts, or the comparison fails (a missing,
duplicated, reordered or unnumbered record). At least one compared round MUST
immediately follow a rejected round of the same row: round `n - 1` proposed at
least one token and committed fewer than it proposed, so round `n`'s
verification ran on rolled-back state. A rejected round's own record does not
count. Depth-zero rows retain only committed target state; when depth
increases, proposal state is recomputed from the current committed target
hidden state rather than reused from a stale speculative tail.

Proposal state for the prompt is seeded during prefill, one chunk at a time.
For prompt chunk `[c, c+n)` the target emits hidden states `c ..< c+n` and the
MTP adapter advances the row's proposal state over `embed(prompt[c+1 ..< c+n+1])`
paired with those hidden states at position `c`. For a non-final chunk the
tail token `prompt[c+n]` is the next prompt token; only the final chunk uses
the sampled first token as its tail and yields the row's first proposal. A
prompt that fits one chunk is the single-pass case of the same rule. A
non-initial chunk MUST find the previous chunk's proposal state at exactly
position `c`, or the row fails before output; no chunk is replayed to
synthesize hidden states.

A row held at depth zero by the MTP-7 load gate does not run a one-column
native verification. It shares the ordinary lockstep decode forward, and the
provider keeps, in order, each token that forward commits for the row with the
target hidden state that produced it. These are exactly the columns per-round
depth-zero finalizes would have fed the MTP adapter. Only before the row's
next native proposal do they advance its proposal state, in one packed step,
so a restored row proposes from the same committed prefix as one that was
never gated. A held row MUST NOT advance its proposal state inside the shared
ordinary rounds, except at the column cap: a row held until it finishes within
1024 committed columns adds no MTP-adapter forward to them. A held row MUST
NOT buffer more than 1024 columns; one whose next ordinary window would pass
the cap advances its proposal state first, in one packed step, so a long held
completion pays one catch-up per 1024 tokens and its buffer stays bounded.
Each buffered hidden state MUST own its storage rather than view the shared
batch output, which would keep every row's state of that round alive. The
emitted tokens are ordinary decode's by construction.

Transactions MUST preserve row identity across proposal, packed verification,
commit, discard, cancellation, and release. State or metrics from one row MUST
NOT be addressable through another row's handles. Rejection at every proposal
position and every boundary of an admitted cache/hybrid state class MUST pass
exact subsequent-token and state parity tests. For `glm5_next_mtp_v1` those
boundaries include KDA recurrent and short-convolution state, `pagedMLA`
latent block edges, and `index_kpool` pool-window edges (SPEC-039 FR-PKV15),
plus the next-N layer's own sparse-attention state. `RotatingKVCache`, sliding-window
attention, or another SPEC-039-nonallowlisted cache remains ordinary-only; this
spec does not turn its boundary test into paged/native-MTP admission.

If exact rewind cannot be proven for any layer/cache class, that capability is
unsupported and the request routes to ordinary decode before output.

### MTP-7 — multi-row scheduling, capacity, and fairness (SPEC-048-R007)

Production native MTP MUST integrate through SPEC-038 scheduling and SPEC-039
paged-KV primitives; it MUST NOT serialize the provider around the serial MTP
iterator. One scheduler round MAY contain ordinary and native-MTP rows, with
different row offsets, proposal depths, accepted-prefix lengths, and terminal
outcomes. Packing and unpacking MUST use explicit row/position maps and MUST
NOT assume lockstep offsets or equal spans.

Admission MUST reserve the initial footprint required by SPEC-038 plus one
complete native-MTP verification window for every admitted native row: target
and MTP state, paged/hybrid checkpoints, workspace, requested proposal span,
and any bonus-token position. Each later round MUST reserve its complete
window before proposal. If a sticky row cannot fund the next window, it MUST
remain on `native_mtp` but deterministically reduce its proposal depth, down to
depth zero, until the next round fits; if even depth zero cannot fit, it takes
the existing SPEC-038 request-local capacity failure. It MUST NOT switch paths,
overcommit memory, or partially stage a round.

The signed SPEC-023 admission sidecar MUST carry
`mtp.complete_window_bytes_by_depth`, an exact array indexed by proposal depth
`0...max_proposal_depth`. Each value is the qualification-derived conservative
complete native-MTP round ceiling for that depth, covering target/MTP state,
checkpoints, workspace, proposal span, and bonus-token position. Values MUST be
positive JSON integers, bounded by the consumer's `Int.max`, and monotonically
nondecreasing. Admission and capability construction MUST fail closed on a
missing array, wrong length, non-integer, nonpositive, decreasing value,
integer overflow, or tuple-digest mismatch. Total scheduler capacity for the
qualified tuple is the checked product of the max-depth value and
`qualified_slots`; overflow is an admission failure.

**Load gate.** Native MTP verifies `B * (1 + depth)` packed target positions
per round, and small-M quantized matmul cost grows with M, so its throughput
advantage over ordinary continuous batching shrinks as concurrent rows rise
and inverts at a tuple-specific row count. The signed SPEC-023 sidecar MUST
therefore carry `max_native_active_rows`, an integer
`1 <= max_native_active_rows <= qualified_slots`; consumers MUST fail closed on
a missing, non-integer, zero, or larger value, and the value is part of the
canonical admission tuple identity. An active row is any in-flight request on
the served runtime, native or ordinary, including queued and prefilling rows.
Admission and in-flight behavior are:

- **Admission.** The selection of a new request counts the other in-flight
  requests atomically with registering it. If that count is
  `>= max_native_active_rows`, the request selects ordinary with reason
  `capacity_above_native_bound` before any native state exists. This is a
  selection, not a pre-output fallback, and does not increment
  `preoutput_fallbacks`.
- **In flight.** Native rows never switch path. While the scheduler's admitted
  rows (prefilling plus decoding) exceed the smallest bound among native rows,
  every native row of that tuple is held at proposal depth zero, the existing
  in-path degraded state, and rides the ordinary lockstep decode forward with
  the other rows instead of a separate one-column native verification forward
  (MTP-6 drafter catch-up). Its selection, reason, and accounting stay
  `native_mtp`. The gate releases only after 8 consecutive decode
  rounds at or below the bound (or when no native row remains); this round-count
  hysteresis is an integer counter, never wall time. Depth then returns to the
  row's adaptation or directive depth, recomputing proposal state from the
  committed target state as for every depth increase.
- Integrity probes (R016 self-test and coordinator canary) run in isolation and
  are exempt from the in-flight depth gate.

A bound equal to `qualified_slots` never engages for a runtime that admits at
most that many rows. The bound is preregistered in the frozen R015 policy and
justified by its native-eligible cells: every slot count from one up to the
bound, at every mandatory prompt and output stratum, MUST pass the R015
improvement gate. Only native-eligible cells set or justify the bound; a gated
cell (slot count above the bound) passing MTP-15 non-inferiority shows the
gate is safe there and never raises the bound. A larger bound needs a new
frozen policy whose native-eligible cells cover it.

Native MTP MUST use SPEC-038 FCFS admission and shared-iteration fairness; it
MUST NOT create a second priority queue or skip an older ready ordinary row for
an MTP-only forward. When a packing limit prevents all ready rows from sharing
one forward, oldest-ready rows are selected first. Under the preregistered
mixed-load fixture, ordinary-row p95 ready-to-decode wait MUST NOT regress by
more than 10% against the same SPEC-038 workload with MTP disabled.

Every production tuple MUST advertise at least two slots and no more than the
SPEC-038 validated Entry-110 depth for that exact tuple. At the largest load
the tuple runs native (`max_native_active_rows` rows; a single row when the
bound is one), the acceptance fixture MUST place native MTP on every row the
bound admits, use proposal depth at least one, force rejection at every proposal
position under load, produce unequal accepted lengths, stagger row entry and
exit, and prove through backend trace evidence that eligible rows shared a
packed target verification forward rather than concurrent serial iterators.
Ordinary rows coexisting with native rows are proven by the load-gate fixture
at the advertised maximum (`qualified_slots`), which exercises the gate
exactly as an MTP-15 gated cell does: native admissions up to the bound,
`capacity_above_native_bound` and ineligible ordinary rows above it, and held
native rows at depth zero. The result MUST match the ordinary batched oracle with no row
bleed, deadlock, leak, starvation, or counter corruption. An eight-slot experimental cell is
reported on the 256 GB Studio but cannot be advertised unless SPEC-038 has
independently validated depth eight for that tuple.

After each non-overlapping 32-committed-token epoch, a deterministic policy
bound into the qualified tuple evaluates integer counters only. Let
`acceptance_ppm = floor(1_000_000 * accepted / proposed)` for the epoch. Two
successive epochs below the sidecar-bound `decrease_threshold_ppm` reduce depth
by one; two successive epochs above `increase_threshold_ppm` increase it by
one, bounded by zero and the qualified maximum, with
`decrease_threshold_ppm < increase_threshold_ppm`. Empty/depth-zero epochs do
not divide by zero: after one 32-token depth-zero cooldown epoch, depth retries
at one. Wall-clock timing and the observability overhead metric MUST NOT drive
the policy or the signed canary digest. Depth zero is an in-path native-MTP
degraded state, not an ordinary path switch. Adversarial low-acceptance prompts
MUST prove bounded excess target work and output/state parity.

Per-request adaptation is subordinate to a tuple-wide circuit breaker so
repeated short requests cannot reset the cost. New requests start at
`min(2, qualified maximum, tuple-wide current depth)`. Over the rolling last 64
eligible requests or 1,024 committed tokens (whichever closes first), compute
`verification_positions_per_committed_milli = floor(1000 * packed target
verification positions / max(1, committed_tokens))`. If it exceeds the
sidecar-bound maximum or tuple-wide acceptance falls below
`decrease_threshold_ppm`, all new and active rows reduce to depth zero for a
64-request cooldown. Two consecutive violating windows disable only the tuple
until a fresh local self-test plus operator/config reload. The sidecar maximum
MUST be `<= 4000`. This breaker is evaluated from integer work counters, not
wall time, and the mixed-load campaign MUST include repeated hostile eligible
requests shorter than 32 tokens.

### MTP-8 — streaming, stop, and termination atomicity (SPEC-048-R008)

The provider MUST buffer verified output as needed so streaming exposes only
committed, stop-safe tokens in ordinary-decode order. Stop strings spanning
proposal positions or scheduler rounds, stop token IDs, EOS, max-token limits,
cancellation during proposal/verification/commit, consumer disconnect, and
early iterator termination MUST leave output, terminal reason, usage, target
state, MTP state, and row release identical to the ordinary oracle at the same
boundary.

No terminal path may emit a duplicate final event, leak a token after the
terminal boundary, retain an uncommitted verification position, or make a
cancelled/failed row visible to persistence or a later request.

Streaming MUST retain the existing per-token SSE framing and MUST NOT encode
proposal depth or accepted-prefix length in frame fields, token grouping, or
padding. Relay and gateway observers may still infer timing/burst metadata;
SPEC-041 does not claim to hide that side channel. Status and buyer output MUST
NOT make the inference more explicit.

### MTP-9 — cache-reuse and persistence boundary (SPEC-048-R009)

Until SPEC-024 and SPEC-037 admit native-MTP state for reuse, the unified
decode-path selector MUST classify a request with a nonempty sticky
`conversation_key` as ordinary before continuous-batch admission or any
conversation-cache/disk-cache `begin()`, lease, promotion, reuse, or commit.

A key the coordinator marked cache-only (SPEC-004 v0.3.6, a SPEC-006-R012
auto-prefix key) MAY stay `native_mtp` through selection. It then takes
exactly the conversation-cache lease the ordinary path would take, and that
lease decides the path before the first native proposal or target-state
mutation, so the change is a selection and never a fallback:

- a lease reporting `cached_prompt_tokens > 0`, no lease, or a runtime that
  would hand back a retained paged-KV entry rather than a serial-format one
  reselects `ordinary` with reason `conversation_key`, keeping the ordinary
  cache-hit decision and discount, except as below;
- **(0.1.57)** a SPEC-024-R005 GLM-5-Next prompt-snapshot hit that carries
  the MTP head state at its boundary stays `native_mtp`: the CB row installs
  target state and head state together, resumes prefill at the snapshot
  length and keeps the hit and its discount. When the runtime can install
  such snapshots, a native row's lease treats every other snapshot (no head
  state, or a recorded boundary token that differs from the prompt's) as a
  miss (`prompt_snapshot_drafter_unavailable`), so the row stays native and
  prefills from zero instead of reselecting ordinary. Under that grant a keyed
  GLM-5-Next row publishes only its prompt snapshot, or nothing when its prompt
  is too short for one, so a cache miss stays native whatever its length;
- otherwise (a miss on a runtime that publishes keyed rows in the SPEC-038
  FR-CB4 serial conversation-cache format) the row stays `native_mtp`, keeps
  the lease, and reports `cached_prompt_tokens = 0`.

Such a native row runs the shared prompt prefill of R007 (the same forward as
its ordinary peers; **(0.1.49)** in a SPEC-038 v0.3.24 serial prefill cohort,
where every row takes its own forward, its own forward over the same chunk
and checkpoint boundaries) and captures the same prompt recurrent
checkpoints. At a
normal terminal it publishes the serial-format entry built from its committed
target state only: tokens, token count, attention KV, and recurrent
checkpoints, which MUST equal the ordinary row's entry for the same request.
No proposal, rejected position, staged state, or drafter state may enter the
entry, except **(0.1.57)** the SPEC-024-R005 MTP head state: the head's
committed cache at exactly the snapshot length, captured during prompt
prefill (never inside a verification round) together with the prompt token
its last entry consumed. It is draft-side only: restoring it can change
proposals and acceptance, never the target's tokens, which the target
verifies as on any native row. A failed, cancelled, or pre-output-fallback native row publishes
nothing and aborts its lease. **(0.1.63)** SPEC-037's versioned prompt-snapshot
codec may persist the complete SPEC-024-R005 target/head pair, including exact
raw tensor bytes, metadata, resume-boundary provenance and folded prompt token.
A restored native turn MUST pass the same target/head reuse checks as a RAM
hit; incomplete/unsupported records miss and stay native. Other native-MTP
state gains no new persistence permission. Cache retention and disk staging
MUST reserve the full CB capacity and native verify window before allocating,
while preserving R012's 10% system free-memory floor; only cache residency may
be declined under pressure. A request with no key behaves as before: no lease,
no commit, no busy key.

This applies to streaming and non-streaming paths. A future amendment that
reuses native-MTP state, or publishes retained paged-KV handoffs from native
rows, must prove target KV plus every MTP/recurrent state component and
preserve SPEC-024 billing isolation. **(0.1.57)** The R005 snapshot reuse is
that amendment for GLM-5-Next: its proof is the SPEC-038 v0.3.31 AC-26 GLM
proof (resumed native rows match ordinary CB tokens at the same row count,
with tokens/s, acceptance and TTFT reported in the R015 cells), recorded
before the signed `cached_turns_accepted` grant.

### MTP-10 — observability and warm-swap isolation (SPEC-048-R010)

The local `GET /v1/status` capability `native_mtp_status_v1` gates exactly one
`native_mtp` object. Its closed fields are: `supported` and `enabled` (bool);
`mode` (`off|eligible|active|degraded_depth_zero`); `family` (lowercase ASCII
matching `^[a-z0-9][a-z0-9._-]{0,63}$`); `proposal_depth` (the configured
maximum, integer `0...16`);
`requests_since_reset`, `proposed_tokens`, `accepted_tokens`, `rejected_tokens`,
`bonus_tokens`, `committed_tokens`, `target_forwards`, `mtp_forwards`,
`preoutput_fallbacks`, `postoutput_failures`, and `capacity_rejections`
(nonnegative 64-bit counters); `accepted_by_position` (array of nonnegative
64-bit counters, length exactly the capability maximum depth and at most 16);
`mean_accepted_length` (since-reset `accepted_tokens / max(1, mtp_forwards)`),
`verification_overhead_ms` (nonnegative cumulative monotonic milliseconds spent
in proposal/verification bookkeeping since reset), and
`throughput_delta_ppm` (signed integer loaded from the admitted sidecar's frozen
R015 result, not a live estimate); `reset_generation` (nonnegative 64-bit
integer incremented at each reset); and `last_reason` from the closed set
`active|disabled_by_default|tuple_not_admitted|tuple_revoked|revocation_state_unavailable|request_ineligible|unsupported_cache_state|capacity_unavailable|capacity_above_native_bound|low_acceptance_depth_zero|runtime_failure|warm_swap`.
`capacity_above_native_bound` records an R007 load-gate admission downgrade or
in-flight depth-zero engagement; a gated snapshot with native rows reads
`mode=degraded_depth_zero`.
No other `native_mtp` field is valid in v0.1.

Every nonnegative 64-bit counter, including each position counter and
`reset_generation`, saturates at `UInt64.max` and MUST NOT wrap. Saturation sets
`last_reason=runtime_failure`, disables the affected native-MTP tuple, and
requires a served-generation reset before it may become eligible again;
ordinary and classic decode remain available.

Mode is snapshot-wide, not a claim that every row has one depth: `off` means
config off or no admitted capability; `eligible` means admitted with no active
native row; `active` means at least one native row currently has depth above
zero; and `degraded_depth_zero` means native rows exist but all are in their
depth-zero cooldown. Per-row current depth is deliberately not exported. All
counters and derived values cover the interval since `reset_generation` only.

Metrics use the `native_mtp_` prefix and the same counter meanings. Labels are
limited to `position=0...15` and the closed `last_reason` values; model IDs,
paths, hashes, request IDs, and free-form errors are forbidden labels.

Exact artifact/runtime revisions belong in bounded diagnostic evidence, not
metric labels. `NativeMTPCapability` is part of the immutable served snapshot.
At SPEC-011 R-3.2.4 activation, the new snapshot publishes a fresh
`reset_generation` and zeroed counters atomically; draining old-snapshot rows
retain their old counter sink until termination and cannot write into the new
generation. New requests cannot use the old capability after that boundary.

The SPEC-001 v1.9.26 amendment admits this object only to local `/v1/status`.
Heartbeat and state-update payloads MUST omit every native-MTP field until a
later SPEC-001 wire revision defines them and passes encode/decode compatibility
against the oldest supported coordinator.

### MTP-11 — buyer, receipt, and accounting invariance (SPEC-048-R011)

Native MTP MUST NOT add or change any buyer request/response, model identity,
usage, receipt, billing, reward, trust-tier, route, or settlement field. Prompt,
cached-prompt, completion, and total token accounting MUST equal ordinary decode
under the same eligibility decision. Because a sticky key routes ordinary and a
cache-only key runs native only on the miss its ordinary lease would also
report (R004/R009), a cache-eligible request retains its ordinary cache-hit
decision and discount; it is never converted into an MTP cache miss.
SPEC-015 receipts bind only the final target-authoritative output and
existing usage object; no proposed, rejected, internal MTP, acceptance, or
decode-path field may enter the receipt.

A failed native-MTP attempt followed by permitted pre-output fallback MUST
produce accounting and any receipt solely for the final ordinary execution. A
post-output MTP runtime failure is non-settling: it MUST NOT emit a success
receipt, billable usage, buyer debit, provider credit, reward, or payout event,
whether output is native-only or stitched. If SPEC-015 emits an existing error
receipt, it MUST use that profile's non-settling/null-usage error form and bind
the exact terminal error; no partial completion is represented as success.

### MTP-12 — independent MLX quantization qualification (SPEC-048-R012)

An MXFP8 artifact used with native MTP MUST first be admitted independently by
SPEC-023/SPEC-010 as an MLX-native artifact for the exact runtime revision.
`mlx_mxfp8` MUST identify the loaded tensor representation, including packed
data, scale representation, group/block size, alignment/padding, unquantized
exceptions, and per-layer exceptions. Compressed-tensors FP8, TorchAO FP8,
GGUF, another microscaling format, or a model/artifact name containing `FP8`
MUST NOT be accepted as MLX-native MXFP8 without an explicit compatible
adapter admitted by the owner specs.

Before measurement, the fit model MUST declare how it accounts for packed
weight bytes, scale bytes, padding, exceptions, shared embeddings/heads,
native-MTP head and state, runtime graph/workspace, paged/hybrid cache, and the
maximum verification window. Its error tolerance and safety headroom MUST be
predeclared from existing fit policy, not selected after observing the result.

Before any MXFP8 measurement, the campaign MUST freeze the higher-precision
reference, corpus, quality metric and bound, memory-fit tolerance, throughput
baseline, TTFT/inter-token budgets, and thermal window. Qualification MUST
prove fixed-corpus load/forward correctness, finite tensors/logits, the frozen
quality bound: validation perplexity MUST be no more than `1.01x` the reference
and the preregistered task score MUST decline by no more than one absolute
percentage point. Predicted peak and resident process memory MUST each be no
more than 5% below the measured value; measured system-wide free unified memory
MUST preserve the R015 10% headroom. Qualification MUST also prove TTFT, decode
throughput, and sustained thermal behavior. A slower artifact may
remain a quality/memory option but MUST NOT be advertised as a throughput tier
or supply a throughput gate seed.

Passing MXFP8 ordinary decode and passing native MTP separately does not admit
their combination. The combined tuple MUST rerun every SPEC-048 correctness,
state, capacity, quality, and performance gate.

MLX affine 4-bit (`mlx_affine_4bit`) artifacts use the SPEC-023-R024
`mlx_affine` representation instead of the MXFP8 quality gate above. Their
admission still requires the exact observed target/MTP representation manifest,
per-layer override arrays, and unquantized exception arrays to match the signed
SPEC-023 sidecar before any native-MTP tuple can advertise capability.

For `glm5_next_mtp_v1` (0.1.35) `mlx_affine_4bit` names the global width only.
The artifact's per-module 5-, 6-, and 8-bit overrides (R002), including those
on `language_model.mtp.0.*` and on `embed_q` / `unembed_out`, are part of the
observed representation: each appears
in `per_layer_exceptions` and in the representation manifest with its exact
`bits` and `group_size`, and the fit model counts their packed bytes at those
widths. A mismatch in any override width or group size, a missing or extra
override, or an override the loader would not apply fails admission closed.
The admitted artifact carries 554 overrides (467 at 8 bits, 70 at 5, 17 at
6, all group 64). SPEC-023 v0.22.27 (lockstep with 0.1.36) admits widths 5
and 6 and raises the exception bound to 1024 entries.

**GLM fit headroom (0.1.36).** The fit model and the R015 10% free-memory
headroom count the next-N layer's own sparse-attention cache as resident
per-row state, not only as round workspace. Computed from the admitted
config (bf16 cache values; `kv_lora_rank` 512, `index_head_dim` 128,
`index_kpool` 4), each sparse layer holds `512 × 2 + 128 × 2 / 4 = 1,088`
bytes per context token. The next-N layer is one such layer: 71,303,168 bytes
per row at 65,536 tokens. With the target's 11 sparse layers (784,334,848
bytes) and the 34 KDA layers' fp32 recurrent state
(`64 × 128 × 128 × 4` bytes each) and bf16 short-convolution state
(`3 × 24,576 × 2` bytes each), 147,619,840 bytes together, one 64k row holds
1,003,257,856 bytes, about 1.00 GB, and the 4-slot design point holds
4,013,031,424 bytes. `complete_window_bytes_by_depth` covers only the staged
round on top of that.

### MTP-13 — signed admission and immutable evidence (SPEC-048-R013)

Catalog/autotune admission MUST be based on the SPEC-023 v0.22.6
`macprovider.native-mtp-admission.v1` signed sidecar bound to one immutable SPEC-023
`release_id` and SPEC-010 model/artifact member, never provider self-report.
The sidecar MUST bind the exact decode path, model/artifact/tokenizer digests,
MTP manifest and family adapter, proposal depth, quantization representation,
runtime/provider revisions, cache/state classes, exact hardware/RAM,
qualified slot count, native active-row bound (`max_native_active_rows`),
request-feature profile, maximum prompt tokens (`max_prompt_tokens`),
benchmark policy digest, source
commit, reproducible-build digest, the exact lowercase 40-hex
`spec023.live_executable_cdhash` CodeDirectory identity for the live signed
executable, `mtp.complete_window_bytes_by_depth`, and evidence artifact
digests. The live executable CDHash is
distinct from the installed binary SHA-256 artifact digest; the sidecar MUST
carry both and MUST NOT substitute one for the other.

Capability advertisement MUST fail closed if the live tuple differs from any
bound decode-path field, or if `live_executable_cdhash` is missing or
malformed. The provider revision, source commit, reproducible-build digest, and
live executable CDHash are recorded provenance of the qualifying build
(SPEC-023 v0.22.13): a consumer MUST NOT require them to equal the running
provider CLI, so a signed admission keeps serving across signed CLI releases.
**(0.1.36)** One CLI release serves every entry of a sidecar, so the
release-owned provenance (`provider_revision`, `source_commit`,
`reproducible_build_sha256`, `live_executable_cdhash`) is shared by all
entries of one release; per-entry provenance is not required.
**(0.1.32)** Admission is model-keyed: only the model key and target
artifact bind. The upstream MLX runtime revision, hardware class, RAM and
qualified slot count are recorded provenance of the qualifying run; a sidecar
entry matching them exactly is preferred, otherwise the first entry for the
model is used, and the MTP-16 on-device self-check qualifies the running
runtime on this Mac. Before 0.1.32 the upstream MLX runtime revision stayed
bound to the running build. Loader
The MLX runtime (fork) revision and target artifact remain bound to the
running build. Regressions under a new CLI are caught by the SPEC-031-R033
native-MTP self-test canary, which compares exact token IDs. Loader
success or a serial correctness pass is not sufficient for
catalog eligibility. Classic SPEC-028 evidence MUST NOT be relabeled as native
MTP evidence, and upstream/non-MLX benchmark numbers MUST NOT satisfy local
admission.

**(0.1.51) Decode-path binding.** Admission binds the decode path, not the
CLI binary. A release entry MAY carry `decode_path_digest` and
`metallib_sha256` (SPEC-023 v0.22.30; both or neither).
`decode_path_digest` is SHA-256 over the checked-in manifest
`phase3-binary/decode-path-manifest.json`: the native-MTP drafter and
verification files, the `ContinuousBatchScheduler` decode and verify windows,
the paged-KV decode kernels and bridge, the batched decode and the row
sampler, plus the pinned mlx-swift and mlx-swift-lm revisions. Those
revisions carry the MLX core and the model families' forward passes.
`scripts/decode_path_digest.py` defines the algorithm. The digest is compiled
into the CLI (`DecodePathIdentity`), so the signed binary carries it, and
`/v1/status` reports it as `build_identity.decode_path_digest`. CI fails when a
listed file is missing or changes without a regenerated digest.

- An entry that carries the binding admits the model only when all of these
  equal the running build: the embedded digest, `runtime_revision`, the SHA-256
  of the loaded Metal library, `hardware_class`, `ram_bytes` and
  `qualified_slots`, plus the model key and the target artifact.
- If any entry for the loaded model carries the binding, there is no
  model-keyed fallback. A mismatch refuses native MTP with reason
  `decode_path_mismatch`, and ordinary decode is unchanged.
- An entry without the binding keeps the 0.1.32 model-keyed rule. Entries
  published for CLI 1.8.258–1.8.260 are such entries.
- The CLI version, `provider_revision`, `source_commit`,
  `reproducible_build_sha256` and `live_executable_cdhash` never gate native
  MTP. Binary trust stays with SPEC-023 signed-release admission: an exactly
  revoked release gets an update-only session that is never routable, and
  tuple revocation is unchanged.
- Consequence: a signed CLI cut needs no admission step when its embedded
  digest equals the admitted entry's `decode_path_digest` and its shipped Metal
  library equals `metallib_sha256` (the other admission fields above still
  MUST match). A changed digest alone does not establish an MTP decode change:
  the manifest hashes whole files and dependency revisions, including changes
  unrelated to the qualified tuple's MTP behavior.
- For an already-qualified MTP tuple, a change that does not alter how it
  drafts, verifies, or commits tokens requires only an identity-only rebind
  when its binding changes: update the signed `decode_path_digest` and CLI
  identity/provenance to the new release, and any other changed runtime
  identity fields, while reusing the existing qualification evidence. This
  includes a CLI cut or a manifest-file/dependency change with no such MTP
  behavior change, as applied in #2136 and #2141. Admission still requires
  exact matching bindings; identity-only rebind does not bypass a mismatch,
  signed publishing, or revocation.
  Reused qualification artifacts MUST retain the source identity of their
  actual measurements, including the original benchmark policy's
  `provider_commit`; rebinding the sidecar MUST NOT rewrite that field or
  relabel historical timings as measurements of the new CLI. A separate
  authenticated reuse record MUST bind those original artifacts and their
  measured source to the reviewed target source and signed CLI identity,
  with the tuple-specific evidence that its draft/verify/commit behavior and
  qualification scope are unchanged. Matching recomputed decode-path digests
  may establish unchanged decode identity across a squash commit; a changed
  digest requires the reviewed behavior analysis above, not an assertion of
  source equality. Raw evidence, original identities, reuse proof and current
  signed bindings MUST all validate before composition or signing. A changed
  sampled verifier or expanded request profile does not inherit historical
  greedy correctness or performance evidence.
  A representative-policy sidecar retains the actual post-gateway replay
  policy bytes and schema as its benchmark-policy binding. Its signed journey
  separately retains and reanalyzes the original R015 matrix policy, runs and
  analysis, with their true measured source, while rederiving the privacy-safe
  representative projection and fresh paired replay. An exact reviewed
  test-only dependency revision change or LAB-only source delta may establish
  reuse mechanically under the reviewed recipe; it does not authorize a
  different request profile, hardware, bounds, Metal library or production
  draft/verify/commit behavior.
  Public R005 evidence MAY use the closed numeric redaction produced only
  after the existing full private acceptance validator passes. It preserves
  every numerical gate and case/position/selection coverage, whole-sequence
  commitments and exact raw result/policy/corpus SHA-256 identities, the true
  measured source, and a durable private Git-commit custody reference. Raw
  prompts, token IDs and per-token hashes MUST remain private. The protected
  signer revalidates that closed projection, arithmetic, coverage, source and
  authenticated transport provenance; it MUST explicitly record that it does
  not reopen the private raw bytes or provide independent hardware
  attestation. A custody commitment alone cannot replace either the full
  producer validation or the public numeric validation.
- R015 requalification is required only when a change alters how the qualified
  tuple drafts, verifies, or commits tokens. Before requesting that rerun,
  list the existing qualification evidence and name the changed decode-path
  code line and its effect on that MTP behavior (AGENTS.md HARD RULE 2).
  A changed digest, CLI identity, or Metal-library hash alone is not that
  evidence. A Metal-library change follows the same behavior test and MUST
  have its signed binding updated; it cannot retain a mismatched hash.
- Publishing: the binding is qualification-owned (tuple input). CLIs before
  the reader reject unknown entry keys, so R014 item 10 applies. A
  decode-path entry is published only when the bound release CLI embeds that
  same digest. The release input records it as `provider_decode_path_digest`.
  Catalog activation (`scripts/ops/catalog-activate.sh`) refuses unless three
  things hold. That value is the digest compiled at the release input's
  `source_commit`. The release tag `v<binaryVersion>` of that commit names it.
  The live coordinator recommends that release or a later one. The identity fields stay
  in every entry as provenance (dual-field).
  The sole pre-promotion exception is an identity-only rebind of an already
  qualified, one-row, depth-one greedy tuple inside the guarded matched signed
  binary/policy transaction exposed by `scripts/ops/`. Its target MUST be the
  exact reviewed main-source acceptance CLI cut: a successful protected
  `acceptance-candidate.yml` run, signature-verified acceptance envelope,
  checksums, source commit, binary SHA-256, CDHash and embedded decode-path
  digest all match the frozen transaction and signed-byte verification record.
  The independently verified prior published signed binary, signed policy and
  self-test bank MUST remain available for exact-pair rollback; the transaction
  MUST preserve CB, prior request-feature scope, model inventory, qualification
  evidence, row/depth bounds and ordinary context, with independent recovery
  custody before pause. Only identity/provenance bindings may change. The
  candidate's final release tag and fleet recommendation are not prerequisites
  for this bounded canary transaction: the existing CLI train requires its
  physical canary and in-scope e2e before final tagging/promotion. Normal catalog
  publication, wider sampled/tools/reasoning eligibility and increased bounds
  retain the general tag/recommendation gate above. This exception neither
  admits a local unsigned/unreleased build nor satisfies an e2e/journey gate;
  every later release and qualification gate remains mandatory.
  The signed native-binding bundle MAY be assembled after the campaign merge
  from the narrow reviewed deterministic recipe in SPEC-023-R017; all emitted
  bytes MUST match independent reconstruction from its committed inputs and
  verified signed CLI identity. That assembly exception changes neither this
  guarded unchanged-greedy-scope transaction nor its rollback obligations.
  Expanded GLM sampled/tools/reasoning scope retains the final tag and fleet
  recommendation gate and requires genuine R005 token/state proof and passing
  R015 qualification on the digest-matched LAB build. Recipe assembly and
  offline projection
  supply neither correctness nor performance evidence.
  JOURNEY-NATIVE-MTP-SERVING also permits its narrow authenticated post-cut
  redacted draft-asset delivery through the existing protected serving-journey
  workflow. The workflow MUST authenticate the exact reviewed merged source,
  successful protected acceptance candidate and CI run, signed candidate bytes
  and full closed evidence inventory before recomputing and signing the
  genuine journey result. Transport does not satisfy a journey step, R005,
  R015, a live e2e gate or conformance promotion; the ordinary committed-evidence
  route remains available.

SPEC-023 autotune recommendation, SPEC-032 hardware-evidence performance
measurement, and every ordinary catalog gate seed MUST force
`decode_path=ordinary`; `native_mtp_mode=auto` is ignored for those
measurements. MTP may be measured only in the separately labeled SPEC-048
campaign and cannot influence model recommendation or hardware admission.

SPEC-023 throughput gate seeding MUST use the ordinary, non-MTP measurement
for the tuple. Native-MTP measurements remain accelerated evidence and are
excluded or discounted exactly as SPEC-023 requires; they cannot raise
`min_sustained_tps` or a tier floor by relabeling accelerated output.

### MTP-14 — production enablement and release gate (SPEC-048-R014)

For each qualified tuple, production enablement requires all of the following:

1. SPEC-048 governance and the SPEC-001/023/024/028/030/031/036/037/038/039 amendments are
   landed. Requirements `SPEC-048-R001..R013`, `R015`, and `R016` are
   `conformant` in `CONFORMANCE.json`; `SPEC-023-R024`, `SPEC-030-R021`,
   `SPEC-031-R033`, `SPEC-036-R018`, `SPEC-038-R018`, and `SPEC-039-R015` are
   also `conformant`. Their signed result and sidecar must bind the exact
   SPEC-023-R024 `native_mtp_admission_tuple_sha256`, and that identity MUST be
   absent from the newest verified emergency-revocation feed the provider
   holds (SPEC-023 §12.5; an aged body still applies, 0.1.31);
   repository-wide conformance alone is insufficient. `pending` is insufficient
   for enablement.
2. The immutable upstream dependency and row-mapped API pass SPEC-048-R003.
3. Capability/manifest negatives, exact greedy parity, cache/state rollback,
   termination, mixed-row, capacity, fairness, and accounting fixtures pass.
4. Independent MXFP8 qualification passes when the tuple uses MXFP8.
5. SPEC-038 FR-CB15/Gate A5 and SPEC-039 FR-PKV13 pass for the same tuple, and
   SPEC-048-R015 passes on every advertised RAM/slot tuple.
6. A signed `JOURNEY-NATIVE-MTP-SERVING` result covers every requirement mapped
   to it: `SPEC-023-R024`, `SPEC-030-R021`, `SPEC-031-R033`, `SPEC-036-R018`,
   `SPEC-038-R018`, `SPEC-039-R015`, and `SPEC-048-R001..R013/R015/R016`, for
   that exact tuple, captured on the tuple's current decode path (AGENTS.md
   HARD RULE 2 and MTP-13: an identity-only rebind reuses the existing signed
   journey; a digest or CLI/runtime identity change alone does not require a
   new run, nor does age). CONFORMANCE state is repository-wide and therefore
   necessary but never sufficient for another tuple; each advertised tuple
   requires its own unrevoked sidecar and journey result.
7. The frozen implementation/evidence diff passes code, security, and
   architecture review with zero Critical, High, or Medium findings.
8. After merge and final signing, the exact release candidate is revalidated
   in isolated loopback against the sidecar source-commit/build digest
   (**0.1.51:** for a decode-path entry, against its `decode_path_digest`; a
   later signed CLI with the same embedded digest needs neither a new sidecar
   nor a new release journey; a changed digest with unchanged MTP
   draft/verify/commit behavior follows the MTP-13 identity-only rebind rule
   and reuses the existing qualification and journey evidence);
   release-asset byte identity and the previous-stable updater pass when the
   CLI ships in both Malibu.app and the standalone tarball. R014 is promoted
   to `conformant` from this post-release-candidate evidence before production
   configuration can enable the tuple. A separate signed
   `JOURNEY-NATIVE-MTP-RELEASE` result covers R014 and is the evidence that may
   promote it to conformant.
9. No unreleased local binary is connected to the live coordinator.
10. (0.1.36) A sidecar or projection manifest that a released CLI cannot
    parse is not published while that CLI is the released one: the v2
    multi-model projection, a second model's entry, a 5- or 6-bit override,
    or more than 256 exceptions ship only after the CLI cut that reads them
    is the released CLI. Publishing earlier would turn native MTP off for
    every tuple on the older CLI.

**Qualification and release identity (0.1.61).** R005 correctness, the formal
R015 matrix and its sustained phase MAY run on an isolated LAB build whose
embedded decode-path digest equals the reviewed PR head's recomputed digest.
The immutable evidence MUST retain the actual measured source, LAB binary
SHA-256, CDHash when present, and embedded decode-path digest. Consumers MUST
recompute source digest equality rather than require the later signed CLI's
executable identity. A CLI cut changes only identity binding: MTP-13's
authenticated identity-only rebind binds its signed SHA-256/CDHash to that
qualification without remeasurement. Raw policies and records retain their
original measured source. Neither representative replay, a v2 collector, a
fresh signed predecessor nor a signed-only qualification command is an added
prerequisite. All existing R005/R015 numerical and tuple gates, signed release,
journey, catalog publication and recovery obligations remain unchanged.

Failure or revocation of any tuple-specific gate MUST remove or disable only that
tuple's native-MTP eligibility and MUST preserve ordinary decode. No partial
Phase 0/1 implementation may claim issue completion or a production MTP
multiplier.

`activation` means the first production configuration load at which an exact
tuple becomes selectable. **(0.1.32)** A sidecar's `expires_at` is structural
only (it must follow `issued_at`); an admitted model keeps native MTP past the
date, and revocation is the off switch. A stale or unreachable revocation
feed keeps the last-known verified revocations (0.1.31); with no feed ever
verified, nothing is revoked. The provider keeps polling and disables the
tuple only when a verified feed names it. **(0.1.48)** A tuple parked after a
coordinator `bank_mismatch` (MTP-16) stays under the same revocation watch; a
verified feed naming it discards it. Before a parked tuple is restored, the
provider reads the newest verified revocation state (network first, else the
last-known verified feed): a tuple it names is discarded, and with no
verified state at all the tuple stays parked and fenced, so a restore fails
closed where a fresh load would not. The tuple stays parked, and so under its
revocation watch, until the moment it is published: the state is read again
after the scheduler fence is lifted, and publication follows that final
identity and revocation check with no suspension in between; a revocation
at any earlier point discards the tuple and the restore re-fences it. Before 0.1.30: sidecars and
serving-journey results expire after 90 days. Renewal creates a new immutable release/sidecar, reruns the local
self-test and signed serving journey, the 30-minute sustained cell, ordinary
and MTP parity sample, and post-gateway eligibility sample. The full matrix may
be reused for at most 180 days only when hardware, OS/toolchain, provider/MLX,
model/artifact/tokenizer/MTP manifest, quantization, cache/state topology,
depth, slots, thresholds, and benchmark policy are byte-identical; any change
or regression forces the full matrix. This lifecycle is independent of
SPEC-032 hardware-attestation TTL.
tuple becomes selectable. A sidecar's and a serving-journey result's
`expires_at` is structural only (0.1.30, #1938): once activated, a tuple stays
selectable until a superseding release replaces its sidecar, the emergency
revocation feed revokes it, or emergency-off is set. Requalification creates a
new immutable release/sidecar and reruns the local self-test and signed serving
journey, the 30-minute sustained cell, ordinary and MTP parity sample, and
post-gateway eligibility sample. It is required when hardware, OS/toolchain,
provider/MLX, model/artifact/tokenizer/MTP manifest, quantization, cache/state
topology, depth, slots, thresholds, or benchmark policy changes, never because
of calendar age. For an already-qualified tuple, provider/MLX or other runtime
identity changes alone instead follow MTP-13: when they do not alter how MTP
drafts, verifies, or commits tokens, only an identity-only rebind is required,
reusing the existing qualification and signed journey evidence. This exception
does not qualify a different model/artifact, hardware tier, capacity, or
benchmark policy. R015 reruns require the named changed decode-path line and
existing evidence specified by MTP-13.

### MTP-15 — preregistered Studio and tier benchmark gate (SPEC-048-R015)

Before collecting admission measurements, the campaign MUST freeze a policy
record containing exact hardware/SoC/RAM, OS, Xcode/Swift, provider and MLX
revisions, model/tokenizer/artifact/MTP-manifest digests, quantization, cache
mode, proposal depth, slot counts, prompt corpus, output budgets, run order,
warmup, exclusion rules, sample count, confidence method, and every pass/fail
threshold.

The matrix MUST compare native MTP with the best production-qualified ordinary
configuration the same host can run, including ordinary continuous batching at
its validated Entry-110 depth; a one-slot ordinary baseline cannot justify an
MTP tuple that reduces node capacity. It MUST also compare MXFP8 ordinary
decode and combined native MTP plus MXFP8 when those artifacts exist, at every
cell of the mandatory matrix below and in a sustained thermal window of at
least 30 minutes. Each cell MUST have at least ten counterbalanced measured runs after
warmup. The pairing unit is one counterbalanced run block on one host/thermal
window containing ordinary then MTP in randomized order; the bootstrap
resamples whole blocks with 10,000 draws. Gates apply separately to every
advertised `(hardware, artifact, slots, prompt/output stratum)` cell; no pooled
pass may hide a failing cell. Holm correction at family-wise alpha 0.05 covers
the throughput, TTFT, per-output-token latency, worst-gap, and rejection
hypotheses across all cells.

**Run order.** The order is preregistered by the frozen policy seed: in each
cell, half the measured blocks (rounded up) run native first, placed by a
SplitMix64-seeded Fisher-Yates permutation of the cell's blocks keyed by the
policy seed and the cell's slots, prompt, and output budget; the sustained
window alternates, native first on even blocks. Every measured block MUST
hold exactly one ordinary and one native record at order positions 0 and 1.
The analyzer recomputes the order and fails a cell on a missing or duplicate
record, an order that differs from the preregistered one, or a cell whose
blocks are not counterbalanced, and it fails an admission policy with fewer
than ten blocks, independent of the bench's own checks.

**Mandatory matrix.** The frozen admission policy MUST name the tuple's
advertised `qualified_slots` (2...8), its `max_native_active_rows`
(`1..qualified_slots`, written *bound* below), and its signed SPEC-023-R024
`max_prompt_tokens` (policy `maximum_prompt_tokens`, written *cap*, at least
1536), and MUST contain exactly these cells:

- *Native-eligible cells.* Every slot count from 1 up to the bound, at every
  prompt stratum of {1536, 4096} that is at or below the cap plus the cap
  itself, and at both fixed output budgets 128
  (short) and 512 (long) tokens. These carry the native speedup claim and
  justify the R007 bound. A prompt above the cap selects ordinary under R004,
  so no native stratum exists there to measure. Every stratum is counted on
  the served prompt, after the chat template the runtime applies, and is
  realized within ±2%; a stratum at the cap is realized at or below it. A
  native run whose row the token bounds sent to ordinary is an error, not a
  native measurement.
- *Gated cells* (policy `gated_cells`). When the bound is below
  `qualified_slots`, exactly the cells at slot counts bound + 1 and
  `qualified_slots` (one cell when those coincide), each at prompt 1536 and
  output 512 under the staggered arrival profile below. Gated rows execute the
  ordinary path (admitted native rows ride the ordinary forward at depth zero
  and later arrivals are downgraded), so their cost does not depend on the
  native speedup strata; non-inferiority at the first gated count and at full
  load bounds the intermediate counts, which repeat the same ordinary-path work
  at a load between the two. The inference rests on the gated cost model:
  above the bound, the only work native MTP adds to a round is buffering the
  committed columns (MTP-6) and admission bookkeeping of at most `bound` held
  rows, plus one drafter catch-up when a held row's depth returns or its
  buffer reaches the 1024-column cap (beyond the gated cells' 512 tokens),
  which does not grow with the ordinary rows, while the ordinary round time
  does not shrink as rows are added; the relative regression is therefore
  largest at bound + 1, and `qualified_slots` adds the full-load scheduling
  and memory point. A runtime change that adds per-row native work above the
  bound (for example drafting for downgraded rows) invalidates the model and
  requires every gated slot count to be measured.
- *Sustained window* of at least 1800 s on the cell at `qualified_slots`,
  prompt 1536, output 512 (`s<qualified_slots>-p1536-o512`, staggered):
  production-shaped full load. It is a separate bench phase on the same frozen
  policy and output file; it reuses that cell's matrix records rather than
  re-running them, binds the same policy digest, and keeps the alternating
  order below. It is one continuous run: an interrupted admission window is
  never resumed or stitched from separate runs; its records are set aside
  and the window is rerun whole (every sustained record carries the run's
  window id). When the bound equals `qualified_slots` the cell is
  native-eligible and already in the matrix.

A slot count above `qualified_slots` is not allowed. The bench refuses, and
the analyzer fails closed on, a policy whose cells differ from these, so a
reduced or substituted matrix cannot pass. Exploratory pilot policies are
exempt and never yield an admission verdict.

**Cell classes.** The frozen `max_native_active_rows` splits the matrix. A
cell whose slot count is at or below it is *native-eligible*: it carries the
throughput, TTFT, per-output-token latency, worst-gap, and rejection gates
above, admits every row
native (a load-gate downgrade there fails the cell), and every native run
must show proposals and target forwards. A cell above it is *gated*: it
measures the R007 load gate, so admitted native rows may legitimately spend
the whole run at depth zero inside the ordinary forward and need recorded,
consistent counters but not positive proposals. A gated cell MUST instead
prove the gate worked and cost nothing: every admission records the other
in-flight rows it was counted against, a native admission only while that
count was below the bound and a `capacity_above_native_bound` downgrade only
at or above it; admissions plus downgrades account for every request; parity
holds and fallback/error is zero; and native is non-inferior to ordinary at
the mixed-load margins of this section — the Holm-corrected lower bound of
the decode-throughput change at least -5%, the corrected upper bounds of p95
TTFT and p95 per-output-token latency regression at most 5%, the worst-gap
bound below, and capacity rejection up by
at most one percentage point. These margins are frozen in the policy
thresholds (`gated_throughput_lower_bound_min` -0.05,
`gated_ttft_p95_upper_bound_max` 0.05, `gated_tpot_p95_upper_bound_max` 0.05)
and join the same Holm family. A tuple whose bound is 1 therefore passes R015
with a native gain at one slot and non-inferiority at its gated cells.

**Reviewed issue #2081 disposition (0.1.50).** The operator's reviewed
campaign disposition accepts one measured performance tradeoff for admission
of exactly this tuple and no other:

- model `qwen/qwen3.6-35b-a3b`, target artifact
  `mlx-community/Qwen3.6-35B-A3B-4bit` with SHA-256
  `3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1`;
- MTP artifact SHA-256
  `fa01beecb6c1e76845e9880623c3b5a009baa602c52e9e9b5d12edc489a23fd2`;
- mlx-swift-lm revision
  `87dc5159c87d73f4d7abd524fbdd17760cf56285`;
- qualified provider source
  `c2519f2ad7ce0097731b654635e059b968aedbec` and frozen policy SHA-256
  `52499da79585817faf1797c0111e183839303102e7235ee1292b93fa4255e143`;
- Mac Studio `Mac15,14` with 256 GiB RAM;
- `max_native_active_rows = 1` and `qualified_slots = 8`.

For that exact issue #2081 campaign tuple, the frozen
`s2-p1536-o512` gated cell recorded a native-versus-ordinary p95 TTFT median
regression of approximately 6.0%, with the Holm-corrected upper bound also
above the preregistered 5% limit; the final exact values remain those in the
immutable analyzer evidence. The frozen policy, raw
records, analyzer output,
and analyzer `FAIL` verdict MUST remain unchanged and MUST accompany any
combined CLI admission review; this disposition does not reinterpret that
verdict as a preregistered `PASS` and does not replace the 5% limit with a new
threshold. For this exact tuple only, that recorded `s2` TTFT failure is not a
campaign admission blocker when the combined review explicitly cites this
operator disposition.

Every other R015 requirement remains mandatory, including the other five
matrix cells, the sustained window, correctness and parity, load-gate
accounting, signed capacity limits, positive native-eligible gain, and the
unchanged artifact and policy bindings. R003/R014 review, the signed serving
journey, and the gateway live proof also remain required by their respective
requirements. This disposition cannot be reused for a different model,
artifact digest, mlx-swift-lm revision, native-row bound, qualified slot count,
hardware tier, or campaign, except that the MTP-13 identity-only rebind rule
preserves the existing qualification and this disposition when runtime identity
changes without altering how the qualified tuple drafts, verifies, or commits
tokens. A change to that MTP behavior requires fresh R015 qualification,
identified by a named changed decode-path code line and the existing evidence
(AGENTS.md HARD RULE 2), and a separately reviewed disposition if its frozen
analyzer does not pass. An identity-only rebind or documentation/specification
merge with no such MTP behavior change does not require the campaign to be
rerun. It has no expiry.

A gated cell MUST also exercise the in-flight hold on the measured hardware,
so a policy with any gated cell MUST freeze a staggered arrival profile
(`arrival_interval_ms` > 0: the first request admits native before later
arrivals cross the bound); the bench refuses and the analyzer fails closed
without it. Across its native runs each gated cell MUST record at least one
native admission while the other in-flight rows were below the bound, at
least one `capacity_above_native_bound` downgrade at or above it, and at
least one round in which an admitted native row was held at depth zero. The
hold evidence comes from the scheduler's own gate decisions through a
lab-only recorder (absent from release builds): per run, depth-zero held
rounds, hold episodes, holds ended by a later committed native round (depth
restored, drafter caught up), holds ended by a stop/length terminal while
held, and unresolved holds. Every hold MUST end restored or cleanly finished
and none may be unresolved; a cell whose every request was downgraded fails.
Zero proposals remain allowed for held rows.
The campaign MUST report median and corrected confidence interval for
aggregate and per-request decode throughput, aggregate committed tokens/s and
per-request tokens/s end to end, p50/p95 TTFT and
inter-chunk gap, p95 per-output-token latency, p99 inter-chunk gap,
proposed/accepted/per-position/mean acceptance, target
forwards per committed token, peak/resident memory, capacity rejection,
fallback/error rate, terminal parity, and thermal stability.

Correctness, state integrity, and zero unexplained fallback/error are hard
gates. R015 throughput is decode throughput: a request's completion tokens
after its first, divided by the interval from its first token to its
completion. A run's aggregate decode throughput is the sum of every request's
tokens after its first, divided by the interval from the run's earliest first
token to its latest completion. Prefill is excluded because it is the same
work on both paths and is gated separately as TTFT below; prefill-inclusive
(end-to-end) committed throughput MUST still be reported but is not a gate.
A missing or non-positive decode throughput fails the run closed; evidence
recorded before the bench emitted it may derive it from recorded per-request
end-to-end throughput, TTFT, completion tokens, and nominal arrival offsets,
and fails closed when any of those is missing. Using the paired-bootstrap
corrected 95% confidence interval, the lower bound for aggregate decode
throughput improvement over the best ordinary baseline
MUST be at least 15% in each cell at the intended advertised slot count; both
paths use that same slot count, and the baseline is the best ordinary
production-qualified configuration at that count. The corrected upper bound
for native-MTP p95 TTFT regression MUST be no more than 10%, and the corrected
upper bound for p95 per-output-token latency (TPOT) regression MUST be no more
than 0%; bare point estimates do not pass. A request's TPOT is its decode
interval (first token to completion) divided by its completion tokens after
the first: the token-weighted mean, over every streamed chunk after the first,
of the chunk's gap divided by the tokens it carries. A run's statistic is the
p95 of its requests' TPOT, compared native over ordinary per paired block like
every other gate. TPOT is computed from the recorded per-request decode
throughput, so it needs no per-chunk token count, which the stream does not
expose. Every cell, native-eligible and gated, MUST also pass a worst-gap
bound: the corrected upper bound of the paired-block ratio of native p99
inter-chunk gap (over every gap of the run's requests) to ordinary p99
inter-chunk gap MUST be no more than `proposal_depth + 1` (policy
`chunk_gap_p99_upper_bound_max` 1.0, as ratio minus one, at the frozen depth
1). A native chunk is one verify round that commits at most `proposal_depth +
1` tokens, so even a round whose every token is a fresh target forward may take
at most that many ordinary token-times; a tail beyond it is a stall or extra
work that no per-token average excuses. A record without its inter-chunk gaps
fails closed.

*Gate amendment (0.1.25).* Through 0.1.24 the latency gate was the corrected
upper bound of the p95 inter-chunk gap, native over ordinary, at most 0%
(gated cells 5%). That compares one native verify round, which streams all of
its committed tokens as one chunk (about 1.85-1.92 tokens at depth 1 on the
A3B tuple), with one ordinary token, so it grows as the native path commits
more tokens per round and cannot pass at any acceptance rate while accepted
tokens are emitted together. The mismatch was first seen in the 2026-10-03
fused-baseline R015 and is documented in both 2026-10-06 R015 runs, where
native per-token latency fell (decode ratio 1.24-1.31) while the inter-chunk
upper bound stayed at +37% to +57%. The amendment replaces that gate with the
TPOT gate and the worst-gap bound above. It does not reinterpret any earlier
run: every R015 verdict recorded under 0.1.24 or earlier stays as recorded
(all of them FAIL), policies frozen with the inter-chunk gate are still judged
by it, and the decode-throughput, TTFT, rejection, memory, and hard gates are
unchanged. Inter-chunk p50/p95 remain reported. Capacity rejection MUST increase by no more than one
percentage point. Measured peak process resident memory plus the frozen safety
margin MUST remain within physical RAM, and system-wide available unified
memory sampled at least once per second MUST retain at least 10% physical-RAM
headroom throughout the 30-minute
sustained window. The exact frozen gates cannot be relaxed after results are
known. A confidence interval merely above zero and upstream `1.8x`, `2x`, or
`3x` claims are insufficient.

The campaign MUST also replay a preregistered, privacy-reviewed representative
post-gateway request-shape sample, preserving real provider-bound conversation
key state, at the observed eligibility mix. It MUST measure the share that
satisfies R004 before runtime capacity checks and compare end-to-end aggregate
throughput at that mix, not only on eligible prompts. At least 10% of requests
and 10% of completion tokens MUST be
eligible; otherwise the tuple may remain experimental but cannot be advertised
or enabled as a production throughput feature. In a mixed ordinary/native load,
the corrected upper bound for ordinary-row p95 TTFT and inter-token regression
MUST be no more than 5%, and the corrected lower bound for ordinary-row
throughput change MUST be no worse than -5%, against the same load with MTP
disabled. This is in addition to R007's ready-to-decode wait bound.

**Optional privacy-safe v2 observation and paired replay.** This optional
observation surface is not a prerequisite for R005 or formal R015
qualification. When used, its claims follow the rules below. The opt-in
`macprovider.native-mtp-request-shape-capture.v2` records successful persistable
completions with the provider's actual `off` or `auto` mode unchanged. Its role
is `request_shape_observation_only`: an observed ordinary or native completion
is not a measured ordinary control. Collection MUST NOT filter on candidate
eligibility, tools, sampling, observed path, or available native capacity.
SPEC-049 nonpersistable requests produce no request-derived record or counter;
sampling claims MUST disclose that population boundary and all omissions.
The existing v1 schema, off-only collection guards and formats remain unchanged;
absent schema selection still chooses v1. Explicit v2 selection does not alter
the signed request profile or admit broader traffic.

V2 MUST preserve normalized parsed controls and actual served family, geometry,
anonymous cache relationships and source identity without raw prompt/tool text,
function names or recoverable cache keys. Capture timestamps MUST NOT be used
as latency or original-arrival evidence.
The `observed_selector_reason`, `observed_selector_eligible` and
`observed_effective_path` fields describe actual capture-time selection only.
The bound candidate plan separately supplies `projected_selector_reason` and
`projected_selector_eligible` before capacity checks; fresh paired runs supply
actual measured admissions and paths. These facts MUST NOT be substituted for
one another. The >=10% request/token floors use candidate pre-capacity R004
shape shares. Capacity fallback remains measured ordinary work, not claimed
native admission. Known ineligible controls remain in both full paired loads
and representative denominators.

V2 capture requires the matching closed v2 projection-plan and replay schemas.
Strict validation MUST bind exact capture, tuple-bounds, complete sanitized
projection, bench-policy and analysis-policy bytes, preserving capture-build
identity separately from replay-build identity. Sampling and analysis rules
are preregistered before collection; a durable truthful privacy review binds
the captured bytes, omissions and reviewed fields. Missing source identity,
unknown family/control states, unresolved tool choices or other unreproducible
shapes remain counted
and make qualification `PENDING_UNREPRODUCIBLE_CAPTURE`; they MUST NOT silently
become known ordinary or eligible shapes. The production parser remains
authoritative before execution.

Both ordinary and mixed replay use the same frozen modeled stagger, in capture
sequence and cache-conflict order across the full qualified CB slots. Its
wave-local offset is index times the bound bench-policy `arrival_interval_ms`,
positive when qualified slots exceed the signed native-row bound. Capture
completion order does not reconstruct real arrival concurrency. Replay MUST
NOT split waves by eligible-row count to manufacture admission: the native cap
counts all active buyer rows, including ordinary rows. Fresh executions retain
all paired blocks and existing completion, cache, concurrency and corrected
metric gates. Conversion to the existing final analyzer contract preserves
projected pre-capacity shape shares separately from measured paths and uses
only fresh paired timings; offline projection remains
`PENDING_REAL_LAB_REPLAY`. Observation or schema validation does not qualify,
release, promote or activate a tuple.

The 256 GB Mac Studio is mandatory for the large-host issue campaign but does
not prove any lower RAM tier. Every hardware/RAM tier advertised for the tuple
requires its own fit, correctness, capacity, and sustained evidence. Sanitized
raw results, environment manifest, commands, hashes, failed/incomplete cells,
and the preregistration record MUST be durable and reviewable; model weights,
credentials, private paths, and operator secrets MUST NOT be committed.

### MTP-16 — native-path self-test and coordinator canary (SPEC-048-R016)

Before locally enabling a tuple, and after artifact/sidecar/runtime/cache-adapter
change, served-generation reset, or restart without continuity proof, the
provider MUST run `native_mtp_selftest_v1` in isolated no-join mode. It forces
`native_mtp`, binds the SPEC-023-R024 admission identity plus immutable served
snapshot (the same fields from which the runtime identity is derived), and compares expected
token-ID digest, terminal reason, acceptance counters, and canonical committed
state digest with the signed synthetic challenge record. Failure disables only
that tuple. This is provider-local health evidence, not coordinator-issued
integrity evidence and not a SPEC-031 canary result.

**(0.1.32)** The self-test reference is on-device: the provider runs the
challenge prompt through native MTP and through ordinary decode on the same
paged engine (same kernels, so near-tied logits resolve identically) at
greedy, requires identical token IDs, and requires the native run to be at
least 1.15x faster (best of two runs each). The 1.15x bar is the R015
native-eligible decode-throughput bound; the R015 PASS on the final
mlx-swift-lm 3.32.3 stack is recorded in `docs/research/mlx-swift-lm-3.32.3/`
(`step3-native-margin.md`, `step3-parity-event.md`, `step45-throughput.md`). Failure disables only that tuple
on that Mac. The signed challenge record's expected digest is no longer
compared by the provider, because it may have been produced on another
runtime revision. The SPEC-031-R033 coordinator canary is unchanged: it still
fails a tuple whose output differs from the signed bank record, so a release
that changes MLX numerics MUST re-baseline the challenge bank on the new
runtime through the normal signed release path.

After admission, the coordinator MUST maintain a fresh SPEC-031-R033
`native_mtp_canary_v1` pass for the exact
`native_mtp_runtime_tuple_sha256`. The profile is bounded to one
release-bound signed challenge bank of at most 256 entries; one synthetic prompt
of at most 8 KiB and 2,048 tokens; at most 64 completion tokens; one in-flight challenge per
provider/tuple, a 60-second deadline, and a default 3,600-second interval with
minimum 900 seconds; unavailable probe capacity reschedules without consuming
buyer capacity. A mismatch, timeout, expired result, unsupported-path fallback,
or ordinary/classic execution disables only the exact native-MTP tuple and
preserves provider readiness and ordinary/classic routing.

**(0.1.48) Tuple offer and re-offer.** The provider offers a tuple that passed
its self-check (`native_mtp_tuple_offer_v1`) once per coordinator session;
an identical offer is not repeated in that session. A coordinator
`bank_mismatch` disable says the canary does not hold the challenge bank the
provider qualified on, not that the tuple failed: the provider fences the
tuple exactly as for any disable (no further native-MTP rows for it), but
keeps its qualified load instead of discarding it. It offers that same tuple
again, restoring it to the state a fresh load reaches after its self-check,
only on (1) a new coordinator session, at most once per session, or (2) the
coordinator's served self-test bank becoming the bank the provider offers,
at most once per session and observed bank. While a tuple waits, the
provider reads the served bank's digest at most every 60 seconds, doubling
to 15 minutes. The re-offer carries the original self-check result; the
provider re-runs the self-check only when its own bank changes, which
arrives with a new release's admission set and so with a new tuple load. A
load, warm swap, revocation, or any other disable reason discards the
parked tuple. Parking never pauses revocation: the parked tuple keeps its
revocation watch, and a restore first re-reads the revocation state (R014).
The rejection is bound to the coordinator session it arrived on and the
offer dedupe is per session, so a disconnect racing either never consumes
or suppresses the next session's re-offer; a disable or park that suspends
while a load or swap installs a new tuple never clears the new one. No other
event re-offers, so repeated rejections never loop.

Neither path may use buyer data or emit usage, receipt, billing, reward,
settlement, or payout activity. Every actual-path/counter/state value is
provider-authored operational regression evidence under a cooperative released-
binary threat model; it is not cryptographic or independently trusted proof
that the path ran. SPEC-030-R021 and SPEC-036-R018 may correlate a fresh result
for diagnostics, but it cannot satisfy path identity, losslessness, compute
integrity, or settlement eligibility. Without a separately specified trusted
execution/attestation binding, their MTP variants remain observe-only and
inconclusive for integrity/enforce decisions. The signed expected record
excludes wall-clock adaptive-depth decisions; its counters bind the fixed
self-test depth and corpus.

## 5. Implementation, tests, and journeys

Implementation is branch-local and default-off. The current campaign branch
contains:

1. an immutable fork pin and reviewed upstream row-transaction, packed
   verification, serialized drafter-state, and hybrid recurrent-cache
   qualification surface;
2. provider signed-admission sidecar parsing and artifact observation for the
   Qwen 3.5 separate-artifact tuple and, in the epic #2029 campaign branch,
   for GLM-5.3-Flash: implemented are the `checkpoint_mtp` observer, the v2
   projection-manifest reader, adapter-derived source layout, the
   `glm5_next_mtp_v1` drafter (fork `GLM5NextMTPDraftModel`, built inside the
   loaded target), the provider load path and admission gate, and paged
   packed verification; pending are the evidence and promotion steps only
   (the final tagged-tuple `JOURNEY-NATIVE-MTP-SERVING` run and the GLM R015
   record, MTP-3);
3. default-off native-MTP selection, revocation gating, and ordinary fallback
   before sticky native state;
4. serial and mixed continuous-batching native-MTP runtime plumbing with
   row-local commit/discard/cancel behavior and status counters;
5. local `/v1/status` `native_mtp_status_v1` diagnostics and bounded metric
   labels;
6. provider-local `native_mtp_selftest_v1` challenge parsing/evaluation and
   coordinator `native_mtp_tuple_offer_v1` / `native_mtp_canary_v1` plumbing;
   and
7. local negative fixtures and parser/contract checks for admission,
   revocation, status, accounting invariance, and canary wire schemas.

This is not production conformance. The campaign still requires a clean frozen
diff, CI, Mac Studio hardware build/e2e/benchmark evidence, three-lane code /
security / architecture audit with zero Critical/High/Medium findings, and the
signed journey evidence listed below. MXFP8 remains excluded until SPEC-023 and
SPEC-048-R012 qualify a concrete artifact and the combined tuple.

Minimum automated coverage:

- complete, missing, extra, duplicate, wrong-shape, wrong-dtype, wrong-quant,
  and silently filtered MTP manifests;
- path traversal, symlink escape, unexpected local/network reference,
  malformed safetensors metadata, size overflow/mismatch, decompression bomb,
  and allocation-bound rejection;
- MLX-native MXFP8 positive fixtures and incompatible `FP8` negative fixtures;
- all accepted, none accepted, and rejection at every proposal position;
- bonus-token behavior and every cache/hybrid wrap boundary;
- exact state after rejection, cancel, EOS, stop, max tokens, disconnect, and
  early consumer stop;
- stop strings spanning proposal and scheduler-round boundaries;
- unequal row offsets/depths/accepted lengths; mixed decode paths; rows
  entering and leaving on different ticks; capacity exhaustion; and warm swap;
- deterministic randomized state-machine comparison with ordinary decode;
- no cache lease/promotion/commit and no cross-row state or metrics bleed;
- closed local-status decoding, bounded metric labels, counter-generation
  isolation, and heartbeat/state-update field omission;
- forced native-path canary success plus wrong digest, timeout, fallback, and
  ordinary-path negative cases;
- receipt, usage, billing, and terminal-event invariance; and
- long-running concurrency/thermal soak with leak and deadlock checks.

The signed `JOURNEY-NATIVE-MTP-SERVING` must bind the exact qualified tuple and
cover every requirement mapped to it: `SPEC-023-R024`, `SPEC-030-R021`,
`SPEC-031-R033`, `SPEC-036-R018`, `SPEC-038-R018`, `SPEC-039-R015`, and
`SPEC-048-R001..R013/R015/R016`, but not R014. It must include at least one
successful streaming request, one non-streaming request, one
forced rejection at a cache/state boundary, one mixed ordinary/native-MTP
batch, one capacity fallback, one cancellation, one warm swap, and one
ordinary-versus-native-MTP benchmark campaign result. When MXFP8 is admitted,
the journey must include its independent and combined evidence.

## 6. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-048-R001..R013/R016` | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | Branch-local implementation and focused parser/contract tests exist; pending CI, frozen-diff audits, Mac Studio hardware evidence, and signed journey evidence before promotion. |
| `SPEC-048-R014/R015` | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | Production enablement remains pending. For the exact issue #2081 Qwen3.6 tuple, MTP-15 records the operator's bounded acceptance of the frozen `s2-p1536-o512` TTFT failure while preserving the analyzer `FAIL`; every other R015 gate and the R014 review remain required. |
| `native-mtp-serving` | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | Authority acceptance, release-candidate review, and signed real-hardware journey evidence for the first production tuple. |
| First Qwen-family MTP artifact | `UNKNOWN` | `@Augustas11` | `#1770` | Legally/provenance-clean immutable model, tokenizer, MTP manifest, and exact hashes. |
| MLX dependency tuple | `RESOLVED_FOR_TUPLE` | `@Augustas11` | `#1906` | The operator's permanent fork model (MTP-3) replaces the upstream-release requirement. MTP-3 names the exact three-fork tuple; each rebase passes the runbook's per-rebase acceptance gate and a SPEC revision. |
| GLM-5.3-Flash `glm5_next_mtp_v1` tuple | `DECISION_REQUIRED` | `@Augustas11` | `#2029` | Pending: the `JOURNEY-NATIVE-MTP-SERVING` run on the R003-authorized tagged tuple and the GLM R015 record, which complete the R003 review record. An LFM-only tuple identity change follows MTP-13 and preserves the original measured GLM runtime/source identities. Implemented in the campaign branch: the observer, sidecar parsing, v2 projection reader, SPEC-023 v0.22.27 widths, the fork's MTP-1 drafter and packed verification, and the provider drafter load path, admission gate and paged packed verification. |
| First MLX-native MXFP8 artifact | `UNKNOWN` | `@Augustas11` | `#1770` | SPEC-023/SPEC-010 format, fit, quality, license, provenance, and hardware evidence. |
| Batched-verify numerical parity | `RESOLVED_FOR_TUPLE` | `@Augustas11` | `#1770` | The qmv-to-qmm switch at 12 packed verify tokens cannot occur for the first tuple: `max_native_active_rows` is 1 and depth is 1, so a packed verify is at most 2 tokens, and rows above the bound ride the ordinary forward at depth zero. A tuple whose bound times `proposal_depth + 1` reaches 12 must decide between a bounded drift allowance and kernel-matched verification before it can be signed. |
| Depth-1 throughput value | `RESOLVED_FOR_TUPLE` | `@Augustas11` | `#1770` | The 2026-10-06 quiet R015 (policy `e24cb7bc…`, amended 0.1.25 gates) passed every cell for the A3B Studio tuple: one-slot decode ratio 1.19-1.28 with corrected lower bounds +18% to +26%, gated s2/s8 cells non-inferior. The value is one-slot only; the R007 bound of 1 keeps native off above it. |

## 7. Evidence

Branch-local implementation and focused verification evidence exists for this
campaign, including Swift parser checks for the changed provider files and
focused coordinator native-MTP canary/config Go tests. No production release,
signed journey, or settlement/integrity evidence exists yet. The issue #1770
planning/review artifacts and this branch's local checks are design and
implementation evidence only, not production conformance.

The first implementation PR must record the selected dependency tuple and
artifact hashes rather than replacing the unknowns in this draft with mutable
model names. Hardware evidence must identify the exact Mac model, SoC/GPU,
RAM, OS, toolchain, power/thermal conditions, provider release, dependency
versions, artifact hashes, context, proposal depth, and slot count.

## 8. Current contract notes

The pinned runtime may already contain some generic MTP and MXFP8 primitives;
that fact is not a serving claim. The unresolved product work is the exact
Qwen-family adapter/runtime tuple, public row-mapped integration surface,
transactional scheduler/cache semantics, artifact/fit admission, and real
hardware evidence.

SPEC-028's production safety gate and effective single slot remain independent.
Fixing native-MTP cache transactions does not prove classic external-draft
rollback safe, and a future fix for classic speculation does not prove native
MTP multi-row state safe.

Optional vision-language serving is deferred. A vision-language-origin model
may be admitted for v0.1 only when its signed artifact/processor contract proves
the text-only path without image inputs; that does not admit multimodal buyer
requests.

## 9. Changelog and history

- **0.1.66 (2026-11-01)** — R003 names mlx-swift-lm `3.32.3-macprovider.13`
  (`5ee4333a8c052d9d0afc58db66b8976ea5fa398e`): GPT-OSS sink attention
  through batched caches. Swift, C and core pins are unchanged. A native-MTP
  admission bound to `.12` rebinds identity only (MTP-13).
- **0.1.65 (2026-10-31)** — R003 names the LFM-only reference-prefill tuple
  across LM, Swift, C and core. Default-false routing and single-token decode
  preserve existing model behavior; signed admission and cross-model hardware
  qualification remain separate gates.
- **0.1.64 (2026-10-28)** — R003 names the LFM-only expert-order correction
  `3.32.3-macprovider.10.15.1` (`36d24585f9373c2661f61f5e5b485c8d66c43a2b`)
  on `.10.15`. Shared/Qwen/GLM sources and transitive pins remain unchanged.
  Existing qualification retains its actual measured identity and scope;
  MTP-13 governs identity-only rebinding without rerunning unchanged R015 cells.

- **0.1.62 (2026-10-27)** — R003 names the combined fork tag
  `3.32.3-macprovider.10.15` (`3905a1b0499f0f38c0f94a008034a0362b9e3dca`), preserving the GLM packed
  projection and depth-one MTP work from `.10.13` together with the Prism loader
  from `.10.14`. Prior qualification records retain their measured source and
  identity; MTP-13 governs any source-equivalence identity-only rebind.

- **0.1.61 (2026-10-27)** — Corrects the campaign qualification bootstrap:
  digest-matched LAB R005/formal R015/sustained evidence records the actual
  executable and measured source. The signed CLI cut uses MTP-13 identity-only
  rebind, without remeasurement. Removes campaign-added signed-only,
  collector/replay and fresh-signed-predecessor prerequisites.

- **0.1.59–0.1.60 (2026-10-26–27)** — The initial signed-only qualification
  bootstrap was superseded by 0.1.61. The GLM implementation ceiling remains
  four with signed row/depth bounds one/one; higher bounds require existing
  per-bound R015 qualification.

- **0.1.58 (2026-10-26)** — Reconciles the sampled-profile campaign with the
  0.1.57 R009 prompt/head snapshot contract; its SPEC-024-R005 and SPEC-038
  AC-26 proof and signed cached-turns grant remain required. R013 cross-references
  SPEC-023-R017's narrow reviewed deterministic native-binding assembly exception
  without relaxing
  signed publication, qualification, unchanged-scope canary or exact rollback
  gates. R002/R004: allow the existing signed sampled
  profile for GLM-5-Next using R005 exact target-sample matching (mlx-vlm
  positioned sampling reference). Greedy signatures remain greedy-only; the
  signed native-row bound remains one pending campaign R015 qualification.
  R003 binds the packed GLM projection candidate `3.32.3-macprovider.10.13`
  (`b128c37f…`); new qualification is required for its changed verifier.
  The exactness description explicitly scopes the fused-shape envelope;
  arbitrary fallback fixtures do not inherit qualification. The existing
  recursive packed head was tested at depth two following SGLang positive-depth
  tuning. Its 0.795–0.860× two-row throughput missed the ordinary-CB floor,
  so its product adapter was removed and signed depth and row limits remain one.
  R004 also admits unconstrained GLM tools/history and ordinary reasoning effort
  following oMLX rendered-prefix semantics. Active grammar and explicit serial
  tool-call stopping remain ordinary. The campaign fixture now uses the actual
  production reasoning control instead of ignored chat-template kwargs.
  The existing GLM greedy profile retains its prior plain-text scope until
  the signed sampled profile is selected. R015 adds mode-independent privacy-safe
  v2 observations, distinct projected/measured eligibility, and identical frozen
  modeled arrivals across full ordinary/mixed CB loads; v1 remains compatible.
  R003 also names `3.32.3-macprovider.10.14`
  (`9b2766ee…`) for the native Prism schema-2 loader, owned snapshots, lazy
  vision and row-safe attention masks. The tree equals the tested `bd5f45f1…`
  baseline; unproven custom-kernel experiments are excluded. The mlx-swift and
  MLX core pins stay unchanged. Catalog admission, 8 GB fit, vendor quality,
  signed serving policy and journey qualification remain separate gates.
- **0.1.57 (2026-10-25)** — R009 (MTP-9): a native-MTP GLM-5-Next row reuses
  a SPEC-024-R005 prompt snapshot together with the MTP head state taken at
  it, on its own CB row, and stays native; any other snapshot is a miss for
  it rather than an ordinary reselection. Draft-side head state may enter the
  snapshot entry. No other family or path changes. Related: #2143.

- **0.1.56 (2026-10-25)** — R003/R013/R014/R015: align requalification with
  AGENTS.md HARD RULE 2 and the identity-only rebinds in #2136 and #2141.
  Qualified tuples reuse evidence when a digest or CLI/runtime identity changes
  without changing how MTP drafts, verifies, or commits tokens. Only such MTP
  decode changes require R015 requalification, with existing evidence listed
  and a named changed decode-path line. Exact signed admission matching,
  publishing, and revocation remain required.

- **0.1.55 (2026-10-24)** — R003: pins the DeepSeek-V4 CB performance slice
  `3.32.3-macprovider.10.5` (`c8be0f61…`) on `676a62a4…`. Batched attention,
  compressor/indexer projections and per-row rotary offsets reduce repeated
  dispatch and weight reads; keys-only windows and geometric pools avoid
  per-step whole-cache staging. SPEC-038/039 define bounded lookahead with
  stopped/failed row state discarded. CPU exactness at 1/2/4/8 rows does not
  establish GPU exactness, the four-row throughput gate, signed activation or
  the campaign freeze audit; those remain pending.


- **0.1.54 (2026-10-24)** — R003: pins the DeepSeek-V4 CB campaign fork
  `3.32.3-macprovider.10.4` (`676a62a4…`, `campaign/2111-dsv4-cb`) on
  `baec1724…`. Only `DeepseekV4.swift`, `DeepseekV4PoolCache.swift` and their
  tiny-fixture tests change in the fork. SPEC-038/039 define its row-owned
  pooled-cache serving boundary. No signed policy or native-MTP admission is
  granted by this tuple update. CPU tests are correctness evidence; the
  operator's native four-row throughput and hardware exactness window remain
  pending, as does the campaign freeze audit.

- **0.1.53 (2026-10-24)** — R004: constrained tool and structured-output
  rows use ordinary decoding until draft/verify preserves grammar state.
  Related: #2107.

- **0.1.52 (2026-10-23)** — R003: the mlx-swift-lm row moves to the
  immutable fork tag `3.32.3-macprovider.10.3` (`baec1724…`, branch
  `dsv4/2111-port`, Related: #2111), two commits on `3.32.3-macprovider.10.1`
  (`87dc5159…`). The diff adds `DeepseekV4.swift` and
  `DeepseekV4PoolCache.swift`, registers `deepseek_v4` in `LLMModelFactory`
  (one line), and adds the tiny DeepSeek-V4 test fixture and its test-target
  resource in `Package.swift`. `GLM5Next.swift` is a pure refactor with no
  numeric change: `makeLimitedSwiGLU` is no longer `private`, and
  `GLM5NextHyperConnection(config)` becomes a convenience init over a
  memberwise init with identical values. No other existing model, cache,
  iterator or loader line changes. The decode-path digest already covers
  this revision (`565617716a5ce9a1…`); the signed native-MTP admission
  entries keep their 0.1.51 bindings
  until rebound under the MTP-13 identity-only rule when MTP draft/verify/commit
  behavior is unchanged; requalification is required only for changes to that
  behavior. The issue #2081 disposition retains its original evidence revision.
  The tag name
  `3.32.3-macprovider.10.2` belongs to an unrelated GLM candidate and is not
  authorized.

- **0.1.51 (2026-10-22)** — R013/R014: admission binds the decode path, not
  the CLI binary. Entries may carry `decode_path_digest`, a SHA-256 over the
  checked-in decode-path manifest compiled into the CLI and reported on
  `/v1/status`, together with `metallib_sha256`. Such an entry admits only an
  exact decode-path match: digest, runtime revision, Metal library, hardware,
  RAM and slots. It has no model-keyed fallback and refuses with
  `decode_path_mismatch`. Entries without the fields keep the 0.1.32 rule. A
  signed CLI cut with an unchanged digest needs no admission step. CLI
  identity never gates, and SPEC-023 exact revocation still blocks serving.
  Publishing follows R014 item 10.

- **0.1.50 (2026-10-21)** — R015 records the operator's reviewed, exact-tuple
  issue #2081 disposition for the Qwen3.6-35B-A3B `s2-p1536-o512` TTFT
  regression. The frozen policy, raw records, 5% limit, and analyzer `FAIL`
  remain unchanged; the disposition makes only that recorded result
  non-blocking for the bound-1, eight-slot tuple while every other campaign,
  correctness, journey, and live-proof gate remains mandatory. It is not
  reusable by another tuple or a changed runtime path and has no expiry.

- **0.1.49 (2026-10-19)** — R009: a cache-only native row in a SPEC-038
  v0.3.24 serial prefill cohort (a backend whose grouped prefill rows always
  run alone, such as glm5_next) prefills in its own forward over the same
  chunk and checkpoint boundaries as its ordinary peers; its published entry
  is unchanged. SPEC-038 v0.3.24 lets native prompt rows join such cohorts,
  which removes the prefill-schedule difference behind the GLM-5.3-Flash
  gated-cell R015 failure on CLI 1.8.256.
- **0.1.48 (2026-10-18)** — MTP-16: tuple offer and re-offer. A coordinator
  `bank_mismatch` fences the tuple but keeps its qualified load; the provider
  offers it again once per new coordinator session, or once when the
  coordinator's served bank becomes the bank it qualified on, without a
  model reload and without re-running the self-check. A parked tuple keeps
  its revocation watch and is discarded when revoked, up to the moment a
  restore publishes it; a restore reads the revocation state before lifting
  the fence and again right before publication, and fails closed without
  one (R014). A bank poll stopped while its fetch is in flight never acts
  on the result. Rejections and the
  offer dedupe are bound to their session. Paired with SPEC-031-R033 v0.3.9,
  under which the coordinator canary bank moves with the release.

- **0.1.47 (2026-10-17)** — MTP-6: the lab oracle's round order is the
  bridge's per-row committed-round number carried by each after-finalize
  record, not the record's position, so a missing record fails the
  comparison instead of renumbering its successor; a rejected round is one
  that proposed at least one token and committed fewer.

- **0.1.46 (2026-10-17)** — MTP-6: the lab oracle's "comparison after a
  rejection" is a compared round whose immediately preceding round of the
  same row committed no proposal, over consecutive rounds in commit order;
  a rejected round's own record no longer counts. The embedded metadata
  version matches the header again (it had stayed at 0.1.43).

- **0.1.45 (2026-10-17)** — MTP-6: the target-oracle state digest is
  defined. A `glm5_next` paged MLA layer contributes the state a forward
  reads plus the last `maxTrim - kpool` folded raw keys (rewind headroom
  that an exact rejection leaves shorter than one-token decode does); the
  journey's step 05 compares it at every ordinary decode-window end a native
  round lands on, and a rejected depth-1 round is a committed round, not an
  abort. No serving behavior changes.

- **0.1.44 (2026-10-17)** — MTP-3: the campaign mlx-swift-lm row is the
  immutable fork tag `3.32.3-macprovider.10.1` (`87dc5159…`); its one commit
  over `18ca5267…` validates the GLM-5-Next configuration at load and changes
  no decode-path line. The upstream watch checks that the tag resolves to the
  row's revision. §5 and §6 separate the implemented GLM-5.3-Flash surface
  from the two pending evidence items (the final tagged-tuple journey and the
  GLM R015 record); the release state stays `DECISION_REQUIRED`.

- **0.1.43 (2026-10-17)** — MTP-2: a `glm5_next_mtp_v1` tuple signs
  `max_native_active_rows` 1 (measured 1.27x ordinary at one native row,
  0.79x at four); the sidecar loader and generator reject a larger bound.

- **0.1.42 (2026-10-17)** — MTP-3 campaign tuple moves to mlx-swift-lm
  `18ca5267…` (untagged; the tag stays a PENDING row), which carries the
  #2035 Qwen2-VL per-image vision attention fix (`8ee6305`). GLM-5-Next MTP
  drafts and verifies up to depth 7 with in-place rollback and serves at
  depth 1 by default (`GLM5NextMTPDraftModel.maximumDepth`); the shared
  iterator gains the optional `MTPAdaptiveDepth` controller, unused by the
  provider. mlx-swift and the MLX core are unchanged.

- **0.1.41 (2026-10-17)** — MTP-3 campaign tuple moves to mlx-swift-lm
  `7d8dbf56…` (untagged; the tag stays a PENDING row). It adds the fused
  GLM-5-Next multi-vector projection (`glm5NextQMVBatch`, bitwise equal to
  the one-vector path) and the one-dispatch KDA verify step, and a shared
  single-sync greedy round in `MTPSpeculativeTokenIterator`, which the
  provider does not use. mlx-swift and the MLX core are unchanged.

- **0.1.40 (2026-10-17)** — MTP-2 GLM-5-Next: provider load and admission.
  The drafter is built inside the loaded target from its `config.json` (no
  second weight load); the allowed (adapter, layout) pairs are listed; a
  `glm5_next_mtp_v1` capability requires the next-N weights, the exact
  KDA + `pagedMLA` topology, the 8-token forward bound with one row's
  verification inside it. The R003 lm row moves to `fa729424…`, which adds
  packed GLM-5-Next verification inside continuous batching (per-row
  transactions, padded columns that write nothing); the provider verifies
  `pagedMLA` rows through a paged equivalent with the same commit rule.

- **0.1.39 (2026-10-17)** — MTP-3 campaign tuple moves to mlx-swift-lm
  `dcbf9333…` (untagged; the tag stays a PENDING row), rebased onto the fork's
  `3.32.3-macprovider.10` line (`b4077dcb…`), which adds the upstream #622
  rotating-cache exact-rewind fix and the per-layer `KVCache.maxTrimCount`
  gate; the GLM-5-Next latent cache reports its exact rewind depth through
  it. mlx-swift `29d3b933…` and MLX core `2f512e39…` are unchanged.

- **0.1.38 (2026-10-17)** — MTP-3 campaign tuple moves to mlx-swift-lm
  `bf6ed339…` (still untagged; the tag stays a PENDING row); mlx-swift and
  the MLX core are unchanged. The two added commits are GLM-5-Next only: the
  MTP-1 target side (verification columns as one-token decode steps, in-place
  one-token rewind, hidden state and `validLatent` for the head) and the
  `GLM5NextMTPDraftModel` drafter with its registration. The provider's
  `glm5_next` native-MTP serving surface stays outside the row.

- **0.1.37 (2026-10-17)** — MTP-3 campaign tuple moves to mlx-swift-lm
  `b177f9ea…` (still untagged; the tag stays a PENDING row), mlx-swift
  `0.32.3-macprovider.9` (`29d3b933…`) and MLX core `v0.32.4-macprovider.4`
  (`2f512e39…`). The core carries the #2028 caller-stream fix onto v0.32.4
  (three commits; `quantized.cpp` and `scaled_dot_product_attention.cpp` are
  unchanged from `v0.32.4-macprovider.1`). The mlx-swift-lm revision adds
  batched GLM-5-Next rows (`GLM5NextBatchedLatentCache`): batched rows are
  bitwise equal to serial up to 8 flattened tokens per forward. The #2028
  review record is kept beside the earlier one.

- **0.1.36 (2026-10-17)** — GLM-5.3-Flash admission details (epic #2029,
  lockstep with SPEC-023 v0.22.27). MTP-2: override widths `4`, `5`, `6`, or
  `8` for every adapter; the source layout is derived from the adapter
  string; the GLM observer admits only a post-sanitize checkpoint and names
  its unpaired floating parameters; the catalog key is
  `zai-org/glm-5.3-flash`. MTP-12: the next-N layer's sparse-attention cache
  (1,088 bytes per token, 71 MB per 64k row) counts in the fit model and the
  R015 headroom; one 64k GLM row is about 1.00 GB. MTP-13: release-owned
  provenance is shared by every entry of one release. MTP-14 item 10: a
  sidecar or projection that a released CLI cannot parse ships only after the
  CLI that reads it is released.

- **0.1.35 (2026-10-17)** — GLM-5.3-Flash native MTP and the campaign fork
  tuple (epic #2029). MTP-2 adds the `glm5_next_mtp_v1` adapter with the
  embedded `checkpoint_mtp` layout: the `mtp` artifact is the target
  directory and the MTP manifest is the target's `config.json`, so the ~4 GB
  next-N layer loads once and the target digest is unchanged. It defines the
  `language_model.mtp.0.*` tensor grammar, the GLM vision namespaces
  (`vision_model.`, `vision_tower.`, `visual.`, `model.visual.`), the
  sanitizer mapping the observer reproduces, 4/5/6/8-bit overrides recorded
  once under `target/`, depth 1 (drafter block size 2), and greedy-only
  admission; R004, R012, R014, and R015 are unchanged. MTP-2 also defines the
  v2 multi-model projection manifest keyed by `model_key` (single-model
  releases keep the v1 bytes). MTP-12 records how the overrides enter the
  representation and that a GLM sidecar needs a SPEC-023-R024 lockstep
  amendment (override widths 5 and 6; more than 256 exceptions). MTP-3 marks
  the mlx-swift-lm fork tag and the tuple's review record as pending rows the
  campaign release step fills, keeps the previous tuple's review record,
  names the GLM-5-Next surface at `378aaf76…`, and updates the MTP-2 loader
  reference to that revision.

- **0.1.34 (2026-10-17)** — MTP-3 (R003) authorizes the operator-approved
  move of the mlx-swift-lm fork pin from `3.32.3-macprovider.9`
  (`dbe8bcb3…`) to `3.32.3-macprovider.9.4` (`ce3bb523…`); the mlx-swift
  (`0.32.3-macprovider.8`, `745f5e48…`) and MLX core
  (`v0.32.2-macprovider.5`, `49d94e9f…`) pins and every upstream base are
  unchanged. `.9.4` is four commits on `.9`: the first three change only
  `Libraries/MLXVLM/Models/Qwen2VL.swift` (vision attention segmented per
  image, issue #2016, with the multimodal rotary embedding's leading batch
  axis dropped, and equal-length blocks batched into one attention call)
  and add `Qwen2VLVisionSegmentationTests`; the fourth is test-only
  (the Qwen2-VL append-only media split now matches the full prefill).
  Tags `3.32.3-macprovider.9.1` (`24856d07…`, traps at runtime),
  `3.32.3-macprovider.9.2` (`983fef9a…`) and `3.32.3-macprovider.9.3`
  (`c453f72e…`) are superseded; they MUST NOT be pinned. Every other
  model's decode path, including the Qwen3.5/Qwen3.6 MTP, packed
  verification, fused MoE and GDN surfaces, is byte-identical to `.9`, so
  the Qwen3.6 continuous-batching and native-MTP qualifications stand and
  re-binding them to the new runtime revision is identity-only under
  AGENTS.md rule 2 (no new qualification or benchmark).
- **0.1.33 (2026-10-16)** — MTP-3 (R003) authorizes the tuple
  `3.32.3-macprovider.9` (`dbe8bcb3…`) / `0.32.3-macprovider.8`
  (`745f5e48…`) / `v0.32.2-macprovider.5` (`49d94e9f…`), upstream bases
  unchanged. The MLX core fork adds one patch: every internal call inside a
  stream-taking op passes the caller's stream, including the
  `quantized_matmul` casts, `gather`/`scatter` index broadcasts, the
  implicit random key split and `categorical` used by sampling, and the
  `layer_norm`, `linalg`, `fft` and attention fallbacks, and the
  primitives' vjp/jvp rules use the primitive's stream. Before it, those
  calls ran on the thread's default stream while mlx-swift runs every op on
  its own pooled stream, so each one was a cross-queue dependency.
  gpt-oss-20b decode paid 140 per token and ran 30% below the 3.31.4
  runtime (#2028). The same kernels run on the same
  inputs, on the caller's stream; no kernel, routing or numerics change.
  The mlx-swift and mlx-swift-lm forks change only their pins.
- **0.1.32 (2026-10-10)** — Model-keyed admission, revocation-only policy,
  on-device qualification (follows SPEC-038 v0.3.15). MTP-13: admission keys
  on the model and its target artifact; the upstream MLX runtime revision,
  hardware class, RAM and qualified slots are recorded provenance that only
  prefer the closest entry, so a fork-revision bump keeps native MTP. MTP-14:
  `expires_at` is structural only, and an absent or stale revocation feed
  revokes nothing; only a feed naming the tuple disables it. MTP-16: the
  provider self-test compares native-MTP greedy output with ordinary decode
  of the same prompt on the same paged engine (same kernels) and requires a
  decode speedup of at least 1.15 (the R015 decode bar); a pre-signed token
  digest from another runtime is no longer the provider-side reference. The
  SPEC-031-R033 coordinator canary still compares the signed bank's expected
  values; a release that changes MLX numerics re-baselines that bank.
- **0.1.31 (2026-10-10)** — The emergency revocation feed fails to last-known
  (#1938, follows SPEC-023 v0.22.23). `revocation_state_unavailable` now means
  no usable authenticated revocation state (none ever verified, or a local
  store/cache/anchor integrity failure); an aged, unreachable or rejected feed
  keeps the newest verified revoked set in force and native MTP on.
- **0.1.30 (2026-10-10)** — No calendar expiry on native MTP (#1938, AGENTS.md
  rule 10). MTP-14: the admission sidecar's and the serving journey's
  `expires_at` are structural only; an activated tuple stays selectable until
  a superseding release, a revocation, or emergency-off. Requalification is
  triggered by a decode-path change, not by age; the 180-day matrix reuse
  limit and the 90-day sidecar/journey lifetime are removed. Follows SPEC-023
  v0.22.20.
- **0.1.29 (2026-10-10)** — MTP-2 names the R003-authorized loader instead
  of the retired 3.31.4 loader (#1906). The observer must inspect every weight
  file the authorized mlx-swift-lm loader can consume; at
  `3.32.3-macprovider.6` its recursive scan is a superset of the loader's
  index-or-top-level selection. Every fork rebase re-establishes that
  containment under the per-rebase acceptance gate.
- **0.1.28 (2026-10-10)** — MTP-3 adopts the operator's permanent fork model
  (#1906). The Augustas11 forks of mlx-swift-lm, mlx-swift, and MLX core are
  the production runtime; MacProvider makes no upstream contributions and
  rebases the fork patch stacks onto each adopted upstream release. R003 now
  authorizes the exact tuple `3.32.3-macprovider.6` (`72c4ab08…`, upstream
  `3.32.3`) / `0.32.3-macprovider.2` (`ca2f61d2…`, upstream `0.32.3`) /
  `v0.32.2-macprovider.2` (`c9196eb7…`, upstream `v0.32.2`), adds the
  compiled MTP verification step, declared compile state for every trace,
  exact-stock-type fused-MoE eligibility, batch-invariant small-M quantized
  routing, and every-thread compiled-function erase to the authorized
  surface, and defines the per-rebase review gate. The upstream-replacement
  removal trigger, the exception re-review date, and the `ca8c384c…`
  candidate authorization are removed.
- **0.1.27 (2026-10-09)** — CLI identity is provenance, not a gate (#1893).
  MTP-13 follows SPEC-023 v0.22.13: the admission's provider revision, source
  commit, reproducible-build digest, and `live_executable_cdhash` stay signed
  and inside the tuple digest but no longer have to equal the running provider
  CLI. The upstream MLX revision and target artifact stay bound, and the
  SPEC-031-R033 self-test canary remains the runtime regression check.
- **0.1.26 (2026-10-06)** — Production eligibility for auto-prefix traffic
  (#1770). MTP-4/MTP-9/MTP-11: a key the coordinator marks cache-only
  (SPEC-004 v0.3.6 `conversation_cache_only`, SPEC-024 v0.2.10) stays eligible
  through selection; the ordinary path's own lease then decides before native
  state exists. A hit, a missing lease, or a retained paged-KV runtime
  reselects ordinary with reason `conversation_key`; a miss on a
  serial-format runtime stays native, keeps the lease, and publishes the same
  serial-format entry the ordinary row would, from committed target state
  only. Sticky keys stay ordinary. Without this the gateway's auto-prefix key
  made nearly all paid traffic ineligible, so R015's 10% post-gateway floor
  could not be met. MTP-7: a native row in an equal-length prefill group now
  shares the group's `[B, L]` target forward (R014 rehearsal mixed-row
  failure); its drafter is seeded from its own slice of that forward's hidden
  states.

- **0.1.25 (2026-10-06)** — MTP-15 replaces the R015 inter-chunk p95 latency
  gate with a per-output-token latency (TPOT) gate (p95 across a run's
  requests, corrected upper bound <= 0%, gated cells <= 5%) and a worst-gap
  bound in every cell (native p99 inter-chunk gap at most `proposal_depth + 1`
  times ordinary's, corrected upper bound, frozen 1.0 as ratio minus one), in
  the same Holm family and paired-block bootstrap (#1770). Motivation: the
  structural mismatch between one multi-token native chunk and one ordinary
  token, first seen 2026-10-03 and documented in the 2026-10-06 runs. Decode
  throughput, TTFT, rejection, memory, and hard gates are unchanged; earlier
  verdicts stay as recorded and legacy-gate policies are still judged by
  their own gates. A new R015 must be frozen with the amended gates; native
  MTP stays default-off. MTP-6: a load-gated row no longer advances its
  drafter every 64 buffered columns; it catches up only before its next
  native proposal. An interleaved s2 control (2026-10-06) showed the periodic
  catch-up as a ~10 ms stall in the shared round every 64 tokens, on both
  rows, in every gated native run of both the 10-06 and step-overhead
  binaries. A held row's buffer is capped at 1024 columns (an early
  catch-up when its next window would pass the cap), and each buffered
  hidden state is a copy of its own row: an uncapped buffer of batch-output
  views kept `B x 4 KiB` per committed token alive outside the paged-KV
  accounting, up to 32 GiB for a held row at `B = 8` and the 1,048,576-token
  completion budget. The cap is above every R015 cell's 512 tokens.
  The R015 frozen on `e1103712d` with these gates (policy `e24cb7bc…`, quiet
  window, live provider paused by operator authorization) passed every cell
  on 2026-10-06. That is lab evidence for one tuple on one host: R015
  conformance still needs every advertised tier and the post-gateway replay,
  and native MTP stays default-off until the R014 operator gate.

- **0.1.24 (2026-10-06)** — Moves the immutable fork candidate to
  `ca8c384c4fb6bc7d2fbb7c70a18c34b935701805` (parent `b1811029…`) to cut
  native-step overhead (#1770): a single-pass checkpointed Gated DeltaNet
  verify kernel, bit-identical to the split prefix/suffix recurrence, and no
  all-true SSM mask when no packed verification row is padded. The provider
  folds the drafter seed conversion into the round's staged evaluation. The
  2026-10-06 R015 (policy `2c8a2344…`) showed native-step cost as the
  one-slot limit; a new R015 must be frozen on this pin. The R003 review gate
  for this revision is pending; ordinary decode is unchanged, and native MTP
  stays default-off.

- **0.1.23 (2026-10-05)** — Moves the immutable fork candidate to
  `b181102984a4d1875efbd9e0eab3a7dfd1c012c5` (chunked envelope at
  `9c1cd900…`, then exact tensor-layout validation; parent `ca29e954…`) and
  qualifies the fused A3B MoE path on the ordinary path, independent of native
  MTP (#1770). The fused-baseline R015 (policy `de99e85c…`, 2026-10-03) failed:
  one-slot throughput lower bounds `+5.18%` to `+10.96%` against the `0.15`
  gate, inter-token p95 upper bounds `+59%` to `+62%`, two-slot TTFT `+7.16%`,
  and eight-slot ordinary/native parity mismatches in 8 of 10 blocks. Studio
  runs on 2026-10-05 traced the parity failure to the fused/stock switch at
  eight flattened tokens: stock and fused are each batch-invariant but not
  bit-equal, and a native row's batch is one token wider than the ordinary
  row's, so the two crossed the switch at different steps. Decode- and
  verify-shaped calls now stay fused at any batch size in chunks of at most
  seven tokens; prefill-shaped rows keep stock. On the Studio the chunked build
  had 0 of 6 eight-slot parity mismatches, bit-identical run-to-run output on
  both paths, and eight-slot ordinary decode throughput equal to stock. The
  R003 review gate for this pin is the ordinary-path qualification plus the
  frozen-diff audit; native-MTP R015 gates only native-tuple signing and
  activation, and native MTP stays default-off. Because a native verification
  row carries `proposal_depth + 1` tokens, SPEC-023-R024 caps
  `proposal_depth`, and the consumer caps the MTP manifest's
  `max_proposal_depth` and `adaptation_max_depth`, at `6`. Every R015 policy frozen
  before this change binds the retired envelope and Studio OS build `25E253`;
  the next R015 is frozen on the current build. The R003 review gate for
  this revision closed on 2026-10-05 (ordinary decode 1.25x / 1.15x / 0.97x
  stock at one / two / eight slots; freeze audit 0/0/0).

- **0.1.22 (2026-10-02)** — Moves the immutable fork candidate to
  `ca29e9544777068a0b53aad87310ff1cfaf3fd1d` and binds qualification to its
  production-reduced Qwen3.5/3.6 A3B fused small-token MoE path (#1770). The
  path is default-on only for the exact affine layout at flattened token counts
  `1...7`, is batch-invariant and overlap-safe, and falls back to stock at
  `8+`; the environment value `0`/`false`/`no`/`off` is the emergency kill
  switch. Because the fused accumulation order can flip bf16 near-tied
  argmaxes, every ordinary oracle, R015 baseline, journey, and release for the
  tuple must use the same setting. Stock-baseline evidence cannot qualify the
  fused pin. The candidate still requires Studio runtime tests, a re-derived
  R015 result, and the frozen-diff audit before signing or activation.

- **0.1.21 (2026-10-02)** — MTP-15 right-sizes the mandatory R015 matrix to
  the cells that answer its two questions (#1770). Native-eligible cells
  (every slot count up to the frozen `max_native_active_rows`) run prompt
  strata 1536 and 4096 capped by the tuple's signed `max_prompt_tokens`, cap
  included, at outputs 128 and 512, and carry the speedup claim. Gated cells
  shrink to two representatives, bound + 1 and `qualified_slots` at prompt 1536
  and output 512 with staggered arrivals, keeping every gated proof. The
  sustained window moves to `s<qualified_slots>-p1536-o512` and is a separate
  bench phase that reuses that cell's matrix records under the same policy
  digest. Thresholds, ten blocks, run order, and Holm correction are unchanged.
  The previous 48-cell matrix cost about 2.5 days of Studio time for an A3B
  tuple at bound 1, nearly all re-measuring the ordinary path in gated cells
  and 8192-token prefill that the cap makes ineligible; the new matrix is six
  cells plus the window. Strata are counted on the served (templated)
  prompt, the cap stratum realized at or below the cap: the first frozen A3B
  run (policy `525ac686…`) realized its 4096 stratum from raw text, the
  template pushed it past the cap, and its native rows silently ran ordinary;
  the runtime now records that token-bound reselection. The gated
  representatives rest on a stated gated cost model, and the MTP-7 acceptance
  fixture places native rows up to the bound and exercises the load gate at
  the advertised maximum. MTP-4/MTP-13 bind the
  prompt bound to the new
  SPEC-023-R024 `max_prompt_tokens` (SPEC-023 v0.22.6), and MTP-7 states the
  bound is preregistered and justified by the native-eligible cells.

- **0.1.20 (2026-10-01)** — MTP-15 preregisters the run order (#1770): per
  cell, a seeded Fisher-Yates permutation runs half the blocks (rounded up)
  native first; the sustained window alternates. The analyzer recomputes it
  and independently enforces one ordinary and one native record per block at
  positions 0 and 1, the preregistered order, counterbalancing, and at least
  ten blocks for an admission policy.
- **0.1.19 (2026-10-01)** — MTP-15 gated cells must prove the R007 in-flight
  hold on hardware (#1770): a frozen staggered arrival profile, a native
  admission below the bound and a downgrade at it, depth-zero held rounds
  from the scheduler's lab-only gate recorder, and every hold ending restored
  or cleanly finished; a fully downgraded gated cell fails. The bound
  definition and MTP-7 now say only native-eligible cells set and justify
  `max_native_active_rows`; a gated non-inferiority pass never raises it.
- **0.1.18 (2026-10-01)** — MTP-15 splits the R015 matrix at the frozen
  `max_native_active_rows` (#1770). Native-eligible cells keep the
  improvement gates and native-work proofs and may not downgrade; gated cells
  above the bound prove each admission honored the bound (recorded
  other-active-row counts), keep parity and zero errors, and gate
  non-inferiority to ordinary at the section's mixed-load margins (decode
  throughput LB >= -5%, p95 TTFT and inter-token UB <= 5%), frozen in the
  policy. Without this a correctly gated tuple (bound 1 on an 8-slot tuple)
  could never pass R015.
- **0.1.17 (2026-10-01)** — MTP-15 makes the R015 matrix explicit (#1770):
  an admission policy names `qualified_slots` and `max_native_active_rows` and
  covers every slot count from 1 to `qualified_slots`, prompt strata 1536,
  4096, and 8192, and output budgets 128 and 512. The bench and analyzer fail
  closed on a policy missing a mandatory cell; previously a policy could omit
  the one-slot cell and the analyzer judged only the listed cells.
- **0.1.16 (2026-10-01)** — MTP-15 defines the R015 throughput gate as
  decode throughput (completion tokens after the first, over the decode
  interval; for a run, earliest first token to latest completion). End-to-end
  committed throughput dilutes the native/ordinary ratio by prompt length
  because both paths run the same prefill; it stays reported, not gated, and
  TTFT keeps its own gate. Missing decode throughput fails closed; pre-0.1.16
  bench records may derive it from recorded per-request throughput, TTFT, and
  tokens (#1770).
- **0.1.15 (2026-10-01)** — Chunked-prefill seeding, load-gate fusion, and
  seeded sampling (#1770). MTP-6 seeds proposal state chunk by chunk over
  each prefill chunk's own target hidden states (tail = next prompt token;
  final chunk = sampled first token), so R004 drops the one-prefill-chunk
  prompt bound (the open "Prompt-length eligibility" gap closes) and prompts
  are bounded only by the signed request profile. MTP-7's in-flight load gate
  now runs depth-zero native rows inside the ordinary lockstep forward rather
  than a separate one-column verify forward; MTP-6 buffers their committed
  (token, target hidden) columns and advances the drafter over them before the
  next native proposal. MTP-4 admits sampled rows (temperature/top_p the
  ordinary row sampler supports) on tuples whose SPEC-023-R024 entry carries
  the new `native_mtp_sampled_text_v1` profile; MTP-5 defines target-sample
  exact-match verification with the row's own seeded sampler at each verify
  position, which keeps seeded sampled native output token-identical to
  seeded ordinary output. Top-k, min-p, penalties, logit bias, and logprobs
  stay ineligible.
- **0.1.14 (2026-10-01)** — Adds the R007 native active-row load gate (#1770).
  Studio evidence showed native MTP's advantage shrink with concurrency (A3B
  +13.5%/+4.2%/-0.3% at 2/4/8 slots; 27B dense -1.0%/-2.2% at 2/4) because
  verification of `B * (1 + depth)` rows runs MLX small-M quantized matmul whose
  cost grows with M. The signed SPEC-023-R024 sidecar now carries
  `max_native_active_rows` (`1..qualified_slots`, inside the admission tuple
  identity); admission selects ordinary with the new closed reason
  `capacity_above_native_bound` when the runtime already holds that many other
  rows, and in-flight native rows drop to depth zero while scheduler rows exceed
  the bound, restoring after 8 calm rounds. R004 and R010 gain the reason value;
  R013 binds the field; the R015 bench may measure one-slot cells on a
  two-slot qualified runtime.
- **0.1.13 (2026-10-01)** — Moves the reviewed fork exception pin from
  `c4bc3461673e9f035c5f11bf41dda120d4baee1d` to
  `ef4ff8568c38c640bc90a8176dc3acfe943a288d` (#1770 round overhead). The
  delta, three commits on `perf/mtp-verify-sync-free`, removes per-round host
  synchronization and per-row drafter forwards without changing what is
  committed: packed-verify offset validation reads a host mirror instead of
  one blocking device readback per cache layer; recurrent row commits can
  defer evaluation so a round resolves every row and layer with one `eval`;
  and a packed stateful-drafter API advances all native rows and proposes
  their next tokens in one drafter forward. Packed drafter state equals the
  per-row commit bit for bit when the matmul shapes match and otherwise
  differs only by kernel accumulation order; drafter state never selects an
  emitted token (MTP-5), so this does not touch the R005 oracle. Proposal
  no longer mutates drafter state, so an aborted round keeps the row's
  pre-round drafter state (MTP-6). The delta is in scope for the campaign
  freeze audit.
- **0.1.12 (2026-10-01)** — Closes observer/loader divergences found in
  the campaign round-1 audit (#1770). The MTP-2 observer now accepts exactly
  the pinned loader grammar: only the top-level `quantization` object, the
  case-sensitive `mode` (absent means affine), `group_size`, and
  `.scales`/`.biases` tensors; overrides and `false` entries match the exact
  post-sanitize loader module path (a bare standalone-drafter `fc` override
  the loader ignores now fails closed); no tensor is excluded by name; the
  drafter namespace is case-sensitive; and only the dotted vision-tower
  namespaces are dropped, with any other name the loader's discard predicate
  would swallow rejected. `base` admissions now recompute their
  representation digest instead of trusting it.
- **0.1.11 (2026-09-29)** — Admits SPEC-023-R024 `mlx_affine`
  native-MTP artifacts for issue #1770 by binding observed MLX affine 4-bit
  target/MTP representation manifests, per-module overrides, and unquantized
  exceptions; documents real mlx-community Qwen3.5/Qwen3.6 affine observer
  rules and standalone drafter namespaces. Moves the reviewed fork exception
  pin from `e874140ecb5b04aeb445eb3837d48f7b187b867e` to
  `c4bc3461673e9f035c5f11bf41dda120d4baee1d`, whose only delta is the packed
  recurrent-cache fix: a zero-proposal row right-padded beside a one-proposal
  row now commits its checkpoint state instead of the post-pad state (found by
  the real Qwen3.6-27B hardware e2e; the prior pin corrupted every
  GatedDeltaNet layer of such rows). The delta is in scope for the campaign
  freeze audit.
- **0.1.9 (2026-09-28)** — Makes the signed MTP manifest the exact captured
  `mtp/config.json`, binds the target loader to captured
  `target/tokenizer.json`, and requires loader-equivalent recursive tensor
  observation before any sanitizer/filter can hide an extra target MTP tensor.
- **0.1.8 (2026-09-28)** — Requires signed
  `mtp.complete_window_bytes_by_depth` admission closure for native-MTP
  scheduler-capacity accounting, including deterministic tuple binding and
  checked max-depth-by-slot multiplication.
- **0.1.7 (2026-09-28)** — Requires the SPEC-023 v0.21.1
  `live_executable_cdhash` binding in the signed native-MTP admission sidecar,
  exposes it as capability input, and keeps it distinct from the installed
  binary SHA-256 artifact digest.
- **0.1.6 (2026-09-28)** — Repins the immutable-dependency exception to fork
  revision `e874140ecb5b04aeb445eb3837d48f7b187b867e`. This preserves the audited
  native-MTP API delta from 0.1.5 while restoring the package manifest's Swift
  6.1 consumer floor required by MacProvider's release CI toolchain.
- **0.1.5 (2026-09-28)** — Repins the immutable-dependency exception to fork
  revision `b250ac2e87a1a780eb82ce73522c4bf3e70a8d8e` after qualifying standalone
  Qwen 3.5 MTP checkpoint normalization and packed row-isolated recurrent
  Mamba transactions. The upstream test bundle compiled on Mac Studio, the
  complete delta received independent adversarial approval with 0 Critical,
  0 High, 0 Medium, and 0 Low findings, and the real Qwen 3.5 target/MTP tuple
  passed concurrent ordinary-versus-native-MTP greedy parity on Mac Studio.
  The feature remains default-off pending the remaining release gates.
- **0.1.4 (2026-09-28)** — Repins the exact immutable-dependency exception
  to fork revision `9f8234109403d1aef7e497672f373776e2b1b3f4` after review of
  serialized non-`Sendable` caller-state access on `MTPDrafterContainer`.
  Mac Studio build-tests and focused Swift Testing coverage passed 2/2 for
  the existing and new container access paths. The exception remains
  default-off and makes no production-enablement claim.
- **0.1.3 (2026-09-28)** — Repinned the exact immutable-dependency exception
  to fork revision `3c8a50228cc6e8edea6a8716fa7954770e9b28a8` after review of
  the strict row-local multi-round continuation API
  (`MTPPackedVerificationRowState` and the `requireContinuationState`
  overload). The evidence records 15/15 upstream Xcode qualification tests and
  independent adversarial review with 0 Critical, 0 High, and 0 Medium findings.
  The exception remains default-off and makes no scheduler, artifact, signed
journey, hardware, release, or production enablement claim.

For the exact Qwen3.5/3.6 A3B affine layout recognized by the pinned fork, the
fused sparse-MoE path is the ordinary and native-MTP kernel baseline for every
call whose rows carry `1...7` tokens (decode and native verification) at any
batch size; above seven flattened tokens the call runs as consecutive fused
chunks of at most seven tokens. Rows longer than seven tokens (prefill) use the
stock path. `MLX_LM_QWEN35_FUSED_MOE=0` (and the equivalent case-insensitive
`false`, `no`, or `off`) is the process-level emergency kill switch, not a
separately qualified performance baseline. The fused path preserves expert
selection and is batch-invariant, but its bf16 accumulation order can change
an argmax at near-tied logits, so it is not bit-equal to stock. A decode row
MUST NOT move between the fused and stock kernels as the batch grows or
shrinks: a flattened-token switch point made a row's greedy output depend on
how many of its steps fell on either side of the switch, which broke
ordinary/native parity in the fused-baseline R015 (`s8-p1536-o512`, 8 of 10
blocks). That is the same bounded numerical-drift class
already documented for stock batched quantized kernels: every R005 oracle,
R015 ordinary baseline, serving journey, and signed tuple using this pin MUST
run the same fused-kernel setting. Evidence comparing fused native MTP against
stock ordinary decode is invalid. Changing the layout or the per-row token
envelope requires a new R003 review, and invalidates every R005 oracle, R015
result, journey, and signed tuple recorded under the previous envelope. The dependency-revision change also
changes `KVBuildIdentity`; prior disk-cold-tier entries are expected misses and
MUST NOT be relabeled as belonging to the new revision.
- **0.1.2 (2026-09-28)** — Extends the exact immutable-dependency exception
  to the reviewed public packed target-verification facade at fork revision
  `31223c97262bd5123e76055c5662a42677936eea`. The exception remains
  default-off and does not satisfy scheduler integration, parity, hardware,
  signed-evidence, audit, release, or production gates.
- **0.1.1 (2026-09-28)** — Records the narrow immutable-dependency exception
  for the reviewed public MTP cache-transaction facade at fork revision
  `3c977326bd0ec2c5160c6b2ec48ba6ede1cc11db`. The exception is exact,
  default-off, removable on a qualified upstream tag, and does not promote any
  runtime tuple or conformance requirement.
- **0.1.0 (2026-09-27)** — Initial draft for issue #1770. Establishes native
  MTP as a distinct target-local, multi-row decode path; preserves SPEC-028
  classic speculation; binds transactional cache/state, request, fallback,
  observability, accounting, signed admission, MXFP8-combination, and
  preregistered real-hardware gates. Drafted from current repository history,
  SPEC-038/039 serving precedents, and issue #1770 planning. Round-1 review
  added owner-spec amendments, a signed admission sidecar, numerical and
  eligibility economics gates, explicit security negatives, native-path
  canary evidence, and a non-circular release sequence.
