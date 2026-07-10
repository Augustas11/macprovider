# BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY — Implementation Audit

Branch: `fix/launch-provider-autotune-apply`

Prompt: `specs/BUILD_FIX_LAUNCH_PROVIDER_AUTOTUNE_APPLY_PROMPT.md`

## Final Status

CODE: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO

SECURITY: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO

ARCHITECTURE: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 1 INFO

The remaining ARCH INFO is non-blocking: the app mirrors the CLI
recommendation-owned key list instead of sharing a schema module. The decision
log re-triggers on `ConfigApplier` key-list changes or a future shared schema,
and CLI tests assert JSON key parity against `ConfigApplier.recommendationOwnedKeys`.

## Fixes Applied During IMPL Audit

- Replaced app-side `serve_config` JSON parsing with a typed `Decodable`
  envelope so integer fields reject JSON booleans.
- Preserved nested/unrelated YAML while persisting recommendation-owned config
  keys; only true top-level keys are replaced.
- Rejected nested/indented serve-config fields during shape validation.
- Made `writeLinkState` preserve raw nested YAML and upsert only top-level
  `link_state`.
- Made configured startup route invalid/missing serve-config shape to onboarding
  instead of direct `agent.start()`.

## Verification

- `git diff --check`: passed.
- `swift test` from `phase3-binary`: 850 tests passed, 7 skipped, 0 failures.
- `xcodegen generate && xcodebuild test -project Malibu.xcodeproj -scheme Malibu -destination 'platform=macOS'`
  from `phase3-binary/app`: 89 tests passed, 0 failures.
- Targeted affected app tests: 44 tests passed, 0 failures.

## Audit Rounds

R1 found app config parsing/persistence and startup bypass issues:
- SECURITY: nested YAML could be flattened or treated as top-level.
- SECURITY: JSON boolean values could bridge through numeric parsing.
- ARCH/CODE: configured startup and link-state writes had validation gaps.

R2 after fixes:
- CODE: no findings.
- SECURITY: no findings.
- ARCHITECTURE: no critical/high/medium/low findings; one non-blocking INFO on
  mirrored app/CLI key lists.
