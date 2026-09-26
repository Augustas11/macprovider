# M6 promotion-economics review record

## Scope

Round 1 reviewed the complete M6 calculator, tests, and evidence runbook in
three Codex lanes: code, security, and architecture. The prompt files in
`prompts/` are the exact review inputs.

## Findings and disposition

- No CRITICAL or HIGH findings were reported.
- All three lanes reported the unrelated SwiftPM `Package.resolved` rewrite as
  MEDIUM. The file was restored and is not part of M6.
- Security reported one MEDIUM hostile-numeric exhaustion finding. The
  calculator now bounds integer digits, decimal significant/fractional digits,
  exponent/effective scale, and JSON nesting before constructing exact rational
  values. Tests cover oversized integers, both extreme exponent directions,
  excessive precision/scale, and excessive nesting.
- Remaining findings were LOW: broader pinning of generated table values,
  stricter-than-general completion invariants, output-parent races, lack of
  signature verification, partial table regression coverage, and prompt-only
  scaffolding. The evidence explicitly states that the tool validates only the
  rate-card projection hash and is an offline modeled proxy, not ledger
  settlement or an authorization surface.

At the operator's direction, no additional audit rounds were run. Validation
moved directly to Mac Studio e2e and only observed failures would trigger more
changes.

## Validation

- Local focused suite: 20 passed, 0 failed.
- Deterministic local double-run: byte-identical, SHA-256
  `5219ada184cc9fb59b795893019604620910429d0bdd635a05443bc5d39f4116`.
- Mac Studio isolated reproduction: 20 passed, 0 failed; two generated reports
  were byte-identical and had the same SHA-256 and 8,508-byte size.
- The Studio run did not pause, restart, reconfigure, or contact the live
  provider.
