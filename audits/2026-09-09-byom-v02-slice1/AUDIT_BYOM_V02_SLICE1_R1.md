# AUDIT — BYOM v0.2 slice 1, round 1

Branch: `feat/byom-v02-slice1-openai-compat-adapter`
Diff under review: `git diff origin/main...HEAD` — commits `f0acf885`
(`openai_compatible_loopback` discovery adapter) and `7cdc0b5b` (hermetic
discovery-journey driver, wrapper, Makefile/CI wiring, tests, runbooks).
Prompt: `audits/2026-09-09-byom-v02-slice1/AUDIT_BYOM_V02_SLICE1_PROMPT.md`
Date: 2026-09-09

## Verdicts (three lanes, R1)

| Lane | Verdict | C | H | M | L | INFO |
| --- | --- | --- | --- | --- | --- | --- |
| code-reviewer | REQUEST CHANGES | 0 | 0 | 6 | 0 | 2 |
| security-reviewer | BLOCK | 0 | 0 | 3 | 1 | — |
| architect | BLOCK | 0 | 0 | 5 | 0 | 2 |

All three lanes agreed on the same root shape: the Swift adapter composes the
existing shared safety layer correctly and no SSRF/loopback escape or earning-path
leak was found (all three lanes confirmed this explicitly), but the new evidence
layer asserted several things it had not established.

## Findings (deduplicated across lanes)

The fourteen MEDIUM/LOW findings deduplicate to eight distinct defects. "Lanes"
names every lane that raised it.

### F1 — Captured documents deleted required schema fields before hashing

Lanes: code-reviewer, security-reviewer (OWASP A08), architect.
`redact_for_capture()` recursively removed `provider_guidance.state_label_key`
and `state_meaning_key` from every captured document, then hashed the altered
object under the original schema name. SPEC-046-R003 requires both fields in
every `provider_guidance` object, so the digest the signed evidence binds to
could not prove the CLI emitted them, nor that they were localization-safe. The
runbook endorsed the lossy transform.

**Resolution.** Captures are archived whole; the stripping is gone.

- `scripts/byom_journey_evidence.py:119-135` — `GUIDANCE_OBJECT_KEY`,
  `GUIDANCE_LOCALIZATION_KEY_FIELDS`, and the closed grammar
  `LOCALIZATION_KEY_RE = ^byom\.[a-z0-9_]+(?:\.[a-z0-9_]+)+$`.
- `scripts/byom_journey_evidence.py:359-364` —
  `reject_unredacted_text_except_hostname()`: every rule (credential shapes,
  URL, absolute path, home-relative path, IPv4, IPv6, localhost) minus the
  shape-based DNS rule.
- `scripts/byom_journey_evidence.py:378-387` —
  `reject_unredacted_localization_key()`: the above, then the value must
  `fullmatch` the grammar. Anything else fails closed.
- `scripts/byom_journey_evidence.py:416-448` —
  `assert_captured_document_redacted()` and `_walk_captured_document()`: the
  field-scoped structural walk. The exemption applies only to those two field
  names, only when the enclosing object is a `provider_guidance` dict, at any
  depth (candidate rows, and top-level evaluation/dry-run/status/withdraw
  documents). Every key, every other string value, and every other field of the
  same guidance object keeps the full rule set.
- `scripts/byom_journey_evidence.py:597-615` — `_digest_document()`
  restructured: the DECODED structural walk is the authority for the hostname
  rule (it is the only scan that can tell a localization key from a hostname,
  and JSON escapes are already decoded when it runs); the raw-text scan over the
  archived bytes then runs every rule EXCEPT the hostname rule.
- `test/e2e/byom/run-discovery-journey.py:415-437` — the driver captures the
  whole document and runs the same imported functions.
- `assert_redacted()` / `_walk_redaction()` are unchanged: emitted evidence has
  no exemption at all, and never carries a `provider_guidance` object.
- Golden fixtures under `scripts/tests/fixtures/byom_journeys/` pass unchanged.

Tests: `scripts/tests/test_byom_journey_evidence.py:215-266` (keys accepted at
those paths; `coordinator.malibu.tech` at those paths rejected; the same
localization-key shape rejected in `next_action` and in `display_name`; an
escaped hostname in a captured document still rejected) and
`scripts/tests/test_discovery_journey_driver.py:236-278, 331-368`.

