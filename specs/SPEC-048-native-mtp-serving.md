# SPEC-048 — Native Multi-Token Prediction Serving

**Version:** 0.1.13

```json
{
  "spec_id": "SPEC-048",
  "title": "Native Multi-Token Prediction Serving",
  "version": "0.1.13",
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

The v0.1 production outcome is not a serial demonstration. It is a greedy,
text-only, multi-row path that preserves isolated ordinary-decode semantics
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
- an upstream MLX Swift MTP dependency with stable row-mapped transaction
  primitives;
- exact greedy token and terminal parity against ordinary decode;
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
- stochastic speculative acceptance or sampling-mode parity;
- tools, structured output, logprobs, penalties, conversation-cache reuse, or
  disk-cache reuse on the v0.1 native-MTP path;
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
- **SPEC-037** owns persistent KV and currently excludes every speculative
  request from lease, promotion, and commit.
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
| Qualified tuple | Exact hardware, OS/toolchain, provider release, MLX runtime, model/artifact, quantization, cache mode, MTP depth, and slot-count combination covered by evidence. |

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
- exact provider and upstream MLX runtime revision used for qualification; and
- the SPEC-023 `live_executable_cdhash` expected CodeDirectory identity for
  the signed provider executable admitted to consume the tuple.

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
packed weights. Overrides are admitted only for `4` or `8` bits, group sizes
`32`, `64`, or `128`, and an absent or exactly `affine` mode. The observed
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

The observer MUST inspect the same recursive set of `.safetensors` files that
the pinned 3.31.4 loader can consume. It MUST reject symlinked or hidden weight
files, scan every parsed tensor name before representation filters, and reject
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

Production implementation MUST use an immutable reviewed MLX Swift release,
not a floating branch. A compile-tested qualification artifact MUST exercise
stable operations for proposal, target verification, stage, contiguous-prefix
commit, rejected-tail discard, and exact rewind with explicit row and position
maps. The production adapter MUST use only interfaces covered by that artifact.
A high-level serial iterator alone is insufficient evidence.

The qualification MUST include the upstream MTP and cache tests, Swift strict
concurrency diagnostics, supported macOS deployment target, dependency/license
review, and cache-boundary rejection tests. If the necessary row-mapped
operations require unstable or private dependency internals, production work
is blocked until a reviewed upstream API is available. A commit pin may be
used only under an explicitly reviewed immutable-dependency exception; a
tagged release is the default production requirement.

The first such exception is closed and exact:

- repository: `https://github.com/Augustas11/mlx-swift-lm.git`;
- revision: `ef4ff8568c38c640bc90a8176dc3acfe943a288d`;
- upstream base: `ml-explore/mlx-swift-lm@bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`
  (`3.31.4`);
- reviewed surface: `MTPKVCacheStorage`, `MTPKVCacheTransaction`,
  `MTPKVCacheTransactionPosition`, `MTPKVCacheTransactionCommit`, and
  `reconcileMTPSharedKVState`; plus `MTPPackedVerificationCache`,
  `MTPPackedVerificationRowMap`, `MTPPackedVerificationRowState`,
  `MTPPackedVerificationOutput`, `MTPPackedVerificationError`, and
  `verifyMTPPackedTargets`, including the strict
  `requireContinuationState` overload for row-local multi-round continuation;
  plus `MTPDrafterContainer.perform(nonSendable:_:)` for serialized movement
  of caller-owned drafter state without model-global mutation or unsafe
  `Sendable` capture; plus standalone Qwen 3.5 MTP checkpoint normalization,
  `MTPPackedMambaBatchCache`, `MTPPackedMambaRowTransaction` (including the
  deferred-evaluation `stageCommit(retaining:)`), and the
  `mtpPackedCheckpointIndex` contract needed for row-isolated commit across
  hybrid attention/Mamba verification; plus the
  `mtpPackedHostBatchOffsets` host offset mirror the packed facade validates
  instead of reading `batchOffset` back from the device; plus
  `MTPPackedStatefulDrafterModel`, `MTPPackedDrafterAdvanceRow`,
  `MTPPackedDrafterAdvanceResult`, `MTPPackedDrafterError`, and the Qwen 3.5
  `advanceAndProposePacked` implementation that advances every native row's
  drafter state and proposes its next token in one drafter forward;
- review date and owner: `2026-09-28`, `@Augustas11`;
- mandatory exception re-review date: `2026-12-27`;
- review gate: upstream-focused build-tests, MacProvider qualification and
  real-hardware tests, plus an independent adversarial review with zero
  Critical, High, or Medium findings; the prior transaction surface passed
  15/15 focused upstream tests, the expanded surface compiled in the complete
  upstream test bundle, and the real Qwen 3.5 target/MTP tuple passed the
  Mac Studio ordinary-versus-native-MTP parity test; and
