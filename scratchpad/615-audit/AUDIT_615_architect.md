# Architect Audit — Partial #615 Exception Enforcement Scaffolding

**Audit target:** `fix/615-exception-enforcement` at `f3d71718a3032e045130684c815f54c3c5a16dc3`  
**Base:** `origin/main`  
**Architectural status:** **BLOCK**  
**Merge gate:** **FAIL** — the required `0 CRITICAL / 0 HIGH / 0 MEDIUM` gate is not met.

## Severity counts

| Severity | Count |
| --- | ---: |
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 5 |
| LOW | 1 |
| INFO | 3 |

## Executive verdict

This is real scaffolding rather than docs-only theater: the checker runs, the deploy gate is reached through the existing deploy-config harness, the promotion workflow contains a fail-closed check, and the targeted tests pass. The current committed inventory behaves default-safe: validation and deploy pass with eight warnings, while promotion fails with eight errors.

The slice is nevertheless not merge-ready under the requested audit gate. The promotion policy ignores the register's explicit `blocks_stable_promotion` decision, scope-widening enforcement is a prose keyword heuristic, the runbook labels several still-open #615 guarantees as landed, the documented anti-resurrection command does not parse, and the dependency-free validator accepts documents rejected by the canonical schema. Partial completion is acceptable, but the runbook must describe partial guarantees accurately and the enforcement surfaces that are claimed as landed must be executable and fail-closed.

## MEDIUM findings

### M1. Stable promotion ignores `blocks_stable_promotion`

**Evidence**

- `ops/runbooks/production-exception-register.md:43-46` defines `blocks_stable_promotion: true` as the marker for an active exception that must block #615/#613/#584/#585-related promotion.
- `scripts/production_exceptions.py:276-281` validates only that the field is boolean.
- `scripts/production_exceptions.py:581-593` promotes only `status_expired`, `unbounded_active`, and `expiry_soon`; it never reads the blocking flag.
- All nine committed exception rows currently set `blocks_stable_promotion: true`.
- Adversarial probe: a valid active row with a future bounded expiry and `blocks_stable_promotion=true` produced `blocking_flag_promote_errors=[]`.
- `scripts/tests/test_production_exceptions.py:133-148` covers expired and unbounded rows, but not a bounded active blocking row.

**Risk**

The current inventory still blocks promotion for other reasons, so there is no immediate fail-open release. Once operators replace unknown expiries with bounded approvals, however, promotion can pass even though the register explicitly says the exception blocks stable promotion. That makes a governance field informational rather than enforced.

**Required correction**

In promote mode, reject active/planned rows whose `blocks_stable_promotion` is true. Add a regression test proving a future-bounded blocking row fails and an explicitly non-blocking bounded row can pass. Preserve the current default-safe deploy behavior unless the policy is deliberately changed.

### M2. Scope-widening enforcement is trivially bypassed by equivalent wording

**Evidence**

- `scripts/production_exceptions.py:158-181` rejects only prose containing `all providers` without `must not widen`, or `arbitrary` without a small set of negations.
- The only widening test, `scripts/tests/test_production_exceptions.py:117-122`, uses exactly `all providers in production without bounds`.
- Adversarial probes for `scope="global production fleet"`, `scope="*"`, and `scope="every production provider"` all produced zero validation errors.
- The canonical #615 acceptance criteria explicitly require tests for scope widening, while `ops/runbooks/production-exception-register.md:48-50` and `:216` describe scope-mismatch rejection as landed.

**Risk**

The gate can be satisfied by rephrasing a globally widened scope. This is not reliable enforcement of the acceptance criterion and makes the runbook's claim stronger than the implementation.

**Required correction**

Represent enforceable scope bounds structurally (for example, a scope kind plus explicit provider/cohort identifiers and a boundedness marker), or constrain accepted scope forms to a reviewed machine-checkable vocabulary. Add adversarial synonyms/wildcards to the test matrix. Until then, mark semantic scope-widening enforcement as partial/manual review in the runbook.

### M3. The runbook marks still-open #615 guarantees as landed

**Evidence**

- The canonical #615 required implementation includes rejection of **unregistered** exceptions, prevention of silent self-extension, and authoritative sync that cannot resurrect removed authority.
- `scripts/production_exceptions.py:241-383` validates only rows already present in the committed register; there is no reconciliation against live Pearl/config/DB authority surfaces, so an unregistered live exception is invisible.
- Gate commands call `validate_register` without `previous_doc` (`scripts/production_exceptions.py:654-666`), so an expiry can be moved forward without any comparison to prior reviewed state. `previous_doc` is used only by direct callers/tests for resurrection.
- Repository search found no sync, restore, or rollback path invoking `sync-check`; it is a standalone operator command.
- Nevertheless, `ops/runbooks/production-exception-register.md:216-218` labels deploy/promotion rejection, expiry/self-extension, and anti-resurrection as “Landed.” The banner at `:7-15` says the inventory is release-gated without stating that only registered-file state is visible.

**Risk**

Operators can reasonably infer that #615 items 4-6 are enforced end-to-end when this slice provides register-local gates and a manual simulation tool. The partial implementation is acceptable; the inaccurate completion boundary is not.

**Required correction**

