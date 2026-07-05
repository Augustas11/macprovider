# AUDIT_BUILD_FIX_LAUNCH_PROVIDER_CODE_AUDIT — CODE lane

You are auditing the BUILD prompt
`specs/BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY_PROMPT.md` before
implementation. Read the BUILD prompt, then inspect the referenced code
only as needed to determine whether the prompt is correct, complete, and
implementation-ready.

## Your lane: CODE correctness

Focus exclusively on implementation correctness risks in the BUILD prompt.
Do not audit security or architecture except where they directly create a
correctness failure.

### Look for

1. Whether the prompt identifies all config fields that `serve` requires
   before coordinator join, not just `model_artifact_sha256`.
2. Whether `autotune --recommend --json` actually exposes the required
   recommendation/provenance fields or whether `--apply` computes anything
   unavailable to the app.
3. Whether the proposed App-side config write can preserve existing
   `provider_id`, `saved_provider_token`, `link_state`, and unrelated CLI
   keys.
4. Whether the prompt names the correct transition points in
   `LaunchProviderController` for fresh launch, retry, and resume.
5. Whether the requested tests are feasible with the existing dependency
   injection seams and can fail on the current bug.
6. Whether the defensive pre-serve validation is specific enough to prevent
   the current exit-2 loop without hiding the real failure.
7. Whether the prompt accidentally requires changing `onboarding.json`
   schema, state-machine stage order, CLI child-process environment, or other
   out-of-scope behavior.
8. Whether any referenced files, methods, line numbers, or expected error
   strings are stale enough to mislead implementation.

### Do NOT flag

- Security concerns unless they would also cause a correctness failure.
- Layering or ownership concerns unless they make the prompt impossible to
  implement correctly.
- Pure wording issues that do not affect implementation.

### Output format

Report findings ranked C (CRITICAL) / H (HIGH) / M (MEDIUM) / L (LOW) /
I (INFO). One paragraph per finding: prompt section, defect description,
concrete implementation failure scenario, proposed prompt fix in plain
English. No code patches.

Include a bottom-line status line:

```
STATUS: CODE lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

