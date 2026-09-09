# AUDIT — BYOM v0.2 slice 1, round 3

Branch: `feat/byom-v02-slice1-openai-compat-adapter`
Diff under review: `git diff origin/main...HEAD` — the full combined fix as it
will land (`openai_compatible_loopback` adapter, hermetic discovery-journey
driver and CI gate, the R1 fixes, the local-default `not_offered` admission
status, and the R2 fixes), not a follow-up slice.
Prompt: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_PROMPT.md`
Round 1 record: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_R1.md`
Round 2 record: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_R2.md`
Date: 2026-09-09

## Verdicts (three lanes, R3)

| Lane | Verdict | C | H | M | L | INFO |
| --- | --- | --- | --- | --- | --- | --- |
| code-reviewer | REQUEST CHANGES | 0 | 0 | 3 | 1 | 0 |
| security-reviewer | PASS (one LOW) | 0 | 0 | 0 | 1 | — |
| architect | APPROVE | 0 | 0 | 0 | 0 | — |

The architect lane is clean. The security lane confirmed every R2 resolution and
found no new CRITICAL/HIGH/MEDIUM: strict literal-loopback origin admission,
disabled redirects and proxies, bounded responses, the shared model-reference
guard, opaque candidates that cannot reach a catalog key or the earning path,
non-overridable observations, failed steps blocking manifest publication, the R2
source binding, and correct CI placement. All three R3 MEDIUMs are in the
evidence layer, and all three are the same shape as R1/R2: a control that was
right for the driver but not for the boundary it actually has to hold.

## Findings (deduplicated across lanes)

Four lane findings deduplicate to four distinct defects (the two LOWs are the
same defect seen from the code and security lanes).

### F14 (MEDIUM) — Evidence mode silently discarded local lockfile changes

Lanes: code-reviewer.
`test/e2e/byom/run-discovery-journey.py:306` and
`scripts/test-byom-discovery-journey.sh:51` each ran an unconditional
`git checkout HEAD -- phase3-binary/Package.resolved` before the cleanliness
check. R2 introduced that restore to make the gate order-independent in CI, and
it does — but it cannot tell CI resolution drift from an operator's uncommitted
work, and `git checkout HEAD --` leaves no copy of what it overwrote. The
reviewer hit this during the review itself: their checkout began with an
unstaged lockfile modification and the gate destroyed it.

**Resolution.** The rule is now conditional, and it lives in exactly one place.
`test/e2e/byom/run-discovery-journey.py:204` `restore_locked_package_resolved()`
compares the working-tree lockfile to `HEAD` and takes one of three branches:

- equal — return, writing nothing;
- differs, `GITHUB_ACTIONS` or `CI` is `true`/`1`, and nothing is staged for the
  file — restore `HEAD`'s bytes and print a notice saying why (an ephemeral CI
  checkout is discarded with the job, so nothing uncommitted there is work
  anyone wanted; and `HEAD`'s lockfile is separately proven by the
  `phase3-binary (locked SwiftPM resolve)` job);
- anything else — a local run, or a CI run with the lockfile **staged** — raise,
  naming the file and telling the operator to commit it or restore it
  themselves. Nothing is written.

`scripts/test-byom-discovery-journey.sh:53` no longer touches the lockfile at
all; the comment there says why, and points at the driver.
`docs/runbooks/byom-journey-evidence.md:163` documents the three branches.

Regression coverage, `scripts/tests/test_discovery_journey_driver.py`: a clean
lockfile passes untouched; a differing lockfile is restored under
`GITHUB_ACTIONS=true` and under `CI=true`; a differing lockfile on a local run is
refused **and its bytes asserted unchanged**; a *staged* lockfile is refused even
with the CI flag set; `CI=false` and an empty environment are not CI. A wrapper
test asserts the shipped script contains no lockfile checkout.

Verified end to end: after `swift test` rewrote the lockfile,
`make test-byom-discovery-journey` on this machine refused with the new message
and the file's md5 was identical before and after.

### F15 (MEDIUM) — Cleanup deleted the pre-existing evidence file it had refused to overwrite

Lane: code-reviewer.
`scripts/test-byom-discovery-journey.sh:27` installed the EXIT trap **before**
the `[ -e "$EVIDENCE" ]` existence check. On a collision the script printed
"refusing to overwrite", exited 1, and the trap then `rm -f`-ed the very file it
had refused to touch. Two runs in the same second share the timestamped name, so
one run could delete another's artifact.

**Resolution.** `scripts/test-byom-discovery-journey.sh:22` — the artifact
lifecycle is now ownership-based rather than name-based. `EVIDENCE_DIR` and
`OUT_DIR` are declared empty, the trap is armed while both are empty (so a
failure before creation removes nothing), and each is then assigned from its own
`mktemp -d`. The evidence directory is `mktemp -d
journeys/evidence/provider-byom-discovery-ci-XXXXXX` — inside the tree because
the capture contract only accepts
`journeys/evidence/provider-byom-discovery-*.redacted.json`
(`scripts/check_spec_governance.py:321`) and the builder verifies the bytes
against a commit containing them. `cleanup()` removes a directory only when its
variable is non-empty, i.e. only when this invocation created it. Collisions are
now structurally impossible, so the "refuse to overwrite" check is gone with the
race it guarded.

Regression coverage,
`scripts/tests/test_discovery_journey_driver.py::WrapperEvidenceArtifactTests`:
the wrapper's real artifact prologue is extracted verbatim from the shipped
script and run in a scratch tree containing a pre-existing
`provider-byom-discovery-ci-*.redacted.json`. A failed run that had already
written its own evidence leaves the pre-existing file **byte-identical** while
removing its own directory; a failure before `mktemp` deletes nothing; four runs
produce four distinct directories.

### F16 (MEDIUM) — Closed-schema validation stopped at the driver, not the evidence trust boundary

Lanes: code-reviewer.
R2 added complete closed-schema validation, but put it in the driver
(`test/e2e/byom/run-discovery-journey.py:206`). `_digest_document()`
(`scripts/byom_journey_evidence.py:550`) — the boundary every capture crosses,
including the hand-authored physical-provider and admission runs the runbook
describes — checked only the claimed top-level schema and redaction, then hashed
whatever it was given. A redaction-clean but schema-incomplete document was
digested into evidence, and the evidence tests demonstrated exactly that by
accepting an incomplete discovery document. R2's "every capture" claim was true
only of the driver's captures.

**Resolution.** The closed key sets and the validator moved to the shared
contract. `scripts/byom_journey_evidence.py:550` now defines the field sets and
`validate_captured_cli_document(schema, parsed, location)` (`:669`), invoked from
`_digest_document()` at `:782` — after the redaction scans, before the digest, so
a document that is both leaky and incomplete still reports the leak first. The
driver keeps a four-line wrapper
(`test/e2e/byom/run-discovery-journey.py:131`) that calls the shared function and
converts `BYOMEvidenceError` to `HarnessFailure`, so a bad capture still fails
the step that produced it instead of the pipeline three commands later; its
duplicate constants and `assert_exact_object` are deleted.

Coverage is every schema a discovery **or** admission journey document can be —
`provider_byom_discovery.v1` (envelope, `adapters[]` rows, candidates,
capabilities, `provider_guidance`), `provider_byom_evaluation.v1` including the
exact `mutation_summary`, `model_admission_offer_dry_run.v1`,
`model_admission_status.v1`, `model_admission_withdraw.v1` (new in R3; the
admission journey's step-08 document was previously unvalidated at any layer),
and `model_catalog_economics.v1` rows and their `admission` object. An
unenumerated schema fails closed. The withdraw field set mirrors the CLI's own
strict decoder (`BYOMAdmissionWithdrawWire.topLevelKeys`,
`phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:768`). As in R2,
`adapters[]` rows and catalog-economics rows — the two shapes the specs describe
without enumerating field names — are frozen at the emitted shape with a comment
saying so.

The golden fixtures under
`scripts/tests/fixtures/byom_journeys/{discovery,admission}/captures/` were
minimal stubs (three to five fields each); all nineteen are now **complete**
closed documents. `scripts/tests/test_byom_journey_evidence.py`'s
`guidance_document()` helper, which hand-built a two-field discovery document and
asserted it was accepted, now starts from the golden fixture and overrides only
the guidance fields under test.

Regression coverage through the **real capture path**
(`build_evidence` → `_digest_document`), not the driver:
missing and unknown envelope fields; a missing nested candidate field; missing
and unknown nested capability fields; missing and unknown nested
`provider_guidance` fields; a missing nested `adapters[]` field; a missing
`mutation_summary` field; a missing withdraw envelope field; an unknown
catalog-economics row field; and an unenumerated schema.

### F17 (LOW) — `--version` stdout skipped the hostname rule

Lanes: code-reviewer (LOW), security-reviewer (LOW, OWASP A08). One defect.
`Runner.run_text()` applied `reject_unredacted_text_except_hostname()` to all
stdout, because JSON documents legitimately carry the SPEC-046-R003 localization
keys. JSON commands then got the structural scan in `run()`, but `--version`
returns straight out of `run_text()` and never received the hostname rule — so
the driver docstring's and the runbook's "every command, `--version` included"
was not exact. Non-blocking: the downstream capture scan would still reject such
a manifest.

**Resolution.** `test/e2e/byom/run-discovery-journey.py:499` — `run_text()` now
applies the FULL plaintext scan by default, hostname rule included. The
exemption is a `defer_hostname_scan` argument set only by `run()`
(`:554`), whose very next act is
`assert_captured_document_redacted()`, the structured walk that decides those
keys field by field. `--version` and any other plain-text command get the whole
rule set.

Regression coverage,
`scripts/tests/test_discovery_journey_driver.py::RunnerStdoutScanTests`: a clean
version string passes; a DNS-shaped version string is refused through the real
`run_text()`; the JSON path still accepts a localization key.
`docs/runbooks/byom-journey-evidence.md:142` restated accordingly.

## Carried items (unchanged from R2, not re-reported by any lane)

- **Binding an executable digest into the run manifest — carried, not done.**
  The run manifest is a closed schema (`macprovider.byom-journey-run.v1`) shared
  with the admission journey and mirrored by committed golden fixtures; adding a
  field is a journey-contract change for a later slice. This slice keeps the
  *source* binding sound instead: locked build, tracked+untracked cleanliness
  before and after the build, `source_sha` recorded only after the post-build
  check.
- **Isolated-checkout builds — not adopted.** The current-worktree path with a
  locked build and a post-build re-check closes the same holes at a fraction of
  the CI cost. Still available if a later slice needs stronger provenance.
- **`~` config-path expansion — pre-existing.** Not introduced by this branch;
  the driver hands `models admission status` an explicit harness-owned
  `--config`.
- **INFO — no action.** All three lanes re-confirmed the adapter: shared safety
  layer reuse, absent-origin no-probe, opaque candidates null-catalog and
  non-earning, step-04's zero-dispatch ledger check, step-10's real CLI ladder,
  CI path classification, and unchanged `models list`/browse contracts.

## Merge bar

0 CRITICAL / 0 HIGH / 0 MEDIUM. F14, F15, F16, and F17 are resolved in this
branch. The three R2 carried items are unchanged and still carried with their
stated reasons. Re-run the three lanes over the full combined diff before
merging.
