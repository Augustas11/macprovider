# Round 3 — SECURITY lane (omc ask codex)


HIGH — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:788 — **NEW; R2 remains open.** The final authorization snapshot is consistent but does not serialize activation with the `CoordinatorClient` actor. After `liveRevocation()` returns, teardown/reconnect can clear or replace authorization before the nonisolated updater activates P. The same race exists between `beforeRestart` returning at line 864 and restart. Removing subsequent awaits does not prevent another executor from changing session state; cancellation is also unchecked. — Perform final session validation and synchronous activation/restart within the same actor-isolated critical section, checking cancellation. Test withdrawal after snapshot capture but before mutation.

HIGH — phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:972 — **PRE-EXISTING; newly identified.** Manual update’s coordinator fallback checks that requested P is newer, but GitHub tag resolution never verifies that the response names P. Controlled release metadata can induce discovery fallback and return an older authentic signed Q for `/releases/tags/vP`. Preparation validates Q against its own signed artifacts, and line 272 installs it without exact revocation, recommendation binding, or a policy check for Q. — Reject response-tag mismatch, bind the prepared version to the requested target, and enforce forward-only ordering and effective policy for the actual prepared target before activation. Add a replayed-release-object regression.

MEDIUM — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:1105 — **PRE-EXISTING; R2 remains open.** Policy is now rechecked, but persistence remains unsynchronized with activation/restart. A concurrent manual `update --check` can persist a signed revocation of P or raise the minimum immediately after this read; the held mutation lock does not constrain `updateSignedPolicy`. P can consequently activate or restart despite already-observed prohibiting policy. — Use shared interprocess synchronization for policy persistence and the final policy-check/mutation boundaries, including atomic policy read/merge/write. Test policy advancement at both boundaries.

MEDIUM — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:1069 — **PRE-EXISTING; recovery remains incomplete.** Successful in-process restoration after a post-drain activation failure leaves `awaitingPreviousReadiness` while provider status remains `.draining`. The new retry invokes admission finalization, but its local-health proof rejects draining status. The pending marker therefore still blocks subsequent attempts. — Restore local readiness under the update-only routing fence, or restart restored V, before retiring the transaction. Test activation failure followed by retry in the held session.

The R2 generation/version binding finding is fixed. Exact identity and boolean handling, canonical downgrade parsing, the floor, shared cryptographic verification, signed discovery, and ops injection/policy guards show no additional confirmed bypass.

T-4 accurately records the intended residual risk: coordinator compromise permits authentic but potentially vulnerable signed history within the floor and locally observed policy bounds. The findings above exceed those intended guarantees.

Read-only static audit of HEAD `e8c0e4296`; no edits, network commands, or tests executed.

VERDICT: C=0 H=2 M=2 L=0
