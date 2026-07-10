# AUDIT_SPEC_026_IMPL_STEP_2_CODE_AUDIT_PROMPT

You are auditing PR #347 from the CODE lane.

Repository/worktree:
- `/Users/augstar/macprovider-spec026-app`
- Branch: `feat/spec-026-app-onboarding-impl`
- Audited HEAD: `520a4a03d9fd9f59552e768c19cf0336bdfed6e6`
- Relevant implementation commits: `4719fa3..520a4a0`

Source of truth:
- `specs/BUILD_SPEC_026_IMPL_STEP_2_APP_BUNDLE_PROMPT.md`
- `specs/SPEC-026-browserless-provider-onboarding.md`
- Adjacent app files and tests under `phase3-binary/app`

Lens: CODE correctness, edge cases, state-machine mechanics, Swift concurrency, persistence behavior, generated project drift, test adequacy, and implementation completeness against the build prompt.

Required checks:
1. Inspect the implementation diff and current files, not only the latest commit.
2. Verify the App-track launch/onboarding state machine, retry/resume paths, startup classifier, migration decisions, earnings client, menu-bar badge behavior, and retired deep-link surface.
3. Treat missing build-prompt scope as CODE if it is an implementation/test gap rather than a product/security/architecture concern.
4. Do not report LOW/INFO as blocking. CRITICAL/HIGH/MEDIUM are blocking.
5. Do not edit files.

Expected validation evidence available locally:
- `cd phase3-binary/app && xcodegen generate && xcodebuild -project Malibu.xcodeproj -scheme Malibu test`
- Retired-symbol grep:
  `rg -n "PendingLinkState|URLSchemeHandler|malibu://|CFBundleURLSchemes|CFBundleURLTypes|\bnode\b" phase3-binary/app/Sources phase3-binary/app/Tests phase3-binary/app/project.yml phase3-binary/app/Malibu.xcodeproj phase3-binary/app/README.md README.md`
- Built bundle URL-scheme check:
  `/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' <DerivedData>/Build/Products/Debug/Malibu.app/Contents/Info.plist`

Output format:
- Start with `CODE VERDICT: READY` if and only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- Otherwise start with `CODE VERDICT: FIX REQUIRED`.
- Include a count line exactly: `COUNTS: C=<n> H=<n> M=<n> L=<n> I=<n>`.
- Then list findings in severity order using IDs like `CODE-C-1`, `CODE-H-1`, `CODE-M-1`.
- Each blocking finding must cite exact files/lines and explain the failure mode plus the expected fix.
- If READY, still mention any LOW/INFO and residual validation gaps.
