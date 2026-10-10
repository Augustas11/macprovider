# Round 3 — ARCHITECTURE lane (omc ask codex)


HIGH — phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:6401 — **PRE-EXISTING; R2 recovery finding still open:** Retry invokes restoration cleanup without restoring local readiness. `autoupdateDrain` sets the provider to `draining`; in-process activation/guard-failure restoration neither restarts nor resets that state. The health proof at line 5152 accepts only `ready`, `busy`, or `degraded`, so cleanup retains the marker and subsequent attempts hit `transactionPending`. — **Concrete fix:** Reconcile local readiness and keepalive after restoration, preserving the coordinator’s update-only routing fence, then prove restored health and retire the transaction. Test failure followed by retry without reconnecting.

MEDIUM — scripts/ops/cli-release.sh:440 — **NEW:** Rollback checks that P is published but never verifies that the supplied target compatibility ID matches P’s signed release identity. A wrong commit suffix can revoke V successfully, report completion, and strand providers when P’s manifest fails the exact-set check. — **Concrete fix:** Verify the supplied ID against P’s signed compatibility manifest before mutation and completion; test a published P with a mismatched commit suffix.

MEDIUM — scripts/ops/cli-release.sh:427 — **NEW:** An interrupted rollback cannot resume through the entrypoint after config installation but before restart. `release-registrations.py:403` recognizes only seed additions as pending revocations; adding V therefore produces a policy mismatch that blocks rollback, despite the config helper supporting unapplied-config recovery. — **Concrete fix:** Recognize the exact requested P-target/V-revocation edit as pending, preserve unrelated-mismatch refusal, and test interruption followed by `next --run`.

VERDICT: C=0 H=1 M=2 L=0
