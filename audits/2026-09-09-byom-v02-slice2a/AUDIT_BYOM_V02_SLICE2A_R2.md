# Audit R2 — BYOM v0.2 slice 2a: catalog artifact-feed generator, class rate expansion, ledger v3

**Branch:** `feat/byom-v02-slice2a-artifact-feed-generator`
**Date:** 2026-09-09
**Prompt:** `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_PROMPT.md`
**Predecessor:** `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_R1.md`
**Authority:** SPEC-023 v0.10.0 §3.2, §3.3.1, §3.5, §3.7.1–§3.7.8, §11 AC-CAT-1…19, §15, §16.8;
SPEC-047-R003 (0.1.3); SPEC-005 §5.5.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R2 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 1 HIGH / 3 MEDIUM / 1 LOW / 0 INFO |
| security-reviewer | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW / 0 INFO |
| architect | 0 CRITICAL / 0 HIGH / 3 MEDIUM / 0 LOW / 0 INFO |

All three lanes returned REQUEST CHANGES. The nine C/H/M findings deduplicate to
five distinct defects (G1–G5) plus one LOW (G6); three of the MEDIUMs were
reported by two or three lanes each under different framings.

Every R1 resolution (F1–F8) was re-confirmed by all three lanes. No R1 finding
regressed.

## Deduplicated findings and resolutions

### G1 — HIGH: the scheduled freshness renewal re-stamped a GENERATED file, not its source

*code-reviewer HIGH "freshness renewal updates the generated rate card instead of
its source of truth".*

`renew-autotune-static-feed.sh` wrote `NOW_ISO` into `rate-card.json`. Since this
slice adopted the §3.3.1 authoring source, `rate-card.json` is MATERIALISED from
`rate-card-source.json` by `expand_rate_card`, so the very next `generate` in the
renewal reverted the re-stamped date to the source's stale
`2026-09-02T00:00:00Z`, and `validate_release_inputs` then aborted the run on a
rate-card `generated_at` that no longer matched the re-stamped candidate catalog.

This is a production defect, not a hypothetical: the signed feed carries a 30-day
client freshness horizon (`AutotuneRecommend.loadSignedStatic`), the renewal runs
unattended every Wednesday out of `.github/workflows/renew-autotune-static-feed-signed.yml`,
and an aborted renewal strands every provider that restarts after the horizon.
The hermetic tests missed it because `HermeticRelease.bump` re-stamped
`rate-card-source.json` itself — the test helper was doing what the production
script did not.

**Resolution.** Which files are SOURCES and which are GENERATED is the
generator's knowledge, so the restamp moved into the generator and the shell
script delegates to it.

* `restamp()` (`scripts/catalog-release.py:3211`) and the `restamp` subcommand
  (`scripts/catalog-release.py:3563`) re-date `version` + `generated_at` on
  candidate/demand and `generated_at` only on the rate card AT ITS SOURCE
  (`rate-card-source.json`), falling back to the published `rate-card.json` only
  on a checkout that predates the source. The generator exclusively materialises
  `rate-card.json`.
* `scripts/renew-autotune-static-feed.sh:155-164` calls
  `catalog-release.py restamp --release-id … --generated-at …` in place of the
  inline heredoc.
* EXECUTABLE regression: `RenewalFlowTest`
  (`scripts/tests/test_catalog_artifact_feed.py:1964`) drives the real
  restamp → generate → sign → generate → verify sequence in BOTH states —
  `test_pre_activation_renewal_restamps_generates_and_verifies` (four-feed) and
  `test_post_activation_renewal_restamps_generates_and_verifies` (five-feed) —
  and asserts candidate, demand, `rate-card.json`, and `rate-card-source.json`
  all carry the same re-stamped `generated_at` afterwards.
  `test_restamping_the_generated_rate_card_instead_of_its_source_aborts` pins the
  defect itself: reproducing the old shell behaviour still fails the release
  closed. `scripts/test-renew-autotune-static-feed-signed.sh` runs that class, and
  greps the script for the delegation and against a direct `rate-card.json`
  re-stamp.
