# AUDIT — BYOM v0.2 slice 1, round 4

Branch: `feat/byom-v02-slice1-openai-compat-adapter`
Diff under review: `git diff origin/main...HEAD` — the full combined fix as it
will land (`openai_compatible_loopback` adapter, hermetic discovery-journey
driver and CI gate, the local-default `not_offered` admission status, and the
R1/R2/R3 fixes), not a follow-up slice.
Prompt: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_PROMPT.md`
Round 1 record: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_R1.md`
Round 2 record: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_R2.md`
Round 3 record: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_R3.md`
Date: 2026-09-09

## Verdicts (three lanes, R4)

| Lane | Verdict | C | H | M | L | INFO |
| --- | --- | --- | --- | --- | --- | --- |
| code-reviewer | REQUEST CHANGES | 0 | 0 | 2 | 1 | 0 |
| security-reviewer | PASS (one MEDIUM) | 0 | 0 | 1 | 0 | — |
| architect | REQUEST CHANGES | 0 | 0 | 1 | 1 | 1 |

No lane found a CRITICAL or a HIGH, and no lane found a runtime defect in the
adapter: all three re-confirmed strict loopback admission, the shared bounded
HTTP client and parser, the model-reference privacy guard, opaque candidates
that cannot reach a catalog key or the earning path, zero dispatch on the
non-loopback path, the real local-state ladder in step 10, and the R3 lockfile
and owned-cleanup fixes. Every R4 finding is in the evidence layer.

The four lane findings deduplicate to three distinct defects plus one INFO.

## Findings

### F18 (MEDIUM, all three lanes) — Closed-schema validation checked key sets, not values

Lanes: code-reviewer, security-reviewer (OWASP A08), architect.

`scripts/byom_journey_evidence.py:validate_captured_cli_document` enforced exact
key sets and nothing else: no wire types, no nullability, no closed enums, no
nested object shapes, no cross-field rules. R3 had treated "closed schema" and
"exact key set" as the same thing, and the committed golden fixtures proved they
are not — every one of these passed validation and could have backed signed
evidence:

- `identity_state: "declared_local"`, `locality: "local_weights"` — neither in
  the SPEC-046-R003 enums; the CLI emits `runtime_reported` and `local_artifact`.
- `evaluation_state: "evaluated"`, `next_action: "configure_coordinator"`,
  `next_action: "serve_traffic"`, `next_action: "await_coordinator_decision"`,
  `next_action: "await_catalog_admission"` — none in the R003 enums.
- `adapter_response_malformed` and `opaque_endpoint_identity` in `warning_codes`
  — the wire code is `adapter_malformed_response`, and the second is not a
  warning code at all.
- adapter `status: "failed"` / `"rejected_non_loopback"` — the adapter emits
  `malformed` and `rejected`.
- evaluation `capability_results` as bare strings — the CLI emits
  `{result, source, reason_code}` objects.
- `completion_sha256` for the wire key `response_body_sha256`.
- catalog-economics `prepare`/`evaluate`/`switch`/`adopt_recommendation`/
  `cleanup_staging` as booleans and `source` as a string — all five actions and
  the source are objects on the wire.

Because validation runs immediately before digesting, a schema-invalid document
could back signed evidence. The security lane rated the blast radius as invalid
CLI output hashed into signed conformance evidence and used at promotion
preflight.

**Resolution — validator.** `scripts/byom_journey_evidence.py:676-818` adds the
closed value enums, transcribed from the spec text where the spec closes the
vocabulary and frozen from the CLI encoder (with a comment saying so) where it
does not: `RUNTIME_SOURCES`, `IDENTITY_STATES`, `LOCALITIES`,
`READINESS_STATES`, `FIT_STATES`, `EVALUATION_STATES`, `ADMISSION_STATES`,
`ADMISSION_STATE_SOURCES`, `LOCAL_DEFAULT_ADMISSION_STATES`,
`COORDINATOR_ADMISSION_STATES`, `ADMISSION_ALLOWED_NEXT_STATES`,
`NEXT_ACTIONS`, `EARNING_PATH_CLASSES`, `WARNING_CODES`,
`WITHDRAW_REASON_CODES`, `ADAPTER_STATUSES`, `ORIGIN_CLASSES`, and the
evaluation scalar sets.
`scripts/byom_journey_evidence.py:820-911` adds the typed helpers
(`require_bool`, `require_int`, `require_number`, `require_text`,
`require_nullable`, `require_enum`, `require_enum_list`) and
`_require_admission_pair` (`:873`), which implements the cross-field rule:
`admission_state_source == local_default` admits only
`{local_only, not_offered, offerable}`, and `coordinator` only the ten
SPEC-047-R001 states.
`scripts/byom_journey_evidence.py:914-1220` replaces the key-set-only body with
one validator per schema —
`_validate_discovery`, `_validate_evaluation`, `_validate_offer_dry_run`,
`_validate_admission_status`, `_validate_admission_withdraw`,
`_validate_catalog_economics` — covering field types, nullability, every closed
enum above, the SPEC-046-R004 capability object (nullable booleans, nullable
number, nullable strings — "unknown is null, never false"), evaluation
capability results as `{result, source, reason_code}` objects, the
`{prompt_sha256, response_body_sha256}` diagnostic-hash keys, the SPEC-047-R002
dry-run / status / withdraw enums, `allowed_next_states` as a subset of the
SPEC-047-R001 row for the reported state (and empty for a `local_default`
state), and the catalog-economics `source` and action objects.

