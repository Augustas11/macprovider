# Audit R3 — BYOM v0.2 slice 2a: catalog artifact-feed generator, class rate expansion, ledger v3

**Branch:** `feat/byom-v02-slice2a-artifact-feed-generator`
**Date:** 2026-09-09
**Prompt:** `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_PROMPT.md`
**Predecessors:** `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_R1.md`,
`audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_R2.md`
**Authority:** SPEC-023 v0.10.0 §3.2, §3.3.1, §3.5, §3.7.1–§3.7.8, §11 AC-CAT-1…19, §15, §16.8;
SPEC-047-R003 (0.1.3); SPEC-005 §5.5.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R3 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 3 MEDIUM / 2 LOW / 0 INFO — REQUEST CHANGES |
| security-reviewer | **no verdict — provider failure** |
| architect | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 0 INFO — BLOCK |

The security lane did not produce a review in R3: the provider run failed and
returned no findings, no verdict, and no validation section. It is **not** a
0/0/0 result and MUST NOT be treated as one. R2's security lane (0 C / 0 H /
2 M, both resolved) is the last completed security verdict on this branch, and
it predates the R3 fixes recorded below. The security lane is therefore
**re-run in R4** over the full combined diff; slice 2a is not merge-eligible
until it returns a verdict at the bar.

All R1 (F1–F8) and R2 (G1–G6) resolutions were re-confirmed by the two lanes that
completed. No earlier finding regressed. Every R3 finding below is NEW.

The committed release is unchanged and still verifies: candidate catalog bytes,
`release.json`, `release-ledger.json`, `dist/static/*`,
`CompatibilitySetManifest.swift`, the nine-name Stage A compatibility map, and
every production file under `phase4-coordinator/internal/billing/` are untouched
by this round.

## Findings and resolutions

### M-A — MEDIUM: `math.floor(scaled + 0.5)` is not an exact port of Go `math.Round`

*code-reviewer M1, `scripts/catalog-release.py:997` — "Python rate-global rounding
can diverge from coordinator billing"; the unresolved half of R2 G5.*

R2 replaced a decimal-semantics port with `math.floor(x + 0.5)` on the binary64
product. That is still not what `billing.ParseShareBps` /
`billing.ParseMultiplierPPM` compute
(`phase4-coordinator/internal/billing/formula.go:151`): Go's `math.Round`
compares the **fractional part** to one half and never forms `x + 0.5`. The sum
is itself a rounded binary64, so for a product immediately below a half unit the
addition can round **up onto the next integer** and carry the value across a
boundary it does not reach. The release gate would then accept a signed
`provider_share_bps` settlement never derives — the §3.3.1 rule-9 parity check
enforcing the wrong integer, which is exactly the money-path defect G5 was
opened for.

The concrete case is `4.9999999999999996e-05 * 10000`, whose product is
`0.49999999999999994` — the largest binary64 below one half. `x + 0.5` rounds to
exactly `1.0`, so `floor(x + 0.5)` answers **1 bps** where `math.Round` answers
**0**.

**Resolution.** `scaled_nonnegative_integer` now ports Go's semantics exactly for
non-negative finite values (`scripts/catalog-release.py:1024-1027`):

```python
truncated = math.floor(scaled)
if scaled - truncated >= 0.5:
    return int(truncated) + 1
return int(truncated)
```

`scaled - math.floor(scaled)` is EXACT for every `0 <= x < 2**52`, so the
comparison involves no intermediate rounding at all; the pre-existing `>= 2**52`
guard is kept, because at or above that bound every binary64 is already an
integer. The docstring (`scripts/catalog-release.py:984-1016`) records why the
comparison is on the fraction rather than on a sum.

The shared vector table gained the boundary vectors, constructed with
`math.nextafter` around each half-unit **product** so the immediately-below and
immediately-above neighbour of a boundary are both pinned
(`scripts/tests/fixtures/rate_global_rounding_cases.json`): six new share vectors
around the 0.5 / 1.5 / 2.5 / 14.5 bps boundaries and five new multiplier vectors
around the 0.5 / 2.5 / 1000002.5 ppm boundaries. The divergent one carries a new
`floor_half_add_divergence: true` flag (`…rate_global_rounding_cases.json:12`).