* Runbook: `docs/runbooks/autotune-feed-renewal.md` step 2.

### G2 — MEDIUM: cross-feed signer equality was not enforced for previous releases or ledger rows

*code-reviewer MEDIUM-1 "previous-release authentication omits the required
cross-feed signer equality"; security-reviewer MEDIUM-2 "authenticated previous
releases may use different trusted candidate and artifact signers"; architect
MEDIUM-3 (same).*

`load_previous_release` proved each feed individually: digest and length against
its `release.json` binding, sidecar `key_id` against that binding, and an Ed25519
verification under the trusted keyring. Every one of those is per-feed. During a
rotation bridge more than one key is concurrently trusted, so a previous release
whose artifact feed and candidate catalog were signed by two DIFFERENT trusted
keys — with `release.json` and the ledger row honestly recording both — satisfied
all of them and became the §3.7.4 rebinding authority, contradicting the
normative equality at SPEC-023 §3.7.2. The shared ledger validator permitted the
same shape in any artifact-bound row.

**Resolution.** One rule, one error, three call sites.

* `require_artifact_signer_equality` (`scripts/catalog-release.py:1439`).
* `load_previous_release` (`scripts/catalog-release.py:1603`) applies it to the
  AUTHENTICATED signer IDs collected during sidecar verification, not to the
  recorded ones.
* `validate_release_ledger` (`scripts/catalog-release.py:1913`) applies it to
  every artifact-bound row, after `validate_ledger_feed` has established both
  signer IDs, so `verify` rejects a hand-assembled document too.
* `manifest` (`scripts/catalog-release.py:1708`) now routes its existing
  generation-time check through the same helper.
* Tests: `test_two_valid_concurrently_trusted_signers_fail_closed`
  (`scripts/tests/test_catalog_artifact_feed.py:2153`) re-signs the previous
  release's artifact feed with a SECOND genuinely trusted key and updates both
  `release.json` and the ledger row to match, so every per-feed check passes and
  only the equality fails; `test_artifact_bound_row_must_record_one_signer_across_both_feeds`
  (`:888`) covers the ledger validator. `HermeticRelease` now provisions a second
  concurrently trusted key (`ALT_KEY_ID`) for exactly this condition.

### G3 — MEDIUM: activation monotonicity was decided from the base ledger only

*code-reviewer MEDIUM-2 "activation and downgrade can coexist in one new ledger
without rejection"; architect MEDIUM-2 "first-activation ledger delta can contain
a later four-feed downgrade".*

`require_ledger_evolution` computed `activated` from the BASE ledger. With
`origin/main` pre-activation, one delta introducing both the first artifact-bound
activation row and a chronologically later four-feed row left `activated` false
for both rows, and the revert passed. §3.7.8 and AC-CAT-19 make monotonicity a
property of the resulting ledger, not of the rows the base happened to have.

**Resolution.** `require_ledger_evolution` (`scripts/catalog-release.py:2055-2078`)
now sweeps the COMPLETE current ledger in chronological order: once any row is
artifact-bound, every later row must be artifact-bound. The base-derived check is
retained alongside it, because it catches the complementary case of a new
four-feed row BACKDATED before an already-recorded activation.

Tests: `test_one_delta_may_not_both_activate_and_revert`
(`scripts/tests/test_catalog_artifact_feed.py:903`) exercises the validator
directly and asserts the same delta WITHOUT the later row is still accepted;
`test_verify_rejects_an_activation_delta_carrying_a_later_four_feed_release`
(`:1799`) exercises it through the PUBLIC `verify` entry point on a real
activated hermetic release.

### G4 — MEDIUM: "latest release" was selected by lexical string comparison

*code-reviewer MEDIUM-3.*

