# Audit Prompt: SPEC-015 v0.2 Implementation Step 8

Audit the Step 8 output-formatting implementation on branch
`impl/spec-015-v0-2-step-08`.

Scope the audit to:

- `phase7-verify/internal/cli/output.go`
- `phase7-verify/internal/cli/output_test.go`
- `phase7-verify/internal/cli/cli.go`
- `phase7-verify/internal/cli/cli_test.go`
- `phase7-verify/internal/verify/verify.go` only where it preserves
  `CoordinatorHost` for human-mode stale-cache output
- `phase7-verify/schemas/output.schema.json`

Normative references:

- `specs/SPEC-015-receipts.md` §10.4.2
- `specs/SPEC-015-receipts.md` §10.6
- `specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` Step 8

Required checks:

- Confirm JSON output uses a CLI-owned payload shape, not direct
  `verify.Result` serialization, and emits exactly one newline-terminated
  JSON object.
- Confirm top-level field dispositions:
  `provider_id`, `model_id`, `signed_at`, and `coordinator_host` render as
  JSON `null` when their §10.4.2 zero/none disposition applies.
- Confirm `details` is present for `invalid` and absent for `valid` and
  `inconclusive`.
- Confirm `details.computed` is absent only for `field == "signature"` and is
  present for all other invalid detail fields.
- Confirm `warnings` is omitted when empty and preserved in JSON even when
  `--quiet` suppresses stderr.
- Confirm warning JSON is flat:
  `{"kind":"...","<field>":"<value>"}` with no nested `fields` object.
- Confirm stderr warning lines match §10.4.2 / Step 8:
  `non_default_coordinator`, `explicit_vs_live_divergence`,
  `live_check_skipped`, and `clock_skew`.
- Confirm human-mode line shapes match §10.4.2:
  `valid (...)` with RFC3339 signed time and `trust=<source>@<host>` for
  live/cache; no `@host` suffix for `explicit_pubkey`; invalid mismatch and
  grace-window forms; inconclusive reason translations including
  cache-stale host text.
- Confirm `--explain` still prints §10.6 text after valid results and remains
  suppressed by `--quiet`.
- Confirm `phase7-verify/schemas/output.schema.json` is a shipped Draft-07
  artifact, not a test fixture.
- Confirm schema completeness:
  it accepts every legal `valid`, `invalid`, and `inconclusive` output shape
  emitted by this implementation and rejects illegal variants.
- Confirm per-result required fields:
  valid requires `result`, `reason`, `provider_id`, `model_id`, `signed_at`,
  `trust_source`, `coordinator_host`, and forbids `details`;
  invalid requires the same plus `details`;
  inconclusive requires `result`, `reason`, `trust_source`,
  `coordinator_host`, permits nullable identity/timestamp fields, and forbids
  `details`.
- Confirm `additionalProperties: false` enforcement on every object whose
  shape is pinned by §10.4.2, including warning objects and `details.extra`.
- Confirm enum coverage:
  3 `result` values, 10 `reason` values, 4 `trust_source` values,
  5 `details.field` values, and 4 warning `kind` values.
- Confirm schema validation tests load the shipped schema artifact and validate
  valid, invalid, and inconclusive fixtures against it.
- Confirm the schema rejects extra top-level properties.
- Confirm no new external Go dependency was added for schema validation.
- Confirm there is no Step 9 scope creep into fixture generation and no Step 10
  scope creep into release artifacts/versioning.

Validation commands to run:

```bash
cd phase7-verify && go vet ./...
cd phase7-verify && go test ./... -race -count=1
cd phase7-verify && go build -o /tmp/macprovider-verify-step8 ./cmd/macprovider-verify
/tmp/macprovider-verify-step8 --version
/tmp/macprovider-verify-step8 --help
```

Report CRITICAL/MAJOR/MINOR findings first with file and line references.
If no issues are found, state that explicitly and cite the validation commands.
