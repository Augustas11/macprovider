# Audit R1 — BYOM v0.2 slice 2a: catalog artifact-feed generator, class rate expansion, ledger v3

**Branch:** `feat/byom-v02-slice2a-artifact-feed-generator`
**Date:** 2026-09-09
**Prompt:** `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_PROMPT.md`
**Authority:** SPEC-023 v0.10.0 §3.2, §3.3.1, §3.5, §3.7.1–§3.7.8, §11 AC-CAT-1…19, §15, §16.8;
SPEC-047-R003 (0.1.3); SPEC-005 §5.5.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R1 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 2 HIGH / 4 MEDIUM / 1 LOW / 0 INFO |
| security-reviewer | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 2 LOW / 1 INFO |
| architect | 0 CRITICAL / 0 HIGH / 5 MEDIUM / 5 LOW / 0 INFO |

All three lanes returned REQUEST CHANGES. The nine C/H/M findings deduplicate to
eight distinct defects (F1–F8): the two HIGHs and five of the MEDIUMs were
reported by two or three lanes each under different framings.

## Deduplicated findings and resolutions

### F1 — Activation was inferred from source presence, breaking pre-activation workflows

*code-reviewer HIGH-1 "the documented artifact-bound signing flow cannot complete";
security-reviewer MEDIUM-1 "artifact activation and feed renewal cannot complete
through the documented signing flow"; architect MEDIUM-2 "source presence, rather
than published-feed state, controls generation".*

`resolve_artifact_feed` built the feed whenever `autotune-artifacts-source.json`
existed. Two consequences, both real:

1. The committed source carries `size_bytes: null` by design, and published-feed
   validation forbids unmeasured sizes, so `resign-autotune-static.sh:51` and the
   scheduled renewal at `renew-autotune-static-feed.sh:173` — which both call
   `generate` unconditionally — would fail on a repository that had merely
   committed the source. A pre-activation four-feed release could no longer be cut.
2. `generate` recorded the current release's artifact bindings in the ledger, and
   the rebinding check then read that same freshly written row as prior history,
   so the second `generate` inside the resign flow rejected its own bindings and
   demanded a previous feed the shell script had no way to pass.

**Resolution.** Activation is now an explicit, ledger-derived state.

* `artifact_feed_activation_state` (`scripts/catalog-release.py:2870`) returns
  `pre_activation` / `activation` / `post_activation` from the release ledger, the
  published feed, and one flag. Pre-activation validates the source's schema only
  (unmeasured `size_bytes` legal) and builds nothing.
* `--activate-artifact-feed` (`scripts/catalog-release.py:3410`) is required for
  the first artifact-bound release, requires a new `release_id`, needs no previous
  release, and is refused once an earlier release has activated.
* `release_history` (`scripts/catalog-release.py:1410`) excludes the release being
  generated, so regenerating the SAME `release_id` — the idempotent re-run before
  and after signing — is not blocked by its own row.
* A published feed with no ledger row binding it fails closed rather than
  activating implicitly (`scripts/catalog-release.py:2921`).
* `AUTOTUNE_ACTIVATE_ARTIFACT_FEED` / `AUTOTUNE_PREVIOUS_RELEASE_DIR` thread
  through `scripts/resign-autotune-static.sh:49-70` (both `generate` invocations, lines 74 and 178)
  and `scripts/renew-autotune-static-feed.sh:172-196`; renewal staging copies the
  artifact feed and sidecar when the release is artifact-bound
  (`scripts/renew-autotune-static-feed.sh:214-222`).

**Evidence.** `scripts/tests/test_catalog_artifact_feed.py:HermeticReleaseTest`
drives the real `generate` / sign / regenerate / `verify` sequence over a
throwaway keyring: four-feed renewal with the unmeasured source present
(`test_four_feed_release_is_unaffected_by_the_committed_unmeasured_source`), a
measured source that still does not activate (`test_activation_requires_the_explicit_flag`),
first activation plus idempotent regeneration after signing
(`test_activation_then_idempotent_regeneration_then_verify`), a subsequent
artifact-bound release with a previous release directory
(`test_post_activation_release_with_the_previous_release_directory`), and
post-activation generation without one failing closed
(`test_post_activation_generate_without_a_previous_release_fails_closed`).

### F2 — `verify` did not reject cross-release artifact-ID rebinding

*code-reviewer HIGH-2.*

