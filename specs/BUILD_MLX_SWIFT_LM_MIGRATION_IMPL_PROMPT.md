# BUILD: Migrate `mlx-swift-examples` 2.29.1 → `mlx-swift-lm` 3.31.4

Author: operator (a11) + Claude session 2026-07-03
Status: DRAFT — plan for review; do NOT begin implementation until this PR is reviewed and merged (or explicitly amended in review).

## 1. Mission

`macprovider-cli` currently depends on `github.com/ml-explore/mlx-swift-examples` pinned at `exact: "2.29.1"` (2025-10-16). Since that tag was cut, Apple split the LLM/VLM libraries out of `mlx-swift-examples` into a **new repo** at `github.com/ml-explore/mlx-swift-lm`. All active LLM development has moved to the new repo:

- `mlx-swift-examples`: last release 2025-10-16 (`2.29.1`), no new tags for 8+ months. The repo is not archived; last push 2026-06-15 is examples-only work.
- `mlx-swift-lm`: created 2025-10-02, forked from `mlx-swift-examples` at `2.29.1`, actively shipping. Latest tag `3.31.4` (2026-06-29). Adds 19 new architectures and 8 months of bug fixes to existing families.

The gap has hardened into a false constraint in our decision log: DECISION_CRITERIA Entries 96 and 97 mark `gemma-4-26b-a4b-it` and `nvidia/nemotron-3-nano-30b-a3b` as "blocked upstream". A 2026-07-03 spike proved the blockers are stale — both architectures ship in `mlx-swift-lm` today (`Gemma4.swift`, `Gemma4Text.swift`, `NemotronH.swift`, `Mamba2.swift`). We are stuck at the fork point.

This build closes that gap. It is a dependency migration with runtime-regression risk, not new product code.

## 2. Non-goals

- This build does not add Nemotron 30B-A3B or Gemma 4 26B-A4B rows to the coordinator rate-card or to the SPEC-023 static catalog. Those are follow-up PRs after the migration lands.
- This build does not change SPEC-023 v0.2 semantics, rate-card version, autotune scoring, or any money-path code.
- This build does not touch coordinator or gateway Go binaries.
- This build does not migrate to `mlx-swift-lm` `main`; it targets the latest tagged release `3.31.4`.
- This build does not add support for the MLXVLM library (vision-language) even though it becomes available. VLM enablement is a separate SPEC.
- This build does not implement a runtime feature flag (Swift conditional compilation) to keep both dependencies in-tree. Rollback is via reinstalling the prior release pkg (v1.7.10), and via the new install.sh `MACPROVIDER_VERSION` override (§8).

## 3. Concrete task list

### 3.1 Prerequisites

- [ ] Baseline capture: on operator's M5 32GB, run `~/macprovider/macprovider-cli autotune --recommend --json` under **v1.7.10 or v1.7.11** and record TPS + TTFT per model to `specs/baselines/mlx-migration-v1.7.11-m5-32gb.json`. This becomes the regression bar.
- [ ] Confirm the 5 currently-shipping models have local HuggingFace snapshots cached at `~/.cache/huggingface/hub/` (or download them if any are missing). Models:
  - `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`
  - `mlx-community/gpt-oss-20b-MXFP4-Q8`
  - `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit`
  - `mlx-community/Qwen3-32B-4bit`
  - `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`

### 3.2 Dependency swap

- [ ] Fresh worktree per `feedback-always-fresh-worktree-for-code-work`.
- [ ] `phase3-binary/Package.swift`:
  - Change dependency URL `https://github.com/ml-explore/mlx-swift-examples.git` → `https://github.com/ml-explore/mlx-swift-lm.git`.
  - Bump `exact:` from `"2.29.1"` → `"3.31.4"`.
  - Update `package:` label in `.product(name: "MLXLLM", package: ...)` and `.product(name: "MLXLMCommon", package: ...)` from `"mlx-swift-examples"` → `"mlx-swift-lm"`.
