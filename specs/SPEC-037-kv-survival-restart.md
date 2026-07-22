# SPEC-037 — KV survival across provider restarts (encrypted provider-local disk tier)

Version: v0.1.0
Status: draft (normative design; IMPL lands behind a disabled-by-default flag)
Owner: provider runtime / prefix-cache persistence
Decision source: `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` (landed decision memo, commit `d6881b14`)

## 1. Purpose and scope

Give the provider's shipped in-RAM prefix cache (`ConversationCache`) a cold
tier on local disk so a reusable conversation prefix survives provider process
loss — deploy, crash, supervisor relaunch, and host reboot — and cuts the
restart-driven re-prefill contribution to the buyer-TTFT tail measured in
RESEARCH_234 (p95 16.8 s, p99 51.4 s, 4.2% of requests over 20 s).

This is a **pure provider-local performance optimization**. It changes KV
**residency only** — never cache eligibility, billing arithmetic, receipts,
routing, or any buyer-visible semantics.

In scope for v0.1:

- An encrypted, provider-namespaced disk tier behind the existing
  `ConversationCache` actor (RESEARCH_233 **Approach A**), using versioned
  opaque per-conversation serialization, append-only generation blobs, and
  atomic manifests.
- The strict exact-match safety envelope that gates any disk hit.
- Per-provider namespace, quota, and eviction model.
- A provider-side conversation-key **purge primitive** with anti-resurrection
  tombstones (ship-blocker: the disk tier MUST NOT be enabled without it).
- Bounded streaming promotion from disk into the current RAM cache.
- The KVS-01 benchmark gate and the explicit stop condition for Approach A.

Out of scope (recorded, not silently dropped):

- Any change to LOCKED SPEC-015 v0.4.2 receipts. Buyer-facing cache
  provenance, if ever needed, is a named future SPEC-015 v0.5 question.
- Any change to SPEC-024 `cached_prompt_tokens` wire/mirror semantics or to
  SPEC-005 billing arithmetic/eligibility.
- A shared paged-KV allocator, copy-on-write prefix sharing, or any
  batch-aware layout (RESEARCH_232 / SPEC-038 territory; see §8).
- Cross-conversation or cross-provider block sharing and global
  content-addressed dedup (rejected — see §9 no-go list).
- External sidecar processes; oMLX as inference engine (rejected).
- Speculative-decoding cache state (excluded from the format and the path).
- Coordinator-propagated purge (`DELETE /v1/sticky` → provider push). v0.1
  ships the provider-local primitive it would invoke; the propagation channel
  is future work and MUST NOT be presented as shipped buyer purge.

## 2. Dependencies and authority

- **SPEC-024 v0.2.1 §11–§16** — provider-local cache isolation baseline
  (FR-CI1..FR-CI10a). This spec preserves those invariants and extends their
  blast-radius analysis to a restart-durable store; it does not re-own them.
- **SPEC-005 v0.6** — billing arithmetic/eligibility authority. Untouched.
- **SPEC-015 v0.4.2** — LOCKED receipts. Untouched.
- **SPEC-032** — OPoI probes are observability-only and bypass this tier.
- **SPEC-001** — provider binary surface (config, control socket, serve loop).

SPEC-037 owns the new authority domain `kv-cache-persistence`: the on-disk
format, its validation/invalidation rules, namespace/quota/purge lifecycle,
and the persistence benchmark gates.

## 3. Terms

| Term | Meaning |
|---|---|
| Hot tier | The shipped in-RAM `ConversationCache` entries (`[KVCache]` layers). |
| Cold tier | The on-disk store this spec defines. |
| Entry | All persisted state for one trimmed `conversation_key` in one namespace. |
| Generation | One immutable committed serialization of an entry (`gen-<N>`). |
| Manifest | The atomically-replaced per-entry metadata document naming the committed generation. |
| Envelope | The authenticated metadata (identity + geometry + lifecycle fields) a hit must exactly match. |
| Namespace | The per-provider-identity subtree holding entries, quota, and keys. |
| Key epoch | Integer version of the namespace's AEAD/index key material; bumping it crypto-shreds all prior ciphertext. |
| Tombstone | Durable per-key purge record that makes prior generations permanently ineligible. |
| Promotion | Streaming a validated cold entry into hot-tier `[KVCache]` layers. |

