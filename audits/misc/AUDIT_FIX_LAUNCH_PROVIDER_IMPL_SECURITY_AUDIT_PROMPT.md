# SECURITY AUDIT PROMPT — Launch Provider Autotune Apply Fix Implementation

You are the SECURITY audit lane for `fix/launch-provider-autotune-apply`.
Work read-only. Do not edit files.

Audit security and trust-boundary properties of the implementation of
`specs/BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY_PROMPT.md`.

Expected implementation contract:
- CLI owns derivation of apply-ready `serve_config` from selected benchmark plus
  signed catalog row.
- Malibu.app consumes explicit `serve_config` only; it must not synthesize or
  rederive catalog/artifact provenance.
- App validation is defensive shape validation only; CLI `serve` remains
  semantic admission authority.
- Config persistence preserves unrelated config and replaces only true
  top-level recommendation-owned keys.
- Config validation does not accept nested/indented YAML keys as top-level
  serve config.
- JSON parsing rejects booleans for integer fields.
- No secret/token logging, permission widening, unintended sensitive-path edits,
  or `d-inference` source inspection.

Return findings first, ordered by severity, with file/line references.
If no issues remain, say `No findings.`

End with:
`STATUS: SECURITY lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