Enum sources used: SPEC-046-R003 (identity/locality/readiness/fit/evaluation/
admission states, admission-state source, `next_action`, `earning_path_class`,
warning codes), SPEC-046-R004 (capability nullability), SPEC-046-R002 (adapter
enum), SPEC-047-R001 (coordinator states and the transition table),
SPEC-047-R002 (dry-run/status/withdraw envelopes and the withdrawal
`reason_code`). Implementation-defined sets frozen from
`phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift`
(adapter `status`, `origin_class`, `health_result`, `adapter_identity`,
`usage_reporting_source`, `fit_estimate_source`, capability result/source) and
`phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift`
(`Source` and `Action` shapes).

**Resolution — fixtures.** Every golden capture was regenerated from real CLI
output rather than corrected by hand. `scripts/tests/fixtures/byom_journeys/README.md`
records the provenance of each one; the short version:

- `discovery/captures/*.json` (all eight): real, unedited output of
  `test/e2e/byom/run-discovery-journey.py --out <tmp>`, copied verbatim.
- `admission/captures/offer-dry-run.json`,
  `admission-status-offer-submitted.json`, `admission-withdraw.json`,
  `admission-status-reentry.json`, `catalog-economics-unpriced.json`: real,
  unedited output of the CLI driven against the hermetic coordinator stub in
  `test/e2e/byom/run-cli-onboarding-e2e.py` (dry-run, offer submit, status
  readback, withdraw, post-withdrawal status, catalog-economics).
- `admission-status-offer-rejected.json`, `-sandbox-probe-only.json`,
  `-revoked.json`, `-settlement-capable.json`, `-novel-non-catalog.json`: the
  real `offer_submitted` readback with ONLY `admission_state`,
  `allowed_next_states`, and the dependent `provider_guidance` fields changed to
  values from the closed enums; plus `state_meaning_key` on the
  settlement-capable one (keeping the real `not_earning` key would assert
  something false) and `catalog_model_key: null` on the novel-non-catalog one
  (step 10 is the non-catalog presentation case). Provider id, candidate id,
  served model reference, timestamps, `cli_version`, and
  `admission_state_source` are the real CLI's.
- `catalog-economics-catalog-priced.json`: the real unpriced document with edits
  confined to the single BYOM row; the other nine catalog rows are untouched.

Nothing was scrubbed. No real document tripped the redaction scanner.

**Resolution — rejection tests.** `scripts/tests/test_byom_journey_evidence.py:353-509`
adds sixteen tests through the real capture path covering a wrong type
(`chat_completions: "yes"`, `projection_sequence: "1"`, `prepare: false`,
capability results as strings), an out-of-enum value (`identity_state`,
`locality`, `evaluation_state`, `next_action`, `warning_codes[0]`, adapter
`status`, withdrawal `reason_code`, an illegal `allowed_next_states` edge), a
null in a non-nullable field (`display_name`, `admission_state`), the renamed
diagnostic hash, and the `local_default` / coordinator-state mismatch on both a
discovery candidate and an admission status document.
`scripts/tests/test_byom_journey_evidence.py:111` — the fixture-accepting test
— is now true of documents the CLI actually emits.

The two sample documents in `scripts/tests/test_discovery_journey_driver.py:66-137`
carried the same class of invention (`origin_class: "loopback"`,
`fit_estimate_source: "runtime_reported"`, empty `capability_results` and
`diagnostic_hashes`) and were corrected to real wire values.