`RFC3339` admits any explicit offset and optional fractional seconds
(`scripts/catalog-release.py:84`), but both latest-release helpers ordered the raw
strings. `2026-09-19T23:00:00-02:00` is one hour LATER than
`2026-09-20T00:00:00Z` and lexically smaller, and `...:00.000Z` sorts after
`...:00Z` for the same instant. A wrong verdict picks the wrong previous release —
the authority the §3.7.4 rebinding check authenticates against and the §3.7.8
intake-transition rule compares admission tiers with.

**Resolution.** `parse_timestamp` (`scripts/catalog-release.py:156`) returns the
aware `datetime` (`parse_time` is now a thin validating wrapper), and
`release_order_key` (`:1491`) orders by that instant with `release_id` as the
deterministic tie-breaker only. Both `latest_artifact_bound_release` (`:1504`) and
`latest_release` (`:2879`) use it, as does the G3 chronological sweep.

Tests: `ReleaseOrderingTest` (`scripts/tests/test_catalog_artifact_feed.py:1899`)
covers mixed offsets for both helpers, the fractional-second spelling of one
instant, and `release_id` acting only as the tie-breaker.

### G5 — MEDIUM: rate-global rounding did not mirror Go binary64 semantics

*security-reviewer MEDIUM-1 "rate conversion still does not exactly mirror
coordinator binary64 rounding"; architect MEDIUM-1 "rate-global parity can
disagree with production Go billing".*

`scaled_nonnegative_integer` reconstructed the value's shortest decimal text and
applied `Decimal` `ROUND_HALF_UP`. `billing.ParseShareBps` /
`billing.ParseMultiplierPPM` instead multiply the PARSED binary64 by the binary64
scale and call `math.Round`. The two disagree whenever the binary64 product falls
just below a half unit that the decimal text lands exactly on, so the §3.3.1 rule
9 parity gate could accept a signed `provider_share_bps` the coordinator never
derives. The R1 test only pinned Python against a Python-authored table, and in
fact carried one wrong expectation: it asserted `0.00015 → 2 bps`, whereas the
coordinator derives 1.

**Resolution.** `scaled_nonnegative_integer` (`scripts/catalog-release.py:984`)
now does what Go does, on the binary64 product:

```python
    if not isinstance(raw, (int, float)) or isinstance(raw, bool):
        fail(f"{label}: expected a finite non-negative number, got {raw!r}")
    value = float(raw)
    if not math.isfinite(value) or value < 0:
        fail(f"{label}: expected a finite non-negative number, got {raw!r}")
    scaled = value * float(scale)
    if not math.isfinite(scaled):
        fail(f"{label}: {raw!r} scaled by {scale} is not finite")
    if scaled >= 2.0 ** 52:
        return int(scaled)
    return int(math.floor(scaled + 0.5))
```

`math.floor(x + 0.5)` is half-away-from-zero for a non-negative binary64 `x` below
2**52, where every `x + 0.5` is exactly representable; at or above that bound every
binary64 is already an integer, which is the one place the identity breaks, so it
is guarded rather than assumed.

Parity is now pinned by ONE shared boundary-vector table,
`scripts/tests/fixtures/rate_global_rounding_cases.json`, following the
`normalize_model_key_cases.json` pattern from R1:

* Python side: `test_scaled_conversion_matches_go_binary64_rounding`
  (`scripts/tests/test_catalog_artifact_feed.py:1265`).
* Go side: `TestRateGlobalRoundingSharedCaseTable`
  (`phase4-coordinator/internal/billing/rate_global_rounding_cases_test.go`),
  running the real `ParseShareBps` / `ParseMultiplierPPM` on the same inputs and
  asserting the same integers. It also pins `share_scale` / `multiplier_scale`
  against `providerShareDenom` / `globalMultiplierDenom`, so a scale change cannot
  silently invalidate every expectation.
* The table carries four vectors flagged `decimal_divergence` — `0.00015`,
  `0.00145`, `1.0000025`, `1.0000075` — where a decimal-semantics port answers one
  unit higher. `test_a_decimal_semantics_port_would_fail_the_flagged_vectors`
  (`:1310`) asserts the flag rather than trusting the annotation, and the parity
  test refuses a table that has lost its divergent vectors.

