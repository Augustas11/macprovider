# Owner lifetime watchdog implementation evidence

Status: compiled; the owner watchdog process suite passed in coordinated Swift20. The complete selected run failed in three other tests, so this is not a combined acceptance pass.

Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Approved design: `retention-lock-budget-r2.md`, SHA-256 `65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21`, and the corresponding SPEC-001 owner heartbeat contract. This evidence covers the newly authored watchdog and its process fixtures. Transaction runner, cleanup, publication and lifecycle integration belong to the CLI implementation lane and require separate combined verification.

## Implementation

`ModelTransactionOwnerLifetimeGuard` uses monotonic time and a private dispatch timer. Eight seconds after its last acknowledged durable write it permanently refuses publication and dispatches cancellation on a separate queue. Ten seconds after that same acknowledgment it exits the owning process with status 70. Blocking filesystem calls, a stalled cancellation callback, Swift task scheduling and child waits do not execute on the watchdog queue. Its small state lock contains no filesystem work or caller callbacks.

The initial deadline begins at guard construction immediately after owner acquisition. Only a successfully fsynced exact-owner/generation start, heartbeat or terminal record, including the required directory durability boundary, may acknowledge progress. Stream writes, busy attempts, index reads and unrelated writes cannot acknowledge it. A late actual fsync cannot revive an already fenced owner. There is no disable method, timing override, environment switch or CLI bypass. A terminal acknowledgment retains the guard through subsequent bounded indexing and owner exit; it does not turn the guard off.

The watchdog owns only its command's lifetime. Existing candidate parent-loss and restoration pipe guards retain child and prior-service recovery ownership. A fenced owner must not start a new explicit restoration or dismiss an established restoration pipe guard. Owner-loss restoration may attempt bootstrap, which is not proof of restored readiness. An already-started owned restoration retains its existing lifecycle.

## Process fixture assertions

The new XCTest file creates fresh xctest processes with private temporary roots. Test-only role variables are read exclusively by the test entry method. Production entry points receive no test bypass.

- Contention fixtures hold a real journal flock while the child holds a distinct owner flock. Actual file and directory fsyncs establish durable acknowledgments. They assert an eight-second fence marker, publication refusal, rejection of a late fsync acknowledgment, exit 70, owner lock release and unchanged pre-existing truth bytes. A positive failure tripwire records any publication permitted beyond the fence. The prepare and cleanup labels use the same common-guard fixture; they do not independently execute those production commands.
- The blocked fixture stalls the owner in a real FIFO open and stalls its cancellation callback for 30 seconds. It starts the actual candidate parent-loss guard in another process and the actual restoration pipe guard with an isolated fake launchctl executable. Assertions cover independent owner exit, owner lock release, candidate disappearance, a restoration-attempt marker and preservation of prior truth bytes. The launcher marker proves an attempted bootstrap only. This fixture does not execute the complete evaluation runner or measure inference.
- The brief-contention fixture releases the journal lock after six seconds, checks that the already-due heartbeat persists promptly, and observes the owner surviving its original ten-second deadline through later actual durable acknowledgments. A real terminal fixture write is acknowledged before ordinary exit. Scheduling in this fixture models the approved heartbeat loop; production loop conformance requires CLI integration verification.

## Snapshot and verification limits

Initial ready-for-build SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `phase3-binary/Sources/macprovider-cli/ModelTransactionOwnerLifetimeGuard.swift` | `5d794a9aa75a6172b0c4a7c4f68be96e432ce34788896b3d80bbd7ec0b6de71c` |
| `phase3-binary/Tests/macprovider-cliTests/ModelTransactionOwnerLifetimeGuardTests.swift` | `030fe5233568833323ab0f45cccd97eaae7af4f4299a33cc73a0b7c2339207ef` |

`git diff --check` was clean for the ready snapshot and after verification. The two source hashes above remained unchanged throughout Swift20. These fixtures cannot establish app GUI crash handling, signed snapshot qualification, physical hardware acceptance, successful launchd restoration or complete transaction publication/config fencing. A different final auditor must review this authored slice; its author's earlier security review is not independent approval of these changes.

## Coordinated Swift20 result

Working directory: `/Users/augstar/.codex/worktrees/macprovider/product-build-1/phase3-binary`.

```bash
swift test --filter 'ModelTransactionContextTests|Build1CommandBootstrapTests|ModelCatalogTransactionsTests|ModelCatalogTransactionRetentionTests|ModelTransactionOwnerLifetimeGuardTests|ModelTransactionControlLeaseTests|ModelCatalogArtifactSealTests' > /tmp/build1-joint-swift20.log 2>&1
```

The command exited 1. Compilation completed in 38.22 seconds. The complete selection executed 63 tests with three failures, two unexpected, in 250.325 seconds. The failures were the bootstrap fixture's HTTP coordinator URL rejection, the full-active migration test returning busy, and the long-verification transaction test returning unsafe-evidence failure. Those belong to other implementation lanes and remain separate blockers.

The actual owner-watchdog results at log lines 6574–6584 were:

| Test | Result | Duration |
| --- | --- | --- |
| `testBlockedEvaluationAndCancellationStillExitWithCandidateAndRestorationOwnership` | Passed | 10.876 s |
| `testDurableAcknowledgmentAfterBriefContentionResumesWithoutResettingDueTick` | Passed | 12.433 s |
| `testOwnerWatchdogSubprocessEntry` | Passed; normal suite entry is a no-op | 0.000 s |
| `testPrepareAndCleanupContentionFenceBeforeIndependentExitWithoutLateRevival` | Passed | 20.764 s |

Owner suite total: four tests, zero failures, 44.073 seconds. The separate short-control lease suite also passed six tests with zero failures in 23.211 seconds. These counts include each suite's subprocess entry method and must not be described as four or six independent behavioral scenarios.

The complete log SHA-256 is `c3144c9b4c30f211b04d3d827ea63e647ee1598c0e2b848405d1b4c2c68b0e89`. A preliminary tail read appeared truncated because stdout and stderr were buffered/interleaved. The complete log contains the final XCTest summary and both lifetime suites; it provides no evidence that a retained watchdog killed the parent XCTest process. No source change was made based on that disproven inference.
