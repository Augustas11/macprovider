=================== code
## Raw output

```text
CODE gate **FAIL: 2 MEDIUM, 1 LOW**. Reviewed the complete `origin/main...HEAD` diff at `2122af1b6`, on `codex/issue-1914-version-policy-rebase`.

Round-1 dispositions:

| Finding | Status | Reason |
|---|---|---|
| CODE: absent health mode bypasses floor disagreement | **NO LONGER APPLICABLE** | Floor mode removed; absent mode now means `legacy_exact`. |
| CODE: disagreement still permits admission mutation | **NO LONGER APPLICABLE** | Allowlist/migration mutations removed; explicit policy mismatch now blocks subsequent Pearl mutations. |
| CODE: Python accepts numeric overflow | **FIXED** | Both helpers enforce int64 bounds; overflow regressions added. |
| SECURITY: failed reconnect can strand fleet during migration | **NO LONGER APPLICABLE** | Migration and historical-version preservation removed. |
| SECURITY: self-reported identities remain forgeable | **NOT FIXED** | Pre-existing, explicitly acknowledged metadata-policy limitation; INFO only. |
| ARCHITECTURE: excluded releases constrain migration | **NO LONGER APPLICABLE** | Migration removed. |
| ARCHITECTURE: registrations prove admission against stale policy | **FIXED** for the original scenario | Target and exact revocations are compared. Pending-edit recovery introduces the related gap below. |

New findings:

- **MEDIUM — A version floor still overrides open repository admission.** [server.go:3378](/Users/augstar/macprovider-1919/phase4-coordinator/internal/ws/server.go:3378), [coordinator.yaml:535](/Users/augstar/macprovider-1919/phase4-coordinator/dist/coordinator.yaml:535). A well-formed, same-repository, non-revoked identity such as `v1.8.1` with matching `binary_version` passes the new compatibility check, then gets disconnected by `required_binary_version: "1.8.33"`. This floor is **pre-existing**, but retaining it contradicts the new no-floor contract. **Fix:** bypass the global binary floor for configured repository admission; reconcile configuration/documentation and add a handshake regression with a non-revoked version below the configured floor.

- **MEDIUM — Pending-edit recovery suppresses arbitrary live-policy disagreement.** [release-registrations.py:416](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:416), [cli-release.sh:517](/Users/augstar/macprovider-1919/scripts/ops/cli-release.sh:517). If disk differs from boot—or the boot digest is unreadable—every repository-mode mismatch is erased. A live candidate revocation absent from stale disk config consequently becomes `compat_rejection=""`; the train can select a restart that removes that revocation. Even a repository-mode health response missing its policy fields loses its mismatch. Reproduced both verdicts locally. **Fix:** retain malformed-policy and arbitrary-drift blockers; authorize recovery only for a recorded pending train mutation, preserving unrelated live revocations. Add these cases alongside the legitimate interrupted-bump test.

- **LOW — Python identity parsing accepts a trailing newline.** [release-registrations.py:341](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:341), [pearl-cli-config.py:76](/Users/augstar/macprovider-1919/scripts/ops/lib/pearl-cli-config.py:76). Python’s `$` anchor permits a final newline, so `compat_repo(valid_id + "\n")` returns the repository while Go rejects that identity. The registrations helper can falsely prove malformed-ID admission. **Fix:** use `fullmatch()` in both helpers and add newline parity tests.

Validation: **20 targeted Python tests passed**; offline checker confirmed **42 seed IDs**; shell syntax and diff-whitespace checks passed. Go/Swift and broader suites were not run. No checkout edits or live-host contact.

C/H/M/L = 0/0/2/1
=================== security
## Raw output

```text
Security gate: **FAIL — one MEDIUM, one LOW.** Reviewed `origin/main...HEAD` at `2122af1b6`; checkout is actually on `codex/issue-1914-version-policy-rebase`. No checkout edits or live-host contact.

Round-1 disposition:

