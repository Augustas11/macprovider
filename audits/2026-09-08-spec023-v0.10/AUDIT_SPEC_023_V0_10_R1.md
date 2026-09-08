# SPEC-023 v0.10.0 — audit round R1

**Date:** 2026-09-08
**Branch:** `spec/023-catalog-artifact-sets-class-rates`
**Audited commit:** `8d5b5505` — "spec(023): v0.10.0 catalog artifact sets, class rate rows, listed-tier intake (BYOM v0.2 prerequisite)"
**Scope:** full branch diff `git diff origin/main...HEAD` — `specs/SPEC-023-installer-autotune-recommend.md`, `specs/SPEC-047-network-model-admission.md`, `specs/CONFORMANCE.json`, `specs/README.md`
**Prompt:** [`AUDIT_SPEC_023_V0_10_PROMPT.md`](AUDIT_SPEC_023_V0_10_PROMPT.md)
**Lanes:** three codex lanes (code-reviewer, security-reviewer, architect), each over the complete diff as it will land.
**Bar:** 0 CRITICAL, 0 HIGH, 0 MEDIUM.

## R1 verdicts

| Lane | Verdict | Result |
|---|---|---|
| code-reviewer | `0 CRITICAL / 0 HIGH / 3 MEDIUM / 1 LOW / 0 INFO` | REQUEST CHANGES |
| security-reviewer | `0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 1 INFO` | Risk level MEDIUM |
| architect | `0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 1 INFO` | Blocking on the intake-signal bound |

All three lanes converged on the same blocking MEDIUM: the new unknown-model demand signal was privacy-redacted and thresholded but not cardinality-bounded. The remaining findings were lane-specific.

Lane artifacts (local, untracked, `.omc/artifacts/ask/`):

- code-reviewer — `codex-spec-audit-...-2026-09-08T13-16-00-966Z.md`
- security-reviewer — `codex-spec-audit-...-2026-09-08T13-17-35-202Z.md`
- architect — `codex-spec-audit-...-2026-09-08T13-19-02-182Z.md`

## Findings and resolutions

### F1 — MEDIUM (all three lanes): `unmatched_model_request_count` lacks a bounded-cardinality contract

**Reported at:** SPEC-023 §16.2(a) (`:1607`, `:1624–1627`, `:1651`, `:1682`), AC-CAT-12 (`:1292`).

**Finding.** The signal was defined as buyer requests aggregated "per normalized requested model key" under SPEC-017 redaction rules, and could admit a key to `listed` on crossing `INTAKE_BUYER_REQUEST_FLOOR` (default 250). §16.7 delegated wire shape, redaction, k-anonymity floor, rollup window, and endpoint to SPEC-017. The requested model string is buyer-controlled, so nothing in the handoff bounded key length, bucket count, normalization grammar, top-N retention, overflow handling, or per-principal contribution. That left an implementation path in which attacker-chosen model strings create unbounded rollup buckets (storage and parser-work pressure) or in which one principal walks one chosen key over the floor. The architect lane named the root cause precisely: ownership was split across the SPEC-023/SPEC-017 boundary without carrying the safety invariant across with it.

**Resolution.** SPEC-023 §16.2(a) now carries a normative nine-item field contract for the signal, stated in SPEC-023 rather than deferred:

1. eligible requests only — auth-valid, non-test buyer requests; anything unauthenticated, rejected before model resolution, or flagged test/synthetic/internal contributes to no bucket;
2. SPEC-005 `NormalizeModelKey` normalization BEFORE any bucket is created or incremented; the raw buyer string is never a bucket key and is never persisted;
3. a closed normalized-key grammar and byte limit — `[a-z0-9._/-]{1,128}`, matched in full, or the key gets no named bucket;
4. at most `INTAKE_UNKNOWN_KEY_BUCKETS` named buckets per rollup window (default `64`, operator-configured), retained by count and enforced **at ingest**, so per-window key-tracking work is bounded by that constant rather than by distinct-key volume;
5. one `other_suppressed` overflow bucket per window carrying a request count and a distinct-key count only — never key material;
6. a per-principal contribution cap per bucket per window — buyer account, partner key, or source class — of `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` of `INTAKE_BUYER_REQUEST_FLOOR` (default `10%`, i.e. 25 requests at the default floor of 250), excess discarded, no per-principal breakdown emitted or retained;
7. below-k-anonymity suppression, matching the §16.2(b) treatment of `distinct_provider_offer_count`;
8. suppressed, overflow, and capped contributions MUST NOT satisfy `INTAKE_BUYER_REQUEST_FLOOR` — the floor is cleared only by a named bucket's post-cap, post-suppression count;
9. no per-request rows and no buyer identity at any stage; the item-6 principal counter is window-scoped, never emitted, and never joined to an intake record.

