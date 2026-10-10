# Round 2 — CODE lane (omc ask codex)


HIGH — `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:766` — **NEW; R1 authorization finding remains open.** The swap gate checks live revocation at line 449, then separately awaits generic trust here. A reconnect can change the revocation or recommendation during that second await while trust remains eligible, allowing activation under stale authorization. — **Fix:** make the final swap gate validate trust, session generation, revocation and recommendation together, with no further await before activation. Test a session change during the final trust check.

HIGH — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:2205` — **NEW, enabled by the pre-existing cancellation race; R1 remains open.** Timeout cancels `restoreTask` without awaiting termination. Restore work already inside session acceptance can resume after cleanup/reconnect and republish its old revocation notice at line 4347. Live checks compare notice values, without binding authorization to the accepted-session generation. — **Fix:** await cancelled restore work before reconnecting and reject stale session acceptance using connection/session identity. Test a suspended restore overlapping reconnect to a non-revoked session.

MEDIUM — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:4842` — **NEW; R1 attribution finding remains partially open.** Restored V still emits rollback cleanup failures without `update_direction`; continuous-batching rollback failures at line 5060 and startup recovery events at line 5687 also omit it. These events originate from V, so the SPEC’s legacy-target exception does not cover them. The test claiming every event is attributed still checks only the last release-resolution event. — **Fix:** derive direction from the marker’s previous/target versions and coordinator authority, stamp all applicable recovery emitters, and assert complete failure/recovery event sequences.

MEDIUM — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:6309` — **NEW.** The new cooldown retry feeds repeated downgrade failures into the R005 tracker, then invokes signed recovery at line 6324. Repeated failures can reach R005 eligibility despite amended R007 explicitly excluding downgrades from that workflow. — **Fix:** keep revoked-build downgrade outcomes outside R005 accounting and use their coordinator retry path exclusively. Test repeated failures through the threshold with no R005 increments or signed-recovery invocation.

The R1 buyer-serving gate is fixed, and cooldown retries are now wired. Diff checks, shell/Python syntax checks, and the targeted Python rollback test passed. Swift/Go tests were not run. No edits or network commands were performed.

VERDICT: C=0 H=2 M=2 L=0
