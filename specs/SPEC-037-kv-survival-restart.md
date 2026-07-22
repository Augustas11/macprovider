# SPEC-037 — KV survival across provider restarts (encrypted provider-local disk tier)

Version: v0.1.0
Status: draft (normative design; IMPL lands behind a disabled-by-default flag)
Owner: provider runtime / prefix-cache persistence
Decision source: `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` (landed decision memo, commit `d6881b14`)
Audit history: R1 five-lane audit (codex code/security/architect + adversarial verificator + product critic) reconciled in this text — envelope authentication scope, tombstone-first purge, per-epoch keys, eligibility-deadline preservation, snapshot-at-commit, buyer-key enablement gate.

## 1. Purpose and scope

Give the provider's shipped in-RAM prefix cache (`ConversationCache`) a cold
tier on local disk so a reusable conversation prefix survives provider process
loss — deploy, crash, supervisor relaunch, and (within eligibility bounds)
host reboot — and cuts the restart-driven re-prefill contribution to the
buyer-TTFT tail measured in RESEARCH_234 (p95 16.8 s, p99 51.4 s, 4.2% of
requests over 20 s).

The tier changes only cache **residency** — which turns can still hit after a
process loss. It introduces no new wire, receipt, or billing field and changes
no existing field's computation rule (FR-KVP1). It is expected and correct
that a post-restart turn reports a positive, provider-earned
`cached_prompt_tokens` where a tier-disabled provider would report 0; that
availability difference is the feature. Cache **eligibility** rules — the
reuse predicate and the TTL eligibility bound — are unchanged (FR-KVP2,
FR-KVP10).

In scope for v0.1:

- An encrypted, provider-namespaced disk tier behind the existing
  `ConversationCache` actor (RESEARCH_233 **Approach A**), using versioned
  opaque per-conversation serialization, immutable generation blobs, and
  atomic manifests.
- The strict exact-match safety envelope, fully bound into AEAD
  authentication, that gates any disk hit.
- Per-provider namespace, quota, and eviction model with a single-writer
  lock.
- A provider-side conversation-key **purge primitive** with tombstone-first
  anti-resurrection ordering (ship-blocker: the disk tier MUST NOT be enabled
  without it).
- Bounded, chunk-authenticated streaming promotion into the current RAM
  cache.
- An operator inspection surface (status + counters + promotion timing).
- The KVS-01 benchmark gate, its production fence, and the explicit stop
  condition for Approach A.

Out of scope (recorded, not silently dropped):

- Any change to LOCKED SPEC-015 v0.4.2 receipts. Buyer-facing cache
  provenance, if ever needed, is a named future SPEC-015 v0.5 question.
- Any change to SPEC-024 `cached_prompt_tokens` wire/mirror semantics, the
  reuse predicate, or the TTL eligibility bound; any change to SPEC-005
  billing arithmetic/eligibility. Extending the eligibility window beyond the
  shipped hot-tier TTL would be a cache-eligibility change and requires a
  SPEC-024 amendment — this spec deliberately does not make it.
- A shared paged-KV allocator, copy-on-write prefix sharing, or any
  batch-aware layout (RESEARCH_232 / SPEC-038 territory; see §8).
- Cross-conversation or cross-provider block sharing and global
  content-addressed dedup (rejected — see §9 no-go list).
- External sidecar processes; oMLX as inference engine (rejected).
- Speculative-decoding cache state (excluded from the format and the path).
- Coordinator-propagated purge (`DELETE /v1/sticky` → provider push). v0.1
  ships the provider-local primitive it would invoke; the propagation channel
  is future work and MUST NOT be presented as shipped buyer purge. Until it
  exists, persistence of coordinator-issued buyer keys is gated (FR-KVP11).
- Defense against a hostile process running under the **same macOS user
  (euid)** as the provider. Such a process can already read the provider's
  Keychain-accessible secrets and memory-adjacent state; the isolation
  guarantees here hold against other-UID processes, other provider
  namespaces, and offline disk access (FileVault + AEAD), and the memo's
  separate-UID deployment control (RESEARCH_233 §5.2) remains the
  recommendation for multi-provider hosts. Stated explicitly so the guarantee
  is not overread.

## 2. Dependencies and authority

- **SPEC-024 v0.2.1 §11–§16** — provider-local cache isolation baseline
  (FR-CI1..FR-CI10a). This spec preserves those invariants and extends their
  blast-radius analysis to a restart-durable store; it does not re-own them.
- **SPEC-005 v0.6** — billing arithmetic/eligibility authority. Untouched.
- **SPEC-010** — model catalog identity; the canonical `model_sha256`
  (canonical artifact hash) semantics this spec's envelope consumes.
- **SPEC-015 v0.4.2** — LOCKED receipts. Untouched.
- **SPEC-032** — OPoI probes are observability-only and bypass this tier.
- **SPEC-001** — provider binary surface (config, control socket, serve loop).

SPEC-037 owns the new authority domain `kv-cache-persistence`: the on-disk
format, its validation/invalidation rules, namespace/quota/purge lifecycle,
and the persistence benchmark gates. SPEC-038 (continuous batching), when it
lands, registers as a consumer of this domain (§8).

## 3. Terms