- removal trigger: replace the fork pin with the first reviewed upstream tag
  that contains equivalent standalone-checkpoint loading, public transaction,
  packed target-verification, and hybrid recurrent-cache surfaces and passes
  the same MacProvider qualification artifact.

No other fork URL, revision, API, or transitive source substitution is covered
by this exception. The exception qualifies standalone-checkpoint loading and
the public cache-transaction, packed target-verification, row-local
continuation-state, and hybrid recurrent-cache boundaries only. It
does not make a model/artifact tuple eligible, satisfy the serial or multi-row
parity gates, admit MXFP8, or enable production serving.

### MTP-4 — v0.1 request eligibility and fallback boundary (SPEC-048-R004)

Native MTP v0.1 accepts only the chat-completions request profile below. Values
are tested after ordinary request parsing/default resolution; an absent
`temperature` is ineligible unless the parser demonstrably resolves it to
exactly zero. The generation-affecting allowlist is: `temperature == 0`,
`top_p == 1`, absent/default `top_k`, absent/zero `min_p`, zero frequency and
presence penalties, absent/default-one repetition penalty, `n == 1`, no logit
bias, no `logprobs` or `top_logprobs`, no reasoning/thinking toggle or chat
template kwargs, no tools/tool choice/tool-call history, plain-text response
format, no Harmony protocol, and text-only messages. The allowed transport or
limit keys are `model`, `messages`, `max_tokens`, `max_completion_tokens`,
`stream`, `stream_options` containing only `include_usage`, `stop`, and `user`;
they retain ordinary validation. A `seed` is eligible only where the ordinary
greedy path treats it as a documented no-op. Legacy completions, `echo`,
`suffix`, an unknown top-level key, or any generation-affecting key/value not
explicitly admitted above routes ordinary. A nonempty `conversation_key` also
routes ordinary. The request additionally requires an admitted
capability, a supported cache/state class, and enough capacity for the next
complete verification round. Streaming and non-streaming are eligible only
after their respective acceptance fixtures pass.

The provider MUST make decode-path selection before output and record exactly
one closed selector reason. `eligible` selects `native_mtp` only after every
request, tuple, sidecar, revocation, state, and capacity gate passes; each other
reason selects ordinary:
`eligible|mode_off|classic_draft_configured|sampling|multiple_completions|tools|
structured_output|logprobs|logit_controls|reasoning_or_template|unknown_request_field|
conversation_key|multimodal|unsupported_processor|unsupported_state_cache|
insufficient_verification_capacity|capability_mismatch|tuple_not_admitted|
tuple_revoked|revocation_state_unavailable`.
Reason strings are local diagnostics, at most 48 ASCII bytes, and do not enter
buyer, receipt, or coordinator wire surfaces.

Current gateway reality is explicit: the authenticated paid gateway assigns an
auto-prefix conversation key to ordinary user-message traffic, so most such
traffic is ineligible under this revision even when the buyer did not request
sticky affinity. R015 MUST measure eligibility from post-gateway provider-bound
requests with their real key state; a synthetic keyless corpus cannot satisfy
the production-eligibility floor. This spec does not silently discard that key
or its possible SPEC-024 discount to inflate MTP coverage.

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

For the serial deterministic acceptance corpus, native MTP MUST produce the
exact token-ID sequence, ordering, decoded bytes, completion-token count, and
terminal reason produced by isolated ordinary greedy decode on the same model
snapshot and request. The preregistered corpus MUST contain at least 200
prompts, at least 20 per short/1.5k/4k/8k/near-boundary stratum, and at least
6,400 compared generated positions, including all/none/partial acceptance,
stop/EOS/max-token terminals, and deliberately near-tied logits. No prompt is
excluded by observed margin: any token-ID divergence is a hard tuple failure.

The numerical oracle for both serial and multi-row tests is teacher-forced:
for every emitted prefix, run that row's ordinary path on the same served
snapshot and prefix, cast both target-logit vectors to float32, and compare the
next-token result before advancing. Top-1 token ID MUST be exact. Maximum
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
byte encoding. Depth-zero rows retain only committed target state; when depth
increases, proposal state is recomputed from the current committed target
hidden state rather than reused from a stale speculative tail.

Transactions MUST preserve row identity across proposal, packed verification,
commit, discard, cancellation, and release. State or metrics from one row MUST
NOT be addressable through another row's handles. Rejection at every proposal
position and every boundary of an admitted cache/hybrid state class MUST pass
exact subsequent-token and state parity tests. `RotatingKVCache`, sliding-window
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

