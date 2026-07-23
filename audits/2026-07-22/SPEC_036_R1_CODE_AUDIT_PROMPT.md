You are performing an independent proof-review (CODE / implementability lane) of a
finished normative specification in the macprovider repository. This is a review of
an existing document for defects — you are NOT asked to author, extend, or attack
any system. Report defects only.

## Target
- Primary: `specs/SPEC-036-compute-integrity-receipt.md` (the spec under review).
- Shared primitive it composes on: `specs/SPEC-030-losslessness-probe.md`
  (owns the distribution-snapshot / `support_selection_v1` / TV-interval /
  authenticated-probe-transport machinery; §FR-3, §FR-4, §FR-7, §FR-9).
- Dependency headers for pinned versions: `specs/SPEC-015-receipts.md`,
  `specs/SPEC-022-verified-model-settlement.md`,
  `specs/SPEC-026-browserless-provider-onboarding.md`.

## Context
SPEC-036 was renumbered from a stale `SPEC-030` draft and its shared-measurement
dependency was rewired from the pre-renumber `SPEC-029` to the canonical
`SPEC-030` (Losslessness Probe). The design decision is to **compose** on the
losslessness probe's shared machinery by normative reference (not duplicate),
keeping a distinct settlement-bearing wire constant `compute_integrity_probe_v1`.

## Review dimensions (CODE / implementability)
Judge the spec as an implementable contract. Find defects in:
1. Internal consistency: any two clauses that contradict each other (e.g. field
   lists, enum values, threshold formulas, state names, key tuples that disagree
   between definitions §3, FRs §5, ACs §7, migration §6).
2. Completeness for implementation: fields referenced but never defined; states or
   `blocked:<reason>` variants used in one place but missing from the state list or
   the settlement-reason mapping table (FR-3); reason-enum members with no producing
   rule, or producing rules with no enum member.
3. Deterministic mappings: the FR-3 captured-state→reason table, the `expiry_cause`
   sub-table, and the `blocked:<reason>`→reason table — verify every state/cause has
   exactly one mapping and every mapping target is in the closed reason enum.
4. Key-tuple coherence: compute-integrity key, window key, threshold key,
   reference-event key, request-start capture fields — verify the same dimensions
   are used consistently (model_id, target_model_hash, tokenizer_identity,
   sampler_stage, target_generation, sampling_profile, corpus_version,
   threshold_version) and that `assigned_id`/`stable_provider_identity` inclusion or
   exclusion is consistent with the stated intent (window accumulators must not
   include assigned_id).
5. Probe schema (FR-6) and TV computation (FR-7): request/result envelope + payload
   field lists, digest domain-separation (`{type, schema_version, payload}`),
   validation rules, K=64→256 retry predicates, support-length bounds [K, 2K],
   tail-mass tolerances — verify they are self-consistent and consistent with the
   inherited SPEC-030 §FR-4/§FR-7/§FR-9 they cite.
6. Composition/reference integrity: every `SPEC-030 §FR-n` citation in SPEC-036
   points at a section of `specs/SPEC-030-losslessness-probe.md` that actually
   contains the cited primitive; no citation still points at the wrong spec; no
   residual `SPEC-029` dependency reference remains except in the explicit
   historical numbering note.
7. Acceptance-criteria coverage: each of the 17 ACs (§7) is fully specified and
   maps to at least one normative FR; flag any AC that tests behavior not defined
   in the FRs, or any settlement-affecting FR with no AC.
8. Version-pin correctness: the `Depends on:` header versions match the current
   header of each dependency spec file.

## Output format
For each finding: SEVERITY (CRITICAL / HIGH / MEDIUM / LOW / INFO), a short title,
the exact file + line or section, the defect, and the minimal fix. Rank most-severe
first. If a dimension is clean, say so in one line. The bar for this spec is
0 CRITICAL, 0 HIGH, 0 MEDIUM. Be precise and cite line numbers.
