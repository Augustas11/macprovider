# CODE AUDIT PROMPT — Launch Provider Autotune Apply Fix Implementation

You are the CODE audit lane for `fix/launch-provider-autotune-apply`.
Work read-only. Do not edit files.

Audit the implementation of `specs/BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY_PROMPT.md`.
Focus on changed files and trace wider impact only where needed.

Expected implementation contract:
- `macprovider-cli autotune --recommend --json` emits an apply-ready top-level
  `serve_config` derived from the selected benchmark plus signed catalog row.
- `serve_config` is `null` when no apply-ready payload exists.
- `--apply` uses the same `RecommendationCore` payload that JSON output emits.
- Malibu.app parses the explicit `serve_config`, persists it to `config.yaml`,
  validates config shape before download/startAgent, and demotes unsafe
  resume/configured paths back to autotune.
- Malibu.app must not synthesize catalog/artifact provenance.
- `serve` remains semantic admission authority.

Check tests cover JSON field parity/null behavior, parser rejection, persistence
and validation, retry/resume/configured paths, nested YAML preservation/rejection,
and strict JSON bool-vs-int handling.

Return findings first, ordered by severity, with file/line references.
If no issues remain, say `No findings.`

End with:
`STATUS: CODE lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
