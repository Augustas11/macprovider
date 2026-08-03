# Full-diff security audit — autotune coherent probe

Review the complete proposed fix from `origin/main` to the current working tree in `/Users/augstar/macprovider-autotune-probe`, not an incremental slice. The implementation scope is:

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`
- `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandTests.swift`

Read `AGENTS.md`, `CLAUDE.md`, the relevant autotune/spec material, and the full diff. Do not inspect `d-inference`; it is a clean-room boundary.

Assess security and fail-closed behavior around the shared probe prompt. Verify that the replacement is fixed, bounded, deterministic, ordinary natural language with no tool/function-call, JSON, or Harmony/ChatML control-token markers; cannot introduce prompt injection or accidental tool invocation; preserves the existing no-tools request and Stage 1/2 request semantics; and does not alter the #877 provider usage fields or throughput computation. Check length calculation for overflow, degenerate contexts, unintended allocation/DoS risk, and whether the tests actually enforce the safety claims. Ignore unrelated pre-existing repository issues.

Report findings with severity `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `INFO`, exact file/line references, concrete exploit or failure reasoning where applicable, and actionable remediation. Treat unresolved CRITICAL/HIGH/MEDIUM findings as blocking. End with a machine-readable summary line in this form:

`SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n> VERDICT=<PASS|BLOCK>`
