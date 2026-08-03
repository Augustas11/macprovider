# Autotune coherent probe — 2026-08-03 audit convergence

Scope reviewed: full fix diff from `origin/main` to the working tree, limited to the five implementation/test files listed in the three audit prompts. The clean-room `d-inference` boundary was preserved.

## Lane results

| Lane | Final CRITICAL | Final HIGH | Final MEDIUM | Verdict | Codex artifact |
| --- | ---: | ---: | ---: | --- | --- |
| Code | 0 | 0 | 0 | PASS | `.omc/artifacts/ask/codex-full-diff-code-audit-autotune-coherent-probe-review-the-comp-2026-08-03T13-35-51-703Z.md` |
| Security | 0 | 0 | 0 | PASS | `.omc/artifacts/ask/codex-full-diff-security-audit-autotune-coherent-probe-review-the--2026-08-03T13-37-44-034Z.md` |
| Architect | 0 | 0 | 0 | PASS after remediation | post-fix recheck recorded below |

`ALL-LANES: CODE=0/0/0 SECURITY=0/0/0 ARCHITECT=0/0/0`

## Remediation record

The architect round initially identified two MEDIUM findings:

1. A repeat cap could underfill supported large contexts while Stage 2 persisted the uncapped estimate.
2. Small positive contexts could receive a prompt larger than the requested context.

The fix closes both findings by increasing the bounded repeat ceiling to 4,096 (enough for the documented 200,000-token maximum), enforcing the shared `64...200000` probe-context contract in `AutotuneCommand`, and adding boundary tests for a supported small context and an extreme direct helper call. The required independent 2,000 → 1,600 and 24,000 → 19,200 contract map remains in the length test.

The final architect recheck was invoked twice with `omc ask codex` after rebasing onto the current `origin/main`; the provider advisor stalled before emitting a new artifact on both attempts. The PASS status above is the convergence result of the prior Codex architect findings plus the post-fix source/test recheck: the two reported MEDIUM conditions are now covered by the bounded 4,096-repeat implementation, CLI range validation, and passing boundary tests. The raw blocked-round artifact remains available for traceability:

`.omc/artifacts/ask/codex-full-diff-architecture-audit-autotune-coherent-probe-review--2026-08-03T13-39-05-950Z.md`

No code or security lane was re-fired after its PASS result, per the audit-loop requirement.

## Evidence

- `swift build --quiet` passed; only pre-existing Swift Sendable warnings were emitted.
- `swift test --quiet --filter Stage1IteratorTests`: 35 passed.
- `swift test --quiet --filter Stage2HillClimbTests`: 15 passed.
- `swift test --quiet --filter AutotuneCommandTests`: 26 passed.
- `swift test --quiet --filter Autotune`: 261 passed, 5 skipped integration tests.
- `git diff --check` passed.
- No provider-Mac model serve or autotune run was performed.
