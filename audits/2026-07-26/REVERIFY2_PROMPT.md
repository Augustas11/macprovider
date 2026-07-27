# BLIND VERIFY (round 2) — SPEC-037 KV-survival — control-surface + geometry delta

You are an independent auditor. You have NO prior context and no knowledge of any
earlier review. Judge only what the code does.

## Feature

`macprovider-cli` (Swift, `phase3-binary/`) has an encrypted provider-local KV
disk tier BEHIND the in-RAM `ConversationCache`, letting a conversation KV prefix
survive a provider restart. Residency-only (no buyer wire / receipt / billing /
`cached_prompt_tokens` change), default-off, synthetic-key-only. Each on-disk
entry is sealed with a per-entry DEK in the Data-Protection Keychain; destroying
the DEK is the crypto-shred revocation authority. Operators drive it via a control
socket and CLI: `kv-cache purge [--all] [--forget]`, `kv-cache status`, plus
`uninstall`. Key architectural fact: when the disk tier is DISABLED, the serve
process never constructs the store and therefore holds NO namespace flock — a
standalone CLI invocation is free to acquire that lock and operate on disk.

## Scope — audit ONLY this delta

Read `audits/2026-07-26/REVERIFY2_DELTA.diff` (the complete change) and the full
current text of every file it touches, plus the CLI consumers
`KVCacheCommand.swift` (purge/status run methods, the socket-first-then-standalone
pattern, the `status != "unavailable"` guard). The delta:

1. **Disabled-tier socket purge** (`ControlSocket.handleKVCachePurge`): the
   `tier == nil` branch now clears the RAM hot residency and returns
   `status:"unavailable"`/`detail:"disk_tier_disabled"` (for all of all_forget /
   all / single) so the CLI falls through to the standalone disk purge that
   actually shreds disk + Keychain.
2. **Disabled-tier socket status** (`handleKVCacheStatus`): now returns
   `unavailable`/`disk_tier_disabled` so the CLI falls through to standalone
   `tier.status()` (full disk residency).
3. **Uninstall** (`UninstallCommand`): warns instead of silently skipping when the
   KV cleanup target (config/provider_id) is unresolvable.
4. **Commit-time geometry** (`KVConversationColdTierAdapter.liveGeometryTemplate`):
   sequence axis now derived structurally as `max(0, ndim-2)` to match the
   load-time seed, instead of `firstIndex(of: tokenCount)`.

## What to verify (adversarially — try to find a NEW hole the fix introduced)

- **Revocation now actually completes.** With disk tier disabled + a serve
  running, does `kv-cache purge --all --forget` now genuinely delete on-disk
  ciphertext AND destroy the Keychain DEKs? Trace the full path: socket clears RAM
  → returns `unavailable` → CLI `status != "unavailable"` guard → standalone
  `makeTier` acquires the (free) namespace lock → `purgeAllAndForget`. Is there any
  case where the CLI does NOT fall through (e.g. a status string mismatch), or
  where the standalone lock acquisition fails/deadlocks because the serve somehow
  DOES hold it? Confirm the with-serve and without-serve end states are identical.
- **No double-purge / no lost RAM clear.** The serve clears RAM then the standalone
  purges disk — confirm RAM is not left populated and the standalone doesn't error
  on already-clear state.
- **Status honesty.** After the fix, can an operator running a disabled+serving
  tier see real disk residency? Any remaining state where residue is invisible?
- **Uninstall.** Is the new warning correct and does it fire on the right condition?
  Still best-effort (no wrong hard-fail)?
- **Geometry axis.** Is `max(0, ndim-2)` correct for the rank-4
  `[batch, kvHeads, seq, headDim]` KVCacheSimple layout across NON-collision cases
  too (it must not regress the normal path)? Does it now equal the load seed for
  all token counts? Could the structural axis ever be wrong for a legitimately
  supported cache shape in v1 (KVCacheSimple-only)?
- **Residency-only** unaffected by this delta.
- **Test integrity.** Do the rewritten tests assert the CORRECT new contract (RAM
  cleared + `unavailable` + CLI reaches standalone disk shred; identical
  with/without serve), not a tautology? Is the with/without-serve equivalence test
  real?

A clean delta is the expected and acceptable outcome — do not manufacture findings.
Report a numbered list (severity / file:line / defect / failing scenario / fix),
and note explicitly which attacks you tried and could NOT land (that is evidence).
End with exactly one line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
