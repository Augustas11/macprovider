# SPEC-023 v0.10.0 — audit round R4

Branch: `spec/023-catalog-artifact-sets-class-rates`
Scope: `git diff origin/main...HEAD` — `specs/SPEC-023-installer-autotune-recommend.md`,
`specs/SPEC-047-network-model-admission.md`, `specs/CONFORMANCE.json`, `specs/README.md`.
Method: three independent codex lanes over the COMPLETE branch diff (not the R3 delta),
cross-checked against SPEC-005 §5.5, SPEC-010 (~975–1010), SPEC-017 v0.2.0, SPEC-022
(route-time snapshot minimum fields, ~line 305), SPEC-032 FR-HG3/FR-HG4, SPEC-044 §2,
SPEC-046-R002/R003, `scripts/catalog-release.py` (ledger row shapes ~767/~783/~848, signer
handling ~675), `AutotuneStrictJSON.swift`, `CompatibilitySetManifest.swift`, and
`phase3-binary/catalog/autotune/*.json`.

## Verdicts

| Lane | Verdict | Recommendation |
|---|---|---|
| code review | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 0 INFO | COMMENT — lock bar not met |
| architecture | 0 CRITICAL / 0 HIGH / 5 MEDIUM / 0 LOW / 0 INFO | does not meet lock bar |
| security | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 0 INFO | one normative retention ambiguity |

Deduplicated across lanes: **6 MEDIUM, 1 LOW.** The code MEDIUM, architecture MEDIUM-1, and the
security LOW are three views of one defect (artifact evidence and signer identity are not bound
into the immutable route-time record); they are resolved together as R4-F1. The security MEDIUM
and architecture MEDIUM-3 are adjacent but distinct (retention window vs. bucket schema) and are
resolved separately.

Bar for the round: 0 CRITICAL / 0 HIGH / 0 MEDIUM. All six deduplicated MEDIUMs and the single
LOW are resolved in this round. Nothing is carried as an unresolved MEDIUM.

## Findings and resolutions

### R4-F1 — MEDIUM: artifact evidence and signer identity were not bound into the immutable route-time snapshot

Lanes: code MEDIUM (SPEC-047:117, SPEC-022:305, SPEC-023:1366), architecture MEDIUM-1
(SPEC-023:656, SPEC-023:800, `catalog-release.py:675`), security LOW-2 (SPEC-023:656/800,
AC-CAT-1, AC-CAT-4, SPEC-047-R003).

Two coupled gaps at one trust boundary.

**(a) Snapshot binding.** SPEC-047-R003 required the "recorded binding" to carry
`artifact_feed_sha256`, the artifact `hash`, and its `hash_algorithm`, but never required those
values to be part of — or transitively immutable through — the SPEC-022 route-time snapshot,
whose minimum field list stops at the candidate-catalog digest, signature identity, and expected
hash. A literal implementation could hold artifact evidence only in mutable admission state while
persisting a candidate-only route snapshot. Primary-hash equality bounded the substitution risk,
but the settlement proof would not preserve WHICH operator-signed artifact verification state
authorized routing. No acceptance case tested missing, changed, cross-release, or wrong-signer
artifact evidence at settlement.

**(b) Signer identity.** §3.7.2 asserted the artifact feed "is signed by the same static-feed key"
as the candidate catalog, and `release.json` records a `signer_key_id` per feed, but nothing
required an equality CHECK. The existing manifest pattern authenticates each sidecar
independently (`catalog-release.py:675`) and never compares signers. During a key-rotation bridge
more than one key is concurrently trusted, so unknown-`key_id` rejection does not enforce
"same key," and no AC tested a valid signature from a second trusted key.

**Resolved.**

- SPEC-023 §3.7.2:660 adds **Signer identity equality (normative)**: at generation AND at
  consumption the authenticated artifact sidecar `key_id` MUST equal
  `release.json.feeds["autotune-artifacts.json"].signer_key_id` AND the authenticated
  candidate-feed signer `key_id` of that release; any mismatch, a valid signature by a different
  concurrently trusted key included, is `catalog_artifact_feed_integrity_failure`, never
  `catalog_artifact_feed_update_required`.
- SPEC-023 §3.7.2 (the `artifact_feed_sha256` paragraph) names `artifact_feed_signer_key_id` and
  states it is recorded only after that equality check succeeds.
- SPEC-023 §3.7.6 class 2 adds signer-identity mismatch to the integrity-failure class, so the
  one testable code covers it.
- SPEC-023 §3.7.7:800 adds **Artifact evidence is signer-bound at generation and snapshot-bound
  at settlement** to R004: the six values MUST reach the immutable SPEC-022 route-time snapshot
  or a separate immutable record the snapshot references by digest, and settlement MUST fail
  closed on missing, changed, cross-release, or wrong-signer evidence.
