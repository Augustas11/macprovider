# AUDIT — SPEC-037 IMPL R3 — SECURITY lane

You are the SECURITY audit lane reviewing the IMPLEMENTATION of SPEC-037
before it merges. Repo root: the current working directory (a macprovider
worktree, branch impl/233-kv-survival).

Scope: the full diff `git diff origin/main...HEAD` — 24 files, all in
phase3-binary/ plus test/e2e/coldwarm-ttft/ (kvs-01a harness). New files:
KVDiskCacheFormat/Keys/Store.swift, KVDiskTier.swift,
KVConversationColdTierAdapter.swift, ConversationColdTier.swift,
KVCacheCommand.swift, KVDiskCacheConfig.swift (MacProviderCore), plus
tests. Modified: ConversationCache.swift, ModelRuntime.swift,
ControlSocket.swift, HTTPServer.swift, InferenceRelay.swift,
ChatCompletionRequest.swift, Config.swift, MacProviderCLI.swift.

THE SPEC IS NORMATIVE: specs/SPEC-037-kv-survival-restart.md (merged to
main; seven-round audited). Judge the implementation against it. Also
load-bearing: SPEC-024 §11–§16 isolation invariants must be preserved
byte-for-byte in hot-tier behavior for non-gated keys.

Documented stage-5 residuals (judge their scoping, do not re-discover
them as new findings unless they violate a normative MUST): (1) first
post-restart-turn promotion needs a load-time geometry template — the
adapter only promotes after the model has committed once in-process;
(2) shutdown drain is best-effort fire-and-forget Tasks rather than a
bounded drain queue (spec FR-KVP3 says "drains pending snapshots for up
to shutdown_drain_seconds" — assess whether the implementation honors
the durability contract that only disk_write_committed generations are
promised); (3) AC-4 HW-map-at-cap rotation and AC-8 live spec-decode
no-lease assertions are named skips (need injectable cap / Metal).

Lane focus (security — weighted per the build charter):
- Cross-account isolation: SPEC-024 FR-CI5/CI6 preserved; the synthetic
  gate (conv:kvs-synth: prefix AND directHTTP provenance) cannot be
  bypassed (provenance threading from all three ingest boundaries; no
  path where relay/Tier-2 traffic persists; allow_buyer_keys rejection).
- Fail-safe-on-corruption: every malformed/corrupt/expired/tombstoned
  artifact resolves to miss with correct output; no serve-loop crash
  path; bounds enforced before allocation; AEAD/nonce/AAD implementation
  matches the spec (non-circular projection; per-chunk CSPRNG nonces).
- Key handling: Data-Protection Keychain usage, per-epoch masters +
  per-entry DEKs, HKDF labels, epoch rotation journal crash ordering,
  DEK destruction on purge/eviction, ownership-checked cleanup, no key
  material or raw conversation keys in logs/paths/errors.
- Quota DoS: per-namespace budgets, metadata reserve, free-space floor,
  write-live budget, staging ceiling, HW-map cap, control-plane bounds.
- No-receipt-drift: grep the diff for any wire/receipt/billing surface
  change; cached_prompt_tokens computation rule unchanged.
Report findings numbered, each with severity (CRITICAL/HIGH/MEDIUM/LOW/
INFO), file:line, the defect, a concrete fix. End with exactly:
VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO
PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.


## R3 context — verify the R2 reconciliation (certification round)

Round 3. R2 (five lanes) found 1 CRITICAL / ~8 HIGH / ~9 MEDIUM,
reconciled across two fix batches (commits 57b5723d..8bf32934). Verify
each theme in your lane's scope is genuinely fixed in the CURRENT code
and look for NEW defects introduced by the fixes:

- CRITICAL (purge admission fences): explicit per-index purgingIndexes +
  namespacePurging states set synchronously before any suspension;
  write() rejects fence_lost / read() rejects disk_miss_busy while a
  fence is up; hot-only purge advances the HWM + cancels pending persist;
  HW-cap rotation routed through performNamespacePurgeRotation (same as
  purge-all). Tests: testHotOnlyPurge*, testWriteDuringPurgeSuspension*,
  testReadAndWriteDuringPurgeAll*, testHighWatermarkCapPurgeClearsHotTier.
- HIGH-1 (memory): streaming seal to O_EXCL fd with rolling SHA (no
  whole-plaintext/blob co-resident); two-pass streaming read (SHA in
  1MiB windows, then per-frame decode) with ONE high-water budget +
  true peak_staging_bytes + disk_miss_budget on true peak.
- HIGH-2 (quota): all-class accounting (controlBytes: control doc +
  tombstones + journal), reserved from data budget, surfaced on status;
  bounded crash-tolerant append-only usage journal (≤1MiB compaction,
  torn-append tolerant, quarantine on malformed complete record, manifest
  fallback) seeding LRU.
- HIGH-3 (unreadable tombstone dir ⇒ quarantine, fail-closed).
- HIGH-4 (identity telemetry): ConversationColdContext.resolve threads
  identityUnavailableReason; gated missing-identity read/commit emit
  disk_miss_identity_unavailable / disk_write_skipped(identity_unavailable)
  before failing safe. commit() is now async.
- HIGH-5 (KVS-01a): restored arm is a genuine second turn (exact-prefix
  by construction); four arms; --cycles ≥30/arm gate + --smoke; nearest-
  rank p50/p95; §6 fields; README rewritten. (Harness cannot run headless
  — needs Metal + lab Mac; delivered as syntax-valid capability. Judge the
  logic, not runnability.)
- M-A..M-F (shutdown drain wiring + config duration; eligibility from
  exact commit instant; retention basis persisted; purge/eviction unlink
  failures ⇒ purge_failed; orphan DEK reconcile; idle retention wall-clock).
- M-G (AC matrix: crash injection at every boundary; per-field envelope
  mutation; live+synthetic snapshot immutability).

Documented residuals (judge scoping, don't re-flag as new unless they
violate a normative MUST): load-time geometry capture is future work
(model-hash fencing means a stale template can only miss, never promote
wrong; harness seeds it); KVS-01a/live-MLX tests need a lab Mac that does
not currently exist (gated behind KV_ENABLE_MLX_TESTS); commit() async.

The defect stream has narrowed R1(2C/14H)→R2(1C/8H). This is a
certification round: report only genuine remaining defects; polish that
doesn't change safety/correctness is LOW/INFO. PASS requires 0 C/H/M.
Same verdict line.
