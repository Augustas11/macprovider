# AUDIT_SPEC_026_IMPL_STEP_2_SECURITY_R2_AUDIT_PROMPT

You are auditing PR #347 from the SECURITY lane, round 2.

Repository/worktree:
- `/Users/augstar/macprovider-spec026-app`
- Branch: `feat/spec-026-app-onboarding-impl`
- Audited HEAD: `0b458595d4089cda4f7e8f41b854dad1d4733156`
- Relevant implementation commits: `4719fa3..0b45859`

Source of truth:
- `specs/BUILD_SPEC_026_IMPL_STEP_2_APP_BUNDLE_PROMPT.md`
- `specs/SPEC-026-browserless-provider-onboarding.md`
- Round 1 SECURITY artifact: `.omc/artifacts/ask/codex-audit-spec-026-impl-step-2-security-audit-prompt-you-are-aud-2026-07-04T03-20-37-100Z.md`

Lens: SECURITY and abuse resistance, especially secret handling, Keychain ownership boundaries, migration rollback integrity, provider identity/proof binding, auth attempt handling, entitlement/deep-link retirement, and security-sensitive state transitions.

Required checks:
1. Verify every round 1 SECURITY blocking finding is closed:
   - SEC-M-1: failed CLI import rollback must not destroy the original config if restore fails; critical rollback errors must not be suppressed.
   - SEC-M-2: identity-signature handling must load an existing identity without generating a replacement and must refuse signing when the loaded key does not derive to the configured provider ID.
   - SEC-M-3: first-serving completion must not be based on control-socket connection alone; it must wait for real serving status.
2. Inspect the current implementation diff and current files, not only the latest commit.
3. Look for new CRITICAL/HIGH/MEDIUM security regressions introduced by the fixes.
4. Do not report LOW/INFO as blocking. CRITICAL/HIGH/MEDIUM are blocking.
5. Do not edit files.

Expected validation evidence available locally:
- `cd phase3-binary/app && xcodegen generate && xcodebuild -project Malibu.xcodeproj -scheme Malibu build-for-testing`
- Full `xcodebuild ... test` currently hangs after launching the macOS app host; an xcresult from the interrupted run recorded cancellation only, not assertion failures.
- Retired-symbol grep returned no matches.
- Built bundle `CFBundleURLTypes` check returned `Does Not Exist`.
- `git diff --check`

Output format:
- Start with `SECURITY VERDICT: READY` if and only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- Otherwise start with `SECURITY VERDICT: FIX REQUIRED`.
- Include a count line exactly: `COUNTS: C=<n> H=<n> M=<n> L=<n> I=<n>`.
- Then list findings in severity order using IDs like `SEC-C-1`, `SEC-H-1`, `SEC-M-1`.
- Each blocking finding must cite exact files/lines and explain the failure mode plus the expected fix.
- If READY, still mention any LOW/INFO and residual validation gaps.
