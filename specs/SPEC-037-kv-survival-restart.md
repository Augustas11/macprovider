# SPEC-037 — KV survival across provider restarts (encrypted provider-local disk tier)

Version: v0.1.0
Status: draft (normative design; IMPL lands behind a disabled-by-default flag)
Owner: provider runtime / prefix-cache persistence
Decision source: `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` (landed decision memo, commit `d6881b14`)
Audit history: R1+R2 five-lane audits (codex code/security/architect + adversarial verificator + product critic) reconciled in this text. R2 forced: positive synthetic-key sub-namespace (the shipped `conv:` validator makes prefix-exclusion gating unsatisfiable), per-entry Keychain DEKs as the rollback-proof revocation anchor, purge-generation stamping at lease acquisition, rotation-intent journal, byte-level format grammar, write-side staging caps, and `allow_buyer_keys` rejected in v0.1.

## 1. Purpose and scope

Give the provider's shipped in-RAM prefix cache (`ConversationCache`) a cold
tier on local disk so a reusable conversation prefix survives provider process
loss — deploy, crash, supervisor relaunch, and (within eligibility bounds,
see FR-KVP10) host reboot — and cuts the restart-driven re-prefill
contribution to the buyer-TTFT tail measured in RESEARCH_234 (p95 16.8 s,
p99 51.4 s, 4.2% of requests over 20 s).

The tier changes only cache **residency** — which turns can still hit after
the hot tier has lost the entry (process loss, or intra-process LRU/token-cap
eviction). It introduces no new wire, receipt, or billing field and changes
no existing field's computation rule (FR-KVP1). It is expected and correct
that a tier-enabled provider reports a positive, provider-earned
`cached_prompt_tokens` on turns where a tier-disabled provider would report 0
— after a restart **or** after an intra-epoch hot-tier eviction; that
availability difference is the feature. Cache **eligibility** rules — the
reuse predicate and the TTL eligibility bound — are unchanged (FR-KVP2,
FR-KVP10).

In scope for v0.1:

- An encrypted, provider-namespaced disk tier behind the existing
  `ConversationCache` actor (RESEARCH_233 **Approach A**), using the format
  of §5a: versioned opaque per-conversation serialization, immutable
  generation blobs, atomic manifests.
- The strict exact-match safety envelope, fully bound into AEAD
  authentication, that gates any disk hit.
- Per-provider namespace, quota, and eviction model with a single-writer
  lock.
- A provider-side conversation-key **purge primitive** whose revocation
  authority is per-entry key destruction (rollback-proof), with
  tombstone-first ordering and purge-generation fencing (ship-blocker: the
  disk tier MUST NOT be enabled without it).
- Bounded, chunk-authenticated streaming promotion into the current RAM
  cache, and bounded write-side snapshotting.
- An operator inspection surface (status + counters + promotion timing).
- The KVS-01 benchmark gate, its production fence, and the explicit stop
  condition for Approach A.

Out of scope (recorded, not silently dropped):

- Any change to LOCKED SPEC-015 v0.4.2 receipts. Buyer-facing cache
  provenance, if ever needed, is a named future SPEC-015 v0.5 question.
- Any change to SPEC-024 `cached_prompt_tokens` wire/mirror semantics, the
  reuse predicate, the `conv:` key-validation rules, or the TTL eligibility
  bound; any change to SPEC-005 billing arithmetic/eligibility. Extending
  the eligibility window beyond the shipped hot-tier TTL would be a
  cache-eligibility change and requires a SPEC-024 amendment — this spec
  deliberately does not make it.
- A shared paged-KV allocator, copy-on-write prefix sharing, or any
  batch-aware layout (RESEARCH_232 / SPEC-038 territory; see §8).
- Cross-conversation or cross-provider block sharing and global
  content-addressed dedup (rejected — see §9 no-go list).
- External sidecar processes; oMLX as inference engine (rejected).
- Speculative-decoding cache state (excluded from the format and the path).
- Coordinator-propagated purge (`DELETE /v1/sticky` → provider push). v0.1
  ships the provider-local primitive it would invoke; the propagation
  channel is future work and MUST NOT be presented as shipped buyer purge.
  Because it does not exist, **persistence of buyer conversation keys is
  disabled and unenableable in v0.1** (FR-KVP11).
- Defense against a hostile process running under the **same macOS user
  (euid)** as the provider, and against host-privileged actions (root, full
  system restore including the user Keychain, kernel/clock control beyond
  the FR-KVP10 dormancy check). Such actors can already reach the provider's
  Keychain-accessible secrets. The isolation guarantees here hold against
  other-UID processes, other provider namespaces, offline disk access
  (FileVault + AEAD), and **data-volume snapshot/backup rollback of the
  cache directory** (closed by per-entry Keychain DEKs, FR-KVP8). The
  memo's separate-UID deployment control (RESEARCH_233 §5.2) remains the
  recommendation for multi-provider hosts.
- Real buyer traffic on the direct-HTTP ingest path. The v0.1 synthetic
  gate (FR-KVP11) treats direct-ingest traffic in the reserved sub-namespace
  as operator-owned; a deployment that fronts real buyers over direct HTTP
  must not enable the tier.

## 2. Dependencies and authority

- **SPEC-024 v0.2.1 §11–§16** — provider-local cache isolation baseline
  (FR-CI1..FR-CI10a), including the shipped `conv:` key-validation rules
  this spec's gate builds on. Preserved, not re-owned.
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
| Synthetic key | A key in the reserved `conv:kvs-synth:` sub-namespace (FR-KVP11). |
| Entry | All persisted state for one canonical key in one namespace. |
| Generation | One immutable committed serialization of an entry (`gen-<N>`). |
| Commit sequence | Monotonic per-index counter allocated under the hot lease, ordering generations. |
| Manifest | The atomically-replaced per-entry metadata document (§5a) naming the committed generation. |
| Envelope | The authenticated manifest metadata a hit must match per FR-KVP4. |
| Namespace | The per-provider-identity subtree holding entries, quota, metadata, and journals. |
| Namespace metadata | The fsync-protected control document holding key epoch, purge high-watermarks, clock high-water, rotation journal. |
| Key epoch | Integer version of the namespace's key material; rotating it crypto-shreds all prior ciphertext. |
| Entry DEK | Per-entry random data-encryption key stored as its own Keychain item; its destruction is the purge revocation authority. |
| Purge generation | Monotonic per-index counter fencing pre-purge state from post-purge writes; high-watermark lives in namespace metadata. |
| Tombstone | Durable per-(epoch, index) purge record used for crash recovery and write fencing. |
| Promotion | Streaming a validated cold entry into hot-tier `[KVCache]` layers. |
| Residency epoch | The lifetime of one provider process between starts. |
| Tier activation | The instant the process acquires the namespace lock and completes recovery (FR-KVP7). |

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
untouched. Hit **availability** legitimately differs wherever the cold tier
retains residency the hot tier has lost — across a restart, and within one
residency epoch after hot-tier LRU/token-cap eviction. Response and receipt
**schemas, field sets, and computation rules** MUST be identical with the
tier enabled or disabled (AC-7); suppressing or inflating a reuse report to
mimic the other configuration is forbidden (it would violate SPEC-024
FR-CI3).