Supporting changes:

- **§16.4** gains two knob rows with defaults and rationale — `INTAKE_UNKNOWN_KEY_BUCKETS` = `64`, `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` = `10%`. At the default floor the cap means clearing it requires at least ten independent principals.
- **§16.7** keeps the ownership sentence (SPEC-017 owns wire shape, endpoint, rollup window, and the k-anonymity floor value) and adds that the safety invariants do not travel away with it: **SPEC-017 MUST adopt this exact contract by amendment before the signal may satisfy any intake floor**, until then the signal is absent for intake even if a field of that name is emitted, and SPEC-017 may specify a stricter bound but never a weaker one.
- **AC-CAT-13** (new, `SPEC-023-R006`) tests every clause, including that a single principal generating any volume for one key never clears the floor, that fanout beyond the bucket bound creates no additional per-window tracking work, and that a field of this name satisfies no floor before the SPEC-017 amendment.
- **§15** gains an "Unknown-model-key fanout" threat row covering key-fanout storage pressure, signal burial, and single-account floor-walking.

### F2 — MEDIUM (code): artifact feed schema not explicitly closed

**Reported at:** SPEC-023 §3.7.3 (`:629`).

**Finding.** §3.7.3 showed the feed shape and §3.7.4 closed several enums, but nothing stated that unknown fields are rejected. AC-CAT-1 treated invalid schema as an integrity failure without making "unknown field = invalid schema" testable.

**Resolution.** §3.7.3 now states the schema is CLOSED at every level and gives explicit REQUIRED/OPTIONAL field sets with JSON types for the top-level object, `models.<model_key>`, `artifacts.<artifact_id>`, and each `source_ref.kind` variant (`huggingface_revision`, `ollama_library_tag`). Unknown, missing, or wrong-typed fields are `catalog_artifact_feed_integrity_failure` (§3.7.6 class 2). The section states why there is no "ignore unknown keys" mode here: the feed is release-bound, so an unrecognised field means consumer and feed disagree about the release, which is exactly the fail-closed condition. A `source_ref` with an unknown `kind`, or one variant's fields under the other's `kind`, is a schema failure. The generator MUST apply the same closed sets before signing and fail the release closed rather than dropping the field. **AC-CAT-1** is renamed "feed trust and closed schema" and now tests each object level with one unknown field, one missing REQUIRED field, and one wrong-typed field, explicitly noting that a valid signature over those bytes rescues none of them.

### F3 — MEDIUM (code): `declared` artifacts "MAY inform intake" contradicts §16.1 P1 / AC-CAT-11

**Reported at:** SPEC-023 §3.7.4 (`:702`).

**Finding.** §3.7.4 said a `declared` artifact "MAY be displayed and MAY inform intake", while §16.1 P1 requires a `verified` artifact before any tier admission and AC-CAT-11 admits a key lacking one at no tier. The wording was implementable as a loophole into `listed`.

**Resolution.** Narrowed to: a `declared` artifact MAY appear in operator backlog and review material only, and MUST NOT satisfy the §16.1 P1 precondition, MUST NOT contribute to admission at any tier, MUST NOT satisfy SPEC-047 `catalog_matched`, MUST NOT support `catalog_priced` or `settlement_capable`, MUST NOT be priced, and MUST NOT be downloaded or prepared as a catalog artifact. Adds the explicit consequence: a key whose artifacts are all `declared` is admitted at no tier, cross-referencing §16.1 and AC-CAT-11.

### F4 — LOW (code): duplicate `Q1` in §13

**Reported at:** SPEC-023 §13 (`:1525`).

**Finding.** The v0.10.0 annotation was added as a second `Q1`, leaving two `Q1` anchors and making future cross-references ambiguous.