### F2 — Step 08 did not run the real scanner over actual CLI output

Lanes: code-reviewer, security-reviewer.
Raw stdout/stderr were checked only against a finite list of run-specific
strings. A forbidden-shaped value that was not in that list could pass while the
manifest claimed all JSON and stderr were clean.

**Resolution.** `test/e2e/byom/run-discovery-journey.py:346-384` — every command
the driver runs now has its parsed stdout put through the same field-aware
structured scan (the evidence module's own functions, imported, not
reimplemented), its raw stdout through the non-hostname rules, and its stderr
through the full generic scanner. Any failure fails the run and therefore step
08. The run-specific forbidden-string check is retained as an additional
assertion at `:979-1000`, now including the coordinator sink's origin and port.

### F3 — Step 10 asserts `not_offered` guidance it never observes — resolved

Lanes: code-reviewer, security-reviewer, architect. **Carried as BLOCKING.**

The journey contract (`journeys/JOURNEY-PROVIDER-BYOM-DISCOVERY.md:58-60`)
requires `local_only`, `offerable`, and local-default `not_offered` each to
report the provider-facing next action and local transition reason. The driver
verifies guidance for `local_only` and `offerable` from discovery, and takes
`not_offered` from `models catalog-economics`, whose admission object carries no
guidance fields — yet the step assertion claims all three reported both.

**No CLI surface can produce local-default `not_offered` with a
`provider_guidance` object.** Verified by exhaustive reading of every
`provider_guidance` emitter and every `local_default` producer:

- `localAdmissionState()`
  (`phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4053-4070`) returns
  only `local_only` or `offerable`. It is the sole admission-state source for the
  MLX-cache and Ollama candidate builders (`:3224`, `:3379`); the opaque-endpoint
  builder hardcodes `local_only` (`:3526`). Discovery therefore never emits a
  `not_offered` candidate.
- `models offer --dry-run` echoes the candidate's state through
  `localDefaultAdmissionState()` (`:2702-2708`), so its `likely_admission_state`
  can only be `not_offered` if a candidate already carried it — unreachable.
- `model_admission_status.v1` does define `local_default` + `not_offered` +
  guidance (`:824-826`, `:894-899`), but the CLI never constructs that wire
  locally. `decodeStrictStatus()` only decodes a **coordinator** response, and
  the single non-decoder construction
  (`withLocalCandidateIdentityIfCoordinatorHasNoOffer`, `:1810-1824`) is guarded
  on `admissionStateSource == "coordinator"`. `models admission status` requires
  a coordinator URL and a bearer token, and a pre-BYOM coordinator (404/405)
  produces an error exit, not a document.
- `model_catalog_economics.v1` does emit local-default `not_offered` rows
  (`ModelCatalogEconomics.swift:436-445`) but its `Admission` struct
  (`ModelCatalogEconomics.swift:49-56`) has no guidance fields at all.

Driving this through a coordinator stub was rejected: the resulting document
would carry `admission_state_source: "coordinator"`, would be the stub's
assertion rather than the CLI's, and would contradict F4's requirement that the
coordinator ledger finish empty.

This is a CLI gap, not a harness gap. SPEC-046 explicitly contemplates the state
(`specs/SPEC-046-provider-byom-discovery.md:92` — local_default `not_offered`
means "coordinator state is unavailable or has not been queried"; `:96` — a
locally eligible candidate may move between `offerable` and `not_offered` as
coordinator reachability changes), but the implementation always chooses
`offerable` and never emits the local-default `not_offered` label. Closing it
means adding a CLI code path that produces that label with guidance — a
governed wire-behaviour change under SPEC-046-R003/R008 that belongs in its own
change with its own SPEC confirmation.

**Resolution.** The CLI now produces the ladder row. `models admission status
<candidate> --json` emits a `model_admission_status.v1` document with
`admission_state_source: "local_default"`, `admission_state: "not_offered"`,
`coordinator_event_id` and `state_observed_at` null, `allowed_next_states` empty
(SPEC-047-R002 for a candidate that has not entered coordinator admission),
`provider_guidance.transition_reason_code: "coordinator_state_unavailable"`, and
the same warning code in `warnings`, in exactly two situations: no coordinator is
configured, or a configured coordinator is unreachable or serves no admission
route (404/405). 401/403, 503 (which keeps its #1448 `wait_for_coordinator`
mapping), any other status, and any decodable response all stay errors.

- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:23-26` —
  `BYOMDiscoveryWarning.coordinatorStateUnavailable`, the R003 warning code
  nothing emitted before.
- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4181-4200` —
  `BYOMDiscoveryGuidance.localNotOfferedGuidance(warnings:)`. The reason code is
  the R003 warning code; the next action is taken from the `offerable` row so the
  two rows stay action-neutral as the ladder requires (`evaluate` while the
  candidate is unevaluated, `offer_dry_run` otherwise); the earning path class is
  the existing local `local_inventory_only`.
- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:1788-1824` —
  `BYOMModelAdmissionRuntime.status` falls through to the local ladder for an
  absent route or an unreachable host, and only for those.
- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:1826-1850` —
  `isAdmissionRouteAbsent` / `isCoordinatorUnreachable`, the closed trigger set.
- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:1852-1893` —
  `localDefaultStatus`: an `offerable` candidate takes the `not_offered` row, a
  `local_only` candidate keeps its own state and guidance, an unresolvable target
  is `candidateNotFound` rather than invented inventory, and the source is never
  `coordinator`.
- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:694-729` —
  `BYOMAdmissionStatusWire.encode(to:)` writes the nullable keys explicitly, so
  the emitted document satisfies the closed SPEC-047-R002 envelope and round-trips
  through `decodeStrictStatus`.
- `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:281-300,
  541-572` — `models admission status` accepts a missing `coordinator_url` and
  builds no client; offer and withdrawal still require one.
- `test/e2e/byom/run-discovery-journey.py:922-988` — step 10 reaches the row
  through `models admission status` with no coordinator configured at all, and
  asserts the coordinator sink ledger and connection count are unchanged across
  it. The step-10 assertion now states exactly what is checked: all three states
  report a closed next action; `local_only` and `not_offered` each report a
  non-null local transition reason; `offerable` reports the nullable field with
  no blocker to name (SPEC-046-R003 makes it nullable, and inventing a code for
  an unblocked candidate was rejected).

Tests: `phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift:669-727`
(pre-BYOM 404/405 — transport still refuses to fabricate a coordinator state, and
the runtime now answers with the local-default document), `:728-755` (a decodable
unknown schema stays an error), `:757-802` (no coordinator configured: the
document, plus zero probe requests), `:804-830` (unreachable coordinator: the
document, plus exactly one attempted request), `:832-855` (401/403 stay errors),
`:857-883` (503 keeps the `wait_for_coordinator` mapping), `:885-918`
(`local_only` candidate keeps its own row), `:920-940` (the document round-trips
through the strict decoder with its nullable keys present as null).

### F4 — Two negative observations were literals, not measurements

Lanes: code-reviewer, architect.
`buyer_traffic_sent` and `provider_credit_created` were assigned `False`
directly, with no preceding independent check, contradicting the driver's and
runbook's claim that every observation comes from the driver's own assertions.

**Resolution.** Both now derive from harness-owned ledgers, checked at the end of
the run.

- `test/e2e/byom/run-discovery-journey.py:164-175` —
  `ConnectionRecordingHTTPServer` counts accepted connections, not only parsed
  requests, so a TLS handshake or half-open probe against the port still
  registers.
- `test/e2e/byom/run-discovery-journey.py:285-309` — `CoordinatorSinkHandler`
  records every request and serves nothing (503), so a leaked request is recorded
  and then fails rather than being satisfied by a fabricated document.
- `test/e2e/byom/run-discovery-journey.py:580-591` — the sink is configured as
  the CLI's coordinator (`MACPROVIDER_COORDINATOR_URL`) for every command in the
  run.
- `test/e2e/byom/run-discovery-journey.py:1005-1048` — before assignment:
  the harness started no buyer gateway (checked against the harness's own
  complete server list); the only chat request anywhere in the run is the
  evaluation's single local probe to the adapter stub, and no chat request
  reached any other stub; the coordinator sink finished with an empty request
  ledger and zero accepted connections. Any violation fails the run before the
  observation is set.
- Runbook provenance sentence rewritten at
  `docs/runbooks/byom-journey-evidence.md:102-112`.

### F5 — Executed binary was not bound to `source_sha`