### F19 (MEDIUM, code-reviewer) — Discovery evidence was not bound to the discovery driver

The real driver reports `test/e2e/byom/run-discovery-journey.py`, but the
discovery golden manifest still named `run-cli-onboarding-e2e.py`, and
`build_evidence()` accepted any existing repository-relative source file — the
test at `test_byom_journey_evidence.py:556` explicitly preserved the stale
identity. A hand-built or stale manifest could therefore claim discovery
evidence under the wrong harness provenance.

**Resolution.** `scripts/byom_journey_evidence.py:187` and `:206` add
`expected_harness_name` to `JourneyContract`;
`scripts/byom_journey_evidence.py:229` and `:244` bind discovery to
`test/e2e/byom/run-discovery-journey.py` and admission to
`test/e2e/byom/run-cli-onboarding-e2e.py` (the harness the admission runbook
names and the one that actually produces admission runs);
`scripts/byom_journey_evidence.py:1525-1529` enforces exact equality in
`build_evidence()`.
`scripts/tests/fixtures/byom_journeys/discovery/run-manifest.json:8` now names
the driver. `scripts/tests/test_byom_journey_evidence.py:700-725` adds three
rejection tests (each journey naming the other's harness, and a manifest naming
an unrelated repository file), and `:743` replaces the assertion that preserved
the stale name.

### F20 (LOW, code-reviewer + architect) — Redaction-failure diagnostics re-emitted the forbidden value

`test/e2e/byom/run-discovery-journey.py:721/732` embedded the first 24
characters of the leaked value in the `HarnessFailure`, and the top-level
handler writes that exception to stderr — so the detector for the
no-origin/no-path stderr invariant could itself violate it. The forbidden set is
exactly origins, absolute paths, the probe prompt, and the completion marker.

**Resolution.** `test/e2e/byom/run-discovery-journey.py:738-766` takes
`forbidden` as `(category, value)` pairs and reports only the category and the
entry's index; `:1317-1336` supplies the categories (`adapter_origin`,
`coordinator_origin`, `loopback_host_port`, `local_path`, `probe_prompt`,
`completion_marker`).
`scripts/tests/test_discovery_journey_driver.py:372-383` asserts the exception
text contains neither the value, nor its first 24 bytes, nor `127.0.0.1`.

### F21 (LOW, architect) — Existing output directories were not made user-private

`prepare_out_dir()` accepted an existing empty directory and then called
`mkdir(mode=0o700, exist_ok=True)`; POSIX applies that mode only when mkdir
actually creates the directory, so a pre-existing permissive `--out` stayed
permissive, and captures were written with default permissions. On a multi-user
host that publishes otherwise redaction-clean operator-local inventory.

**Resolution.** `test/e2e/byom/run-discovery-journey.py:712-736` chmods an
existing (empty, so nothing is destroyed) directory to `0700`;
`:604-609` creates `captures/` `0700`, `:640-646` creates each capture file
`0600`, and `:707` writes the manifest `0600`.
`scripts/tests/test_discovery_journey_driver.py:389-395` and `:511-520` assert
both.

### F22 (INFO, architect) — Admission-status help contradicted its new local behavior

`ModelsSubcommand.swift:236` still read "Read coordinator-backed BYOM admission
status" although the command deliberately supports a coordinator-free
`local_default` result.

**Resolution.** `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:237-245`
now describes coordinator readback with the local-default fallback. The
withdrawal command's "coordinator-backed" wording is left alone: withdrawal
always reaches the coordinator.

## Verification

- `cd phase3-binary && swift build` — PASS.
- `swift test --filter BYOM` — PASS, 99 tests, 0 failures.
- `swift test --filter ModelsSubcommandTests` — PASS, 44 tests, 0 failures.
- `make test-byom-e2e` — PASS.
- `CI=true make test-byom-discovery-journey` — PASS (driver, capture, build,
  preflight).
- `make test-byom-discovery-journey` — PASS.
- `python3 -m unittest scripts.tests.test_discovery_journey_driver
  scripts.tests.test_byom_journey_evidence scripts.tests.test_spec_governance` —
  PASS, 230 tests, 0 failures.
- `python3 scripts/check_spec_governance.py` — PASS.
- `python3 scripts/gen_spec_index.py --lint` — PASS.
- `git diff --check` — clean.

## Carried items

None. Every R4 finding — the three defects and the INFO — is resolved above; no
LOW or INFO is carried into the PR.

## Closing note

R5 codex re-run deliberately NOT run — four anchored rounds; closure delegated to
an independent review on the PR.
