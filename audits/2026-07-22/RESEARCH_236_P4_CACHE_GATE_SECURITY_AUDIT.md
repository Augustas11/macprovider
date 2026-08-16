# RESEARCH_236 P4 — SECURITY audit lane (network-harness cache-reuse gate)

You are a **security auditor**. Review ONLY the diff of branch
`research/236-p4-cache-regression` against `origin/main` (commit
`b8fd549a`). Context: an internal e2e harness that fires buyer requests at
the live gateway (`api.malibu.tech`) using a bearer token read from
`${BUYER_TOKEN}` (`~/.config/macprovider/buyer-api-key`). The diff adds a
sticky KV-cache-reuse regression gate. Files listed in the CODE-lane
prompt in this directory.

## Threat model to check

1. **Token / secret leakage.** The new `sticky_cache` path builds request
   bodies and a large generated prefix. Confirm the buyer token is never
   logged, embedded in the generated prefix, written to an artifact, or
   echoed. The prefix is seeded by `buyerIdx` + a time-based `runSalt` —
   confirm the salt is not a secret and leaks nothing sensitive.
2. **Untrusted-response parsing.** `usage.cached_prompt_tokens` comes from
   the gateway/provider (untrusted). Check the new pointer-based parse
   can't be abused: negative values, huge values, non-integer, injected
   into a forged SSE error envelope (#232 lineage — the streaming path has
   a standalone-error-envelope gate; verify the new cached-field extraction
   sits AFTER that gate and cannot import tokens from a forged envelope).
   Any integer overflow / panic on malformed usage?
3. **Resource / prod-safety.** The generated prefix size is bounded by
   `CachePrefixLines` with a `MinCachePrefixLines` floor; is there an upper
   bound so a scenario can't be crafted to send an enormous body? Is the
   scenario genuinely light (single sequential buyer, small max_tokens)?
   Any way the pattern loops unboundedly or amplifies load on prod?
4. **Scenario-as-input.** Scenario YAML is semi-trusted. Confirm the new
   fields (`cache_prefix_lines`, `sticky_conversation_key` under
   `sticky_cache`) can't be used to point at an unintended host, inject
   headers, or interpolate `${VAR}` secrets into artifact fields (recall
   SEC-M-1 mode-probe lineage). The sticky conversation header is built via
   `fmt.Sprintf(key, buyerIdx)` — any format-string / header-injection
   risk?
5. **No new network egress** beyond the configured gateway.

## Rules

- FINDINGS ONLY: CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line and a
  concrete fix. Bar: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
- Scope is the diff; pre-existing harness security posture is out of scope
  unless the diff regresses it.
