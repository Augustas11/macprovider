# SPEC-015 v0.2 Step 8 audit

## Round 1 by Codex

Scope audited: `impl/spec-015-v0-2-step-08` against base `impl/spec-015-v0-2-step-07`, using `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_8_PROMPT.md` plus the requested code/security/architect lenses. This was a read-only audit except for appending this report.

### Code Lens

Findings, ordered by severity:

1. **HIGH - Reason enum drift: the published schema/code omit the spec-listed bundle mismatch invalid reason.**  
   `specs/SPEC-015-receipts.md:1822`-`1827` lists the v0.2.x reason enum and includes `bundle_pubkey_provider_mismatch` under `invalid`. The schema invalid branch at `phase7-verify/schemas/output.schema.json:87`-`95` permits only `signature_verify_failed`, `prompt_hash_mismatch`, `output_hash_mismatch`, `pubkey_not_endorsed`, and `previous_key_outside_grace_window`. The verifier constants at `phase7-verify/internal/verify/verify.go:27`-`36` also have no `bundle_pubkey_provider_mismatch` reason. Result: the release schema rejects a spec-legal invalid JSON output, and the implementation has no way to emit that mandated reason. `provider_id_unresolvable` is intentionally present in the schema at `phase7-verify/schemas/output.schema.json:187`-`193` and is supported by verifier mapping at `phase7-verify/internal/verify/verify.go:391`-`407`, so that part is not the issue.

2. **LOW - Step 8 preserves the prior CLI quiet/explain behavior, but the test assertion remains mostly substring-based.**  
   The code path still suppresses stderr under `--quiet` at `phase7-verify/internal/cli/cli.go:120`-`125` while preserving JSON warnings through `renderJSON` at `phase7-verify/internal/cli/output.go:53`-`61`. The existing Step 7 assertions remain present at `phase7-verify/internal/cli/cli_test.go:233`-`258` and `phase7-verify/internal/cli/cli_test.go:318`-`325`; the only Step 7 assertion edited was the provider-not-in-pool human text at `phase7-verify/internal/cli/cli_test.go:367`-`382`. This is acceptable, but not a full byte-for-byte regression guard for all stderr combinations.

Code lens verdict: **NOT READY**.  
Residual risk: JSON output rendering is mostly correct, but the reason vocabulary is not aligned with the normative spec.

### Security Lens

Findings, ordered by severity:

1. **HIGH - The JSON Schema accepts trust-root states that §10.4.2 says must not exist.**  
   §10.4.2 says `trust_source: "none"` is only for `result == "inconclusive"` and `coordinator_host` must be non-null when `trust_source` is `live` or `cache`, and null for `explicit_pubkey` or `none` (`specs/SPEC-015-receipts.md:1815`-`1816`). The schema valid branch allows `trust_source` to be any of `explicit_pubkey`, `cache`, `live`, or `none` and allows `coordinator_host` as either string or null (`phase7-verify/schemas/output.schema.json:24`-`25`). The invalid branch repeats the same permissive shape (`phase7-verify/schemas/output.schema.json:99`-`100`). The renderer itself is stricter via `coordinatorHostOrNull` at `phase7-verify/internal/cli/output.go:189`-`194`, but AC-24 is the buyer/CI contract: a forged or buggy `{"result":"valid","trust_source":"none","coordinator_host":null,...}` shape would pass the published schema.

2. **INFO - Warning serialization is flat and deterministic.**  
   `jsonWarning.MarshalJSON` writes `kind` plus sorted top-level warning fields with no nested `fields` object at `phase7-verify/internal/cli/output.go:81`-`112`; `TestRenderJSONFlattensWarningFields` covers this at `phase7-verify/internal/cli/output_test.go:212`-`231`. The schema enforces per-kind warning shapes with `oneOf` and `additionalProperties: false` in each result branch, e.g. `phase7-verify/schemas/output.schema.json:26`-`68`.

Security lens verdict: **NOT READY**.  
Residual risk: The formatter emits stricter data than the schema accepts, so downstream schema-only consumers can accept semantically unsafe trust-root combinations.

### Architect Lens

Findings, ordered by severity:

1. **MEDIUM - AC-24 testing is unit-level schema coverage, not the published prompt's acceptance-fixture gate.**  
   The Step 8 build prompt requires `--json` output validation against `output.schema.json` for each result type across `testdata/*.bundle.json` fixtures (`specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md:342`). Current Step 8 tests validate three synthetic `verify.Result` fixtures through `renderJSON` (`phase7-verify/internal/cli/output_test.go:254`-`285`) and reject one extra-property input (`phase7-verify/internal/cli/output_test.go:287`-`292`). The inline validator does enforce `oneOf`, `not`, `required`, `enum`, `additionalProperties`, `items`, `if/then/else`, and nullable type arrays (`phase7-verify/internal/cli/output_test.go:372`-`467`), so this is not a validator hole. The architectural gap is that the schema gate is not wired to every CLI acceptance output/fixture yet.

