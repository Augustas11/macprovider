# #1816 SPEC amendments: response to round-1 audits

Inputs: `RESULT_code_R1.md` (C1-C12), `RESULT_security_R1.md` (S1-S2), and
`RESULT_architecture_R1.md` (A1-A8), all against draft `397034dbc`. Line
numbers refer to the revised tree. Every finding was checked against the draft
text before it was fixed, and all 22 are valid. Three are fixed by a different
mechanism than the auditor proposed, following design decisions already made
for the implementation lanes. Those three are marked *fixed (alt)*.

Revised versions: SPEC-005 0.6.12, SPEC-006 0.9.43, SPEC-010 1.16, SPEC-022
v0.2.6, SPEC-023 v0.22.4, SPEC-032 v0.3.6, SPEC-042 0.0.38, SPEC-043 0.2.2,
and SPEC-047 0.2.5.

## Code lane

| ID | Sev | Disposition | Where |
|---|---|---|---|
| C1 | HIGH | **Fixed (alt).** The rate card is unchanged. Bounds moved to coordinator config `trusted_pools.pool_model_pricing_bounds` (six int64 min/max fields, validated at load). When unset or invalid, every entry fails closed. The rate-card-carries-bounds rule is removed. Versioning FeedSchema-A, as proposed, was rejected: FeedSchema-A is closed and the fleet CLI rejects extra keys. | `specs/SPEC-005-billing.md:1520`; `specs/SPEC-042-pool-control-plane.md:369` (items 7-9) |
| C2 | HIGH | **Fixed.** R-12.1 admits the R011 entry hash and binds `serving_provider_account_id` for R016 members. R-12.3 accepts the R003(iv) or R011 identity and either the creator account or an R016-named owner account. This matches SPEC-042-R006 condition 4. | `specs/SPEC-022-verified-model-settlement.md:1094`, `:1128`; `specs/SPEC-042-pool-control-plane.md:225` |
| C3 | MED | **Fixed.** R002's status enum adds `pool_attested_earning`, with its predicate (a pool-scoped `catalog_priced` event while the R010 conditions hold). An older closed decoder treats the status as undecodable. The SPEC-046-R003 local enum is unchanged. | `specs/SPEC-047-network-model-admission.md:136` |
| C4 | MED | **Fixed.** The pool-manifest origin gets closed reasons: `pool_manifest_bound` and `pool_manifest_rebound`, plus four `revoked` reasons. All four revocations append `revoked`. A rollback attempt appends nothing. | `specs/SPEC-047-network-model-admission.md:109`, `:198` |
| C5 | MED | **Fixed.** Adds the auditable signed-manifest `catalog_priced -> catalog_priced` rebind (table row and actor paragraph) and a generation-rollover sweep. The sweep is idempotent, and an unrebound binding fails closed. | `specs/SPEC-047-network-model-admission.md:96`, `:103`, `:196` |
| C6 | MED | **Fixed.** `manifest_core_digest` is used everywhere, including the closed `pool_binding` object. | `specs/SPEC-047-network-model-admission.md:188` |
| C7 | MED | **Fixed.** Probe results are a coordinator-owned `model_admission_probe_evidence.v1` record, linked from the event as `pool_binding.probe_evidence_digest` and covered by the event digest. They are never part of the provider-signed `evaluation_digest`. | `specs/SPEC-047-network-model-admission.md:200` |
| C8 | MED | **Fixed.** The R004 predicate requires R003(iv) or R011, as applicable. | `specs/SPEC-032-proof-of-weights-hello-gate.md:454` |
| C9 | MED | **Fixed.** The producer is SPEC-047-R012 (`model_admission_pool_proven.v1`, operator-only, with cadence, ceilings, and an explicit `suppressed` flag with nullable counts). SPEC-023 retains the response as `model-admission-pool-proven.json` under §16.8 rule 9 and re-derives it. | `specs/SPEC-047-network-model-admission.md:202`; `specs/SPEC-023-installer-autotune-recommend.md:3730` |
| C10 | MED | **Fixed.** Entries carry the formula's three int64 rates (`prompt`, `prompt_cache_hit` <= `prompt`, and `completion`), each in `[0, 2^63-1]`. `provider_share_bps` and `global_multiplier_ppm` come from the `default` row. Config validation rejects bounds that could overflow the formula. | `specs/SPEC-005-billing.md:1518`, `:1520`; `specs/SPEC-042-pool-control-plane.md:369` |
| C11 | MED | **Fixed.** Acceptance rejects any entry whose pair resolves to a catalog identity in any tier (`pool_model_entry_catalog_overlap`). A later catalog addition revokes the pool binding (`pool_manifest_entry_revoked`), and the catalog path then applies. | `specs/SPEC-042-pool-control-plane.md:376`; `specs/SPEC-047-network-model-admission.md:186` |
| C12 | LOW | **Fixed.** §16.2 now says four signals, adds (d), and adds the §16.3 pool-proven term and its threshold row. | `specs/SPEC-023-installer-autotune-recommend.md:3478` |

