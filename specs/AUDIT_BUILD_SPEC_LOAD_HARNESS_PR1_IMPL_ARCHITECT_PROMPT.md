# ARCHITECT AUDIT PROMPT — Load/fairness harness kickstart PR 1

You are the ARCHITECT audit lane for `feat/load-harness-pr1-baseline`.
Work read-only. Do not edit files.

Audit the implementation of PR 1 from `specs/BUILD_SPEC_LOAD_FAIRNESS_HARNESS_KICKSTART_PROMPT.md`,
focused on structural + longevity concerns from BUILD_SPEC §7 ARCHITECT.

## Scope

Same in-scope files as `AUDIT_BUILD_SPEC_LOAD_HARNESS_PR1_IMPL_CODE_PROMPT.md`.

## Design questions to answer

### `load_summary.json` schema stability

Load scenarios 18–22 will emit the same file with the same key names. Break the schema now and phase-B triage cannot diff across runs.

- Are `RouteEntry` / `LatencyBucket` / `FairnessMetrics` / `StarvationFloor` field names generic enough that adding a streaming scenario (PR 6) doesn't force a rename? Look for baked-in "non-streaming"-only assumptions.
- Does the empty-run case produce the same JSON keys as the populated case? Missing keys break jq downstream.
- Is `WindowSeconds` reliable when a mid-run ctx cancel truncates results? (Answer: it's computed from result StartUTC/EndUTC extremes, so a partial run reports a shorter window truthfully. Confirm.)

### Fairness metric choice

Three metrics ship together (Gini, stddev, max/min). BUILD_SPEC §7 says "justify with reference to what beta providers actually care about."

- Is the choice of Gini vs. a simpler entropy measure (e.g., normalized Shannon) justified? Gini is well-known but has poor behavior at N<5 providers — the baseline scenario runs 3 providers, so triage should read all three headline numbers, not pick one prematurely.
- `MaxMinRatio` floors the min at 1 to avoid divide-by-zero. Is that documented well enough that a reader won't misinterpret "ratio=10 with min=0" as "worst provider got 1/10 the load"? Look at the FairnessMetrics docstring.
- ProviderCount is emitted alongside the metrics — good, but is the field ordering in the JSON stable across marshals? Go's encoding/json emits struct fields in declaration order, so any struct field reorder is a schema change.

### Local-rig extensibility

BUILD_SPEC §7 ARCHITECT: "Local rig can extend to more providers (add M-Ultra, add M-base Pros) without rewriting the rig itself."

- Is `Provider` (in `internal/localrig/`) a stable interface, or does adding a "sometimes-fails" provider (for PR 3's asymmetric-fleet-starvation scenario) require rig internals to change?
- Ports.go allocates on demand — good. Is there any implicit cap on the number of providers (e.g., a hard-coded `providers []` bound, or a WS connection ceiling on the coord side)?
- Can a follow-up PR wire a REAL `macprovider-cli` binary alongside the fakes without rearchitecting? Look at `providers.go` — is the FakeProvider tightly coupled to the rig's WS lifecycle, or can real-binary process substitution be added later?

### Rig lifecycle safety

- On SIGINT during the rig's binary build (~15s cold): does the build get cancelled cleanly, or does it hold the tempdir open? Check `buildBinaries` context handling.
- On coord/gateway crash mid-run: does the harness exit with the right code, or does buyer.Run hang trying to reach a dead gateway until its per-request timeout expires N times? Look at whether the rig surfaces a "process died" signal.
- Is the rig's WorkDir cleanup safe on double-Shutdown? `Shutdown()` docstring claims idempotent — verify.

### Metric shape reusable across scenarios

BUILD_SPEC §7 ARCHITECT: "Metric primitives are reusable across scenarios, not scenario-specific."

- `loadmetrics.Class` is generic. But `DefaultClasses` has scenario 17's specific `short_16tok` / `medium_200tok` labels baked in. Sticky scenario (PR 2) will want a "sticky_hit_rate" bucket — does the current abstraction support that additively, or would it require a rewrite?
- Is there anything scenario-17-specific in `loadmetrics.Compute` that a rewrite in a hurry might not notice?

### DoS guard placement

- The `validateProdLoadGuard` runs at scenario-Validate time — good; the error surfaces before any request fires. But the guard reads env directly (`os.Getenv`). If a test wants to exercise the failure path without setting env, `t.Setenv` should cover it — verify the tests do so.
- Should the guard also cover WS-level chaos scenarios (05, 06, 12) that use PROVIDER_SSH to kill providers on Pearl? Those are technically not high-concurrency load, but a chaos scenario with `buyers.count = 25` against api.streamvc.live would slip through. Is that in-scope for PR 1 or explicitly deferred?

### Coexistence with `test/integration`

- The rig duplicates ~50% of `test/integration/harness_test.go`'s config-writing + spawn logic. Does the PR body flag this as intentional (share-refactor deferred) or does it silently ship a fork? Silent forks age badly. A `TODO(shared-rig-refactor)` comment somewhere is the right move.
- Is there any risk of the rig's coord/gateway configs drifting from what `test/integration` uses on a production config-shape change? If integration's YAML changes and the rig's doesn't, load runs pass but integration breaks — flag if there's no explicit test coupling.

### PR body coverage

- Does the PR description explain the empirical scale ceiling encountered during dev? BUILD_SPEC §10 makes this a success criterion.
- Are follow-up scenarios 18–22 outlined in the PR body?
- Is the fairness-metric choice justified in the PR body, or only in code comments?

## Method

1. Read the BUILD_SPEC end-to-end to internalize what "phase-A discipline" means.
2. Read every changed file top-to-bottom (not just the diff).
3. For each design question, either write a concrete answer with `file:line` citations, OR flag it as an ARCH finding.
4. Distinguish LOW/INFO ARCH observations from real MEDIUM/HIGH structural issues. LOW/INFO ship in the PR body.

Return findings ordered by severity with file:line references.
If no issues remain, say `No findings.`

End with:
`STATUS: ARCHITECT lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
