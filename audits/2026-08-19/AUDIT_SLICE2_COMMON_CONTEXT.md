# SPEC-042 manifest slice 2 — audit context (shared across lanes)

You are auditing a single, self-contained implementation slice in the macprovider
coordinator (Go, phase4-coordinator). Review the FULL fix diff as it will land:

    git -C /Users/augstar/macprovider-spec042-manifest-sig diff d8f6b31b..HEAD

(equivalently the patch at
`audits/2026-08-19/slice2-manifest-sig-fulldiff.patch`). Base commit is
`d8f6b31b` (origin/main), which already contains slice 1 (the canonical manifest
encoding in `phase4-coordinator/internal/poolmanifest/manifest.go`).

## What this slice is

SPEC-042 "Trusted Pools" is a Layer-2 administrative-trust substrate. Slice 1
froze the canonical byte grammar for a pool's identity core (→ `pool_id`) and
versioned policy core (→ `manifest_core_digest`). **Slice 2 (this diff) makes that
encoding trust-bearing**: given a signer set, decide whether a signed policy core
is authentic, authorized, and threshold-met. New file:
`phase4-coordinator/internal/poolmanifest/signature.go` (+ `signature_test.go`,
design doc, SPEC 0.0.8→0.0.9, CONFORMANCE R001/R012 records, regenerated README).

Core API:
- `PolicyCoreSigningMessage(digest)` = `"macprovider/spec042/policy-core-sig/v1" ‖ manifest_core_digest`.
- `SignerSet{Version, Keys[], Threshold M, NotBeforeUnix, ExpiresAtUnix, Revoked}` + `Validate()`.
- `VerifyPolicyCore(core, sigs, signerSet)` — signer_set_version match; unrevoked
  signer set whose half-open `[NotBefore,Expires)` window contains the policy's
  `not_before_unix`; recomputed `manifest_core_digest`; and M-of-N over DISTINCT
  AUTHORIZED VALID signatures.
- `VerifyPoolIDBinding(identityCore, claimedPoolID)` — recompute-and-compare.

## Scope boundaries (NOT defects — do not report these as missing)

This is a deliberately layered slice. The following are explicitly deferred to
later slices and are documented as such in the design doc and SPEC:
- The **authority log** (SPEC-042-R012) that establishes and versions signer sets,
  its hash-chained append-only entry grammar, root-issuer/prior-set signatures,
  rollback/threshold/hash-chain checks, and the only writer of `SignerSet.Revoked`.
  Slice 2 verifies a policy core against a signer set it is HANDED; it does not
  construct or look up signer sets.
- Stateful manifest rejects needing durable history: `manifest_version`
  monotonicity, `prev_manifest_core_hash` chaining, rollback, active-policy
  selection / validity-window overlap (slice 4), durable acceptance-verdict record
  for restart replay (slice 5).
- Mutable operational field signing (no encoding yet).
- Any wiring into live routing/settlement. The package is default-inert: nothing
  in the money path or request path calls it yet.

## Governing normative text

`specs/SPEC-042-pool-control-plane.md` R001 (manifest/identity/rollback + canonical
encoding + the new "Signature verification (policy core)" paragraph) and R012
(manifest authority + signer-set key lifecycle). Key R012 constraints this slice
must honor: a policy core is verified against EXACTLY its named `signer_set_version`;
the signer set must be valid (unrevoked, validity window containing the policy's
`not_before_unix`) — acceptance validity anchored to `not_before_unix`, never to
`manifest_version`; reject material signed under a not-yet-active/expired/revoked/
version-mismatched signer set; threshold `1 ≤ M ≤ N`.

## The bar

This is money-path-adjacent trust infrastructure (it will gate pool routing and
pool-labeled settlement once wired). Hold it to the money-path bar: report every
Critical / High / Medium with concrete exploit or failure scenario, file:line, and
a fix. The slice is not "done" until 0 Critical / 0 High / 0 Medium. LOW/INFO are
welcome but do not block. If you find nothing at a severity, say so explicitly.
Focus on the ACTUAL diff; do not invent requirements outside SPEC-042 R001/R012 or
re-litigate the documented slice boundaries above.
