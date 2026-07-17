# SPEC governance foundation architecture

PR #619 establishes a structured governance foundation for the canonical
`specs/SPEC-NNN-*.md` corpus. The authoritative machine-readable sources are:

- `specs/AUTHORITY.json` for shared concept ownership and whether an
  authority domain requires signed physical journey results;
- `specs/CONFORMANCE.json` for SPEC metadata, requirement mappings, states,
  gaps, and evidence;
- `schemas/spec-authority-v1.schema.json`,
  `schemas/spec-conformance-v1.schema.json`, and
  `schemas/spec-pr-governance-v1.schema.json` for the public JSON contracts.

CI validates the manifests with `scripts/check_spec_governance.py`. The checker
uses only Python standard-library JSON, path, date, hash, and Git operations. It
validates unique SPEC and requirement IDs, unique bidirectional authority
ownership, signed-result gating metadata, lifecycle and conformance states,
structured cross-SPEC references, file mappings, journey references, evidence
dates, commit/digest evidence, and exact title/version alignment with canonical
SPEC headers.

PR declarations use an exact raw marker boundary:

```text
SPEC-GOVERNANCE-DECLARATION-BEGIN
{ "...": "JSON only" }
SPEC-GOVERNANCE-DECLARATION-END
```

The declaration parser reads only the bytes between those markers and parses
them as JSON. Markdown remains the human-readable documentation format, but
arbitrary Markdown rendering is outside the governance trust boundary. The
validator does not inspect prose for `MUST`, interpret CommonMark containers,
evaluate raw HTML, hide comments, process disclosure markup, or reconstruct
rendered links.

Deferred to issue #614:

- migrating legacy prose obligations into stable structured requirement IDs;
- reconciling each authority domain against implementation and journey
  evidence;
- defining the signed physical journey-result contract required for sensitive
  conformance promotion;
- reconciling SPEC-020, SPEC-023, and the #585 recovery lifecycle.