- [ ] `phase3-binary/Package.resolved`: delete and regenerate via `swift package resolve`. Confirm transitive pin `mlx-swift 0.29.1` → `0.31.6` (or newer), and `swift-syntax 602-603.x`.
- [ ] Verify `swift-tools-version` in `Package.swift` (currently `5.9`). `mlx-swift-lm/Package.swift` requires `swift-tools-version: 6.1`. If a newer tools version is required for our consumers, bump; otherwise leave since SPM auto-negotiates.

### 3.3 Migrate `ModelRuntime.swift` API sites

The spike identified 4 concrete errors, all confined to `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`:

- [ ] **Lines 281 + 297**: `LLMModelFactory.shared.loadContainer(configuration:)` — the new signature is:
  ```swift
  public func loadContainer(
      from downloader: any Downloader,
      using tokenizerLoader: any TokenizerLoader,
      configuration: ModelConfiguration,
      useLatest: Bool = false,
      progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
  ) async throws -> ContainerType
  ```
  Two migration options. The IMPL agent picks whichever the mlx-swift-lm 3.31.4 API surface actually exposes as a "default":
    1. Prefer the local-directory overload if `configuration.id` is a resolved snapshot path:
       ```swift
       let container = try await LLMModelFactory.shared.loadContainer(
           from: snapshotURL,
           using: <default tokenizer loader>
       )
       ```
       We already resolve HuggingFace snapshots to local paths via `CachedModelArtifactResolver`, so this is the natural fit.
    2. Otherwise use the downloader overload with the default HuggingFace downloader and default tokenizer loader.
  Document which overload we chose in an inline comment.
- [ ] **Line 300**: `configuration.modelDirectory()` — inaccessible + non-callable in 3.31.4. Replace with the equivalent public property on `ModelConfiguration` in the new API (likely `.directory` or similar). If no public accessor exists, wrap the local-path input we already have from `CachedModelArtifactResolver` and skip the round-trip through `ModelConfiguration`.
- [ ] **Line 779**: label rename `tokens:` → `tokenIds:` on the relevant call (`StopTokenFilter.matches(...)` or equivalent). Update `StopTokenFilter` type signatures if the rename cascades.
- [ ] Search the whole tree (`grep -rnE "loadContainer|modelDirectory|tokens:"` under `phase3-binary/Sources/`) for any additional API sites the compiler surfaces during the build.

### 3.4 Local build clean

- [ ] `swift build --product macprovider-cli` — **must** succeed with zero errors. Warnings are allowed to persist if they existed at v1.7.11 head (the migration is not the place to also tackle Swift 6 concurrency warnings; that is a separate scope).
- [ ] Sanity check the built binary loads:
  ```
  .build/arm64-apple-macosx/debug/macprovider-cli --version
  # expected: 1.8.0 (bumped in §3.7)
  ```

### 3.5 Full swift test suite

- [ ] `swift test` — **must** produce `Executed 812+ tests, with 0 failures`. Delta may be +N for any additional tests we add during migration; failures block ship.
- [ ] Explicitly re-verify SPEC-024 conversation-cache tests pass. The KV-cache path is one of the most API-sensitive surfaces to a MLX-Swift core bump. Named tests:
  ```
  swift test --filter ConversationCacheTests
  swift test --filter 'HTTPServerReceiptTests|InferenceRelayTests|Tier2ProviderSessionTests|ChatCompletionRequestTests|ConversationCacheTests'
  ```
  Both filter sets must be green.
- [ ] Explicitly re-verify autotune probe tests:
  ```
  swift test --filter AutotuneRecommendTests
  swift test --filter ServeCommandTests
  swift test --filter CoordinatorClientTests
  ```

### 3.6 Runtime regression validation on M5 32GB

This is the **load-bearing verification step**. Compile-time correctness does not prove runtime equivalence; MLX-Swift 3.x may have changed tokenizer, sampler, quant dequant, or KV-cache semantics quietly.