| Term | Meaning |
|---|---|
| Hot tier | The shipped in-RAM `ConversationCache` entries (`[KVCache]` layers). |
| Cold tier | The on-disk store this spec defines. |
| Canonical key bytes | UTF-8 encoding of the NFC-normalized, whitespace-trimmed `conversation_key` (FR-KVP6). |
| Entry | All persisted state for one canonical key in one namespace. |
| Generation | One immutable committed serialization of an entry (`gen-<N>`). |
| Manifest | The atomically-replaced per-entry metadata document naming the committed generation. |
| Envelope | The authenticated metadata (identity + geometry + lifecycle fields) a hit must match per FR-KVP4. |
| Namespace | The per-provider-identity subtree holding entries, quota, and keys. |
| Key epoch | Integer version of the namespace's independently generated key material; bumping it crypto-shreds all prior ciphertext. |
| Purge generation | Monotonic per-index counter fencing pre-purge state from post-purge writes. |
| Tombstone | Durable per-(epoch, index) purge record carrying the purge generation. |
| Promotion | Streaming a validated cold entry into hot-tier `[KVCache]` layers. |
| Residency epoch | The lifetime of one provider process between starts. |

## 4. Normative requirements

Requirement IDs `SPEC-037-R001`..`R013` are the conformance units; FR labels
below are the prose anchors.

### FR-KVP1 — residency only, no observable-contract change (SPEC-037-R001)

The cold tier MUST NOT add any wire, receipt, or billing field and MUST NOT
change the **computation rule** of any existing field: a promoted hit reports
`cached_prompt_tokens` by exactly the same LCP rule as a RAM hit (SPEC-024
FR-CI3 — the provider reports actual reuse performed); `prompt_tokens`
remains the full incoming prompt length; SPEC-005 billing arithmetic and
eligibility gates, SPEC-015 v0.4.2 receipts, and SPEC-004 routing are
untouched. Hit **availability** legitimately differs: a tier-enabled provider
may report positive `cached_prompt_tokens` on a post-restart turn where a
tier-disabled provider reports 0. Response and receipt **schemas, field
sets, and computation rules** MUST be identical with the tier enabled or
disabled (AC-7); suppressing or inflating a reuse report to mimic the other
configuration is forbidden (it would violate SPEC-024 FR-CI3).

### FR-KVP2 — hot-tier semantics preserved exactly (SPEC-037-R002)

The shipped reuse mechanism is unchanged and remains the only reuse mechanism:

1. the trimmed `conversation_key` selects exactly one candidate (FR-CI1);
2. reuse is the exact token-level LCP, `LCP >= 32` and `LCP <` incoming
   prompt length (FR-CI2);
3. every KV layer must be trimmable and every trim must remove exactly the
   requested count — any shortfall is a miss;
4. the incoming request still reports its full prompt length; and
5. speculative decoding stays entirely outside this cache path. Normatively:
   on **both** the streaming and non-streaming endpoints, speculative-decode
   routing MUST be determined **before** any conversation-cache `begin()`,
   promotion, or commit; a request routed to speculative decode MUST NOT
   acquire a cache lease, trigger promotion, or commit cache state, and MUST
   NOT leave a key busy (fixture: AC-8).

Promotion MUST materialize a cold entry into the same in-memory
representation the hot tier commits today, then let the existing `begin()`
predicate decide hit/miss under the same per-key serialization (FR-CI4a).
The cold tier MUST NOT implement a second, divergent reuse predicate. The
three inherited traps from commit `84e50c92` (tokenizer non-canonicity →
token-LCP only; full-prompt accounting; `cache_offset` priming) are
persistence-format test fixtures (§7).

### FR-KVP3 — entry format, snapshot, and commit ordering (SPEC-037-R003)

Format v1: manifest schema ID `kvsurv-manifest-v1`; payload codec ID
`kvsurv-codec-v1` (separate identifiers; either may version independently).

- Entry layout: `<namespace>/<index>/manifest.json` plus immutable generation
  blobs `<namespace>/<index>/gen-<N>.blob`, where `<index>` is the HMAC index
  of FR-KVP6 — never the raw `conversation_key`.
- **Snapshot at commit.** The hot tier mutates committed layer objects in
  place on subsequent trims, so the disk writer MUST serialize from an
  immutable snapshot of the layer state and token sequence captured
  synchronously at hot-tier `commit()` **while the per-key lease is still
  held**. Serialization and I/O then proceed asynchronously off the request
  path from that snapshot only; the writer MUST never read live hot-tier
  layer objects.
- The persisted token sequence is exactly the hot tier's canonical sequence:
  `prompt_token_ids ‖ generated_token_ids` as committed.
- The payload (encrypted per FR-KVP6) serializes that token sequence plus
  each KV layer's state arrays and per-layer metadata as an **opaque
  versioned record** of the current per-conversation layer state. Only cache
  classes on an explicit serialization allowlist may be persisted; an entry
  whose layers include any other class MUST NOT be written
  (`disk_write_skipped`).
