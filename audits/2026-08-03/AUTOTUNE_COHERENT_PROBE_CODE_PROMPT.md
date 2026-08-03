# Full-diff code audit — autotune coherent probe

Review the complete proposed fix from `origin/main` to the current working tree in `/Users/augstar/macprovider-autotune-probe`, not an incremental slice. The implementation scope is:

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`
- `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandTests.swift`

Read the repository `AGENTS.md`, `CLAUDE.md`, the relevant autotune/spec material, and the full diff. Do not inspect `d-inference`; it is a clean-room boundary.

Audit the requested fix: Stage 1/2 must use one centralized deterministic coherent English prompt instead of repeated `probe` padding, retain the historical 80%-of-context prompt estimate (including contexts 2,000 and 24,000), be safe for Harmony/reasoning models, and leave request shape, max tokens, streaming, temperature, candidate path, and the #877 usage-based throughput calculation unchanged. Check that tests meaningfully lock length and marker safety and that no unrelated behavior or sensitive path was changed.

Report findings with severity `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `INFO`, exact file/line references, concrete evidence, and actionable remediation. Treat unresolved CRITICAL/HIGH/MEDIUM findings as blocking. End with a machine-readable summary line in this form:

`SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n> VERDICT=<PASS|BLOCK>`
