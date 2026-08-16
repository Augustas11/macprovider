# BUILD: Migrate `mlx-swift-examples` 2.29.1 → `mlx-swift-lm` 3.31.4

Author: operator (a11) + Claude session 2026-07-03
Status: IMPLEMENTATION AMENDED IN REVIEW — this PR now carries the migration implementation plus prerelease-canary controls. Approval of this PR approves an opt-in `v1.8.0` prerelease canary only; default/latest promotion remains blocked on the explicit promotion gates below.

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
- This build does not implement a runtime feature flag (Swift conditional compilation) to keep both dependencies in-tree. Rollback is via reinstalling the prior supported release pkg (v1.7.11), and via the new install.sh `MACPROVIDER_VERSION` override (§8).

## 3. Concrete task list

### 3.1 Prerequisites

- [ ] Baseline capture: on operator's M5 32GB, run `~/macprovider/macprovider-cli autotune --recommend --json` under **v1.7.11** and record TPS + TTFT per model to `specs/baselines/mlx-migration-v1.7.11-m5-32gb.json`. This becomes the regression bar.
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
- [ ] `phase3-binary/Package.resolved`: delete and regenerate via `swift package resolve`. Confirm transitive pin `mlx-swift 0.29.1` → exactly `0.31.6`, and `swift-syntax 602-603.x` as resolved by `mlx-swift-lm 3.31.4`.
- [ ] Supply-chain review gate: list every changed remote pin in the PR body with `identity`, `version`, and `revision` from `Package.resolved`. Expected changed pins from the implementation audit are:
  - removed `gzipswift` `6.0.1` revision `731037f6cc2be2ec01562f6597c1d0aa3fe6fd05`
  - removed `mlx-swift-examples` `2.29.1` revision `9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631`
  - `mlx-swift-lm` `3.31.4` revision `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`
  - `mlx-swift` `0.31.6` revision `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`
  - `swift-atomics` `1.3.1` revision `0442cb5a3f98ab802acb777929fdb446bda11a34`
  - added `swift-syntax` `603.0.2` revision `79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1`
  - `swift-system` `1.7.2` revision `7502b711c92a17741fa625d722b0ccbd595d8ed1`
  - `swift-transformers` remains `1.0.0` revision `a2e184dddb4757bc943e77fbe99ac6786c53f0b2`; URL normalized to `.git` and the package is now a direct dependency for the tokenizer loader surface.
  If `swift package resolve` produces a different revision or a newer version for any changed remote pin, stop and rerun the security audit before continuing.
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

  Rows for `qwen3-32b` and `qwen2.5-coder-32b` are **not-applicable** on M5 32GB (blocked by min_ram gate). They are not waived; they move to §3.6b and block default release until validated on eligible larger-RAM hardware.

- [ ] Buyer-path smoke for each M5-validated model: start the branch binary as a provider attached to the live network or an equivalent gateway+coordinator staging stack, then run one non-streaming and one streaming `/v1/chat/completions` request through the buyer-facing path (`api.malibu.tech` → gateway → coordinator → provider, or equivalent staging). Assert route hit for the intended model/provider, HTTP 2xx, non-empty output, terminal `usage`, no stop-token leak, no provider crash, no fallback rate-card row, and gateway/coordinator reconciliation with no token drift. Prefer extending or reusing `test/network-harness` scenarios such as `smoke_gpt_oss_20b.yaml`, `smoke_qwen3_coder_30b_a3b.yaml`, and `smoke_llama_31_8b.yaml`; record harness output, wall time, model ID, route distribution, and reconciliation result in the PR body.

### 3.6b Runtime regression validation on 48GB+ M-Pro/M-Max/Ultra

Before v1.8.0 can become the default installer release, validate the two currently-shipping larger-RAM catalog rows on eligible hardware:

- [ ] On a 48GB+ M-Pro/M-Max/Ultra host with cached snapshots, run the same 3-run median TPS/TTFT regression process as §3.6 for:
  - `mlx-community/Qwen3-32B-4bit`
  - `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`
- [ ] Apply the same ship gate: any per-model TPS regression > 5% OR TTFT regression > 10% blocks default release.
- [ ] Run the same buyer-path smoke for each larger-RAM validated model, including gateway/coordinator reconciliation and no fallback row or token drift.
- [ ] If eligible larger-RAM hardware is unavailable, do not promote v1.8.0 to default/latest. v1.8.0 may remain prerelease/opt-in only via `MACPROVIDER_VERSION=v1.8.0` after the M5 gates pass.

