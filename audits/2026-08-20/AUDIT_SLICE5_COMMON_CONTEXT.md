# SPEC-042 slice 5 (durable persistence + verdict-replay reconstruction) — audit context

Audit one self-contained slice in the macprovider coordinator (Go, phase4-coordinator).
Review the FULL fix diff:

    git -C /Users/augstar/macprovider-spec042-persist diff 2efc33fc..HEAD

Base 2efc33fc is origin/main with slices 1-4: manifest.go (encoding), signature.go
(policy-core M-of-N verification), authoritylog.go (authority log -> signer sets),
policyhistory.go (active-policy selection over policy cores).

## What this slice is

Slices 1-4 are pure crypto/logic over in-memory inputs. **Slice 5 makes a pool's
manifest state survivable across restart/failover** (SPEC-042-R011) and delivers the
R012 acceptance-verdict grandfathering. New file:
`phase4-coordinator/internal/poolmanifest/persist.go` (+ test, design doc, SPEC
0.0.11->0.0.12, CONFORMANCE R011/R012, README). Small additions to signature.go
(verifyPolicyCoreSignature) and policyhistory.go (shared internal builder).

Core API:
- `ManifestSnapshot{IdentityCore, RootIssuerKey, AuthorityLog []AuthorityLogEntry,
  Policies []AcceptedPolicyRecord}`; `AcceptedPolicyRecord{SignedCore, AcceptedAtUnix}`.
- `ManifestSnapshot.CanonicalBytes()` / `ParseManifestSnapshot([]byte)` — a reversible,
  deterministic, length-prefixed codec (a strict bounds-checked `decoder` mirrors the
  `encoder`; domain tag `macprovider/spec042/manifest-snapshot/v1`). Reversible STORAGE
  (preserves field order so Parse(CanonicalBytes(x))==x; carries signatures + epoch),
  NOT a signed wire object.
- `ReconstructPool(snapshot) (*ReconstructedPool, error)` — rebuilds the authority log
  (BuildAuthorityLog, full timeless re-verification) then the policy-core history via
  the shared builder with the TIMELESS `verifyPolicyCoreSignature` (signer-set Validate
  + exact signer_set_version + recomputed digest + M-of-N), which SKIPS the
  time-dependent revoked/window gate that online VerifyPolicyCore applies.

## The load-bearing property

R012: "the acceptance verdict ... MUST be durably recorded as final, so reconstruction
replays the recorded verdict rather than re-evaluating validity against the current
wall-clock." Concretely: a policy accepted under signer set v1, where v1 is LATER
revoked, must stay accepted across restart. The online build rejects it
(errSignerSetRevoked); ReconstructPool grandfathers it by re-verifying only the
TIMELESS signature and honoring the recorded verdict. This is the timeless
(re-verify: authority-log chain, M-of-N signatures, structural rules) vs
time-dependent (replay: the revoked/window gate) split.

## Scope boundaries (NOT defects — do not report as missing)

- **Wiring into the live coordinator store** (SQLite/Postgres schema, the
  record-on-acceptance write path, the read-at-boot path) — the enable path. This
  slice is a pure codec + reconstruction function: WHAT is persisted and HOW it is
  replayed, not WHERE the bytes live.
- The membership ledger / revocation blocklist / lifecycle state that R011 also lists
  live in the trustpool/registry layer (already durable in earlier merged work); this
  slice covers the MANIFEST half.
- The snapshot is coordinator-internal trusted storage; it is intentionally NOT signed
  as a whole — integrity comes from the trusted store plus the timeless
  re-verification. (Do not report "snapshot not signed" as a defect.)

## Governing normative text

`specs/SPEC-042-pool-control-plane.md` R011 (reconstruct pool state from durable
storage across restart/failover) and R012 (acceptance verdict recorded as final;
replay rather than re-evaluate against current wall-clock).

## The bar

Trust infrastructure. Money-path bar: report every Critical / High / Medium with a
concrete exploit/failure scenario, file:line, and a fix. Not "done" until 0 C/0 H/0 M.
LOW/INFO welcome, non-blocking. Focus on the ACTUAL diff; do not re-litigate the
documented slice boundaries.
