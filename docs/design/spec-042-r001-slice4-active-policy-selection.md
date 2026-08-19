# SPEC-042 R001 slice 4 — active-policy selection (versioned policy-core history)

Status: design → implementation. Coordinator-only (phase4), extends
`internal/poolmanifest`. Fourth of the manifest epic. Slice 3 versioned the
**signer sets**; this slice versions the **policy cores** signed by them: it accepts
a pool's policy-core history under the R001 rollback/chain/window rules and selects
the one policy that is *active* at a given instant (or fails closed with
`pool_policy_stale`).

## 1. Scope

Deliver the R001 "active-policy selection + version history" deliverable:

1. **Policy-core history acceptance** — order a pool's signed policy cores under the
   R001 rules: signature-valid (slice 2, against the signer set materialized by the
   slice-3 authority log), `pool_id`-bound, **strictly-monotonic `manifest_version`**
   (rollback rejected), **`prev_manifest_core_hash` chain**, and **non-overlapping
   half-open validity windows** `[not_before_unix, expires_at_unix)`.
2. **Active-policy selection** — given `now`, return the single policy version whose
   half-open window contains `now`; at most one can (overlaps are rejected at
   acceptance). Future-dated versions are accepted but inactive until `not_before`.
   If none is active (a validity gap, or all expired), fail closed with
   `pool_policy_stale`.

This composes the crypto core end-to-end: identity/encoding (slice 1) → signature
verification (slice 2) → authority log / signer sets (slice 3) → **active policy
(slice 4)**.

Out of scope (later slices):

- **Durable persistence + restart/failover reconstruction** of the policy-core
  history and the highest-accepted `manifest_version`, and the **durable
  acceptance-verdict record** (R012). This slice is pure: it accepts an in-memory
  list and takes `now` only as an explicit parameter to `ActivePolicy`. In
  particular, the R012 rule that a policy accepted *before* its signer set was later
  revoked stays valid (rather than being re-rejected on replay) is the slice-5
  durable-verdict job; `BuildPolicyHistory` here verifies each core against the
  **authority-log state it is handed**, which models accepting policy cores while
  their signer sets are live.
- **Which policy was in force for a settled request** (the settlement-time lookup)
  and the mutable-operational-field application — later.
- Wiring active-policy selection into live routing/admission (slice 6).

## 2. Acceptance rules (`BuildPolicyHistory`)

`BuildPolicyHistory(ic IdentityCore, authLog *AuthorityLog, cores []SignedPolicyCore)
(*PolicyHistory, error)` processes `cores` **in ascending `manifest_version` order**
(the caller supplies them so; a non-ascending list is rejected as a rollback). Per
core, all must hold (distinct typed sentinel on any failure):

1. **Pool binding** — `core.PoolID == ic.PoolID()` (a policy core carries `pool_id`
   as a reference; a mismatch is not this pool's policy).
2. **Window well-formed** — `not_before_unix < expires_at_unix` (a non-empty
   half-open window).
3. **Version** — `manifest_version >= 1` and strictly greater than the previous
   accepted version; `<=` is a rollback (R001).
4. **Chain** — `prev_manifest_core_hash` equals the previous accepted core's
   `manifest_core_digest`; the first core's prev hash must be the 32-zero genesis
   value.
5. **Non-overlap** — the new `[not_before, expires)` must not overlap **any**
   already-accepted version's window (two half-open intervals `[a,b)` and `[c,d)`
   overlap iff `a < d && c < b`; adjacent `b == c` is allowed). R001: "reject a new
   policy core whose half-open validity window would overlap an already-accepted
   version."
6. **Signature** — resolve the signer set: `authLog.SignerSet(core.SignerSetVersion)`
   (absent → reject), then `VerifyPolicyCore(core, sigs, ss)` (slice 2: exact
   signer-set version, unrevoked, signer-set window contains the policy's
   `not_before`, recomputed digest, M-of-N distinct authorized signatures).

On acceptance, the history records `manifest_version → {deep-copied policy core,
manifest_core_digest, window}`. Deep-copying (the `PrevManifestCoreHash` and
`ModelAllowlist` slices) follows the slice-3 immutability rule so a caller cannot
mutate accepted policy material through the input or a returned value.

## 3. Active-policy selection

`(*PolicyHistory) ActivePolicy(nowUnix uint64) (PolicyCore, error)` returns the
version whose half-open window `[not_before, expires)` contains `nowUnix`. Because
acceptance rejected overlapping windows, at most one version qualifies, and it is the
current policy. If none does — `nowUnix` is before the earliest `not_before`, in a
gap between windows, or after the latest `expires` — it returns `errPoolPolicyStale`
(the SPEC-042-R010 `pool_policy_stale` fail-closed signal); the caller MUST NOT route.
The returned core is a deep copy.

`(*PolicyHistory) HighestVersion() uint64` reports the highest accepted
`manifest_version` (for observability / the rollback floor); it is **not** the
"current policy" (which is time-dependent and may be a lower, currently-active
version, or none).

## 4. Golden / behavioral vectors

Fixed-seed keys (reuse the slice-2/3 helpers) and the slice-3 authority log build a
pool with three chained policy cores:

- v1 window `[1000, 2000)`, v2 `[2000, 3000)` (adjacent, non-overlapping), v3
  `[4000, 5000)` (leaving a gap `[3000, 4000)`), each signed under an active signer
  set and chained by `prev_manifest_core_hash`.

Behavioral assertions: `ActivePolicy` returns v1 at `1500`, v2 at `2000` (boundary
belongs to the later window) and `2999`, v3 at `4000`; and `pool_policy_stale` at
`999` (before genesis), `3500` (gap), and `5000` (after expiry). Reject vectors, each
asserting its sentinel: pool_id mismatch, empty/inverted window, `manifest_version`
rollback and `0`, broken prev-hash chain, non-genesis first prev, overlapping window,
unknown signer-set version, and a bad signature.

## 5. API synopsis

```go
type SignedPolicyCore struct { Core PolicyCore; Signatures []Signature }

type PolicyHistory struct { /* opaque: version -> accepted core, digest, window */ }

func BuildPolicyHistory(ic IdentityCore, authLog *AuthorityLog, cores []SignedPolicyCore) (*PolicyHistory, error)
func (*PolicyHistory) ActivePolicy(nowUnix uint64) (PolicyCore, error) // errPoolPolicyStale if none active
func (*PolicyHistory) HighestVersion() uint64
```

Acceptance is a pure, total function of `(ic, authLog, cores)`; selection is a pure
function of `now`. No I/O, no persistence, no ambient clock — those seams are slice 5.
