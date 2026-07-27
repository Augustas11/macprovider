# BLIND RE-VERIFY — SPEC-037 KV-survival IMPL — SECURITY lane

You are an independent security auditor. You have NO prior context on this
change and no knowledge of any earlier review. Judge only what the code does.

## Feature under review

`macprovider-cli` (Swift, `phase3-binary/`) has an encrypted, provider-local KV
disk tier that sits BEHIND the shipped in-RAM `ConversationCache`. It lets a
reusable conversation KV prefix survive a provider restart. Hard invariants:

- **Residency-only.** No change to the buyer wire, receipts, billing, or
  `cached_prompt_tokens`. The tier is a latency optimization, invisible to buyers.
- **Default-off.** The disk tier is only attached when explicitly enabled.
- **Synthetic-key-only (v0.1).** Only entries under the `conv:kvs-synth:` key
  prefix that arrived via direct-HTTP ingest provenance are eligible.
- **Per-entry revocation authority.** Each on-disk entry is sealed with a
  per-entry DEK stored in the Data-Protection Keychain; destroying the DEK is
  the rollback-proof crypto-shred. Namespace is bound into the HMAC index key
  AND the AEAD associated data (JCS-canonical manifest, `blob_sha256` excluded).
- **Promotion validation (FR-KVP4).** On read, `store.read` fully validates the
  on-disk manifest envelope (model hash, epoch, per-layer geometry, AEAD tag)
  before any bytes are promoted into a live cache. A geometry "template" the
  runtime holds is only the EXPECTED shape used to reconstruct the cache; it is
  never a substitute for envelope validation.

## Scope — audit ONLY this delta

Read `audits/2026-07-26/REVERIFY_DELTA.diff` (the complete change) and the full
current text of every file it touches. The delta changes three surfaces:

1. **Load-time geometry seeding** — `ModelRuntime` now seeds a geometry template
   for the cold-tier adapter from the loaded model's live `KVCacheSimple` shape
   at attach time (see `seedColdGeometry`, `KVConversationColdTierAdapter`
   `seedTemplate`/`liveGeometryTemplate`).
2. **Purge/status decoupled from disk-tier enablement** — `ControlSocket`'s
   `kv-cache purge`/`status` handlers now service the in-RAM `ConversationCache`
   even when the disk tier is disabled (`ModelRuntime.purgeHotConversation`
   /`purgeAllHotConversations`/`hotConversationStats`).
3. **Uninstall wiring** — `UninstallCommand` now calls the tier's
   `purgeAllAndForget` before removing product files.

## What to hunt (weighted)

- **Mis-promotion via the seeded template.** Can a seeded/stale geometry template
  EVER cause a wrong or cross-context promotion — wrong model, wrong epoch after
  rotation, wrong namespace, a promotion that skips or weakens envelope
  validation? Trace `seedTemplate` → `promotionRuntime`/expected-geometry →
  `store.read` validation. Confirm a wrong template can only ever produce a MISS,
  never a wrong hit. If the seed path can bypass any FR-KVP4 check, that is CRITICAL.
- **Purge honesty / revocation completeness.** In the disabled path, can `purge`
  report success (`purge_ok`) for state it did not actually clear? Can it report a
  removal count that overstates what was evicted? Does the disabled path ever
  touch or claim to touch disk/Keychain material it has no lock for? Does `status`
  leak anything, or misreport `enabled`? Is there any residue the operator would
  reasonably think was purged but wasn't (state honesty, not just bytes)?
- **Uninstall.** Does a `purgeAllAndForget` failure wrongly block or abort the
  uninstall (availability), or conversely silently leave DEKs/ciphertext behind
  while claiming clean removal? Best-effort must be honest about partial failure.
- **Residency-only regression.** Does any line in this delta touch the buyer wire,
  receipts, billing, or `cached_prompt_tokens`? (A `#if DEBUG` test-only read of
  an existing field is fine.)
- **New concurrency/TOCTOU** introduced by the new `ModelRuntime` delegation
  methods or the ControlSocket wiring.

Report findings as a numbered list; each states severity (CRITICAL/HIGH/MEDIUM/
LOW/INFO), file:line, the concrete defect, a failing scenario, and a fix. Do not
invent findings to appear thorough — a clean delta is an acceptable verdict. End
with exactly one line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