2. **INFO - No Step 9 or Step 10 scope creep observed.**  
   Changed files are limited to CLI output/CLI tests/verify host preservation/schema/audit prompt; no `phase7-verify/testdata` fixture harness, release artifact packaging, LICENSE work, or version bump was introduced. `phase7-verify/go.sum` is unchanged against `impl/spec-015-v0-2-step-07`.

Architect lens verdict: **NOT READY**.  
Residual risk: The schema artifact is present, but the contract is not yet locked by end-to-end acceptance-fixture validation.

### Positive Coverage Notes

- JSON renderer uses a CLI-owned payload (`phase7-verify/internal/cli/output.go:16`-`26`), not direct `verify.Result` serialization.
- `provider_id`, `model_id`, `signed_at`, and `coordinator_host` render as JSON null through pointer fields where unresolved (`phase7-verify/internal/cli/output.go:40`-`49`, `phase7-verify/internal/cli/output.go:175`-`194`).
- `details` is emitted only for invalid results with non-nil details (`phase7-verify/internal/cli/output.go:50`-`52`) and is omitted for valid/inconclusive in tests (`phase7-verify/internal/cli/output_test.go:176`-`183`).
- `details.computed` is omitted for `field == "signature"` and present otherwise (`phase7-verify/internal/cli/output.go:69`-`78`; test at `phase7-verify/internal/cli/output_test.go:185`-`203`).
- Human-mode examples are covered for valid/invalid/inconclusive output shapes (`phase7-verify/internal/cli/output_test.go:85`-`128`), including RFC3339 signed time.
- JSON output is one line and newline-terminated through `json.Marshal` plus `append(data, '\n')` (`phase7-verify/internal/cli/output.go:62`-`66`) and `stdout.Write` (`phase7-verify/internal/cli/cli.go:377`-`384`).

### Verification Evidence

Commands run:

- `cd phase7-verify && go vet ./...` - passed.
- `cd phase7-verify && set -o pipefail; go test ./... -race -count=1 -v 2>&1 | tail -50` - passed; tail included passing AC-18 through AC-27 verify tests and package PASS lines.
- `cd phase7-verify && go build -o /tmp/macprovider-verify-r1 ./cmd/macprovider-verify` - passed.
- `/tmp/macprovider-verify-r1 --version` - printed `macprovider-verify 0.1.0-step1-scaffold`.
- `/tmp/macprovider-verify-r1 --help` - printed expected flags including `--json`, `--quiet`, `--coordinator`, and `--explain`.
- `test -z "$(git diff impl/spec-015-v0-2-step-07 -- phase7-verify/go.sum)"` - passed.
- `jq -e . phase7-verify/schemas/output.schema.json` - passed.
- `grep -n "additionalProperties\|oneOf\|\"enum\"" phase7-verify/schemas/output.schema.json | wc -l` - returned `29`.

Overall verdict: **NOT READY**. Target `READY TO LOCK` is not met because there are HIGH/MEDIUM findings across the lenses.

## Round 2 by Codex

Scope audited: `impl/spec-015-v0-2-step-08` at `a58301e` against base `impl/spec-015-v0-2-step-07`, with emphasis on the round-1 fix commit `a58301e`. This was a read-only audit of implementation state; the only write was appending this Round 2 report.

### Code Lens

Findings, ordered by severity:

- **CRITICAL (0)** - None.
- **HIGH (0)** - None.
- **MEDIUM (0)** - None.
- **LOW (0)** - None.

Resolution evidence:

- `bundle_pubkey_provider_mismatch` exists as a verifier reason constant at `phase7-verify/internal/verify/verify.go:33`.
- The invalid schema branch includes `bundle_pubkey_provider_mismatch` in its reason enum at `phase7-verify/schemas/output.schema.json:101`-`109`.
- `TestSchemaValidationReservedBundlePubkeyProviderMismatch` marshals a synthetic `verify.Result{Result: "invalid", Reason: "bundle_pubkey_provider_mismatch", Details: ...}` through `renderJSON` and validates it against the loaded schema at `phase7-verify/internal/cli/output_test.go:271`-`285` and `phase7-verify/internal/cli/output_test.go:382`-`390`.
- The inline validator evaluates `oneOf` branches, `allOf`, and nested `if/then/else`, including the newly added `allOf` handling at `phase7-verify/internal/cli/output_test.go:463`-`487` and `if/then/else` handling at `phase7-verify/internal/cli/output_test.go:551`-`564`.
- The only `cli_test.go` delta from Step 7 is the expected human-summary string for provider-not-in-pool, aligning the assertion with current output text; no CLI behavior regression was observed.

Code lens verdict: **READY TO LOCK**.  
Residual risk: The reserved mismatch reason is schema/test-covered but still intentionally has no Step 8 detection path.

### Security Lens

Findings, ordered by severity:

- **CRITICAL (0)** - None.
- **HIGH (0)** - None.
- **MEDIUM (0)** - None.
- **LOW (0)** - None.

