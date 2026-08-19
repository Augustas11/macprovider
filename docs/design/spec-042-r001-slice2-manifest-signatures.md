# SPEC-042 R001/R012 slice 2 — manifest signature verification (M-of-N over a signer set)

Status: design → implementation. Coordinator-only (phase4), extends the existing
`internal/poolmanifest` package. Second of the R001 manifest epic. Builds directly
on slice 1 (canonical encoding + `pool_id`/`manifest_core_digest` derivations,
frozen by golden vectors) and makes that encoding **trust-bearing**: given a signer
set, decide whether a signed policy core is authentic, authorized, and threshold-met.

## 1. Scope

Deliver the signature layer that turns a canonical policy core into an accepted or
rejected signed record:

1. The **detached-signature wire shape** (`Signature{KeyID, Sig}`, Ed25519, base64url
   on the wire — matching the SPEC-014/tier2 catalog-signature precedent) and the
   **domain-separated signing preimage** for a policy core.
2. A **`SignerSet`** value type — the authorized keys, the `M`-of-`N` threshold, and a
   validity window — as the **input** to verification, with its own structural
   validation (`1 ≤ M ≤ N`, distinct key ids, well-formed keys).
3. **M-of-N threshold verification** with distinct-signer counting, and the
   policy-core accept/reject predicate that binds `signer_set_version`, the signer-set
   validity window, and the recomputed `manifest_core_digest`.
4. The **`pool_id` binding check** (recompute the identity-core digest and reject on
   mismatch against the carried `pool_id`, SPEC-042-R001).
5. **Golden vectors** (fixed seed-derived keypairs) that freeze the signing preimage
   and pin accept + every reject path.

Out of scope (later slices, called out so the boundary is explicit):

- The **authority log** (SPEC-042-R012) that *establishes and versions* signer sets —
  the append-only hash-chained log signed by the root issuer / prior signer set, its
  own byte grammar, and the lookup "given `signer_set_version`, return the `SignerSet`."
  Slice 2 verifies a policy core against a `SignerSet` it is **handed**; slice 3
  produces that value and its `Revoked` verdict. (`SignerSet.Revoked` is honored here
  but only ever *set* by slice 3.)
- **Stateful** manifest rejects that need durable history: `manifest_version`
  monotonicity, `prev_manifest_core_hash` chaining, rollback, and active-policy
  selection / validity-window overlap (slice 4), and the durable acceptance-verdict
  record for restart replay (slice 5).
- **Mutable operational field** signing (R001) — a separate signed structure with no
  defined encoding yet; the threshold primitive here is written to be reusable for it
  and for authority-log entries, but no mutable-field API ships in slice 2.

This slice is pure verification: no I/O, no persistence, no wall-clock — `crypto/ed25519`
+ `crypto/sha256` + stdlib only. Every check is a total function of its inputs.

## 2. What gets signed (policy-core signing preimage)

A signature is a detached Ed25519 signature over a domain-separated message:

```
policy_core_sig_message = tag("macprovider/spec042/policy-core-sig/v1") ‖ manifest_core_digest
```

where `manifest_core_digest = SHA256(canonical policy core)` from slice 1 (32 bytes).
The digest already commits to `pool_id`, `manifest_version`, `signer_set_version`, the
allowlist, every predicate, the R009 group, and the validity window — so signing the
digest binds the entire policy core. The **distinct signing tag** (note: `-sig/v1`, not
the `policy-core/v1` preimage tag of slice 1) domain-separates a policy-core signature
from the identity-core, authority-log-entry, and mutable-field signatures that later
slices will add, so a signature harvested from one structure can never be replayed as
another. Signing the 32-byte digest (rather than the full preimage) keeps the signed
message short; it is equivalent in strength under SHA-256 collision resistance, and the
signing tag lives outside the digest so it cannot be confused with a digest-preimage field.

## 3. Signer set (verification input)

```go
type SignerKey struct { KeyID string; PublicKey ed25519.PublicKey }
type SignerSet struct {
    Version       uint64        // signer_set_version this set embodies (SPEC-042-R012)
    Keys          []SignerKey   // N authorized signer keys, distinct key ids
    Threshold     uint32        // M; requires 1 ≤ M ≤ N
    NotBeforeUnix uint64        // validity window [NotBefore, Expires)
    ExpiresAtUnix uint64
    Revoked       bool          // set only by the slice-3 authority log
}
```

`Validate()` enforces `N = len(Keys) ≥ 1`, `1 ≤ Threshold ≤ N`, distinct non-empty key
ids, each `PublicKey` exactly `ed25519.PublicKeySize`, **distinct public-key bytes**,
and `NotBeforeUnix < ExpiresAtUnix`. `Validate()` is a structural check on the set
itself and does **not** consult the clock or any policy — window *applicability* is
evaluated per policy (§4).

Distinct public-key bytes are load-bearing, not cosmetic: because threshold counting
dedupes signatures by key id (§4.1), a set carrying the same public key under two key
ids would let the holder of a *single* private key present the same valid signature
under both ids and satisfy a 2-of-N threshold with one key — collapsing M-of-N. This
slice rejects duplicate public keys at the trust-primitive boundary so the M-of-N
independence invariant holds regardless of how the slice-3 authority log builds the
set (defense in depth: slice 3 SHOULD also refuse to construct such a set).

