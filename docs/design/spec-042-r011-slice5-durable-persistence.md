# SPEC-042 R011/R012 slice 5 — durable persistence + verdict-replay reconstruction

Status: design → implementation. Coordinator-only (phase4), extends
`internal/poolmanifest`. Fifth of the manifest epic. Slices 1–4 are pure crypto/logic
over in-memory inputs; this slice makes a pool's manifest state **survivable**: a
reversible canonical snapshot codec, and a reconstruction that rebuilds the authority
log (slice 3) and policy-core history (slice 4) from durable records — **replaying
the recorded acceptance verdicts** rather than re-evaluating time-dependent validity
against the current wall-clock (SPEC-042-R011/R012).

## 1. The load-bearing property (why this slice exists)

R012 requires: "The acceptance verdict and the epoch at which it was made MUST be
durably recorded as final, so restart/failover reconstruction replays the recorded
verdict rather than re-evaluating validity against the current wall-clock (which
could flip an accepted policy to rejected after its signer set later expires)."

Concretely: a policy core accepted under signer set v1, where v1 is **later revoked**
(the authority log rotates to v2 and revokes v1), MUST stay accepted across a
restart. But slice-4 `BuildPolicyHistory` calls `VerifyPolicyCore`, which rejects a
policy under a revoked signer set (`errSignerSetRevoked`). So a naive
"reconstruct = re-run the online build" would wrongly reject the grandfathered
policy. Reconstruction MUST instead **replay the recorded verdict**.

### What reconstruction re-checks vs replays

- **Re-verified (timeless, safe to recompute, detects store corruption):** the
  authority-log chain in full (its authorization is over fixed data — root/prior-set
  signatures and data-vs-data window checks, no wall-clock), and each recorded
  policy's **M-of-N signature** over its digest (a valid signature stays valid
  forever), plus the structural rules (`pool_id`, monotonic `manifest_version`,
  `prev_manifest_core_hash` chain, non-overlapping windows).
- **Replayed, NOT re-evaluated:** the **time-dependent** signer-set gate — whether
  the signer set was unrevoked and its window contained the policy's `not_before` at
  acceptance. That verdict was recorded final; reconstruction honors it, so a
  later-revoked or later-expired signer set does not retroactively invalidate an
  already-accepted policy.

This is exactly the timeless/time-dependent split: reconstruction keeps every check
that is a pure function of the bytes, and trusts the durable record only for the one
thing that depended on the clock at acceptance time.

## 2. Snapshot (durable state)

```go
type AcceptedPolicyRecord struct {
    SignedCore     SignedPolicyCore // the accepted policy core + its signatures
    AcceptedAtUnix uint64           // the epoch the verdict was recorded as final (R012)
}

type ManifestSnapshot struct {
    IdentityCore  IdentityCore
    RootIssuerKey SignerKey           // the pool root issuer (id must bind IdentityCore)
    AuthorityLog  []AuthorityLogEntry  // in chain order
    Policies      []AcceptedPolicyRecord // in ascending manifest_version order
}
```

### 2.1 Canonical, reversible codec

`ManifestSnapshot.CanonicalBytes()` / `ParseManifestSnapshot([]byte)` use the same
length-prefixed framing as the rest of the package (a new **`decoder`** mirrors the
existing `encoder`), under the domain tag `macprovider/spec042/manifest-snapshot/v1`.
Unlike the *signed preimage* encodings of slices 1–3, this is **reversible storage**:
it preserves field order exactly (e.g. `ModelAllowlist` is stored as given, not
set-sorted), so `Parse(CanonicalBytes(x)) == x` **up to empty-slice canonicalization**
— a count-zero list decodes to `nil`, so a `[]T{}` field round-trips to `nil` (both
encode identically, and reconstruction treats nil and empty the same). It carries the
signatures and the `AcceptedAtUnix` epoch that the preimages omit. Encoding is
deterministic; decoding is strict — every read is bounds-checked, list counts are
capped and appended as decoded (so a malformed count cannot force an oversized
allocation), non-`0x00`/`0x01` booleans are rejected, decoded byte fields are copied
(never alias the input), and trailing bytes are rejected. The format is frozen by a
golden digest + a round-trip vector.

