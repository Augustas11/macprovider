# Codex audit: #1646 M5 durable relay replay — security/money lane, round 1

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
AC-20 and AC-25, plus receipt construction/verification and durable replay
authority code used by the fixture.

The intended invariant is exactly-once settlement ownership across a relay
reconnect: one stable request identity, one inference execution, one signed v4
receipt for `eligible_owner`, then a retained `non_settling_replay` with the
same usage and no duplicate receipt. The fixture must remain inaccessible
without `MACPROVIDER_ALLOW_TEST_FIXTURES=1`, must not expose secrets, and must
not create a production fault-injection or receipt-minting bypass.

Fresh leader evidence: focused Go regression PASS; Linux integration test
compiles; full Swift suite PASS (3545 tests, 55 skipped, 0 failures).

Security/money focus: duplicate settlement/receipt risk; identity/fingerprint
binding; forged or vacuous receipt validation; filesystem permissions and
unsafe paths; test surface reachability; leakage of keys/material; ways the
fixture could report a disposition different from what `InferenceRelay` used.
Read source and run existing tests only. Do not edit files.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report every finding with severity,
file:line, concrete failure scenario, and narrow fix. LOW/INFO may be carried.
Do not manufacture findings. End exactly with `VERDICT: PASS` or
`VERDICT: FAIL (C/H/M counts)`.