Both readers consume the same table and both pass:

* Python — `RateGlobalsTest.test_scaled_conversion_matches_go_binary64_rounding`
  and the new `test_a_floor_half_add_port_would_fail_the_flagged_vectors`
  (`scripts/tests/test_catalog_artifact_feed.py:1332`), which ASSERTS the
  annotation rather than trusting it: for every vector it recomputes
  `floor(x + 0.5)` and requires the divergence claim to match, and requires the
  table to still carry at least one such vector.
* Go — `TestRateGlobalRoundingSharedCaseTable`
  (`phase4-coordinator/internal/billing/rate_global_rounding_cases_test.go`),
  unchanged, now running the widened table against the real
  `ParseShareBps` / `ParseMultiplierPPM`.

Note that no divergent vector exists at the multiplier scale: no binary64 value
multiplied by `1e6` lands exactly on `0.49999999999999994`. The multiplier
boundary vectors are pinned anyway, so a future change to either scale is caught
on both sides.

### M-B — MEDIUM: `emit-coordinator-rate-card` could not project a class-only row before activation

*architect M, `scripts/catalog-release.py:3433` — "first-activation class
expansion cannot produce coordinator fallback rows".*

The emitter derived `rate_classes` through `published_artifact_feed`, which
returns `(None, None)` while no artifact feed is published. A model key priced
solely by `rate_class` is expanded only while iterating that class map, so with
an empty map and no explicit row the recommendable-row guard rejected the
expansion. The first activation was therefore circular: the operator needs the
emitter to produce the coordinator fallback row, the emitter could not see the
authored class until a feed was published, and `generate
--activate-artifact-feed` will not publish that feed until rule-9 parity already
holds. That contradicted the runbook step that tells the operator to use this
command when adding a fallback row.

The root cause is a category error: published bytes are the right authority for
VERIFYING a release and the wrong authority for PROJECTING the config a
not-yet-cut release needs. `rate_class` is authored on
`autotune-artifacts-source.json` and only reaches the published feed at the
activation cut.

**Resolution.** New `authoring_rate_classes(candidate, candidate_obj)`
(`scripts/catalog-release.py:2845`) resolves the class map for authoring-time
projections: the published feed when one exists, the authored source when none
does, and an explicit equality between the two when both exist (stated rather
than left implicit in `published_artifact_feed`'s byte reproduction — mismatch
fails closed with both maps named). `cmd_emit_coordinator_rate_card` now calls it
(`scripts/catalog-release.py:3538`).

Nothing in the VERIFICATION path changed: `generate` still derives its classes
from the feed it builds from the source at the release cut, and `verify` still
derives them from the published bytes. The generation-time activation gate
already read the source
(`artifact_activation_prerequisites`, `scripts/catalog-release.py:3203`).

Regression test at the PUBLIC command boundary:
`test_emit_coordinator_rate_card_projects_a_class_only_row_pre_activation`
(`scripts/tests/test_catalog_artifact_feed.py:1982`) removes the explicit
`qwen3-8b` row from a hermetic `rate-card-source.json`, leaving the key priced
only by its authored `class-8b`, asserts no published feed exists, runs
`cmd_emit_coordinator_rate_card`, and requires the emitted block to carry the
`qwen3-8b` row, the class rates to equal the values that priced the key
explicitly, and `check_rate_card_parity` to accept the emitted block. Before the
fix this raised `recommendable candidate row 'qwen3-8b' resolves to no rate-card
row`.

### M-C — MEDIUM: `verify` did not enforce the null intake-decision transition rule

*code-reviewer M2, `scripts/catalog-release.py:3330`.*

`generate` calls `require_intake_decision`; `verify` only reconstructed the
ledger record from the CURRENT optional digest. A hand-assembled artifact-bound
release that adds a `listed` row or promotes a row to `recommendable` while
recording `intake_decision_sha256: null` — with no `intake-decision.json` for the
digest to disagree with — passed every other equality and verified clean. Ledger
validation only checks null-or-hex shape.

The rule is a TRANSITION rule, and the ledger carries only the DIGEST of the
previous release's candidate catalog, not its admission tiers. So the verdict is
reconstructible only from the same authenticated previous-release input
`generate` takes.

**Resolution.**

