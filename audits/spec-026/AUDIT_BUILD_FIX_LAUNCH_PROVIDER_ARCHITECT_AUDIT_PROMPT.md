# AUDIT_BUILD_FIX_LAUNCH_PROVIDER_ARCHITECT_AUDIT — ARCHITECT lane

You are auditing the BUILD prompt
`specs/BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY_PROMPT.md` before
implementation. Read the BUILD prompt, then inspect the referenced code
only as needed to determine whether the proposed shape fits the existing
system boundaries.

## Your lane: ARCHITECT

Focus on design-level concerns: ownership, boundaries, extensibility, and
consistency with existing repo patterns. Do not audit ordinary correctness
or security except where they reveal a design flaw.

### Look for

1. Whether App-side persistence of CLI recommendation fields belongs in
   `ProviderConfig`/onboarding plumbing rather than duplicating CLI config
   writer logic in `LaunchProviderController`.
2. Whether the prompt keeps SPEC-026 stage order and `onboarding.json` schema
   unchanged while still covering fresh launch, retry, and resume.
3. Whether any required config schema knowledge should be centralized so the
   app and CLI do not drift on serve-readiness requirements.
4. Whether the BUILD prompt's fallback options avoid scope creep into the
   CLI autotune hang, coordinator surfaces, package signing, or installer
   logic.
5. Whether the tests belong in `LaunchProviderControllerTests`,
   `ProviderConfigTests`, or both, based on existing ownership seams.
6. Whether the defensive pre-serve validation should be a reusable
   `ProviderConfig` capability rather than inline controller parsing.
7. Whether the prompt includes the necessary decision-log update if the app
   takes ownership of writing autotune recommendation fields.
8. Whether manual smoke requirements are realistic and separate from
   automated definition-of-done checks.

### Do NOT flag

- Code-level bugs unless they indicate the prompt's design is wrong.
- Security-only concerns without an architectural implication.
- Pure taste differences that do not affect maintainability or boundaries.

### Output format

Report findings ranked C / H / M / L / I. Each finding lists: prompt
section, design concern, future scenario where it bites, proposed prompt
change.

```
STATUS: ARCHITECT lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

