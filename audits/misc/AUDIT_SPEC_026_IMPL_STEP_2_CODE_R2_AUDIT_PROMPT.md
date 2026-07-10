# AUDIT_SPEC_026_IMPL_STEP_2_CODE_R2_AUDIT_PROMPT

You are auditing PR #347 from the CODE lane, round 2.

Repository/worktree:
- `/Users/augstar/macprovider-spec026-app`
- Branch: `feat/spec-026-app-onboarding-impl`
- Audited HEAD: `0b458595d4089cda4f7e8f41b854dad1d4733156`
- Relevant implementation commits: `4719fa3..0b45859`

Source of truth:
- `specs/BUILD_SPEC_026_IMPL_STEP_2_APP_BUNDLE_PROMPT.md`
- `specs/SPEC-026-browserless-provider-onboarding.md`
- Round 1 CODE artifact: `.omc/artifacts/ask/codex-audit-spec-026-impl-step-2-code-audit-prompt-you-are-auditin-2026-07-04T03-20-26-802Z.md`

Lens: CODE correctness, edge cases, state-machine mechanics, Swift concurrency, persistence behavior, generated project drift, test adequacy, and implementation completeness against the build prompt.

Required checks:
1. Verify every round 1 CODE blocking finding is closed:
   - CODE-H-1: uninstall must not delete the SPEC-015 receipt Keychain service.
   - CODE-H-2: v2 partial onboarding resume and CLI-owned config import must not be gated behind `MALIBU_ONBOARD_V2`; only fresh starts should be flag-gated.
   - CODE-M-1: migration cancel should quit without file changes, and the start-fresh backup dialog should show the exact reclaim command `macprovider-cli --config <backup-file>`.
   - CODE-M-2: unclaimed badge dismissal should be session-scoped, not persisted across launches.
2. Inspect the current implementation diff and current files, not only the latest commit.
3. Look for new CRITICAL/HIGH/MEDIUM regressions introduced by the fixes.
4. Treat missing build-prompt scope as CODE if it is an implementation/test gap rather than a product/security/architecture concern.
5. Do not report LOW/INFO as blocking. CRITICAL/HIGH/MEDIUM are blocking.
6. Do not edit files.

Expected validation evidence available locally:
- `cd phase3-binary/app && xcodegen generate && xcodebuild -project Malibu.xcodeproj -scheme Malibu build-for-testing`
- Full `xcodebuild ... test` currently hangs after launching the macOS app host; an xcresult from the interrupted run recorded cancellation only, not assertion failures.
- Retired-symbol grep returned no matches:
  `rg -n "PendingLinkState|URLSchemeHandler|malibu://|CFBundleURLSchemes|CFBundleURLTypes|\bnode\b" phase3-binary/app/Sources phase3-binary/app/Tests phase3-binary/app/project.yml phase3-binary/app/Malibu.xcodeproj phase3-binary/app/README.md README.md`
- Built bundle URL-scheme check returned `Does Not Exist`:
  `/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' <DerivedData>/Build/Products/Debug/Malibu.app/Contents/Info.plist`
- `git diff --check`

Output format:
- Start with `CODE VERDICT: READY` if and only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- Otherwise start with `CODE VERDICT: FIX REQUIRED`.
- Include a count line exactly: `COUNTS: C=<n> H=<n> M=<n> L=<n> I=<n>`.
- Then list findings in severity order using IDs like `CODE-C-1`, `CODE-H-1`, `CODE-M-1`.
- Each blocking finding must cite exact files/lines and explain the failure mode plus the expected fix.
- If READY, still mention any LOW/INFO and residual validation gaps.