## 4. Normative requirements

Requirement IDs `SPEC-037-R001`..`R012` are the conformance units; FR labels
below are the prose anchors.

### FR-KVP1 — residency only, no observable-contract change (SPEC-037-R001)

The cold tier MUST NOT change: the SPEC-024 §3 `cached_prompt_tokens` wire
field or §8 buyer mirror; SPEC-005 billing inputs or eligibility; SPEC-015
v0.4.2 receipt fields; SPEC-004 routing behavior; or any buyer-visible
response field. A disk-promoted hit reports `cached_prompt_tokens` by exactly
the same rule as a RAM hit (the reused exact LCP). `prompt_tokens` remains the
full incoming prompt length. A provider with the cold tier enabled MUST be
wire-indistinguishable from one without it, TTFT aside.

### FR-KVP2 — hot-tier semantics preserved exactly (SPEC-037-R002)

The shipped reuse mechanism is unchanged and remains the only reuse mechanism:

1. the trimmed `conversation_key` selects exactly one candidate (FR-CI1);
2. reuse is the exact token-level LCP, `LCP >= 32` and `LCP <` incoming
   prompt length (FR-CI2);
3. every KV layer must be trimmable and every trim must remove exactly the
   requested count — any shortfall is a miss;
4. the incoming request still reports its full prompt length; and
5. speculative decoding stays entirely outside this cache path.

Promotion MUST materialize a cold entry into the same in-memory representation
the hot tier commits today, then let the existing `begin()` predicate decide
hit/miss. The cold tier MUST NOT implement a second, divergent reuse predicate.
The three inherited traps from commit `84e50c92` (tokenizer non-canonicity →
token-LCP only; full-prompt accounting; `cache_offset` priming) are
persistence-format test fixtures (§7).

### FR-KVP3 — entry format: versioned opaque blobs, atomic manifests (SPEC-037-R003)

Format v1 (`kvsurv1`):

- Entry layout: `<namespace>/<index>/manifest.json` plus one or more
  immutable generation blobs `<namespace>/<index>/gen-<N>.blob`, where
  `<index>` is the HMAC index of FR-KVP6 — never the raw `conversation_key`.
- A generation blob is append-only while being written and immutable once its
  manifest commits. The payload (encrypted per FR-KVP6) serializes: the
  canonical token sequence needed for LCP, and each KV layer's state arrays
  plus per-layer metadata, as an **opaque versioned record** of the current
  per-conversation layer state. Only cache classes on an explicit
  serialization allowlist may be persisted; an entry whose layers include any
  other class MUST NOT be written.
- Commit protocol: write blob → `fsync` blob → write `manifest.json.tmp` →
  `fsync` → atomic `rename(2)` over `manifest.json` → `fsync` directory. A
  crash at any point yields either the previous committed generation or no
  committed generation — never a partially-visible one. A manifest naming a
  blob whose length, checksum, or AEAD tag does not verify exactly is treated
  as absent (miss) and quarantined for deletion.
- Writes occur only after a successful request commit (the same point the hot
  tier commits), asynchronously off the request path; write failure is
  logged and dropped (the hot tier is unaffected).
- The manifest carries the full envelope (FR-KVP4), the generation number,
  blob length, blob SHA-256, and AEAD parameters.

### FR-KVP4 — envelope: strict exact-match identity set (SPEC-037-R004)

Every manifest MUST record, and every load MUST validate by exact equality
before any payload byte is deserialized:

1. format magic and schema version (`kvsurv1`);
2. provider namespace ID and key epoch;
3. HMAC index of the `conversation_key` (recomputed and compared);
4. model ID, exact `model_sha256` (canonical artifact hash), and catalog
   revision;
5. tokenizer identity and chat-template hash;
6. MLX / `mlx-swift-lm` compatibility epoch pinned by the build;
7. cache implementation class and layer count;
8. per-layer tensor shapes, dtypes, and layout version;
9. `kvBits`, quantization group size, and quantization mode;
10. token count and generation number;
11. creation time and eligibility deadline (TTL);
12. payload length, payload SHA-256, and AEAD authentication data;
13. decode path class (ordinary decode only; speculative state MUST NOT be
    written).

Deserialization success is NOT reuse eligibility: the envelope decides first.
Model *family*, filename, or catalog alias similarity is never sufficient — a
warm-swap to a same-family model is a miss unless every identity above
matches.

### FR-KVP5 — fail safe to miss (SPEC-037-R005)

Any of the following resolves to a **miss with correct fresh output**, never a
partial or best-effort reuse, never a crash of the serve loop, and never an
escalation into drift/fraud/sanction signals: envelope mismatch on any
FR-KVP4 field; expiry; checksum or AEAD failure; truncated, oversized, or
malformed blob or manifest; incomplete commit; unsupported cache class;
non-exact trim after promotion; I/O error; disk-full; read-only filesystem;
oversized or malicious length/shape metadata (bounds MUST be validated before
allocation); wrong key epoch; tombstoned key. Each miss records a closed-set
reason code (§6 telemetry). Corrupt artifacts are quarantined/deleted
asynchronously. A cold-tier failure MUST NOT degrade the request beyond the
cost of a normal miss.

### FR-KVP6 — encryption, index hiding, key lifecycle (SPEC-037-R006)

- All payload bytes at rest are encrypted with an AEAD cipher (v1:
  AES-256-GCM) whose associated data binds the envelope identity fields
  (schema version, namespace, key epoch, index, generation).
- Entry directory names are `base16(HMAC-SHA256(index_key, trimmed
  conversation_key))` — the raw key never appears in any path, log, or
  manifest field.
- Per-namespace master key material lives in the macOS Keychain following the
  shipped `KeychainProviderCredentialStore` SecItem pattern
  (`kSecClassGenericPassword`, non-synchronizable); AEAD and index keys are
  derived (HKDF-SHA256) from the master per key epoch. Key material MUST
  never be written to the cache directory.
- Directory/file discipline: namespace directories `0700`, files `0600`,
  `O_NOFOLLOW` on open, owner/euid verified — the control-socket hardening
  pattern.
- Bumping the key epoch (purge-all, provider removal) crypto-shreds every
  prior generation: old-epoch entries are ineligible (FR-KVP5) regardless of
  physical presence, and the old key material is deleted from the Keychain.
- Encryption is a necessary control, not a secrecy claim: it does not protect
  against a compromised live provider process, and the spec makes no physical
  erasure claim at TTL (FR-KVP10).

### FR-KVP7 — per-provider namespace and quota (SPEC-037-R007)

- The cold tier root contains one namespace per provider identity, keyed by a
  digest of the stable provider ID; the namespace records its provider ID and
  key epoch in namespace metadata. A provider process MUST only open its own
  namespace.
- Cross-namespace reads, writes, eviction, or key derivation are forbidden. A
  raw entry copied between namespace directories MUST fail closed (namespace
  is bound into the HMAC index and AEAD associated data).
- Quotas are enforced **per namespace**: total bytes (default 16 GiB —
  operational guardrail, not a protocol value), entry count (default 64), and
  per-entry byte cap (default 2 GiB). Eviction on quota pressure is LRU by
  last-eligible-use within the namespace only. Global content-addressed dedup
  across keys, accounts, or namespaces is forbidden.
