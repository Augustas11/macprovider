# BUILD_SPEC_029_IMPL_PROMPT - Sweep Workload-Class Stratification

You are starting a fresh implementation session in the macprovider repo. You
have no memory of prior conversations. Read this prompt end-to-end before
writing code.

## 0. Workspace And Authority

Before editing anything, verify:

```bash
pwd
git status -sb
git worktree list
git fetch origin
ls AGENTS.md CLAUDE.md specs/SPEC-029-sweep-workload-class-stratification.md
```

Work in a fresh isolated worktree/feature branch, never local `main`, and read
`AGENTS.md` plus `CLAUDE.md` before writing or pushing code.

Controlling contract:

- `specs/SPEC-029-sweep-workload-class-stratification.md`.
- `docs/research/sweep-workload-class-2026-07.md`.
- `.omc/logs/sweep-workload-class-open-questions-2026-07.md`.
- Repo rules in `AGENTS.md` and `CLAUDE.md`.

If SPEC-029 status still says "Draft, research round. Implementation MUST NOT
begin before maintainer review" and the user has not explicitly authorized
implementing draft SPEC-029, STOP after reporting that maintainer authorization
is required. If maintainer authorization has been given, implement the SPEC
exactly; do not re-litigate the product decisions. If code reveals a true SPEC
ambiguity, stop and surface it as a SPEC follow-up instead of silently changing
the contract in code.

Clean-room boundary: do not inspect Darkbloom / layr-labs `d-inference`
source.

## 1. Scope Summary

Implement SPEC-029 v0.1 as a research/data-plane extension:

- Class-aware sweep partitions keyed by `(workload name, RAM-tier key)`.
- Per-workload/per-RAM-tier winner or explicit no-winner result.
- Workload-specific gates, deterministic tie-breakers, and report rows.
- Speculative decoding search-cell metadata when SPEC-028 fields are present.
- Additive static-catalog `workload_profiles` schema and validation.
- Backward-compatible current-client behavior when `workload_profiles` exists.

Out of scope:

- No buyer API change.
- No coordinator routing-policy change.
- No provider request-time classifier.
- No runtime class-routed serving.
- No settlement, receipt, request-log, ledger, billing, or payout schema change.
- No modification to SPEC-013 or SPEC-028.
- No single legacy/default export derived from workload winners unless a later
  SPEC or maintainer-approved run manifest defines the weighting policy.
- No regeneration of old class-blind sweep reports unless needed for fixtures.

## 2. Existing Surfaces To Inspect First

Start by mapping the current code; do not assume file names beyond this list:

- Beta harness/report: `beta/harness.py`, `beta/report.py`,
  `beta/workloads.py`, `beta/workloads_adversarial.py`, `beta/config*.yaml`.
- Static catalog and recommendation parsing:
  `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`,
  `phase3-binary/Sources/macprovider-cli/AutotuneRecommendSimulateCommand.swift`,
  `phase3-binary/dist/static/autotune-candidates.json`.
- Provider capacity / RAM tier behavior:
  `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`.
- SPEC-028 plumbing and tests:
  `phase3-binary/Tests/macprovider-cliTests/Spec028PlumbingTests.swift`.
- Candidate-catalog tests:
  `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`,
  `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendSimulateTests.swift`.
- Signing/key material:
  `phase3-binary/dist/static/keys/README.md`,
  `scripts/resign-autotune-static.sh`.

Preserve existing class-blind modes and existing static catalog behavior unless
SPEC-029 explicitly adds a field or test.

## 3. Mandatory Implementation Slices

Implement in the order below. Each slice must include targeted tests before
moving on.

### Slice A - SPEC-029 Data Model And RAM-Tier Helpers

Add a small, explicit model layer for class-aware sweep artifacts instead of
scattering dictionaries across the harness/report code.

Requirements:

1. Define the included workload set exactly:
   `short_chat`, `medium_with_system`, `long_context`, `code_completion`,
   `agent_style`.
