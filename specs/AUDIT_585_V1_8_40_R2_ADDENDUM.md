# AUDIT ADDENDUM — Issue #585 v1.8.40 — Round 2

Read this together with your lane's base prompt
(`AUDIT_585_V1_8_40_{CODE,SECURITY,ARCHITECT}_PROMPT.md`). The diff under
audit is now `git diff 71eb927a..HEAD`. All R1 findings were fixed; R2 must
(a) verify each fix actually discharges its finding, and (b) audit the fix
code itself for new issues. Same severity scale, same attribution rule, same
`VERDICT:` line.

## R1 findings and the implemented fixes

| R1 | Fix |
|---|---|
| CODE M1 — writer/predecessor validated independently | Edge-specific `(predecessor, target, writer)` guard in `ProviderLifecycleState.swift` scoped to `loading_model` exits: `degraded_serving` only for `serve`, `paused_by_operator` only for `operator_command`. Negative + positive tests added. |
| SEC H1 — 1.8.40 advertisement re-arms legacy binary-only updater | Server-side capability gate `gatedRecommendedBinaryVersion` in `phase4-coordinator/internal/ws/server.go`: hellos without `compatibility_set_id` receive no recommendation (v1 hello_ack + v2 auth_response both gated; /healthz mirror deliberately ungated — v1.8.30 never consumes healthz for updates, verified against the v1.8.30 tag). Go tests added; yaml comments updated, values unchanged. |
| SEC M2 — snapshot follows symlinks / unsafe metadata | New `stage_lifecycle_snapshot()` in install.sh: store-lock held, parent dir owned non-symlink 0700, state file owned non-symlink regular 0600 nlink==1 <=1MB, O_NOFOLLOW read with dev/ino re-check, umask-077 O_EXCL 0600 staging, post-copy source re-verify; fail-closed pre-mutation. Fixtures corrected to 0700/0600; four negative tests. |
| SEC M3 — restore declared verified without durability | `restore_lifecycle_state()` in recover.sh: atomic O_EXCL temp + fsync + os.replace, post-swap byte/type/mode verification (or verified absence), fsync of file + parent dir before success; `RECOVERY_LIFECYCLE_FAULT` fault-injection tests. |
| ARCH A-01 — raw restore can fence restored CLI; pause loss | Snapshot AND restore run under the store's `.state-v1.json.lock` (fcntl, 10s bounded, fail-closed). Restore re-reads live record: durable operator pause preserved; updater-written snapshots translated to an installer-owned `rollback_in_progress` record (fresh operation id, sequence advanced past snapshot+live, store-valid schema) so serve can always leave it. Full-schema fixtures; five new tests incl. lock contention. |
| ARCH A-02 — candidate writes incumbent's lifecycle file | Candidate-scoped store `lifecycle/candidate-state-v1.json` (own lock) routed at the single store construction point in serve; transition graph still enforced in candidate mode. Acceptance evidence: real-model integration test re-run with byte-identical `state-v1.json` before/after; candidate file contains the legal terminal edge. |
| ARCH A-03 — closure precedes physical evidence | `audits/2026-07-15/RELEASE_GATE_V1_8_40.md` created as the ACTIVE gate: three separately tracked gates (implementation / candidate / rollout), 12-point candidate proof checklist (now covering candidate store + legacy gate), evidence ledger. Entry 161 re-worded: closure explicitly gated on physical proof. |
| ARCH A-04 — Entry 160 standing per-release authority | Entry 160 re-scoped to a cohort-bound recovery exception with expiry (both cohort Macs recovered) and "future re-arm requires a new decision entry with release-specific proof"; source comment on `legacyBootstrapTarget` matches. |
| ARCH A-05 — lease not reconciled | `reconcile_lifecycle_lease()` in recover.sh under `.lease.json.lock`: removes lease owned by the rolled-back operation or a dead PID, preserves live foreign owner, never touches lock files; final state/lease pair asserted. Tests added. |
| ARCH A-06 (LOW) | Three-class transaction boundary documented in the release gate doc. |
| ARCH A-07 (LOW) | Handoff marked HISTORICAL SNAPSHOT, superseded by the release gate doc. |

## Known documented seams (evaluate, do not assume)

1. The translated installer-owned record is constructed to match
   `ProviderLifecycleState.validate()` and the fencing switch, but no test
   feeds the exact emitted JSON through the actual Swift store (cross-lane
   seam — rate it if you judge it material).
2. `candidate-state-v1.json` persists after candidate runs (not
   garbage-collected between runs; uninstall removes it).

## Verification state at commit time

Swift 1,361/0 (exit 0), Go build+test 0/0, Malibu app 171/0 (exit 0),
`make test-dist` exit 0, real-model integration test PASS with byte-identical
incumbent lifecycle file, version alignment at 1.8.40, shellcheck clean on
new installer code, mutation-tested regression tests (translation and symlink
guards each proven load-bearing).
