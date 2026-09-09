# SPEC-023 v0.10.0 — audit round R3

Branch: `spec/023-catalog-artifact-sets-class-rates`
Scope: `git diff origin/main...HEAD` — `specs/SPEC-023-installer-autotune-recommend.md`,
`specs/SPEC-047-network-model-admission.md`, `specs/CONFORMANCE.json`, `specs/README.md`.
Method: three independent codex lanes over the COMPLETE branch diff (not the R2 delta),
cross-checked against SPEC-005 §5.5, SPEC-010 (~975–1010), SPEC-022, SPEC-032 FR-HG3/FR-HG4,
SPEC-044 §2, SPEC-046-R002/R003, `scripts/catalog-release.py`, `AutotuneStrictJSON.swift`,
`CompatibilitySetManifest.swift`, and `phase3-binary/catalog/autotune/*.json`.

## Verdicts

| Lane | Verdict | Recommendation |
|---|---|---|
| code review | 0 CRITICAL / 1 HIGH / 2 MEDIUM / 2 LOW / 0 INFO | REQUEST CHANGES |
| architecture | 0 CRITICAL / 2 HIGH / 2 MEDIUM / 1 LOW / 0 INFO | does not meet lock bar |
| security | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW / 1 INFO | two normative inconsistencies remain |

Deduplicated across lanes: **2 HIGH, 4 MEDIUM, 2 LOW, 1 INFO (carried).**
Bar for the round: 0 CRITICAL / 0 HIGH / 0 MEDIUM. All eight actionable findings are resolved
in this round; the INFO item is carried as pre-existing and out of scope.

## Findings and resolutions

### R3-F1 — HIGH: the §3.7 introduction and the changelog still authorized non-primary settlement

Lanes: code HIGH, architecture HIGH-1, security MEDIUM-1 (same defect, three severities).

The §3.7 opening thesis said two artifacts of one model key "are priced identically and settle
against different hashes," and changelog point 1 said "Settlement binds to an artifact hash …
Only `verified` artifacts may bind settlement." Both predate the R2 resolution and contradict it.
R2 restricted `catalog_priced` / `settlement_capable`, the SPEC-010 wire pair, and SPEC-022
bindings to the primary artifact (§3.7.4, §3.7.7 R004, AC-CAT-17, SPEC-047-R003). An implementer
reading the section's framing rather than its later requirements could admit a secondary MLX
quantization or a GGUF artifact as a settlement identity, which SPEC-010-R001/R004 exclude.
Severity is driven by where the sentence sits: it is the architectural thesis of the section, and
the defect is at a money-path identity boundary.

**Resolved.** §3.7 introduction (SPEC-023:633–637) rewritten as three paragraphs: pricing is
model-key scoped; settlement identity is artifact-scoped and, in v0.10.0, primary-only, naming the
primary artifact's four conditions explicitly; every non-primary artifact of any format is a
matchable identity that stays unpriced and non-settling pending the SPEC-010 amendment (§13 Q14);
and one `(hash_algorithm, hash)` pair belongs to exactly one model key. The introduction now also
tells the reader how to read every later "settlement binds the artifact hash" sentence — those say
which fields a binding records, never that a non-primary artifact may be bound. Changelog point 1
(SPEC-023:11) rewritten to the same rule and to "`verified` is necessary but never sufficient for
settlement." The §3.7.4 bullet formerly headed "Only `verified` may bind settlement" is retitled
to say `verified` is necessary for every artifact-derived capability and never sufficient for
settlement, with a pointer to the primary-only bullet that follows it.

**Sweep.** `grep -n "settle against different\|each artifact.*settle\|priced identically and settle"`
over both specs is empty. A full scan of every `settle`/`settlement` occurrence in both specs was
read line by line; no remaining sentence implies a non-primary artifact may settle.

### R3-F2 — HIGH: an artifact hash did not resolve to one pricing identity

Lane: architecture HIGH-2.

SPEC-047 0.1.3 defines `catalog_matched` by verified `(hash_algorithm, hash)` and treats a
provider-supplied `catalog_model_key` as insufficient authority, while pricing resolves by model
key (§3.3, §3.3.1). Nothing rejected or resolved the case where one verified pair appears beneath
two model keys carrying different rate rows: identical bytes could match two pricing identities
with no normative canonical choice, so settlement-adjacent behavior would depend on an
implementation's tie-break. The generator's existing conflicting-hash check does not supply the
invariant — `scripts/catalog-release.py` rejects two DIFFERENT `model_sha256` values under one
normalized `model_id`, and says nothing about one hash under two model identities.

