# AUDIT — SPEC-037 IMPL R2 — SECURITY lane

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

## R2 context — verify the R1 reconciliation

Round 2. R1 (five lanes) found 2 CRITICAL / ~8 HIGH / ~11 MEDIUM,
reconciled in 14 fix commits (ffdf25f7..plus M-16). Verify each theme in
your lane's scope is genuinely fixed in the CURRENT code, then audit the
new fix code as fresh material:

- C1: purge now clears the hot tier via callbacks wired at
  attachKVDiskTier (single-key before unlink; purge-all before rotation),
  with integration tests through the real path.
- C2: key epoch + commit sequence captured synchronously under the lease
  (adapter-cached epoch, per-index atomic sequence seeded at activation);
  writeColdSnapshot rejects fenceLost on epoch/sequence mismatch;
  purge-all cancels+awaits pending persist tasks before rotation.
- H3: KVS-01a fails loud (no || true; restored arm must record disk_hit
  with exact cached_prompt_tokens), seeds the geometry template on a
  DIFFERENT synthetic key post-relaunch, --cycles N four-arm interleave
  with nearest-rank summary, README rewritten. Load-time config-derived
  geometry capture is a DOCUMENTED residual with a safety argument
  (model-hash fencing means a wrong template can only miss, never
  promote incorrectly; follow-up = persist-and-seed the learned
  template). Judge the residual's scoping, not its existence.
- H4: one shared entry DEK across generations (create only when absent;
  fresh only after purge/eviction); gen1-committed/gen2-crash/read-gen1
  test.
- H5: geometry estimate + write-live reservation BEFORE deep copy;
  one-pending-per-index displacement; tracked tasks; bounded shutdown
  drain; chunk-by-chunk encrypt-append.
- H6: Σ ct_length coherence pre-allocation; streamed read frames; staging
  ceiling as a real peak bound.
- H7: throwing fsyncDirectory propagated; committed never emitted on a
  failed barrier; failpoints at each fsync boundary.
- H8: pinned revisions as source constants with a Package.resolved drift
  test; live tokenizer/template file bytes hashed at load; real catalog
  revision; identity_unavailable when absent.
- M-9 closed-schema quarantine; M-10 raw-JCS AAD (no NFC) + fixture;
  M-11 reserved-vs-committed split; M-12 creation-basis scheduled
  retention; M-13 serve-lock bounded-backoff retry with recovery at
  acquisition; M-14 bounds ⇒ disk_miss_corrupt; M-15 delimited keychain
  service; M-16 directory ownership/mode/symlink verification at
  activation + recovery; M-19 statfs failure fails closed; LOWs: TM
  exclusion xattr, CSPRNG ⇒ dormancy.

Do not manufacture findings; the store held up well in R1 (crypto/format
clean) — focus on whether the fixes are correct and complete and whether
they introduced regressions. PASS requires 0 C / 0 H / 0 M. Same verdict
line format.