### FR-KVP2 — hot-tier semantics preserved exactly (SPEC-037-R002)

The shipped reuse mechanism is unchanged and remains the only reuse
mechanism:

1. the trimmed `conversation_key` selects exactly one candidate (FR-CI1);
   key validity remains the shipped `validConversationKey` rule (`conv:`
   prefix et al.) — this spec narrows which valid keys may *persist*
   (FR-KVP11), never which keys may be cached in RAM;
2. reuse is the exact token-level LCP, `LCP >= 32` and `LCP <` incoming
   prompt length (FR-CI2);
3. every KV layer must be trimmable and every trim must remove exactly the
   requested count — any shortfall is a miss;
4. the incoming request still reports its full prompt length; and
5. speculative decoding stays entirely outside this cache path. Normatively:
   on **both** the streaming and non-streaming endpoints,
   speculative-decode routing MUST be determined **before** any
   conversation-cache `begin()`, promotion, or commit; a request routed to
   speculative decode MUST NOT acquire a cache lease, trigger promotion, or
   commit cache state, and MUST NOT leave a key busy (fixture: AC-8).

Promotion MUST materialize a cold entry into the same in-memory
representation the hot tier commits today, then let the existing `begin()`
predicate decide hit/miss under the same per-key serialization (FR-CI4a).
The cold tier MUST NOT implement a second, divergent reuse predicate. The
three inherited traps from commit `84e50c92` (tokenizer non-canonicity →
token-LCP only; full-prompt accounting; `cache_offset` priming) are
persistence-format test fixtures (§7).

### FR-KVP3 — snapshot, write ordering, durability events (SPEC-037-R003)

- **Snapshot at commit.** The hot tier mutates committed layer objects in
  place on subsequent trims, so the disk writer MUST serialize from an
  immutable snapshot captured synchronously at hot-tier `commit()` **while
  the per-key lease is still held**. The snapshot MUST include, atomically
  at that instant: (a) the layer state and canonical token sequence
  (`prompt_token_ids ‖ generated_token_ids` as committed); (b) the
  **complete envelope identity** — served model ID and `model_sha256`,
  catalog revision, tokenizer/template identities, geometry, `kvBits`
  tuple, decode path class, key epoch, sampled purge generation (see
  FR-KVP8 stamping rule), and an allocated **commit sequence** (monotonic
  per index). A warm-swap or config change after commit MUST NOT alter what
  the snapshot records (fixture: AC-9).
- **Write-side budget (RAM-DoS bound).** Before copying, the writer MUST
  estimate snapshot bytes from validated cache geometry; if the estimate
  exceeds `write_staging_max_bytes` (default 256 MiB; hard max 1 GiB) or
  the per-entry byte cap, the write is skipped (`disk_write_skipped`)
  without copying. At most **one** pending snapshot may exist per index
  (a newer commit replaces an unstarted older one) and pending snapshot
  bytes namespace-wide MUST NOT exceed `write_staging_max_bytes`; excess
  commits skip persistence. The hot commit itself is never blocked or
  failed by any of this; the synchronous copy cost is bounded by the same
  cap and is measured by the KVS harness (§6 write-path overhead).
- **Write ordering (per index, single writer — FR-KVP7):** writes for one
  index are serialized in commit-sequence order; the writer MUST drop any
  snapshot whose commit sequence is ≤ the last published one. Blob and
  manifest temp files use per-write unique names created with `O_EXCL` in
  the **same directory** as their destination. Commit protocol: write
  `gen-<N>.blob` → `fsync(blob fd)` → `fsync(entry directory)` → write
  manifest to unique temp → `fsync(temp fd)` → enter the per-index
  **mutation lane** (the same critical section purge uses, FR-KVP8) and
  atomically re-verify: key epoch current, sampled purge generation ≥ the
  live high-watermark, commit sequence still newest → atomic `rename(2)`
  over `manifest.json` → `fsync(entry directory)` → leave the lane → emit
  `disk_write_committed` (with index hash, generation, commit sequence).
  Because the re-check and rename happen inside the mutation lane, no purge
  can interleave between them.
- After a crash, recovery (at tier activation, FR-KVP7) observes either the
  previous committed generation, the complete new generation, or no
  committed generation — never a partially-visible one; orphan temp/blob
  files are swept and their bytes reclaimed.
- **Shutdown drain.** On graceful shutdown (deploy path), the writer drains
  pending snapshots for up to `shutdown_drain_seconds` (default 5), then
  abandons the rest; crash survival is only promised for generations whose
  `disk_write_committed` was emitted, and the KVS harness uses that event
  as its persist-before-kill barrier (§6).
- Writes occur only after a successful request commit. Any write failure is
  logged (`disk_write_skipped`) and dropped; the hot tier is unaffected.

### FR-KVP4 — envelope: strict validation, fully authenticated (SPEC-037-R004)

Every manifest records the envelope (encoded per §5a). On load, validation
completes **before any payload byte is deserialized**, in four categories:

**(a) Exact-match identity fields** — items 1–10 MUST equal the current
runtime value byte-for-byte:

1. manifest schema ID and payload codec ID (`kvsurv-manifest-v1` /
   `kvsurv-codec-v1`);
2. provider namespace ID and key epoch;
3. HMAC index of the canonical key bytes (recomputed and compared);
4. model ID, exact `model_sha256` (SPEC-010 canonical artifact hash), and
   catalog revision;
5. tokenizer identity, tokenizer configuration hash, and chat-template
   hash;
6. serialization compatibility identity: the source-controlled
   **serialization ABI epoch** plus the exact pinned `mlx-swift-lm`
   revision and MLX version strings recorded at build time. The ABI epoch
   MUST be bumped by explicit code change whenever cache-class state
   layout, the serializer, or tensor ABI changes incompatibly; the pinned
   revision strings additionally hard-miss across any dependency bump
   (cache invalidation on upgrade is accepted — this tier is an
   optimization);
7. cache implementation class and layer count (v1 allowlist: §5a);
8. per-layer tensor shapes, dtypes, and layout version;
9. `kvBits`, quantization group size, quantization mode, and cache
   quantization policy;
10. decode path class (ordinary decode only; speculative state MUST NOT be
    written).

**(a′) Fence field:** 11. purge generation — NOT byte-equality: it MUST be
≥ the live purge-generation high-watermark for the index (FR-KVP8).