**Resolution.** The new item is renamed `Q1a` ("**[new v0.10.0, partially answering Q1]**"). The original Q1 paragraph is unchanged and every other Q number is stable — `Q12`, `Q13`, `Q14`, `Q15`, `Q16` all keep their existing identifiers.

### F5 — LOW (security): SPEC-047 GGUF boundary less explicit than SPEC-023

**Reported at:** SPEC-047 `:115`, against SPEC-023 `:732`, `:1282`.

**Finding.** SPEC-047-R003's v0.1.3 amendment said a non-SPEC-010-named `hash_algorithm` MUST NOT reach `settlement_capable`, without saying it also MUST NOT reach `catalog_priced`. An implementer could read SPEC-047 alone as permitting priced economics display for GGUF artifacts.

**Resolution.** The SPEC-047-R003 amendment now reads: an artifact whose `hash_algorithm` is not a canonical wire pair named by SPEC-010-R002 MUST NOT reach `catalog_priced` or `settlement_capable`, and MUST NOT be used as the SPEC-010 `model_hash`/`model_hash_algorithm` pair or as a SPEC-022 route-time settlement binding — so a `macprovider.gguf-file.v1` artifact may reach `catalog_matched`, `sandbox_probe_only`, and `network_visible_unpriced` but neither `catalog_priced` nor `settlement_capable`. The same wording is mirrored in SPEC-023 §3.7.7, whose requirement sentence previously named only the SPEC-010 wire pair and the SPEC-022 binding. The SPEC-047 v0.1.3 changelog entry is updated to match.

### F6 — LOW (architect): SPEC-047-R002 duplicated offer-package MUST-list — **CARRIED (pre-existing)**

**Reported at:** SPEC-047 `:109` and `:113`.

**Finding.** SPEC-047-R002 states the v0.1 offer-package MUST-list twice. The earlier list, inside the requirement paragraph, omits signing key id/digest and signature algorithm; the later standalone paragraph repeats the schema and adds those plus the SPEC-001/SPEC-026 current-admission-key authority. The stricter paragraph resolves the security boundary, so this is not a settlement flaw, but the duplicate MUST-list is an implementer ambiguity.

**Disposition: CARRIED — pre-existing on `origin/main`, not introduced or worsened by this branch.** Both paragraphs predate v0.1.3; this branch amends only the later, stricter one (adding "catalog match if any under the SPEC-047-R001 `catalog_matched` definition"). Restructuring a requirement that is not this revision's subject would exceed the minimal-amendment scope this revision holds itself to.

**Mitigation applied.** A citation-only note is added after the new `catalog_matched` paragraph naming **the later, stricter paragraph as the authoritative offer-package schema** where the two lists differ, stating that the earlier list is a partial restatement that never relaxes it, and recording that the duplication predates v0.1.3 and is carried unchanged. Consolidating the two lists is a SPEC-047 editorial revision for a later pass.

## Carried items

| Item | Lane | Severity | Why carried |
|---|---|---|---|
| F6 — SPEC-047-R002 duplicated offer-package MUST-list | architect | LOW | Pre-existing on `origin/main`; not introduced or worsened here. Authority between the two lists is now cited explicitly; consolidation deferred to a SPEC-047 editorial revision. |
| `govulncheck` reachable findings in `phase7-verify` under local Go `1.26.4` | security | INFO | Toolchain artifact, not a branch finding. Repo target is Go `1.26.6` and this branch changes no dependency files. Re-run under the target toolchain before release. |

## Verification after fixes

```
python3 scripts/gen_spec_index.py --lint
python3 scripts/gen_spec_index.py --check
python3 scripts/check_spec_governance.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_spec_governance
python3 scripts/catalog-release.py verify
git diff --check
```

Results are recorded in the fix commit message and the handoff report. The revision remains docs-and-governance only: no catalog JSON, no generator code, and no Go/Swift code changes on this branch.

## Round status

R1 findings: 5 resolved (3 MEDIUM, 2 LOW), 1 carried as pre-existing LOW (F6) with the authority ambiguity cited in-spec. R2 re-audit runs all three lanes over the complete combined diff — commit `8d5b5505` plus this fix commit — not the fix slice alone.
