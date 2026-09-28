# BUILD PROMPT — Implement SPEC-048 native MTP serving

This is an implementation and hardware-campaign prompt, not a research or
spec-writing prompt. Implement the largest safe, evidence-backed slice of
[SPEC-048](../../specs/SPEC-048-native-mtp-serving.md) toward issue
[#1770](https://github.com/Augustas11/macprovider/issues/1770). Keep one
campaign branch and one draft PR for the complete code, automated tests,
serving evidence, audits, and lab iterations. Do not close #1770 for a serial
oracle or other partial milestone.

The normative authority is the landed repository, especially SPEC-048 and its
owner specs. This prompt supplies execution order and stop conditions; it does
not relax or replace any requirement.

## Required outcome

Deliver a default-off, fail-closed `native_mtp` path that:

- remains distinct from `ordinary` and SPEC-028 `classic_draft_spec`;
- uses the target model's qualified MTP component and target-authoritative
  verification;
- preserves exact greedy token IDs, bytes, usage, stop/terminal behavior,
  receipts, billing, rewards, routing, trust, and settlement;
- supports row-local propose, verify, stage, contiguous-prefix commit,
  rejected-tail discard, and exact rewind in mixed multi-row continuous
  batches;
- is admitted only for an immutable, signed, non-revoked tuple with current
  journey evidence; and
- is production-enabled only after the full SPEC-048 release gate passes.

The production outcome is greedy, text-only, multi-row serving. A serial path
is a correctness oracle and diagnostic milestone only.

## Hard stop conditions

Stop the production implementation at the relevant gate, document the exact
blocker in the draft PR and issue #1770, and preserve ordinary decode if any of
these conditions holds:

1. No reviewed immutable MLX Swift release exposes stable, public, row-mapped
   proposal, target-verification, stage, prefix-commit, discard, and rewind
   operations with explicit row and position maps.
2. The needed behavior is available only through private or unstable upstream
   internals, or only through a high-level serial iterator.
3. The candidate model, tokenizer, MTP tensors, cache/state adapter, or runtime
   revision cannot be bound to immutable digests and a complete manifest.
4. Exact ordinary-versus-MTP greedy parity or transactional rewind fails.
5. The exact tuple lacks the required automated, signed, hardware, audit, or
   release evidence.

Do not paper over an upstream API gap with a MacProvider-local fork, copied
private internals, or an unreviewed floating dependency. A commit pin is
allowed only through the explicit immutable-dependency exception required by
SPEC-048-R003; a tagged release is the default.

## Safety boundaries

- Never connect a locally built, unsigned, ad-hoc-signed, or unreleased
  `macprovider-cli` to the live Malibu coordinator. Local work runs as an
  isolated provider with `--no-join` or against a local coordinator/gateway.
- Do not replace the live `127.0.0.1:8080` provider with a local candidate.
- Do not change buyer API shape, token accounting, receipts, billing, rewards,
  payout, routing, trust tiers, or settlement for MTP.
- Do not add buyer-visible MTP fields. MTP selector reasons and metrics remain
  bounded provider-local diagnostics unless an owner spec is amended first.
- Do not inspect `d-inference` source.
- Do not commit model weights, raw prompts/completions, credentials, private
  paths, payout material, tensor values, or operator secrets.
- Do not add a second inference runtime, custom MXFP8 kernels, or a new
  dependency without explicit review and contract need.
- Do not mark conformance from tests alone. Physical journey evidence and the
  post-release-candidate journey are separate gates.

## Start correctly

1. Read `AGENTS.md`, `CLAUDE.md`, SPEC-048, `specs/AUTHORITY.json`,
   `specs/CONFORMANCE.json`, both native-MTP journeys, and every owner spec
   referenced by SPEC-048.
2. Run `git status -sb`, `git worktree list`, and `git fetch --prune origin`.
3. Create a fresh hidden worktree from current `origin/main` under
   `/Users/augstar/.codex/worktrees/macprovider/` on a dedicated
   `campaign/1770-native-mtp` branch. Never implement in the canonical checkout
   or reuse another session's worktree.
4. Inspect the current MLX Swift pin, Package.resolved, provider inference
   architecture, scheduler, paged-KV and hybrid-state adapters, catalog,
   autotune, canary, journey, signing, and evidence patterns before editing.
5. Recheck issue #1770 and any linked upstream MTP and transactional-cache
   trackers against official upstream code, releases, tests, and licenses.
   Record exact release/tag/commit evidence; do not rely on stale issue prose
   or benchmark claims.
6. Open one draft campaign PR after the first coherent, tested commit. Keep all
   implementation and real-Mac findings in that PR until freeze.

## Closed decode-path behavior

Implement one closed internal selector:

```text
decode_path = ordinary | classic_draft_spec | native_mtp
```

Selection happens before inference work can escape the request. `native_mtp`
must not reuse or increment `draft_model`, `num_draft_tokens`, `spec_decode_*`,
the classic single-slot flag, or any external-draft artifact/capacity state.
When a non-empty `draft_model` is configured, native MTP is ineligible;
SPEC-028-admitted requests use classic draft speculation and all others use
ordinary decode. The two accelerated paths must never be selected or resident
for the same served snapshot.

Native MTP remains default-off unless every gate for the exact tuple passes.
Any rejection, expiry, revocation, or failure disables only that tuple and
preserves otherwise-valid ordinary decode.

## Phase 0 — dependency, artifact, and API qualification

Complete this phase before production scheduler work.

1. Select an immutable MLX Swift candidate and build a compile-tested
   qualification artifact that exercises the exact stable operations required
   by SPEC-048-R003 with explicit row and position mappings.
2. Run upstream MTP/cache tests, strict-concurrency diagnostics, supported
   macOS deployment checks, dependency/license review, and cache-boundary
   rejection tests.
3. Identify the first provenance-clean Qwen-family artifact and bind exact
   model, revision, tokenizer, artifact, MTP tensor-manifest, family-adapter,
   runtime, quantization, cache/state, proposal-depth, and sharing-layout
   identities.
4. Prove fail-closed rejection of missing, extra, duplicate, silently filtered,
   wrong-shape, wrong-dtype, wrong-quantization, unmanifested, and
   digest-mismatched required tensors.
5. Implement or extend immutable byte-source loading exactly as R002 requires:
   descriptor-relative no-follow resolution, bounded regular files, private
   same-volume staging or exact consumed-buffer hashing, mutation/race checks,
   and no validated-path reopen.
6. Add path traversal, symlink/hardlink escape, rename replacement,
   truncation, same-size rewrite, timestamp restoration, malformed metadata,
   size overflow/mismatch, decompression bomb, unexpected reference, and
   allocation-bound negative fixtures.

If the stable row-mapped API is unavailable, finish the reproducible
qualification artifact and negative evidence, update #1770 with the exact
missing upstream surface and release condition, and stop. Do not start Phase 2.

## Phase 1 — serial greedy correctness oracle, default-off

1. Add explicit `DecodePath` and immutable `NativeMTPCapability` types without
   weakening the ordinary or classic paths.
2. Implement the exact SPEC-048-R004 request classifier after normal parsing
   and default resolution. Unknown or unsupported generation-affecting fields,
   conversation keys, sampling, tools, structured output, logprobs, reasoning
   controls, multimodal input, unsupported cache/state, capacity failure,
   admission failure, revocation, or unavailable revocation state route to
   ordinary with one bounded closed selector reason.
3. Implement target-local proposal and target-authoritative verification. MTP
   scores may propose candidates but never directly commit buyer-visible
   tokens.
4. Implement a pre-request checkpoint and staged state. Commit only the exact
   ordinary-equivalent prefix; discard the rejected tail and rewind every
   target/MTP/cache/recurrent offset exactly.
5. Prove exact token-ID, byte, usage, and terminal parity for all accepted,
   none accepted, every rejection position, bonus-token cases, EOS, token
   stop, boundary-spanning stop strings, max tokens, cancellation, disconnect,
   and early consumer stop.
6. Permit one pre-output fallback only after exact restoration and proof that
   no output, receipt, usage, request-log terminal state, or cache state
   escaped. After the first native mutation the path is sticky; later failure
   terminates through the existing inference-error path without retry or
   stitching.

Keep the serial implementation behind test-only/default-off admission. Do not
claim #1770 complete and do not advertise a throughput multiplier.

## Phase 2 — production-shaped multi-row serving

Begin only after Phase 0's public row-mapped transaction API and Phase 1's
oracle pass.

1. Integrate per-row native-MTP transactions into the existing continuous
   batching scheduler, paged-KV engine, and every admitted hybrid recurrent
   state class. Do not add a parallel scheduler.
2. Support ordinary and native-MTP rows in one round with unequal offsets,
   proposal depths, accepted prefixes, admission times, and completion times.
3. Make stage/commit/discard/rewind row-local and atomic. Prove no cross-row
   state, token, terminal, counter, or metric bleed.
4. Account for the complete verification window before selection. When
   capacity shrinks after stickiness, reduce depth in-path; depth zero is an
   ordinary-shaped native-MTP step, not a path switch. Fail boundedly if even
   that cannot fit.
5. Preserve SPEC-038 fairness, ready-row wait bounds, advertised slots, memory
   limits, cancellation release, and warm-swap tuple isolation.
6. Keep all native-MTP requests excluded from SPEC-024 conversation reuse and
   SPEC-037 persistent-KV lease, promotion, and commit.
7. Add bounded local metrics for proposed, accepted, per-position acceptance,
   depth, forwards per committed token, selector reason, fallback, error, and
   tuple generation. Reset them safely on warm swap. Do not add heartbeat or
   state-update fields unless SPEC-001 admits them first.
8. Add deterministic randomized state-machine comparison with ordinary decode,
   maximum-slot mixed-row stress, allocator/cache wrap boundaries, leak and
   deadlock checks, and long-running cancellation/warm-swap tests.

## Phase 3 — independent MLX-native MXFP8 qualification

Treat MXFP8 and native MTP as independent gates.

1. Use the existing MLX runtime only; do not implement custom kernels.
2. Prove the candidate is genuinely MLX-native MXFP8, not merely named `FP8`,
   and bind exact format, tensor coverage, loader behavior, provenance,
   license, fit, quality, and hardware identities under SPEC-010/SPEC-023.
3. Add positive native-format fixtures and incompatible/generic-FP8 negative
   fixtures.
4. Qualify ordinary MXFP8 independently before testing the combined
   `native_mtp + mlx_mxfp8` tuple.
5. Run the entire serving journey again for the combined tuple. Never reuse a
   base-artifact journey as combined evidence.

Failure here may leave a separately qualified base native-MTP tuple
experimental; it must not admit or advertise the combined tuple.

## Phase 4 — admission, self-test, canary, and evidence tooling

1. Implement the exact SPEC-023-R024 tuple/sidecar and revocation consumption
   required by SPEC-048. Schema validation is closed, canonical, signed,
   expiry-aware, replay-resistant, and fail-closed.
2. Implement `native_mtp_selftest_v1` in isolated no-join mode with signed
   expected token, terminal, acceptance-counter, and committed-state digests.
3. Implement the bounded `native_mtp_canary_v1` lifecycle and tuple-scoped
   disablement required by R016. Canary traffic uses no buyer data and creates
   no usage, receipt, billing, reward, settlement, or payout activity.
4. Keep SPEC-030/SPEC-036 MTP observations diagnostic and inconclusive for
   integrity/enforcement. Do not upgrade provider-authored path counters into
   trusted proof.
5. Build closed validators and signer tests for
   `JOURNEY-NATIVE-MTP-SERVING`, including recomputation of every digest and
   observation from immutable referenced artifacts. Self-asserted booleans are
   insufficient.
6. Produce redacted evidence only at the exact journey paths and schemas.
   Preserve failed and incomplete cells. Never fabricate a passing manifest or
   promote conformance without physical evidence.

## Phase 5 — preregistered hardware campaign

Freeze the SPEC-048-R015 benchmark policy before measuring. The record must
bind hardware/SoC/RAM, OS, Xcode/Swift, provider and MLX revisions,
model/tokenizer/artifact/MTP digests, quantization, cache mode, depth, slots,
corpus, output budgets, run order, warmup, exclusions, sample count,
confidence method, and thresholds.

Run the complete matrix on the 256 GB Mac Studio and every lower hardware/RAM
tier intended for advertisement. Compare:

- best production-qualified ordinary continuous batching at the same slot
  count;
- native MTP;
- ordinary MXFP8 when qualified; and
- combined native MTP plus MXFP8 when qualified.

Use slots 1, 4, and 8 or every lower advertised maximum; prompt lengths near
1.5k, 4k, and 8k; fixed short and long outputs; at least ten counterbalanced
measured run blocks after warmup; 10,000 whole-block bootstrap draws; Holm
correction; and a sustained thermal window of at least 30 minutes per required
cell.

Enforce every R015 hard and corrected-confidence gate exactly. In particular,
do not substitute a one-slot baseline, pooled result, point estimate, upstream
speedup claim, or synthetic keyless request corpus. Replay the preregistered
privacy-reviewed post-gateway request mix with real conversation-key state and
measure its eligibility and end-to-end economics.

Local HTTP loopback proves provider formatting, inference correctness, and
bounded local concurrency only. It does not prove Malibu buyer routing,
billing, receipt, or settlement gates.

## Automated verification

Run targeted tests while iterating, then all relevant repository gates. At a
minimum include:

```bash
cd phase3-binary && swift test
make test
make vet
make test-dist
```

Also run the new qualification, negative-loader, serial oracle, randomized
transaction, mixed-row, capacity, canary, evidence-schema, signer, benchmark,
and journey tests directly. Run Swift strict-concurrency checks and a release
build on the campaign Mac. Never report an interrupted, skipped, simulated, or
timed-out command as passed.

For each requirement, maintain a table with requirement ID, implementation
paths, automated tests, physical evidence, current verdict, and remaining
blocker. Leave a requirement `pending` until its required evidence actually
exists.

## Freeze and three-lane audit

When the complete implementation plus serving-evidence diff is frozen:

1. Resolve the exact base/head/tree, binary diff digest, and reviewed-path-set
   digest required by `JOURNEY-NATIVE-MTP-RELEASE`.
2. Run independent native Codex code, security, and architecture auditors over
   the full landing diff, not the last fix slice.
3. Store durable prompts and verdict summaries under `audits/spec-048/`.
4. Fix every Critical, High, and Medium finding. After any reviewed-path
   mutation, rerun all three lanes because R014 binds one identical frozen
   subject.
5. Stop only at 0 Critical, 0 High, and 0 Medium findings in every lane. Carry
   Low/Info findings explicitly in the PR body with rationale.

Code audit must verify spec-to-code traceability, exact ordinary parity,
transaction atomicity, multi-row behavior, capacity/fairness, test adequacy,
and absence of fake conformance. Security audit must attack artifact TOCTOU,
path/reference parsing, memory bounds, cross-row isolation, revocation/replay,
sidecar/signature validation, diagnostic leakage, canary abuse, and
unreleased-local-to-live pairing. Architecture audit must verify owner-spec
boundaries, the three-path state machine, scheduler/cache integration,
warm-swap identity, evidence lifecycle, and release ordering.

## PR, merge, and release boundary

- Use one draft PR titled
  `feat(provider): implement SPEC-048 native MTP serving (refs #1770)`.
- Keep the SPEC governance declaration accurate whenever specs, manifests,
  journeys, schemas, executable scripts, or product behavior change.
- The PR body must report phase status, selected upstream/artifact hashes,
  requirement matrix, exact test commands/results, hardware matrix and raw
  redacted evidence, audit convergence, unresolved Low/Info findings, and all
  blockers.
- Do not close #1770 until the multi-row implementation, every advertised
  hardware tuple, signed serving journey, release gate, and production
  economics criteria pass. A blocked upstream dependency or serial oracle is
  progress, not completion.
- Do not merge red CI or bypass branch protection. Obtain the required
  independent approval and squash-merge only after the campaign evidence is
  frozen and the lab journey passes.
- After merge, build/sign/notarize/package the exact reviewed candidate, prove
  Malibu.app/tarball CLI byte identity and previous-stable updater behavior
  where applicable, and run the isolated-loopback release journey.
- Only the signed `JOURNEY-NATIVE-MTP-RELEASE` result may promote R014 and
  permit production configuration to select the exact tuple.

## Final report

Return one evidence-backed report containing:

1. PR and commit identifiers;
2. exact upstream release and artifact/tuple identities;
3. completed phase and requirement matrix;
4. targeted, full-suite, journey, and hardware command results;
5. benchmark gates with corrected intervals and failed/incomplete cells;
6. code/security/architecture verdict counts and artifact paths;
7. signed sidecar, serving-journey, and release-journey identities, if earned;
8. confirmation that no unreleased local binary contacted the live coordinator;
9. issue #1770 and any linked upstream-tracker status; and
10. the single exact blocker if full production admission remains incomplete.

Do not use optimistic wording for unmeasured hardware, absent signatures,
pending conformance, unavailable upstream APIs, or unrun release gates.
