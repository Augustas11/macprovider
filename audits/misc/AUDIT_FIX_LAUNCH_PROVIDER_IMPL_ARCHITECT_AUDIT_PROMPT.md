# ARCHITECT AUDIT PROMPT — Launch Provider Autotune Apply Fix Implementation

You are the ARCHITECT audit lane for `fix/launch-provider-autotune-apply`.
Work read-only. Do not edit files.

Audit architecture and contract fit of the implementation of
`specs/BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY_PROMPT.md`.

Expected implementation contract:
- Preferred Approach B is implemented: CLI JSON emits apply-ready `serve_config`
  from selected benchmark plus signed catalog row; Malibu.app persists that
  explicit payload and never synthesizes provenance.
- `--apply` and `--recommend --json` share the same `RecommendationCore`-derived
  payload.
- `LaunchProviderController` persists/validates `serve_config` before progress
  to download/startAgent and demotes unsafe resume/configured paths to autotune.
- CLI `serve` remains semantic authority for catalog freshness, artifact hash,
  path admissibility, and rate-card/model checks.
- Tests and decision log lock the contract enough for future maintenance.

Return findings first, ordered by severity, with file/line references.
If no CRITICAL/HIGH/MEDIUM issues remain, explicitly state whether any LOW/INFO
risk is non-blocking.

End with:
`STATUS: ARCH lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
