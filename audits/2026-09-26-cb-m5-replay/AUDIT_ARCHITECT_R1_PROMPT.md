# Codex audit: #1646 M5 durable relay replay — architecture lane, round 1

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
AC-20 and AC-25, and the relevant production relay, scheduler, replay-authority,
and receipt boundaries.

The intended proof reconstructs `InferenceRelay` while retaining the production
continuous-batching scheduler and file-backed replay authority. The first
terminal owns settlement; the same stable request identity after reconstruction
reuses the terminal result, performs no second generation, and is explicitly
non-settling. This is a regression prerequisite, not yet packaged Studio enable
evidence.

Fresh leader evidence: focused Go regression PASS; Linux integration test
compiles; full Swift suite PASS (3545 tests, 55 skipped, 0 failures).

Architecture focus: whether reconstructed components model the real reconnect
boundary; whether hidden fixture logic duplicates or drifts from production
semantics; lifecycle/ownership correctness; false confidence at the M5 enable
gate; maintainability and scope. Read source and run existing tests only. Do not
edit files.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report every finding with severity,
file:line, concrete failure scenario, and narrow fix. LOW/INFO may be carried.
Do not manufacture findings. End exactly with `VERDICT: PASS` or
`VERDICT: FAIL (C/H/M counts)`.
