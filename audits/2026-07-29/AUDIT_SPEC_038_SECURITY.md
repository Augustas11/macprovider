# SPEC-038 audit — SECURITY / CORRECTNESS lane (money-path weighted)

You are auditing a **normative SPEC document** (design text), not an
implementation. Proof-review only; produce findings, not code.

This is a **money-path** SPEC. Continuous batching moves per-request token
usage accounting under one shared model forward, which is adjacent to
receipts, provider earnings, and billing. Weight your review on per-request
usage/receipt isolation and on serial-fallback parity.

## Scope (read these files)

- `specs/SPEC-038-continuous-batching.md`
- `specs/CONFORMANCE.json`, `specs/AUTHORITY.json`
- Adjacent locked/authoritative contracts the SPEC must not break:
  - `specs/SPEC-015-receipts.md` (LOCKED receipts)
  - `specs/SPEC-024-prefix-cache-billing.md` (`cached_prompt_tokens`, reuse
    predicate, `conv:` key rules)
  - `specs/SPEC-005-billing.md`
  - `specs/SPEC-028-mlx-speculative-decoding.md`
  - `specs/SPEC-037-kv-survival-restart.md` (KV persistence round-trip)
- Ground truth: `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md`
  (§2.7 invariants, §5.9–§5.11 receipt/hash/OPoI, §4.9 gates).

## What to check (SECURITY / CORRECTNESS lane)

1. **Per-request isolation under the shared forward (load-bearing).** Does
   FR-CB6 fully forbid cross-request token attribution, sampler/stop/cache
   leakage, and receipt cross-contamination? Are there gaps where a shared
   forward could mis-bill a buyer or mis-credit a provider? Is the "no batch
   ID in the receipt identity tuple" rule airtight vs SPEC-015?
2. **Serial-fallback parity.** Is FR-CB9 strong enough that a flag-off (or
   unsupported-model, or post-failure safe-mode) provider is provably
   identical to today — including receipts, `slots_total`/`slots_free`, and
   byte-identical greedy output? Any way the fallback could silently diverge?
3. **Model-hash / warm-swap binding.** FR-CB13: can an accepted or queued
   request ever be served against warm-swapped weights while carrying the old
   hash? Is drain coverage (prompt rows, decode rows, queued, cache commit,
   receipt) complete? Is the queued-work binding policy choice explicit?
4. **Silent-downgrade attack surface.** FR-CB8: can an unsupported cache class
   or `kv_bits` mode ever silently downgrade quantization, reinterpret a
   quantized cache as ordinary KV, or silently fall back — producing wrong
   accounting or a security-relevant KV confusion? Must be observable/reason-
   coded.
5. **OPoI/drift and capacity-inflation.** FR-CB11 / §6: can queued work
   inflate advertised capacity, or can batched aggregate TG be fed into a
   single-stream drift decision and cause false sanction / mis-settlement?
6. **Enable-gate integrity.** FR-CB15: is a green CI/audit pass sufficiently
   excluded as an enable gate, so a runtime money-path feature cannot be
   turned on for real traffic without the real-hardware per-request-
   correctness exercise?
7. **Unmeasured-number leakage.** FR-CB14: can any vendor throughput multiplier
   escape into an advertised/settlement-relevant number?

## Output

Per finding: SEVERITY (CRITICAL / HIGH / MEDIUM / LOW / INFO), exact location,
the isolation/accounting risk, and a concrete normative fix. Bar is 0 C / 0 H /
0 M. State explicitly if the SPEC meets the bar; list LOW/INFO separately.
