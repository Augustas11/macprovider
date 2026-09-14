# Build 1 origin/main c944 reconciliation addendum r4

Status: proposed. This revision incorporates reconciliation r1 SHA-256
`353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`,
r2 SHA-256
`d3093609329f0177318913544fc6d0b351a26d1104b9c8cf43f176e0ff9db44a`,
and r3 SHA-256
`1455757afbcbd2b9ce09f1698281fb67b893f0e5d80adaebe5016c79e5d7742f`.
It resolves H6, M4, and M5 from independent GPT-5.6 Sol review
`origin-main-c944-plan-r3-sol.md` SHA-256
`c585a4062fe06f9d5208d2e9c8688330e12293beba22ce1528951da6c053ca4d`.
All requirements closed by r1-r3 remain in force. Reconciliation implementation
is blocked until the complete r1-r4 and r5-r8 bundle passes a fresh independent
gate at zero Critical, High, and Medium.

## R4-01 — authoritative SPEC-047 amendment before runtime

Before changing runtime code, amend the current c944 SPEC-047 v0.1.4 to the next
available version and update its version-of-record metadata, change history,
SPEC README, AUTHORITY/CONFORMANCE indexes, and exact R003/R008 selectors using
the repository governance tools. If another branch lands that consumes the
next version first, reconcile semantically and choose the next version; never
overwrite or silently combine its contract.

The amendment keeps c944's discriminator-free exact six-field artifact record
as an immutable historical schema. It normatively introduces the additive
route-snapshot extension `macprovider.artifact_admission.v2`: exactly one
`artifact_admission_schema` discriminator plus the exact 24 required fields
listed in reconciliation r3. SPEC-047 owns the complete envelope and cites the
existing owner rules rather than changing them:

- SPEC-010 and SPEC-023 own verified member identity, canonical algorithms,
  release/feed membership, and signer equality;
- SPEC-005/SPEC-023/SPEC-044 own signed rate identity, pricing arithmetic,
  provider share, multiplier, unit, and billing-snapshot authority;
- SPEC-011 owns the exact loaded provider session/model identity; and
- SPEC-015/SPEC-022 own receipt identity, immutable route digest binding, and
  verified settlement.

All 24 fields are all-or-none, non-null and included in the canonical route
snapshot preimage. The discriminator is separate from the gateway settlement
policy version and does not amend SPEC-022's minimum field list. Historical
c944 rows remain the exact six-key record with
`artifact_candidate_catalog_sha256`; no-extension rows remain empty. Neither
class is rewritten or upgraded by inference. Unknown schema values, extra or
duplicate keys, both catalog-hash spellings, partial v2, and any null field fail
closed before routing or settlement. This normative amendment does not enable
deployment, enforcement, economic activation, or new payout behavior.

The SPEC-047-R008 conformance contract names golden canonical bytes/digests for
no-extension, historical six-field, and v2 records; exact 24-field coverage;
missing/extra/duplicate/null/wrong-type cases; member/release/signer/model-key/
session/receipt-key/expiry/economics mismatch; restart/replay; and the rule that
historical settlement never consults current feed/index/keyring state.

## R4-02 — token-bound positive authority publication

`SetModelAdmissionAuthority` is part of the complete publication inventory. It
must no longer install or preserve a positive preparer directly. Retain it only
as a fail-closed compatibility operation, or remove it and migrate every caller;
either outcome first advances/invalidate paid admission authority.

The combined WS catalog/member-index publisher returns an opaque, server-owned
publication token containing the exact `autotuneCatalogMu` generation and
catalog/index pointers. Only a new positive-authority publisher can consume
that token after exact session refresh. It atomically installs resolver and
preparer under `modelAdmissionAuthorityMu` while comparing the still-current
WS catalog/index generation and the complete buyer/Tier2/billing/session epoch.
The token has unexported construction state and cannot be synthesized by a
provider, buyer request, test fixture, or another package. It is one-shot for
the exact server/generation; replacement, split setter use, clear, reload, or
failed publication invalidates it.

Production boot/reload therefore performs: invalidate authority; build and
validate immutable feeds/index/Tier2/billing state; publish WS catalog/index and
obtain its token; refresh sessions against that exact generation; install the
positive preparer by consuming the token and comparing every captured epoch.
Any failure leaves authority unavailable. Same-package tests use an explicit
test-only publisher that exercises the same combined/token checks; cross-package
tests compose the real publisher and may not regain the old direct bypass.

## R4-03 — raw-token null validation

The closed v2 decoder first tokenizes the object with duplicate-key detection
and retains a `json.RawMessage` for every allowed key. It checks exact key-set
membership and rejects literal JSON `null` for every string and numeric field
before decoding typed values. Only then may it decode integers and apply range,
relationship, and zero-valid economics rules. A missing field, a present null,
and numeric zero are three distinct states; permitted zero rates remain valid
only when the raw token was a JSON number whose exact integer value is zero.
Floating-point, exponent, quoted-number, overflow, boolean, array, and object
forms fail. Canonicalization uses the validated typed integers without losing
precision.

## R4 stop conditions

Stop before runtime work if SPEC-047 does not own the exact versioned envelope,
if a direct setter/test seam can install positive authority without the opaque
catalog/index token, if any numeric null reaches typed zero, or if historical
c944 canonical bytes require rewriting. These are gate failures, not
implementation discretion.
