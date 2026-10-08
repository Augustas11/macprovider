# Audit R2: SPEC-049 v0.2.0 automatic enrollment (all lanes)

Read `audits/2026-10-06-privacy-auto-enrollment/AUDIT_AUTO_ENROLLMENT_CONTEXT.md` and the lane prompt for your lane (`AUDIT_AUTO_ENROLLMENT_<LANE>_PROMPT.md`) first; the METHOD constraint applies. Scope is again the FULL combined diff `origin/main...HEAD`. This is round 2 of at most 3. Report only real defects; the gate is 0 CRITICAL/HIGH/MEDIUM.

The branch is rebased onto main after PR #1867, which recorded SPEC-049 0.1.4 (§8.1 staged-canary exception, Entry 249, the committed signed journey result). The branch's SPEC-049 is 0.2.0 on top of 0.1.4.

## Round-1 verdicts

- SECURITY: 0 / 0 / 0 / 1 LOW / 0
- CODE: 0 / 0 / 1 MEDIUM / 1 LOW / 0
- ARCHITECTURE: 0 / 0 / 2 MEDIUM / 3 LOW / 0

## Dispositions

- CODE MEDIUM (pre-existing): a consumed challenge rejected for session binding, clock skew, or key backend left the earlier posture eligible until max age. Fixed: every consumed, non-quarantine reject now calls `NoteChallengeTimeout`; tests updated to require ineligibility.
- ARCHITECTURE MEDIUM 1 (rollout skew drops plain relay-blind): fixed. Automatic mode now requires both `privacy_class_beta` and `relay_blind_enabled` unset. An explicit `relay_blind_enabled: true` keeps plain SPEC-041 relay-blind records, so nothing a provider advertised before is withdrawn. Providers with relay-blind unset advertised no relay-blind records before this change. SPEC-049 R001/R024 and the runbook updated.
- ARCHITECTURE MEDIUM 2 (loader cap empties the approval set): fixed. The loader orders `v<x>.<y>.<z>.json` newest first, reads the 256 newest, and reports the rest as rejected; it never drops the whole set for size. SPEC-049-R027 updated; test added.
- CODE LOW (fixture claim without records): fixed.
- SECURITY LOW (status prints provider ID and code identity): the SPEC wording was wrong, not the CLI. `status` is an operator command on the coordinator host's own store; R018 now states it lists provider ID, public fingerprints, and code identity, never key bytes.
- ARCHITECTURE LOW 5 (mixed provenance): specified in R028; a provider with a configured identity pin and an enrolled SE key is `source: enrolled`.
- Carried LOWs: unbounded revoked-enrollment history (rows are tiny and bounded by operator reenroll actions), and directory capacity alerting before 4096 entries / 1 MiB (the directory fails closed with a logged warning; far above current fleet size).
- Merge with #1867: SPEC-049 §8.1 (one pinned provider) is superseded cleanly by v0.2.0 (see §8.2 and §10): §8.1 governs only coordinator code at 0.1.x; production activation of 0.2.0 automatic enrollment needs a new dated exception or R023 promotion. Per-requirement CONFORMANCE rationales now record the committed signed result and the recorded exception; every requirement stays pending.

Lane: <LANE>. Findings by severity with file:line, condition, fix, NEW or PRE-EXISTING. End with exactly one line:
`VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW / <n> INFO`
