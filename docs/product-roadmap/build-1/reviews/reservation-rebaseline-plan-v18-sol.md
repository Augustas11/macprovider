# Build 1 reservation rebaseline plan v18 — independent Sol gate

Date: 2026-09-12

Reviewer model: `gpt-5.6-sol`, high reasoning, independent critic lane

Repository authority: landed merge `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`

Reviewed exact artifacts:

- `reservation-rebaseline-plan-v18.md` — SHA-256 `6c5557f2cc6080c63804cff01c45c7502c1b847728a6808aa846431476fa2802`
- `reservation-rebaseline-test-spec-v18.md` — SHA-256 `507671ecbd506596b5a05fe961ad90bf9a6625d8cd6be896ef3879e5d321485a`

Verdict: **REJECT**

Findings: **0 Critical, 2 High, 0 Medium**.

## Findings and required corrections

- `B1-V18-H1`: T18 still named the committed v17 plan/test as the review target, allowing the reopened representation to receive credit. V19 must require the exact current v19 artifacts and treat v17 as historical only.
- `B1-V18-H2`: T18 omitted explicit disposition of `B1-STORAGE-V17-H1`. V19 must require confirmation that v17 temp/root envelope state is rejected and that the only approved path is byte-identical private-state envelope temp/targets plus a separate raw root-identity bootstrap/final record.

The reviewer found the v18 split storage representation constructive; implementation remains blocked because its governing exact-artifact gate was stale and incomplete.