**Deferred (carried LOW).** `Validate()` and threshold verification accept
unbounded-size `Keys`/`sigs` slices. Nothing untrusted reaches this package yet — it
is called only with in-process values — so there is no allocation-DoS surface today.
A SPEC-backed maximum (`MaxSignerSetKeys` / `MaxPolicyCoreSignatures`) belongs to the
slice-3 wire/parse layer that first admits attacker-sized manifests, and is recorded
there rather than hard-coded here without a spec anchor.

## 4. Policy-core accept/reject predicate

`VerifyPolicyCore(core PolicyCore, sigs []Signature, ss SignerSet) error` accepts iff
**all** hold (any failure returns a distinct typed sentinel; no partial acceptance):

1. `ss.Validate()` passes (a malformed signer set can authorize nothing).
2. **Signer-set version match** — `ss.Version == core.SignerSetVersion`. A policy core is
   verified against *exactly* the signer set it names (SPEC-042-R012); a set of a
   different version is rejected even if its keys would verify.
3. **Signer-set applicability** — `ss` is not `Revoked`, and its window *contains the
   policy's* `not_before`: `ss.NotBeforeUnix ≤ core.NotBeforeUnix < ss.ExpiresAtUnix`.
   Per SPEC-042-R012 acceptance validity is anchored to `not_before_unix`, never to
   `manifest_version` (a policy ordinal, not a time anchor). Slice 2 takes no wall-clock;
   the durable "verdict + epoch" record that replay uses is slice 5.
4. **`manifest_core_digest`** recomputes from `core` (this also runs slice-1 structural
   validation — 32-byte prev hash, no duplicate allowlist entry).
5. **M-of-N threshold met** by *distinct authorized valid* signatures (§4.1).

### 4.1 Threshold counting (the security-load-bearing part)

`sigs` must be a **clean** list: every entry authorized, cryptographically valid, and
distinct by key id. Concretely, iterating `sigs`:

- a **duplicate key id** → reject (`errDuplicateSigner`): one key must never count toward
  the threshold twice, and a repeated key id is malformed, not silently deduped;
- a key id **not in `ss.Keys`** → reject (`errUnknownSigner`): a signature from a
  non-member key is "signature-invalid against the signer set" (R001), not ignorable
  padding;
- wrong signature length or **Ed25519 verify failure** over the §2 message → reject
  (`errBadSignature`);
- then require `len(sigs) ≥ ss.Threshold` (`errThresholdNotMet`); an empty list is
  "unsigned" and fails here.

Because every listed signature must be valid/authorized/distinct, the accepted count is
exactly `len(sigs)`, and `M`-of-`N` means *M distinct authorized keys signed the same
digest* — never M signatures from one key, never M-good-plus-garbage. Ed25519 signature
malleability is irrelevant: a malleated second signature for the same `(key, digest)`
carries the same key id and is rejected as a duplicate, so it cannot inflate the count.

## 5. `pool_id` binding

`VerifyPoolIDBinding(ic IdentityCore, claimedPoolID string) error` recomputes
`ic.PoolID()` and compares against `claimedPoolID`, rejecting on mismatch
(`errPoolIDMismatch`, SPEC-042-R001: "rejected on mismatch against the recomputed
identity-core digest"). The comparison uses `subtle.ConstantTimeCompare` for hygiene
though `pool_id` is a public identifier. The identity core itself carries no signature
in this slice — `pool_id = hash(identity core)` is a self-certifying *name*;
authorization flows only from signatures over policy cores by a root-issuer-authorized
signer set (the authority log, slice 3).

## 6. Golden vectors

Keypairs are derived from **fixed 32-byte seeds** (`ed25519.NewKeyFromSeed`) so the
vectors are deterministic and reproducible with no `crypto/rand`. The table pins:

- the exact hex of the §2 signing message for the slice-1 sample policy core;
- a valid **2-of-3** signature set (accept) and a valid **1-of-1** (accept);
- reject paths, each asserted to return its specific sentinel: wrong
  `signer_set_version`; signer set `Revoked`; `not_before` outside the signer-set
  window (both below `NotBefore` and at/after `Expires`); one fewer signature than the
  threshold; a duplicate key id; a signature from a key outside the set; a signature
  over a tampered digest; a malformed signer set (`M > N`, `M = 0`, duplicate key id,
  bad key length).

Any change to the signing tag or preimage construction breaks the message vector —
which is the point; the signing format is frozen alongside the slice-1 encoding.

## 7. API synopsis

```go
type Signature struct { KeyID string; Sig []byte }   // Alg is fixed Ed25519
type SignerKey struct { KeyID string; PublicKey ed25519.PublicKey }
type SignerSet  struct { Version uint64; Keys []SignerKey; Threshold uint32; NotBeforeUnix, ExpiresAtUnix uint64; Revoked bool }

func (SignerSet) Validate() error
func PolicyCoreSigningMessage(manifestCoreDigest []byte) ([]byte, error) // tag ‖ digest
func VerifyPolicyCore(core PolicyCore, sigs []Signature, ss SignerSet) error
func VerifyPoolIDBinding(ic IdentityCore, claimedPoolID string) error
```

Verification is total and deterministic; it returns a typed sentinel on every reject and
`nil` only when the policy core is authentic, authorized under the named signer set, and
threshold-met. No durable state, no clock, no lookup — those are the boundaries of
slices 3–5.
