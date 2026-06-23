# AUDIT_SPEC_015_v0_2_IMPL_STEP_1 — phase7 verifier scaffold audit

You are auditing Step 1 of
`specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` on branch
`impl/spec-015-v0-2-step-01`.

## Normative sources

- `specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` Step 1.
- `specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md`
  "Dependencies (HARD constraint)".
- `specs/SPEC-015-receipts.md` v0.2.4, especially §10.4 and §10.4.4.
- `phase4-coordinator/go.mod` for the repo Go version.
- `.github/workflows/ci.yml` for existing CI job style.

## Scope

Step 1 is limited to creating the `phase7-verify/` Go module scaffold and
its CI gate. The intended modified paths are:

- `.github/workflows/ci.yml`
- `phase7-verify/**`
- `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_1_PROMPT.md`

No `phase3-binary`, `phase4-coordinator`, `phase5-gateway`, or locked
`specs/SPEC-*.md` files should be modified by this step.

## Intended implementation

1. `phase7-verify/` exists as a standalone Go module with module path
   `github.com/augstar/macprovider/phase7-verify` and a Go version matching
   `phase4-coordinator/go.mod`.
2. `phase7-verify/go.sum` exists and is byte-empty. No external Go module is
   used.
3. Directory layout matches the BUILD prompt Step 1 scaffold:
   - `cmd/macprovider-verify/main.go`
   - `internal/jcs/jcs.go`
   - `internal/canon/canon.go`
   - `internal/receipt/receipt.go`
   - `internal/cache/cache.go`
   - `internal/resolver/resolver.go`
   - `internal/verify/verify.go`
   - `internal/cli/cli.go`
   - `internal/version/version.go`
   - `testdata/.gitkeep`
   - `schemas/.gitkeep`
   - `README.md`
   - `LICENSE`
   - `Makefile`
   - `implementation-notes.md`
4. Internal package files are stubs only and contain later-step TODO comments.
   No receipt parsing, canonicalization, resolver, cache, or verification
   logic is implemented.
5. `internal/version/version.go` exports exactly:
   - `BinaryVersion = "0.1.0-step1-scaffold"`
   - `MaxSPECVersion = "0.2.4"`
6. The CLI parses the full SPEC-015 §10.4 / §10.4.4 flag set:
   `--receipt`, `--prompt-hash`, `--output-hash`, `--bundle`, `--pubkey`,
   `--provider-id`, `--json`, `--offline`, `--quiet`, `--coordinator`,
   `--explain`, plus scaffold-only `--version` and `--help`.
7. `--version` prints exactly:
   `macprovider-verify <BinaryVersion> (verifies up to SPEC-015 v<MaxSPECVersion>)`.
8. `--help` prints usage containing every §10.4 / §10.4.4 flag and no
   verifier-specific extras outside that set other than scaffold control flags
   `--version` and `--help`.
9. Any non-help/non-version invocation exits `64` with a Step 7 TODO message.
10. `MACPROVIDER_COORDINATOR` is read as the fallback default for
    `--coordinator`, but no resolver/network behavior is implemented.
11. CI adds `phase7-verify (go vet + test)` and runs:
    - `cd phase7-verify && go vet ./...`
    - `cd phase7-verify && go test ./... -race -count=1`
    - an explicit assertion that `phase7-verify/go.sum` is empty.
12. `phase7-verify/Makefile` includes `build`, `build-all`, `test`, `vet`,
    and `clean`. Cross-compilation targets explicitly set `GOOS`, `GOARCH`,
    and `CGO_ENABLED`.

## Audit tasks

Review the diff and report findings by severity.

### Code review lens

- Verify the CLI skeleton has deterministic exit codes for `--version`,
  `--help`, and placeholder verification invocations.
- Verify tests cover version output, help flag coverage, exit 0 for
  `--version`/`--help`, and exit 64 for no-args or placeholder bundle use.
- Verify the scaffold remains stdlib-only and does not import any external
  module.
- Verify no verification logic landed early.

### Architecture review lens

- Verify package boundaries match the planned Step 2-7 decomposition.
- Verify the CI job follows the existing repo pattern and is included in the
  aggregate required gate.
- Verify `README.md` is buyer-comprehensible for a scaffold and does not claim
  verification support before later steps land.
- Verify `implementation-notes.md` captures the Go version, license decision,
  and deviations from Step 1.

### Specific required checks

- Zero-external-dep invariant: `phase7-verify/go.sum` is empty.
- Directory layout matches BUILD prompt Step 1.
- CI gate wires correctly.
- Version-string format matches the BUILD prompt.
- Flag set in `--help` matches SPEC-015 §10.4 / §10.4.4 with no omissions and
  no verifier-specific extras outside §10.4, except `--version` and `--help`.
- License hygiene: `phase7-verify/LICENSE` is present and consistent with the
  main repo decision, or the placeholder/question is clearly surfaced.
- Makefile cross-compilation targets are sane by inspection. Do not invoke
  `make build-all` unless you choose to; inspection is sufficient for this
  audit item.

## Required local commands

Run or inspect equivalent fresh evidence:

```bash
git diff --check HEAD~2..HEAD
test ! -s phase7-verify/go.sum
cd phase7-verify && go vet ./... && go test ./... -race -count=1
cd phase7-verify && make build
./phase7-verify/macprovider-verify --version
./phase7-verify/macprovider-verify --help
./phase7-verify/macprovider-verify --bundle /dev/null; test $? -eq 64
```

## Severity contract

- `CRITICAL`: external Go dependency introduced; non-empty `go.sum`; locked
  spec or out-of-scope runtime module modified; verification logic implemented
  in Step 1; CI omits the verifier gate entirely.
- `MAJOR`: missing required directory/package; missing required CLI flag;
  wrong version constants or version string format; placeholder invocations do
  not exit 64; CI exists but does not run vet/test/race or does not assert
  empty `go.sum`; license file absent without an implementation-note question.
- `MINOR`: README clarity, Makefile polish, naming/doc issues, or test gaps
  that do not threaten the scaffold contract.

The lock gate for this step is 0 CRITICAL and 0 MAJOR.

## Expected output

Return:

1. Verdict: `READY` or `NEEDS FIX PASS`.
2. Counts: `CRITICAL n / MAJOR n / MINOR n`.
3. Findings grouped by code and architecture lens, with concrete file/line
   references.
4. Verification commands actually run and their results.
5. Residual non-blocking notes.
