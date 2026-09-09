# AUDIT — BYOM v0.2 slice 1, round 2

Branch: `feat/byom-v02-slice1-openai-compat-adapter`
Diff under review: `git diff origin/main...HEAD` — the full combined fix as it
will land (`openai_compatible_loopback` adapter, hermetic discovery-journey
driver and CI gate, the R1 fixes, and the local-default `not_offered` admission
status), not a follow-up slice.
Prompt: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_PROMPT.md`
Round 1 record: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_R1.md`
Date: 2026-09-09

## Verdicts (three lanes, R2)

| Lane | Verdict | C | H | M | L | INFO |
| --- | --- | --- | --- | --- | --- | --- |
| code-reviewer | REQUEST CHANGES | 0 | 1 | 2 | 3 | 0 |
| security-reviewer | BLOCK | 0 | 0 | 1 | 0 | — |
| architect | BLOCK | 0 | 0 | 2 | 1 | 2 |

All three lanes again confirmed the adapter itself: the shared loopback origin
validator, the bounded no-proxy/no-redirect transport, the shared parser bounds,
and the model-reference privacy guard are reused rather than reimplemented; no
SSRF or loopback escape was found; the absent-origin path probes nothing; opaque
candidates stay null-catalog, null-capability, `local_only`, non-earning, and
non-submittable; and the new local-default `not_offered` path preserves the
401/403/503 error mapping. Every R2 finding is in the evidence layer, not the
adapter.

## Findings (deduplicated across lanes)

The nine lane findings deduplicate to five distinct defects.

### F9 (HIGH) — Evidence-source binding was CI-order-dependent and raced its own build

Lanes: code-reviewer (HIGH), security-reviewer (MEDIUM, OWASP A08), architect
(MEDIUM ×2). R1 F5 was not actually closed.

Three separate holes, one root cause — the driver checked its inputs once, before
doing the thing that changes them:

1. **CI order.** The `swift test` step runs before `make test-byom-discovery-journey`
   in the same job (`.github/workflows/ci.yml:423`, `:436`) and rewrites tracked
   `phase3-binary/Package.resolved` under the runner's default toolchain. The
   evidence-mode cleanliness check then refused to run at all. The required check
   was red for a reason that says nothing about the run.
2. **The build raced the check.** After a manual restore the gate passed — and
   its own plain `swift build` mutated the lockfile again, *after* the sole
   cleanliness check, then published and preflighted evidence against the
   `SOURCE_SHA` the wrapper had already recorded.
3. **Untracked inputs were exempt by design.** The check used
   `--untracked-files=no` and a unit test explicitly endorsed that. SwiftPM's
   executable target selects the whole `Sources/macprovider-cli` directory with
   no closed source list (`phase3-binary/Package.swift:59`), so an untracked
   `.swift` file there is a build input while the evidence names `HEAD`.

A fourth, related hole (architect MEDIUM, security MEDIUM): the operator runbook
documented the driver **without** `--evidence`, and that mode accepts a
`MACPROVIDER_CLI_BINARY` override and checks nothing — yet still wrote a
`run-manifest.json` that capture accepts. Following the runbook produced a
promotable manifest bound to nothing.

**Resolution.** Evidence mode is now order-independent, locked, re-checked, and
the only mode that can publish.

- `test/e2e/byom/run-discovery-journey.py:286` — `EVIDENCE_RESTORED_LOCKFILE`,
  and `:306` `restore_locked_package_resolved()`: the committed
  `Package.resolved` is restored from `HEAD` before the cleanliness check. The
  comment states why this is honest rather than lenient — the drift is an
  artifact of CI step ordering, and `HEAD`'s lockfile is separately proven
  consistent by the `phase3-binary (locked SwiftPM resolve)` job
  (`.github/workflows/ci.yml:467-490`, `scripts/verify-swift-package-lock.sh`).
  The wrapper does the same first (`scripts/test-byom-discovery-journey.sh:51`).
- `test/e2e/byom/run-discovery-journey.py:268` — `EVIDENCE_SOURCE_PATHS` is now
  `phase3-binary/Sources`, `phase3-binary/Tests`, `phase3-binary/Package.swift`,
  `phase3-binary/Package.resolved`, `scripts`, `test/e2e/byom`.
