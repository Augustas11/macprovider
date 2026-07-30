# AUDIT_SPEC_026_IMPL_STEP_2_ARCHITECT_AUDIT_PROMPT

You are auditing PR #347 from the ARCHITECT lane.

Repository/worktree:
- `/Users/augstar/macprovider-spec026-app`
- Branch: `feat/spec-026-app-onboarding-impl`
- Audited HEAD: `520a4a03d9fd9f59552e768c19cf0336bdfed6e6`
- Relevant implementation commits: `4719fa3..520a4a0`

Source of truth:
- `specs/BUILD_SPEC_026_IMPL_STEP_2_APP_BUNDLE_PROMPT.md`
- `specs/SPEC-026-browserless-provider-onboarding.md`
- Adjacent app files and tests under `phase3-binary/app`

Lens: ARCHITECTURE, including right-layer ownership, SPEC-026/SPEC-025/SPEC-016/SPEC-027 boundaries, App-vs-CLI responsibilities, rollout/feature-flag posture, startup/migration state classification, controller seams, steady-state UI invariants, and whether the branch is safe to treat as Step 2 App-track implementation.

Required checks:
1. Inspect the implementation diff and current files, not only the latest commit.
2. Verify the implementation does not take ownership of sibling coordinator, SPEC-016 wallet signing, SPEC-027 cancellation/email, or real model-catalog scope beyond the specified seams.
3. Verify configured, CLI-owned, v2-partial, fresh, identity-only, and configured-but-first-serving-missing routes compose cleanly with App launch behavior.
4. Verify unclaimed-earnings/MALIBU-locked UI behavior has a durable domain model rather than one-off strings.
5. Verify the implementation can evolve to real autotune/model download without architectural rewrite.
6. Do not report LOW/INFO as blocking. CRITICAL/HIGH/MEDIUM are blocking.
7. Do not edit files.

Expected validation evidence available locally:
- `cd phase3-binary/app && xcodegen generate && xcodebuild -project Malibu.xcodeproj -scheme Malibu test`
- Retired-symbol grep:
  `rg -n "PendingLinkState|URLSchemeHandler|malibu://|CFBundleURLSchemes|CFBundleURLTypes|\bnode\b" phase3-binary/app/Sources phase3-binary/app/Tests phase3-binary/app/project.yml phase3-binary/app/Malibu.xcodeproj phase3-binary/app/README.md README.md`
- Built bundle URL-scheme check:
  `/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' <DerivedData>/Build/Products/Debug/Malibu.app/Contents/Info.plist`

Output format:
- Start with `ARCHITECT VERDICT: READY` if and only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- Otherwise start with `ARCHITECT VERDICT: FIX REQUIRED`.
- Include a count line exactly: `COUNTS: C=<n> H=<n> M=<n> L=<n> I=<n>`.
- Then list findings in severity order using IDs like `ARCH-C-1`, `ARCH-H-1`, `ARCH-M-1`.
- Each blocking finding must cite exact files/lines and explain the boundary/design failure plus the expected fix.
- If READY, still mention any LOW/INFO and residual validation gaps.
