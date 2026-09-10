# AUDIT — BYOM v0.2 slice 4 IMPL closure pass 4 (codex, code-reviewer; security and architect at bar)

Diff: `git diff origin/main` at `874c657f` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 1 HIGH / 0 MEDIUM / 0 LOW / 0 INFO |

Closure-3 fix confirmed (shared `operator_key` refused first; excluded from availability).

**HIGH — a named operator secret equal to an ACTIVE provider token would let that provider authenticate as the operator** (code). The named matcher consulted only `operator_keys`; provider tokens are a distinct credential class the coordinator can classify (read-only validation, `ValidateTokenReadOnly`). Fix: `authorizedModelAdmissionOperator` refuses a bearer that validates as an active provider token BEFORE the named match (`activeProviderTokenSecret`), and `operatorDualControlAvailable` never counts an entry whose secret is an active provider token. Test: a fake read-only token authority; the provider bearer → `invalid_operator_token`; the remaining single usable actor → `dual_control_unavailable`. (Issuance-time / startup cross-class collision validation would be a config/onboarding change outside this slice; the surface fails closed without it.)
