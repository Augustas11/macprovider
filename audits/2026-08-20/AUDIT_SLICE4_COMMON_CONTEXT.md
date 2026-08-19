# SPEC-042 slice 4 (active-policy selection) — audit context (shared across lanes)

Audit one self-contained slice in the macprovider coordinator (Go, phase4-coordinator).
Review the FULL fix diff as it will land:

    git -C /Users/augstar/macprovider-spec042-policyhistory diff 1551d546..HEAD

Base 1551d546 is origin/main with slices 1-3: manifest.go (canonical encoding),
signature.go (policy-core M-of-N verification against a SignerSet), authoritylog.go
(the authority log that materializes signer_set_version -> SignerSet).

## What this slice is

Slice 3 versioned the SIGNER SETS. **Slice 4 versions the POLICY CORES signed by
them** (SPEC-042-R001 active-policy selection). New file:
`phase4-coordinator/internal/poolmanifest/policyhistory.go` (+ test, design doc,
SPEC 0.0.10->0.0.11, CONFORMANCE R001, README).

Core API:
- `SignedPolicyCore{Core PolicyCore; Signatures []Signature}`.
- `BuildPolicyHistory(ic IdentityCore, authLog *AuthorityLog, cores []SignedPolicyCore)
  (*PolicyHistory, error)` — accepts a pool's policy cores in ascending
  manifest_version order under the R001 rules.
- `(*PolicyHistory) ActivePolicy(nowUnix uint64) (PolicyCore, error)` — the single
  version whose half-open `[not_before, expires)` window contains now, else
  `errPoolPolicyStale` (the R010 `pool_policy_stale` fail-closed signal).
- `(*PolicyHistory) HighestVersion() uint64`.

Per-core acceptance (all must hold): (1) `core.PoolID == ic.PoolID()`; (2)
`not_before < expires`; (3) `manifest_version >= 1` and strictly increasing (rollback
rejected); (4) `prev_manifest_core_hash` chain (genesis = 32 zero bytes; else = prior
core's `manifest_core_digest`); (5) non-overlapping half-open window vs every accepted
version; (6) signature via `VerifyPolicyCore(core, sigs, authLog.SignerSet(core.SignerSetVersion))`
(exact signer-set version, unrevoked, signer-set window contains the policy's
not_before, recomputed digest, M-of-N distinct authorized). Accepted cores are
deep-copied (no aliasing through inputs or returned values).

## Scope boundaries (NOT defects — do not report as missing)

Deferred to later slices, documented in the design doc + SPEC:
- **Durable persistence + restart/failover reconstruction** of the policy-core
  history and highest-accepted `manifest_version`, and the **durable per-request
  acceptance-verdict record** (R012) — slice 5. This slice is pure: acceptance is a
  total function of `(ic, authLog, cores)`; selection takes `now` only as an explicit
  parameter. In particular, `BuildPolicyHistory` verifies each core against the
  authority-log state it is HANDED, so a policy accepted before its signer set was
  later revoked would be re-rejected on a from-scratch replay — grandfathering that
  via recorded verdicts is explicitly slice 5, NOT a defect here.
- Settlement-time "which policy was in force for a settled request" lookup, mutable
  operational fields, and wiring into live routing/admission (slice 6).

## Governing normative text

`specs/SPEC-042-pool-control-plane.md` R001, especially the "Active-policy selection"
paragraph (half-open `[not_before_unix, expires_at_unix)`, at most one active,
adjacent boundary allowed, future-dated pre-accepted but inactive, `pool_policy_stale`
on gap, reject overlapping windows) and the rollback/chain sentence (reject
non-monotonic `manifest_version`, `<=` last accepted = rollback, broken
`prev_manifest_core_hash` chain).

## The bar

Trust infrastructure that will gate pool admission once wired. Money-path bar: report
every Critical / High / Medium with a concrete exploit/failure scenario, file:line,
and a fix. Not "done" until 0 C / 0 H / 0 M. LOW/INFO welcome, non-blocking. Focus on
the ACTUAL diff; do not re-litigate the documented slice boundaries.
