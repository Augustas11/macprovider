# AUDIT_BUILD_FIX_LAUNCH_PROVIDER_SECURITY_AUDIT — SECURITY lane

You are auditing the BUILD prompt
`specs/BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY_PROMPT.md` before
implementation. Read the BUILD prompt, then inspect the referenced code
only as needed to determine whether the prompt adequately constrains the
security-sensitive parts of the fix.

## Your lane: SECURITY

Focus exclusively on security-class prompt gaps. Do not audit ordinary code
correctness or architecture.

### Look for

1. **Config file integrity**
   - App-written config preserves mode `0600`.
   - Writes use the existing atomic replace plus fsync discipline.
   - Partial writes cannot leave `serve` reading a truncated or mixed config.

2. **Path safety**
   - The fix writes only to the expected app/provider config path from the
     existing `ProviderConfig` path plumbing.
   - No CLI-output-controlled path is introduced.
   - Retry/resume cannot redirect writes through a stale or untrusted path.

3. **YAML/value injection**
   - `model_artifact_sha256` must be validated as 64 lowercase hex before it
     is written or accepted as serve-ready.
   - Catalog/model fields copied from autotune JSON must be serialized through
     an existing safe writer or strict escaping path.
   - Newline, colon, quote, and comment characters in model/catalog fields
     cannot create extra YAML keys or alter existing keys.

4. **Privilege/secret boundaries**
   - The app must not weaken `sanitizedProcessEnvironment`.
   - The fix must not log provider tokens, keychain material, config file
     contents, or full paths unnecessarily.
   - It must preserve existing `saved_provider_token` handling.

5. **Trust boundary of autotune JSON**
   - If the app trusts CLI JSON, the prompt must require strict schema/field
     validation before persisting values that `serve` treats as provenance.
   - If the JSON lacks required provenance, the prompt must not instruct the
     app to synthesize trusted catalog fields.

6. **Failure behavior**
   - Fail-loud validation must avoid retry loops that repeatedly rewrite bad
     data.
   - A malformed or malicious autotune JSON response must stop before
     `.startingAgent`.

### Do NOT flag

- Non-security correctness defects.
- Placement or maintainability issues without a security consequence.
- Security changes outside the local Malibu.app / bundled CLI config path
  unless the BUILD prompt introduces them.

### Output format

Report findings ranked C / H / M / L / I. Each finding lists: prompt
section, threat model, concrete scenario, proposed mitigation or prompt
change.

```
STATUS: SECURITY lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

