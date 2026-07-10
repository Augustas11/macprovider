# BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY — BUILD audit

Three-lane Codex BUILD audit completed before implementation.

## Round 1

- CODE: `CRITICAL=0 HIGH=3 MEDIUM=1 LOW=0 INFO=1`
- SECURITY: `CRITICAL=0 HIGH=2 MEDIUM=1 LOW=0 INFO=0`
- ARCHITECT: `CRITICAL=0 HIGH=2 MEDIUM=3 LOW=2 INFO=0`

Outcome: prompt was not implementation-ready. Main correction: current
`autotune --recommend --json` does not emit apply-ready artifact/catalog
provenance, so Malibu.app must not synthesize serve config from display
JSON.

## Round 2

- SECURITY: `CRITICAL=0 HIGH=0 MEDIUM=0 LOW=1 INFO=0`
- ARCHITECT: `CRITICAL=0 HIGH=0 MEDIUM=2 LOW=1 INFO=0`

Outcome: prompt still needed explicit app-side result/dependency seams and
syntactic-vs-semantic validation ownership.

## Round 3

- CODE: `CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0 INFO=0`
- SECURITY: `CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0 INFO=0`
- ARCHITECT: `CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0 INFO=0`

Outcome: BUILD prompt converged to 0/0/0. Implementation proceeds under the
audited Approach B: CLI emits typed `serve_config` from apply-ready
`RecommendationCore`; Malibu.app validates/persists that payload through
`ProviderConfig`; controller verifies config shape before download/start and
demotes unsafe resume points back to autotune.