The rebinding check ran only at generation. `validate_release_ledger` enforced
`(model_key, artifact_id)` uniqueness within a row, never across rows, so a
release assembled by hand and correctly signed could reuse a pair under a
different `(hash_algorithm, hash)` and pass `verify`.

**Resolution.** `artifact_binding_history` (`scripts/catalog-release.py:1371`) is
now called from `validate_release_ledger` (`scripts/catalog-release.py:1835`), so
every path that reads a ledger — `verify` included — rejects a pair recorded with
two identities. A retired `artifact_id` stays bound to its bytes.

**Evidence.**
`HermeticReleaseTest.test_verify_rejects_a_hand_assembled_cross_release_rebinding`
asserts through the public `verify` entry point with a hand-assembled ledger row.

### F3 — Ledger v3 accepted `null` intake provenance across add/promote transitions

*code-reviewer MEDIUM-1; security-reviewer MEDIUM-2; architect MEDIUM-4.*

`intake_decision_digest` hashed `intake-decision.json` when it happened to exist
and returned `null` otherwise; nothing compared candidate statuses. SPEC-023
§3.7.8 permits `null` only for a release that adds no `listed` row and promotes no
row to `recommendable`, so a signed, settlement-adjacent catalog could admit or
promote a model with no release-bound record of the decision.

**Resolution.** `require_intake_decision` (`scripts/catalog-release.py:2830`)
compares this release's per-key admission tier against the previous release's and
fails closed when a transition carries a null digest. Prior state comes from two
named release inputs (`previous_candidate_admission`,
`scripts/catalog-release.py:2778`):

* post-activation — the authenticated `--previous-release-dir` candidate catalog;
* the activation release — the ledger's recorded `autotune-candidates.json`
  digest. Re-stamping the current catalog with the preceding release's `version`
  and `generated_at` reproduces its exact bytes when, and only when, nothing else
  changed, so digest equality PROVES the admission tiers are unchanged.

If prior state is unavailable after activation, the release fails closed; at
activation it fails closed unless a non-null intake digest is committed.
`CANDIDATE_ADMISSION_TIER` (`scripts/catalog-release.py:2757`) ranks the §3.2
statuses so absent→listed/recommendable, pre-admission→listed/recommendable, and
listed→recommendable are all caught while a demotion is not mistaken for one.

**Evidence.** `IntakeDecisionTest.test_each_add_or_promote_transition_requires_a_digest`
(six negative cases, each also asserted to pass with the digest),
`:test_a_release_with_no_transition_may_carry_null`,
`:test_a_demotion_needs_no_intake_decision`,
`:test_unavailable_prior_state_fails_closed_after_activation`,
`:test_unavailable_prior_state_at_activation_requires_a_digest`,
`:test_prior_state_is_proven_from_the_ledger_candidate_digest`, and end-to-end
`HermeticReleaseTest.test_intake_decision_is_required_when_a_release_promotes_a_row`.

### F4 — Python and coordinator global rounding disagreed at midpoints

*code-reviewer MEDIUM-2; architect MEDIUM-5; security-reviewer LOW-3.*

`check_rate_card_parity` used Python's `round` (ties-to-even) where
`billing.ParseShareBps` / `ParseMultiplierPPM` use Go `math.Round` (half away from
zero) (`phase4-coordinator/internal/billing/formula.go:151`). At a value scaling
onto an exact half unit the release gate would accept a signed
`provider_share_bps` the coordinator never derives.

**Resolution.** `scaled_nonnegative_integer` (`scripts/catalog-release.py:974`)
parses the value's decimal text into a `Decimal` and quantizes with
`ROUND_HALF_UP`, reproducing the Go result exactly over the non-negative domain
the config admits and avoiding a second binary-float rounding step.

**Evidence.** `RateGlobalsTest.test_scaled_conversion_rounds_half_away_from_zero_like_go`
(midpoint table for both share and multiplier) and
`:test_midpoint_share_disagreement_fails_the_parity_gate`.

### F5 — Per-row global equality was not a shared validation invariant

*code-reviewer MEDIUM-3; architect LOW-1.*

Expansion stamped the release globals onto every row, but published-feed
validation checked only types and bounds and coordinator parity compared only the
`default` row, so `verify-directory` accepted a properly signed rate card whose
non-default row carried a different share or multiplier.

**Resolution.** `validate_rate_card` (`scripts/catalog-release.py:698`, per-row check at :739) — the
SHARED validator every verification path uses — now requires every row's
`provider_share_bps` and `global_multiplier_ppm` to equal the `default` row's, the
published feed's only in-band representation of the release globals.
`check_rate_card_parity` (`scripts/catalog-release.py:995`) checks the
coordinator globals against every row, not just `default`.

