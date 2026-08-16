# SPEC-015 v0.2 Step 7 audit

## Round 1 by Codex

Scope audited: `phase7-verify/internal/cli`, `phase7-verify/cmd/macprovider-verify`, and the explicit hash bypass in `phase7-verify/internal/verify/verify.go`, against `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_7_PROMPT.md` plus the three required lenses.

Base: `impl/spec-015-v0-2-step-06`  
Branch: `impl/spec-015-v0-2-step-07`

### Findings ordered by severity

#### Code lens

- **MEDIUM - Required CLI conformance test coverage is incomplete.** The implementation is mostly aligned, but `cli_test.go` does not exercise every required §10.4.4 row and every §10.4.3/§10.4.1 boundary requested by this audit. The normative matrix says every listed interaction is pinned (`specs/SPEC-015-receipts.md:1909`) and missing provider-id behavior is exit 64, not `inconclusive` (`specs/SPEC-015-receipts.md:1725`). Current CLI tests cover many rows in `TestFlagInteractionMatrixRows` (`phase7-verify/internal/cli/cli_test.go:185`) and `TestUsageBoundaries` (`phase7-verify/internal/cli/cli_test.go:359`), but the following required cases are not covered by concrete CLI tests:
  - `--coordinator H` produces a `non_default_coordinator` warning when `H != coordinator.malibu.tech`. `TestCoordinatorEnvAndOverride` only checks parse/option precedence (`phase7-verify/internal/cli/cli_test.go:398`), not CLI result warnings.
  - `--explain` prints §10.6 verbatim, and `--quiet --explain` suppresses that stderr output. The current assertion only checks the first sentence substring (`phase7-verify/internal/cli/cli_test.go:311`).
  - Bundle strictness variants required by this audit: missing `bundle_version`, `bundle_version: 2`, `"1"`, `true`, missing `request`, and missing `response`. The current bundle table covers `99`, unknown top-level key, missing `receipt`, and malformed JSON (`phase7-verify/internal/cli/cli_test.go:151`).
  - CLI-level exit-65 receipt data boundaries: malformed receipt header with no `.`, tuple base64 decode failure, and signature/base64 tuple parse failures. These are covered lower in `receipt`/`verify` package tests (`phase7-verify/internal/receipt/receipt_test.go:82`, `phase7-verify/internal/verify/verify_test.go:214`), but not by a concrete CLI invocation as requested.

#### Security lens

- **MEDIUM - Security-sensitive parse boundaries are not locked at the CLI layer.** The code maps parse failures to exit 65 through `verify.InputFormatError` (`phase7-verify/internal/cli/cli.go:443`) and the receipt parser rejects no-dot and malformed base64 inputs (`phase7-verify/internal/receipt/receipt.go:73`), but the CLI tests do not prove that a bundle-embedded malformed receipt exits 65 before verifier-result classification. This matters because the audit explicitly calls out "malformed receipt header", "base64 decode failure on tuple", and "bundle JSON with embedded receipt that fails parse-time validation MUST return exit 65, not 1".

- **LOW - The CLI globally recovers panics into undocumented exit 70.** `run` catches all panics and returns `exitSoftware` (`phase7-verify/internal/cli/cli.go:82`). I found no current documented 64/65 case that is preempted by this path, and the requested validation suite passes, but the audit's "MUST NOT swallow panics" requirement is not fully demonstrated by the implementation or tests.

#### Architect lens

- **MEDIUM - CF7's fallback architecture lacks negative-path CLI tests for exact single-match semantics.** The implementation resolves provider id in the intended order: CLI flag, bundle field, then cache fallback by receipt pubkey under the normalized coordinator (`phase7-verify/internal/cli/cli.go:220`, `phase7-verify/internal/cli/cli.go:305`). It also requires exactly one distinct cache match (`phase7-verify/internal/cli/cli.go:333`, `phase7-verify/internal/cli/cli.go:352`). However, the CLI tests only cover the one-match success path (`phase7-verify/internal/cli/cli_test.go:376`) and no-match usage path (`phase7-verify/internal/cli/cli_test.go:375`); they do not cover two providers with the same receipt pubkey falling through to exit 64. That leaves the "zero or two+ -> fall through" architecture unpinned at the CLI contract layer.

### §10.4.4 row-to-test map

