# SPEC governance process

This document governs the canonical `specs/SPEC-NNN-*.md` corpus. It controls
contract ownership and conformance; it does not make deployed behavior
authoritative merely because it exists.

## Lifecycle

Every canonical spec is recorded in `CONFORMANCE.json` with exactly one status:

- `draft`: under design; not a release contract.
- `normative`: reviewed and binding, but implementation/production proof is
  tracked separately.
- `implemented-unverified`: implemented, without current complete physical or
  production evidence where that evidence is required.
- `physically-verified`: the mapped implementation, tests, and required
  physical journeys have current evidence.
- `deprecated`: no longer authoritative; it names its successor or states that
  no successor exists.

Lifecycle status is not conformance. A draft may describe shipped behavior and
a normative spec may have known code defects. `implemented-unverified` and
`physically-verified` require evidence in `CONFORMANCE.json`; prose claims are
not enough.

Forward transitions are `draft → normative → implemented-unverified →
physically-verified`; any live status may transition to `deprecated`, and a
status may remain unchanged. Reverse transitions and revival of a deprecated
spec are invalid. The validator compares the PR head to its trusted base and
also rejects silent owner changes.

## Mismatch arbitration

Every discovered mismatch receives exactly one verdict before either artifact
is changed:

| Verdict | Meaning | Required action |
|---|---|---|
| `CODE_BUG` | The normative requirement remains valid and code violates it. | Fix code and tests; retain the requirement. |
| `SPEC_BUG` | Shipped behavior is explicitly accepted and verified by the owning journey/decision authority. | Update the spec and record the decision and evidence. |
| `DECISION_REQUIRED` | The requirement is ambiguous or neither behavior is acceptable. | Decide explicitly, then update spec, code, tests, and mappings atomically. |
| `DUPLICATE_AUTHORITY` | More than one spec defines the same concept. | Select one owner and replace other definitions with references. |
| `UNKNOWN` | Behavior or production state cannot be verified. | Do not guess; record an owner and blocking issue. |

The accepted end-to-end journey plus explicit product, security, and
architecture decisions arbitrate. The last-edited artifact and the currently
deployed behavior do not.

## Authority

`AUTHORITY.json` names exactly one owning spec for each tracked shared field,
identity, catalog, protocol transition, and lifecycle transition. A consumer
spec references the owner and may add local integration constraints, but may
not restate or redefine the owned contract. New shared concepts must be added
to the authority manifest in the same PR that introduces them. Pending
reconciliation is explicit and issue-linked; it is not permission for a second
owner. Both governance manifests use deterministic JSON with unique object
keys; duplicate keys are invalid rather than last-value-wins aliases.

## Requirement IDs

Each new or migrated normative `MUST`, `MUST NOT`, and security/recovery
`SHOULD` has one stable ID in the form `SPEC-NNN-RMMM`, where `NNN` is the
owning spec and `MMM` is a zero-padded, never-reused sequence. Define an ID once
using the format in `TEMPLATE.md`; later mentions are references. Moving text
does not change its ID. Deleted or superseded IDs remain reserved and their
history is retained. Existing clauses without canonical IDs are tracked as
pending migration gaps in `CONFORMANCE.json`; no wildcard mapping is allowed.
Existing clauses without stable IDs remain explicit pending gaps in
`CONFORMANCE.json`. The foundation does not infer which prose is normative; a
later reconciliation PR migrates requirements into structured IDs and mappings
before claiming conformance.

Canonical SPEC IDs, stable requirement IDs, and authority-domain IDs are
append-only identities. The trusted base manifest/spec corpus is the tombstone
ledger: deletion or reuse fails validation, and authority-owner changes require
a versioned governance migration rather than an ordinary manifest edit.

## Conformance and evidence

`CONFORMANCE.json` maps every canonical requirement ID to implementation
locations, automated tests, physical journey IDs where machine-only proof is
insufficient, a conformance state, and evidence. Allowed states are
`pending`, `blocked`, `conformant`, `nonconformant`, and `not-applicable`.

- `conformant` requires implementation mapping, a test or journey, reachable
  commit evidence for the code mappings, and current evidence with an expiry
  date. Every mapped source and test file must still match that evidence
  commit; a later file change invalidates the evidence even when its selector
  text remains present.
- `pending`, `blocked`, and `nonconformant` require an arbitration verdict,
  owner, and issue.
- `not-applicable` requires a recorded rationale and owner.
- Signing, identity, update, migration, restart/rollback, admission, and
  release behavior require mapped physical journeys; unit tests alone cannot
  establish physical conformance.
- Every journey ID resolves to `journeys/JOURNEY-NAME.md`; an invented ID is
  not evidence. Sensitive conformant requirements also carry a recomputable
  SHA-256 artifact under `journeys/evidence/`.