- Rationale (SPEC-024 FR-CI8 extension): a shared pool would turn the
  existing in-process capacity channel into a cross-process/cross-provider
  denial vector; per-namespace quotas close it.

### FR-KVP8 — purge primitive and tombstones — ship-blocker (SPEC-037-R008)

- The provider binary MUST expose a local purge primitive **before** the disk
  tier can be enabled: a control-socket command (and matching
  `macprovider-cli` subcommand) that (a) purges one conversation key —
  addressed by raw key, which the CLI HMAC-indexes — or (b) purges the whole
  namespace via key-epoch bump.
- Single-key purge: delete the entry's generations and manifest, then write a
  durable **tombstone** recording the index and purge time. While a tombstone
  is live, any manifest for that index — including one restored from backup
  or an in-flight write racing the purge — is ineligible and deleted on
  sight. Tombstones persist at least as long as the maximum eligibility
  window of any generation they cover.
- Purge also removes the matching hot-tier entry, and completes (durable
  tombstone) before the command reports success. Success output includes
  counts (entries removed, bytes freed) but never raw keys.
- Motivation (SPEC-024 FR-CI10a): `DELETE /v1/sticky` purges only coordinator
  state; without this primitive a restart-durable provider entry would be
  buyer-unpurgeable. v0.1 ships the primitive; wiring coordinator deletion to
  invoke it remotely is future work (§1 out of scope).

### FR-KVP9 — bounded streaming promotion (SPEC-037-R009)

- Promotion is lazy and on-demand only: triggered by a hot-tier miss for a
  key with a valid cold entry, during request admission for that key. Eager
  whole-store restoration at startup is forbidden.
- Restore staging MUST stay within a fixed ceiling (default 256 MiB) above
  the selected hot-cache state; reads are bounded/streamed (chunked or
  memory-mapped), decrypt-then-materialize per layer, and MUST NOT hold a
  second full copy of the restored tensors once promoted.
- Promoted entries count against the existing hot-tier budgets (200k tokens,
  entry cap); promotion MUST NOT raise any RAM ceiling. At most one
  promotion runs at a time (back-pressure; concurrent candidates fall back to
  miss rather than queueing unboundedly).
- An entry whose promoted layers subsequently fail the FR-KVP2 predicate
  (LCP < 32, non-exact trim, …) is a normal miss; the promotion cost is
  bounded by the staging ceiling and never retried in the same request.

### FR-KVP10 — lifecycle: TTL is an eligibility deadline (SPEC-037-R010)

- Cold entries carry their own eligibility TTL (default 240 minutes,
  configurable), independent of the hot tier's 15-minute TTL. Expiry is
  evaluated at load time (FR-KVP4.11) and by periodic/opportunistic
  compaction; expired or superseded generations are deleted best-effort.
- TTL is a reuse-eligibility deadline, **not** a physical-erasure guarantee;
  documentation and telemetry MUST NOT claim secure deletion at TTL.
  Bounded best-effort deletion comes from compaction, quota eviction, unlink
  on quarantine, and key-epoch destruction.
- Disk LRU/eviction is independent of RAM promotion state; evicting a cold
  entry never touches a live hot entry, and hot-tier eviction never deletes a
  committed cold generation before its own expiry.

### FR-KVP11 — configuration and default-off rollout (SPEC-037-R011)

The tier ships behind `AppConfig` following the `idle_prewarm` triple-source
pattern (YAML `kv_disk_cache:` block, `MACPROVIDER_KV_DISK_CACHE_*` env vars,
CLI overrides): `enabled` (**default `false`**), `directory`, `max_bytes`,
`max_entries`, `max_entry_bytes`, `ttl_minutes`, `staging_max_bytes`.
Enabling the tier without a functioning purge primitive MUST fail closed
(tier stays off, error logged). Disabling the tier stops reads and writes but
does not delete existing entries (operator purges explicitly).

