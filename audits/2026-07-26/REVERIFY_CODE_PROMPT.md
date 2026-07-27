# BLIND RE-VERIFY — SPEC-037 KV-survival IMPL — CODE lane

You are an independent code-correctness auditor. You have NO prior context on
this change and no knowledge of any earlier review. Judge only what the code does.

## Feature under review

`macprovider-cli` (Swift, `phase3-binary/`) has an encrypted provider-local KV
disk tier behind the in-RAM `ConversationCache`, letting a reusable conversation
KV prefix survive a provider restart. Residency-only, default-off,
synthetic-key-only. `KVDiskCacheStore` is an actor; writes are synchronous on the
actor. Promotion reconstructs a live `KVCacheSimple` from validated on-disk bytes.

## Scope — audit ONLY this delta

Read `audits/2026-07-26/REVERIFY_DELTA.diff` and the full current text of every
file it touches. The delta:

1. **Load-time geometry seeding** (`ModelRuntime.seedColdGeometry`,
   `KVConversationColdTierAdapter.seedTemplate`/`liveGeometryTemplate`,
   `captureSnapshot` refactor): at cold-tier attach, a minimal 1-token warmup
   prefill runs on the loaded container, the live per-layer `KVCacheSimple`
   geometry is snapshotted (`KVCacheSerialization.snapshotLayers`), and a template
   keyed by `servedModelID` is seeded so the FIRST post-restart request can
   reconstruct the cache. The sequence axis is derived structurally as `ndim-2`.
2. **Purge/status decoupling** (`ControlSocket`, `ModelRuntime.purgeHotConversation`
   /`purgeAllHotConversations`/`hotConversationStats`).
3. **Uninstall wiring** (`UninstallCommand` → `purgeAllAndForget`).

## What to hunt

- **Seed correctness & equivalence.** Does the load-time seeded geometry EQUAL
  what `captureSnapshot` records for a real multi-token commit for the same model?
  Is the `ndim-2` sequence-axis derivation correct for the rank-4
  `[batch, kvHeads, seq, headDim]` KVCacheSimple layout, and unambiguous for the
  1-token/batch=1 warmup (no axis collision)? Does `seedTemplate` correctly refuse
  to overwrite a template already learned from an in-process commit? If the warmup
  prefill throws / no container / non-KVCacheSimple runtime / MLX-Metal absent, is
  the skip truly best-effort (feature still off, no crash, no partial state)?
- **Delegation correctness.** Do `purgeHotConversation`/`purgeAllHotConversations`
  /`hotConversationStats` correctly reflect the real `ConversationCache` state?
  Off-by-one or wrong count in the reported eviction number? Any nil/optional
  mishandling when no serve cache exists?
- **Handler control flow.** In `ControlSocket`, are the enabled vs disabled
  branches for `purge`/`status` both correct and mutually exclusive? Any path that
  double-purges or returns before responding?
- **Test adequacy.** Do the new tests actually exercise the claimed behavior
  (first-request promotion seeded vs unseeded; wrong-geometry-still-misses;
  disabled-path purge count; uninstall cleanup count→0)? Any test that asserts
  nothing, or is tautological?
- **Regressions** in the touched functions of `ModelRuntime` /
  `KVConversationColdTierAdapter` (the streaming/non-streaming inference path).

Report findings as a numbered list with severity, file:line, defect, failing
scenario, fix. A clean delta is an acceptable verdict. End with exactly one line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
