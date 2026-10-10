# Round 2 fixes: mlx-swift-lm 3.32.3 / MLX 0.32 (PR #1927)

Round 2 ran the three lanes over the whole diff in `SCOPE.md` again. The
architecture verdict was 0 C / 0 H / 1 M / 2 L. Both fixes are Python and shell
only. The Swift sources and fork pins did not change, and no Studio run was
needed.

## Finding to fix

| # | Lane / severity | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Architecture MEDIUM | `scripts/read_swiftpm_pins.py` checked exact revisions only for fork URLs. An upstream URL at any version passed, so a mixed stack (mlx-swift-lm fork + upstream mlx-swift 0.32.3) was accepted and silently lost the core batch-invariance and trace-cache-erase patches. | `15aa06692`: historical parsing (`read_pins`) is now separate from the production gate (`read_production_pins`). The gate fails closed unless mlx-swift-lm and mlx-swift both resolve from the Augustas11 forks at their reviewed revisions. Package.resolved does not list the MLX core submodule, so the docstring records that the mlx-swift fork revision `ca2f61d2` pins it through its gitlink (`Source/Cmlx/mlx` → `Augustas11/mlx` at `c9196eb7`, checked through the GitHub API). Consumers: `native_mtp_rehearsal_release.runtime_revision()` uses the gate. The CLI uses the gate by default. `check-upstream-throughput-blockers.sh` (the upstream watch) passes `--historical` because it reports the pinned graph and computes `local_pin_matches` itself. No workflow calls the reader. New tests in `scripts/tests/test_upstream_watch.py` (`ProductionForkTupleTests`) cover: full fork tuple accepted, checked-in Package.resolved accepted, LM fork + upstream mlx-swift rejected, upstream LM + mlx-swift fork rejected, fully upstream rejected, wrong revision on either fork rejected, and CLI strict by default with `--historical` opt-in. |
| 2 | Architecture LOW | The record that `check-upstream-throughput-blockers.sh` generates still described temporary forks: `review_due_at`, an upstream-equivalence `removal_trigger`, and #645 as `replacement_tracker`. | `ba19fa0dd`: the three lifecycle fields are removed from the generated record and from the checked-in baseline `beta/throughput-engineering/UPSTREAM_WATCH.json`. They had to come out of the baseline too, because `merge_snapshot` keeps reviewed keys. The record now carries `fork_model: permanent_production_fork_rebased_per_upstream_release` and `patch_retirement_candidates`, which lists #645 as a candidate to retire the matching fork patch during a reviewed rebase. The implementation-signals note says the same. All other watch behavior is unchanged. A test asserts that neither the script nor the baseline has the lifecycle fields. |

## Carried

| Lane / severity | Finding | Reason |
| --- | --- | --- |
| Architecture LOW | Build and signer toolchain profiles are defined in both `scripts/build-release-provenance.py` and `scripts/validate-release-toolchain.py`. | Carried from round 1. This is a release-tooling refactor outside the dependency upgrade. If the copies drift, provenance generation fails loudly; it cannot publish a wrong record. |

## Verification

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_upstream_watch scripts.tests.test_native_mtp_rehearsal_release`: 37 tests, OK
- `bash -n scripts/check-upstream-throughput-blockers.sh`: OK; the embedded Python heredoc compiles
- `bash scripts/test-swift-package-lock.sh`: passed
- `python3 scripts/check_spec_governance.py`: passed
- `python3 scripts/gen_spec_index.py --check`: up to date
- `make test-dist`: stops at `scripts.tests.test_pool_promotion_transition`, which has 10 failures and fails on main too. A full `make -i test-dist` run passes every other step except `scripts/ops/test-runbook-commands.sh` (`FAIL unsafe COORDINATOR_URL rendered`, 7/1). That failure reproduces on canonical main at `fc758f583`, and this branch does not touch `scripts/ops/`. `scripts/ops/test-entrypoints.sh` passed in this run (69/0).