Lanes: code-reviewer (MEDIUM), architect (MEDIUM), security-reviewer (LOW).
`MACPROVIDER_CLI_BINARY` could point at any executable while the wrapper
unconditionally recorded the repository `HEAD` as `source_sha`, so evidence could
be attributed to a commit it never executed.

**Resolution.** A new `--evidence` mode, used by the CI wrapper.

- `test/e2e/byom/run-discovery-journey.py:99-103` — `EVIDENCE_SOURCE_PATHS`
  (`phase3-binary`, `scripts`, `test/e2e/byom`).
- `test/e2e/byom/run-discovery-journey.py:115-160` —
  `require_clean_evidence_source()` (tracked-only `git status --porcelain
  --untracked-files=no` over those paths, empty or fail closed) and
  `build_cli(..., evidence_mode)`, which refuses `MACPROVIDER_CLI_BINARY` in
  evidence mode and builds from the current source. Non-evidence local runs keep
  the override.
- `scripts/test-byom-discovery-journey.sh:44-48` — the gate passes `--evidence`.
- The manifest schema is unchanged.

### F6 — The new parser duplicated the shared record-count bound

Lane: code-reviewer.
`parseOpenAIModels` hardcoded `rawModels.prefix(100)` separately from
`parseOllamaTags`, contradicting the #1246 invariant that the adapter
reimplements no parser-bound logic, and the boundary test covered Ollama only.

**Resolution.** `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:3592-3610`
— `BYOMDiscoveryHTTPBounds.maxInventoryRecords` and
`boundedInventoryRecords(_:)`; both parsers call it (`:3633`, `:3683`).
Test: `phase3-binary/Tests/macprovider-cliTests/BYOMDiscoveryTests.swift:1061-1104`
— `testOpenAICompatibleRedactionDoesNotInspectPastSharedRecordBound`, mirroring
the Ollama test including the withheld-record-beyond-the-cap condition.

### F7 — A failed rerun could leave a stale passing manifest

Lane: security-reviewer (OWASP A08).
The driver accepted an existing output directory and wrote `run-manifest.json`
only on success, so a failed rerun into a previously successful directory left
that pass manifest consumable.

**Resolution.**
- `test/e2e/byom/run-discovery-journey.py:492-508` — `prepare_out_dir()` requires
  a new or empty directory and creates it mode 0700. Operator data is refused,
  never deleted.
- `test/e2e/byom/run-discovery-journey.py:482-490` — the manifest is written to
  a temp file and `os.replace`d into place, only after every step and observation
  check has passed.
- Regression tests: `scripts/tests/test_discovery_journey_driver.py:386-405`
  (`test_a_failed_rerun_cannot_reuse_a_stale_manifest_directory`,
  `test_a_failed_run_publishes_no_manifest`).

### F8 — `not_configured` was a new, undocumented wire status

Lane: architect.
With no origin supplied the runner appended an adapter row with
`status: "not_configured"`, a value SPEC-046 does not define, and added a row to
the no-flag projection that existing consumers had not seen.

**Resolution.** The row is omitted entirely, matching the existing Ollama
skip behaviour.
`phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:2069-2089` — the
`else` branch and the `unconfiguredAdapter` constant are gone. No new wire value
is introduced.
Test: `phase3-binary/Tests/macprovider-cliTests/BYOMDiscoveryTests.swift:1102-1136`
— the frozen `not_configured` assertion is replaced by absence of the row, parity
with the skipped Ollama adapter, and a check that every emitted adapter status
stays inside the existing vocabulary.

## Carried items

- **F3 (MEDIUM × 3 lanes) — resolved.** The CLI change described under F3 above
  landed in this branch; no item is carried.
- INFO (code-reviewer, architect): the adapter's reuse of the shared origin
  validator, bounded no-proxy/no-redirect transport, and runtime-reference guard
  was confirmed correct by all three lanes; no SSRF or loopback escape was found;
  opaque candidates remain null-catalog, null-capability, `local_only`, and
  non-submittable. CI placement beside `test-byom-e2e` and the changed-path
  classifier were confirmed correct. No action.

## Merge bar

0 CRITICAL / 0 HIGH / 0 MEDIUM required. F1 through F8 are resolved. The fixes
have not yet been re-audited as a combined diff; re-run the three lanes over the
full fix before merging.
