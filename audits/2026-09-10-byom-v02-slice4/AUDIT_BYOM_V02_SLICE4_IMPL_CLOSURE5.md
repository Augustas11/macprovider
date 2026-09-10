# AUDIT — BYOM v0.2 slice 4 IMPL closure pass 5 (codex, code-reviewer; security and architect at bar)

Diff: `git diff origin/main` at `29fe3192` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 1 HIGH / 0 MEDIUM / 0 LOW / 0 INFO |

Closure-4 fix confirmed for the classified case.

**HIGH — provider-token classification failed open when unavailable** (code). `activeProviderTokenSecret` returned "not a provider token" both for a genuine negative and for an authority without read-only validation, a backend error or a timeout. Fix: classification is tri-state via `secretIsNotAProviderToken` — with a token authority configured it must POSITIVELY succeed; an authority without `ValidateTokenReadOnly`, an error or a timeout is unknown and fails closed (bearer refused; entry not counted toward dual control); without a token authority there is no provider credential class to confuse. Tests: a read-only-less authority and an erroring authority both → `invalid_operator_token` and `dual_control_unavailable`.