### FR-KVP12 — telemetry and probe boundary (SPEC-037-R012)

- Cold-tier events use the existing `conv_cache`-style structured stderr
  logging with a closed reason set (e.g. `disk_hit`, `disk_miss_envelope`,
  `disk_miss_corrupt`, `disk_miss_expired`, `disk_miss_tombstoned`,
  `disk_write_skipped`, `disk_evict_quota`, `purge_ok`), keyed by the
  truncated key hash already used by the hot tier — never raw keys, paths
  with raw keys, or token content.
- Telemetry is provider-local observability only: it MUST NOT feed billing,
  routing, settlement, or sanctions, and MUST NOT create a new cross-account
  prefix oracle (SPEC-024 FR-CI9/FR-CI10 hold unchanged).
- SPEC-032 OPoI probes bypass the cold tier entirely in v0.1. A cache restore
  failure is cache-health telemetry, never model-drift or fraud evidence.

## 5. Not-a-hit table

Every row resolves to miss (fresh prefill, correct output,
`cached_prompt_tokens` per shipped rules — 0 unless the hot tier
independently hits):

| # | Condition | Reason code |
|---|---|---|
| 1 | `model_sha256` differs (same model ID/alias/family) | `disk_miss_envelope` |
| 2 | Model ID or catalog revision differs | `disk_miss_envelope` |
| 3 | Tokenizer or chat-template hash differs | `disk_miss_envelope` |
| 4 | `kvBits`, group size, or quantization mode differs | `disk_miss_envelope` |
| 5 | Cache class, layer count, tensor shape, dtype, or layout version differs | `disk_miss_envelope` |
| 6 | `mlx-swift-lm` compatibility epoch differs | `disk_miss_envelope` |
| 7 | Schema version / format magic unknown | `disk_miss_envelope` |
| 8 | Namespace or key-epoch mismatch (incl. file copied across namespaces) | `disk_miss_envelope` |
| 9 | HMAC index does not recompute from the presented key | `disk_miss_envelope` |
| 10 | Eligibility TTL passed | `disk_miss_expired` |
| 11 | AEAD tag, checksum, or length mismatch; truncated/oversized blob | `disk_miss_corrupt` |
| 12 | No committed manifest (crash between blob append and manifest rename) | `disk_miss_corrupt` |
| 13 | Malicious/oversized shape or length metadata | `disk_miss_corrupt` |
| 14 | Live tombstone for the index (incl. pre-purge manifest replay) | `disk_miss_tombstoned` |
| 15 | Speculative-decode state encountered | `disk_miss_envelope` |
| 16 | Promoted layers fail LCP/trim predicate (LCP < 32, non-exact trim, nothing-new) | shipped hot-tier reasons |
| 17 | I/O error, disk-full, read-only FS, staging ceiling exceeded, promotion busy | `disk_miss_io` / `disk_miss_busy` |

## 6. KVS gates and the Approach-A stop condition

### KVS-01 — restart survival on an 8k prefix (primary gate)

Persist → kill provider → relaunch exact build/model → matching suffix
request. Controls: in-RAM warm repeat, clean cold restart, disk-disabled
provider. Correctness gates: multi-turn semantic fixture passes; exact
expected LCP reported in `cached_prompt_tokens`; `prompt_tokens` = full
incoming length; all layers trim exactly; corrupted-block variant yields miss
with correct output. Performance gate (acceptance hypothesis, normalized):
restored p50 ≤ `max(1.25 × warm p50, warm p50 + 1 s)`; restored p95 ≤
`max(1.5 × warm p95, warm p95 + 2 s)`; once a usable cold control exists,
≥ 30% p95 TTFT reduction vs that control.

### KVS-02 / KVS-03 — invalidation gates

Warm-swap same family → deterministic miss with explicit reason; exact-hash
change with tempting alias → zero old-generation hits, tombstone/invalidation
recorded, no stale payload read into model memory. Repeat across tokenizer,
`kvBits`, layout-epoch, and truncated-manifest variants.