- SPEC-047-R003 (amended v0.1.3) states the same requirement on the SPEC-047 side, enumerates the
  four fail-closed settlement cases, and forbids settlement from consulting a current feed,
  `release.json`, or keyring to repair evidence a snapshot lacks.
- AC-CAT-1:1376 adds the different-but-concurrently-trusted-signer case, failing closed at
  generation and at consumption.
- New **AC-CAT-20**:1414 asserts the six snapshot-carried values and the four settlement negative
  cases (missing / changed / cross-release / wrong-signer), and asserts explicitly that an
  implementation storing artifact evidence only in mutable admission state fails the criterion.

**SPEC-022 was NOT amended.** Its route-time snapshot minimum field list is unchanged and its
file is untouched by this branch. The extension is stated as a **SPEC-047-owned OPTIONAL record**
on two grounds recorded in both specs: SPEC-022 states the snapshot "contains at least" those
fields, which an owner spec may extend, and the settlement-capable receipt profile already binds
the snapshot by digest, so the extension travels under the binding SPEC-022 already requires.

### R4-F2 — MEDIUM: the artifact-bound release-ledger row had no normative wire shape

Lane: architecture MEDIUM-2 (SPEC-023:739, SPEC-023:800, AC-CAT-19:1412;
`catalog-release.py:767`, `:783`, `:848`).

The ledger "MUST record every `(model_key, artifact_id, hash_algorithm, hash)` binding," with no
field name, JSON structure, ordering, uniqueness rule, or evolution rule. It could not be
inferred: v1/v2 release rows are the exact closed set `{generated_at, policy_version, feeds}`
and the serializer still emits v2.

**Resolved.** SPEC-023 §3.7.8:819 adds **Release-ledger schema version 3 (normative wire
shape)**, named `macprovider.autotune-release-ledger.v3` to match the existing
`…-ledger.v1` / `.v2` naming in `catalog-release.py`:

- top level unchanged: the exact closed set `{schema_version, releases, tombstones}`; tombstone
  shape unchanged;
- artifact-bound release row: the exact closed set
  `{generated_at, policy_version, feeds, artifact_bindings, intake_decision_sha256}` — the v1/v2
  set extended with `artifact_bindings` (this finding) and `intake_decision_sha256` (R4-F5);
- `artifact_bindings`: an array of the exact closed object
  `{model_key, artifact_id, hash_algorithm, hash}`, four strings, `artifact_id` under the §3.7.4
  grammar, `hash` lowercase 64-hex;
- completeness: exactly one element per published `(model_key, artifact_id)` including `declared`
  and `blocked` artifacts, since the rebinding check is about bytes-under-an-id, not trust state;
- canonical ordering: ascending `model_key` then `artifact_id`, UTF-8 byte order, part of the
  wire shape so two generators emit byte-identical arrays;
- uniqueness: `(model_key, artifact_id)` at most once and `(hash_algorithm, hash)` at most once —
  the ledger mirror of §3.7.4 global artifact-hash uniqueness;
- historical rows: v1/v2 rows keep their shape forever, are never rewritten, never gain the new
  keys, and are never re-validated against v3; within a v3 document the two new keys are REQUIRED
  exactly when the feed set is the artifact-bound five-feed set and PROHIBITED otherwise;
- activation: the first artifact-bound release is written into a v3-serialized ledger and every
  later release MUST be a v3 artifact-bound row; a v2 serialization or a row without
  `artifact_bindings` afterwards is a downgrade and fails closed. A v3 reader accepts v1/v2; a v2
  reader need not accept v3, and that is not a fleet fail-close because `release-ledger.json` is
  a release-host and audit artifact never fetched, baked, or parsed by an installed provider.

AC-CAT-19:1412 now asserts the concrete representation — field set, types, ordering, uniqueness,
completeness, historical-row invariance, and activation in both directions — rather than that the
bindings are "recorded".

### R4-F3 — MEDIUM: `other_suppressed` had a self-contradictory closed shape

Lane: architecture MEDIUM-3 (SPEC-023:1744, AC-CAT-13:1380, SPEC-023:1839).

Item 6 said the bucket carries `request_count` and `distinct_key_count` "only", then required the
emitted object to set `saturated: true`. AC-CAT-13 repeated the contradiction, so the "exact
contract" §16.7 requires SPEC-017 to adopt was unadoptable: either it violates the two-field rule
or omits the saturation indicator. A single shared flag also loses which counter saturated.