### 3.7 Version bump + install.sh rollback surface

- [ ] `CoordinatorClient.binaryVersion`: `"1.7.11"` → `"1.8.0"`. This is a **major-minor bump** signaling the MLX-Swift dependency-layer change even though there are no user-facing feature additions. Semantic-versioning honesty: we could argue for `1.7.12` since no CLI-surface breaking change, but the underlying LLM stack IS breaking, and downstream regression risk is real. Prefer `1.8.0`.
- [ ] Update `CoordinatorClientTests.testBinaryVersion` to `"1.8.0"`.
- [ ] `phase3-binary/dist/install.sh`: add `MACPROVIDER_VERSION` env override. New behavior:
  ```
  if [ -n "$MACPROVIDER_VERSION" ]; then
    validate_macprovider_version_tag "$MACPROVIDER_VERSION"
    tag="$MACPROVIDER_VERSION"
    log "Using operator-pinned version: $tag (via MACPROVIDER_VERSION)"
  else
    tag="$(latest_release_tag)"
  fi
  ```
  Placement: inside the existing tag resolution block near `use_fresh_recommendation_if_available` or wherever `latest_release_tag` is currently called. Add operator-facing note in the "Environment variables" comment header at the top of the script, including the pipe-side form: `curl -fsSL https://get.malibu.tech/install.sh | MACPROVIDER_VERSION=v1.7.11 bash`.
- [ ] Add `validate_macprovider_version_tag`:
  - Accept only `vMAJOR.MINOR.PATCH` (`^v[0-9]+\.[0-9]+\.[0-9]+$`).
  - Reject empty values, slashes, path traversal, whitespace, newlines, control characters, `main`, `verify-v*`, and every non-release-channel tag.
  - Enforce rollback support floor `v1.7.11`; tags below that floor fail closed with a clear error. No unsupported-version escape hatch in this PR.
  - Nonexistent allowed-shape tags (for example `v99.0.0`) still proceed to the signed download path and fail on missing release artifacts; they must not silently fall back to latest.
- [ ] Preserve release validation chain: both latest and pinned installs must run through the same `download_release -> verify_sha256 -> validate_release_payload` sequence, including signed `checksums.txt.sig`, SHA256, Gatekeeper/stapler, and payload validation. The pinned path must not bypass signature validation and must never fall back to latest on failure.
- [ ] Canary-channel support: update `latest_release_tag` to ignore GitHub prereleases. A prerelease `v1.8.0` can then be installed only by explicit `MACPROVIDER_VERSION=v1.8.0`; default unpinned installs remain on the newest non-prerelease tag until promotion.
- [ ] `.github/workflows/release.yml`: add a workflow-dispatch `prerelease` input. When true, publish with `gh release create --prerelease --latest=false`; when false, keep the normal latest release behavior. The tag format remains `vX.Y.Z`.
- [ ] Extend `scripts/test-install-amfi-retry.sh` **only if the AMFI helper's public surface changed** — this install.sh edit is a separate hunk that does not touch the helper. If unrelated, do not extend that test.
- [ ] Add a new regression test `scripts/test-install-version-pin.sh` verifying:
  - Case 1: `MACPROVIDER_VERSION=v1.7.11` → install.sh downloads the v1.7.11 pkg URL through the normal signed-validation path.
  - Case 2: unset `MACPROVIDER_VERSION` → install.sh queries GitHub releases API and picks latest `^v[0-9]` tag.
  - Case 3: `MACPROVIDER_VERSION=v99.0.0` (nonexistent) → install.sh dies with a clear error message (no silent fallback to latest).
  - Case 4: invalid tags (`main`, `verify-v1.0.0`, `../v1.7.11`, newline/control-character input) fail before download.
  - Case 5: below-floor tag `v1.7.10` fails closed with a clear unsupported-version error.
  - Case 6: pinned signature/SHA mismatch aborts without fallback to latest.
  - Case 7: the documented piped invocation shape passes the variable to the installer shell: `curl -fsSL https://get.malibu.tech/install.sh | MACPROVIDER_VERSION=v1.7.11 bash`.
  - Case 8: latest lookup skips prerelease `v1.8.0` and chooses the newest non-prerelease tag unless `MACPROVIDER_VERSION=v1.8.0` is set explicitly.
  Use the existing awk-extract-function pattern from `scripts/test-install-amfi-retry.sh`.

### 3.8 Decision-log correction

