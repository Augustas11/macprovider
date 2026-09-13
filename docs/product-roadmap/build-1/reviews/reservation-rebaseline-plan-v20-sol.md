# Build 1 reservation rebaseline plan v20 — independent Sol gate

Date: 2026-09-12

Reviewer model: `gpt-5.6-sol`, high reasoning, independent critic lane

Repository authority: landed merge `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`

Reviewed exact artifacts at plan commit `a5935667c9c97e5fd80c81b1817c9c609e761887`:

- `reservation-rebaseline-plan-v20.md` — SHA-256 `8045eccb1660e98a8213bbcf41b5a0b26f72970324a7f92bcf3afca152addf57`
- `reservation-rebaseline-test-spec-v20.md` — SHA-256 `f218249c00586c829a8364971ea3fa2382c789e2f7c78b019c60741a96794c0f`

Verdict: **PASS**. Findings: **0 Critical, 0 High, 0 Medium**.

## Required finding dispositions

- `B1-STORAGE-V17-H1` closed: five replaceable private-state leaves store byte-identical `model_catalog_private_state_envelope.v1` temp/target bytes; `root.identity` has a separate raw closed `model_catalog_root_identity.v1` bootstrap/final path. V17 `model_catalog_unique_temp.v2`, raw durable lifecycle payloads, and envelopes at `root.identity` are incompatible development state and rejected.
- `B1-V18-H1/H2` closed: T18 requires exact committed v20 plan/test bytes and explicitly dispositions the storage representation.
- `B1-V19-M1` closed: Slice 6A requires independent review of the current v20 bytes, agreeing with T18.

The reviewer independently checked landed authority ancestry, exact hashes, SPEC-001 v1.9.17/SPEC-044 v0.2.8, trust boundaries, bounded recovery and generation semantics, crash ordering, ACL/descriptor races, compatibility, economics truthfulness, and the acceptance tests. No remaining Critical, High, or Medium finding was reported.

## Implementation gate

Storage may resume only against v20. The contract candidate at PR #1491 head `fe9376d7` must first replace its v17 temp schema, remove root identity from the private-state envelope kind inventory, and provide raw root-identity bootstrap/final handling. Contract correction, storage code, and complete cumulative diffs still require fresh tests and independent code, security, and architecture audits before acceptance.