Production billing is untouched: no file under `phase4-coordinator/internal/billing/`
changed except the addition of the new test.

### G6 — LOW: pre-activation validation was wider than "schema-only"

*code-reviewer LOW-1.*

The runbook said the source is schema-validated pre-activation, but
`validate_artifact_source` also ran `require_primary_artifact_consistency`. A
routine candidate-catalog change could therefore block an otherwise valid
four-feed release against a source document nothing is serving yet.

**Resolution.** `validate_artifact_source` (`scripts/catalog-release.py:1285`)
takes `candidate_obj` as optional. Structural checks — schema closure, the
identity-tuple matrix, `artifact_id` grammar, GGUF digest equality, global hash
uniqueness — always run; candidate consistency runs only when `candidate_obj` is
supplied, which is activation time (`artifact_activation_prerequisites`) and every
artifact-bound cut (`resolve_artifact_feed`). The two pre-activation callers
(`generate` at `:3129`, `published_artifact_feed` at `:2822`) pass no candidate.

Documented in `docs/runbooks/catalog-artifact-feed-release.md` under the
activation-state table. Test:
`test_a_candidate_change_still_cuts_a_pre_activation_four_feed_release`
(`scripts/tests/test_catalog_artifact_feed.py:1835`) changes a candidate row's
`min_ram_gb` with an unmeasured source and asserts the four-feed release is still
cut, AND that the same drift is reported as an unmet activation prerequisite.

## Files changed in R2

| File | Change |
|---|---|
| `scripts/catalog-release.py` | `restamp` command + `parse_timestamp` / `release_order_key` + `require_artifact_signer_equality` + Go-parity rounding + ledger-wide activation sweep + structural/consistency split |
| `scripts/renew-autotune-static-feed.sh` | delegates the restamp to `catalog-release.py restamp` |
| `scripts/test-renew-autotune-static-feed-signed.sh` | delegation greps + runs the executable `RenewalFlowTest` |
| `scripts/tests/test_catalog_artifact_feed.py` | `ReleaseOrderingTest`, `RenewalFlowTest`, second trusted key in `HermeticRelease`, six new targeted tests |
| `scripts/tests/fixtures/rate_global_rounding_cases.json` | NEW shared rate-global rounding vectors |
| `phase4-coordinator/internal/billing/rate_global_rounding_cases_test.go` | NEW Go half of the shared table |
| `docs/runbooks/autotune-feed-renewal.md` | source-stamped restamp step |
| `docs/runbooks/catalog-artifact-feed-release.md` | pre-activation validation scope |

Unchanged, re-confirmed: candidate catalog bytes, `release.json`,
`release-ledger.json`, `dist/static/*`, `CompatibilitySetManifest.swift`, the
nine-name Stage A compatibility map, and every production file under
`phase4-coordinator/internal/billing/`.

## Verification

| Command | Result |
|---|---|
| `python3 scripts/catalog-release.py verify` | pass — `published-2026-09-02-gpt-oss-120b-v1` |
| `bash scripts/test-catalog-release.sh` | PASS |
| `bash scripts/test-renew-autotune-static-feed-signed.sh` | ok |
| `python3 -m unittest scripts.tests.test_catalog_artifact_feed scripts.tests.test_spec_governance` | 159 tests, OK |
| `go test ./internal/billing -count=1` | ok |
| `bash -n scripts/resign-autotune-static.sh scripts/renew-autotune-static-feed.sh` | clean |
| `python3 scripts/check_spec_governance.py` | SPEC governance validation passed |
| `python3 scripts/gen_spec_index.py --lint` | ok, 51 tracked |
| `git diff --check` | clean |

Test count moved 142 → 159: 98 → 113 in `test_catalog_artifact_feed` (15 new) and
46 → 46 in `test_spec_governance`,
plus the new Go parity test.