**(b) Temporal checks:** `creation_time ≤ now`, `now ≤
eligibility_deadline` (FR-KVP10), evaluated against the clock-rollback
guard of FR-KVP10.

**(c) Structural consistency:** token count, generation number, commit
sequence, chunk table (count, per-chunk lengths, contiguous ordinals
`0..count-1`, no gaps or duplicates), total payload length, and declared
tensor shapes MUST be internally consistent and within the §5a parsing
bounds **before any allocation is sized from them**.

**(d) Cryptographic verification:** the manifest's declared blob SHA-256
matches, and every payload chunk's AEAD tag verifies with the entry DEK
under the §5a AAD (which binds the entire manifest, so rewriting any
envelope field invalidates every chunk).

**Live identity completeness.** If any live-identity input (e.g. the
canonical model hash) is unavailable in the current process, the tier MUST
NOT write (`disk_write_skipped`, reason detail `identity_unavailable`) and
MUST NOT promote (`disk_miss_identity_unavailable`). Deserialization
success is NOT reuse eligibility. Model *family*, filename, or
catalog-alias similarity is never sufficient — a warm-swap to a same-family
model is a miss unless every identity above matches. Mutation of each
individual envelope field is a required fixture (AC-2).

### FR-KVP5 — fail safe to miss (SPEC-037-R005)

Any of the following resolves to a **miss with correct fresh output**,
never a partial or best-effort reuse, never a crash of the serve loop, and
never an escalation into drift/fraud/sanction signals: any FR-KVP4
category failure; expiry; checksum/AEAD failure; truncated, oversized, or
malformed blob or manifest; incomplete commit; unsupported or
allowlist-removed cache class; non-exact trim after promotion; I/O error or
promotion deadline; read-side disk errors; oversized or malicious
length/shape metadata; wrong or unavailable key epoch; Keychain material
unavailable (pre-unlock, missing entitlement, or destroyed DEK); tombstoned
or fenced index; staging or concurrency budget exhaustion; clock-rollback
dormancy; quarantined store. §5 maps each condition to exactly one
FR-KVP12 reason code, split by phase (read/promotion vs write vs
control-plane). Corrupt artifacts are quarantined/deleted asynchronously;
corrupt or unreadable **control-plane** state (namespace metadata, rotation
journal, tombstones) MUST quarantine the namespace or index into dormancy
(`disk_store_quarantined`) — it is never interpreted as "no fence".

**Bounded miss cost.** The cold tier adds bounded work to a miss, not zero
work: manifest reads are bounded by §5a parsing limits (`fstat` before
read); promotion work is bounded by the staging ceiling and
`promotion_max_seconds` (default 5 s; on expiry the promotion is abandoned
and the request proceeds as a miss — worst-case added latency for that
request ≈ the promotion budget on top of a normal fresh prefill, stated so
operators can reason about the regression). A cold-tier failure MUST NOT
block, fail, or corrupt the request being served.

### FR-KVP6 — encryption, index hiding, key lifecycle (SPEC-037-R006)

- **Canonical key bytes.** One function everywhere (lookup, write, purge,
  tombstone): trim whitespace per the shipped FR-CI1 handling, apply
  Unicode NFC normalization, encode UTF-8. This matches Swift's
  canonical-equivalence string keying in the hot tier so one logical key
  maps to one index (positive equivalence fixture: AC-1).
- **Index hiding.** Entry directory names are
  `base16(HMAC-SHA256(index_key_epochN, canonical_key_bytes))`. The raw key
  never appears in any path, log, or manifest field. Index computation
  happens only inside the owning provider process.
- **Key hierarchy.**
  - Per key epoch, an **epoch master key** (random 32 bytes) is stored as
    its own Keychain item. The per-epoch **index key** is derived
    HKDF-SHA256(epoch master, salt = "macprovider-kv-v1", info =
    "index/<epoch>", L = 32). A conformance vector for the derivation is a
    required fixture.
  - Per entry, a random 32-byte **entry DEK** is stored as its own Keychain
    item (service embeds namespace + epoch, account = entry index) and is
    the AES-256-GCM key for that entry's chunks. **DEK destruction is the
    purge revocation authority** (FR-KVP8): ciphertext restored from any
    directory backup/snapshot is undecryptable once the DEK is gone.
- **Keychain mode (normative).** All items use the **Data Protection
  Keychain**: `kSecUseDataProtectionKeychain = true`, an access group per
  the shipped `SecureEnclaveIdentity` pattern (`keychain-access-groups`
  entitlement; `MACPROVIDER_KEYCHAIN_ACCESS_GROUP` override),
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable,
  and non-interactive lookups (authentication UI forbidden; failure ⇒
  dormant). If the entitlement/access group is unavailable (e.g. unsigned
  dev build), the tier stays dormant and warns — it does not fall back to
  the legacy login keychain (whose ACL model does not honor
  `kSecAttrAccessible`).
- **AEAD framing.** Chunked AES-256-GCM per §5a: every chunk uses a fresh
  CSPRNG 96-bit nonce (never derived from counters that can roll back);
  AAD binds the whole manifest (hence the full envelope, chunk table
  included) plus the chunk ordinal. Total chunk count is an authenticated
  envelope field, and the reader MUST verify decrypted chunks cover
  ordinals `0..count-1` exactly.
- **Epoch rotation (purge-all), crash-safe ordering:** (0) durably record a
  rotation-intent journal entry `{from: N, to: N+1, phase}` in namespace
  metadata (fsync) **before any key operation**; (1) create + verify the
  epoch-(N+1) master Keychain item; (2) durably commit epoch N+1 in
  namespace metadata (fsync + atomic rename); (3) delete epoch-N Keychain
  items (master + all entry DEKs) and verify absence; (4) delete old-epoch
  files best-effort; (5) clear the journal entry and report success. At
  tier activation, an open journal entry blocks all reads until recovery
  drives the rotation forward through the remaining phases; the namespace
  MUST never fall back to an older epoch.
- **Pre-unlock behavior.** If Keychain material is unavailable, the tier is
  dormant: reads miss (`disk_miss_io`, detail `keychain_unavailable`),
  writes skip, and the tier retries opportunistically. Dormancy telemetry
  MUST be rate-limited/aggregated (no per-request log storms). Never fail
  the serve loop for key unavailability.
- Directory/file discipline: namespace directories `0700`, files `0600`,
  `O_NOFOLLOW` on open, owner/euid verified — the control-socket hardening
  pattern; violations quarantine the namespace (`disk_store_quarantined`).
- Encryption is a necessary control, not a secrecy claim: it does not
  protect against a compromised live provider process or host-privileged
  restore of the Keychain itself (§1 exclusions), and no physical-erasure
  claim is made at TTL (FR-KVP10).