| Matrix row | CLI test mapping | Status |
|---|---|---|
| no `--pubkey`, no `--offline` default online path | `TestFlagInteractionMatrixRows/no pubkey no offline live fetch` (`phase7-verify/internal/cli/cli_test.go:198`) | Covered |
| `--pubkey P` no `--offline`; explicit wins; live divergence YES | basic online call covered at `phase7-verify/internal/cli/cli_test.go:206`; actual live divergence warning covered by `TestExplicitVsLiveDivergenceWarningDoesNotDowngrade` (`phase7-verify/internal/cli/cli_test.go:336`) | Covered |
| `--pubkey P --offline`; `live_check_skipped reason=offline_flag` | `phase7-verify/internal/cli/cli_test.go:213` | Covered |
| `--offline` no `--pubkey`; inconclusive on cache miss/stale | `phase7-verify/internal/cli/cli_test.go:220` | Covered |
| `--quiet` alone; stderr suppressed | `phase7-verify/internal/cli/cli_test.go:227` | Covered |
| `--quiet --json`; stderr suppressed; warnings still JSON | `phase7-verify/internal/cli/cli_test.go:234` | Covered |
| `--coordinator H`; non-default warning if not default | env/override precedence only at `phase7-verify/internal/cli/cli_test.go:398`; no CLI warning assertion | **Uncovered** |
| `--explain`; §10.6 verbatim printed after valid | substring assertion only at `phase7-verify/internal/cli/cli_test.go:311`; no verbatim/full text assertion | **Partially covered** |
| `--bundle B --receipt R`; exit 64 | `phase7-verify/internal/cli/cli_test.go:369` | Covered |
| `--bundle -`; stdin | `phase7-verify/internal/cli/cli_test.go:248` | Covered |
| `--provider-id I` + header+hashes, no `--pubkey`; addressed by I | `phase7-verify/internal/cli/cli_test.go:254` | Covered |
| `--provider-id I` + header+hashes + `--pubkey P`; explicit wins | `phase7-verify/internal/cli/cli_test.go:261` | Covered |
| `--provider-id I` + bundle provider_id J mismatch; exit 64 | `phase7-verify/internal/cli/cli_test.go:370` | Covered |
| `--provider-id I` + bundle provider_id I or none; proceed | `phase7-verify/internal/cli/cli_test.go:268` and `phase7-verify/internal/cli/cli_test.go:276` | Covered |
| header+hashes no `--provider-id`, no `--pubkey`; exit 64 | `phase7-verify/internal/cli/cli_test.go:371` | Covered |
| bundle/stdin no provider id anywhere, no `--pubkey`, no single-match cache; exit 64 | `phase7-verify/internal/cli/cli_test.go:375` | Covered for bundle; stdin form not separately covered |
| header+hashes + `--pubkey`, no `--provider-id`; no live fetch, `provider_id:null`, `provider_id_unresolvable` | no-live/warning at `phase7-verify/internal/cli/cli_test.go:284`; JSON null at `phase7-verify/internal/cli/cli_test.go:377` | Covered |

### §10.4.3 exit-code and boundary map

| Case | Test mapping | Status |
|---|---|---|
| exit 0 valid | `phase7-verify/internal/cli/cli_test.go:37` | Covered |
| exit 1 invalid | `phase7-verify/internal/cli/cli_test.go:45` | Covered |
| exit 2 inconclusive | `phase7-verify/internal/cli/cli_test.go:53` | Covered |
| exit 64 usage | `phase7-verify/internal/cli/cli_test.go:61` | Covered |
| exit 65 input format | `phase7-verify/internal/cli/cli_test.go:68` | Covered |
| `bundle_version=99` -> 65 | `phase7-verify/internal/cli/cli_test.go:152` | Covered |
| malformed bundle JSON -> 65 | `phase7-verify/internal/cli/cli_test.go:155` | Covered |
| unknown bundle top-level key -> 65 | `phase7-verify/internal/cli/cli_test.go:153` | Covered |
| missing required bundle field, drop `receipt` -> 65 | `phase7-verify/internal/cli/cli_test.go:154` | Covered |
| malformed receipt header, no `.` -> 65 | lower-level tests only (`phase7-verify/internal/receipt/receipt_test.go:82`, `phase7-verify/internal/verify/verify_test.go:214`) | **CLI gap** |
| base64 decode failure on tuple -> 65 | lower-level receipt test only (`phase7-verify/internal/receipt/receipt_test.go:85`) | **CLI gap** |
| unknown flag -> 64 | `phase7-verify/internal/cli/cli_test.go:372`; command wrapper also `phase7-verify/cmd/macprovider-verify/main_test.go:100` | Covered |
| missing required flag -> 64 | `phase7-verify/internal/cli/cli_test.go:61` | Covered |
| mutual exclusion -> 64 | `phase7-verify/internal/cli/cli_test.go:369` | Covered |
| malformed `--pubkey` base64 -> 64 | `phase7-verify/internal/cli/cli_test.go:373` | Covered |
| valid base64 `--pubkey` wrong length -> 64 | `phase7-verify/internal/cli/cli_test.go:374` | Covered |
| header+hashes no provider id/no pubkey -> 64 | `phase7-verify/internal/cli/cli_test.go:371` | Covered |
| provider-id mismatch vs bundle provider_id -> 64 | `phase7-verify/internal/cli/cli_test.go:370` | Covered |

