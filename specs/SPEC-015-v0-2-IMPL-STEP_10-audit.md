# SPEC-015 v0.2 Step 10 audit

## Round 1 by Codex

Baseline: `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_10_PROMPT.md`, extended with code, security, and architect lenses per the Round 1 instructions.

### Code lens

#### LOW

1. `phase7-verify/cmd/macprovider-verify/main_test.go:100`
   Issue: Two test comments still describe final CLI behavior as "scaffold" behavior (`main_test.go:100-102`, `main_test.go:111-112`).
   Risk: Non-runtime documentation drift; it does not affect behavior, constants, release output, or README buyer-facing claims.
   Evidence: Buyer-facing scaffold language was removed from `phase7-verify/README.md`; `phase7-verify/internal/version/version.go:1-8` now reflects Step 10 final acceptance.
   Fix: Rename those comments to "CLI" or "run" behavior in a cleanup pass.

#### INFO

- `phase7-verify/internal/version/version.go:7-8` sets `BinaryVersion = "1.0.0"` and `MaxSPECVersion = "0.2.4"`.
- `phase7-verify/internal/version/version_test.go:38-48` pins Step 10 exact constants; the regex format test remains at `version_test.go:8-35`.
- `phase7-verify/internal/cli/cli.go:99-101` composes `--version` from `version.BinaryVersion` and `version.MaxSPECVersion`; no duplicate literal in `cli.go`.
- `phase7-verify/internal/cli/cli_test.go:598-604` and `phase7-verify/cmd/macprovider-verify/main_test.go:20-22` assert composed output using the constants.
- Built binary output exactly matched: `macprovider-verify 1.0.0 (verifies up to SPEC-015 v0.2.4)`.
- `phase7-verify/README.md:68-82` covers every flag printed by `--help`.
- `phase7-verify/README.md:94-102` matches SPEC-015 §10.4.3 exit codes `0/1/2/64/65`.
- `phase7-verify/README.md:108`, `phase7-verify/README.md:114`, and `phase7-verify/README.md:118` cover schema, v1.0.x compatibility, and §10.6 trust-boundary links.

Code verdict: READY TO LOCK.
Residual risk: Release workflow execution itself was not run on GitHub Actions; local build, tests, YAML parsing, and workflow inspection passed.

### Security lens

#### INFO

- `.github/workflows/release-verify.yml:14-15` limits release permissions to `contents: write`.
- `.github/workflows/release-verify.yml:25-30` and `.github/workflows/release-verify.yml:100-113` pin checkout/setup-go by SHA, matching the existing release workflow pattern.
- `.github/workflows/release-verify.yml:122-127` builds with `CGO_ENABLED=0`, `-trimpath`, and `-ldflags="-s -w"`.
- `.github/workflows/release-verify.yml:129-136` runs each built matrix binary with `--version` and aborts on grep mismatch.
- `.github/workflows/release-verify.yml:138-145` computes per-binary SHA-256 files.
- `.github/workflows/release-verify.yml:146-158` attaches the binary, checksum, and `phase7-verify/schemas/output.schema.json` to the GitHub Release.
- Search found no Homebrew tap, package-registry, Docker/GHCR, npm, or package-push behavior in the verifier release workflow.
- `git diff --name-only impl/spec-015-v0-2-step-09 -- '**/go.mod' '**/go.sum'` produced no output; no external Go dependencies were added.

Security verdict: READY TO LOCK.
Residual risk: GitHub token release publishing is still an external side effect of the workflow; the workflow is constrained to GitHub Release asset creation only.

### Architect lens

#### LOW

1. `beta/DECISION_CRITERIA.md:371`
   Issue: Entry 83 was inserted above Entry 82 instead of being appended at the physical end of the decision-log table. The table continues after it, including `beta/DECISION_CRITERIA.md:379`.
   Risk: Traceability/order hygiene only; the entry body includes the required lock date, audit-round counts, final v1.0.0 state, AC coverage, fixtures/schema/coordinator status, and SPEC-006 honesty-gate rationale.
   Fix: Move Entry 83 to the physical end of the decision-log table before the one-line summary.

#### INFO

- `.github/workflows/release-verify.yml:3-12` has both `push` tags `verify-v*.*.*` and `workflow_dispatch` with required `version` input.
- `.github/workflows/release-verify.yml:84-98` defines exactly three build targets: darwin-arm64, darwin-amd64, and linux-amd64.
- `.github/workflows/release.yml` is unchanged from `impl/spec-015-v0-2-step-09`.
- `README.md:22` and `README.md:113-137` replace the old planned/not-implemented receipt language with shipped verifier language and link to `phase7-verify/README.md`.
- Scope guard passed: no `phase4-coordinator/internal/**`, `phase5-gateway/internal/**`, locked `specs/SPEC-*.md`, `go.mod`, or `go.sum` changes in the Step 10 diff.
- Determinism spot-check passed: `/tmp/v1` and `/tmp/v2` were byte-identical with SHA-256 `33614398acf90067105b381f3aa96d4f5a67a4922bf87485ce3ee2e119740968`.

Architect verdict: READY TO LOCK.
Residual risk: Decision-log ordering should be cleaned before merge for archival hygiene, but it is below the CRITICAL/HIGH/MEDIUM lock gate.

### Verification evidence

- `cd phase7-verify && go vet ./...` passed.
- `cd phase7-verify && go test ./... -race -count=1` passed.
- `cd phase7-verify && go test -tags=integration -count=1 -timeout 120s ./...` passed, including 11 committed bundle fixtures, generator idempotency, and previous-key cache regression coverage.
- `cd phase4-coordinator && go test ./internal/buyer/... -count=1` passed.
- `cd phase7-verify && go build -o /tmp/macprovider-verify-step10 ./cmd/macprovider-verify` passed.
- `/tmp/macprovider-verify-step10 --version` output exactly `macprovider-verify 1.0.0 (verifies up to SPEC-015 v0.2.4)`.
- `/tmp/macprovider-verify-step10 --help` listed `--version`, `--help`, `--bundle`, `--receipt`, `--prompt-hash`, `--output-hash`, `--pubkey`, `--provider-id`, `--json`, `--offline`, `--quiet`, `--coordinator`, and `--explain`.
- `test -z "$(git diff impl/spec-015-v0-2-step-09 -- phase7-verify/go.sum)"` passed.
- `python3 -c "import yaml; yaml.safe_load(open('../.github/workflows/release-verify.yml'))"` passed from `phase7-verify/`.
- `git diff impl/spec-015-v0-2-step-09 -- .github/workflows/release.yml` produced no output.
- `go build -trimpath -ldflags="-s -w" -o /tmp/v1 ./cmd/macprovider-verify` and `/tmp/v2` produced matching SHA-256 `33614398acf90067105b381f3aa96d4f5a67a4922bf87485ce3ee2e119740968`.

Overall verdict: READY TO LOCK (0 CRITICAL, 0 HIGH, 0 MEDIUM; 2 LOW, 0 blocking).