### FR-KVP7 — namespace, single writer, quota (SPEC-037-R007)

- The cold tier root contains one namespace per provider identity, keyed by
  a digest of the stable provider ID; namespace metadata records provider
  ID, key epoch, format IDs, purge high-watermarks, clock high-water, and
  the rotation journal. A provider process MUST only open its own
  namespace.
- **Single writer with retry.** A process MUST hold an exclusive advisory
  lock (`flock`) on a namespace lockfile while the tier is active. If the
  lock is unavailable (supervisor-relaunch overlap, duplicate instance),
  the tier is **transiently** dormant and MUST retry acquisition with
  bounded backoff, warning if contention persists; it activates on
  acquisition. **All recovery** (orphan sweep, tombstone/purge completion,
  rotation-journal resolution, usage-journal recovery) runs at
  **tier activation** — not merely process start — and no disk read is
  served before it completes. Every mutating purge/cleanup operation
  requires the lock **regardless of the `enabled` flag** (a disabled tier
  still purges); a purge that cannot acquire it within a bounded wait fails
  (`purge_failed`), never silently.
- Cross-namespace reads, writes, eviction, or key derivation are forbidden.
  A raw entry copied between namespace directories MUST fail closed (the
  namespace ID is bound into the HMAC index, the DEK item identity, and
  the authenticated envelope).
- **Quota accounting covers every namespace artifact**: blobs, manifests,
  temp files, tombstones, journals, quarantine, and metadata. Bytes are
  reserved before a write begins; orphaned bytes are swept at activation.
  A small **non-evictable metadata reserve** (default 4 MiB) is held back
  from the data budget so tombstones, journals, and namespace metadata can
  always be written — purge MUST NOT become impossible at full quota, and
  purge MAY evict unrelated blobs to fund itself. Tombstone records are
  bounded (compacted once their fence is subsumed by the namespace
  high-watermark map, which is itself bounded and retained until epoch
  destruction).
- Caps (operational defaults, not protocol values): total bytes 16 GiB,
  entry count 64, per-entry bytes 2 GiB. The per-entry cap is calibrated to
  the memo's q4-KV estimate; if the active KV representation is FP16,
  long-context entries may exceed it and be skipped
  (`disk_write_skipped`) — the active-`kvBits` question is memo Q6/Q7.
- **Free-space floor.** Writes are refused (`disk_write_skipped`) when host
  free space would drop below `min_free_bytes` (default 8 GiB; MUST be
  ≥ 1 GiB — a zero floor is invalid config). At enable time the tier logs
  free space vs configured caps and warns when headroom is insufficient.
- Eviction on quota pressure is LRU by last-eligible-use within the
  namespace only (`disk_evict_quota`). **LRU metadata** is advisory: a
  namespace-level append-only usage journal (compacted periodically,
  crash-tolerant; recovery falls back to manifest creation times).
  It is not authenticated — tampering can reorder eviction within the
  namespace (same-euid excluded per §1) but can never affect eligibility.
- Capacity-channel scope (SPEC-024 FR-CI8 extension): per-namespace quotas
  plus the single-writer lock **bound** each namespace's disk usage and
  prevent cross-namespace eviction; they do not close joint volume
  exhaustion (two namespaces can together approach the shared volume's
  floor). The mandatory nonzero free-space floor mitigates that residual;
  hosts running multiple providers MUST provision `max_bytes` sums within
  the volume budget (operator guidance, logged at enable time). Global
  content-addressed dedup across keys, accounts, or namespaces is
  forbidden.

### FR-KVP8 — purge primitive: DEK destruction + fencing — ship-blocker (SPEC-037-R008)

- The provider binary MUST expose a local purge primitive **before** the
  disk tier can be enabled: a control-socket command (and matching
  `macprovider-cli` subcommand) that (a) purges one conversation key —
  addressed by raw key, canonicalized and HMAC-indexed inside the provider
  process — or (b) purges the whole namespace via key-epoch rotation
  (FR-KVP6).
- **Revocation authority is DEK destruction.** Single-key purge ordering:
  (1) advance the index's purge-generation high-watermark in namespace
  metadata and write + `fsync` a tombstone for the (epoch, index) carrying
  it; (2) delete the entry's DEK Keychain item and verify absence — from
  this instant the entry is unrecoverable even if every file is restored
  from a snapshot or backup of the cache directory; (3) remove the matching
  hot-tier entry and cancel any in-flight promotion or pending/queued
  snapshot for the index whose sampled purge generation predates the new
  high-watermark; (4) delete the entry's generations and manifest; (5)
  report success with counts (entries removed, bytes freed), never raw
  keys. The index MUST be ineligible at every intermediate crash point;
  recovery at tier activation completes interrupted purges (tombstone
  present ⇒ finish steps 2–4) before any read is served. A purge failing
  partway (Keychain deletion error, I/O error, lock timeout) reports
  `purge_failed` and leaves the tombstone in place (fail closed).
- **Stamping rule (fence semantics).** The purge generation a writer stamps
  into a manifest is the high-watermark **sampled at hot-lease acquisition
  (`begin()`)**, carried immutably through the snapshot, and re-verified
  `≥` the live high-watermark inside the FR-KVP3 mutation lane at
  publication. A manifest whose stamped generation is below the live
  high-watermark is ineligible and deleted on sight — including one
  reintroduced by backup/snapshot rollback (already undecryptable per step
  2) or published by a racing writer. New commits after the purge sample
  the incremented high-watermark and are eligible, so a continuing
  conversation re-caches normally. The high-watermark map lives in
  namespace metadata, is retained until epoch destruction (it survives
  tombstone compaction), and is bounded (FR-KVP7).
- **Purge-all (epoch rotation)** MUST, before reporting success: fence the
  namespace (no new writes/promotions), cancel or join all in-flight
  promotions and pending snapshots, **remove every hot-tier entry and
  invalidate every outstanding hot lease's pending commit**, then run the
  FR-KVP6 rotation journal through old-key destruction. Success is
  reported only after the old epoch's Keychain material is verified
  absent.
- Purge, status, and fence enforcement MUST remain fully functional while
  `enabled=false` (a disabled tier still has purgeable residue) — under
  the namespace lock per FR-KVP7.
- An uninstall/cleanup mode (`purge --all --forget`) MUST rotate the
  epoch, delete the namespace directory, and delete all of the namespace's
  Keychain items; the provider uninstall path invokes it so no orphaned
  ciphertext or key material outlives the product.
- Motivation (SPEC-024 FR-CI10a): `DELETE /v1/sticky` purges only
  coordinator state; without this primitive a restart-durable provider
  entry would be buyer-unpurgeable. v0.1 ships the primitive; wiring
  coordinator deletion to invoke it remotely is future work (§1) and a
  precondition for ever enabling buyer-key persistence (FR-KVP11).