**Resolved.** §3.7.4 gains a normative **global artifact-hash uniqueness** bullet: within one
artifact feed a `(hash_algorithm, hash)` pair MUST appear under exactly one model key and exactly
one `artifact_id`; a duplicate is `catalog_artifact_feed_integrity_failure`, rejected by the
generator before signing and by the consumer before any artifact from that feed binds anything.
The bullet states explicitly that this is a NEW check, names the existing candidate-catalog check
it does not subsume, and states the consequence: a verified pair resolves to exactly one
`(model_key, artifact_id)`, that resolved key is the pricing identity, and a provider-offered
`catalog_model_key` is advisory and MUST equal the resolved key or the match fails closed.
Mirrored in §3.7.7 R004, in §16.1 P4, in the §15 artifact-substitution row, in the SPEC-047-R001
`catalog_matched` amendment, in SPEC-047-R003, and in the SPEC-047 0.1.3 changelog entry. New
acceptance case **AC-CAT-18** covers the duplicate under two keys with differing rate rows, the
duplicate twice under one key, the advisory-key equality rule, and the both-checks-run assertion.

### R3-F3 — MEDIUM: `candidate` all-declared staging contradicted unscoped MUSTs

Lanes: code MEDIUM-1, architecture MEDIUM-1.

R2 made the ladder and AC-CAT-5 permit a `candidate` row whose artifact entries are all
`declared`, and scoped §3.7.5 accordingly. Three rules stayed unscoped and contradicted it: the
§3.7.4 field rule requiring every `primary_artifact_id` to name a `verified` artifact, the §3.7.4
"a key whose artifacts are all `declared` is admitted at no tier" sentence, AC-CAT-11's "a key
lacking any `verified` artifact is admitted at no tier," and §16.1's "no model key may be admitted
at any tier." A conforming generator could not satisfy both contracts.

**Resolved.** The verified-primary requirement is now status-scoped in §3.7.4: `primary_artifact_id`
MUST always name an `mlx_safetensors` entry whose `source_ref.repo_id`, `source_ref.revision`,
`hash_algorithm`, and `hash` correspond to the row's `model_id`, `model_revision`,
`macprovider.snapshot-manifest.v1`, and `model_sha256`; the `verified` status is required only for
a row entering or held at `listed` or `recommendable`, and MAY remain `declared` for a `candidate`
row. Staging permits an unconfirmed hash, never an unnamed, absent, or mismatched primary artifact.
§16.1's preamble is scoped to entry into `listed` (and transitively `recommendable`) and states
that the preconditions do not govern authoring a `candidate` row; P1 carries the same scoping.
§3.2's scoping rule 1 now covers the §3.7.4 field rule as well as the §3.7.5 check, and the ladder
table's `candidate` row states the identity-correspondence requirement alongside the all-`declared`
permission, so the table and AC-CAT-5 agree. AC-CAT-5 and AC-CAT-11 are updated to assert the same
boundary in both directions: an all-`declared` `candidate` row is valid and warning-free, and a
`candidate` row whose primary artifact is absent, wrong-format, or identity-mismatched still fails
closed at generation.

### R3-F4 — MEDIUM: principal caps were not integrated into the Space-Saving update order

Lane: code MEDIUM-2.

§16.2(a) item 4 updated the named summary "on an eligible request," while items 7–9 required
capped and overflow-principal contributions to reach `other_suppressed` only and never affect a
bucket's floor count. No processing order said those contributions bypass the item-4 increment, so
two literal implementations could disagree about whether capped traffic enters `count` and
`count - error`, breaking AC-CAT-13's single-principal invariant.

**Resolved.** §16.2(a) gains a normative **per-request processing order** after item 10, with five
binding steps and an explicit no-later-step-after-routing rule:

- **S1 — eligibility and authentication filter (item 1).** An ineligible request contributes to
  nothing at all — not a named bucket, not `other_suppressed`.
- **S2 — normalization (item 2).** `NormalizeModelKey` before any bucket exists.
- **S3 — grammar and byte-limit check (item 3).** An out-of-grammar or over-long key contributes
  to `other_suppressed` (item 6) only; the pipeline stops.
- **S4 — principal derivation and cap check (items 7 and 8).** Derive the opaque window-scoped
  token, check the per-bucket principal bound and the per-principal cap; a capped or
  overflow-principal contribution goes to `other_suppressed` only and MUST NOT reach S5.
- **S5 — Space-Saving update (item 4).** Only an S1-through-S4 survivor performs the item-4
  update and increments its item-8 principal counter.

The order closes with the disqualifying anti-pattern named explicitly: incrementing a named entry
first and subtracting capped traffic afterwards does not conform, because the item-5 lower bound
would then have counted traffic the floor rules forbid. Item 4's lead-in is rewritten from "on an
eligible request" to "on an intake-eligible contribution — a request that has passed steps S1
through S4 … which is the only point at which this update runs." AC-CAT-13 asserts the order step
by step and names the failing anti-pattern.