- Authority domains that require a signed physical result set
  `requires_signed_journey_result: true` in `AUTHORITY.json`. Requirements in
  those domains can become `conformant` only when a mapped journey has a
  SHA-256 evidence artifact under `journeys/evidence/` whose bytes reproduce
  the digest and whose signed envelope has the shape defined by
  `schemas/journey-result-v1.schema.json`. The governance validator is the
  normative enforcement path for semantic checks the schema cannot prove by
  itself: an `ecdsa-p256-sha256` signature over
  `macprovider.journey-result.v1\n` plus canonical sorted compact JSON,
  verified against the pinned
  `security/acceptance-candidate-signing-public.pem` trust anchor, the mapped
  journey ID, the promoted requirement ID, a repository commit matching the
  requirement's commit evidence, operator and environment bindings, a passing
  run result, passing step results that reference hash-bound artifacts, current
  expiry, and explicit redaction confirmations. A Markdown journey description,
  arbitrary digest, mutable public key, or self-asserted signature status alone
  cannot promote lifecycle state.
- Evidence records the proving reachable commit or an immutable artifact whose
  repository source bytes reproduce its SHA-256 digest, plus capture date and
  expiry. Expired evidence fails validation rather than silently downgrading.
- Implementation and test mappings name repository files plus selectors that
  resolve in those files; physical journey IDs resolve to tracked journey
  records. Evidence uses a reachable full commit SHA or a SHA-256 digest
  recomputed from a repository artifact. Future capture dates and arbitrary
  trust strings are invalid.

## Deprecation and history

Canonical specs contain the current contract, its conformance summary, and
issue-linked open gaps. Superseded wording, reconstruction notes, and long
change narratives belong in `docs/spec-history/` or `audits/`; Git remains the
complete revision history. A deprecated spec must identify its successor and
must not retain active authority domains. Each formerly owned domain remains in
`AUTHORITY.json` as an immutable `deprecated` tombstone with its original
owner; the deprecated domain is removed from the spec's active
`authority_domains` list. Historical documents must not use the canonical
header shape or appear in the generated index.

## Pull requests and release gates

Behavior-changing PRs must list affected spec IDs, requirement IDs, authority
domains, arbitration verdicts, tests, and journeys. A PR with no product
behavior change states `behavior-change: none`. Any change to a canonical SPEC
body, `AUTHORITY.json`, or `CONFORMANCE.json` additionally states
`contract-change: yes`; this prevents normative contract edits from hiding
inside the governance-only path allowlist. Changes to normative specs,
authority, conformance, validator logic, or release gates require review and
must pass the spec index, governance validator, targeted tests, and the three
repository audit lanes at 0 CRITICAL, 0 HIGH, and 0 MEDIUM.

A release may advance only when every affected requirement is conformant and
all required journey evidence is current. The physical release gate tracked by
GitHub issue #613 is the execution surface; this process does not create a
competing general waiver path. A one-time limited activation exception is valid
only when the affected normative SPEC and decision log both name its exact
scope, evidence, rollback, expiry, and unresolved journey. Such an exception
cannot mark the missing evidence conformant or close #613. Missing, stale,
skipped, or failed evidence otherwise blocks promotion.

## Release-scoped reconciliation slices

Issue #614 is the complete reconciliation program, not a standing blocker for
every release. A bounded release may name a narrower reconciliation slice when
the release scope is explicit, owned, and evidence-backed.

A release-scoped slice must record:

- the product outcome being released;
- the SPEC IDs, requirement IDs, and authority domains that are active for that
  outcome;
- the specs and requirements that are default-off, future, historical,
  not-deployed, or otherwise outside the release scope;
- the minimum journeys, automated tests, and production or physical evidence
  required for that outcome;
- the stop condition for promotion and the issue that tracks any remaining
  non-blocking conformance debt.

Unknown governance debt outside the named slice does not block the scoped
release. Unknown governance debt inside the named slice must be arbitrated as
`CODE_BUG`, `SPEC_BUG`, `DECISION_REQUIRED`, `DUPLICATE_AUTHORITY`, `UNKNOWN`,
`not-applicable`, or `not-deployed` before promotion. A release-scoped slice
may narrow the gate; it may not mark a requirement conformant without the
evidence required by this process.

Every PR body contains exactly one raw, marker-delimited JSON declaration:

```text
SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "none",
  "contract_change": "none",
  "specs": [],
  "requirements": [],
  "authority_domains": [],
  "arbitration": [],
  "tests": [],
  "journeys": []
}
SPEC-GOVERNANCE-DECLARATION-END
```

Use `"contract_change": "yes"` whenever canonical SPEC bodies,
`AUTHORITY.json`, or `CONFORMANCE.json` change, even when product behavior
remains unchanged. For a behavior change, use `"behavior_change": "yes"` and
fill non-empty `specs`, `arbitration`, `tests`, and `journeys` arrays
(`"not-required"` is explicit for a non-physical journey). SPEC IDs,
requirement IDs, and authority-domain IDs must resolve in the tracked
manifests. CI compares the declaration to the base-to-head diff on every pull
request; `"behavior_change": "none"` is accepted only for the
governance/documentation allowlist.

The declaration boundary is not Markdown. The validator reads the raw bytes
between the exact markers and parses them as JSON; it does not evaluate fenced
code, comments, disclosure blocks, rendered links, or other prose semantics.

## Reconciliation workflow

Reconcile one authority domain per bounded PR: inventory spec/code/tests/live
evidence, assign one arbitration verdict per mismatch, update the authoritative
spec and mappings, run mapped tests/journeys, attach evidence, then audit.
Unrelated domains remain available for development. The remaining program is
tracked by GitHub issue #614.