- **Write ordering (per index, single writer — FR-KVP7):** generations are
  allocated monotonically per index; writes for one index are serialized;
  blob and manifest temp files use per-write unique names created with
  `O_EXCL`. Commit protocol: write `gen-<N>.blob` → `fsync(blob fd)` →
  `fsync(entry directory)` → write manifest to unique temp → `fsync(temp
  fd)` → verify, immediately before publication, that the current tombstone
  purge generation (FR-KVP8) and key epoch still admit this write and that
  `N` still exceeds the committed generation → atomic `rename(2)` over
  `manifest.json` → `fsync(entry directory)`. After a crash, recovery
  observes either the previous committed generation, the complete new
  generation, or no committed generation — never a partially-visible one;
  orphan temp/blob files are swept and their bytes reclaimed on startup.
- Writes occur only after a successful request commit (the same point the
  hot tier commits). Write failure of any kind is logged
  (`disk_write_skipped`) and dropped; the hot tier is unaffected.
- A manifest naming a blob whose length, checksum, or AEAD verification does
  not pass exactly is treated as absent (miss) and quarantined for deletion.

### FR-KVP4 — envelope: strict validation, fully authenticated (SPEC-037-R004)

Every manifest MUST record the envelope below. On load, validation completes
**before any payload byte is deserialized**, in four categories:

**(a) Exact-match live-identity fields** — each MUST equal the current
runtime value byte-for-byte:

1. manifest schema ID and payload codec ID (`kvsurv-manifest-v1` /
   `kvsurv-codec-v1`);
2. provider namespace ID and key epoch;
3. HMAC index of the canonical key bytes (recomputed and compared);
4. model ID, exact `model_sha256` (SPEC-010 canonical artifact hash), and
   catalog revision;
5. tokenizer identity, tokenizer configuration hash, and chat-template hash;
6. `mlx-swift-lm` **serialization ABI epoch** — a source-controlled constant
   in the provider binary, bumped by an explicit code change whenever the
   pinned `mlx-swift-lm` revision or cache-class ABI changes incompatibly
   (not derived from build IDs, so ordinary rebuilds do not thrash the
   cache);
7. cache implementation class and layer count;
8. per-layer tensor shapes, dtypes, and layout version;
9. `kvBits`, quantization group size, quantization mode, and cache
   quantization policy;
10. decode path class (ordinary decode only; speculative state MUST NOT be
    written);
11. purge generation (MUST be ≥ the live tombstone's purge generation for
    the index, per FR-KVP8).

**(b) Temporal checks:** `creation_time ≤ now` (a future creation time is
ineligible — clock rollback defense) and `now ≤ eligibility_deadline`
(FR-KVP10).

**(c) Structural consistency:** token count, generation number, per-chunk
and total payload lengths, and declared tensor shapes MUST be
internally consistent and within configured bounds **before any allocation
is sized from them**.

**(d) Cryptographic verification:** every payload chunk's AEAD tag verifies
(FR-KVP6), and the manifest's own authentication verifies as below.

**Authentication scope.** A canonical, versioned byte encoding of the
**entire envelope** — every field in (a), (b), (c), plus each chunk's nonce,
length, and ordinal — is bound as AEAD associated data of every payload
chunk (FR-KVP6). No envelope field is trusted unauthenticated: rewriting any
manifest field invalidates decryption. Mutation of each individual envelope
field is a required fixture (AC-2).

**Live identity completeness.** If any live-identity input (e.g. the
canonical model hash) is unavailable in the current process, the tier MUST
NOT write (`disk_write_skipped`, reason `identity_unavailable`) and MUST NOT
promote (miss, `disk_miss_identity_unavailable`). Deserialization success is
NOT reuse eligibility. Model *family*, filename, or catalog-alias similarity
is never sufficient — a warm-swap to a same-family model is a miss unless
every identity above matches.

### FR-KVP5 — fail safe to miss (SPEC-037-R005)

Any of the following resolves to a **miss with correct fresh output**, never
a partial or best-effort reuse, never a crash of the serve loop, and never an
escalation into drift/fraud/sanction signals: any category-(a)–(d) envelope
failure; expiry; checksum/AEAD failure; truncated, oversized, or malformed
blob or manifest; incomplete commit; unsupported or allowlist-removed cache
class; non-exact trim after promotion; I/O error or timeout; disk-full;
read-only filesystem; oversized or malicious length/shape metadata; wrong or
unavailable key epoch; Keychain material unavailable (e.g. before first
unlock after reboot); tombstoned index; promotion budget or concurrency
limit reached. Each outcome maps to exactly one FR-KVP12 reason code.
Corrupt artifacts are quarantined/deleted asynchronously.

**Bounded miss cost.** The cold tier adds bounded work to a miss, not zero
work: lookup + validation reads are bounded by the manifest size; promotion
work is bounded by the staging ceiling and by per-promotion deadlines
(`promotion_max_seconds`, default 10 s wall-clock; on expiry the promotion
is abandoned and the request proceeds as a miss). A cold-tier failure MUST
NOT block, fail, or corrupt the request being served.

### FR-KVP6 — encryption, index hiding, key lifecycle (SPEC-037-R006)

- **Canonical key bytes.** One function everywhere (lookup, write, purge,
  tombstone): trim whitespace per the shipped FR-CI1 handling, apply Unicode
  NFC normalization, encode UTF-8. This matches Swift's canonical-equivalence
  string keying in the hot tier so one logical key maps to one index
  (composed/decomposed fixtures required, AC-2).