2. Treat `streaming_check` as a TTFT probe only. It may be measured and gated,
   but it must not emit a serve-knob winner or static `workload_profiles`
   profile.
3. Preserve workload/corpus mapping from `beta/workloads.py`
   `_WORKLOAD_CORPUS_MAP`; add `corpus_class` only where both workload name
   and corpus class must be represented.
4. Add RAM-tier normalization matching `ProviderCapacity` thresholds:
   - physical RAM <= 12 GiB -> `8gb`
   - > 12 and <= 24 GiB -> `16gb`
   - > 24 and <= 48 GiB -> `32gb`
   - > 48 GiB -> `64gb_plus`
   - existing provider tier strings map `8GB`, `16GB`, `32GB` to lower-case
     keys and `64GB+` case-insensitively to `64gb_plus`
   - any other provider tier string is invalid for SPEC-029 publication.
5. Define a closed no-winner enum:
   `insufficient_samples`, `gate_unmet`, `hard_failure`,
   `no_cells_evaluated`.
6. Define workload gate defaults exactly as SPEC-029 FR-6:
   - `short_chat`: min samples 20, max p95 TTFT 8000 ms
   - `medium_with_system`: min samples 20, max p95 TTFT 12000 ms
   - `long_context`: min samples 20, max p95 TTFT 60000 ms
   - `code_completion`: min samples 20, max p95 TTFT 12000 ms
   - `agent_style`: min samples 20, max p95 TTFT 20000 ms
   - `streaming_check`: min samples 20, max p95 TTFT 2000 ms, probe only
   - every workload has hard stop-token leak rate 0 and advisory
     `min_median_tps = null`.

Tests:

- RAM-tier boundary tests at 12/13/24/25/48/49 GiB.
- Provider-tier string normalization tests for `8GB`, `16GB`, `32GB`,
  case variants of `64GB+`, and invalid strings.
- Included/probe workload tests proving `streaming_check` cannot be published
  as a winner profile.

### Slice B - Class-Aware Trial Capture And Report Rows

Extend the beta harness/report path to record the SPEC-029 identity fields
without breaking existing runs or daily reports.

Requirements:

1. Class-aware artifacts must record at least:
   - target model identifier
   - host RAM bytes
   - RAM-tier key
   - workload name
   - corpus class when known
   - context limit cell
   - concurrency cell
   - kv-bit cell
   - measured TTFT, total latency, error/status state, and stop-token leak
   - prompt/completion token counts and throughput when emitted
   - `metric_unavailable_reason` when token counts or throughput are
     unavailable
   - winner/no-winner decision and reason.
2. For speculative search cells, also record:
   - `draft_model`
   - `draft_model_artifact_sha256` when `draft_model` is present
   - `num_draft_tokens`
   - drafted token count, accepted token count, and acceptance rate when
     speculative decoding was attempted
   - candidate source: static `draft_candidates[]`, local operator override,
     or research fixture.
3. Keep existing class-blind run/report mode working. Add opt-in flags or a
   new output artifact for class-aware sweep reports rather than making old
   scripts require new columns unconditionally.
4. If existing SQLite rows lack new fields, migration/default handling must let
   old reports render without failure.

Tests:

- Fixture rows with token counts present and missing.
- `metric_unavailable_reason` emitted when throughput cannot be computed.
- Old/class-blind report path still renders from a legacy-shaped fixture.
- Speculative metadata is preserved when present and omitted/null-safe when
  absent.

### Slice C - Winner Selection Engine

Build a deterministic selector over `(workload name, RAM-tier key)` partitions.

Requirements:

1. A non-speculative winner tuple is exactly:
   `(kv_bits, max_context_override, max_concurrency_override)`.
2. A speculative winner tuple may additionally include:
   `(draft_model, draft_model_artifact_sha256, num_draft_tokens)`.
3. `num_draft_tokens` is selected per workload. Do not export a single shared
   value unless a later SPEC or maintainer-approved run manifest defines the
   weighting policy.