**Resolved.** §16.2(a) item 6:1762 defines the bucket as a closed object carrying **exactly four
fields** — `{request_count, request_count_saturated, distinct_key_count,
distinct_key_count_saturated}` — with a JSON example, integer/boolean types, and per-counter
flags; a bare `saturated` key, an unknown key, a missing key, or a wrong-typed value is a
malformed intake record. Item 10:1783 restates the closed four-field shape, AC-CAT-13:1400
asserts it and the per-counter flags, and the §16.7:1881 SPEC-017 adoption sentence names the
same four fields, so all four sites agree.

### R4-F4 — MEDIUM: provider-offer suppression depended on a k-anonymity floor that did not exist

Lane: architecture MEDIUM-4 (SPEC-023:1762, SPEC-023:1801, SPEC-017:3, SPEC-023:1837).

`distinct_provider_offer_count` had to be suppressed below "the same k-anonymity floor the
SPEC-017 signal uses", and `INTAKE_OFFER_FLOOR = 3` was asserted to be above that floor — but
SPEC-017 v0.2.0 defines no such field or floor, and §16.7 lets SPEC-017 choose a higher one. Only
the buyer-request signal was gated on the SPEC-017 amendment; provider-supply intake was not, so
the floor it depended on was undefined at the moment it would be used.

**Resolved.** §16.4:1843 adds `INTAKE_K_ANONYMITY_MIN`, default `3`, as a **SPEC-023-owned**
minimum applying to BOTH `distinct_provider_offer_count` and the SPEC-017 unknown-key signal.
§16.2(b):1801 states the ownership, requires `INTAKE_OFFER_FLOOR >= INTAKE_K_ANONYMITY_MIN` in
every configuration (below it, the release fails closed at generation), states that a suppressed
provider count MUST NOT satisfy the offer floor — not unsuppressed, not read as "at least k", not
added back — and states explicitly that **provider-offer intake is available now**: it is
coordinator-owned SPEC-047 admission data, not a SPEC-017 stats field, so it is not gated on the
SPEC-017 amendment. §16.2(a) item 9 and §16.7 are reworded to "effective k-anonymity floor
(`INTAKE_K_ANONYMITY_MIN`, or a higher SPEC-017 value)"; §16.7 adds that SPEC-017 may not select
a floor below the SPEC-023 minimum and that the ownership split covers `unmatched_model_request_count`
only. AC-CAT-12:1398 asserts the floor, the suppressed-count rule, the configuration gate, and the
no-amendment-needed availability.

### R4-F5 — MEDIUM: intake decisions were not reconstructible from the release record as claimed

Lane: architecture MEDIUM-5 (SPEC-023:1812, :1762, :1766, :1771).

§16.4 claimed an intake decision is "reconstructible from the release record alone" on the
strength of recording threshold CHANGES in release notes. Recording the rule is not recording the
inputs: the decision also depends on provider-offer counts, fleet-fit observations, the selected
admission clause, and suppression state, none of which any schema bound into the release record.

**Resolved.** §16.4's closing sentence:1854 no longer claims reconstructibility; it says release
notes alone do not carry it and points to §16.8. New **§16.8 Intake decision record
(release-bound)**:1883 defines `intake-decision.json`
(`schema_version: "macprovider.intake-decision.v1"`), committed with the release inputs and
digest-bound as `intake_decision_sha256` in the §3.7.8 ledger row. Like `rate-card-source.json`
it is never served, never baked, and never bound in `release.json`, so it adds no name to any
exact-set check. It is closed at every level, and its eight field rules require, for every added
or promoted key: evaluated signal values with the authenticated source snapshot digests they were
read from (absent signals as `null` with a closed `*_absent_reason`, never silently omitted),
observation window bounds and an `as_of` timestamp with a staleness gate of one §16.5 cadence
period, per-signal suppression state (a suppressed signal records `null` and may not be the
selected clause), every §16.4 threshold at the value in force, the selected `admission_clause`
and `fit_clause`, `coldstart_slot_used` bounded by `INTAKE_COLDSTART_SLOTS`, `listed_since`
(non-null exactly for promotions), and the `operator_decision` and `operator_role`. Rule 8 keeps
the §16.2 privacy invariants on the manifest: no provider or buyer identity, no raw principal
identifier, no principal token. New **AC-CAT-21**:1416 asserts the manifest, its ledger digest
binding, the closed schema, the per-key completeness, the negative cases, and the auditor
reconstruction.

### R4-F6 — MEDIUM: raw principal identifiers could persist for the whole rollup window

Lane: security MEDIUM-1 (SPEC-023 §16.2(a) items 10 and 7 / lines 1745–1748, AC-CAT-13:1380).
OWASP A02 / A04.