| Finding | Status | Reason |
|---|---|---|
| Code: absent health mode bypass | FIXED | Missing mode now uses legacy exact admission. |
| Code: disagreement permits mutation | NOT FIXED | A different mismatch bypass remains, described below. |
| Code: Python numeric overflow | FIXED | Both admission helpers enforce int64 bounds. |
| Security: migration strands providers | NO LONGER APPLICABLE | Floor migration and its connection-event query were removed. |
| Security: forgeable reported identities | NOT FIXED | Pre-existing, explicitly accepted metadata-policy limitation. |
| Architecture: migration protects excluded releases | NO LONGER APPLICABLE | Floor migration was removed. |
| Architecture: stale-policy registration proof | NOT FIXED | Full policy comparison exists, but digest disagreement suppresses it. |

- **MEDIUM — An unapplied disk config bypasses the live-revocation guard.** [release-registrations.py:416](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:416), [cli-release.sh:517](/Users/augstar/macprovider-1919/scripts/ops/cli-release.sh:517).  
  **Failure scenario:** The running policy revokes build X, but disk config omits X and differs from the boot digest—for example, after a SIGHUP revocation followed by a stale config restore or pending edit. `live_policy()` detects disagreement, then `evaluate()` clears it because `config_applied=false`. The train can select `_pearl-config` recovery or `revocation_seed`, restart from disk, and remove X’s live revocation. The helper validates configuration syntax and requested postconditions, but does not preserve all existing live revocations. This bypass is introduced by the diff.  
  **Evidence:** Local reproduction returned an explicit raw revocation mismatch, followed by `policy_mismatch=""`, `compat_rejection=""`, and a true recovery-restart condition.  
  **Fix:** Preserve policy disagreement regardless of boot-digest equality. Permit recovery only when the full live compatibility policy agrees with disk; recheck under the mutation locks before replacing config or restarting. Add regression coverage for differing digests with a live-only revocation.

- **LOW — Seed generation does not verify signed release provenance.** [legacy-compatibility-revocations.py:58](/Users/augstar/macprovider-1919/scripts/legacy-compatibility-revocations.py:58).  
  **Failure scenario:** The generator trusts the JSON field named `signed` and compares it against an unverified remote tag. Someone able to replace release assets and move tags, without the release signing key, can supply matching unsigned metadata. Regeneration then revokes the replacement identity while omitting the original published identity. Offline `check()` proves internal consistency, not authenticity or completeness. This is new; it does **not** establish that the current 42 entries are wrong.  
  **Evidence:** With external calls mocked, generation accepted an envelope containing no signatures.  
  **Fix:** Verify manifests with the existing compatibility-manifest validator and trusted release key; verify tag provenance against approved signers before deriving seed identities.

- **INFO — Reported identities remain forgeable (pre-existing).** [SPEC-002-coordinator.md:5194](/Users/augstar/macprovider-1919/specs/SPEC-002-coordinator.md:5194). A modified provider can change its SHA or consistently change both reported versions to evade an exact revocation. Canonical formatting rejects leading-zero aliases, overflow and foreign repositories, but cannot authenticate binary provenance. No additional fix is required under the operator-approved metadata policy.

No additional routing bypass found for sessions retaining the exact revoked ID: update-only admission remains excluded by routing predicates, reload fencing survives heartbeat state changes, and repository drift is refused before publication.

Validation: **20 targeted Python tests passed**, plus the two isolated reproductions above. Go/Swift tests were not run.

C/H/M/L = 0/0/1/1
=================== architecture
## Raw output

