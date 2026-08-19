# SPEC-042 R001 slice 1 — canonical manifest encoding + pool_id derivation

Status: design → implementation. Coordinator-only (phase4), new package
`internal/poolmanifest`. First of the R001 manifest epic (encoding + derivation
+ golden vectors); no signing, authority log, active-policy selection,
persistence, or routing wiring yet (slices 2–6).

## 1. Scope

Deliver the deterministic, versioned **canonical byte grammar** for the SPEC-042
identity core and versioned policy core, the two derivations that hang off it —
`pool_id` and `manifest_core_digest` — and **golden vectors** that lock the wire
format. This closes the deferred R001 "canonical byte grammar + golden vectors"
detailed-design deliverable (R010 promotion checklist) for these two cores.

Out of scope (later slices): signatures, the root-issuer/signer-set authority
log (R012), mutable operational fields, active-policy selection / validity
windows, durable persistence, and wiring the manifest into trustpool/routing.

## 2. Framing primitives (mirror SPEC-041-R002 / tier2 pillar_b)

All multi-byte integers are big-endian. Every core is prefixed by an ASCII
**domain-separation tag** so an identity-core preimage can never collide with a
policy-core preimage or any other signed structure.

- `tag(T)`   → the raw ASCII bytes of the domain tag string T (fixed length, no prefix; it is the leading discriminator).
- `str(s)`   → `u32(len(utf8 s))` ‖ utf8 bytes of s.
- `bytes(b)` → `u32(len(b))` ‖ b.
- `u64(n)`   → 8 bytes big-endian.
- `bool(x)`  → one byte, `0x01` (true) or `0x00` (false).
- `list(xs)` → `u32(count)` ‖ each element's own length-prefixed encoding, in the element order defined per field (see below). Lists whose semantics are set-like are encoded in **byte-lexicographic ascending order of the element's utf8 bytes** and MUST contain no duplicates.

`u32` is a 4-byte big-endian length; encoding fails if any length exceeds 2^32−1.

## 3. Identity core (→ `pool_id`)

Domain tag: `macprovider/spec042/identity-core/v1`

Fields, in this exact order (R001: identity core contains ONLY identity-genesis
fields — no pool_id, manifest_version, chaining hash, signer set, or policy):

1. `tag("macprovider/spec042/identity-core/v1")`
2. `str(root_issuer_key_id)`   — the stable root issuer signing-key id (opaque).
3. `bytes(genesis_nonce)`      — creator-chosen genesis nonce/parameters (opaque).

```
pool_id = base64url_nopad( SHA256(identity_core_bytes)[0:16] )
```

`pool_id` is a 128-bit truncation, a **non-capability** naming key (R001). It is
carried alongside the manifest and MUST be rejected on mismatch against the
recomputed identity-core digest (mismatch check is a later verification slice;
this slice provides the derivation + an equality helper).

## 4. Versioned policy core (→ `manifest_core_digest`)

Domain tag: `macprovider/spec042/policy-core/v1`

Fields, in this exact order (R001 policy-core field list). `pool_id` is carried
as a **reference** (it is NOT part of its own identity preimage — it lives in the
identity core — but it IS bound into the policy-core digest so a policy core
cannot be lifted to another pool):

1. `tag("macprovider/spec042/policy-core/v1")`
2. `str(pool_id)`                       — reference to the owning pool.
3. `u64(manifest_version)`              — monotonic.
4. `bytes(prev_manifest_core_hash)`     — 32 bytes; the genesis value is 32 zero bytes.
5. `u64(signer_set_version)`
6. `list(model_allowlist)`              — SPEC-010 canonical ids, set-ordered.
7. `str(min_binary_version)`            — SPEC-020/001 authority; "" = no floor.
8. `str(min_attestation_tier)`          — "", "self_signed", or "hardware".
9. `bool(require_encrypted_leg)`
10. `str(settlement_mode)`
11. `u64(revenue_split_bps)`
12. `str(split_execution_status)`       — "declared_not_executed" in v0.1.
13. `str(retention_policy_id)`
14. `u64(min_eligible_members)`
15. `str(privacy_mode)`                 — R009 Layer-3 compat group (forward-declared, "none" in v0.1).
16. `bool(relay_blind_capable)`
17. `str(receipt_contract)`
18. `str(metadata_visible)`
19. `str(downgrade_policy)`
20. `bool(sticky_routing_allowed)`      — default false for trust-sensitive pools.
21. `u64(not_before_unix)`
22. `u64(expires_at_unix)`

```
manifest_core_digest = SHA256(policy_core_bytes)   // 32 bytes
```

### Field notes
- The genesis `prev_manifest_core_hash` is fixed at 32 zero bytes (a defined
  genesis value, R001). A non-genesis version carries the previous version's
  `manifest_core_digest`.
- The full R009 Layer-3 compatibility group (`privacy_mode`,
  `relay_blind_capable`, `receipt_contract`, `metadata_visible`,
  `downgrade_policy`, `sticky_routing_allowed`) is forward-declared per R009 so
  the later Layer-3 amendment is **additive** (populate the reserved fields)
  rather than a breaking re-encode. v0.1 uses `privacy_mode="none"` and makes no
  relay-blind claim.
- Field 2 (`pool_id`) binding: including the pool_id reference in the policy-core
  preimage means a signed policy core is non-transferable to a different pool,
  even though pool_id is derived solely from the identity core.

## 5. Golden vectors

A `testdata`-free, in-code golden vector table pins the exact hex of
`identity_core_bytes`, `pool_id`, `policy_core_bytes`, and `manifest_core_digest`
for a fixed sample identity + policy. Any change to the grammar breaks these,
which is the point — the wire format is frozen once these land. Vectors cover:
- a minimal identity (empty genesis nonce) and a non-empty one;
- a genesis policy core (zero prev hash) and a v2 core (non-zero prev hash);
- an empty vs multi-entry, out-of-input-order model allowlist (proving set-order
  normalization is deterministic).

## 6. API (package `internal/poolmanifest`)

```go
type IdentityCore struct { RootIssuerKeyID string; GenesisNonce []byte }
type PolicyCore struct { PoolID string; ManifestVersion uint64; PrevManifestCoreHash []byte; SignerSetVersion uint64; ModelAllowlist []string; MinBinaryVersion string; MinAttestationTier string; RequireEncryptedLeg bool; SettlementMode string; RevenueSplitBps uint64; SplitExecutionStatus string; RetentionPolicyID string; MinEligibleMembers uint64; PrivacyMode string; NotBeforeUnix uint64; ExpiresAtUnix uint64 }

func (IdentityCore) CanonicalBytes() ([]byte, error)
func (IdentityCore) PoolID() (string, error)            // base64url(SHA256(canonical)[0:16])
func (PolicyCore) CanonicalBytes() ([]byte, error)      // validates PrevManifestCoreHash is 32 bytes, allowlist non-dup
func (PolicyCore) ManifestCoreDigest() ([]byte, error)  // SHA256(canonical)
```

Encoding is total and deterministic; it errors only on structurally invalid
input (over-long field, `PrevManifestCoreHash` not 32 bytes, duplicate allowlist
entry). No I/O, no crypto beyond SHA-256, no dependencies outside stdlib.