Change the status table to distinguish “registered-row enforcement landed” from these open guarantees: discovery/reconciliation of unregistered live exceptions, reviewed non-self-extending expiry transitions, and integration into authoritative sync/restore/rollback paths. Implement those later or keep them explicitly open.

### M4. The documented anti-resurrection command is unusable and its CLI path is untested

**Evidence**

- The runbook places the global `--tombstones` option after the `sync-check` subcommand at `ops/runbooks/production-exception-register.md:142-147`.
- `scripts/production_exceptions.py:719-729` defines `--tombstones` only on the top-level parser; `scripts/production_exceptions.py:757-771` does not add it to `sync-check`.
- Exact runbook repro exited `2` with `error: unrecognized arguments: --tombstones ...`.
- `scripts/tests/test_production_exceptions.py:150-167` tests the internal simulation function, not the CLI command. `scripts/test-production-exceptions.sh:42-68` exercises deploy/promote and grep-based wiring, but never executes `sync-check`.
- The canonical #615 acceptance list also calls for rollback-failure coverage; no test in this slice exercises a failing operational rollback/sync invocation.

**Risk**

The only documented operator procedure for the new anti-resurrection scaffold fails before performing a check. Unit coverage therefore proves the inner model, not the operator surface claimed by the runbook.

**Required correction**

Either move `--tombstones` before `sync-check` in the runbook or expose it on the subparser. Add an end-to-end CLI test for both clean and resurrecting stale inputs, plus an explicit failure-path test. Keep authoritative rollback-failure acceptance open until an actual rollback integration exists.

### M5. The CI validator is not equivalent to the schema it claims to enforce

**Evidence**

- `ops/exceptions/production-exceptions.schema.json:6`, `:75`, and `:201` disallow additional properties; `:50-53` requires valid date-time values; `:172-176` requires non-empty string evidence.
- The dependency-free validator checks timestamp shape but does not parse `updated_at`/`created_at`, does not reject extra properties, and checks only that `evidence` is a list (`scripts/production_exceptions.py:220-283`).
- An adversarial document containing `updated_at="2026-99-99T99:99:99Z"`, an unexpected top-level property, and `evidence=[123, ""]` produced `schema_drift_validation_errors=[]`.
- The runbook says required fields are enforced “by ... schema and ... checker” (`ops/runbooks/production-exception-register.md:35-41`) and that dependency-free structural validation is always on while CI uses it (`:63-65`). The module docstring also says it validates against the committed schema's structural rules.

**Risk**

CI can approve a register that violates the canonical schema, despite the deploy gate's documented promise to hard-fail malformed inventory. This creates two competing definitions of valid production authority.

**Required correction**

Make CI enforce the canonical schema, or implement the schema's relevant constraints exactly in the stdlib checker. Add negative tests for impossible timestamps, additional properties, and invalid evidence/open-question element types.

## LOW findings

### L1. Promotion's approaching-expiry behavior is stricter than the stable-promotion summary

`scripts/production_exceptions.py:586-592` upgrades `expiry_soon` to an error for promote mode. The detailed enforced-deploy text implies all warn classes can be promoted, but `ops/runbooks/production-exception-register.md:123-133` and the shared audit context summarize fail-closed promotion as expired/unbounded plus structural errors and omit the 72-hour block. This is fail-safe, not unsafe, but operators may see an unexpected promotion refusal. State the 72-hour promotion block explicitly.

## INFO observations

### I1. Default-safe deploy versus fail-closed promotion works on the committed inventory

Fresh current-clock probes returned `validate_rc=0`, `deploy_rc=0`, and `promote_rc=1`. Deploy reported eight warnings; promotion converted the seven unbounded active rows and one expired row into eight errors. This matches the intended partial rollout posture.

### I2. #608 catalog bridges were preserved

`ops/exceptions/production-exceptions.json` has no branch diff from `origin/main`, and the existing `exc-catalog-compatibility-bridges` row remains active. The slice does not clear the catalog bridge or claim #608 completion.

### I3. No Pearl mutation was introduced or performed by this lane

The diff adds local validation/reporting, CI/promotion gating, deploy preflight wiring, tombstone data, tests, and runbook text. It does not change coordinator/gateway runtime logic or mutate live Pearl state. This audit used only repository inspection and local tests; no Pearl SSH or production mutation command was run.

## Verification evidence

- `git rev-parse HEAD` => `f3d71718a3032e045130684c815f54c3c5a16dc3`
- `git diff --check origin/main...HEAD` => clean
- `bash scripts/test-production-exceptions.sh` => PASS; 14 unit tests passed
- `bash scripts/test-acceptance-promotion.sh` => PASS
- `bash phase4-coordinator/dist/test/check_deploy_config_test.sh` => PASS; 61 assertions, 0 failures
- Current-clock validator/deploy/promote probes => `0 / 0 / 1`, as intended for the present inventory
- Exact runbook `sync-check` command => FAIL (`argparse` exit 2)
- Adversarial probes confirmed M1, M2, and M5

## Gate conclusion

**CRITICAL 0 / HIGH 0 / MEDIUM 5 / LOW 1 / INFO 3 — BLOCK.**

The slice demonstrates substantive, tested scaffolding and preserves both the #608 bridge and Pearl's live state. It must not be represented as merge-ready under the repository audit contract until all five MEDIUM findings are corrected and re-audited to zero.