Native MTP MUST use SPEC-038 FCFS admission and shared-iteration fairness; it
MUST NOT create a second priority queue or skip an older ready ordinary row for
an MTP-only forward. When a packing limit prevents all ready rows from sharing
one forward, oldest-ready rows are selected first. Under the preregistered
mixed-load fixture, ordinary-row p95 ready-to-decode wait MUST NOT regress by
more than 10% against the same SPEC-038 workload with MTP disabled.

Every production tuple MUST advertise at least two slots and no more than the
SPEC-038 validated Entry-110 depth for that exact tuple. At the advertised
maximum, the acceptance fixture MUST place native MTP on at least half of the
rows, use proposal depth at least one, force rejection at every proposal
position under load, produce unequal accepted lengths, stagger row entry and
exit, and prove through backend trace evidence that eligible rows shared a
packed target verification forward rather than concurrent serial iterators.
The result MUST match the ordinary batched oracle with no row bleed, deadlock,
leak, starvation, or counter corruption. An eight-slot experimental cell is
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

### MTP-9 — cache-reuse and persistence exclusion (SPEC-048-R009)

Until SPEC-024 and SPEC-037 explicitly admit native-MTP state, the unified
decode-path selector MUST classify any request with a nonempty
`conversation_key` as ordinary before continuous-batch admission or any
conversation-cache/disk-cache `begin()`, lease, promotion, reuse, or commit. A
native-MTP request therefore has no conversation key, MUST acquire no lease,
must commit no reusable entry, and must leave no key busy. `cached_prompt_tokens`
MUST remain zero for the native-MTP attempt.

This exclusion applies to both streaming and non-streaming paths and to
pre-output failures, cancellations, and successful completions. A future
cache-reuse amendment must prove target KV plus every MTP/recurrent state
component and must preserve SPEC-024 billing isolation before changing this
requirement.

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
`active|disabled_by_default|tuple_not_admitted|tuple_revoked|revocation_state_unavailable|request_ineligible|unsupported_cache_state|capacity_unavailable|low_acceptance_depth_zero|runtime_failure|warm_swap`.
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
under the same eligibility decision. Because every nonempty conversation key
routes ordinary under R004/R009, a cache-eligible request retains its ordinary
cache-hit decision and discount; it is never converted into an MTP cache miss.
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

### MTP-13 — signed admission and immutable evidence (SPEC-048-R013)

Catalog/autotune admission MUST be based on the SPEC-023 v0.22.3
`macprovider.native-mtp-admission.v1` signed sidecar bound to one immutable SPEC-023
`release_id` and SPEC-010 model/artifact member, never provider self-report.
The sidecar MUST bind the exact decode path, model/artifact/tokenizer digests,
MTP manifest and family adapter, proposal depth, quantization representation,
runtime/provider revisions, cache/state classes, exact hardware/RAM,
qualified slot count, request-feature profile, benchmark policy digest, source
commit, reproducible-build digest, the exact lowercase 40-hex
`spec023.live_executable_cdhash` CodeDirectory identity for the live signed
executable, `mtp.complete_window_bytes_by_depth`, and evidence artifact
digests. The live executable CDHash is
distinct from the installed binary SHA-256 artifact digest; consumers MUST bind
both and MUST NOT substitute one for the other.

Capability advertisement MUST fail closed if the live tuple differs from any
bound field, including a missing or mismatched `live_executable_cdhash`. Loader
success or a serial correctness pass is not sufficient for
catalog eligibility. Classic SPEC-028 evidence MUST NOT be relabeled as native
MTP evidence, and upstream/non-MLX benchmark numbers MUST NOT satisfy local
admission.

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
   absent from the current authenticated emergency-revocation feed;
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
   that exact tuple and is no older than 90 days. CONFORMANCE state is repository-wide and therefore
   necessary but never sufficient for another tuple; each advertised tuple
   requires its own unexpired sidecar and journey result.
7. The frozen implementation/evidence diff passes code, security, and
   architecture review with zero Critical, High, or Medium findings.
8. After merge and final signing, the exact release candidate is revalidated
   in isolated loopback against the sidecar source-commit/build digest;
   release-asset byte identity and the previous-stable updater pass when the
   CLI ships in both Malibu.app and the standalone tarball. R014 is promoted
   to `conformant` from this post-release-candidate evidence before production
   configuration can enable the tuple. A separate signed
   `JOURNEY-NATIVE-MTP-RELEASE` result covers R014 and is the evidence that may
   promote it to conformant.
9. No unreleased local binary is connected to the live coordinator.

Failure or expiry of any tuple-specific gate MUST remove or disable only that
tuple's native-MTP eligibility and MUST preserve ordinary decode. No partial
Phase 0/1 implementation may claim issue completion or a production MTP
multiplier.

