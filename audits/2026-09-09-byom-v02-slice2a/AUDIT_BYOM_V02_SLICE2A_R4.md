# Audit R4 — BYOM v0.2 slice 2a: catalog artifact-feed generator, class rate expansion, ledger v3

**Branch:** `feat/byom-v02-slice2a-artifact-feed-generator`
**Date:** 2026-09-09
**Prompt:** `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_PROMPT.md`
**Predecessors:** `AUDIT_BYOM_V02_SLICE2A_R1.md`, `AUDIT_BYOM_V02_SLICE2A_R2.md`,
`AUDIT_BYOM_V02_SLICE2A_R3.md` (same directory)
**Authority:** SPEC-023 v0.10.0 §3.2, §3.3.1, §3.5, §3.7.1–§3.7.8, §11 AC-CAT-1…19, §15, §16.8;
SPEC-047-R003 (0.1.3); SPEC-005 §5.5.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R4 verdicts (full six-commit diff `origin/main...HEAD`, rebased)

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 1 LOW / 0 INFO — REQUEST CHANGES |
| security-reviewer | **0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 0 INFO — merge bar satisfied** |
| architect | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 0 INFO |

The security lane, which failed at the provider in R3, completed in R4 and is
at the bar. All R1 (F1–F8), R2 (G1–G6), and R3 (M-A…) resolutions were
re-confirmed by every lane; no earlier finding regressed. Every R4 finding
below is NEW and each is resolved in the commit that adds this record.

## Four-round stop

R4 is the fourth anchored codex round on this branch. Per the standing rule
(an anchored loop validates its own framing after 3–4 rounds), the codex loop
STOPS here: the three R4 MEDIUMs are concrete and are fixed and tested below,
but the fixes are **not** re-fed to the same lanes. Closure of slice 2a is
delegated to the independent `/code-review ultra` review of the pull request,
which sees the full diff including this round's fixes. Any finding that review
raises is fixed on the PR before it leaves draft.

## Findings and resolutions

### N1 — MEDIUM: post-activation source/feed `rate_class` comparison was tautological

*code-reviewer M1, `scripts/catalog-release.py` `authoring_rate_classes`.*

`published_artifact_feed()` re-derived the published feed from
`autotune-artifacts-source.json`, so `authoring_rate_classes()` compared the
source's class map with a map built from the same source. The "published feed
must agree with the source" equality could never fail, and
`emit-coordinator-rate-card` could project source classes that the committed,
signed feed does not bind.

**Resolution.** New `published_feed_rate_classes()` reads the class map from the
committed `autotune-artifacts.json` BYTES (schema closure + model validation
only — release binding stays `verify`'s job, and is legitimately stale between
`restamp` and the next `generate`). `authoring_rate_classes()` now takes no
arguments and compares the authored source against those bytes. Regression:
`HermeticReleaseTest.test_emit_coordinator_rate_card_reads_published_classes_from_the_feed_bytes`
activates a scratch release, edits the source's `rate_class`, and requires both
the emitter (`must agree`) and `verify` (`generated drift`) to fail closed.

### N2 — MEDIUM: freshness-renewal continuity guards omitted the artifact feed

*code-reviewer M2, `scripts/renew-autotune-static-feed.sh` pre-deploy loop and
under-lock recheck.*

Both dates-only guards compared only candidate, demand, and rate-card feeds. A
post-activation change confined to `autotune-artifacts.json` `models` — or the
feed appearing or disappearing — would have deployed through the scheduled
freshness path instead of a deliberate catalog release.

**Resolution.** The rules now live in the generator as
`feed_continuity_drift()` / `catalog-release.py continuity-check --incoming
--live`: candidate/demand/rate-card compared with `version` + `generated_at`
stripped; the artifact feed compared by PRESENCE and by content with
`version`, `release_id`, `generated_at`, `candidate_catalog_sha256` stripped.
The script's pre-deploy check snapshots the live feeds (artifact feed fetched
only when present, with an explicit present/absent probe so an SSH failure
cannot read as "absent") and calls the subcommand; the under-lock recheck on
Pearl mirrors the same rules inline (Pearl has no checkout) and is
text-asserted by `scripts/test-renew-autotune-static-feed-signed.sh` to run
before the release directory is installed. Regression:
`RenewalFlowTest.test_continuity_check_covers_the_artifact_feed_by_presence_and_content`
(restamp passes; model drift fails; presence mismatch fails in both directions;
candidate drift still fails).

### N3 — MEDIUM: class-derived rate rows could be published under a non-normalized key

*architect, `expand_rate_card` / `validate_rate_card_source`.*

Explicit-row lookup normalized correctly, but a class row for a key with no
explicit row was written under the raw artifact-feed spelling, and the source
validator checked only key grammar. Billing resolves exact spelling before
`NormalizeModelKey`, so a class row under `vendor/model` would make `model` and
`vendor/model` — one model — resolve to different rows. The committed release
is unaffected (the one differently-spelled key resolves through its explicit
normalized row) and the committed rate-card bytes are unchanged.

**Resolution.** `validate_rate_card_source` requires every non-`default` row
key to be its own `NormalizeModelKey` fixed point (all 12 committed rows are);
`expand_rate_card` materialises class rows under the normalized key, decides
explicit-row precedence against the SOURCE rows only, and fails closed when two
artifact keys normalize to one key but declare different classes. Regressions:
`test_source_rows_must_be_normalized_keys`,
`test_class_expansion_materialises_under_the_normalized_key`,
`test_conflicting_classes_under_one_normalized_key_fail_closed`;
`test_committed_source_reproduces_the_published_rows_byte_for_byte` (AC-CAT-10)
still passes.

### L1 — LOW: renewal runbook and script comment kept pre-activation file counts

*code-reviewer L1 / architect L1.* `docs/runbooks/autotune-feed-renewal.md` and
the script's section comment now state three signed feeds / nine files for a
rate-card-bound release and four / eleven once artifact-bound.

### L2 — LOW: rate-global parity accepted values outside the coordinator int64 domain

*security-reviewer L1.* `scaled_nonnegative_integer` now fails closed when the
Go-parity integer exceeds `INT64_MAX` (Go's float64→int64 conversion is
implementation-defined out of range). `global_multiplier_ppm` in the source was
already bounded by `strict_json`, which rejects any integer outside the signed
64-bit range at parse time; a test now pins that.
Regressions: `RateGlobalsTest.test_scaled_conversion_rejects_values_outside_the_int64_domain`,
`RateCardSourceTest.test_global_multiplier_ppm_is_bounded_to_the_coordinator_int64_domain`.

## Validation after the R4 fixes

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_catalog_artifact_feed scripts.tests.test_spec_governance` — 172 tests, OK
- `python3 scripts/catalog-release.py verify` — committed release unchanged, verified
- `bash scripts/test-catalog-release.sh` — PASS
- `bash scripts/test-renew-autotune-static-feed-signed.sh` — ok
- `bash scripts/test-compatibility-set-manifest.sh` — ok
- `python3 scripts/check_spec_governance.py` — passed
- `git diff --check` — clean

Candidate catalog, `release.json`, `release-ledger.json`, `rate-card.json`, and
`dist/static/*` are untouched by this round.
