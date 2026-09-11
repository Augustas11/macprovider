# BYOM v0.2 slice 5 SPEC audit — round 1 (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `c44c422e` (SPEC-017 v0.2.1, SPEC-047 v0.1.6, SPEC-023 v0.10.4). Three codex lanes.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 5 | 8 | 1 | 0 |
| security-reviewer | 0 | 0 | 7 | 1 | 0 |
| architect | 0 | 1 | 8 | 2 | 1 |

## Findings and dispositions (fixed in the R1 fix commit unless noted)

- **k-anonymity counted requests, not principals** (code H, arch H, sec M1): §16.2(a) item 9 and AC-CAT-13 amended — a bucket is suppressed unless ≥ `INTAKE_K_ANONYMITY_MIN` DISTINCT principal tokens contributed; cardinality never emitted; suppressed buckets OMITTED from the wire (`suppressed_bucket_count` only). SPEC-017 §5.2b.4/§5.2b.5.
- **Gateway-authenticated traffic excluded by the literal predicate** (code H, arch M1): §5.2b.2 item 1 defines the authenticated account as direct buyer-key auth OR a sanitized account assertion inside a gateway-service-bearer-authenticated context; bare header → nothing; `demo:` subjects ineligible.
- **`stats_intake_current` had no DDL/grants/cadence/freshness/health entry** (code H, arch M4): §9.1 DDL, §7.2.2 rollup grants, §9.2 cadence row, §9.5 freshness row, §5.8 bullet, §5.3 nine components, health CHECK comment.
- **One manifest window for three source windows; open window `null` end** (code H, arch M5, sec M4): §16.8 rule 3 per-signal windows (`*_window_start/_end`, `unmatched_model_request_window_id`), envelope semantics, staleness per signal; buyer signal only from the LATEST `complete` (epoch_elapsed) window, selected deterministically, never open/incomplete (`incomplete_window`); SPEC-017 §3.2a `complete`.
- **Closed-window parameter provenance lost** (code H): `parameters` moved INTO each window, immutable at open; generator validates thresholds against the relied-on window's parameters.
- **Partner keys not least-privilege** (sec M2, arch M2): `stats.intake.reader_partner_key_ids` allowlist by `partner_keys.id`; empty default refuses every key; provider-bound keys 403.
- **Sybil buyer accounts** (sec M3): §5.2b.3 states what a principal costs (operator-issued key or funded wallet session under gateway issuance limits), what the floor buys (`listed` only, operator decision required), and that the SPEC claims no Sybil-proofness. Carried as a documented residual; lanes re-judge in R2.
- **Short/selectable epochs** (sec M4): incomplete windows never satisfy a floor; deterministic latest-complete selection; no operator choice.
- **Eligibility change inside an epoch** (sec M5, arch M7): change closes the window (`eligibility_changed`); each window carries `eligibility_policy_sha256` (revision fingerprint, no identifiers).
- **Suppressed provider rows reveal sub-k interest** (sec M6): NOT changed — SPEC-023 §16.8 rule 4 normatively requires key-attributable suppression state for this signal; the operator credential already reads every per-provider offer via the listing; rows name no provider. Rationale stated in SPEC-047 text; lanes re-judge in R2.
- **Null digests discard evidence; unsigned responses** (sec M7, arch M6, code M): rule 2 — digest non-null whenever the source was read; null only for `spec017_amendment_not_landed`/`source_unavailable`; new rule 8 commits the exact source responses under `intake-sources/<release_id>/` and the generator re-derives every value; signed envelope deferred to §13 (LOW carried).
- **Sanction predicate undefined** (arch M9, code M): SPEC-047 closed `provider_intake_sanctioned` = admission rejection, canary sanction, revoked provider token; trust/payout/blacklist explicitly out with reasons; offer path refuses the same set.
- **`created_at` undefined** (code M): coordinator-assigned append time; provider timestamp prohibited.
- **Response value contract missing** (code M): exact frame + field rules for `model_admission_intake_offer_counts.v1`.
- **False candidate-cap bound** (code M, arch L1): bound restated as the R007 per-provider offer rate limit over the window; indexed `(state, created_at)` scan.
- **Closed schema vs §8.2 additive rules** (code M, arch M8): §8.2 exemption for `macprovider.stats-intake.v1`; field-set change = new schema_version.
- **Source unavailability unrepresentable** (code M): `source_unavailable` absent reason for the three coordinator signals; `stats.intake.enabled=false` → 404 → `source_unavailable`.
- **Draft SPEC-017 adopted by locked SPEC-023** (arch M3): SPEC-017 v0.2.1 Status set to LOCKED (v0.2.0 surfaces are deployed and CONFORMANCE lists SPEC-017 normative).
- **Stale spec index** (code M): `specs/README.md` regenerated.
- **Memory bound omitted closed windows** (code L): total bound stated (open window + ≤ 8 closed wire forms, no principal tables).
- **Cache-Control `private` + `s-maxage`; C5** (arch L2): `private, max-age=30`; C5 exemption stated.
- **"retained" wording** (arch I1): "persisted"; tokens live in bounded private memory until window close.

## Carried
- LOW (sec 8 / arch M6 tail): unsigned response bytes prove content, not coordinator provenance → §13 open question; rule 8 committed sources + ledger digest are the v0.10.4 evidence.