Item 10 forbade buyer identity "at any stage" but then said both the raw identifier and the token
exist inside the aggregator "for the life of the window", so a literal implementation could retain
a window of linkable buyer-account, partner-key, or source-class identifiers. AC-CAT-13 tested
that no raw identity appears in a RECORD, never that it is discarded after derivation. The design
needs the raw principal only transiently, to derive the window-scoped HMAC token.

**Resolved.** §16.2(a) item 10:1783 is retitled and split: the raw principal identifier MAY be
read transiently ONLY while deriving `principal_token` at S4; it MUST be discarded before any
intake-state mutation — before the item-8 principal-table lookup or insert, before the item-7 cap
comparison mutates a counter, and before any item-4 Space-Saving update — and MUST NOT be stored
in a bucket, counter table, principal table, log line, trace span, metric label, diagnostic dump,
crash artifact, or any other aggregator state. Only the token and its one bounded counter persist
for the window. Step **S4**:1794 carries the same discard obligation inline, so the processing
order and the field contract cannot drift apart. AC-CAT-13:1400 asserts that immediately after S4
no raw principal identifier is reachable from aggregator state and that a serialized diagnostic
dump taken at that instant contains none — an implementation that keeps the raw identifier
alongside its token for the window fails the criterion even though it emits no identity. §16.7's
adoption sentence names transient-only handling as part of the contract SPEC-017 must adopt.

### R4-F7 — LOW: the class-rate authoring source had no versioned, closed schema

Lane: code LOW (SPEC-023:488; `catalog-release.py:614`, `:1614`).

§3.3.1 defined the contents of each `classes` entry but never named or closed the surrounding
authoring-source document. The current generator reads the published `rate-card.json`, whose exact
schema rejects `classes`, so implementations would have to invent a separate input artifact and
its top-level structure — incompatible source formats could satisfy the same prose, weakening
reproducibility and fixture portability. No published bytes or billing behavior were affected.

**Resolved.** §3.3.1 rule 3:490 names the artifact `rate-card-source.json` with
`schema_version: "macprovider.rate-card-source.v1"`, states it is never served at `/v1/rate-card`,
never baked, never bound in `release.json`, and never in the release-ledger feed set, and closes
its top level to the exact set `{schema_version, generated_at, policy_version,
usd_per_million_credits, provider_share_bps, global_multiplier_ppm, rows, classes}` — naming
where the release-global values live, requiring `rows` and `classes` to be present (possibly
empty), and failing the release closed on an unknown key, a missing key, a wrong-typed value, or
a `rows`/`classes` entry with any field beyond the three credit-rate fields. Rule 5 is clarified
so "published verbatim" refers to the three credit values, with the release-global values
materialised under rule 4. AC-CAT-9:1392 adds the unknown-field, missing-field, wrong-type,
unknown-`schema_version`, and extra-entry-field cases, the valid empty-`rows`/empty-`classes`
case, and the never-published assertion.

## Carried items

- **SPEC-022 is deliberately unamended.** The route-time snapshot extension is a SPEC-047-owned
  optional record referenced from the snapshot; SPEC-022's minimum field list and its file are
  untouched. If a future reviewer concludes the extension must live in SPEC-022's own minimum
  list, that is a SPEC-022 revision with its own owner and audit, not a SPEC-023/047 edit.
- **Requirement states stay `pending`.** `SPEC-023-R004`, `-R005`, and `-R006` remain `pending`
  with `DECISION_REQUIRED` gaps in `specs/CONFORMANCE.json`; R4 adds normative surface, not
  implementation. The R004 and R006 rationales are extended to name the new normative content
  (signer equality, snapshot-bound artifact evidence, ledger v3, the closed `other_suppressed`
  shape, `INTAKE_K_ANONYMITY_MIN`, and the intake-decision manifest) so the gap text stays honest.
- **SPEC-017 amendment still gates `unmatched_model_request_count`.** R4 changes which floor is
  minimum, not the gate: that signal still satisfies no intake floor until SPEC-017 adopts the
  §16.2(a) contract by amendment. `distinct_provider_offer_count` is now explicitly NOT gated.
- **The R2/R3 INFO item** (pre-existing SPEC-047-R002 duplicate MUST-list, carried as a
  citation-only note) is unchanged and remains out of scope.

## Verification

Run in `/Users/augstar/macprovider-spec023-catalog-pipeline` after the R4 edits:

- `python3 scripts/gen_spec_index.py --lint` — passed
- `python3 scripts/gen_spec_index.py --check` — passed
- `python3 scripts/check_spec_governance.py` — passed
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_spec_governance` — passed
- `python3 scripts/catalog-release.py verify` — passed
- `git diff --check` — clean

## Closing note

R5 codex re-run deliberately NOT run — four anchored rounds; closure delegated to an independent
review on the PR.