- [ ] Install the branch-built binary locally at `~/macprovider/macprovider-cli` (bypassing pkg install to save time; note this exercises the SAME code path but not the install.sh pipeline — that runs later at release time).
- [ ] For each of the 5 currently-shipping models with a locally-cached snapshot, run:
  ```
  ~/macprovider/macprovider-cli autotune --recommend --json --config ~/.config/macprovider/config.yaml
  ```
  Record TPS + TTFT (from the `probeDiagnostics` field) per model per run. Take 3 runs per model to smooth noise, use the median.
- [ ] Compare against baselines captured in §3.1.
- [ ] **Ship gate**: any per-model TPS regression > 5% OR per-model TTFT regression > 10% blocks ship. Reason: TPS is the operator's earnings proxy; TTFT is the buyer's latency SLO. TTFT has a slightly looser gate because it's noisier under cold-start.
- [ ] Record the comparison table in the PR body:

  | Model | v1.7.11 TPS | v1.8.0 TPS | Δ% | v1.7.11 TTFT | v1.8.0 TTFT | Δ% | Ship? |
  |---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
  | qwen3-coder-30b-a3b | ... | ... | ... | ... | ... | ... | ✅/❌ |

  Rows for `qwen3-32b` and `qwen2.5-coder-32b` are **not-applicable** on M5 32GB (blocked by min_ram gate); note "N/A on this hardware, revalidate on M-Pro/M-Max before shipping to those tiers" and defer the ship gate for those two rows until a second regression run on a larger-RAM Mac exists.

### 3.7 Version bump + install.sh rollback surface

- [ ] `CoordinatorClient.binaryVersion`: `"1.7.11"` → `"1.8.0"`. This is a **major-minor bump** signaling the MLX-Swift dependency-layer change even though there are no user-facing feature additions. Semantic-versioning honesty: we could argue for `1.7.12` since no CLI-surface breaking change, but the underlying LLM stack IS breaking, and downstream regression risk is real. Prefer `1.8.0`.
- [ ] Update `CoordinatorClientTests.testBinaryVersion` to `"1.8.0"`.
- [ ] `phase3-binary/dist/install.sh`: add `MACPROVIDER_VERSION` env override. New behavior:
  ```
  if [ -n "$MACPROVIDER_VERSION" ]; then
    tag="$MACPROVIDER_VERSION"
    log "Using operator-pinned version: $tag (via MACPROVIDER_VERSION)"
  else
    tag="$(latest_release_tag)"
  fi
  ```
  Placement: inside the existing tag resolution block near `use_fresh_recommendation_if_available` or wherever `latest_release_tag` is currently called. Add operator-facing note in the "Environment variables" comment header at the top of the script.
- [ ] Extend `scripts/test-install-amfi-retry.sh` **only if the AMFI helper's public surface changed** — this install.sh edit is a separate hunk that does not touch the helper. If unrelated, do not extend that test.
- [ ] Add a new regression test `scripts/test-install-version-pin.sh` verifying:
  - Case 1: `MACPROVIDER_VERSION=v1.7.10` → install.sh downloads the v1.7.10 pkg URL.
  - Case 2: unset `MACPROVIDER_VERSION` → install.sh queries GitHub releases API and picks latest `^v[0-9]` tag.
  - Case 3: `MACPROVIDER_VERSION=v99.0.0` (nonexistent) → install.sh dies with a clear error message (no silent fallback to latest).
  Use the existing awk-extract-function pattern from `scripts/test-install-amfi-retry.sh`.

### 3.8 Decision-log correction

- [ ] `beta/DECISION_CRITERIA.md`: correct Entry 97's claim that `gemma-4-26b-a4b-it` and (by extension) `nemotron-3-nano-30b-a3b` are "upstream architecturally missing". State facts: the decoders ship in `mlx-swift-lm`, not `mlx-swift-examples`; we were pinned to the fork point. Reference the migration entry (added below).
- [ ] Add Entry 102 documenting the migration itself: rationale, verification results table, risk register, rollback path via `MACPROVIDER_VERSION=v1.7.11`, follow-up (add Nemotron/Gemma4 rate-card rows in a subsequent PR).

