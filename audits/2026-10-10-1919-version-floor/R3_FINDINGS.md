=================== code
## Raw output

```text
| Round-2 CODE finding | Disposition |
|---|---|
| MEDIUM: version floor disconnects repository-admitted releases | **FIXED** — [server.go:3378](/Users/augstar/macprovider-1919/phase4-coordinator/internal/ws/server.go:3378) connects below-required releases update-only with recommendation; fresh credential bootstrap retains its floor. Regression added. |
| MEDIUM: pending recovery suppresses arbitrary policy disagreement | **FIXED** — [release-registrations.py:393](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:393) rejects malformed policy and unrelated drift, preserves every live revocation, and tolerates only candidate-target/seed additions. Candidate revocation is judged against live policy. |
| LOW: Python identity parsing accepts trailing newline | **FIXED** — both helpers use `fullmatch()` with newline regressions. |

**No new CODE-lane findings. Gate PASS: 0 CRITICAL/HIGH/MEDIUM.**

Reviewed the complete `origin/main...HEAD` squash diff at `cf84c38dc0124c9923e31709faf77edf1d51be2b`. Actual checkout branch is `codex/issue-1914-version-policy-rebase`.

Validation: **23 targeted Python tests passed**; offline seed checker confirmed **42 IDs**; shell syntax and diff-whitespace checks passed. Go/Swift and broader ops tests were inspected but not executed under the host resource boundary. Checkout remains clean; no edits or live-host contact.

C/H/M/L = 0/0/0/0
=================== security
## Raw output

```text
| Round-2 security finding | Round-3 disposition |
|---|---|
| MEDIUM: unapplied disk config bypasses live revocation | **FIXED** — pending recovery preserves every live revocation and permits only candidate-target changes or seed additions. Malformed health policy fails closed. |
| LOW: seed generation lacks signed provenance verification | **NOT FIXED** — retained below. |
| INFO: reported release identities remain forgeable | **NOT FIXED** — pre-existing, explicitly accepted metadata-policy limitation. |

**Security gate: PASS — zero CRITICAL/HIGH/MEDIUM findings.** Reviewed `origin/main...HEAD` at `cf84c38dc`; actual checkout branch is `codex/issue-1914-version-policy-rebase`.

- **LOW — Seed generator trusts unsigned release metadata.** [legacy-compatibility-revocations.py:58](/Users/augstar/macprovider-1919/scripts/legacy-compatibility-revocations.py:58). An attacker able to replace release assets and move tags, without possessing the signing key, can substitute matching metadata. Regeneration then revokes the substituted identity while omitting the original. A fully mocked reproduction accepted an envelope with no signatures. **Fix:** verify compatibility-manifest signatures with the trusted release key and verify tag provenance against approved signers. This is retained from round 2; it does not establish that the current 42 IDs are incorrect.

- **INFO — Provider-reported identities remain spoofable (pre-existing).** [SPEC-002-coordinator.md:5200](/Users/augstar/macprovider-1919/specs/SPEC-002-coordinator.md:5200). A modified provider can report the target repository, another SHA, or consistently change both version fields to evade exact revocation. Canonical formatting blocks alias tricks but cannot authenticate executable provenance. **Fix:** cryptographically bind identity to the executable if that stronger guarantee becomes required; no additional fix is required under the accepted metadata policy.

**No new issues found.** Exact revoked identities connect update-only and remain excluded by routing predicates. Reload fencing survives heartbeat changes, acknowledgement release rechecks policy, and repository drift is refused before publication.

Validation: **23 targeted Python tests passed**; offline seed check confirmed **42 consistent IDs**; shell syntax and diff-whitespace checks passed. Go/Swift tests were not run. No checkout edits or live-host contact.

C/H/M/L = 0/0/0/1
=================== architecture
## Raw output

```text
Architecture gate **FAIL — 1 MEDIUM, 1 LOW**. Reviewed `origin/main...HEAD` at `cf84c38dc`; actual checkout branch is `codex/issue-1914-version-policy-rebase`.

Round-2 architecture findings:

| Finding | Disposition |
|---|---|
| Digest disagreement disables live-policy safety | **FIXED** — pending recovery preserves every live revocation, permits only candidate-target/seed additions, and judges admission against live policy. |
| Global floor disconnects admitted releases | **FIXED** — configured-policy releases below the requirement connect update-only; bootstrap/unconfigured exceptions are documented. |
| Legacy runtime reaches impossible recommendation mutation | **FIXED** — recommendation mutation now requires repository mode. |
| Operational instructions retain allowlist/bridge semantics | **NOT FIXED completely** — first-hop and privacy procedures were corrected; active trusted-pool instructions remain obsolete. |

- **MEDIUM — Seed ordering deadlocks when the incumbent target belongs to the seed.**  
  [cli-release.sh:462](/Users/augstar/macprovider-1919/scripts/ops/cli-release.sh:462), [pearl-cli-config.py:162](/Users/augstar/macprovider-1919/scripts/ops/lib/pearl-cli-config.py:162).  
  **Scenario:** A new coordinator boots an otherwise valid old config targeting published `v1.8.123`. Repository mode immediately selects `revocation_seed`, before recommendation migration. `_revoke-seed` passes all 42 identities, including that target; the helper correctly refuses to revoke it. Every retry selects the same failing step, leaving the later recommendation bump unreachable. Offline reproduction returned `refusing to revoke the target ...v1.8.123...`. This is introduced by the diff.  
  **Fix:** Handle seeded incumbent targets explicitly: apply other revocations, advance the target through the normal signed-release gates, then apply the deferred revocation. Add an old-target ordering regression.

- **LOW — Active trusted-pool instructions still require ignored allowlist edits.**  
  [trusted-pool-m1-activation-plan.md:440](/Users/augstar/macprovider-1919/docs/runbooks/trusted-pool-m1-activation-plan.md:440), [trusted-pool-m1-activation-plan.md:232](/Users/augstar/macprovider-1919/docs/runbooks/trusted-pool-m1-activation-plan.md:232).  
  **Scenario:** Operators are instructed to add candidates to `accepted_ids`, restart, and use membership as acceptance evidence. Repository-mode admission ignores that field. **Pre-existing instructions, newly invalidated; carried from round 2.**  
  **Fix:** Replace these steps with live repository-policy/revocation checks and signed candidate identity evidence; update their dependent checklist entries.

No direct `accepted_ids` admission dependency found in installer, Malibu.app, gateway, or stats. Legacy train fallback deliberately retains exact-list comparison; gateway/pool routing continues excluding `update_bridge`.

Validation: **23 targeted Python tests passed**, including offline 42-ID seed consistency; diff whitespace check passed. Go/Swift suites were not run. Checkout remained clean; no edits or live-host contact.

C/H/M/L = 0/0/1/1
