# #1646 M5 durable relay replay audit

Date: 2026-09-26

Gate result: **PASS** — 0 CRITICAL, 0 HIGH, 0 MEDIUM findings across
code, security/money, and architecture lanes after two bounded rounds.

## Round 1

- Code: **PASS**. No CRITICAL/HIGH/MEDIUM findings. One LOW asked the
  regression to bind signed provider, model, hash, terminal state, and usage
  fields rather than only signature/version/request identity. The final diff
  includes those assertions.
- Security/money: **PASS**. No findings. The lane verified the environment
  gate, non-settling replay receipt suppression, replay-store permissions, and
  focused replay tests.
- Architecture: **FAIL** with one MEDIUM. The fixture duplicated production
  request-to-scheduler and result-to-completion mappings, allowing a production
  bridge regression to leave the fixture green.

## Round 2

- Architecture: **PASS**. No findings. The production streaming and
  non-streaming paths and the fixture now use
  `ModelRuntime.continuousBatchSubmission`; the fixture also uses production
  `ModelRuntime.finalizeContinuousBatchRow`. The lane found no production
  semantic change and confirmed that the handoff does not overclaim this as
  packaged Studio enable evidence.

## Fresh leader validation

- `swift build --product macprovider-cli`: PASS.
- `go test -run '^TestSwiftRelayContinuousBatchDurableTerminalReplay$' -count=1 -v`:
  PASS; exactly one receipt was issued and replay omitted a receipt with reason
  `non_settling_replay`.
- `swift test --skip testWaitForReadyDeadlineCancelsDrippingSpoofResponse`:
  PASS; 3545 tests executed, 55 skipped, 0 failures in 272.022 seconds.
- `git diff --check`: PASS.

The first full-suite attempt was interrupted and is not counted: the existing
`testWaitForReadyRejectsReadinessFromUnexpectedListenerOwner` cleanup blocked
in `Process.waitUntilExit()` after its spoof process had exited. A fresh rerun
of the exact command completed successfully.

Prompt inputs are stored beside this file. Raw local `omc ask codex` artifacts
remain under `.omc/artifacts/ask/` and are intentionally not committed.