### 3.9 3-lane codex audit

- [ ] Write three audit prompt files under `specs/`:
  - `AUDIT_MLX_SWIFT_LM_MIGRATION_CODE_PROMPT.md` — focus on API-rename correctness, behavior-preserving replacements, no accidental scope creep.
  - `AUDIT_MLX_SWIFT_LM_MIGRATION_SECURITY_PROMPT.md` — focus on transitive dependency changes (mlx-swift 0.29 → 0.31, swift-syntax bump), signed-artifact chain integrity, install.sh version-pin injection surface.
  - `AUDIT_MLX_SWIFT_LM_MIGRATION_ARCHITECT_PROMPT.md` — focus on migration cadence (why now vs later), version bump justification (1.8.0 vs 1.7.12), rollback plan sufficiency, decision-log correction shape.
- [ ] Fire all three lanes in parallel via `omc ask codex "$(cat ...)"`.
- [ ] Converge to 0 CRITICAL / 0 HIGH / 0 MEDIUM per `feedback-stop-iterating-on-low-audits` before merge. Fix inline where reasonable; document LOW deferrals in the PR body.

### 3.10 Ship

- [ ] Commit + push + PR (title: `feat(mlx): migrate mlx-swift-examples 2.29.1 → mlx-swift-lm 3.31.4 + bump v1.8.0`).
- [ ] antfleet-ops approve → Augustas11 squash-merge (per project convention).
- [ ] Post-merge: `gh workflow run release.yml -f version=v1.8.0`.
- [ ] Deploy nothing to Pearl. This is a client-only change; the coordinator does not read `mlx-swift-lm`.

### 3.11 Post-ship follow-ups (separate PRs)

- [ ] PR A: add Nemotron 30B-A3B row to `phase3-binary/dist/static/autotune-candidates.json` (+ baked mirror + v3 resign) + coordinator rate-card row + full 5-signal verification per Entry 97 pattern.
- [ ] PR B: when upstream `mlx-swift-lm` MoE-key registration for Gemma 4 26B-A4B lands, bump the pin and add the Gemma 4 row via the same pattern.

## 4. Acceptance criteria

The PR ships if and only if ALL of the following are green:

1. `swift build --product macprovider-cli` — zero errors.
2. `swift test` — Executed N ≥ 812 tests, 0 failures (allowing the 7 pre-existing skips).
3. `ConversationCacheTests` — 6/6 pass.
4. `AutotuneRecommendTests` — 71/71 pass.
5. `ServeCommandTests` — full pass.
6. `CoordinatorClientTests.testBinaryVersion` — expects `"1.8.0"`.
7. New `scripts/test-install-version-pin.sh` — all cases pass.
8. Runtime regression on M5 32GB per §3.6 shows ≤5% TPS regression and ≤10% TTFT regression on the 3 M5-eligible models (qwen3-coder-30b-a3b, gpt-oss-20b, meta-llama/llama-3.1-8b). qwen3-32b and qwen2.5-coder-32b: N/A on M5.
9. 3-lane codex audit converged 0/0/0 C/H/M.
10. PR body contains: comparison table with actual measured numbers, rollback instructions, and Entry 102 draft (or linked commit).

## 5. Rollback plan

### Fast path — operator downgrade to v1.7.11
An operator who observes a regression after installing v1.8.0 can roll back with a single command once the install.sh `MACPROVIDER_VERSION` override lands:

```
MACPROVIDER_VERSION=v1.7.11 curl -fsSL get.streamvc.live/install.sh | bash
```

Until the override lands (this PR is what lands it), operators can roll back manually:

```
curl -fL https://github.com/Augustas11/macprovider/releases/download/v1.7.11/macprovider-cli-v1.7.11-darwin-arm64.pkg -o /tmp/mp.pkg
sudo installer -pkg /tmp/mp.pkg -target /
launchctl kickstart -k gui/501/live.streamvc.macprovider
```