4. A winner requires the winning cell's successful sample count to be at least
   `gate_policy.min_samples`; do not aggregate samples across cells to qualify
   a winner.
5. Tie-breaking is partition-local and deterministic:
   - zero hard failures and zero stop-token leaks
   - satisfies workload-specific TTFT gate
   - higher median throughput
   - lower TTFT
   - lower memory-risk posture, such as lower context or lower concurrency,
     when throughput is materially tied
   - lexical serialized tuple fallback.
6. Non-runnable speculative candidate cells count as evaluated but must not
   produce `recommended`.
7. No-winner reason precedence is exactly:
   `no_cells_evaluated` -> `hard_failure` -> `insufficient_samples` ->
   `gate_unmet`.
8. For no-winner profiles, `profile_metrics.sample_count` is the highest
   successful sample count among cells, or 0 when no cells were evaluated.
   Other profile metrics are null in the static no-winner sentinel.

Tests:

- One partition cannot affect another partition's winner.
- Winner sample count is from the winning cell, not the aggregate.
- Deterministic tie-breaker fallback is stable.
- `hard_failure` wins when every evaluated cell hard-failed or was
  non-runnable.
- `insufficient_samples` wins when at least one cell produced successful
  samples but none reached min samples.
- `gate_unmet` wins when at least one cell reached min samples but none passed
  hard gates.
- `no_cells_evaluated` wins when zero cells were evaluated.
- Non-runnable speculative cells are evaluated, excluded from sample-count
  conditions, and never produce `recommended`.

### Slice D - Static Catalog `workload_profiles`

Extend candidate-catalog parsing/validation additively. Do not require current
recommendation or serving code to consume `workload_profiles` for routing.

Requirements:

1. Add optional row field `workload_profiles`.
2. Shape is:

```text
workload_profiles.<workload_name>.<ram_tier_key> -> tier-scoped workload profile
```

3. Tier key must be one of `8gb`, `16gb`, `32gb`, `64gb_plus`.
4. Winner profile:
   - may omit `status` or use `"winner"`
   - includes `recommended`, `gate_policy`, `profile_metrics`, and `source`.
5. No-winner profile:
   - has `status: "no_winner"`
   - has closed-vocabulary `no_winner_reason`
   - omits `recommended`
   - includes `gate_policy`, `profile_metrics`, and `source`
   - only `profile_metrics.sample_count` is populated; all other
     `profile_metrics` fields are JSON null.
6. Use the exact recommended field names from SPEC-013/SPEC-028:
   `kv_bits`, `max_context_override`, `max_concurrency_override`,
   optional `draft_model`, optional `draft_model_artifact_sha256`, optional
   `num_draft_tokens`.
7. If `recommended.draft_model` is present:
   - `draft_model_artifact_sha256` must be present and lowercase 64-hex
   - `1 <= num_draft_tokens <= 16`
   - `max_concurrency_override <= 1`
   - `max_context_override` must not exceed SPEC-028 draft caps:
     `8gb=8192`, `16gb=20000`, `32gb=50000`, `64gb_plus=120000`.
8. `gate_policy.min_median_tps` is JSON null unless a maintainer-approved run
   manifest defines a throughput floor.
9. `profile_metrics` units:
   - `p95_ttft_ms` in milliseconds
   - `median_tps` in tokens/sec
   - rates as 0.0-1.0 fractions
   - nullable attempted metrics encoded as JSON null, not omitted.
10. `streaming_check` must not be published in `workload_profiles`.
11. Preserve current consumers: existing recommendation paths must ignore this
    additive field unless this implementation explicitly adds a read-only
    inspection/simulation command.

Tests:

- Decode a current catalog with no `workload_profiles`.
- Decode a catalog with winner and no-winner workload profiles.
- Reject invalid tier key, invalid workload name, `streaming_check` profile,
  unknown no-winner reason, missing no-winner reason, no-winner with
  `recommended`, winner without required metrics, invalid draft hash, invalid
  `num_draft_tokens`, speculative context over tier cap, and speculative
  concurrency > 1.
