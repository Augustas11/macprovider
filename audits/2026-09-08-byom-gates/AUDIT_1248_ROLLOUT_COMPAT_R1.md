# Audit record R1 — BYOM old-client compat + offer-submit disablement (#1248)

Branch `fix/1248-rollout-compat-disablement`, prompt `AUDIT_1248_ROLLOUT_COMPAT_PROMPT.md`, three codex lanes (`code-reviewer`, `security-reviewer`, `architect`) run 2026-09-08 against the pre-rebase tree.

| Lane | Verdict | Findings |
|---|---|---|
| architect | 0 C / 0 H / 0 M / 2 L / 1 I | LOW: env parser not directly tested; LOW: runbook overstated "no row can satisfy settlement predicate"; INFO: branch behind `origin/main` (#1443). |
| security-reviewer | 0 C / 0 H / 0 M / 1 L / 1 I | LOW: two-dot diff vs `origin/main` showed #1443 install bootout-settle fix as removed (branch-base artifact, not a branch change); INFO: gate ordering (auth → 503 → rate-limit → parse → append) and readback/withdraw invariants hold; govulncheck 0. |
| code-reviewer | 0 C / 2 H / 0 M / 1 L / 0 I | Both HIGHs = the same #1443 branch-base artifact (install.sh settle loop + `ProviderLifecycleState` `uninstalled → rollback_in_progress` guard appear "removed" in a two-dot diff against a main that moved after the branch was cut). LOW: env parser untested. |

## Resolution

- **Branch-base artifact (2 HIGH + 1 LOW + 1 INFO):** rebased onto `origin/main` `3d97de18`; `git diff origin/main` no longer contains any install/lifecycle hunks. Not a change made by this branch.
- **Env parser untested (LOW ×3 lanes):** added `phase4-coordinator/cmd/coordinator/model_admission_submissions_test.go` (`TestModelAdmissionSubmissionsDisabledParsesPolicyValues`: unset/whitespace → enabled, `enabled`/`disabled` case- and padding-insensitive, `off`/`true`/`0` refuse boot and never report disabled).
- **Runbook overstatement (LOW):** `docs/runbooks/byom-disablement-rollback.md` "Design fact" paragraph now states the precise invariant: the predicate is satisfiable by a `settlement_capable` row with a full trusted catalog binding (and a test proves such a row routes/credits under enforce), but providers can only reach `offer_submitted`/`withdrawn` and no v0.1 coordinator path mints that binding.

R2 (post-fix re-run of all three lanes): see `AUDIT_1248_ROLLOUT_COMPAT_R2.md`.
