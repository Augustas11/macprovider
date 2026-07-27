# AUDIT — SPEC-037 IMPL R1 — ARCHITECT lane

You are the ARCHITECT audit lane reviewing the IMPLEMENTATION of SPEC-037
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

Lane focus (architect):
- Fidelity: does the implementation structure honor the spec's
  authority boundaries (no receipt/billing/wire change; hot tier
  unchanged for non-gated keys; residency-only semantics)?
- Layering: ConversationColdTier protocol seam, KVDiskTier coordinator,
  store actor — is the composition sound, are responsibilities where
  the spec puts them (e.g. no second reuse predicate, promotion under
  the per-key lease, index computation inside the owning process)?
- SPEC-038 collision surface: are the ModelRuntime/ConversationCache
  diffs minimal and rebase-friendly for the parallel batching work?
- Lifecycle wiring: serve activation, dormancy/retry, shutdown, control
  socket in-process route vs standalone CLI flock model.
- Residual scoping: are the three named stage-5 residuals correctly
  scoped as follow-ups (vs violating a normative MUST)? Is the
  first-post-restart-turn promotion gap acceptable for a v0.1 whose
  KVS-01a gate requires post-restart promotion — does the harness
  actually exercise a code path that works (write in relaunched
  process happens only after first commit)? Think this through
  concretely against kvs-01a.sh's sequence.
Report findings numbered, each with severity (CRITICAL/HIGH/MEDIUM/LOW/
INFO), file:line, the defect, a concrete fix. End with exactly:
VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO
PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
