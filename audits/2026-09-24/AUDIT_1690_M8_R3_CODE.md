# #1690 M8 audit: round 3, CODE lane only

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Focus diff:** `git diff f44e5ef6 HEAD`, which is M8 with its fix commits `ed2474cd` and `0a399761`. The M8 common brief (`AUDIT_1690_M8_COMMON.md`) and code lane brief (`AUDIT_1690_M8_LANE_CODE.md`) apply. The SECURITY and ARCH lanes passed in round 2.

**New since round 2:** `0a399761`. Every snapshot directory walk in `MLXLMLoopback.swift` now takes the hashing deadline, checked before starting, per entry, and after traversal. Snapshots are capped at 100,000 regular files. The per-request `isCurrent()` revalidation has a 5 s budget, stops early once it sees more files than were hashed, and fails closed on overrun. New tests cover an expired deadline and a large tree.

**Verify that the round-2 CODE MEDIUM (unbounded snapshot scans) is resolved, and that nothing regressed.** Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