### FR-KVP9 — bounded streaming promotion (SPEC-037-R009)

- Promotion is lazy and on-demand only: triggered by a hot-tier miss for a
  key with a valid cold entry, during request admission for that key, under
  the same per-key serialization as `begin()` (FR-CI4a). Eager whole-store
  restoration at startup is forbidden.
- Restore staging MUST stay within a **hard ceiling of 256 MiB** above the
  selected hot-cache state (v1 normative; configuration may lower it,
  never raise it). Reads are chunked per §5a, verified-then-materialized
  per layer, and MUST NOT hold a second full copy of the restored tensors
  once promoted. An entry whose declared decoded size exceeds the ceiling
  is not promoted (`disk_miss_budget`).
- Promoted entries count against the existing hot-tier budgets (200k
  tokens, entry cap); promotion MUST NOT raise any RAM ceiling. At most one
  promotion runs at a time namespace-wide (back-pressure; concurrent
  candidates fall back to miss, `disk_miss_busy`, rather than queueing).
- Each promotion is bounded by `promotion_max_seconds` and the staging
  ceiling (FR-KVP5); exceeding either abandons the promotion as a miss
  (`disk_miss_io` for the deadline, `disk_miss_budget` for the ceiling)
  and is never retried within the same request.
- An entry whose promoted layers subsequently fail the FR-KVP2 predicate is
  logged `disk_promote_rejected` together with the shipped hot-tier
  reason, and the request proceeds as a normal miss.

### FR-KVP10 — lifecycle: eligibility preserved, retention bounded (SPEC-037-R010)

- **Eligibility is the hot tier's own bound, persisted.** Each generation
  records the eligibility deadline its hot entry carried (commit time +
  the shipped `ConversationCache` TTL as configured, default 900 s). A
  cold entry is eligible only until that deadline; the disk tier grants
  **no eligibility extension**. (Extending it is a SPEC-024 eligibility
  change, out of scope — §1.) Restart survival therefore covers process
  loss and recovery within the TTL window measured from the last turn's
  commit — deploys, crashes, supervisor relaunches, fast reboots. Reboot
  recovery additionally depends on Keychain availability after first
  unlock (FR-KVP6), so "host reboot" is a bounded capability, not
  unconditional.
- **Clock integrity.** Namespace metadata maintains a persisted,
  monotonically non-decreasing **wall-clock high-water mark** (updated at
  writes and periodically, fsynced). If current wall-clock < high-water,
  the tier is dormant (reads miss `disk_miss_io`, detail
  `clock_rollback`; writes skip) until the clock reaches the mark again.
  This prevents a backward clock step from re-opening expired eligibility.
  `creation_time > now` additionally hard-misses (FR-KVP4b). No stronger
  clock guarantee is claimed (host-privileged clock control is out of
  scope, §1).
- **Physical retention** is separately bounded: expired or superseded
  generations are deleted by compaction (opportunistic and periodic) and
  at latest `retention_minutes` (operational default 60) after creation
  (`disk_evict_retention`). Retention is a cleanup deadline that does
  **not** extend reuse eligibility — and must not be presented to
  operators as survival time (FR-KVP11 notice). TTL and retention are
  reuse-eligibility and cleanup deadlines, **not** physical-erasure
  guarantees; bounded best-effort deletion comes from compaction, quota
  eviction, quarantine unlink, DEK destruction, and key-epoch
  destruction.
- Disk eviction is independent of RAM promotion state; evicting a cold
  entry never touches a live hot entry, and hot-tier eviction never
  deletes a committed cold generation before its retention deadline.
- The cache directory default is a Caches-class location (FR-KVP11) and
  the namespace root MUST be marked excluded from Time Machine backup
  (backup-exclusion attribute). Snapshot/backup copies that evade this are
  covered by the DEK revocation anchor (FR-KVP8), not by retention.

### FR-KVP11 — configuration, default-off rollout, synthetic-key gate (SPEC-037-R011)

Config follows the `idle_prewarm` triple-source pattern with precedence
YAML file → environment → CLI overrides. Exact surface (AC-9 fixtures):

| YAML `kv_disk_cache:` key | Env var | CLI flag | Default | Rule |
|---|---|---|---|---|
| `enabled` | `MACPROVIDER_KV_DISK_CACHE_ENABLED` | `--kv-disk-cache-enabled` | `false` | bool; invalid ⇒ tier disabled, error logged |
| `allow_buyer_keys` | `MACPROVIDER_KV_DISK_CACHE_ALLOW_BUYER_KEYS` | `--kv-disk-cache-allow-buyer-keys` | `false` | **v0.1: `true` is rejected** — config error, tier disabled, error names the preconditions. Reserved for a future revision gated on machine-verifiable coordinator purge propagation + published FR-CI10a disclosure |
| `directory` | `MACPROVIDER_KV_DISK_CACHE_DIR` | `--kv-disk-cache-dir` | `~/Library/Caches/macprovider/kv-cache` | leading `~` expanded to the user home, then MUST be absolute; created `0700` |
| `max_bytes` | `MACPROVIDER_KV_DISK_CACHE_MAX_BYTES` | `--kv-disk-cache-max-bytes` | 16 GiB | > 0; invalid ⇒ tier disabled |
| `max_entries` | `MACPROVIDER_KV_DISK_CACHE_MAX_ENTRIES` | `--kv-disk-cache-max-entries` | 64 | > 0; invalid ⇒ tier disabled |
| `max_entry_bytes` | `MACPROVIDER_KV_DISK_CACHE_MAX_ENTRY_BYTES` | `--kv-disk-cache-max-entry-bytes` | 2 GiB | > 0; invalid ⇒ tier disabled |
| `retention_minutes` | `MACPROVIDER_KV_DISK_CACHE_RETENTION_MINUTES` | `--kv-disk-cache-retention-minutes` | 60 | > 0; **cleanup deadline only — does NOT extend reuse eligibility, which is fixed at the hot-tier TTL (default 900 s) and is not tunable here**; invalid ⇒ tier disabled |
| `staging_max_bytes` | `MACPROVIDER_KV_DISK_CACHE_STAGING_MAX_BYTES` | `--kv-disk-cache-staging-max-bytes` | 256 MiB | ≤ 256 MiB hard (FR-KVP9); invalid ⇒ tier disabled |
| `write_staging_max_bytes` | `MACPROVIDER_KV_DISK_CACHE_WRITE_STAGING_MAX_BYTES` | `--kv-disk-cache-write-staging-max-bytes` | 256 MiB | ≤ 1 GiB hard (FR-KVP3); invalid ⇒ tier disabled |
| `min_free_bytes` | `MACPROVIDER_KV_DISK_CACHE_MIN_FREE_BYTES` | `--kv-disk-cache-min-free-bytes` | 8 GiB | ≥ 1 GiB; invalid ⇒ tier disabled |
| `promotion_max_seconds` | `MACPROVIDER_KV_DISK_CACHE_PROMOTION_MAX_S` | `--kv-disk-cache-promotion-max-s` | 5 | > 0; invalid ⇒ tier disabled |
| `shutdown_drain_seconds` | `MACPROVIDER_KV_DISK_CACHE_SHUTDOWN_DRAIN_S` | `--kv-disk-cache-shutdown-drain-s` | 5 | ≥ 0; invalid ⇒ tier disabled |