```text
Architecture gate: **FAIL — 3 MEDIUM, 1 LOW.** Reviewed `origin/main...HEAD` at `2122af1b6`, in the clean checkout on `codex/issue-1914-version-policy-rebase`.

Round-1 dispositions:

| Finding | Status |
|---|---|
| Code: absent health mode bypasses comparison | **FIXED** — absent mode now selects legacy exact admission. |
| Code: policy disagreement permits mutation | **NOT FIXED** — normal disagreement blocks, but the digest exception below still permits mutation. |
| Code: Python numeric overflow | **FIXED** — both helpers enforce int64 bounds. |
| Security: rejected reconnect corrupts migration preservation | **NO LONGER APPLICABLE** — migration and historical-usage checks were removed. |
| Security INFO: self-reported identity is forgeable | **NOT FIXED** — acknowledged, pre-existing limitation; not a gate failure under this metadata policy. |
| Architecture: excluded releases constrain migration | **NO LONGER APPLICABLE** — floor migration was removed. |
| Architecture: registrations use stale policy | **NOT FIXED** — full policy comparison was added, but disagreement can still be suppressed. |

1. **MEDIUM — Digest disagreement disables the live-policy safety gate.**  
   [release-registrations.py:416](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:416), [cli-release.sh:446](/Users/augstar/macprovider-1919/scripts/ops/cli-release.sh:446).  
   **Scenario:** The running coordinator revokes candidate X, while disk config omits that revocation and differs from boot bytes. `live_policy()` detects the mismatch, but `evaluate()` clears it because `config_applied=false`. The train can then select seed application, privacy setup, or the pending-config restart, replacing the running policy and erasing X’s revocation. This violates R004’s requirement that any policy difference block every Pearl-mutating step. In-memory reproduction confirmed `policy_mismatch=""` and `compat_rejection=""` despite the live revocation.  
   **Fix:** Preserve policy mismatches regardless of boot digests. Recover unrelated pending config only when its compatibility policy agrees with the live snapshot. Add combined digest/policy-disagreement coverage.

2. **MEDIUM — The global admission floor survives the “no floor” rewrite.**  
   [server.go:3378](/Users/augstar/macprovider-1919/phase4-coordinator/internal/ws/server.go:3378), [coordinator.yaml:535](/Users/augstar/macprovider-1919/phase4-coordinator/dist/coordinator.yaml:535).  
   **Scenario:** With the new coordinator and an old config containing `required_binary_version`, a well-formed, matching-repository, nonrevoked identity below that floor is disconnected with `version_unsupported`, before receiving its recommendation. Config validation still accepts this combination, and the distributed config retains floor `1.8.33`. The floor is **pre-existing**, but retaining its enforcement conflicts with the new R004 contract.  
   **Fix:** Ignore the global release-admission floor under repository policy, retaining legacy unconfigured behavior if required; deprecate its configured-policy documentation and add an old-config regression test. Separate per-model capability requirements need not be removed.

3. **MEDIUM — Legacy-runtime admission can advance into an impossible recommendation step.**  
   [release-registrations.py:426](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:426), [pearl-cli-config.py:327](/Users/augstar/macprovider-1919/scripts/ops/lib/pearl-cli-config.py:327).  
   **Scenario:** An old coordinator already lists the candidate, so the new train proves admission and advances. Recommendation application then unconditionally requires `compatibility_policy_target_id`, which that runtime never exposes. Even a successful restart and correct recommendation fail the postcondition, triggering restoration and another restart. In-memory reproduction confirmed the refusal. This is introduced by the diff.  
   **Fix:** Gate recommendation mutation on repository-runtime availability and direct the train to the runtime release before attempting the edit.

4. **LOW — Operational instructions still prescribe ignored allowlist/bridge semantics.**  
   [entry-610-first-hop-recovery.md:32](/Users/augstar/macprovider-1919/ops/runbooks/entry-610-first-hop-recovery.md:32), [privacy-class-beta-operations.md:103](/Users/augstar/macprovider-1919/docs/runbooks/privacy-class-beta-operations.md:103).  
   **Scenario:** The recovery runbook promises that `first_hop_bridge_ids` prevents buyer routing, although the new runtime ignores it; privacy setup documentation still promises an `accepted_ids` edit. These instructions are **pre-existing**, newly invalidated by this change. Trusted-pool instructions also require obsolete allowlist evidence.  
   **Fix:** Rewrite active procedures around repository admission and exact revocations; mark historical bridge guidance superseded.

No direct `accepted_ids` admission dependency was found in the installer, Malibu.app, gateway, or stats. Gateway and stats consume coordinator routing eligibility; retaining `update_bridge` as the revoked-session exclusion preserves that behavior. Seed selection is correctly restricted to repository-mode runtimes.

Validation: seven targeted Python tests passed, including offline seed consistency for 42 identities; two in-memory reproductions confirmed findings 1 and 3. No Go/Swift builds, file edits, or live-host contact.

C/H/M/L = 0/0/3/1