* `verify` takes an optional `previous_release_dir`
  (`scripts/catalog-release.py:3337`). When supplied it authenticates the
  directory with `load_previous_release` — the same trusted-keyring, manifest,
  digest, signer-equality, and ledger-row checks `generate` applies — and re-runs
  `require_intake_decision` with `previous_candidate_admission` against it,
  including the activation-release case
  (`scripts/catalog-release.py:3424-3445`). It prints
  `verified intake-decision transitions for <release> against <previous>`.
* When NOT supplied and the release is artifact-bound, `verify` prints an
  explicit `verify: NOTICE: … the intake_decision_sha256 transition rule
  (SPEC-023 §3.7.8) was NOT re-derived; pass --previous-release-dir …`. It never
  passes the rule silently.
* `--previous-release-dir` is wired onto the `verify` subparser with that
  contract in its help text (`scripts/catalog-release.py:3696`), and
  `verify-directory` now carries help stating it has no ledger and no previous
  release, so a hand-assembled staged release is checked for transitions only by
  `verify --previous-release-dir` in the repository that holds the ledger
  (`scripts/catalog-release.py:3718`).
* The runbook states the same in the post-activation flow and adds
  `verify --previous-release-dir` to the documented command sequence
  (`docs/runbooks/catalog-artifact-feed-release.md:251-252, 276-284`).

Regression test:
`test_verify_re_derives_the_intake_transition_with_the_previous_release`
(`scripts/tests/test_catalog_artifact_feed.py:1933`) activates, demotes, then
promotes a row with a real intake decision, and then hand-assembles the defect by
dropping `intake-decision.json` and the ledger row's digest TOGETHER, so every
other equality still holds. It asserts that plain `verify` prints the NOTICE and
that `verify --previous-release-dir` fails closed naming `qwen3-8b`.

### M-D — MEDIUM: five-feed compatibility-manifest acceptance was not functionally tested

*code-reviewer M3, `scripts/tests/test_catalog_artifact_feed.py:1082`.*

`test_release_json_feeds_check_accepts_both_bound_sets` only asserted a relation
between two constants. It would stay green if the five-feed branch of
`catalog_component` (`scripts/compatibility-set-manifest.py:558-594`) stopped
reading the artifact body, stopped digest-checking it, or emitted the wrong Stage
A `files` map — the exact regressions AC-CAT-15 exists to prevent.

**Resolution.** The constants test is kept, and
`test_five_feed_release_passes_the_compatibility_manifest_catalog_component`
(`scripts/tests/test_catalog_artifact_feed.py:2024`) now runs the real
`catalog_component` over a real generated five-feed release staged from the
hermetic harness. It asserts:

* acceptance, with `release_id` equal to the activation release;
* the `files` map is the EXACT unchanged nine-name set, with
  `autotune-artifacts.json` absent from it, and every entry's digest equal to the
  packaged bytes;
* failure when the artifact feed is missing from the directory while
  `release.json` binds five feeds (error names the feed);
* failure when the artifact feed's bytes are corrupted at equal length, so the
  DIGEST check is what fires (`digest does not match`), not the byte-count check.

### L-1 — LOW: a pre-activation static artifact leftover could be signed and ignored

*code-reviewer L1, `scripts/resign-autotune-static.sh:161`.*

Pre-activation rejected an unbound catalog-side artifact file, but not an artifact
body or sidecar left only under `dist/static`. The signer signed that file when
present, while `verify` omitted it from its expected set — so a release could ship
a signed feed that no manifest, ledger row, or expected-signature set accounts
for.

**Resolution.** Artifact-feed presence must AGREE across the catalog directory,
`dist/static`, `release.json`, and the ledger. The manifest and ledger sides were
already equalities; `dist/static` now is too.

* `verify` fails closed when the release publishes no artifact feed and
  `dist/static/autotune-artifacts.json` or its `.sig` exists
  (`scripts/catalog-release.py:3364-3384`).
* `resign-autotune-static.sh` refuses the same state after `generate` and BEFORE
  any signing (`scripts/resign-autotune-static.sh:77-87`), using a new
  `CATALOG_DIR` (`scripts/resign-autotune-static.sh:9`) that also sources
  `TRUSTED_KEYS`.