Rollout gates:

- **Default off.** Enabling with a missing/non-functional purge primitive
  MUST fail closed (tier stays off, error logged).
- **Synthetic-key gate (v0.1 normative).** The tier persists and promotes
  **only** keys in the reserved synthetic sub-namespace: canonical key
  bytes with prefix `conv:kvs-synth:` **and** ingested via the direct-HTTP
  operator path. Both conditions are required: coordinator-derived buyer
  keys can never match the sub-namespace (their `conv:` suffix is base64url
  HMAC output, which cannot contain `:`), and relay/Tier-2 ingest never
  persists regardless of key shape (defense in depth against a buyer
  crafting the prefix on a non-gateway path). All other traffic uses the
  hot tier exactly as today. This satisfies the shipped
  `validConversationKey` rule (synthetic keys are valid `conv:` keys) and
  makes the §6 gates runnable under the default configuration.
- **Enable-time notice.** On enable, log one plain-language INFO line:
  directory, caps, **reuse-eligibility TTL (the hot-tier value)**,
  retention (labeled cleanup-only), synthetic-gate state, and the purge
  command name; plus the FR-KVP7 free-space headroom check.
- Disabling stops reads and writes but does not delete entries;
  purge/status remain available (FR-KVP7/8), and the notice points to
  them.

### FR-KVP12 — telemetry, inspection, and probe boundary (SPEC-037-R012)

- **Closed reason-code enum (exhaustive, normative):**
  read/promotion phase — `disk_hit`, `disk_promote_rejected`,
  `disk_miss_absent`, `disk_miss_envelope`, `disk_miss_corrupt`,
  `disk_miss_expired`, `disk_miss_tombstoned`, `disk_miss_io`,
  `disk_miss_busy`, `disk_miss_budget`, `disk_miss_identity_unavailable`;
  write phase — `disk_write_committed`, `disk_write_skipped`;
  lifecycle — `disk_evict_quota`, `disk_evict_retention`;
  control plane — `disk_store_quarantined`, `purge_ok`, `purge_failed`.
  §5 maps every condition to exactly one code per phase. `disk_miss_absent`
  (no committed entry) is aggregated, not per-request logged.
- Events use the existing `conv_cache`-style structured stderr logging,
  keyed by the truncated key hash already used by the hot tier — never raw
  keys, raw index values, or token content. Dormancy and repeated
  `disk_miss_io` events MUST be rate-limited/aggregated (no
  `idle_prewarm_skipped`-class log storms).
- **Promotion instrumentation (stop-condition decidability):** every
  `disk_hit` records restore bytes read, decrypt+materialize wall-time
  (ms), and peak staging bytes; every `disk_write_committed` records
  serialized bytes and write wall-time, so the §6 gates (including
  write-path overhead) are evaluable from shipped telemetry.
- **Inspection surface:** a read-only control-socket command and
  `macprovider-cli` subcommand report, per namespace: current bytes and
  entry count vs caps, free-space headroom, key epoch, tombstone count,
  the reuse-eligibility TTL, and cumulative counters per reason code. No
  raw keys.
- Telemetry is provider-local observability only: it MUST NOT feed
  billing, routing, settlement, or sanctions, and MUST NOT create a new
  cross-account prefix oracle (SPEC-024 FR-CI9/FR-CI10 hold unchanged).
- SPEC-032 OPoI probes bypass the cold tier entirely in v0.1. A cache
  restore failure is cache-health telemetry, never model-drift or fraud
  evidence.

### FR-KVP13 — KVS gates, production fence, stop condition (SPEC-037-R013)

The §6 gates, their production fence, and the Approach-A stop condition are
normative conformance obligations: the tier MUST NOT graduate past
synthetic-key experiments (FR-KVP11 gate) unless KVS-01..03 pass as
specified, and the stop condition MUST be executed as written when it
trips.

## 5. Outcome tables

Read/promotion phase — every row resolves to miss (fresh prefill, correct
output, `cached_prompt_tokens` per shipped rules — 0 unless the hot tier
independently hits), with exactly one reason code:

| # | Condition | Reason code |
|---|---|---|
| 1 | No committed entry for the index | `disk_miss_absent` |
| 2 | `model_sha256` differs (same model ID/alias/family) | `disk_miss_envelope` |
| 3 | Model ID or catalog revision differs | `disk_miss_envelope` |
| 4 | Tokenizer identity, tokenizer configuration hash, or chat-template hash differs | `disk_miss_envelope` |
| 5 | `kvBits`, group size, quantization mode, or cache quantization policy differs | `disk_miss_envelope` |
| 6 | Cache class or layer count/shape/dtype/layout version differs from current runtime | `disk_miss_envelope` |
| 7 | Persisted cache class since removed from the serialization allowlist | `disk_miss_envelope` |
| 8 | Serialization ABI epoch, pinned `mlx-swift-lm` revision, or MLX version differs | `disk_miss_envelope` |
| 9 | Manifest schema ID or payload codec ID unknown | `disk_miss_envelope` |
| 10 | Namespace or key-epoch mismatch (incl. file copied across namespaces/epochs) | `disk_miss_envelope` |
| 11 | HMAC index does not recompute from the presented canonical key bytes | `disk_miss_envelope` |
| 12 | Decode path class is not ordinary decode | `disk_miss_envelope` |
| 13 | Token count, generation, commit sequence, chunk table, or lengths internally inconsistent | `disk_miss_envelope` |
| 14 | `creation_time` in the future | `disk_miss_envelope` |
| 15 | Eligibility deadline passed | `disk_miss_expired` |
| 16 | AEAD tag, blob SHA-256, or length mismatch; truncated/oversized/reordered/duplicated chunk | `disk_miss_corrupt` |
| 17 | No committed manifest (crash between blob write and manifest publish) | `disk_miss_corrupt` |
| 18 | Malicious/oversized shape or length metadata (§5a bounds, pre-allocation) | `disk_miss_corrupt` |
| 19 | Stamped purge generation below live high-watermark (incl. backup/snapshot reintroduction, racing writer) | `disk_miss_tombstoned` |
| 20 | Entry DEK absent/destroyed | `disk_miss_tombstoned` |
| 21 | Read-side I/O error; promotion deadline exceeded; Keychain unavailable (pre-unlock/entitlement); clock-rollback dormancy | `disk_miss_io` |
| 22 | Concurrent promotion in flight | `disk_miss_busy` |
| 23 | Declared decoded size exceeds the promotion staging ceiling | `disk_miss_budget` |
| 24 | Live identity input unavailable in current process | `disk_miss_identity_unavailable` |
| 25 | Promoted layers fail hot-tier predicate (LCP < 32, nothing-new, non-exact trim) | `disk_promote_rejected` + shipped reason |

