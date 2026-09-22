# Round 2 — CODE lane re-audit, CB per-tuple acceptance coverage

Worktree `/Users/augstar/macprovider-cb-tuple-acceptance`, branch
`fix/cb-tuple-acceptance-coverage`, based on `origin/main` at `a912e039`.

Review the FULL combined diff as it will land (`git diff`), not just the round-2
delta. Round 1 of this lane returned 0 CRITICAL, 1 HIGH, 1 MEDIUM, 1 LOW. All
four were addressed:

- **HIGH `Package.resolved`** — the lockfile had been pruned by local
  `swift build` runs. Restored from `origin/main`; `git diff` on that path is
  now empty. Confirm it is absent from the diff.
- **MEDIUM identity-field validation** (`Config.swift`) — `requiredString` now
  rejects values with leading/trailing whitespace, and a new `requiredSHA256`
  requires canonical 64-character lowercase hex for `model_sha256`. Two new
  tests cover uppercase / 63-char / 65-char / non-hex SHAs and a
  whitespace-padded `hardware_class`.
- **LOW CLI help** (`MacProviderCLI.swift`) — the `--continuous-batching` help
  now names `continuous_batching_accepted_tuples` and the
  `tuple_acceptance_coverage_unavailable` canary reason.
- **LOW CODEOWNERS** (raised by the security lane) —
  `phase3-binary/Sources/MacProviderCore/Config.swift` added to the CB block.

Verify the fixes are correct and complete, and look for anything they
introduced. In particular:
- Is the whitespace rule right, or does it reject a legitimate declaration?
  Model ids contain `/` and `-`; hardware classes and cache classes are
  free-form local strings.
- Is `value.allSatisfy { $0.isHexDigit && !$0.isUppercase }` a correct
  canonical-lowercase-hex test in Swift? Consider non-ASCII digits, Unicode
  characters for which `isHexDigit` is true, and characters that are neither
  uppercase nor lowercase.
- Does the runtime-measured `modelSHA256` that coverage is compared against
  actually arrive as canonical lowercase 64-hex? If it can ever differ in case
  or length, the new validation makes a previously-matchable declaration
  unmatchable. Check where the runtime value originates.
- Do the two new tests actually pin the behavior?

Report CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line, a concrete failure
scenario, and a fix. Gate is 0 CRITICAL, 0 HIGH, 0 MEDIUM. State explicitly if
you find none. Do not propose SPEC edits.