- **Index hiding.** Entry directory names are
  `base16(HMAC-SHA256(index_key_epochN, canonical_key_bytes))`. The raw key
  never appears in any path, log, or manifest field. Index computation
  happens only inside the owning provider process.
- **AEAD.** Payloads are encrypted AES-256-GCM in **bounded chunks** (v1
  chunk size ≤ 64 MiB). Every chunk uses a fresh 96-bit nonce from a CSPRNG
  — never derived from generation numbers or counters that can roll back —
  and carries the FR-KVP4 canonical envelope encoding plus its own ordinal,
  length, and nonce as associated data. Chunks verify before their plaintext
  is used; cumulative decoded size is checked against the declared total.
- **Keys.** Each key epoch has an **independently generated random master
  key** stored as its own macOS Keychain item (SecItem
  `kSecClassGenericPassword`, non-synchronizable, accessibility
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, default ACL binding
  access to the signed binary — the shipped `KeychainProviderCredentialStore`
  pattern). Per-epoch AEAD and index keys are HKDF-SHA256-derived from that
  epoch's master. Epoch keys are NOT derivable from one another or from any
  retained root: deleting epoch N's Keychain item crypto-shreds every epoch-N
  ciphertext.
- **Epoch rotation (purge-all), crash-safe ordering:** generate + store the
  new epoch's Keychain item and verify readback → durably commit the new
  epoch number in namespace metadata (fsync + atomic rename) → delete the
  old epoch's Keychain item → verify absence → delete old-epoch files
  best-effort. After any interruption, recovery completes the rotation
  forward; the namespace MUST never fall back to an older epoch.
- **Pre-unlock behavior.** If Keychain material is unavailable (e.g. process
  start before first unlock after reboot), the tier is dormant: reads miss
  (`disk_miss_io`, reason detail `keychain_unavailable`), writes skip, and
  the tier retries opportunistically. Never fail the serve loop for key
  unavailability.
- Directory/file discipline: namespace directories `0700`, files `0600`,
  `O_NOFOLLOW` on open, owner/euid verified — the control-socket hardening
  pattern. Key material MUST never be written under the cache directory.
- Encryption is a necessary control, not a secrecy claim: it does not
  protect against a compromised live provider process (§1 same-euid
  exclusion), and no physical-erasure claim is made at TTL (FR-KVP10).

### FR-KVP7 — per-provider namespace, single writer, quota (SPEC-037-R007)

- The cold tier root contains one namespace per provider identity, keyed by
  a digest of the stable provider ID; the namespace records its provider ID,
  current key epoch, and format IDs in namespace metadata. A provider
  process MUST only open its own namespace.
- **Single writer.** A process MUST hold an exclusive advisory lock
  (`flock`) on a namespace lockfile for as long as the tier is active; if
  the lock is unavailable (e.g. supervisor-relaunch overlap, duplicate
  instance), the tier stays dormant in that process (hot tier unaffected).
  All FR-KVP3 atomicity and quota guarantees are stated under this
  single-writer condition.
- Cross-namespace reads, writes, eviction, or key derivation are forbidden.
  A raw entry copied between namespace directories MUST fail closed (the
  namespace ID is bound into the HMAC index and the authenticated envelope).
- **Quota accounting covers every namespace artifact**: blobs, manifests,
  temp files, tombstones, quarantine, and namespace metadata. Bytes are
  reserved against the quota before a write begins; orphaned temp/blob bytes
  are swept and reclaimed on startup. Caps (operational defaults, not
  protocol values): total bytes 16 GiB, entry count 64, per-entry bytes
  2 GiB. Note: the per-entry cap is calibrated to the memo's q4-KV estimate;
  if the active KV representation is FP16, long-context entries may exceed
  it and be skipped (`disk_write_skipped`) — the cap is a guardrail, and the
  active-`kvBits` question is memo Q6/Q7.
- **Free-space floor.** Writes are refused (`disk_write_skipped`) when host
  free space would drop below `min_free_bytes` (default 8 GiB). At enable
  time the tier logs available free space vs configured caps and warns when
  headroom is insufficient.
- Eviction on quota pressure is LRU by last-eligible-use within the
  namespace only (`disk_evict_quota`). Global content-addressed dedup across
  keys, accounts, or namespaces is forbidden.
- Rationale (SPEC-024 FR-CI8 extension): a shared pool would turn the
  existing in-process capacity channel into a cross-process/cross-provider
  denial vector; per-namespace quotas plus the single-writer lock close it
  against other namespaces (same-euid hostile peers are excluded per §1).

### FR-KVP8 — purge primitive and tombstones — ship-blocker (SPEC-037-R008)

- The provider binary MUST expose a local purge primitive **before** the
  disk tier can be enabled: a control-socket command (and matching
  `macprovider-cli` subcommand) that (a) purges one conversation key —
  addressed by raw key, canonicalized and HMAC-indexed inside the provider
  process — or (b) purges the whole namespace via key-epoch rotation
  (FR-KVP6).
