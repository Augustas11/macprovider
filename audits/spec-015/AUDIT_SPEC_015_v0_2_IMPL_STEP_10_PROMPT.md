# Audit Prompt: SPEC-015 v0.2 Implementation Step 10

Audit Step 10 of `BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` on branch
`impl/spec-015-v0-2-step-10`.

This is the final release-artifacts and acceptance audit for the SPEC-015 v0.2
verifier. Scope the audit to Step 10 changes only; do not re-litigate locked
SPEC text or re-design Steps 0-9 unless Step 10 introduced a regression.

Normative references:

- `specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` Step 10
- `specs/SPEC-015-receipts.md` section 10, especially 10.4, 10.4.3,
  10.4.4, 10.6, and 10.7

Required checks:

1. Version-constant integrity:
   - Confirm `phase7-verify/internal/version/version.go` sets
     `BinaryVersion = "1.0.0"` and keeps `MaxSPECVersion = "0.2.4"`.
   - Confirm the exact-constant test was renamed for Step 10 final acceptance
     and no Step 1 scaffold pin remains.
   - Confirm `--version` output is composed from `version.BinaryVersion` and
     `version.MaxSPECVersion`; it must not duplicate either value as a second
     source of truth.
   - Confirm built output is exactly:
     `macprovider-verify 1.0.0 (verifies up to SPEC-015 v0.2.4)`.

2. Release workflow reproducibility:
   - Confirm `.github/workflows/release-verify.yml` is new and
     `.github/workflows/release.yml` remains unmodified.
   - Confirm triggers are tag pushes matching `verify-v*.*.*` and
     `workflow_dispatch` with a `version` input.
   - Confirm permissions are limited to `contents: write`.
   - Confirm checkout and setup-go actions are pinned by SHA.
   - Confirm Go is fixed to a Go 1.22+ line.
   - Confirm the build matrix covers exactly `darwin-arm64`, `darwin-amd64`,
     and `linux-amd64`.
   - Confirm each build uses `go build -trimpath -ldflags="-s -w"` from
     `phase7-verify` and produces the expected asset name.
   - Confirm checksum files use a reproducible SHA-256 format.

3. Release workflow smoke behavior:
   - Confirm the smoke step actually executes the built binary for each matrix
     target before upload.
   - Confirm the smoke check fails the job unless `--version` contains
     `1.0.0 (verifies up to SPEC-015 v0.2.4)`.
   - Confirm the binary, checksum, and `phase7-verify/schemas/output.schema.json`
     are attached to the GitHub Release.

4. README accuracy:
   - Confirm `phase7-verify/README.md` is buyer-facing and no Step 1 scaffold
     language remains.
   - Confirm every flag printed by `macprovider-verify --help` appears in the
     README CLI reference with semantics consistent with SPEC-015 section
     10.4 and 10.4.4.
   - Confirm the exit-code table matches SPEC-015 section 10.4.3.
   - Confirm the JSON schema link points to the shipped
     `schemas/output.schema.json`.
   - Confirm the version-compatibility table says `1.0.x` verifies `0.2.0`
     through `0.2.4`.
   - Confirm the trust-boundary section links to SPEC-015 section 10.6.
   - Confirm the Reporting section documents that gateway receipt-header
     forwarding was verified when PR #123 landed and does not add a new SDK
     smoke script.

5. Root README honesty:
   - Confirm the root README no longer says SPEC-015 v0.2 verifier receipts
     are "planned" or "not yet implemented".
   - Confirm the top copy links buyers to `phase7-verify/README.md`.
   - Confirm the Roadmap section says the verifier shipped in v1.0.0.

6. Decision-log Entry 83:
   - Confirm `beta/DECISION_CRITERIA.md` appends Entry 83 in the decision-log
     section and does not overwrite or reorder unrelated entries.
   - Confirm Entry 83 includes the SPEC lock date, audit-round summary, 11-step
     IMPL phase, per-step audit counts, final v1.0.0 state, AC-18..AC-27,
     11 deterministic golden fixtures, Draft-07 JSON Schema gate, coordinator
     handler status, and the SPEC-006 honesty-gate rationale.
   - Confirm the style matches neighboring entries.

7. Regression and dependency guard:
   - Confirm no new external Go dependencies were added and `phase7-verify/go.sum`
     is unchanged.
   - Confirm no locked `specs/SPEC-*.md` file was modified.
   - Confirm no regression on Steps 0-9 by running the full validation suite.

Validation commands to run:

```bash
cd phase7-verify && go vet ./...
cd phase7-verify && go test ./... -race -count=1
cd phase7-verify && go test -tags=integration -count=1 -timeout 120s ./...
cd phase4-coordinator && go test ./internal/buyer/... -count=1
cd phase7-verify && go build -o /tmp/macprovider-verify-step10 ./cmd/macprovider-verify
/tmp/macprovider-verify-step10 --version
/tmp/macprovider-verify-step10 --help
yq eval .github/workflows/release-verify.yml > /dev/null
gh workflow view release-verify --workflow=.github/workflows/release-verify.yml
git diff -- phase7-verify/go.sum
```

If `yq` is unavailable, use a Python YAML parser only as a local tooling
fallback and report that substitution.

Report CRITICAL/MAJOR/MINOR findings first with file:line evidence and exact
reproduction commands. If no blocking findings remain, state `READY TO LOCK`.
