# AUDIT_SPEC_026_IMPL_STEP_2_SECURITY_AUDIT_PROMPT

You are auditing PR #347 from the SECURITY lane.

Repository/worktree:
- `/Users/augstar/macprovider-spec026-app`
- Branch: `feat/spec-026-app-onboarding-impl`
- Audited HEAD: `520a4a03d9fd9f59552e768c19cf0336bdfed6e6`
- Relevant implementation commits: `4719fa3..520a4a0`

Source of truth:
- `specs/BUILD_SPEC_026_IMPL_STEP_2_APP_BUNDLE_PROMPT.md`
- `specs/SPEC-026-browserless-provider-onboarding.md`
- Adjacent app files and tests under `phase3-binary/app`

Lens: SECURITY, including Keychain boundaries, token handling, no secret logging, no bearer persistence in YAML/onboarding JSON, clean-room boundaries, migration rollback safety, uninstall cleanup, app/CLI trust boundary, identity-signature frame behavior, and URL/deep-link retirement.

Required checks:
1. Inspect the implementation diff and current files, not only the latest commit.
2. Verify identity key material never leaves the App Keychain slot and is not exported to child process environments.
3. Verify provider tokens are not persisted in app-owned YAML/onboarding state after migration or save, are not logged, and are not exposed through error strings.
4. Verify the migration import/start-fresh/cancel paths are failure-safe and do not accidentally mark a CLI-owned config as app-owned without a token.
5. Verify the earnings endpoint, first-serving wait, and menu badge changes do not introduce credential leakage or unsafe network behavior.
6. Do not report LOW/INFO as blocking. CRITICAL/HIGH/MEDIUM are blocking.
7. Do not edit files.

Expected validation evidence available locally:
- `cd phase3-binary/app && xcodegen generate && xcodebuild -project Malibu.xcodeproj -scheme Malibu test`
- Retired-symbol grep:
  `rg -n "PendingLinkState|URLSchemeHandler|malibu://|CFBundleURLSchemes|CFBundleURLTypes|\bnode\b" phase3-binary/app/Sources phase3-binary/app/Tests phase3-binary/app/project.yml phase3-binary/app/Malibu.xcodeproj phase3-binary/app/README.md README.md`
- Built bundle URL-scheme check:
  `/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' <DerivedData>/Build/Products/Debug/Malibu.app/Contents/Info.plist`

Output format:
- Start with `SECURITY VERDICT: READY` if and only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- Otherwise start with `SECURITY VERDICT: FIX REQUIRED`.
- Include a count line exactly: `COUNTS: C=<n> H=<n> M=<n> L=<n> I=<n>`.
- Then list findings in severity order using IDs like `SEC-C-1`, `SEC-H-1`, `SEC-M-1`.
- Each blocking finding must cite exact files/lines and explain exploitability or security impact plus the expected fix.
- If READY, still mention any LOW/INFO and residual validation gaps.
