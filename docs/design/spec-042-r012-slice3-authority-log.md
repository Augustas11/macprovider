# SPEC-042 R012 slice 3 — authority log (versioned M-of-N signer sets)

Status: design → implementation. Coordinator-only (phase4), extends
`internal/poolmanifest`. Third of the R001/R012 manifest epic. Slice 2 verifies a
policy core against a `SignerSet` it is **handed**; this slice is where that
`SignerSet` comes from — the append-only, hash-chained **authority log** that the
root issuer uses to establish and version operational signer sets, and to revoke
them (SPEC-042-R012).

## 1. Scope

Deliver:

1. The **authority-log entry canonical byte grammar** (domain-separated,
   length-prefixed, SPEC-041-R002 precedent) + `authority_log_entry_hash` +
   the entry **signing preimage**. This closes the last deferred R001/R012
   "canonical encoding + golden vectors" deliverable (the R001 slice-1 doc
   explicitly left "the authority-log entry encoding ... to its implementation
   slice").
2. **Chain verification / replay**: given the pool's root-issuer key and an ordered
   list of entries, verify the whole chain and materialize
   `signer_set_version → SignerSet` (the exact value type slice 2 consumes),
   with the `Revoked` flag set — so `VerifyPolicyCore` becomes end-to-end usable.
3. A tiny **generic threshold helper** extracted from slice 2 so policy-core and
   authority-log signatures share one M-of-N primitive with distinct domain tags
   (the slice-2 architect's recommendation), leaving `VerifyPolicyCore` behavior
   byte-identical.
4. **Golden vectors** freezing the entry encoding, hash, sig preimage, and a
   genesis → rotate → revoke replay, plus every reject path.

Out of scope (later slices, called out so the boundary is explicit):

- **Durable persistence + restart/failover reconstruction** of the log, the
  highest-accepted `signer_set_version` per pool, and the **durable
  acceptance-verdict record** that R012 requires so replay does not re-evaluate
  validity against the current wall-clock (slice 5). This slice is pure: it
  verifies an in-memory entry list and takes no clock.
- **Emergency signed control messages** for pool *lifecycle*
  (`paused`/`draining`/`revoke_immediate`, SPEC-042-R011/R003) — a different
  structure (a control message over pool state, not a signer-set entry).
  Signer-set *revocation* (marking a `signer_set_version` revoked) **is** in this
  slice, via a per-entry `revokes_versions` list.
- **Operator-provenance binding** (R012 option a) / self-asserted disclosure
  (option b), and root-issuer-compromise `supersedes` lineage / new-pool minting —
  buyer-surface and pool-identity concerns, not the log mechanism.
- Wiring the materialized sets into live routing/settlement (slice 6).

## 2. Authority-log entry

An entry has a signed **content** (the TBS part, hashed and chained) plus the
**signatures** that authorize it (not part of the hash — like a certificate's
signature is not part of its TBSCertificate).

```go
type AuthorityLogEntry struct {
    // --- content (hashed + chained) ---
    PoolID                      string      // binds the entry to one pool (must equal ic.PoolID())
    SignerSetVersion            uint64      // monotonic, >= 1 (0 reserved)
    PrevAuthorityLogEntryHash   []byte      // 32 bytes; genesis = 32 zero bytes
    Keys                        []SignerKey // the signer set this entry establishes
    Threshold                   uint32      // M of N = len(Keys)
    NotBeforeUnix               uint64      // validity window [NotBefore, Expires)
    ExpiresAtUnix               uint64
    RevokesVersions             []uint64    // prior versions this entry revokes; set-ordered, no dups
    AuthorizingSignerSetVersion uint64      // 0 = root issuer; else a prior still-authorized set
    // --- authorization (NOT hashed) ---
    Signatures                  []Signature // root-issuer sig (authorizing=0) OR M-of-N of the authorizing set
}
```

### 2.1 Canonical content encoding

Domain tag `macprovider/spec042/authority-log-entry/v1` (distinct from the identity-
and policy-core tags so an entry hash can never collide with a core digest). Fields
in this exact order, reusing the slice-1 length-prefixed encoder:

1. `tag("macprovider/spec042/authority-log-entry/v1")`
2. `str(pool_id)` — binds the entry to one pool (SPEC-042-R012: the log is keyed under `pool_id`)
3. `u64(signer_set_version)` — MUST be `>= 1` (version 0 is the root-authorizer sentinel)
4. `bytes(prev_authority_log_entry_hash)` — 32 bytes
5. `list(keys)` — `u32(count)` then each key `str(key_id) ‖ bytes(public_key)`, in
   byte-lexicographic ascending order of `key_id`, no duplicate key id and no
   duplicate public key.
6. `u64(threshold)`
7. `u64(not_before_unix)`
8. `u64(expires_at_unix)`
9. `list(revokes_versions)` — `u32(count)` then each `u64`, **strictly ascending, no duplicates (a non-ascending or duplicate list is rejected, not normalized**, so the in-memory struct equals the signed bytes 1:1).
10. `u64(authorizing_signer_set_version)`

`authority_log_entry_hash = SHA256(canonical content)` (32 bytes).

### 2.2 Signing preimage

Domain tag `macprovider/spec042/authority-log-entry-sig/v1`:

```
entry_sig_message = tag("macprovider/spec042/authority-log-entry-sig/v1") ‖ authority_log_entry_hash
```

Distinct from the policy-core signing tag so an authority-log signature can never be
replayed as a policy-core signature (and vice versa).

## 3. Chain verification / replay

`BuildAuthorityLog(ic IdentityCore, rootIssuer SignerKey, entries []AuthorityLogEntry) (*AuthorityLog, error)`
processes entries in order, maintaining the running chain hash, the accepted
`version → SignerSet` map, and the revoked-version set. `rootIssuer` is the pool's
trust anchor, bound to the identity core by checking
`rootIssuer.KeyID == identityCore.RootIssuerKeyID` (helper `IdentityCore.BindsRootIssuer`).
`rootIssuer.PublicKey` must be a well-formed Ed25519 key. `BuildAuthorityLog` performs that binding itself: it rejects unless `ic.BindsRootIssuer(rootIssuer)` holds, and it requires **every entry's `PoolID` to equal `ic.PoolID()`** — so an entry (or a whole log) signed under a root key reused across pools cannot be replayed into a different pool. The `pool_id` is bound into the entry content (§2.1, field after the tag).

Per entry (index `i`), all must hold (distinct typed sentinel on any failure):

1. **Signer set well-formed** — build `SignerSet{Version, Keys, Threshold,
   NotBeforeUnix, ExpiresAtUnix}` and run slice-2 `Validate()` (`1 ≤ M ≤ N`,
   distinct key ids, **distinct public keys**, non-empty window). Reject on failure
   (covers R012's `M < 1 || M > N`).
2. **prev-hash length** = 32.
3. **Monotonic version** — `signer_set_version` strictly greater than the previous
   accepted entry's version; the first entry seeds the chain. `≤` is a rollback.
4. **Chain intact** — `prev_authority_log_entry_hash` equals the previous entry's
   `authority_log_entry_hash`; the first entry's prev hash must be the 32-zero
   genesis value.
5. **revokes_versions well-formed** — ascending, no duplicates, and every listed
   version is `< signer_set_version` and already present in the accepted map (cannot
   revoke self, a future version, or a nonexistent one).
6. **Authorization**:
   - `authorizing_signer_set_version == 0` → **root issuer**: exactly one signature,
     whose key id is `rootIssuer.KeyID`, valid over `entry_sig_message`.
   - else → a **prior still-authorized set**: `authorizing_signer_set_version` must
     be `< signer_set_version` and present; that set must **not** be revoked (as of
     the entries processed so far) and its window must contain this entry's
     `not_before_unix` (`auth.NotBefore ≤ entry.NotBefore < auth.Expires`); then
     **M-of-N** of that set must sign `entry_sig_message` (the shared threshold
     primitive). Authorization is checked **before** this entry's own
     `revokes_versions` is applied, so an entry may be authorized by a set it then
     revokes (rotate-and-revoke).
7. On acceptance: set the running hash to this entry's hash, insert the new
   `SignerSet`, then apply `revokes_versions` (mark those versions revoked).

After all entries: stamp `Revoked = true` on every revoked version in the map. The
result exposes `SignerSet(version) (SignerSet, bool)` for slice 2, plus the current
(highest) version and the head hash.

### 3.1 What "revoked" means here (and what is deferred)

A version marked revoked in the log is `Revoked` in the materialized map, so slice 2
`VerifyPolicyCore` rejects any policy core naming it (R012 "reject material signed
under a revoked signer set"). This slice is a pure function of the entry list —
revocation is not wall-clock-anchored. The R012 rule that an acceptance verdict
recorded *before* a revocation stays final (so a policy already accepted under a
later-revoked set is not retroactively rejected) is the **durable verdict record**
of slice 5; this slice provides the current authoritative set state, not the
historical per-request verdict.

## 4. Golden vectors

Fixed-seed keypairs (`ed25519.NewKeyFromSeed`, no `crypto/rand`). A root issuer key,
a v1 signer set (2-of-3), a v2 set (rotation, 2-of-2), a v3 set. The replay:

- **genesis** v1 — root-signed, prev = zeros;
- **rotate** v2 — authorized by 2-of-3 of v1;
- **revoke** v3 — authorized by 2-of-2 of v2, `revokes_versions = [2]`.

Pinned: the genesis content hex, `authority_log_entry_hash` for each, the
`entry_sig_message` hex, and the materialized state (v1 active, v2 revoked, v3
active, current = 3). Reject vectors (each asserting its sentinel): broken chain,
rollback / non-monotonic version, `M > N` and `M = 0`, duplicate public key,
genesis not root-signed, entry authorized by a revoked set, authorizing version ≥
entry version, unknown authorizing version, revoke of a future/self/nonexistent
version, wrong root key, and below-threshold authorization.

## 5. API synopsis

```go
type AuthorityLogEntry struct { /* §2 */ }

func (AuthorityLogEntry) CanonicalContentBytes() ([]byte, error) // §2.1
func (AuthorityLogEntry) EntryHash() ([]byte, error)             // SHA256(content)
func AuthorityLogEntrySigningMessage(entryHash []byte) ([]byte, error)

type AuthorityLog struct { /* opaque: version->SignerSet, head hash, current version */ }
func BuildAuthorityLog(ic IdentityCore, rootIssuer SignerKey, entries []AuthorityLogEntry) (*AuthorityLog, error)
func (*AuthorityLog) SignerSet(version uint64) (SignerSet, bool)
func (*AuthorityLog) CurrentVersion() uint64
func (*AuthorityLog) HeadHash() []byte

func (IdentityCore) BindsRootIssuer(rootIssuer SignerKey) bool // KeyID match, key well-formed
```

Verification is total and deterministic; no I/O, no persistence, no clock. It errors
with a distinct sentinel on every reject and returns a fully-materialized log
(including revocation state) on success — the signer-set source slice 2 was written
against.