Tests: `test_a_pre_activation_static_artifact_leftover_fails_verify`
(`scripts/tests/test_catalog_artifact_feed.py:2063`, both the body and the
sidecar) and `test_the_signer_refuses_a_pre_activation_static_artifact_leftover`
(`scripts/tests/test_catalog_artifact_feed.py:2081`), which pins the shell guard
between the `generate` call and the first `sign_one`.

### L-2 — LOW: Stage A serving status was contradictory

*code-reviewer L2, `docs/runbooks/catalog-artifact-feed-release.md:276`.*

Stage A was described as already "served" while lines 68–78 and 271 said serving
remains a 2b/2c prerequisite, which can misstate activation readiness.

**Resolution.** The runbook now says this slice **generates, signs, binds, and
records** the feed, and reserves "served" for 2b/2c completion:
`docs/runbooks/catalog-artifact-feed-release.md:23-27` (the published-outputs
paragraph, which named the serving routes as present tense) and
`docs/runbooks/catalog-artifact-feed-release.md:298-301` (the Stage A paragraph).

## Carried items

1. **CI post-activation `verify` has no previous-release snapshot.** CI runs
   `python3 scripts/catalog-release.py verify` with no `--previous-release-dir`,
   so once a release is artifact-bound that job will print the M-C NOTICE rather
   than re-derive the §3.7.8 transition rule. Wiring a previous-release snapshot
   into that job belongs with the FIRST activation release cut, when an
   artifact-bound release directory exists to snapshot; until then the
   enforcement point is the operator `generate` run, which fails closed, and
   `verify` states the gap explicitly instead of passing silently. Recorded in
   the runbook's activation section
   (`docs/runbooks/catalog-artifact-feed-release.md:285-292`).
2. **Security lane owes a verdict.** See "R3 verdicts": the R3 security run
   failed at the provider and returned nothing. R4 must re-run it over the full
   combined diff.
3. **Consumer-side AC-CAT-2/7/12 are out of slice 2a** (carried from R3
   code-reviewer's positive observations): this branch is not evidence that the
   first artifact-bound release is consumer-ready. Serving, packaging, the live
   release gate, and the coordinator routes are slices 2b/2c.

## Files changed in R3

| File | Change |
|---|---|
| `scripts/catalog-release.py` | exact Go `math.Round` port; `authoring_rate_classes`; source-aware `emit-coordinator-rate-card`; `verify --previous-release-dir` + transition NOTICE; static artifact-feed presence agreement; `verify-directory` help |
| `scripts/resign-autotune-static.sh` | `CATALOG_DIR`; pre-signing refusal of an unbound `dist/static` artifact body or sidecar |
| `scripts/tests/fixtures/rate_global_rounding_cases.json` | nextafter boundary vectors around every half-unit product; `floor_half_add_divergence` flag |
| `scripts/tests/test_catalog_artifact_feed.py` | six new tests (rounding port, emitter pre-activation, `verify` transitions, functional five-feed manifest, static leftover ×2) |
| `docs/runbooks/catalog-artifact-feed-release.md` | serving wording; `verify --previous-release-dir` step; CI carried item |
| `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_R3.md` | this record |

`phase4-coordinator/internal/billing/rate_global_rounding_cases_test.go` is
unchanged: it reads the shared table, so the widened vectors bind Go without a
Go-side edit.

## Verification

| Command | Result |
|---|---|
| `python3 scripts/catalog-release.py verify` | pass — `published-2026-09-02-gpt-oss-120b-v1` |
| `bash scripts/test-catalog-release.sh` | PASS |
| `bash scripts/test-renew-autotune-static-feed-signed.sh` | ok |
| `bash scripts/test-compatibility-set-manifest.sh` | ok |
| `python3 -m unittest scripts.tests.test_catalog_artifact_feed scripts.tests.test_spec_governance` | 165 tests, OK |
| `go test ./internal/billing -count=1` | ok |
| `python3 scripts/check_spec_governance.py` | SPEC governance validation passed |
| `python3 scripts/gen_spec_index.py --lint` | ok |
| `git diff --check` | clean |

Test count moved 159 → 165: 113 → 119 in `test_catalog_artifact_feed` (six new),
46 unchanged in `test_spec_governance`.