- **Tombstone-first ordering (normative):** single-key purge MUST (1) write
  and `fsync` a durable tombstone for the (epoch, index) carrying an
  incremented monotonic **purge generation**, `fsync` the directory; (2)
  remove the matching hot-tier entry and invalidate any outstanding hot
  lease's pending commit for that key; (3) delete the entry's generations
  and manifest; (4) only then report success, including counts (entries
  removed, bytes freed) but never raw keys. The index MUST be ineligible at
  every intermediate crash point; startup recovery completes interrupted
  purges (tombstone present ⇒ enforce deletion) before any read is served.
- **Fencing, not permanent blocking.** A manifest whose recorded purge
  generation is **lower** than the live tombstone's is ineligible and
  deleted on sight — including one reintroduced by backup or snapshot
  rollback, or published by a write that raced the purge (the FR-KVP3
  pre-publication check closes the race). New commits after the purge record
  the incremented purge generation and are eligible, so a continuing
  conversation re-caches normally. Tombstones are scoped per (epoch, index);
  an epoch rotation supersedes them (crypto-shred covers all prior state).
  Tombstones persist at least as long as the maximum eligibility window of
  any generation they fence.
- Purge, status, and tombstone enforcement MUST remain fully functional
  while `enabled=false` (a disabled tier still has purgeable residue).
- An uninstall/cleanup mode (`purge --all --forget`) MUST rotate the epoch,
  delete the namespace directory, and delete all of the namespace's Keychain
  items; the provider uninstall path invokes it so no orphaned ciphertext or
  key material outlives the product.
- Motivation (SPEC-024 FR-CI10a): `DELETE /v1/sticky` purges only
  coordinator state; without this primitive a restart-durable provider entry
  would be buyer-unpurgeable. v0.1 ships the primitive; wiring coordinator
  deletion to invoke it remotely is future work (§1 out of scope) and is a
  precondition for buyer-key persistence per FR-KVP11.

### FR-KVP9 — bounded streaming promotion (SPEC-037-R009)

- Promotion is lazy and on-demand only: triggered by a hot-tier miss for a
  key with a valid cold entry, during request admission for that key, under
  the same per-key serialization as `begin()` (FR-CI4a). Eager whole-store
  restoration at startup is forbidden.
- Restore staging MUST stay within a **hard ceiling of 256 MiB** above the
  selected hot-cache state (v1 normative; configuration may lower it, never
  raise it). Reads are chunked per FR-KVP6, verified-then-materialized per
  layer, and MUST NOT hold a second full copy of the restored tensors once
  promoted.
- Promoted entries count against the existing hot-tier budgets (200k
  tokens, entry cap); promotion MUST NOT raise any RAM ceiling. At most one
  promotion runs at a time namespace-wide (back-pressure; concurrent
  candidates fall back to miss, `disk_miss_busy`, rather than queueing).
- Each promotion is bounded by `promotion_max_seconds` (FR-KVP5) and by the
  staging ceiling; exceeding either abandons the promotion as a miss and is
  never retried within the same request.
- An entry whose promoted layers subsequently fail the FR-KVP2 predicate is
  logged `disk_promote_rejected` together with the shipped hot-tier reason,
  and the request proceeds as a normal miss.

### FR-KVP10 — lifecycle: eligibility preserved, retention bounded (SPEC-037-R010)

- **Eligibility is the hot tier's own bound, persisted.** Each generation
  records the eligibility deadline its hot entry carried (commit time + the
  shipped `ConversationCache` TTL, default 900 s). A cold entry is eligible
  only until that deadline; the disk tier grants **no eligibility
  extension**. (Extending it is a SPEC-024 eligibility change, out of scope
  — §1.) Restart survival therefore covers process loss and recovery within
  the TTL window — deploys, crashes, supervisor relaunches, fast reboots —
  which is the RESEARCH_234-measured tail this spec targets.
- **Physical retention** is separately bounded: expired or superseded
  generations are deleted by compaction (opportunistic and periodic) and at
  latest by `retention_minutes` (default 240) after creation
  (`disk_evict_retention`). TTL and retention are reuse-eligibility and
  cleanup deadlines, **not** physical-erasure guarantees; documentation and
  telemetry MUST NOT claim secure deletion at either. Bounded best-effort
  deletion comes from compaction, quota eviction, quarantine unlink, and
  key-epoch destruction.
- Clock caveats: `creation_time > now` ⇒ ineligible (FR-KVP4b). A backward
  clock step can defer retention cleanup; it cannot extend eligibility past
  the recorded deadline check and cannot resurrect a tombstoned generation.
- Disk eviction is independent of RAM promotion state; evicting a cold entry
  never touches a live hot entry, and hot-tier eviction never deletes a
  committed cold generation before its own retention deadline.
- The cache directory default is a Caches-class location (see FR-KVP11) and
  the namespace root MUST be marked excluded from Time Machine backup
  (backup-exclusion attribute) so retention bounds are not silently defeated
  by backup copies.

### FR-KVP11 — configuration, default-off rollout, buyer-key gate (SPEC-037-R011)

Config follows the `idle_prewarm` triple-source pattern (YAML block → env →
CLI overrides, that precedence). Exact surface (AC-9 fixtures):