- `test/e2e/byom/run-discovery-journey.py:325` — `require_clean_evidence_source()`
  uses `git status --porcelain --untracked-files=all` and fails closed on
  anything reported. It takes a `phase` label so the message names when the
  tree drifted.
- `test/e2e/byom/run-discovery-journey.py:294`, `:370` —
  `SWIFT_LOCKED_RESOLUTION_FLAG = "--only-use-versions-from-resolved-file"`,
  appended to the evidence-mode build. This is the same lock the locked-resolve
  CI job applies through xcodebuild's `-onlyUsePackageVersionsFromResolvedFile`:
  resolution may only use the versions in `Package.resolved` and fails if that
  file is out of date, so the build cannot rewrite it.
- `test/e2e/byom/run-discovery-journey.py:377` — the cleanliness check runs
  **again after the build**, before anything is captured or published.
- `scripts/test-byom-discovery-journey.sh:64` — `SOURCE_SHA` is read only after
  the driver (and therefore the post-build check) has succeeded. Reading it
  earlier named a commit before knowing whether the run stayed bound to it.
- `test/e2e/byom/run-discovery-journey.py:736` — only an `--evidence` run writes
  `run-manifest.json`; a run without it writes the same content as
  `run-summary.json`, a name `scripts/capture-byom-journey-evidence.py` does not
  consume. An unbound run is non-promotable by construction, not by operator
  discipline.
- `docs/runbooks/byom-journey-evidence.md:93` — step 1 uses `--evidence` and
  states that a non-evidence run cannot be captured; `:152` documents the full
  binding (restore, tracked+untracked check, locked build, post-build re-check,
  late `source_sha`).

Tests, `scripts/tests/test_discovery_journey_driver.py`:
- `:518` `test_evidence_mode_refuses_an_untracked_swift_source_file` — reverses
  the R1 test that endorsed untracked files; an untracked `.swift` under
  `Sources/macprovider-cli` is refused.
- `:534` `test_lockfile_drift_after_the_build_fails_closed`.
- `:545` `test_the_committed_lockfile_is_restored_before_the_check`.
- `:557` `test_evidence_builds_with_locked_resolution` — asserts the flag, and
  that the locked-resolve script applies the xcodebuild equivalent.
- `:583` `test_the_ci_wrapper_runs_the_driver_in_evidence_mode` — asserts the
  wrapper's ordering: restore, then run, then record `SOURCE_SHA`.
- `:596` `ManifestPublicationModeTests` — evidence publishes `run-manifest.json`;
  a non-evidence run publishes `run-summary.json` and no manifest; the runbook
  passes `--evidence`.

**CI-order simulation (the exact sequence that failed in R2), run locally:**
`swift test --filter BYOMDiscoveryTests` (which dirties the lockfile), then
`make test-byom-discovery-journey` — passes, and leaves `Package.resolved`
unmodified afterwards.

### F10 (MEDIUM) — Captured documents were not validated against complete closed schemas

Lane: code-reviewer.
Capture checked JSON-ness, the top-level schema id, and redaction — never the
exact field set. Step 03 read `capabilities` through an `or {}` fallback, so
"every capability value is null" was vacuously true for an absent or partial
object; step 07 accepted any nonempty subset of `mutation_summary` whose present
values were false. A redaction-clean but schema-incomplete document would have
been digested into signed evidence as if the CLI had emitted the full envelope.

**Resolution.** Every capture is validated against its complete closed schema;
a missing field and an unknown field both fail the step.

- `test/e2e/byom/run-discovery-journey.py:196` — `assert_exact_object()`.
- `test/e2e/byom/run-discovery-journey.py:206` — `validate_captured_document()`,
  called from `ManifestBuilder.capture()` at `:677` (after the redaction scan,
  so a leaky document still fails as a leak).
- Field sets: SPEC-046-R003 discovery envelope, candidate, and
  `provider_guidance`; the exact SPEC-046-R004 capability list; the
  SPEC-046-R005 evaluation envelope and `mutation_summary`; the SPEC-047-R002
  `model_admission_offer_dry_run.v1` and `model_admission_status.v1` envelopes.
  The two shapes the specs describe without enumerating field names —
  `adapters[]` rows and the `model_catalog_economics.v1` row — are frozen at
  the shape the CLI actually emits, so a silent projection change fails the
  gate. An unrecognized schema id is refused outright.