- Prove existing recommendation selection output is unchanged when an otherwise
  identical catalog adds valid `workload_profiles`.
- Prove static signing still uses the existing SPEC-023 v4 key material and no
  new key ID is introduced.

### Slice E - Publication/Fixture Artifacts

Do not publish production workload winners unless real sweep data exists and
maintainers have approved the run manifest. Use fixtures for schema and tests.

Requirements:

1. Add minimal fixture JSON that exercises:
   - one winner profile
   - one no-winner profile
   - one non-speculative tuple
   - one SPEC-028 speculative tuple
   - nullable throughput/token metrics.
2. If `phase3-binary/dist/static/autotune-candidates.json` is updated in this
   PR, keep the change additive and re-sign with the existing SPEC-023 v4 key
   only. Do not rotate keys for SPEC-029.
3. If production static artifacts are not updated, add tests that validate a
   fixture catalog and leave production catalog bytes untouched.
4. Append to `beta/DECISION_CRITERIA.md` only if this implementation makes a
   new maintainer decision not already captured by SPEC-029.

Tests:

- Fixture round-trip validation.
- `scripts/resign-autotune-static.sh` or existing static sync checks still pass
  if static artifacts changed.

## 4. Acceptance Criteria Coverage

Map tests or explicit verification notes to every SPEC-029 acceptance criterion:

- AC-1: class-aware sweep groups by workload and RAM-tier.
- AC-2: `streaming_check` is probe-only.
- AC-3: partition-local deterministic winner.
- AC-4: speculative `num_draft_tokens` selected per workload.
- AC-5: additive `workload_profiles` schema.
- AC-6: existing SPEC-023 signing/key identity preserved.
- AC-7: no runtime classifier or routing policy added.
- AC-8: reports include workload, corpus, RAM-tier, gates, metrics, and reason.
- AC-9: current clients ignore additive field / unchanged recommendation.
- AC-10: nullable metrics encoded as JSON null.
- AC-11: FR-3 trial/report identity fields present.
- AC-12: `min_samples` semantics use winning-cell count.
- AC-13: SPEC-028 RAM-tier caps enforced.
- AC-14: closed no-winner reasons and precedence implemented.

## 5. Audit-Loop Discipline

Before opening or updating the PR as ready:

1. Run targeted tests after each slice.
2. Run the repo-appropriate aggregate checks, at minimum:

```bash
git diff --check
cd phase3-binary && swift test --filter AutotuneRecommendTests
cd phase3-binary && swift test --filter Spec028PlumbingTests
```

3. If Python beta tests are added, run the exact test command for them and
   include it in the PR.
4. Run 3 independent native audit lanes and 2 external Claude subscription
   review lanes against the implementation and SPEC-029. In this repo, Claude
   subscription CLI can be invoked without the stale API-key setting by using:

```bash
claude -p --setting-sources project,local "<review prompt>"
```

5. Loop on all Critical/High/Medium findings until there are 0 C/H/M findings
   remaining. Low findings may be accepted only with a written rationale in
   the PR or audit note.
6. Include an audit summary in the PR with:
   - lanes run
   - commands/tests run
   - remaining accepted Low findings, if any
   - explicit statement that C/H/M findings are 0.

## 6. PR Checklist

The PR is not complete until all of the following are true:

- Implementation is in an isolated feature worktree/branch.
- SPEC-029 draft-status authorization is documented or SPEC status has been
  updated by maintainers before implementation began.
- Existing class-blind behavior still works.
- `streaming_check` is probe-only.
- No buyer API, coordinator routing, provider runtime classifier, billing,
  settlement, request-log, or payout paths were changed.
- Static catalog compatibility is proven by tests.
- Signing remains SPEC-023 v4.
- Tests and `git diff --check` pass.
- Audit loop is converged to 0 C/H/M findings.
- Commit message follows the Lore Commit Protocol in `AGENTS.md`.