**Evidence.** `RateGlobalsTest.test_a_non_default_row_may_not_carry_a_different_global`
(both fields, projection hash recomputed so the mutation is otherwise valid),
`:test_a_non_default_row_global_fails_the_parity_gate`, and
`ReleaseDirectoryTest.test_verify_directory_rejects_a_non_default_row_global`,
which mutates a staged release and asserts `verify-directory` rejects it on the
global-equality rule before reaching any signature check.

### F6 — The previous artifact feed was not authenticated

*security-reviewer LOW-4; architect LOW-2.*

`--previous-artifact-feed` took raw JSON bytes. Its signature, release identity,
signer, and completeness against the ledger row were never checked, so the
rebinding check's prior-binding authority was an unproven operator input.

**Resolution.** Replaced by `--previous-release-dir`. `load_previous_release`
(`scripts/catalog-release.py:1444`) verifies the directory's `release.json`, every
static feed's digest / length / version, and every detached Ed25519 signature
under the trusted keyring; requires the sidecar signer to equal the signer
`release.json` binds; requires the directory to be the release the ledger records
as the latest artifact-bound one; and requires its published artifact bindings to
equal that row's `artifact_bindings` exactly.

**Evidence.** `PreviousReleaseDirectoryTest`:
`test_a_conforming_previous_release_loads`,
`test_tampered_feed_bytes_fail_the_release_json_binding`,
`test_ledger_bindings_must_equal_the_signed_feed_exactly` (missing pair, extra
pair, changed identity), `test_the_wrong_release_fails_closed`,
`test_the_wrong_signer_fails_closed`, `test_an_invalid_signature_fails_closed`.

### F7 — The committed source could not complete class expansion

*architect MEDIUM-1.*

`expand_rate_card` recognised an explicit override by EXACT key only. The artifact
source's key `nvidia/nemotron-3-nano-30b-a3b` is priced by the published row
`nemotron-3-nano-30b-a3b`, and `class-30b-moe` is deliberately unseeded, so
generation from the committed inputs failed — a state the AC-CAT-10 test missed
because it expanded against an EMPTY class map.

**Resolution.** An explicit row now resolves the way SPEC-023 §3.3.1 rule 7 and
SPEC-005 §5.5 resolve one: exact key, then `NormalizeModelKey`
(`scripts/catalog-release.py:823`, lookup at :852). Resolution publishes NO row for the
un-normalized spelling, so the published bytes are unchanged. A declared
`rate_class` with no class rates is an error only when no explicit row resolves.

**Evidence.** `RateCardSourceTest.test_committed_source_reproduces_the_published_rows_byte_for_byte`
now expands with the COMMITTED artifact source's `rate_class` declarations (all
ten keys) and still asserts byte identity with `rate-card.json`;
`:test_every_committed_key_resolves_a_rate_row_through_its_declared_class` proves
each of the ten rows resolves, including the four in the unseeded `class-30b-moe`
and `class-32b`; `:test_normalized_explicit_row_is_not_republished_under_the_feed_spelling`
pins that no second spelling is published;
`:test_missing_class_rates_still_fail_when_no_explicit_row_resolves` pins that
normalized resolution is not a bypass. Confirmed live:
`python3 scripts/catalog-release.py status` reports "every declared rate_class
resolves to an explicit row or class rates" as satisfied.

### F8 — No explicit "not activatable yet" state for Stage A

*architect MEDIUM-3.*

This slice ships the generator, but the distribution surfaces Stage A requires —
CLI packaging, release assets, the live release gate, and the coordinator nginx
route — belong to slices 2b/2c and are absent. Failing accidentally on null sizes
and class expansion is not a release gate.

