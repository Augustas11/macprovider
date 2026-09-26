# #1646 Gate A5 counter evidence

Date: 2026-09-26

Result: **PASS for the offline Gate A5 measurement mechanism; Gate A5 itself
remains NOT GREEN.** No real signed 60-pair measurement window was collected,
and this evidence does not authorize `continuous_batching: on` or any live
configuration change.

## What was proved

The campaign now has a closed schema-v4 counter for the previously undefined
focal row-zero OPoI false-positive condition. It binds the exact candidate
frame, ranked selection, tuple, artifact, runtime, evaluator, challenge,
schedule, raw source captures, complete shared-forward membership, independent
reviewer receipt and source review, and three disjoint signing roles. It fails
closed on invalid or inconclusive pairs and requires both the observed rate and
the exact one-sided 95% upper confidence bound to be strictly below 5%.

The counter is offline evidence tooling only. It cannot change routing,
tiering, admission, sanctions, payout, billing, receipts, settlement, or live
provider configuration. Reviewer custody, review quality, seed commitment, and
append-only receipt timing remain manual external controls.

## Validation

- The local regression suite passed all 56 tests.
- The same counter and test bytes ran on the Mac Studio: 56 tests, 0 failures,
  1 intentional skip for the Git-worktree-only package-lock assertion.
- Counter SHA-256 on both machines:
  `a3c5dd7f0dff0cda021e2754cca00b191c575ab5642bc462279c4e137a0e8310`.
- Test SHA-256 on both machines:
  `5bcca6b1586d08cfa72165e1266d66ea1cfe95be191e177dba7db4aa6cf71f4d`.
- Python compilation, the Swift package-lock check, and `git diff --check`
  passed.
- The full Swift suite passed: 3545 executed, 55 skipped, 0 failures.
- The live Studio provider was untouched; no benchmark pause was required.

## Audit status and boundary

All three audit rounds were used. Round 3 still found HIGH/MEDIUM issues. Those
issues were fixed, but the campaign rule forbids a fourth audit round and moves
to Studio e2e instead. The Studio run and regression suite passed on the final
bytes, while the lack of post-remediation independent audit convergence remains
explicit carried process risk.

The detailed audit record is
[`audits/2026-09-26-cb-gate-a5/README.md`](../../audits/2026-09-26-cb-gate-a5/README.md).
The operational protocol is
[`continuous-batching-enable-gate.md`](continuous-batching-enable-gate.md).

## Campaign consequence

The counter/protocol prerequisite is complete, so the campaign may evaluate M6
promotion economics using the re-measured batched numbers. The final M7 decision
must still keep `on` disabled because no real signed Gate A5 measurement exists.
Any later claim that Gate A5 is green requires a new predeclared evidence window
and the complete signed bundle defined by SPEC-038 FR-CB15.
