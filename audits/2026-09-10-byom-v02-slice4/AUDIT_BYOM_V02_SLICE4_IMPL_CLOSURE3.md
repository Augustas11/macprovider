# AUDIT — BYOM v0.2 slice 4 IMPL closure pass 3 (codex, code-reviewer; security and architect at bar)

Diff: `git diff origin/main` at `fd0c88e0` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 1 HIGH / 0 MEDIUM / 0 LOW / 0 INFO |

Closure-2 fix confirmed (secret multiplicity over every entry, strict normalized actors, alias disqualification).

**HIGH — the legacy shared `operator_key` could authenticate as a named actor when a named entry reused its secret** (code). Authentication compared the bearer only against `operator_keys`, so `operator_key = operator_keys.alice = "shared"` made the shared bearer `operator:alice`; availability counted alice. Fix: `authorizedModelAdmissionOperator` refuses a bearer equal to the shared `operator_key` BEFORE any named match (`sharedOperatorKeyBearer`), and `operatorDualControlAvailable` never counts an entry whose secret equals the shared key. Test: shared bearer → `invalid_operator_token`; the remaining single usable actor → `dual_control_unavailable`. (Startup validation of cross-class secret reuse would be a config change outside this slice; the surface fails closed without it.)