Document both in the PR body.

### Slow path — repo-side revert
If a majority of the M-Base fleet regresses, revert the merge commit on `origin/main`, cut v1.8.1 that carries only the AMFI helper + version-pin env var but restores the `mlx-swift-examples 2.29.1` dependency. Requires re-running the full verification pipeline.

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|:---:|:---:|---|
| Quantization dequant path changed silently → 4-bit weights load but produce wrong logits | Medium | High | §3.6 runtime regression on all 3 M5-eligible models. Any TPS or TTFT step-change beyond noise is a signal. |
| Tokenizer library bump changes stop-token detection | Medium | Medium | SPEC-024 conv-cache tests + ConversationCacheTests already exercise tokenizer round-trip. Any silent shift breaks those. |
| Sampler defaults changed → same prompt yields different output | Medium | Low | Autotune probes measure TPS not semantic quality; a semantic drift may not surface until buyer traffic. Accept the risk for the first release; monitor logs for any `event=inference_output_hash_drift` or equivalent. |
| KV-cache reuse API changes → SPEC-024 sticky-hit logic breaks | Low | High | Explicit named test filter in §3.5. Any test failure blocks ship. |
| Migration compile succeeds on M5 but fails on CI Ubuntu runners (Swift 6.1 platform matrix) | Medium | Medium | CI runs `phase3-binary (swift test)` — if it fails there, the audit + fix loop catches it before merge. |
| New tokenizer requires a wire-format change (unlikely but possible) | Low | High | Would break any assumption in `ChatCompletionRequestTests`. Ship gate is the whole test suite green. |
| `mlx-swift-lm` `main` between `3.31.4` and time-of-merge introduces a critical bug fix we need | Low | Medium | Pin `exact: "3.31.4"`. If a critical fix lands, cut a follow-up PR bumping the pin. |
| Operator field regression not caught by M5 validation | Medium | Medium | Rollback path documented in §5; monitor first 72h post-release for install-time bug reports. Consider a canary release rollout: keep `latest_release_tag` returning v1.7.11 for 24h and require `MACPROVIDER_VERSION=v1.8.0` for early adopters before flipping default. |

## 7. Sequencing

Do steps in this order; do not parallelize because later steps depend on earlier signals:

1. §3.1 Prerequisites (baselines captured).
2. §3.2 Dependency swap.
3. §3.3 ModelRuntime.swift API migration.
4. §3.4 Build clean.
5. §3.5 Test suite.
6. §3.6 Runtime regression on M5 (**gate: block if fails**).
7. §3.7 Version bump + install.sh env var.
8. §3.8 Decision-log correction.
9. §3.9 3-lane codex audit.
10. §3.10 Ship.
11. §3.11 Follow-up PRs.

## 8. Open questions for reviewers

- Is v1.8.0 the right version tier, or should we use v1.7.12 to signal "no CLI-surface break, only internal MLX bump"? SemVer-strict says the CLI surface is unchanged so 1.7.12 is defensible. Operational-honesty says the MLX layer break IS a break in an important internal boundary and 1.8.0 signals that. **Recommendation: 1.8.0.**
- Should we implement the "canary release" idea in §6 (latest-tag stays v1.7.11 for 24h, MACPROVIDER_VERSION=v1.8.0 for early adopters)? This adds server-side release-metadata complexity but reduces field-regression blast radius.
- The `MACPROVIDER_VERSION` env override is a modest new install-surface. Any concerns about someone pinning to a very old version (e.g. v1.6.x) and hitting known-fixed bugs? Should install.sh warn if the pinned version is more than N minor versions behind `latest_release_tag`?

## 9. What this PR is NOT

- It is NOT the migration itself. This PR contains only this plan document. Executing the plan produces a SEPARATE PR that references this one.
- It is NOT a design change to macprovider's product behavior.
- It is NOT a promise to ship Nemotron or Gemma 4. Those are §3.11 follow-ups; they only become possible after this migration lands.