### R3-F5 — MEDIUM: stable `artifact_id` had no grammar and no historical authority

Lane: architecture MEDIUM-2.

`artifact_id` was declared stable and forbidden from rebinding to new bytes, and the §15 threat
model relied on that prohibition as the substitution defense — but the id had no closed grammar or
length bound beyond "lowercase," no prior-feed or registry input was named for the generator, the
release ledger recorded feed bindings rather than `(model_key, artifact_id) → (algorithm, hash)`
history, and no acceptance case covered removal/reintroduction or cross-release rebinding. The
requirement was not reproducibly enforceable from the named release inputs.

**Resolved.** The §3.7.4 bullet is replaced with a three-paragraph normative rule:

1. **Grammar.** `artifact_id` MUST match `^[a-z0-9][a-z0-9-]{0,63}$` in full — lowercase ASCII
   letters, digits, hyphens, alphanumeric first character, 1–64 characters. Any other value is
   `catalog_artifact_feed_integrity_failure` at generation and at consumption.
2. **Cross-release rebinding check.** The generator MUST take the previous release's signed
   artifact feed as an input alongside the release ledger, and MUST fail the release closed when
   any `(model_key, artifact_id)` present in both feeds carries a `(hash_algorithm, hash)`
   differing from its prior binding. New bytes require a NEW id; the old id is retired by
   publishing it with `verification_status: "blocked"` and MUST NOT be reintroduced with different
   bytes. Removal is explicitly not an escape hatch: appear → absent → reappear-with-different-bytes
   is a rebinding and fails closed exactly as an in-place change does.
3. **Durable authority.** §3.7.8's release-binding paragraph now requires the artifact-bound
   feed-set ledger row to record every `(model_key, artifact_id, hash_algorithm, hash)` binding the
   feed publishes, so the verdict is reconstructible from named release inputs alone — the ledger
   plus the previous release's signed feed bytes — and auditable without trusting the generator
   that produced the release.

Mirrored in §3.7.7 R004 and in the §15 artifact-substitution row. New acceptance case
**AC-CAT-19** covers grammar rejection (uppercase, underscore, leading hyphen, empty, 65 chars),
in-place rebinding, the valid new-id-plus-blocked-retirement path, removal-and-reintroduction, and
auditor reproducibility from the ledger plus the previous signed feed.

### R3-F6 — MEDIUM: GGUF `source_ref.digest` was not bound to the artifact `hash`

Lane: security MEDIUM-2.

For `gguf`, both `source_ref.digest` and `hash` were described as the SHA-256 of the same bytes,
but no MUST required `source_ref.digest == "sha256:" + hash`. The closed identity matrix validates
types and enum combinations, not value consistency, so a correctly signed feed could bind two
incompatible identities to one artifact — the source reference naming one blob while catalog
matching trusted another digest. Blast radius in v0.10.0 is bounded to unpriced visibility and
probes (a GGUF artifact is never primary and therefore never settles), which is why the lane rated
it MEDIUM rather than HIGH.

**Resolved.** §3.7.4 gains a normative **GGUF source-digest equality** bullet: for `runtime_format
== "gguf"`, `source_ref.digest` MUST equal `"sha256:" + hash` — the same 64-hex lowercase digest,
prefixed. A mismatch is `catalog_artifact_feed_integrity_failure`, rejected by the generator before
signing and by the consumer **before** the artifact may satisfy `catalog_matched` or any other
artifact-derived capability. The bullet states that the matrix cannot express value-level equality,
so the two rules are complementary rather than redundant. Mirrored in §3.7.7 R004 and in the §15
artifact-substitution row. **AC-CAT-16** is extended with the mismatch cases (differing digest,
missing `sha256:` prefix, uppercase digest, digest naming a different blob) asserted to fail at
consumption before `catalog_matched` and at generation before signing, plus the positive case.

### R3-F7 — LOW: overflow `request_count` double-counted inherited Space-Saving error

Lane: code LOW-1.

A Space-Saving replacement entry inherits `victim_count` as its `error`, while item 6 added "every
count evicted" to `other_suppressed`. On a later eviction the inherited count was added a second
time, inflating the diagnostic `request_count`. It cannot satisfy an intake floor and is bounded by
saturation, hence LOW.

**Resolved.** Item 6 now absorbs the **non-inherited** part of an eviction, `victim_count -
victim_error`, with the reason stated inline: the inherited `error` was already absorbed when the
entry it came from was evicted and MUST NOT be added a second time. S5 of the processing order
states the same transfer. AC-CAT-13 asserts that a count inherited through a chain of evictions is
added to `other_suppressed.request_count` exactly once.

### R3-F8 — LOW: stale intake item cross-references after the R2 renumbering