Resolution evidence:

- Valid outputs constrain `trust_source` to exactly `explicit_pubkey`, `cache`, and `live` at `phase7-verify/schemas/output.schema.json:24`; the branch enforces `explicit_pubkey -> coordinator_host:null` and all other allowed values -> `coordinator_host:string` at `phase7-verify/schemas/output.schema.json:71`-`83`.
- Invalid outputs use the same three-value `trust_source` enum at `phase7-verify/schemas/output.schema.json:114` and the same coordinator-host coupling at `phase7-verify/schemas/output.schema.json:190`-`202`.
- Inconclusive outputs constrain `trust_source` to exactly `explicit_pubkey`, `cache`, `live`, and `none` at `phase7-verify/schemas/output.schema.json:227`; the branch enforces `explicit_pubkey|none -> coordinator_host:null` and `cache|live -> coordinator_host:string` at `phase7-verify/schemas/output.schema.json:274`-`286`.
- `TestSchemaRejectsTrustSourceCoordinatorHostMismatches` covers and rejects all five requested spec-illegal inputs at `phase7-verify/internal/cli/output_test.go:312`-`345`: valid+none, valid+live+null host, valid+explicit_pubkey+string host, inconclusive+live+null host, and inconclusive+none+string host.
- The targeted schema-test run passed all rejection subtests, confirming the inline validator does not silently skip the nested Draft-07 conditionals inside `oneOf` branches.

Security lens verdict: **READY TO LOCK**.  
Residual risk: Schema strictness now matches renderer strictness for the audited trust-source/coordinator-host contract.

### Architect Lens

Findings, ordered by severity:

- **CRITICAL (0)** - None.
- **HIGH (0)** - None.
- **MEDIUM (0)** - None.
- **LOW (0)** - None.

Resolution evidence:

- The Step 9 deferral is explicit: `bundle_pubkey_provider_mismatch` detection is documented as a bundle-layer check landing with Step 9 end-to-end fixtures and integration at `phase7-verify/internal/cli/implementation-notes.md:48`-`53`.
- The acceptance-fixture deferral is explicit: Step 8 ships the output schema, inline validator, and synthetic valid/invalid/inconclusive schema tests, while Step 9 owns `testdata/*.bundle.json` fixtures and schema-gated end-to-end integration at `phase7-verify/internal/cli/implementation-notes.md:55`-`58`.
- The fix did not broaden scope into Step 9 fixture wiring; `a58301e` only touched implementation notes, output schema/tests, and the reserved verifier constant.

Architect lens verdict: **READY TO LOCK**.  
Residual risk: End-to-end fixture gating remains Step 9 scope by design and is now documented unambiguously.

### Regression Evidence

Commands run:

- `cd phase7-verify && go vet ./...` - passed.
- `cd phase7-verify && go test ./... -race -count=1 -v 2>&1 | tail -40` - passed; the module contains 9 packages (`go list ./...`).
- `cd phase7-verify && go test ./internal/cli -run 'TestSchema(ValidationReservedBundlePubkeyProviderMismatch|RejectsTrustSourceCoordinatorHostMismatches|ValidationValid|ValidationInvalid|ValidationInconclusive)$' -count=1 -v` - passed, including all five mismatch rejection subtests.
- `cd phase7-verify && go build -o /tmp/macprovider-verify-r2 ./cmd/macprovider-verify` - passed.
- `/tmp/macprovider-verify-r2 --version` - printed `macprovider-verify 0.1.0-step1-scaffold`.
- `/tmp/macprovider-verify-r2 --help` - printed expected flags including `--json`, `--quiet`, `--coordinator`, and `--explain`.
- `test -z "$(git diff impl/spec-015-v0-2-step-07 -- phase7-verify/go.sum)"` - passed; `go.sum` is unchanged.
- `jq -e . phase7-verify/schemas/output.schema.json` - passed.
- `jq '.oneOf[] | {variant: .properties.result.const, trust_source_enum: .properties.trust_source.enum}' phase7-verify/schemas/output.schema.json` - showed valid/invalid enums as `explicit_pubkey`, `cache`, `live`; inconclusive as `explicit_pubkey`, `cache`, `live`, `none`.
- `grep -c "bundle_pubkey_provider_mismatch" phase7-verify/internal/verify/verify.go phase7-verify/schemas/output.schema.json phase7-verify/internal/cli/output_test.go` - returned counts `1`, `1`, and `3`.
- `grep -c "if\\|then\\|else" phase7-verify/schemas/output.schema.json` - returned `16`.
- `git diff --check impl/spec-015-v0-2-step-07...HEAD` - passed.

No new defects were found from adding the reserved reason or the schema `if/then/else` nests. No schema branch was observed to silently pass malformed trust-root combinations, and no existing test broke under `-race`.

Overall verdict: **READY TO LOCK**. All three lenses are `READY TO LOCK` with 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
