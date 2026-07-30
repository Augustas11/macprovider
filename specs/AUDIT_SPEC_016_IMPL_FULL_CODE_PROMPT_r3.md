# IMPL audit prompt — SPEC-016 FULL implementation, **CODE REVIEW lane, r3**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r3.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any implementation file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 2) auditing the FULL SPEC-016
implementation — round 3.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r3.md`. HEAD: `90e3dbf`.
r2 found 1 HIGH + 1 MEDIUM in code lane; fix-pass at this commit.

## r2 closure verification

### [full-code:r2-1] confirmedDepth bool

Walk `pollAndConfirm` in runner.go. Verify:
- A new `confirmedDepth bool` is declared before the for-loop.
- Inside the for-loop, `candidatePri` / `candidateSec` capture the
  poll results (NOT the shared recPri/recSec).
- recPri / recSec are assigned ONLY when both per-RPC depths
  satisfy `>= ConfirmationBlocks` AND `confirmedDepth = true`
  IS set right before the break.
- The post-loop guard refuses to proceed when confirmedDepth is
  false (defense-in-depth nil checks remain).
- The "receipt poll deadline expired without both-RPC depth" log
  message reflects the new failure mode accurately.
- The test `TestRunner_PollAndConfirm_RejectsShallowSecondary`
  exercises receipt_block=100 + primary head 200 + secondary
  head 102 + ConfirmationBlocks=5 + short timeout, and asserts
  zero claim calls + confirmed_at_utc stays NULL.

### [full-code:r2-2] regression test

Walk runner_e2e_test.go. Verify:
- The test compiles and is in the package's test corpus.
- Asserts both claim-call count == 0 AND confirmed_at_utc NULL.
- Doesn't depend on state from sibling tests.

## New cross-step probes (round 3)

### A. confirmedDepth bool — new defects?

1. Does `confirmedDepth = true` get reset incorrectly anywhere?
2. Is there any path that sets confirmedDepth but does NOT also
   assign recPri/recSec, or vice versa?
3. Could a deadline expiry race with a successful break — i.e.
   could the for-loop break successfully and then the next
   iteration's `time.Now().Before(deadline)` immediately fail?
   (Answer should be: irrelevant — break exits the loop
   immediately, no further iteration.)
4. The candidate variables (`candidatePri`, `candidateSec`) are
   re-allocated every iteration. Is this safe? (Garbage-collected
   Go pointer; the old candidates go out of scope.)

### B. Halt gate composition with confirmedDepth

The halt gate in claimAndLog runs AFTER pollAndConfirm completes.
If halt fires while pollAndConfirm is mid-loop (long timeout),
the loop continues until deadline or success — there is no halt
check in the loop itself. Is this a problem?

The audit prompt at r1-2 said: "before irreversible money-path
operations such as allocation, signing, broadcast, confirmation,
and claim". pollAndConfirm doesn't BROADCAST — it polls receipts.
A halt during polling that lets the loop run to completion and
then gets caught at the claim gate is correct behavior. Verify
this composition is what r1-2 intended.

### C. Tests holistic

- `go test -count=1 ./internal/payout/...` PASS?
- `go test -race -count=1 ./internal/payout/...` PASS?
- `gofmt -l` on r2-touched files clean?
- New tests in test corpus run by default (no build tag, no
  testing.Short() skip)?

## Output

Write findings to `specs/SPEC-016-IMPL-FULL-code-r3-audit.md`.
Standard structure. If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Verify r2 closures hold. Look for what r2 fix-pass introduced.
- Wall-clock target: 20-30 min.

=== END PROMPT ===
```
