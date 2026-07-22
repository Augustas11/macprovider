# RESEARCH_236 P4 — CODE audit lane (network-harness cache-reuse gate)

You are a **code-quality auditor**. Review ONLY the diff of branch
`research/236-p4-cache-regression` against `origin/main` (commit
`b8fd549a`, "feat(harness): P4 sticky KV-cache-reuse regression gate").

## What the change does

Adds a phase-C regression gate to the internal network-harness
(`test/network-harness/`) that measures sticky KV-cache reuse and turns it
into two benchmark invariants (B8/B9), guarding the already-measured ~64%
prefix-cache reuse win (#376). Files:

- `internal/buyer/result.go` — new fields: `CachedPromptTokens`,
  `CachedPromptTokensPresent`, `UsagePresent`, `CachePhase`.
- `internal/buyer/loadgen.go` — parses `usage.cached_prompt_tokens`
  (pointer, so absent ≠ 0) in both the streaming (`chunkPayload`) and
  non-streaming (`nonStreamingChatCompletion`) paths; new `sticky_cache`
  buyer pattern that prepends a per-buyer/per-run deterministic large
  prefix (`stickyCachePrefix`) and tags `CachePhase`
  ("uncached" for request_index 0, "cached" for >=1).
- `internal/scenario/schema.go` — `CachePrefixLines` field,
  `MinCachePrefixLines` floor, `sticky_cache` pattern validation, B8/B9
  added to the known-invariants map.
- `internal/benchmark/benchmark.go` — `CacheReuseMetrics`, compute of
  reuse ratios + cached/uncached TTFT split, `evalB8`/`evalB9`, case
  dispatch. CALIBRATED threshold constants (RE-AUDIT R6): B8 armed
  `CacheReuseTarget=0.60` / `CacheReuseBareMin=0.50` (PASS ≥0.60, WARN
  [0.50,0.60), FAIL <0.50), calibrated from the 0.725 prod baseline; B9
  record-only (SKIP, no Target/BareMin). Confirm the reband + its unit test
  (WARN case at 0.55) + SPEC band text are internally consistent and that
  `go test ./...` / `go vet` pass.
- tests: `internal/buyer/loadgen_cache_reuse_test.go`,
  additions to `internal/benchmark/benchmark_test.go`.
- `scenarios/16_sticky_cache_reuse.yaml`, `docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md` §3.5.

## Focus

1. **Correctness of the reuse metric.** Is `reuse = cached_prompt_tokens /
   prompt_tokens` computed only over successful warm ("cached"-phase) turns
   that actually reported the fields? Is the median the right statistic? Any
   divide-by-zero, integer/float, or off-by-one bug?
2. **Presence vs zero.** Verify a genuine `cached_prompt_tokens: 0` (cache
   collapsed) is distinguished from an omitted field, and that B8
   FAILs on the former but SKIPs on the latter (and when no cached turns
   exist). Pointer-based presence detection sound?
3. **Phase tagging + prefix injection.** Is `request_index` 0 always the
   uncached first-touch and >=1 cached? Is the generated prefix
   deterministic within a run and distinct per buyer and per run (so the
   uncached baseline is a true cold first-touch)? Interval pacing correct?
4. **B9 ratio** direction and SKIP conditions (cachedP50/uncachedP50).
5. **Consistency** with existing B7/cold_warm idioms; dead code; naming;
   the new fields don't break existing artifact consumers.
6. **Test quality** — do the fixtures actually exercise working / collapsed
   / usage-absent, and the schema validation table cover the reject paths?

## Rules

- Report FINDINGS ONLY as CRITICAL / HIGH / MEDIUM / LOW / INFO with
  file:line and a concrete fix. Bar to pass: **0 CRITICAL, 0 HIGH, 0
  MEDIUM**. LOW/INFO may be carried.
- Scope is the diff. Pre-existing harness behavior outside the diff is out
  of scope unless the diff worsens it.
- Do not run the network scenario (it hits prod). `go test ./...` under
  `test/network-harness/` is fine.
