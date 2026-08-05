# SPEC-NNN — Title

**Version:** 0.1.0

```json
{
  "spec_id": "SPEC-NNN",
  "title": "Title",
  "version": "0.1.0",
  "path": "specs/SPEC-NNN-lowercase-kebab-title.md",
  "status": "draft",
  "owner": "@owner",
  "authority_domains": ["domain-id"],
  "supersedes": [],
  "depends_on": ["SPEC-001"],
  "implementation_status": "pending-reconciliation",
  "production_status": "pending-verification",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": null
}
```

Copy this file to `SPEC-NNN-lowercase-kebab-title.md`. Keep the title on line
one and the version within the first 15 lines so the canonical index can parse
it. Add the JSON object above to `CONFORMANCE.json`; that manifest is the single
machine-readable metadata record, while this spec header remains the
human-readable title/version source checked against it. New specs start with
complete ID migration because every normative obligation must be represented by
a structured requirement record from the first draft.

## 1. Purpose and scope

State the user/system outcome, in-scope behavior, exclusions, and compatibility
constraints. Name the accepted user journeys that arbitrate this contract.

## 2. Dependencies and authority

List dependency spec IDs and the authority domains this spec owns. For every
shared concept owned elsewhere, link to the owner from `AUTHORITY.json` rather
than restating its definition. In `AUTHORITY.json`, mark any domain that needs
signed physical journey results with `requires_signed_journey_result: true`;
until Phase 5 defines that result contract, those domains cannot promote
requirements to `conformant`.

## 3. Normative requirements

Define each requirement exactly once. IDs are stable and never reused.

**SPEC-NNN-R001 — Short imperative title.** The implementation MUST state one
testable obligation. Follow-up prose may clarify the same obligation without
creating an unnumbered second requirement.

Security and recovery `SHOULD` requirements explain the conditions under which
deviation is acceptable. Normative `MUST`, `MUST NOT`, and such `SHOULD`
statements without a stable ID are invalid once this spec leaves `draft`.

## 4. Implementation, tests, and journeys

Summarize the intended mapping. The authoritative machine-readable mapping is
in `CONFORMANCE.json` and includes:

- implementation files or symbols;
- automated test IDs/locations;
- physical journey IDs when machine-only proof is insufficient;
- conformance state and evidence.

Mappings use `path:symbol` or `path::test_name` and the selector must resolve in
the named file. A `sha256:` evidence artifact also names its repository-relative
source file; commit evidence uses `source: null`. Commit evidence remains
current only while every mapped implementation and test selector fragment
matches between the evidence commit and the current tree.
For physical journey promotion, one redacted evidence artifact may cover a
superset of requirements, but the signed journey-result may claim only IDs
present in that artifact.

## 5. Open gaps

Record each unresolved mismatch with exactly one arbitration verdict, owner,
and issue. Do not resolve a gap by making the spec mirror code without the
required decision/evidence.

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-NNN-R001` | `UNKNOWN` | `@owner` | `#NNN` | Description |

## 6. Evidence

List human-readable evidence pointers. Machine-enforced evidence, capture date,
and expiry live in `CONFORMANCE.json`. Identify any required physical hardware
role and journey contract version.

## 7. Current contract notes

Keep only explanatory material needed to implement the current contract.

## 8. Changelog and history

Keep a concise version-to-decision summary here. Move superseded wording,
reconstruction notes, audit transcripts, and long narratives to
`docs/spec-history/` or `audits/` and link them. Git retains the full edit
history.
