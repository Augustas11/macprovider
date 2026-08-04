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

`beta/DECISION_CRITERIA.md` is the human decision log used by the arbitration
process for accepted product, security, architecture, release, and exception
decisions. It is not a machine-readable conformance manifest, but changes to it
are inside the SPEC governance review boundary because those decisions can be
used to justify `SPEC_BUG`, `DECISION_REQUIRED`, and release-exception outcomes.

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

## Provider pre-beta #614 slice

The first bounded #614 release slice is provider pre-beta. Its purpose is to
let the operator sign and admit new providers, keep their provider runtime
smooth through install, update, restart, model readiness, and admission, and
capture the provider-facing payout setup that is now part of launch readiness.

This slice is not a full buyer/API/money-path reconciliation. Buyer traffic is
in scope only as smoke evidence that an onboarded provider is routable and can
serve after the relevant provider lifecycle step. Full buyer API, settlement,
receipt, and paid-path conformance remains outside this slice unless a provider
pre-beta requirement explicitly depends on it.

Provider pre-beta active domains:

| Area | Specs | Scope |
| --- | --- | --- |
| Provider onboarding and admission | `SPEC-003`, `SPEC-025`, `SPEC-026`, `SPEC-034` | App/install entry, signed identity, referral or invite admission where applicable, and provider launch completion. |
| Provider runtime and release lifecycle | `SPEC-001`, `SPEC-020` | CLI identity, signing, update, restart, rollback, and provider reconnect readiness. |
| Model readiness and trust | `SPEC-010`, `SPEC-013`, `SPEC-023`, `SPEC-032`, `SPEC-033` | Catalog authority, autotune recommendation, hardware evidence, admission gates, and verifier evidence needed for admitted providers. |
| Provider payout setup | `SPEC-016` | Provider wallet registration, payout eligibility prerequisites, default-off runner boundary, and operator evidence needed before promising provider payout readiness. |
| Serving smoke | `SPEC-002`, `SPEC-006` only as needed | Minimal coordinator/gateway smoke that proves the provider serves after onboarding or lifecycle transitions. |

Deferred for provider pre-beta:

- full buyer API reconciliation beyond provider-serving smoke;
- full billing, settlement, verified receipt, and paid buyer-path conformance;
- default-off or future performance features such as `SPEC-024`, `SPEC-037`,
  `SPEC-038`, and `SPEC-039`, except where explicitly enabled for the provider
  cohort;
- historical component issues already closed in GitHub unless current evidence
  shows an active provider-prebeta regression.

Stop condition for this slice:

- every provider-prebeta active requirement has either a current conformance
  mapping or an explicit non-promoting state with owner, issue, and arbitration
  rationale;
- there is no unresolved `UNKNOWN` for provider install, signing, admission,
  update/restart/rollback, model readiness, hardware evidence, referral/invite
  admission, or provider payout setup;
- required physical journeys for signing, identity, update, restart/rollback,
  admission, and payout setup are named, and captured evidence is mapped where
  it exists;
- buyer traffic evidence is limited to smoke proof that the admitted provider
  serves successfully after the relevant provider lifecycle step;
- specs outside the slice are marked as deferred, default-off, not-deployed,
  future, or non-blocking for provider pre-beta rather than treated as hidden
  launch blockers.

The slice can reduce pre-beta release scope, but it cannot promote a sensitive
requirement to conformant until the evidence rules in `specs/PROCESS.md` are
satisfied. In particular, signed journey-result work remains the durable
promotion path for sensitive physical claims.
