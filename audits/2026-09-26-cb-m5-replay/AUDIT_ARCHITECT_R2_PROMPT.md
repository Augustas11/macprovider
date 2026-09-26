# Codex audit: #1646 M5 durable relay replay — architecture lane, round 2

Worktree: `/Users/augstar/macprovider-1646-rest`
Branch: `campaign/1646-remaining`

This is the only re-audit lane after round 1. Code review and security review
both passed round 1. Architecture round 1 found one MEDIUM: the fixture built
its own relay-request-to-scheduler mapping and its own scheduler-result-to-
completion mapping, so production bridge regressions could leave the test
green.

Review the complete current M5 diff with:

```bash
git diff HEAD -- \
  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift \
  phase3-binary/Sources/macprovider-cli/RelayBlindFixtureCommand.swift \
  test/integration/swift_relay_provider_test.go \
  docs/handoffs/1646-remaining-campaign.md
```

Read `AGENTS.md`, `CLAUDE.md`, `docs/handoffs/1646-remaining-campaign.md`,
`docs/runbooks/continuous-batching-enable-gate.md`, SPEC-038 FR-CB13/FR-CB15,
AC-20 and AC-25, and the relevant production relay, scheduler, replay-authority,
and receipt boundaries.

The round-1 fix extracted `ModelRuntime.continuousBatchSubmission`, now used by
both production continuous-batch paths and the fixture for stable identity,
conversation, sampling, retained state, and scheduler request construction.
The fixture also now calls the existing production
`ModelRuntime.finalizeContinuousBatchRow` for result-to-completion semantics.
Receipt assertions were tightened to bind the signed provider/model/hash,
terminal state/timestamp, and observed/billable usage to the terminal frame.

Fresh leader evidence after the fix:

- `swift build --product macprovider-cli`: PASS.
- focused Go M5 regression: PASS, with one `receipt_issued` and replay
  `receipt_omitted` reason `non_settling_replay`.
- full Swift suite: PASS, 3545 tests, 55 skipped, 0 failures.

Determine whether the round-1 MEDIUM is closed without creating a new
architecture-level gate finding. Pay special attention to whether the shared
production builder and existing production finalizer make this fixture fail on
the relevant bridge regressions, whether production behavior remains
unchanged, and whether the fixture still overclaims packaged Studio enable
evidence. Read source and run existing tests only. Do not edit files.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report every finding with severity,
file:line, concrete failure scenario, and narrow fix. LOW/INFO may be carried.
Do not manufacture findings. End exactly with `VERDICT: PASS` or
`VERDICT: FAIL (C/H/M counts)`.
