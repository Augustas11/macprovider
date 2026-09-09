# Independent review — BYOM v0.2 slice 2a (PR #1461), after the four-round codex stop

**Branch:** `feat/byom-v02-slice2a-artifact-feed-generator` at `0292b369` (R4 fixes included)
**Date:** 2026-09-09
**Method:** three cold-context reviewer lanes (code, security, architecture) with a
neutral prompt — no R1–R4 narrative — over the full `git diff origin/main...HEAD`,
each running the existing suites. Used in place of `/code-review ultra` (usage
credits exhausted). The R1–R4 records in this directory were given to the lanes
as CLAIMS to verify, not as settled findings.

## Verdicts

| Lane | Verdict |
|---|---|
| code | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 3 LOW / 3 INFO — 34 targeted mutations, 31 caught |
| security | **0 CRITICAL / 0 HIGH / 0 MEDIUM / 2 LOW / 3 INFO — merge bar met** |
| architecture | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 3 LOW / 1 INFO |

No behavioural defect was found; the committed release is byte-identical to
`origin/main`'s and every reachable path fails closed. Every item below is
resolved in the commit that adds this record unless marked deferred.

## Resolutions

- **MEDIUM (architecture) — §3.3.1 rule 8 was a test over today's seed data, not a generation gate.** `require_rate_card_unchanged_at_activation` now fails `generate --activate-artifact-feed` unless the new rate-card projection `version` (rows + release globals + usd) equals the ledger's latest recorded release's; the activation release is the first at which class expansion can change a row and §3.7.8 makes it irreversible. Test: `test_activation_refuses_a_rate_card_that_differs_from_the_preceding_release`.
- **MEDIUM (code) — the rule-9 parity gate's call sites in `generate` and `verify` were not pinned.** The hermetic harness now patches `COORDINATOR_YAML_PATH` to a throwaway copy; `test_generate_and_verify_each_enforce_coordinator_parity` drifts `provider_share` and requires both call sites to raise.
- **MEDIUM (architecture) / LOW (security) — `status` understated what must land before activation.** The "coordinator serving" entry now names the buyer routes, feed loader/validator, config keys, and deploy paths besides nginx; a "scheduled renewal" entry names `AUTOTUNE_PREVIOUS_RELEASE_DIR` for the signed renewal workflow; a `DEFERRED_REQUIREMENTS` block names AC-CAT-21 (intake-decision schema, SPEC-023-R006). Runbook table updated to match. (Slice 2b lands the serving surface and the live gate.)
- **LOW (security) — normalized-key invariant only on the authoring source.** `validate_rate_card` now enforces it on published bytes too, so `verify-directory` and the parity gate apply it to bytes they did not generate. Test: `test_published_rate_card_rejects_an_unnormalized_row_key`.
- **LOW (code) — post-activation emitter deadlock.** `emit-coordinator-rate-card --from-source` projects the authored classes with a stderr NOTICE; runbook paragraph added. Test: `test_emit_from_source_projects_authored_classes_post_activation`.
- **LOW (code) — tab rejection fired outside the rewards block.** Scoped to the block.
- **LOW (code) — runbook row 11 was split from the disablement matrix by a blank line.** Joined.
- **INFO (code) — `verify`'s catalog-directory artifact drift check unpinned.** Assertion tightened to name `ARTIFACT_FEED_PATH`.
- **INFO (security) — Pearl under-lock mirror pinned partially.** Shell test now requires the full release-field tuple.
- **INFO (code) — parity is a statement about the committed config, not Pearl overlays.** Runbook clause added.
- **INFO (code + architecture) — `normalize_model_key` Unicode scope.** Docstring scopes equivalence to `MODEL_KEY`-conforming input.
- **Deferred, documented:** SPEC-023 §3.7 naming `autotune-artifacts-source.json` (next SPEC revision; runbook notes it); shared Go/Python/Swift conformance fixtures for the artifact-feed schema (slice 2c, where the third consumer lands); INFO on rate-card signer equality with the candidate feed (pre-existing, raised to the SPEC-023 owner in the PR body).

## Validation after the fixes

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_catalog_artifact_feed scripts.tests.test_spec_governance` — 176 tests, OK
- `python3 scripts/catalog-release.py verify` — committed release unchanged, verified
- `bash scripts/test-catalog-release.sh` — PASS
- `bash scripts/test-renew-autotune-static-feed-signed.sh` — ok
- `git diff --check` — clean

## Confirmation pass (code + architecture lanes on `b7a401fe`; security not re-run)

| Lane | Verdict |
|---|---|
| code | **0 CRITICAL / 0 HIGH / 0 MEDIUM** / 1 LOW / 3 INFO — all three call sites now mutation-pinned |
| architecture | **0 CRITICAL / 0 HIGH / 0 MEDIUM** / 2 LOW / 2 INFO — rule-8 placement at activation judged faithful |

Resolved in the follow-up commit: rule 8 is re-derived by `verify` for the
activation release (call-site test with a sentinel, and a four-feed release
must not consult it); the gate fails closed on a preceding release with no
recorded rate card instead of returning; the pending-surface list is pinned by
`PendingSurfaceListTest` (each entry's surface must still be absent from the
tree); the rewards-parser tab scoping has above/inside/after cases; the
`--from-source` CLI wiring is exercised through `main()`; `status` separates
its sections; the runbook parenthetical now claims only what `status` prints.
181 tests OK.