`activation` means the first production configuration load at which an exact
tuple becomes selectable. Sidecars and serving-journey results expire after 90
days. Renewal creates a new immutable release/sidecar, reruns the local
self-test and signed serving journey, the 30-minute sustained cell, ordinary
and MTP parity sample, and post-gateway eligibility sample. The full matrix may
be reused for at most 180 days only when hardware, OS/toolchain, provider/MLX,
model/artifact/tokenizer/MTP manifest, quantization, cache/state topology,
depth, slots, thresholds, and benchmark policy are byte-identical; any change
or regression forces the full matrix. This lifecycle is independent of
SPEC-032 hardware-attestation TTL.

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
decode and combined native MTP plus MXFP8 when those artifacts exist, at slot counts
1, 4, and 8 or every lower maximum the tuple advertises; prompt lengths near
1.5k, 4k, and 8k tokens; fixed short and long outputs; and a sustained thermal
window of at least 30 minutes. Each cell MUST have at least ten counterbalanced measured runs after
warmup. The pairing unit is one counterbalanced run block on one host/thermal
window containing ordinary then MTP in randomized order; the bootstrap
resamples whole blocks with 10,000 draws. Gates apply separately to every
advertised `(hardware, artifact, slots, prompt/output stratum)` cell; no pooled
pass may hide a failing cell. Holm correction at family-wise alpha 0.05 covers
the throughput, TTFT, inter-token, and rejection hypotheses across all cells.
The campaign MUST report median and corrected confidence interval for
aggregate committed tokens/s, per-request tokens/s, p50/p95 TTFT and
inter-token latency, proposed/accepted/per-position/mean acceptance, target
forwards per committed token, peak/resident memory, capacity rejection,
fallback/error rate, terminal parity, and thermal stability.

Correctness, state integrity, and zero unexplained fallback/error are hard
gates. Using the paired-bootstrap corrected 95% confidence interval, the lower bound for
aggregate committed throughput improvement over the best ordinary baseline
MUST be at least 15% in each cell at the intended advertised slot count; both
paths use that same slot count, and the baseline is the best ordinary
production-qualified configuration at that count. The corrected upper bound
for native-MTP p95 TTFT regression MUST be no more than 10%, and the corrected
upper bound for p95 inter-token regression MUST be no more than 0%; bare point
estimates do not pass. Capacity rejection MUST increase by no more than one
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
   Qwen 3.5 separate-artifact tuple;
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
| `SPEC-048-R014/R015` | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | Production enablement and preregistered Studio/advertised-tier benchmarking remain pending. |
| `native-mtp-serving` | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | Authority acceptance, release-candidate review, and signed real-hardware journey evidence for the first production tuple. |
| First Qwen-family MTP artifact | `UNKNOWN` | `@Augustas11` | `#1770` | Legally/provenance-clean immutable model, tokenizer, MTP manifest, and exact hashes. |
| Upstream MLX Swift release | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | A reviewed fork exception is pinned for this campaign; replacement by an upstream tag remains required by the re-review/removal trigger. |
| First MLX-native MXFP8 artifact | `UNKNOWN` | `@Augustas11` | `#1770` | SPEC-023/SPEC-010 format, fit, quality, license, provenance, and hardware evidence. |
| Prompt-length eligibility | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | The implementation routes native MTP only when the whole prompt fits one prefill chunk (`ModelRuntime.nativeMTPFullPromptPrefillTokenLimit`, 512 tokens); longer prompts silently select ordinary. R004 does not state this bound. Either specify it in R004 with its own selector reason or capture drafter hidden state across chunked prefill. |
| Batched-verify numerical parity | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | On the Mac Studio M3 Ultra, MLX `get_qmv_batch_limit` switches quantized matmul from qmv to qmm once the packed verify reaches 12 tokens for K/N above 4096. Qwen3.5-9B stayed bit-exact at 5 slots (10 packed tokens) and drifted by one bf16 step from 6 slots, flipping near-tied argmaxes. R005 as written forbids any such divergence, so multi-row verification at >=12 packed tokens cannot pass it. Decide between a bounded drift allowance and kernel-matched verification. |
| Depth-1 throughput value | `DECISION_REQUIRED` | `@Augustas11` | `#1770` | 2026-09-29 Studio pilot, Qwen3.6-35B-A3B, 384-token greedy prompts: native MTP 0.66x/0.61x/0.57x ordinary continuous batching at 2/4/8 slots with 87-90% acceptance. Profiling projects about 1.3x at 2 slots and break-even at 8 after overhead fixes. Evidence and parked work: branch `park/native-mtp-perf-2026-09-29`. |

## 7. Evidence

Branch-local implementation and focused verification evidence exists for this
campaign, including Swift parser checks for the changed provider files and
focused coordinator native-MTP canary/config Go tests. No production release,
signed journey, or settlement/integrity evidence exists yet. The issue #1770
planning/review artifacts and this branch's local checks are design and
implementation evidence only, not production conformance.

The first implementation PR must record the selected upstream release and
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