### Implementation confirmations

- Provider-id resolution order is correct in code: `--provider-id` first (`phase7-verify/internal/cli/cli.go:306`), bundle `provider_id` second (`phase7-verify/internal/cli/cli.go:309`), cache fallback by parsed receipt pubkey third (`phase7-verify/internal/cli/cli.go:312`), missing provider id without `--pubkey` exits 64 with an error naming `--provider-id` (`phase7-verify/internal/cli/cli.go:224`).
- The single-match cache fallback requires exactly one distinct provider id (`phase7-verify/internal/cli/cli.go:333`, `phase7-verify/internal/cli/cli.go:352`). Zero or two+ fall through to missing-provider handling.
- Bundle decoding uses `json.Decoder.DisallowUnknownFields()` on the whole bundle object (`phase7-verify/internal/cli/cli.go:250`) and validates `bundle_version`, `receipt`, `request`, and `response` (`phase7-verify/internal/cli/cli.go:261`).
- Explicit `--pubkey` is base64 decoded and length-checked before verification (`phase7-verify/internal/cli/cli.go:167`, `phase7-verify/internal/cli/cli.go:276`).
- `MACPROVIDER_COORDINATOR` is read via injected `getenv` (`phase7-verify/internal/cli/cli.go:127`) and `--coordinator` wins through flag parsing (`phase7-verify/internal/cli/cli.go:146`), with tests at `phase7-verify/internal/cli/cli_test.go:398`.
- Explicit hash bypass exists only on `VerifyInput` (`phase7-verify/internal/verify/verify.go:52`) and is used only by `computedPromptHash` / `computedOutputHash` before byte-for-byte comparison to receipt fields (`phase7-verify/internal/verify/verify.go:222`, `phase7-verify/internal/verify/verify.go:254`). The CLI sets these fields only in header+hashes mode (`phase7-verify/internal/cli/cli.go:195`), while bundle mode sets `Request`/`Response` and leaves explicit hashes unset (`phase7-verify/internal/cli/cli.go:178`).
- `--quiet` suppresses stderr output at `writeErr`/`emitWarnings` (`phase7-verify/internal/cli/cli.go:416`, `phase7-verify/internal/cli/cli.go:458`) but does not mutate `Result.Warnings`; JSON warnings are preserved by result marshaling.
- Step 8/9 scope creep was not found. Human output remains a minimal single-line summary (`phase7-verify/internal/cli/cli.go:388`), and no full JSON Schema validation, fixture generator, or end-to-end integration harness was added in Step 7.

### Validation

- `cd phase7-verify && go vet ./...` -> passed.
- `cd phase7-verify && go test ./... -race -count=1` -> passed all packages, including `internal/cli`, `internal/resolver`, and `internal/verify`.
- `cd phase7-verify && go build -o /tmp/macprovider-verify-audit ./cmd/macprovider-verify` -> passed.
- `/tmp/macprovider-verify-audit --version` -> `macprovider-verify 0.1.0-step1-scaffold`.
- `/tmp/macprovider-verify-audit --help` -> printed all Step 7 flags: `--bundle`, `--receipt`, `--prompt-hash`, `--output-hash`, `--pubkey`, `--provider-id`, `--json`, `--offline`, `--quiet`, `--coordinator`, `--explain`, plus `--version`/`--help`.
- `test -z "$(git diff impl/spec-015-v0-2-step-06 -- phase7-verify/go.sum)"` -> passed; no `go.sum` diff.