| YAML `kv_disk_cache:` key | Env var | Default | Bounds / invalid-value rule |
|---|---|---|---|
| `enabled` | `MACPROVIDER_KV_DISK_CACHE_ENABLED` | `false` | bool; invalid ⇒ tier disabled, error logged |
| `allow_buyer_keys` | `MACPROVIDER_KV_DISK_CACHE_ALLOW_BUYER_KEYS` | `false` | bool; see gate below |
| `directory` | `MACPROVIDER_KV_DISK_CACHE_DIR` | `~/Library/Caches/macprovider/kv-cache` | absolute path; created `0700` |
| `max_bytes` | `MACPROVIDER_KV_DISK_CACHE_MAX_BYTES` | 16 GiB | > 0; invalid ⇒ tier disabled |
| `max_entries` | `MACPROVIDER_KV_DISK_CACHE_MAX_ENTRIES` | 64 | > 0; invalid ⇒ tier disabled |
| `max_entry_bytes` | `MACPROVIDER_KV_DISK_CACHE_MAX_ENTRY_BYTES` | 2 GiB | > 0; invalid ⇒ tier disabled |
| `retention_minutes` | `MACPROVIDER_KV_DISK_CACHE_RETENTION_MINUTES` | 240 | > 0; invalid ⇒ tier disabled |
| `staging_max_bytes` | `MACPROVIDER_KV_DISK_CACHE_STAGING_MAX_BYTES` | 256 MiB | ≤ 256 MiB hard (FR-KVP9); invalid ⇒ tier disabled |
| `min_free_bytes` | `MACPROVIDER_KV_DISK_CACHE_MIN_FREE_BYTES` | 8 GiB | ≥ 0; invalid ⇒ tier disabled |
| `promotion_max_seconds` | `MACPROVIDER_KV_DISK_CACHE_PROMOTION_MAX_S` | 10 | > 0; invalid ⇒ tier disabled |

Rollout gates:

- **Default off.** Enabling with a missing/non-functional purge primitive
  MUST fail closed (tier stays off, error logged).
