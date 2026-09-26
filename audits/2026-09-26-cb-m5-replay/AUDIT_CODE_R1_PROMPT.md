# Codex audit: #1646 M5 durable relay replay — code lane, round 1

Worktree: `/Users/augstar/macprovider-1646-rest`
Branch: `campaign/1646-remaining`

Review the complete current M5 diff with:

```bash
git diff HEAD -- \
  phase3-binary/Sources/macprovider-cli/RelayBlindFixtureCommand.swift \
  test/integration/swift_relay_provider_test.go \
  docs/handoffs/1646-remaining-campaign.md
```

Read `AGENTS.md`, `CLAUDE.md`, `docs/handoffs/1646-remaining-campaign.md`,
`docs/runbooks/continuous-batching-enable-gate.md`, SPEC-038 FR-CB13/FR-CB15,
AC-20 and AC-25, and the production `InferenceRelay`,
`ContinuousBatchScheduler`, and `ContinuousBatchRuntimeReplayAuthority` paths.

The intended proof is: a terminal request entering production `InferenceRelay`
and the production scheduler claims the file-backed replay identity once,
executes deterministic generation once, emits one valid eligible-owner receipt,
then after relay reconstruction returns the retained result as
`non_settling_replay` with identical usage and no second receipt. The fixture is
hidden behind `MACPROVIDER_ALLOW_TEST_FIXTURES=1`; no production behavior should
be weakened.

Fresh leader evidence: focused Go regression PASS; Linux integration test
compiles; full Swift suite PASS (3545 tests, 55 skipped, 0 failures).

Code-review focus: whether the test genuinely crosses the claimed production
boundaries; identity and result retention fidelity; races or false-positive
instrumentation; receipt/disposition/usage assertions; portability; regression
risk to the pre-existing relay-blind fixture. Read source and run existing tests
only. Do not edit files.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report every finding with severity,
file:line, concrete failure scenario, and narrow fix. LOW/INFO may be carried.
Do not manufacture findings. End exactly with `VERDICT: PASS` or
`VERDICT: FAIL (C/H/M counts)`.
