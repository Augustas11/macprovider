# Short-control lease implementation and process evidence

Result: **the six lease test methods passed with zero failures in Swift17 (22.939 seconds).** One method is the subprocess entry point, so this represents five behavioral scenarios, not six independent end-to-end journeys. The complete Swift17 selection failed: 117 tests, 11 failures, eight unexpected. This note makes no combined-suite or final-audit pass claim.

## Implementation scope

The authored runtime change is limited to `ModelTransactionControlLease` in `ModelTransactionContext.swift`: production `start(options:)` delegates to an internal overload accepting a throwing home-directory provider. Production always supplies `kernelHomeDirectory`; the independent ten-second deadline remains fixed. The provider executes after watchdog installation, allowing isolated tests to block that boundary without changing clocks or adding a CLI/environment/config bypass. The root-owned inherited-lock correction remains exercised by these tests.

Added `Tests/macprovider-cliTests/ModelTransactionControlLeaseTests.swift`. Fixtures run fresh xctest processes through `posix_spawn`, explicitly inherit descriptors, use private temporary directories, and do not open or create the operator's real Malibu/config directories. Test-only role selection exists solely in the selected test entry point. No retention owner watchdog or pending retention-budget proposal was implemented or authorized by this change.

## Observed tests and assertion types

| Behavioral test | Actual assertions | Swift17 duration |
| --- | --- | --- |
| Inherited lock survives parent-descriptor close until lifetime EOF | Independent nonblocking flock reports `EWOULDBLOCK` after the parent closes its lock FD; closing the lifetime writer yields helper exit 70 within the test's four-second wait; a new exclusive flock then succeeds | 0.440 s |
| Unrelated description, wrong inode and invalid selectors fail closed | Independently opened same-inode FD, wrong-inode FD, duplicate context/lifetime descriptors and wrong parent PID each yield fixture rejection exit 71; none writes the ready marker | 1.089 s |
| Fixed deadline before blocked home metadata | Home-provider closure writes a barrier then blocks for 30 seconds; real timer exits helper with 70; elapsed time after the barrier is asserted greater than eight and less than 13 seconds; inherited lock is busy while blocked and acquirable after exit | 10.320 s |
| Blocked reconciliation preserves another heartbeat and releases ownership | Actual `reconcile(selector, metadataCheck:)` blocks after staged-directory metadata inspection, outside the global journal lock while holding the first operation's owner lock. A second running record receives more than ten production journal heartbeat writes, each asserted under one second. Helper exits 70; first owner lock and control lock become acquirable; first primary journal bytes are unchanged | 10.358 s |
| Actual parent death with lifetime writer retained | A real intermediate parent spawns the leased helper. The test retains the lifetime write end, kills only that intermediate parent with SIGKILL and reaps it; helper ceases to be signalable within five seconds and its control lock becomes acquirable. EOF therefore does not explain this exit | 0.732 s |

The sixth method, `testLeaseSubprocessEntry`, returns immediately in the ordinary suite and passed in 0.000 seconds. Subprocess roles execute the actual lease class; the blocked-reconciliation role uses the actual transaction store and owner-lock path. It is not a mocked process/clock assertion.

The reconciliation fixture deliberately uses a valid started, uncommitted prepare record. It proves process deadline, journal availability, preserved original bytes and OS lock release during a blocking observation callback. It does not claim that this case exercised a committed artifact seal or a kernel filesystem syscall stalled on physical storage.

## Exact command and evidence provenance

Root executed this command from `/Users/augstar/.codex/worktrees/macprovider/product-build-1/phase3-binary`:

```bash
swift test --filter 'ModelTransactionContextTests|ModelsSubcommandTests|RecommendationAdoptionJournalPathTests|Build1CommandBootstrapTests|ModelTransactionControlLeaseTests|ModelCatalogTransactionsTests|ModelCatalogArtifactSealTests|DurableModelArtifactStoreTests|ModelCatalogTransactionRetentionTests' > /tmp/build1-joint-swift17.log 2>&1
```

Command exit: **1**. The log records build completion in 25.50 seconds and the lease suite passing from 2026-09-10 15:38:48.467 to 15:39:11.406. Its lease summary is six tests, zero failures, zero unexpected, 22.938 seconds test time / 22.939 seconds elapsed. The final selected-suite summary is 117 tests, 11 failures, eight unexpected, 124.124 seconds elapsed.

The author inspected the actual log and source assertions after root's run; the author did not independently execute this command. Root also records the invocation in the lead validation evidence.

## Source and log hashes

SHA-256 values captured when recording this evidence:

```text
dc5a867aaab1fc85b1e4822a9c3c9ffed16b3a701f94e4add79466d78f548377  phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift
987400238cfdcd468c69dcebbfcc60f144069dc2b6b146801e8f2083b146a5ae  phase3-binary/Tests/macprovider-cliTests/ModelTransactionControlLeaseTests.swift
e74b19b37159da4897199da0295f856454372b719920687964ece9010efad51a  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
ba30945b4861e8f516464927fc769d5e34078af565e7cd83d9de0b53eec8f7dc  /tmp/build1-joint-swift17.log
```

The context and transaction files also contain other owners' changes. This evidence identifies the inspected files; it does not substitute for a complete immutable build manifest or a later final source snapshot.

## Remaining qualification and independence

- These tests establish real child-process lifetime/FD behavior in the isolated fixture. They do not establish Malibu GUI crash/relaunch behavior, installed app dispatch and supervision, or the end-to-end pinned signed executable snapshot path.
- Code-signature/CDHash replacement, actual installed-helper identity, notarization, release packaging and app GUI cancellation still require their separate evidence. No physical MLX, large-artifact timing, settlement or production economic activation is claimed.
- The fixed deadline is exercised through the same lease body with an isolated home provider; this suite does not access the user's real kernel-home lock directory. Production routing to the kernel-home helper is source-verified.
- The author implemented the lease overload and these tests. A different auditor must independently review this authored slice in the final combined code/security/architecture gate. The author's earlier preliminary context report cannot count as independent approval of these later edits.
