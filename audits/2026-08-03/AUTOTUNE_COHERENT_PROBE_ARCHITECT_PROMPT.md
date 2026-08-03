# Full-diff architecture audit — autotune coherent probe

Review the complete proposed fix from `origin/main` to the current working tree in `/Users/augstar/macprovider-autotune-probe`, not an incremental slice. The implementation scope is:

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`
- `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandTests.swift`

Read `AGENTS.md`, `CLAUDE.md`, the relevant autotune/spec material, and the full diff. Do not inspect `d-inference`; it is a clean-room boundary.

Evaluate design integrity and scope discipline. Confirm Stage 1 and Stage 2 truly share one prompt definition, the prompt remains coherent and tool-call-safe for Harmony/reasoning and plain models, the length invariant is documented and tested at 2,000 and 24,000 contexts, and the implementation preserves throughput semantics and all existing request parameters. Look for hidden coupling, model-dependent assumptions, poor naming, duplicated policy, insufficient regression coverage, and changes outside the surgical probe path. Distinguish genuine CRITICAL/HIGH/MEDIUM defects from acceptable tokenizer approximation and orchestrator-owned hardware verification.

Report findings with severity `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `INFO`, exact file/line references, evidence, and actionable remediation. Treat unresolved CRITICAL/HIGH/MEDIUM findings as blocking. End with a machine-readable summary line in this form:

`SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n> VERDICT=<PASS|BLOCK>`