- **Buyer-key gate.** With `allow_buyer_keys=false` (default), the tier
  persists and promotes only conversation keys that do **not** carry the
  coordinator's account-scoped `conv:` prefix — i.e. provider-owned
  synthetic/operator keys on the direct/Tier-2 ingest paths (the KVS harness
  traffic; matches the memo's synthetic-first canary, RESEARCH_233 §10).
  Setting `allow_buyer_keys=true` is an explicit operator action whose
  documented preconditions are (a) the SPEC-024 FR-CI10a buyer disclosure
  updated to cover encrypted at-rest persistence, restart survival,
  eligibility vs physical retention, and the absence of coordinator-
  propagated purge; and (b) a buyer-reaching purge path. This gate exists
  because enabling durable persistence of real buyer prefixes without those
  is a buyer-facing retention change, not a pure optimization.
- **Enable-time notice.** On enable, log one plain-language INFO line:
  directory, caps, retention, buyer-key gate state, and the purge command
  name; plus the FR-KVP7 free-space headroom check.
- Disabling stops reads and writes but does not delete entries; purge/status
  remain available (FR-KVP8), and the enable-time notice points to them.

### FR-KVP12 — telemetry, inspection, and probe boundary (SPEC-037-R012)

- **Closed reason-code enum (exhaustive, normative):** `disk_hit`,
  `disk_promote_rejected`, `disk_miss_envelope`, `disk_miss_corrupt`,
  `disk_miss_expired`, `disk_miss_tombstoned`, `disk_miss_io`,
  `disk_miss_busy`, `disk_miss_identity_unavailable`, `disk_write_skipped`,
  `disk_evict_quota`, `disk_evict_retention`, `purge_ok`. Phase mapping:
  read/validation failures → `disk_miss_*`; a promotion that then fails the
  hot-tier predicate → `disk_promote_rejected` alongside the shipped
  hot-tier reason; write-path failures → `disk_write_skipped`;
  lifecycle/quota deletions → `disk_evict_*`. §5 maps every condition to
  exactly one code.
- Events use the existing `conv_cache`-style structured stderr logging,
  keyed by the truncated key hash already used by the hot tier — never raw
  keys, raw paths containing indexes derived per-request, or token content.
- **Promotion instrumentation (stop-condition decidability):** every
  `disk_hit` records restore bytes read, decrypt+materialize wall-time (ms),
  and peak staging bytes, so the §6 gates and stop condition are evaluable
  from shipped telemetry.
- **Inspection surface:** a read-only control-socket command and
  `macprovider-cli` subcommand report, per namespace: current bytes and
  entry count vs caps, free-space headroom, key epoch, tombstone count, and
  cumulative counters per reason code. No raw keys.
- Telemetry is provider-local observability only: it MUST NOT feed billing,
  routing, settlement, or sanctions, and MUST NOT create a new cross-account
  prefix oracle (SPEC-024 FR-CI9/FR-CI10 hold unchanged).
- SPEC-032 OPoI probes bypass the cold tier entirely in v0.1. A cache
  restore failure is cache-health telemetry, never model-drift or fraud
  evidence.

### FR-KVP13 — KVS gates, production fence, stop condition (SPEC-037-R013)

The §6 gates, their production fence, and the Approach-A stop condition are
normative conformance obligations: the tier MUST NOT graduate past
synthetic-key experiments (FR-KVP11 gate) unless KVS-01..03 pass as
specified, and the stop condition MUST be executed as written when it trips.

## 5. Not-a-hit table

Every row resolves to miss (fresh prefill, correct output,
`cached_prompt_tokens` per shipped rules — 0 unless the hot tier
independently hits), with exactly one reason code:

| # | Condition | Reason code |
|---|---|---|
| 1 | `model_sha256` differs (same model ID/alias/family) | `disk_miss_envelope` |
| 2 | Model ID or catalog revision differs | `disk_miss_envelope` |
| 3 | Tokenizer identity, tokenizer configuration hash, or chat-template hash differs | `disk_miss_envelope` |
| 4 | `kvBits`, group size, quantization mode, or cache quantization policy differs | `disk_miss_envelope` |
| 5 | Cache class or layer count/shape/dtype/layout version differs from current runtime | `disk_miss_envelope` |
| 6 | Persisted cache class since removed from the serialization allowlist | `disk_miss_envelope` |
| 7 | Serialization ABI epoch differs | `disk_miss_envelope` |
| 8 | Manifest schema ID or payload codec ID unknown | `disk_miss_envelope` |
| 9 | Namespace or key-epoch mismatch (incl. file copied across namespaces/epochs) | `disk_miss_envelope` |
| 10 | HMAC index does not recompute from the presented canonical key bytes | `disk_miss_envelope` |
| 11 | Decode path class is not ordinary decode | `disk_miss_envelope` |
| 12 | Token count, generation number, or declared lengths internally inconsistent | `disk_miss_envelope` |
| 13 | `creation_time` in the future | `disk_miss_envelope` |
| 14 | Eligibility deadline passed | `disk_miss_expired` |
| 15 | AEAD tag, checksum, or length mismatch; truncated/oversized blob or chunk | `disk_miss_corrupt` |
| 16 | No committed manifest (crash between blob write and manifest publish) | `disk_miss_corrupt` |
| 17 | Malicious/oversized shape or length metadata (pre-allocation bounds check) | `disk_miss_corrupt` |
| 18 | Manifest purge generation below live tombstone's (incl. backup/snapshot reintroduction, pre-purge replay) | `disk_miss_tombstoned` |
| 19 | I/O error, disk-full, read-only FS, promotion deadline exceeded, Keychain unavailable | `disk_miss_io` |
| 20 | Concurrent promotion in flight | `disk_miss_busy` |
| 21 | Live identity input unavailable in current process | `disk_miss_identity_unavailable` |
| 22 | Promoted layers fail hot-tier predicate (LCP < 32, nothing-new, non-exact trim) | `disk_promote_rejected` + shipped reason |

## 6. KVS gates, production fence, and the Approach-A stop condition

**Production fence (normative).** KVS-01/02/03 kill-and-relaunch cycles MUST
run on a non-production host or inside an announced maintenance window; they
MUST NOT be executed against the live single-provider production pool (the
2026-07-10 outage class). All gate traffic uses provider-owned synthetic
conversation keys (FR-KVP11 default gate).

**Harness (normative).** Use the merged `test/e2e/coldwarm-ttft/` harness
(`run-coldwarm.sh --build-matrix`); do not build a parallel harness. Every
run records: regime label, prompt/input hashes, model ID/hash, catalog
revision, `kvBits`, format IDs, hit/miss reason, full prompt tokens, cached
prompt tokens, TTFT, total latency, disk bytes read/written, peak staging
RSS, and correctness outcome.

### KVS-01 — restart survival on an 8k prefix (primary gate)

Persist → kill provider → relaunch exact build/model → matching suffix
request within the eligibility window. Arms: restored (disk hit), in-RAM
warm repeat, clean cold restart (disk-disabled), and disk-enabled-but-miss.
**Protocol:** minimum 30 cycles per arm, interleaved (paired warm control
per restored cycle); percentiles nearest-rank; no outlier exclusion (report
all cycles); record host, build, and model metadata per run. Correctness
gates: multi-turn semantic fixture passes; exact expected LCP reported in
`cached_prompt_tokens`; `prompt_tokens` = full incoming length; all layers
trim exactly; a corrupted-block variant yields miss with correct output.
**Performance gate (acceptance hypothesis, normalized):** restored p50 ≤
`max(1.25 × warm p50, warm p50 + 1 s)` and restored p95 ≤ `max(1.5 × warm
p95, warm p95 + 2 s)`; once a usable cold control exists, ≥ 30% p95 TTFT
reduction vs that control. v0.1 measures single-conversation restore only;
concurrent post-restart resume yield (thundering-herd realism) is
explicitly not covered by this gate and is recorded as an open evaluation
item in the gate's decision-log entry.

### KVS-02 / KVS-03 — invalidation gates

Warm-swap same family → deterministic miss with explicit reason code;
exact-hash change under a tempting alias → zero old-generation hits,
tombstone/invalidation recorded, no stale payload read into model memory.
Repeat across tokenizer, `kvBits`, ABI-epoch, truncated-manifest, and
envelope-field-mutation variants.

### Stop condition (normative)

If KVS-01 cannot meet the warm-relative gate **without replacing the current
per-conversation KV layout with a shared paged allocator** — e.g. tensor
reconstruction dominates TTFT (decidable from the FR-KVP12 promotion
instrumentation), the format forces full-copy materialization, RAM peaks are
unsafe, or `mlx-swift-lm` cannot restore the shipped cache classes reliably
— then Approach A PAUSES: no further persistence engineering; record the
finding and the Approach C / RESEARCH_232 paged-layout sequencing decision
as a `beta/DECISION_CRITERIA.md` entry naming the failed gate, the measured
numbers, and the chosen sequencing. The v1 codec boundary exists so a later
paged layout is a **new codec version**, never a reinterpretation of v1
blobs.

KVS-04 (24-hour budget soak) and KVS-05 (prewarm composition) are later
milestone gates (RESEARCH_233 §10), not v0.1 acceptance.

## 7. Acceptance criteria (fixtures)

All are required tests in `phase3-binary/Tests/macprovider-cliTests/`:

- **AC-1 round trip:** snapshot → serialize → deserialize →
  envelope-validate → promote → exact LCP/trim reuse produces identical
  layer state and identical `cached_prompt_tokens` / `prompt_tokens`
  accounting as a same-process hit at the same LCP.
- **AC-2 not-a-hit matrix:** every §5 row exercised, including a mutation
  fixture for **each individual authenticated envelope field** and
  composed/decomposed Unicode key forms; each yields exactly its mapped
  reason code and a fresh correct result; no partial reuse.
- **AC-3 crash consistency:** kill injected at each FR-KVP3 ordering
  boundary → recovery sees old generation, complete new generation, or
  clean miss; never a partial generation; orphan bytes swept and accounted.
- **AC-4 tombstone/purge:** tombstone-first ordering observed; kill between
  tombstone-durable and deletion → index ineligible and recovery completes
  the purge; pre-purge manifest reintroduced (simulated snapshot/backup
  restore) → refused via purge-generation fence; post-purge re-caching
  succeeds under the new purge generation; purge-all rotates the epoch
  crash-safely and deletes old Keychain material; hot-tier entry removed;
  purge works with `enabled=false`; success never reported before
  durability.
- **AC-5 namespace isolation and locking:** entry copied into another
  namespace fails closed; quota eviction in namespace A never touches
  namespace B; second process contending the namespace lock stays dormant
  without serve-loop impact.
- **AC-6 budgets:** promotion staging stays ≤ ceiling on a large entry;
  promotion deadline abandons cleanly; concurrent promotion degrades to
  `disk_miss_busy`; write-side quota reservation, free-space floor, and
  per-entry cap each enforce.
- **AC-7 contract non-drift:** within a single residency epoch (no
  restart), tier-enabled vs disabled produce identical response/receipt
  schemas, field sets, and accounting rules; under pinned deterministic
  decoding, byte-identical bodies. Across a restart, the only permitted
  difference is legitimate hit availability (positive `cached_prompt_tokens`
  by the unchanged LCP rule; AC-1 values). No new fields either way.
- **AC-8 inherited traps + spec-decode exclusion:** tokenizer
  non-canonicity, full-prompt accounting, and `cache_offset` priming
  fixtures pass against promoted (not just resident) cache state; a
  speculative-decode-routed request on each endpoint acquires no lease,
  triggers no promotion, commits nothing, and leaves no busy key.
- **AC-9 config and rollout gates:** default-off; enable without purge
  primitive fails closed; buyer-key gate filters `conv:`-prefixed keys when
  `allow_buyer_keys=false`; triple-source precedence and each
  invalid-value rule honored; enable-time notice and headroom check
  emitted; snapshot-at-commit verified (mutating the hot entry after commit
  does not alter the persisted bytes).

## 8. Sequencing with RESEARCH_232 / SPEC-038

SPEC-037's IMPL serializes the **current** contiguous per-conversation layer
state and lands **first**; SPEC-038 (continuous batching) rebases onto it
and registers as a consumer of `kv-cache-persistence` when it lands. This
spec MUST NOT introduce paged blocks, copy-on-write sharing, or a new
attention allocator. **Any** cache-class or layout change that breaks v1
round-trip compatibility — paged or not — requires a new payload codec ID
plus an ABI-epoch bump, and re-running the KVS gates under the new layout
before it can persist; v1 blobs are invalidated by the epoch, never
migrated or reinterpreted. SPEC-038 MUST either retain v1 round-trip
support for unchanged layouts or keep its layout flag-isolated from
persistence.

## 9. No-go list (inherited from RESEARCH_233 §9.3)

oMLX as engine; d-inference inspection (clean-room absolute); multi-provider
sidecar; global dedup; plaintext token files as production cache; reuse by
family/alias without exact hash; best-effort partial-layer reuse; counting
startup rehydrate as eliminated prefill; raising RAM budgets because disk
exists; claiming physical erasure at TTL; shipping without purge +
tombstones; adding fields to LOCKED SPEC-015 v0.4.2; treating oMLX marketing
numbers as macprovider evidence.

## 10. Open questions carried (non-blocking for v0.1)

Coordinator purge-propagation design (precondition for buyer keys, FR-KVP11);
per-SSD-class disk budgets; q4-KV quality gates and the active-`kvBits`
question for the live Qwen model (memo Q6/Q7 — affects the per-entry cap);
concurrent post-restart promotion policy beyond one-at-a-time; buyer-facing
provenance (deferred to a future SPEC-015 v0.5 question). Tracked in
RESEARCH_233 §11; none may weaken a MUST above.