## Security lane

| ID | Sev | Disposition | Where |
|---|---|---|---|
| S1 | LOW | **Fixed.** Same fix as C9. The source schema, endpoint, retained filename, bounds, and re-derivation are now defined. | `specs/SPEC-047-network-model-admission.md:202`; `specs/SPEC-023-installer-autotune-recommend.md:3730` |
| S2 | LOW | **Fixed.** The journey now requires buyer-final debit on the authorized pool route and no global or poolless buyer-final debit. | `specs/SPEC-047-network-model-admission.md:200` |

## Architecture lane

| ID | Sev | Disposition | Where |
|---|---|---|---|
| A1 | HIGH | **Fixed.** A snapshot-manifest entry may list `mlx_cache` without adding it to `runtime_allowlist`. SPEC-042-R004 defines the native pool-entry path, and SPEC-032 exempts only the exact-matching member hello for that pool's routes. Uncatalogued `mlx_cache` stays closed everywhere else. Native receipts and `coordinator_observed` are unchanged (SPEC-022 R-13.5). | `specs/SPEC-042-pool-control-plane.md:202`, `:369`; `specs/SPEC-032-proof-of-weights-hello-gate.md:466`; `specs/SPEC-022-verified-model-settlement.md` R-13.5 |
| A2 | HIGH | **Fixed (alt).** R-13.2 keeps the `route_snapshot_v1` preimage byte-identical for every existing route. The new provenance sits either (A) outside the receipt-bound digest or (B) in a `route_snapshot_v2` preimage used only by routes that carry it. The choice is implementation-defined pending. R-13.3 fixes the tuple semantics for pool routes and reconciles with SPEC-015 by reference. SPEC-015 itself is not edited in this round: its §N.2 amendment is a stated promotion gate of R013, and option B requires it. | `specs/SPEC-022-verified-model-settlement.md:1349`, `:1377` |
| A3 | MED | **Fixed.** There is no new encoding. Two named v2 extensions, `pool_attested_members/v1` and `pool_model_entries/v1`, have closed bodies. Cores without them are byte-identical, and the existing no-re-encode promise holds. | `specs/SPEC-042-pool-control-plane.md:155` |
| A4 | MED | **Fixed (alt).** Same fix as C5: a rebind edge with an atomic, fail-closed sweep and single-pool cardinality, chosen over a separate binding projection. | `specs/SPEC-047-network-model-admission.md:186`, `:196` |
| A5 | MED | **Fixed.** New SPEC-006-R018 (§5.4.3) owns the buyer `/v1/models` pool view, price disclosure, and response headers, with its own CONFORMANCE row. SPEC-043-R014 keeps only the creator and launch disclosure. | `specs/SPEC-006-buyer-api.md:1944`; `specs/SPEC-043-trusted-pool-creator-onboarding.md:130`; `specs/CONFORMANCE.json:10329` |
| A6 | MED | **Fixed.** SPEC-047-R009 owns hash-key derivation and the opt-in v2 frame. SPEC-047-R012 owns the pool-proven producer. SPEC-023-R026 is consumer-only. Each has a separate pending row. | `specs/SPEC-047-network-model-admission.md:182`, `:202`; `specs/SPEC-023-installer-autotune-recommend.md:3728`; `specs/CONFORMANCE.json:10344` |
| A7 | MED | **Fixed.** Pool-proven `listed` admission requires a current passing R011 evidence record, the SPEC-023 signals, and an operator decision. The record is carried in `macprovider.intake-decision.v2`. | `specs/SPEC-023-installer-autotune-recommend.md:3752`; `specs/SPEC-047-network-model-admission.md:200` |
| A8 | LOW | **Fixed.** Same fix as C6. | `specs/SPEC-047-network-model-admission.md:188` |

## Totals

22 findings: 22 fixed (3 by an alternative mechanism: C1, A2, A4), 0 rejected.
All new and changed CONFORMANCE rows remain `pending` with explicit gaps. New
rows are SPEC-006-R018 and SPEC-047-R012.