### Stop condition (normative)

If KVS-01 cannot meet the warm-relative gate **without replacing the current
per-conversation KV layout with a shared paged allocator** — e.g. tensor
reconstruction dominates TTFT, the format forces full-copy materialization,
RAM peaks are unsafe, or `mlx-swift-lm` cannot restore the shipped cache
classes reliably — then Approach A PAUSES: no further persistence
engineering; record the finding and escalate the Approach C / RESEARCH_232
paged-layout sequencing decision in `beta/DECISION_CRITERIA.md`. The v1
format's codec-version boundary exists so a later paged layout is a **new
codec version**, never a reinterpretation of v1 blobs.

KVS-04 (24-hour budget soak) and KVS-05 (prewarm composition) are later
milestone gates (RESEARCH_233 §10), not v0.1 acceptance.

## 7. Acceptance criteria (fixtures)

All are required tests in `phase3-binary/Tests/macprovider-cliTests/`:

- **AC-1 round trip:** serialize → deserialize → envelope-validate → promote
  → exact LCP/trim reuse produces identical layer state and identical
  `cached_prompt_tokens` / `prompt_tokens` accounting as a same-process hit.
- **AC-2 not-a-hit matrix:** every §5 row exercised; each yields the mapped
  reason code and a fresh correct result; no partial reuse observed.
- **AC-3 crash consistency:** kill between blob append and manifest rename →
  old generation (or clean miss) only; never a partial generation.
- **AC-4 tombstone/purge:** purge one key → entry gone, tombstone live,
  pre-purge manifest replay refused; purge-all → key-epoch bump, all prior
  entries ineligible, Keychain old-epoch material deleted; hot-tier entry
  also removed; success before durability is a failure.
- **AC-5 namespace isolation:** entry copied into another namespace fails
  closed; quota eviction in namespace A never touches namespace B.
- **AC-6 budget:** promotion staging stays ≤ configured ceiling on a large
  entry; concurrent promotion requests degrade to miss, not queue growth.
- **AC-7 no-receipt-drift:** with tier enabled vs disabled, byte-identical
  wire responses and receipts for identical request sequences (TTFT aside).
- **AC-8 inherited traps:** tokenizer non-canonicity, full-prompt
  accounting, and `cache_offset` priming fixtures pass against promoted
  (not just resident) cache state.
- **AC-9 config:** default-off; enable-without-purge-primitive fails closed;
  triple-source config precedence honored.

## 8. Sequencing with RESEARCH_232 / SPEC-038

SPEC-037's IMPL serializes the **current** contiguous per-conversation layer
state and lands **first**; SPEC-038 (continuous batching) rebases onto it.
This spec MUST NOT introduce paged blocks, copy-on-write sharing, or a new
attention allocator. If batching later adopts paged KV, persistence defines a
new codec version and re-runs the KVS gates under the new layout; v1 blobs
are invalidated by the compatibility epoch, not migrated.

## 9. No-go list (inherited from RESEARCH_233 §9.3)

oMLX as engine; d-inference inspection (clean-room absolute); multi-provider
sidecar; global dedup; plaintext token files as production cache; reuse by
family/alias without exact hash; best-effort partial-layer reuse; counting
startup rehydrate as eliminated prefill; raising RAM budgets because disk
exists; claiming physical erasure at TTL; shipping without purge +
tombstones; adding fields to LOCKED SPEC-015 v0.4.2; treating oMLX marketing
numbers as macprovider evidence.

## 10. Open questions carried (non-blocking for v0.1)

Keychain unattended-supervisor access policy detail; coordinator purge
propagation design; per-SSD-class disk budgets; q4-KV quality gates for the
live Qwen model; buyer-facing provenance (deferred to a future SPEC-015 v0.5
question). Tracked in RESEARCH_233 §11; none may weaken a MUST above.
