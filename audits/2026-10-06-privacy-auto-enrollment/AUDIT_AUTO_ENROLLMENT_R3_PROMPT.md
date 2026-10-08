# Audit R3 (FINAL): SPEC-049 v0.2.0 automatic enrollment (all lanes)

Read `AUDIT_AUTO_ENROLLMENT_CONTEXT.md`, your lane prompt (`AUDIT_AUTO_ENROLLMENT_<LANE>_PROMPT.md`), and `AUDIT_AUTO_ENROLLMENT_R2_PROMPT.md` in this directory first; the METHOD constraint applies. Scope: the FULL combined diff `origin/main...HEAD` (main now includes #1867, SPEC-049 0.1.4). Round 3 of 3, the last. Report only real defects; the gate is 0 CRITICAL/HIGH/MEDIUM. Remaining findings after this round are carried in the PR body.

## Round-2 verdicts

- SECURITY: 0 / 1 HIGH / 2 MEDIUM / 3 LOW / 0
- CODE: 0 / 0 / 2 MEDIUM / 0 / 0 (the same two issues as security HIGH 1 and MEDIUM 3)
- ARCHITECTURE: 0 / 0 / 0 / 4 LOW / 0

## Round-2 dispositions

- HIGH (stale session enrolls after replacement or reenroll): fixed. `VerifyPosture` checks `postureStillCurrent` (session generation, bound generation, epoch) and that every listed key digest is still fresh for that session before `EnrollPrivacyIdentity`. The ws probe runs `VerifyPosture` inside `withProviderSection` with a `pool.Resolve` current-session check; session replacement holds that section. `reenroll` revokes the provider's privacy keys, so an in-flight posture that lists them is rejected `posture_keys_stale`. Tests: `TestEnrollmentFencedForStaleSessionAndRevokedKeys`. SPEC-049-R025 updated.
- MEDIUM (pre-existing; failed quarantine write not fail-closed): fixed with an in-memory `pendingQuarantine` latch used by `isQuarantined` at every check (advertisement, posture, `Eligible`), retrying the durable write until it lands. Test: `TestQuarantineWriteFailureLatchesUntilDurable`. SPEC-049-R017 updated. The latch is in memory; after a coordinator restart every posture is gone anyway and a new posture must verify.
- MEDIUM (two config snapshots): fixed. `sameEligibilityInputs` compares the checked and the serving snapshot; automatic mode falls back to ordinary serving (`configuration_changed`), forced mode throws. Test: `testConfigurationChangedBetweenReadsNeverServesUncheckedPrivacy`. SPEC-049-R024 updated.
- LOW (eligibility creates the SE key and state directory): documented as intended in R024 and the hook comment; only an eligible host reaches that step, and the side effects are harmless for ordinary serving.
- LOW (release loader symlink TOCTOU): `O_NOFOLLOW` open plus the existing `Lstat`/`SameFile` check.
- LOW (keygen chmod by path): mode set on the open descriptor before close.
- ARCHITECTURE LOWs: §1.3 label and the `## 3. Authority and composition` heading fixed. Carried: revoked-enrollment retention and directory capacity alerting.

Lane: <LANE>. Findings by severity with file:line, condition, fix, NEW or PRE-EXISTING. End with exactly one line:
`VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW / <n> INFO`