Write phase: successful durable publication → `disk_write_committed`; any
write-side failure or refusal (identity unavailable, allowlist, geometry
over budget, quota/floor, I/O, disk-full, read-only FS, fence lost at
publication, snapshot displaced) → `disk_write_skipped` with a detail
reason. Control plane: malformed namespace metadata / rotation journal /
tombstones, or unsafe ownership/permissions → `disk_store_quarantined`
(namespace or index dormant, fail closed); purge outcomes → `purge_ok` /
`purge_failed`.

## 5a. Format v1 normative encoding

- **Manifest** (`manifest.json`): UTF-8 JSON, canonicalized per RFC 8785
  (JCS) for hashing/AAD; maximum 64 KiB (`fstat` before read); duplicate
  keys and unknown fields rejected; parsed with §5a bounds before any
  dependent allocation. Fields (types): schema/codec IDs (strings);
  namespace ID (string); key epoch, generation, commit sequence, purge
  generation, token count, chunk count (non-negative integers within
  JSON-safe range); creation time and eligibility deadline (integer Unix
  seconds UTC); model/tokenizer/catalog identities (strings ≤ 1 KiB);
  hashes (lowercase base16); layer records (class ID string, layer index,
  ndim ≤ 8, dims, dtype enum); chunk table (per chunk: ordinal, ciphertext
  length, 96-bit nonce as base16); blob total length; blob SHA-256.
- **Bounds:** ≤ 512 layers; ndim ≤ 8; each dim ≤ 2^32; chunk count ≤ 4096;
  per-chunk ciphertext ≤ 64 MiB; strings ≤ 1 KiB. Violations →
  `disk_miss_corrupt` before allocation.
- **AAD:** the JCS canonical bytes of the complete manifest object, plus
  the 4-byte big-endian chunk ordinal appended, form each chunk's AEAD
  associated data. The manifest contains no secret and no AEAD output of
  itself; any manifest mutation invalidates every chunk tag.
- **Blob** (`gen-<N>.blob`): concatenated chunk frames, each
  `"KVS1"(4B) ‖ u32-LE ordinal ‖ u32-LE ciphertext-length ‖ nonce(12B) ‖
  ciphertext ‖ GCM tag(16B)`; ordinals contiguous from 0 and matching the
  manifest chunk table exactly; blob SHA-256 in the manifest covers the
  whole file.
- **Payload codec** (`kvsurv-codec-v1`, the decrypted concatenated
  plaintext): token array (i32 LE) followed by per-layer records
  `{class ID, layer index u32, ndim u8, dims u64 LE, dtype enum (f16=1,
  bf16=2, f32=3, i32=4, u32=5), row-major contiguous LE tensor bytes}` for
  each key/value tensor of the layer, in layer order.
- **Serialization allowlist (v1):** exactly `KVCacheSimple` (the pinned
  `mlx-swift-lm` standard cache class). Extending the allowlist is a
  codec-affecting change (new codec ID or ABI-epoch bump with fixtures).
- Temp files are created `O_EXCL` in the same directory as their
  destination (rename atomicity); tombstones, usage journal, rotation
  journal, and namespace metadata use the same fsync + atomic-rename
  discipline.

## 6. KVS gates, production fence, and the Approach-A stop condition

**Production fence (normative).** KVS-01/02/03 kill-and-relaunch cycles
MUST run on a non-production host or inside an announced maintenance
window; they MUST NOT be executed against the live single-provider
production pool (the 2026-07-10 outage class). All gate traffic uses
synthetic keys in the reserved `conv:kvs-synth:` sub-namespace over the
direct-HTTP ingest path (runnable under the default FR-KVP11 gate).

**Harness (normative).** Use the merged `test/e2e/coldwarm-ttft/` harness
(`run-coldwarm.sh --build-matrix`); do not build a parallel harness. The
harness uses `disk_write_committed` as its persist-before-kill barrier.
Every run records: regime label, prompt/input hashes, model ID/hash,
catalog revision, `kvBits`, format IDs, hit/miss reason, full prompt
tokens, cached prompt tokens, TTFT, total latency, disk bytes
read/written, peak staging RSS, commit-latency delta (write-path
overhead), and correctness outcome.

### KVS-01 — restart survival on an 8k prefix (primary gate)

Persist (await `disk_write_committed`) → kill provider → relaunch exact
build/model → matching suffix request within the eligibility window. Arms:
restored (disk hit), in-RAM warm repeat, clean cold restart
(disk-disabled), and disk-enabled-but-miss. **Protocol:** minimum 30 cycles
per arm, interleaved (paired warm control per restored cycle); percentiles
nearest-rank; no outlier exclusion; record host, build, and model metadata
per run. Correctness gates: multi-turn semantic fixture passes; exact
expected LCP reported in `cached_prompt_tokens`; `prompt_tokens` = full
incoming length; all layers trim exactly; a corrupted-block variant yields
miss with correct output. **Performance gates (acceptance hypotheses):**
restored p50 ≤ `max(1.25 × warm p50, warm p50 + 1 s)`; restored p95 ≤
`max(1.5 × warm p95, warm p95 + 2 s)`; once a usable cold control exists,
≥ 30% p95 TTFT reduction vs that control; and write-path overhead
(commit-latency delta with the tier enabled) p95 ≤ 250 ms at the 8k class.
**Scope honesty:** v0.1 gates validate the 8k class under the default
budgets; the memo's highest-value 32k–64k workloads exceed the default
write/promotion budgets and are explicitly deferred to KVS-04-class
evidence with raised caps — recorded in the gate's decision-log entry
along with the single-conversation-restore limitation (no thundering-herd
measurement).

### KVS-02 / KVS-03 — invalidation gates

Warm-swap same family → deterministic miss with explicit reason code;
exact-hash change under a tempting alias → zero old-generation hits,
fence/invalidation recorded, no stale payload read into model memory.
Repeat across tokenizer, `kvBits`, ABI-epoch/pinned-revision,
truncated-manifest, and per-envelope-field mutation variants.

### Stop condition (normative)