- `test/e2e/byom/run-discovery-journey.py:943` — step 03 asserts the exact
  capability field set with every value `null` (no `or {}` fallback).
- `test/e2e/byom/run-discovery-journey.py:1068` — step 07 asserts the exact
  mutation-summary field set with every value `false`.

Tests: `scripts/tests/test_discovery_journey_driver.py:638`
(`ClosedCaptureSchemaTests`) covers a missing and an unknown field at the
envelope (`:668`, `:673`), candidate, capability (`:683`, `:690`), guidance, and
mutation-summary (`:700`, `:706`) levels, plus an unvalidated schema id and the
SPEC-046-R004 capability list itself. The suite's document fixtures were
rewritten as complete closed documents.

### F11 (LOW) — `--version` bypassed the all-command redaction scan

Lane: code-reviewer.
Version collection called `subprocess.run` directly, so neither stream entered
`Runner.transcript` or the shared scanner, contradicting the documented claim
that the scan covers every command's real stdout and stderr.

**Resolution.** `test/e2e/byom/run-discovery-journey.py:564` — `Runner.run_text()`
runs the command, records both streams in the transcript, and applies the shared
scanners; `Runner.run()` is now a JSON wrapper around it, and `:852` collects the
version through it. Runbook claim updated to say `--version` included.

### F12 (LOW) — Rollback runbook described superseded wire behaviour

Lanes: code-reviewer, architect.
Row 10 still promised `adapters[].status: not_configured` for an absent origin,
a value R1 removed, and the old-coordinator section did not separate the three
distinct behaviours.

**Resolution.** `docs/runbooks/byom-disablement-rollback.md` row 10 — an absent
origin emits **no** `openai_compatible_loopback` adapter row at all (parity with
a skipped Ollama adapter; no new wire value) and dispatches zero requests. The
old-coordinator section (`:111`) now separates: the **transport** still reports
404/405 and an unknown 200 schema as errors; the **command runtime** maps only
"no coordinator configured" and "admission route absent or unreachable" to the
local ladder row `not_offered` / `local_default` with
`coordinator_state_unavailable`; and 401/403/503 plus unknown successful schemas
**stay errors**. Each is cited to its existing test.

### F13 (LOW) — Misaligned arguments in two production call sites

Lane: code-reviewer. Style only.

**Resolution.** `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:290`
and `:372` — `openAICompatibleOrigin:` aligned with `ollamaOrigin:`; all six call
sites now match.

## Carried items

- **Binding an executable digest into the run manifest — carried, not done.**
  Both the security and architect lanes suggested recording a SHA-256 of the
  built CLI in the manifest and cross-checking it during capture. The run
  manifest is a closed schema (`macprovider.byom-journey-run.v1`) shared with the
  admission journey, validated on both the capture side and the governance side
  (`scripts/byom_journey_evidence.py`, `scripts/check_spec_governance.py`), and
  mirrored by committed golden fixtures. Adding a field is a journey-contract and
  schema change affecting both journeys, so it belongs to a later slice rather
  than to an audit-fix commit. What this slice does instead is make the *source*
  binding sound: locked build, tracked+untracked cleanliness before and after the
  build, and `source_sha` recorded only once the post-build check passed.
- **Isolated-checkout builds — not adopted.** The architect's strongest option
  (build evidence from a fresh `git worktree` of `source_sha` with a private
  scratch path) was weighed against the chosen option in that lane's own
  trade-off table. The current-worktree path with a locked build and a post-build
  re-check closes the same holes at a fraction of the CI cost; the isolated
  checkout stays available if a later slice needs provenance stronger than
  "this tree, verified unchanged across the build".
- **`~` config-path expansion — pre-existing.** `models admission status`
  resolves `~` from the account rather than from `HOME`, which is why the driver
  hands it an explicit harness-owned `--config`. Not introduced by this branch;
  no change made here.
- **INFO (all three lanes) — no action.** Adapter composition, shared safety
  layer reuse, absent-origin no-probe behaviour, opaque-candidate non-earning
  states, the closed local-default status envelope, the driver's position as the
  CI seam, and the changed-path classifier were each confirmed correct again.

## Merge bar

0 CRITICAL / 0 HIGH / 0 MEDIUM. F9 through F13 are resolved in this branch. The
executable-digest binding is carried with a stated reason; the `~` expansion is
pre-existing. Re-run the three lanes over the full combined diff before merging.
