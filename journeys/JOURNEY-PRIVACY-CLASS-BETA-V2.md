# JOURNEY-PRIVACY-CLASS-BETA-V2

Status: draft journey contract; no implementation evidence
Owner: operator-constrained privacy class
Specs: SPEC-049
Requirements: SPEC-049-R001, SPEC-049-R002, SPEC-049-R003, SPEC-049-R004,
SPEC-049-R005, SPEC-049-R006, SPEC-049-R007, SPEC-049-R008, SPEC-049-R009,
SPEC-049-R010, SPEC-049-R011, SPEC-049-R012, SPEC-049-R013, SPEC-049-R014,
SPEC-049-R015, SPEC-049-R016, SPEC-049-R017, SPEC-049-R018, SPEC-049-R019,
SPEC-049-R020, SPEC-049-R021, SPEC-049-R022, SPEC-049-R023, SPEC-049-R024,
SPEC-049-R025, SPEC-049-R026, SPEC-049-R027, SPEC-049-R028
Authority domains: operator-constrained-privacy-class,
verified-model-settlement, inference-receipts, provider-wire-protocol
Issue: https://github.com/Augustas11/macprovider/issues/1749
Execution mode: provider-privacy-class-beta

## Purpose

This is the v0.2 privacy-class physical evidence profile. A signed result of
this journey must rerun the full v1 baseline on the same exact signed and
notarized release identity, then add the v0.2 automatic-mode, enrollment,
reenrollment, release-derived approval, and operator-signed directory evidence.
The five v0.2 steps are not an extension-only proof.

The result remains evidence-only while SPEC-049-R023 is open. It MUST NOT
promote SPEC-049-R023 on its own because production promotion still requires a
staged canary, the canary outcome, and three-lane audits.

## Required steps

Steps `step-01-bind-signed-release` through `step-16-redaction-review` are the
same baseline contract as `JOURNEY-PRIVACY-CLASS-BETA`.

17. `step-17-auto-mode-eligibility` proves automatic eligible, automatic
    ineligible, automatic hardening fallback, explicit opt-out, and explicit
    plain relay-blind modes from raw launch/config/client captures.
18. `step-18-auto-enrollment-distinct-identities` proves durable enrollment for
    at least two distinct provider identities, posture-after-commit ordering,
    failed posture non-enrollment, and cross-provider key-reuse refusal.
19. `step-19-key-change-quarantine-reenroll` proves key-change quarantine,
    privacy key-record revocation, no implicit replacement, repeated quarantine
    after expiry, operator reenroll, held-reservation rejection, and enrollment
    of new keys after reenroll.
20. `step-20-release-derived-approval` proves the tested release identity is
    approved from signed release metadata, failed metadata contributes nothing,
    denied cdhash quarantine, and withdrawal or expiry removes eligibility.
21. `step-21-operator-signed-directory` proves directory signature verification
    under the pinned public key, tamper/expiry/revocation/wrong-key rejection,
    gateway byte-for-byte forwarding with `Cache-Control: no-store`, closed
    store-error behavior, and the exact 13-entry v0.2 residual-risk disclosure.

## Required evidence contract

The reviewed redacted evidence manifest MUST be committed under:

```text
journeys/evidence/privacy-class-beta-*.redacted.json
```

It MUST be the same closed object shape as v1, except:

- `schema_version` is `macprovider.privacy-class-beta-evidence.v2`;
- `journey_id` is `JOURNEY-PRIVACY-CLASS-BETA-V2`;
- `steps` contains the 16 baseline steps plus steps 17 through 21 above;
- `observations` contains all v1 observations plus the v0.2 observations in
  `scripts/privacy_class_beta_journey_evidence.py`.

The source facts for steps 17 through 21 are exported under
`primary/v2/sources/`. The five `primary/v2/*.json` files are summaries and
provenance manifests, not proof by themselves. Each manifest MUST contain the
closed `macprovider.privacy-class-beta-v2-source.v1` profile and exactly the
`{kind,path,sha256}` rows declared by `V2_SOURCE_CONTRACT` in
`scripts/privacy_class_beta_journey_evidence.py`. The extractor has the same
contract and copies the exact bytes from these closed raw paths:

- automatic mode: non-secret launch, loaded config, accepted-session, bounded
  stdout/stderr, and before/after database captures;
- enrollment: database captures before and after first admission, second
  admission, cross-provider reuse, and failed posture, plus actual client
  response excerpts;
- reenrollment: initial, key-change, post-expiry retry, operator-clear, and
  post-reenrollment database captures, plus actual client response excerpts;
- release approval: exact release metadata, ECDSA signature bytes, the pinned
  release public key, a separate trusted-key-signed invalid metadata fixture,
  lstat facts, loaded eligibility/client captures, and approved, denied, and
  withdrawn database captures;
- directory: exact signed envelope bytes, the buyer's out-of-band pinned
  Ed25519 public-key capture, exact gateway body, allowlisted response headers,
  client negative captures, enrollment/revocation store facts, and the emitted
  residual-risk disclosure.

Raw captures live only under `evidence/v2-raw/`; their exact paths and kinds
are authoritative in `V2_SOURCE_CONTRACT`. The extractor rejects absent or
extra raw files, kind/path drift, hash drift, duplicate JSON keys, malformed
JSON, oversized sources, and symlink or non-regular-file substitution. It
copies public signature bytes without redaction so verification is over the
original bytes. The reviewed bundle permits binary bytes only for the two
closed public release-signature source paths; all other artifacts remain UTF-8
and subject to the ordinary path, secret, private-key, and needle sweeps.

Every database phase capture MUST contain a positive `captured_at_unix` and
complete, untruncated exports of exactly these public-state tables:
`privacy_class_enrollment`, `relay_blind_key_records`,
`privacy_class_quarantine`, `relay_blind_reservations`, and
`privacy_class_operator_clear`. The per-table public column allowlists live in
`V2_DB_COLUMNS`; extra, omitted, or reordered columns and rows that do not
exactly match the projection are rejected. No buyer key, private key,
ciphertext, request body, token, or credential field is part of this export.

Launch captures contain only the executable digest, capture time, and the two
non-secret mode arguments. They MUST NOT copy argv, environment, config files,
credentials, or host paths wholesale. Gateway header captures are closed and
contain no authorization or cookie value. Successful client captures retain
only the provider ID, HTTP status, and the actual
`usage_macprovider_privacy.posture_verified_at_unix` response excerpt; that
timestamp is not accepted as a free-standing asserted field. Error captures
retain only the actual error code.

The validator independently recomputes enrollment ordering and uniqueness,
key revocation and quarantine transitions, operator-clear effects, database
key-advertisement deltas, release-signature validity and repository trust-key
identity, directory signature/key-id/fingerprint/expiry/revocation facts, and
gateway byte identity. Summary booleans or conclusions can only pass when they
equal that recomputation. The exact v0.2 disclosure is also a bound raw source,
not a validator-supplied conclusion.

The step artifacts for steps 17 through 21 are the five
`primary/v2/*.json` manifests. Their journey digests therefore bind the exact
primary source digests used by each predicate. Composition MUST select the
profile explicitly:

```text
build-privacy-class-beta-journey-result.py compose-evidence --profile v2 ...
```

The default remains `v1`; v2 is never inferred from files found in a bundle.
An incomplete v2 bundle fails composition instead of silently producing a v1
result. This document and the synthetic contract tests do not constitute a lab
run: all hardware observations and a signed v2 PASS result remain pending a
genuine designated-Mac-Studio capture.