### Lens verdicts

- Code lens verdict: **NOT READY**. Residual risk: required CLI test coverage is incomplete despite passing implementation tests.
- Security lens verdict: **NOT READY**. Residual risk: malformed receipt/bundle parse boundaries are not proven through concrete CLI invocations.
- Architect lens verdict: **NOT READY**. Residual risk: CF7 exact single-match fallback is implemented but not fully pinned against ambiguous-cache regressions.

## Round 2 by Codex

Scope audited: current HEAD `8f95250` on `impl/spec-015-v0-2-step-07`, compared with `impl/spec-015-v0-2-step-06`, with focus on the Round 1 fix commit `8f95250`.

### Code lens

Findings ordered by severity:

- **None.**

Resolution evidence:

- `--coordinator H` with a non-default host is now covered by `TestNonDefaultCoordinatorWarningJSON` (`phase7-verify/internal/cli/cli_test.go:331`). The test decodes JSON warnings and requires both `kind == "non_default_coordinator"` and `coordinator_host == normalizedCoordinatorHost(server.URL)` (`phase7-verify/internal/cli/cli_test.go:349`, `phase7-verify/internal/cli/cli_test.go:360`).
- `--explain` now asserts the full emitted trust-boundary text by requiring stderr to end with `explainText + "\n"` (`phase7-verify/internal/cli/cli_test.go:324`). The embedded constant matches the full §10.6 paragraph from `A valid result...` through the final `buyer who is about to act on a valid result` sentence (`phase7-verify/internal/cli/cli.go:484`; `specs/SPEC-015-receipts.md:1992`; `specs/SPEC-015-receipts.md:2057`).
- `--quiet --explain` is now a dedicated matrix row (`phase7-verify/internal/cli/cli_test.go:254`) and the shared assertion requires stderr to be empty when `wantStderrEmpty` is set (`phase7-verify/internal/cli/cli_test.go:315`).
- Bundle strictness now covers the requested variants: missing `bundle_version`, `bundle_version: 2`, `bundle_version: "1"`, `bundle_version: true`, missing `request`, and missing `response`, each expecting `exitDataErr` / exit 65 (`phase7-verify/internal/cli/cli_test.go:152`, `phase7-verify/internal/cli/cli_test.go:154`, `phase7-verify/internal/cli/cli_test.go:155`, `phase7-verify/internal/cli/cli_test.go:156`, `phase7-verify/internal/cli/cli_test.go:159`, `phase7-verify/internal/cli/cli_test.go:160`).
- CLI-level receipt parse boundaries are now covered by `TestCLIReceiptParseBoundariesExit65`: no-dot receipt, malformed tuple base64, and bundle-embedded malformed receipt each invoke the CLI runner and assert `exitDataErr` / exit 65 (`phase7-verify/internal/cli/cli_test.go:456`, `phase7-verify/internal/cli/cli_test.go:464`, `phase7-verify/internal/cli/cli_test.go:474`, `phase7-verify/internal/cli/cli_test.go:483`, `phase7-verify/internal/cli/cli_test.go:491`).
- The Round 1 confirmed coverage did not regress: the §10.4.4 matrix remains in `TestFlagInteractionMatrixRows` (`phase7-verify/internal/cli/cli_test.go:191`) and exit/boundary coverage remains in `TestUsageBoundaries` plus `TestCLIReceiptParseBoundariesExit65` (`phase7-verify/internal/cli/cli_test.go:408`, `phase7-verify/internal/cli/cli_test.go:456`); the full race suite passes all nine packages.

Code lens verdict: **READY TO LOCK**. Residual risk: none beyond normal future spec-drift risk between the embedded `explainText` constant and §10.6.

### Security lens

Findings ordered by severity:

- **None.**

Resolution evidence:

- Bundle-embedded malformed receipt now has a direct CLI test (`phase7-verify/internal/cli/cli_test.go:483`) and asserts exit 65 (`phase7-verify/internal/cli/cli_test.go:491`).
- The implementation parses bundle/header identity before verifier-result classification: `run` exits on `optionsToVerifyArgs` errors before calling `verify.Verify` (`phase7-verify/internal/cli/cli.go:104`), `resolveProviderID` parses the receipt at the bundle/header layer (`phase7-verify/internal/cli/cli.go:312`), parse failures are wrapped as `verify.InputFormatError` (`phase7-verify/internal/cli/cli.go:314`), and `exitForError` maps that class to exit 65 (`phase7-verify/internal/cli/cli.go:443`, `phase7-verify/internal/cli/cli.go:451`).
- The exit-70 panic-recover path is documented as last-resort only, with documented outcomes `0`, `1`, `2`, `64`, and `65` taking precedence through ordinary control flow (`phase7-verify/internal/cli/implementation-notes.md:28`).
- No test-only hook was added to production code paths. The Round 1 fix commit changes only `cli_test.go` and `implementation-notes.md`, and repo search found no production `testHook` / `ForTest` style hook in `phase7-verify/internal/cli` or `phase7-verify/internal/verify`.

Security lens verdict: **READY TO LOCK**. Residual risk: no panic-injection test exists, but the accepted documentation alternative is present and precise.

### Architect lens

Findings ordered by severity:

- **None.**

Resolution evidence:

- CF7 ambiguous-cache behavior is now pinned by `TestUsageBoundaries/ambiguous cache falls through to missing provider id` (`phase7-verify/internal/cli/cli_test.go:427`).
- The test invokes without `--provider-id` and without `--pubkey` via `headerArgs("https://example.test", fixture)` (`phase7-verify/internal/cli/cli_test.go:427`), seeds two entries under the same normalized coordinator with different provider IDs and the same receipt pubkey (`phase7-verify/internal/cli/cli_test.go:438`), and expects exit 64 plus an error containing `--provider-id` (`phase7-verify/internal/cli/cli_test.go:427`, `phase7-verify/internal/cli/cli_test.go:449`).
- The production semantic remains exact-single-match: cache matches are collected by distinct provider ID (`phase7-verify/internal/cli/cli.go:333`), `len(matches) != 1` falls through to an empty provider id (`phase7-verify/internal/cli/cli.go:352`), and the CLI then emits the missing-provider usage error when no explicit pubkey exists (`phase7-verify/internal/cli/cli.go:224`).
- The added tests do not introduce shared cache ordering risk. CLI tests allocate a per-test cache file under `t.TempDir()` through `buffersAndCache` / `openTempCache` (`phase7-verify/internal/cli/cli_test.go:676`, `phase7-verify/internal/cli/cli_test.go:682`), and the race suite passed.

Architect lens verdict: **READY TO LOCK**. Residual risk: none identified.

### Regression and validation

- `cd phase7-verify && go vet ./...` -> passed.
- `cd phase7-verify && go test ./... -race -count=1 -v 2>&1 | tail -40` -> passed; tail showed the final `internal/verify` and `internal/version` tests passing.
- `cd phase7-verify && go test ./... -race -count=1` -> passed all 9 packages: `cmd/macprovider-verify`, `internal/cache`, `internal/canon`, `internal/cli`, `internal/jcs`, `internal/receipt`, `internal/resolver`, `internal/verify`, and `internal/version`.
- `cd phase7-verify && go build -o /tmp/macprovider-verify-r2 ./cmd/macprovider-verify` -> passed.
- `/tmp/macprovider-verify-r2 --version` -> `macprovider-verify 0.1.0-step1-scaffold`.
- `/tmp/macprovider-verify-r2 --help` -> printed the Step 7 flag surface, including `--bundle`, `--receipt`, `--prompt-hash`, `--output-hash`, `--pubkey`, `--provider-id`, `--json`, `--offline`, `--quiet`, `--coordinator`, and `--explain`.
- `test -z "$(git diff impl/spec-015-v0-2-step-06 -- phase7-verify/go.sum)"` -> passed; `go.sum` is unchanged from Step 6.
- `git diff impl/spec-015-v0-2-step-06..impl/spec-015-v0-2-step-07 --stat` -> 7 files changed, 1446 insertions, 118 deletions.
- `grep -n "non_default_coordinator\|bundle_version.*2\|provider_id_unresolvable" phase7-verify/internal/cli/cli_test.go | head -20` -> found the expected coverage anchors at `cli_test.go:154`, `cli_test.go:299`, `cli_test.go:360`, and `cli_test.go:364`.
- `git diff --check impl/spec-015-v0-2-step-06..impl/spec-015-v0-2-step-07` and `git diff --check 1662812..8f95250` -> passed.

### Overall verdict

Overall verdict: **READY TO LOCK**. All three lenses are READY TO LOCK with 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