Lanes: code LOW-2, architecture LOW-1.

§16.2(a) item 3 sent invalid normalized keys to `other_suppressed` "item 5" when that bucket is
item 6, and §16.4's `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` row pointed at "item 6" when the
principal cap is item 7.

**Resolved.** Both corrected. Every `item N` / `item-N` / `items N and M` reference in the file was
then re-enumerated with surrounding context and checked against the ten numbered items: item 1
eligibility, item 2 normalization, item 3 grammar, item 4 Space-Saving, item 5 lower bound, item 6
`other_suppressed`, item 7 principal cap, item 8 principal cardinality, item 9 suppression, item 10
no-identity. All references now resolve correctly, including the four inside AC-CAT-13 and the four
in the §16.4 knob table.

## Changes made

- `specs/SPEC-023-installer-autotune-recommend.md`
  - changelog point 1 (line 11) — primary-only settlement rule, `verified` necessary-not-sufficient,
    uniqueness invariant.
  - changelog point 9 (new) — records the R3 closures.
  - §3.2 ladder table `candidate` row, `candidate` scoping rule 1 — staging scope.
  - §3.7 introduction — three-paragraph rewrite (F1).
  - §3.7.4 — status-scoped `primary_artifact_id` rule (F3); global artifact-hash uniqueness bullet
    (F2); GGUF source-digest equality bullet (F6); `artifact_id` grammar / rebinding / ledger
    authority (F5); `verified`-bullet retitle and all-`declared` wording (F1, F3).
  - §3.7.7 `SPEC-023-R004` — uniqueness, GGUF digest equality, `artifact_id` grammar and history.
  - §3.7.8 release binding — ledger row records every
    `(model_key, artifact_id, hash_algorithm, hash)` binding.
  - §15 artifact-substitution threat row — restated mitigations.
  - §16.1 — preamble and P1 scoped to entering `listed`; P4 carries the uniqueness invariant.
  - §16.2(a) — item 3 reference fix, item 4 lead-in, item 6 eviction transfer, per-request
    processing order S1–S5.
  - §16.4 — principal-cap knob item reference.
  - AC-CAT-5, AC-CAT-11, AC-CAT-13, AC-CAT-16 extended; AC-CAT-18 and AC-CAT-19 added.
- `specs/SPEC-047-network-model-admission.md`
  - `catalog_matched` amendment — one-sentence uniqueness/resolution mirror.
  - `SPEC-047-R003` — one-sentence resolved-model-key mirror.
  - 0.1.3 changelog entry — records the mirror.
- `specs/CONFORMANCE.json` — `SPEC-023-R004` gap rationale lists the added invariants. R004–R006
  remain `pending` with honest implementation gaps; no state was upgraded.

## Carried items

- **SPEC-047-R002 duplicated MUST-list (pre-existing, INFO).** SPEC-047-R002 states the v0.1
  offer-package MUST-list twice. v0.1.3 adds a citation-only paragraph naming the later, stricter
  paragraph as authoritative and amends only that one; consolidating the duplication is a SPEC-047
  editorial revision and is out of scope for a minimal cross-spec amendment. Unchanged across R1,
  R2, and R3, and not recounted by any lane.
- **`GO-2026-5970` via `golang.org/x/text v0.37.0` in `phase7-verify/go.mod` (pre-existing, INFO).**
  Reported by the security lane's `govulncheck`; the fix is `v0.39.0`. Untouched by this branch,
  which changes no Go module. Standard-library findings the lane observed under local Go 1.26.4 are
  fixed by the repository target Go 1.26.6.
- **R004–R006 remain `pending`.** This is a docs-and-governance revision: no generator, coordinator,
  or CLI implementation of the artifact feed, class expansion, or intake pipeline exists yet. The
  new normative rules — uniqueness, GGUF digest equality, `artifact_id` history, the intake
  processing order — are implementation obligations recorded in CONFORMANCE, not claims of
  implemented behavior.

## Verification after fixes

| Check | Result |
|---|---|
| `python3 scripts/gen_spec_index.py --lint` | pass |
| `python3 scripts/gen_spec_index.py --check` | pass |
| `python3 scripts/check_spec_governance.py` | pass |
| `python3 -m unittest scripts.tests.test_spec_governance` | 46 tests, OK |
| `python3 scripts/catalog-release.py verify` | current release verified |
| `python3 -m json.tool specs/CONFORMANCE.json` | pass |
| `git diff --check` | clean |
| forbidden-wording grep over SPEC-023 | empty |
| `item N` re-enumeration across §16 | all resolve |

## Round status

R3 closed: 2 HIGH, 4 MEDIUM, 2 LOW resolved in-spec; 3 INFO/pre-existing items carried with
rationale. Next action is an R4 three-lane pass over the complete branch diff.