Note the snapshot is **coordinator-internal durable storage**, not a signed wire
object — its integrity comes from the trusted store plus the timeless re-verification
in §3, not from a signature over the snapshot itself.

## 3. Reconstruction

`ReconstructPool(snapshot ManifestSnapshot) (*ReconstructedPool, error)` where
`ReconstructedPool{ AuthorityLog *AuthorityLog; PolicyHistory *PolicyHistory }`:

1. **Authority log** — `BuildAuthorityLog(ic, rootIssuer, snapshot.AuthorityLog)`
   (slice 3, unchanged): full timeless re-verification, materializing
   `signer_set_version → SignerSet` with revocation state.
2. **Policy history (verdict replay)** — the same structural acceptance as slice-4
   `BuildPolicyHistory` (`pool_id` binding, window well-formed, monotonic version,
   prev-hash chain, non-overlap, signer-set lookup), but the per-core verify step is
   the **timeless** `verifyPolicyCoreSignature` (signer-set `Validate`, exact
   `signer_set_version`, recomputed digest, M-of-N distinct authorized signatures) —
   it does **not** re-apply the `Revoked`/window gate. So a policy under a
   now-revoked signer set is accepted on reconstruction (grandfathered) exactly when
   its recorded signature still verifies.

Slice 4 and slice 5 share one internal builder parameterized by the per-core verify
function (online = full `VerifyPolicyCore`; reconstruction = timeless
`verifyPolicyCoreSignature`), so the structural rules cannot drift between them.
`ActivePolicy(now)` then behaves identically on the reconstructed history.

## 4. Scope boundary (deferred)

- **Wiring into the live coordinator store** (SQLite/Postgres schema, the write path
  that records a verdict at online acceptance, the read path at boot) — the enable
  path / slice 6. This slice is a pure codec + reconstruction function; it defines
  *what* is persisted and *how* it is replayed, not *where* the bytes live.
- The **membership ledger, revocation blocklist, and lifecycle state** that R011 also
  lists for reconstruction live in the trustpool/registry layer (already durable in
  the earlier merged work); this slice covers the **manifest** half (authority log +
  policy history + verdicts).
- Emergency signed lifecycle control messages, operator-provenance, and the
  settlement-time "which policy governed a settled request" lookup remain later.

## 5. Golden / behavioral vectors

Fixed-seed keys build a pool with a rotate-and-revoke authority log (signer set v1
revoked by v2) and accepted policy records. Assertions:

- **round-trip** — `Parse(CanonicalBytes(snapshot))` deep-equals the snapshot;
- **determinism** — `CanonicalBytes` is stable (pinned SHA-256), and strict decoding
  rejects truncated / trailing-byte inputs;
- **reconstruction == online** for a non-revoked signer set (same active policy);
- **grandfathering** (the load-bearing vector) — a policy accepted under signer set
  v1 is **rejected** by online `BuildPolicyHistory` (`errSignerSetRevoked`, because
  v1 is now revoked) but **accepted** by `ReconstructPool`, and is returned by
  `ActivePolicy` within its window;
- **corruption caught** — a recorded policy whose signature is tampered is rejected on
  reconstruction (timeless signature re-verification still runs).

## 6. API synopsis

```go
type AcceptedPolicyRecord struct { SignedCore SignedPolicyCore; AcceptedAtUnix uint64 }
type ManifestSnapshot struct { IdentityCore IdentityCore; RootIssuerKey SignerKey; AuthorityLog []AuthorityLogEntry; Policies []AcceptedPolicyRecord }
type ReconstructedPool struct { AuthorityLog *AuthorityLog; PolicyHistory *PolicyHistory }

func (ManifestSnapshot) CanonicalBytes() ([]byte, error)
func ParseManifestSnapshot(b []byte) (ManifestSnapshot, error)
func ReconstructPool(snapshot ManifestSnapshot) (*ReconstructedPool, error)
```

Everything here is a pure, total function of its inputs; no I/O, no ambient clock.
