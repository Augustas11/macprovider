# SPEC-042 slice 3 (authority log) — audit context (shared across lanes)

You are auditing one self-contained slice in the macprovider coordinator (Go,
phase4-coordinator). Review the FULL fix diff as it will land:

    git -C /Users/augstar/macprovider-spec042-authlog diff ac9defdc..HEAD

(patch: `audits/2026-08-20/slice3-authlog-fulldiff.patch`). Base `ac9defdc` is
origin/main and already contains slice 1 (`manifest.go`, canonical encoding) and
slice 2 (`signature.go`, policy-core M-of-N signature verification against a
`SignerSet`).

## What this slice is

SPEC-042 "Trusted Pools" is a Layer-2 administrative-trust substrate. Slice 2
verifies a policy core against a `SignerSet` it is HANDED. **Slice 3 (this diff) is
where that `SignerSet` comes from**: the append-only, hash-chained **authority log**
(SPEC-042-R012) that the pool's root issuer uses to establish, version, and revoke
operational signer sets. New file:
`phase4-coordinator/internal/poolmanifest/authoritylog.go` (+ `authoritylog_test.go`,
design doc, SPEC 0.0.9→0.0.10, CONFORMANCE R012, README). Plus a small refactor in
`signature.go` extracting `verifyThresholdMessage` (policy-core verification is meant
to be byte-identical — verify that).

Core API:
- `AuthorityLogEntry` — content (SignerSetVersion, PrevAuthorityLogEntryHash, Keys,
  Threshold, NotBefore/Expires, RevokesVersions, AuthorizingSignerSetVersion) +
  Signatures (not hashed).
- `CanonicalContentBytes()` / `EntryHash()` / `AuthorityLogEntrySigningMessage()` —
  domain-separated length-prefixed grammar; `entry_hash = SHA256(content)`; sig
  message = `...-entry-sig/v1 ‖ entry_hash`.
- `BuildAuthorityLog(rootIssuer SignerKey, entries []AuthorityLogEntry)
  (*AuthorityLog, error)` — replays and verifies the chain, materializing
  `signer_set_version → SignerSet` with `Revoked` stamped.
- `IdentityCore.BindsRootIssuer(rootIssuer)` — binds the trust anchor to the pool id.

Per-entry replay checks: signer-set `Validate()` (`1≤M≤N`, distinct key ids, distinct
public keys, non-empty window); strictly-monotonic `signer_set_version` (rollback
rejected); prev-hash chain (genesis prev = 32 zero bytes); `revokes_versions`
ascending/distinct and each a prior existing version (no self/future/nonexistent);
authorization by EITHER exactly one root-issuer signature (`authorizing=0`) OR M-of-N
of a prior still-authorized (unrevoked, window contains the new entry's `not_before`)
lower-versioned set. Authorization is checked BEFORE the entry's own revocations
apply (rotate-and-revoke).

## Scope boundaries (NOT defects — do not report these as missing)

Deferred to later slices, documented in the design doc + SPEC:
- **Durable persistence + restart/failover reconstruction** of the log, the
  highest-accepted-version store, and the **durable per-request acceptance-verdict
  record** (R012's "recorded as final") — slice 5. This slice is pure (in-memory
  entry list, no clock, no I/O).
- **Emergency pool-lifecycle control messages** (paused/draining/revoke_immediate,
  R011/R003) — a separate structure. Signer-set *revocation* IS in this slice.
- **Operator-provenance binding** (R012 option a/b) and root-issuer-compromise
  `supersedes` lineage — buyer-surface / pool-identity concerns.
- Wiring materialized sets into live routing/settlement (slice 6).

## Governing normative text

`specs/SPEC-042-pool-control-plane.md` R012 (manifest authority + key lifecycle),
especially the new "Authority-log entry encoding and chain verification" paragraph,
and R001. Load-bearing R012 constraints this slice must honor: each authority-log
entry carries monotonic `signer_set_version`, prev/self hash chain, authorized signer
key ids, threshold `M`-of-`N` with `1≤M≤N`, a validity window, and a signature from
the root issuer or a prior still-authorized signer set; reject any entry `≤` the
highest accepted version (rollback), that breaks the hash chain, uses a revoked
signer set, or declares `M<1 || M>N`. A policy core is verified against exactly its
`signer_set_version`, valid (unrevoked + window containing `not_before_unix`) at the
policy's acceptance epoch.

## The bar

This is trust infrastructure that will gate pool routing + pool-labeled settlement
once wired. Money-path bar: report every Critical / High / Medium with a concrete
exploit or failure scenario, file:line, and a fix. Not "done" until 0 C / 0 H / 0 M.
LOW/INFO welcome but non-blocking. Focus on the ACTUAL diff; do not re-litigate the
documented slice boundaries above or invent requirements outside SPEC-042 R001/R012.
