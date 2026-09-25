# #1690 M8 audit: round 4, CODE lane only (final)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Focus diff:** `git diff f44e5ef6 HEAD`, which is M8 with its fix commits (`ed2474cd`, `0a399761`, `050be887`). The M8 common brief and code lane brief apply. The SECURITY and ARCH lanes passed in round 2.

**New since round 3:** `050be887`. Serve-time snapshot hashing always runs under a deadline, `MLXLMLoopbackServeModel.snapshotHashingDeadline()` = now + `BYOMModelAdmissionRuntime.artifactHashBudgetSeconds` (600 s, the same budget as the BYOM offer path). The parameter is non-optional, and an overrun stops startup fail-closed. A test covers it.

**Verify that the round-3 MEDIUM (serve-time hashing with a nil deadline) is resolved, and that nothing regressed.** Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