- [ ] `beta/DECISION_CRITERIA.md`: correct Entry 97's claim that `gemma-4-26b-a4b-it` and (by extension) `nemotron-3-nano-30b-a3b` are "upstream architecturally missing". State facts: the decoders ship in `mlx-swift-lm`, not `mlx-swift-examples`; we were pinned to the fork point. Reference the migration entry (added below).
- [ ] Do not change Gemma/Nemotron `runtime_status` or add coordinator rate-card rows in this PR. Do update stale blocked-row wording where present so the reason is "pending migration validation/rate-card rollout" rather than "blocked upstream"; include `specs/SPEC-023-installer-autotune-recommend.md`, `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`, and any baked/static catalog explanatory text touched by the implementation. The JSON status remains `blocked`.
- [ ] Add Entry 103 documenting the migration itself: rationale, verification results table, risk register, rollback path via `MACPROVIDER_VERSION=v1.7.11`, follow-up (add Nemotron/Gemma4 rate-card rows in a subsequent PR). Entry 102 is already occupied on `origin/main` by SPEC-026.

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
- [ ] Post-merge canary: `gh workflow run release.yml -f version=v1.8.0 -f prerelease=true`.
- [ ] 24h opt-in canary: operators install with `curl -fsSL https://get.malibu.tech/install.sh | MACPROVIDER_VERSION=v1.8.0 bash`; default unpinned install remains on v1.7.11/newest non-prerelease because `latest_release_tag` skips prereleases.
- [ ] Promote to default/latest only after all local, CI, M5, larger-RAM, served-path, and 24h canary gates are green with no >5% TPS regression, no >10% TTFT regression, and no serve/network errors. Promotion may be via `gh release edit v1.8.0 --prerelease=false --latest`.
- [ ] Deploy nothing to Pearl. This is a client-only change; the coordinator does not read `mlx-swift-lm`.

### 3.11 Post-ship follow-ups (separate PRs)

- [ ] PR A: add Nemotron 30B-A3B row to `phase3-binary/dist/static/autotune-candidates.json` (+ baked mirror + v3 resign) + coordinator rate-card row + full 5-signal verification per Entry 97 pattern.
- [ ] PR B: when upstream `mlx-swift-lm` MoE-key registration for Gemma 4 26B-A4B lands, bump the pin and add the Gemma 4 row via the same pattern.

## 4. Acceptance criteria

This PR may merge and publish an opt-in `v1.8.0` prerelease canary if and only if the prerelease gate is green:

1. `swift build --product macprovider-cli` — zero errors.
2. `swift test` — Executed N ≥ 812 tests, 0 failures (allowing the 7 pre-existing skips).
3. `ConversationCacheTests` — 6/6 pass.
4. `AutotuneRecommendTests` — 71/71 pass.
5. `ServeCommandTests` — full pass.
6. `CoordinatorClientTests.testBinaryVersion` — expects `"1.8.0"`.
7. New `scripts/test-install-version-pin.sh` — all cases pass, including tag validation, below-floor rejection, prerelease skip, pinned signature/SHA failure, and documented pipe-side env placement.
8. Provider artifact preflight and release packaging checks require MLX Metal resources (`mlx.metallib` or legacy bundle `default.metallib`) and reject traversal, absolute-path, symlink, hardlink, and device members before extraction.
9. Local M5 smoke on the 3 M5-eligible rows (`qwen3-coder-30b-a3b`, `gpt-oss-20b`, `meta-llama/llama-3.1-8b`) proves branch binary startup, non-streaming and streaming HTTP 200, non-empty output, terminal streaming usage, no stop-token leakage, and no provider crash. This is a prerelease safety gate, not the default-promotion regression table.
10. `Package.resolved` changed remote pins are listed in the PR body with identity/version/revision and match the reviewed revisions unless security re-approves the delta.
11. Diff does not modify coordinator rate-card config, signed static catalog JSON/signatures, or demand-rank files except for explicit explanatory wording allowed in §3.8; no money-path Go binary changes.
12. 3-lane codex audit converged 0/0/0 C/H/M for prerelease-canary merge approval.
13. PR body contains: validated hardware/model matrix, local-smoke evidence, canary plan/status, default-release promotion criteria, rollback/downgrade floor, signed-pin list, audit C/H/M status, explicit "no rate-card/catalog semantic change in this PR" statement, and Entry 103 draft (or linked commit).

Default/latest promotion remains blocked until ALL of the following additional gates are green:

1. Runtime regression on M5 32GB per §3.6 shows ≤5% TPS regression and ≤10% TTFT regression on the 3 M5-eligible models.
2. Runtime regression on eligible 48GB+ M-Pro/M-Max/Ultra hardware per §3.6b shows ≤5% TPS regression and ≤10% TTFT regression on `qwen3-32b` and `qwen2.5-coder-32b`; if not available, v1.8.0 cannot be promoted to default/latest.
3. Buyer-path smoke passes for every model validated in §3.6 and §3.6b through `api.malibu.tech` or equivalent gateway+coordinator staging, with route hit, HTTP 2xx, non-empty output, terminal usage, no stop-token leak/crash, no fallback row, and gateway/coordinator token reconciliation.
4. The opt-in prerelease canary observation window completes without install fallback, runtime regressions, or serve/network errors.

## 5. Rollback plan

### Fast path — operator downgrade to v1.7.11
An operator who observes a regression after installing v1.8.0 can roll back with a single command once the install.sh `MACPROVIDER_VERSION` override lands:

```
curl -fsSL https://get.malibu.tech/install.sh | MACPROVIDER_VERSION=v1.7.11 bash
```

Until the override lands (this PR is what lands it), operators can roll back manually:

```
curl -fL https://github.com/Augustas11/macprovider/releases/download/v1.7.11/macprovider-cli-v1.7.11-darwin-arm64.pkg -o /tmp/mp.pkg
sudo installer -pkg /tmp/mp.pkg -target /
launchctl kickstart -k gui/501/live.malibu.provider
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
| Migration compile succeeds on M5 but fails on the macos-15/Xcode CI toolchain matrix | Medium | Medium | CI runs `phase3-binary (swift test)` on macos-15 — if it fails there, the audit + fix loop catches it before merge. |
| New tokenizer requires a wire-format change (unlikely but possible) | Low | High | Would break any assumption in `ChatCompletionRequestTests`. Ship gate is the whole test suite green. |
| `mlx-swift-lm` `main` between `3.31.4` and time-of-merge introduces a critical bug fix we need | Low | Medium | Pin `exact: "3.31.4"`. If a critical fix lands, cut a follow-up PR bumping the pin. |
| Operator field regression not caught by M5 validation | Medium | Medium | Mandatory prerelease canary: `latest_release_tag` skips prereleases, v1.8.0 installs only with `MACPROVIDER_VERSION=v1.8.0` for the first 24h, and default/latest promotion is blocked until M5, larger-RAM, served-path, and canary evidence are green. |

## 7. Sequencing

Do steps in this order; do not parallelize because later steps depend on earlier signals:

1. §3.1 Prerequisites (baselines captured).
2. §3.2 Dependency swap.
3. §3.3 ModelRuntime.swift API migration.
4. §3.4 Build clean.
5. §3.5 Test suite.
6. §3.6 Runtime regression on M5 (**gate: block if fails**).
7. §3.6b Runtime regression on 48GB+ M-Pro/M-Max/Ultra (**gate: block default release if fails or unavailable**).
8. §3.7 Version bump + install.sh env var + prerelease canary mechanics.
9. §3.8 Decision-log correction.
10. §3.9 3-lane codex audit.
11. §3.10 Ship/canary/promote.
12. §3.11 Follow-up PRs.

## 8. Open questions for reviewers

- Is v1.8.0 the right version tier, or should we use v1.7.12 to signal "no CLI-surface break, only internal MLX bump"? SemVer-strict says the CLI surface is unchanged so 1.7.12 is defensible. Operational-honesty says the MLX layer break IS a break in an important internal boundary and 1.8.0 signals that. **Recommendation: 1.8.0.**
- Canary decision: yes. Implement prerelease canary mechanics in this PR: unpinned installs skip prereleases, pinned `MACPROVIDER_VERSION=v1.8.0` can install the prerelease, and promotion waits for the gates in §3.10.
- `MACPROVIDER_VERSION` decision: enforce `vMAJOR.MINOR.PATCH` tags and supported rollback floor `v1.7.11`; below-floor tags fail closed in this PR.

## 9. What this PR is NOT

- It is NOT default/latest promotion for v1.8.0. This PR implements the migration and may publish only an opt-in prerelease canary until §4 promotion gates pass.
- It is NOT a design change to macprovider's product behavior or buyer-facing money path.
- It is NOT a promise to ship Nemotron or Gemma 4. Those are §3.11 follow-ups; they only become possible after this migration lands.