If KVS-01 cannot meet the warm-relative gate **without replacing the
current per-conversation KV layout with a shared paged allocator** — e.g.
tensor reconstruction dominates TTFT (decidable from FR-KVP12
instrumentation), the format forces full-copy materialization, RAM peaks
are unsafe, or `mlx-swift-lm` cannot restore the shipped cache classes
reliably — then Approach A PAUSES: no further persistence engineering;
record the finding and the Approach C / RESEARCH_232 paged-layout
sequencing decision as a `beta/DECISION_CRITERIA.md` entry naming the
failed gate, the measured numbers, and the chosen sequencing. The codec
boundary exists so a later paged layout is a **new codec version**, never
a reinterpretation of v1 blobs.

KVS-04 (24-hour budget soak) and KVS-05 (prewarm composition) are later
milestone gates (RESEARCH_233 §10), not v0.1 acceptance.

## 7. Acceptance criteria (fixtures)

All are required tests in `phase3-binary/Tests/macprovider-cliTests/`:

- **AC-1 round trip + key equivalence:** snapshot → serialize →
  deserialize → envelope-validate → promote → exact LCP/trim reuse
  produces identical layer state and identical `cached_prompt_tokens` /
  `prompt_tokens` accounting as a same-process hit at the same LCP;
  composed and decomposed Unicode forms of the same key canonicalize to
  one index (positive equivalence); HKDF derivation matches the
  conformance vector.
- **AC-2 outcome matrix:** every §5 read-phase row exercised, including a
  mutation fixture for **each individual authenticated envelope field**,
  chunk reorder/truncation/duplication/splice variants, and wrong-epoch /
  cross-namespace copies; each yields exactly its mapped reason code and a
  fresh correct result; no partial reuse.
- **AC-3 crash consistency:** kill injected at each FR-KVP3 ordering
  boundary and each FR-KVP6 rotation-journal phase → recovery (at tier
  activation) sees old generation, complete new generation, or clean miss;
  never a partial generation; open rotation journal drives forward; orphan
  bytes swept and accounted; a writer paused after its mutation-lane check
  cannot be interleaved by purge (lane exclusivity fixture).
- **AC-4 purge/fence:** DEK-destruction ordering observed (index
  unrecoverable from restored files after step 2); kill between each purge
  step → recovery completes the purge before reads; **whole-namespace
  rollback fixture**: restore the entire cache directory from a pre-purge
  copy → entry ineligible (DEK gone, fence holds); purge → re-cache →
  tombstone compaction → eviction → second purge → backup restoration →
  still fenced (high-watermark survives); purge-all with live hot entries,
  in-flight leases, and queued snapshots → all invalidated before success;
  purge at full quota succeeds (metadata reserve); `purge_failed` on
  induced Keychain error leaves the fence closed; purge works with
  `enabled=false`; success never reported before durability.
- **AC-5 namespace isolation and locking:** entry copied into another
  namespace fails closed; quota eviction in namespace A never touches
  namespace B; a second process contending the lock stays dormant, retries
  with backoff, and activates (with full recovery) once the first exits —
  no serve-loop impact meanwhile.
- **AC-6 budgets:** promotion staging ≤ ceiling on a large entry;
  promotion deadline abandons cleanly; concurrent promotion →
  `disk_miss_busy`; oversized decoded size → `disk_miss_budget`;
  write-side geometry check skips before copying; pending-snapshot
  displacement (newer commit supersedes unstarted older); quota
  reservation, metadata reserve, free-space floor, and per-entry cap each
  enforce.
- **AC-7 contract non-drift:** tier-enabled vs disabled produce identical
  response/receipt schemas, field sets, and computation rules in all
  cases. In a controlled sequence with no restart and no hot-tier
  eviction, under greedy (temperature-0) decoding, bodies are
  byte-identical. Where the cold tier legitimately retains residency the
  hot tier lost (restart, or intra-epoch LRU eviction), the only permitted
  difference is hit availability: positive `cached_prompt_tokens` (and
  derived fields such as `kvCacheBytesReused`) by the unchanged LCP rule.
  No new fields either way.
- **AC-8 inherited traps + spec-decode exclusion:** tokenizer
  non-canonicity, full-prompt accounting, and `cache_offset` priming
  fixtures pass against promoted (not just resident) cache state; a
  speculative-decode-routed request on each endpoint acquires no lease,
  triggers no promotion, commits nothing, and leaves no busy key.
- **AC-9 config and rollout gates:** default-off; enable without purge
  primitive fails closed; `allow_buyer_keys=true` rejected (tier
  disabled, error names preconditions); synthetic gate admits
  `conv:kvs-synth:` keys on direct ingest and refuses (a) non-synthetic
  `conv:` keys on any path and (b) synthetic-shaped keys arriving via
  relay/Tier-2; triple-source precedence including CLI flags; tilde
  expansion; each invalid-value rule; enable-time notice (with
  eligibility TTL) and headroom check; snapshot-at-commit identity
  (mutating the hot entry or warm-swapping after commit does not alter
  the persisted bytes or recorded identity).

## 8. Sequencing with RESEARCH_232 / SPEC-038

SPEC-037's IMPL serializes the **current** contiguous per-conversation
layer state and lands **first**; SPEC-038 (continuous batching) rebases
onto it and registers as a consumer of `kv-cache-persistence` when it
lands. This spec MUST NOT introduce paged blocks, copy-on-write sharing,
or a new attention allocator. **Any** cache-class or layout change that
breaks v1 round-trip compatibility — paged or not — requires a new payload
codec ID plus an ABI-epoch bump, and re-running the KVS gates under the
new layout before it can persist; v1 blobs are invalidated by the epoch,
never migrated or reinterpreted. SPEC-038 MUST either retain v1 round-trip
support for unchanged layouts or keep its layout flag-isolated from
persistence.

## 9. No-go list (inherited from RESEARCH_233 §9.3)

oMLX as engine; d-inference inspection (clean-room absolute);
multi-provider sidecar; global dedup; plaintext token files as production
cache; reuse by family/alias without exact hash; best-effort partial-layer
reuse; counting startup rehydrate as eliminated prefill; raising RAM
budgets because disk exists; claiming physical erasure at TTL; shipping
without purge + tombstones; adding fields to LOCKED SPEC-015 v0.4.2;
treating oMLX marketing numbers as macprovider evidence.

## 10. Open questions carried (non-blocking for v0.1)

Coordinator purge-propagation design (precondition for ever activating
buyer-key persistence, FR-KVP11); per-SSD-class disk budgets; q4-KV
quality gates and the active-`kvBits` question for the live Qwen model
(memo Q6/Q7 — affects the per-entry cap and the 32k–64k deferral);
concurrent post-restart promotion policy beyond one-at-a-time;
copy-on-write snapshot handles to shrink the synchronous copy cost
(FR-KVP3 bounds it by budget in v0.1); buyer-facing provenance (deferred
to a future SPEC-015 v0.5 question). Tracked in RESEARCH_233 §11; none may
weaken a MUST above.