**Resolution.** `catalog-release.py status` (`scripts/catalog-release.py:3280`)
prints the activation state, every generator-side prerequisite with its verdict,
and the four pending distribution surfaces with the exact file and line each 2b/2c
slice must touch (`PENDING_DISTRIBUTION_SURFACES`,
`scripts/catalog-release.py:2931`). `--activate-artifact-feed` refuses while any
generator-side prerequisite is unmet, listing all of them at once
(`scripts/catalog-release.py:3002`). The runbook gained an "Activation state"
section with the state table and a "What the 2b/2c slices must land before
activation" table naming `phase3-binary/dist/package.sh` (~196),
`.github/workflows/release.yml` (~1385, ~1418),
`scripts/verify-live-coordinator-release-gate.py` (~17), and
`phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
(`docs/runbooks/catalog-artifact-feed-release.md:26-72`).

**Evidence.** `HermeticReleaseTest.test_activation_is_refused_while_a_prerequisite_is_unmet`,
`:test_activation_requires_a_new_release_id`,
`:test_activate_flag_is_refused_once_an_earlier_release_activated`,
`:test_a_stale_published_feed_never_activates_implicitly`.

## LOW findings resolved

| Finding | Lanes | Resolution |
|---|---|---|
| AC-CAT-19 positive case added no new bytes under a new id | code-reviewer MEDIUM-4 (test half), architect LOW-3 | `LedgerV3Test.test_new_bytes_under_a_new_artifact_id_are_allowed` publishes a NEW `artifact_id` carrying NEW bytes, retires the old id as `blocked` with its original bytes, moves the primary, asserts both bindings, and then proves that reintroducing the retired id bound to the replacement's bytes still fails. The removal/reintroduction case stays in `:test_cross_release_rebinding_fails_closed`. |
| Module docstring claimed AC coverage it did not have | code-reviewer MEDIUM-4 (claim half), security-reviewer INFO-5 | `scripts/tests/test_catalog_artifact_feed.py:1-53` now scopes the module to the GENERATOR half and names AC-CAT-2, 7, 12, 13, 17, 20, 21 as owned elsewhere and unimplemented in this slice, rather than listing them as out of scope with AC-CAT-12 half-claimed. |
| `NormalizeModelKey` table test was not a drift detector | architect LOW-4 | ONE shared table, `scripts/tests/fixtures/normalize_model_key_cases.json` (25 cases), consumed by the Python test (`RateCardSourceTest.test_normalize_model_key_matches_the_go_implementation`, which also asserts the Go test references the same file) and by a new Go test, `phase4-coordinator/internal/billing/normalize_model_key_cases_test.go`. A change to either implementation alone now turns one of them red. |
| Disablement runbook contradicted the committed state | code-reviewer LOW-1, architect LOW-5 | `docs/runbooks/byom-disablement-rollback.md` row 11 now states that the source IS committed, that committing it activates nothing, that activation requires `--activate-artifact-feed` or an existing artifact-bound ledger row, and that no feed is published or release-bound. State cell: "off (source committed; no feed published or release-bound)". |

## Carried items

* **AC-CAT-2, AC-CAT-7, AC-CAT-12, AC-CAT-13, AC-CAT-17, AC-CAT-20, AC-CAT-21 are
  not covered by this slice.** They are consumer, coordinator, and §16 intake
  criteria; this slice ships no code for them. The module docstring now says so
  rather than presenting the suite as complete. Not a defect — a scope statement
  that R1 was right to require be made honest.
* **Stage-A distribution is not shippable from this branch.** Packaging, release
  assets, the live release gate, and the nginx route are slices 2b/2c. `status`
  and the runbook name each file and line; `--activate-artifact-feed` gates only
  the generator-side prerequisites, since the generator cannot verify a serving
  surface it does not own.
* **The intake-decision rule is a generation-time gate, not a document
  validator.** `release-ledger.json` records the previous candidate catalog's
  digest, not its rows, so a validator reading the ledger alone cannot recompute
  admission transitions. F2's rebinding check, which needs only ledger content,
  IS in the shared validator.

## Verification

```
python3 scripts/catalog-release.py verify                         -> pass
bash scripts/test-catalog-release.sh                              -> PASS
python3 -m unittest scripts.tests.test_catalog_artifact_feed
       scripts.tests.test_spec_governance                         -> 141 tests OK
cd phase4-coordinator && go test ./internal/billing
       -run 'NormalizeModelKey' -count=1                          -> ok
bash -n scripts/resign-autotune-static.sh
       scripts/renew-autotune-static-feed.sh                      -> clean
bash scripts/test-renew-autotune-static-feed-signed.sh            -> ok
bash scripts/test-compatibility-set-manifest.sh                   -> ok
python3 scripts/check_spec_governance.py                          -> passed
python3 scripts/gen_spec_index.py --lint                          -> ok (51 tracked)
make test-dist                                                    -> pass
git diff --check                                                  -> clean
```

The committed four-feed release still verifies unchanged, the candidate catalog,
`release.json`, `release-ledger.json`, and `dist/static/*` are untouched, and the
published rate-card rows remain byte-identical — now proved by expanding with the
committed artifact source's real class declarations rather than an empty map.
