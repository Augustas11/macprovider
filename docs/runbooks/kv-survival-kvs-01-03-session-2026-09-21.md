# KV Survival — Session Record (KVS-01 through KVS-03)
**Date:** 2026-09-20 / 2026-09-21  
**Lab machine:** Mac Studio M3 Ultra (home machine, isolated loopback)  
**Status:** CLOSED — enablement decision deferred (see bottom)

---

## What this session tested

The goal was to verify that the KV cache on disk survives a provider restart and that the cache is correctly invalidated when the model changes. All testing happened on an isolated port (127.0.0.1:18080). Live buyer traffic on 8080 was never touched.

---

## KVS-01a — Basic survive-and-restore

**Landed on main:** PR #1654

- Provider ran on the Studio at `127.0.0.1:18080` with `--no-join` (not registered to fleet).
- Only synthetic `conv:kvs-synth:` keys were written. Real buyer keys: off. Continuous batching: off.
- 30/30 probe cycles: cache entry persisted across SIGKILL, provider relaunch, and disk hit check.
  - `disk_hit`, `cached_prompt_tokens=1616` on every restore.
  - Purge drops the encryption key (DEK), so a post-purge probe correctly gets a cache miss.
- **Live 8080 was not killed or affected.**
- Evidence: `docs/runbooks/kv-survival-kvs01a-enable-gate-evidence-2026-09-20.md`  
- Decision log: Entry 244

---

## KVS-01b — 8k prefix, memory ceiling

**Landed on main:** PR #1657

- Same isolated lab setup as KVS-01a.
- Prompt extended to ~8k tokens. Both staging knobs set to 1 GiB ceiling.
- CLI build `9be5e2f1…` (ceiling enforcement added in #1655) used for the run.
- 30/30 probe cycles: `disk_hit`, `cached_prompt_tokens=8016`.
- Timing on restore: TTFT p50/p95 = 1111 ms / 1127 ms (vs cold miss ~5557 ms, vs warm ~482 ms).
- Peak disk usage ~752 MiB, staging peak ~815 MiB — within the 1 GiB ceiling.
- Write latency p95 = 531 ms. This exceeds the internal 250 ms write-cap target at 8k. Noted; not blocking the gate at this stage.
- **Live 8080 stayed on the packaged release (version 172). Not touched.**
- Evidence: `docs/runbooks/kv-survival-kvs01b-8k-gate-evidence-2026-09-21.md`  
- Decision log: Entry 246

---

## KVS-02 — Cross-model invalidation (different model ID, same family)

**This branch (feat/037-kvs02-03)**

This test checks that a cache entry written for model A is NOT served when model B starts up — even if A and B are in the same model family.

- Model A: Qwen3-Coder-30B-A3B-4bit
- Model B: Qwen3-8B-4bit
- Same isolated lab port (127.0.0.1:18080). Live 8080 untouched.
- **Miss arm (model swap):** provider starts with B after A's cache was written → `disk_miss_envelope`, `cached_prompt_tokens=0`. Correct fresh output.
- **Control arm (same model relaunch):** provider relaunched with A → `disk_hit`, `cached_prompt_tokens=528`. Cache correctly served.
- Harness SIGKILL of B happened before it could overwrite A's blob on disk.
- Samples saved on Studio at `~/.local/state/kvs-02/evidence/`.

**Result: PASS**

---

## KVS-03 — Same model ID, different artifact hash

**This branch (feat/037-kvs02-03)**

This test checks that a cache entry written for a specific snapshot of a model is NOT served when the same model ID is loaded from a different snapshot (different artifact SHA-256).

- Model ID (same both arms): `Llama-3.2-3B-Instruct-4bit`
- Snapshot A: artifact SHA `e7e5bff4…`, HF revision `7f0dc925`
- Snapshot B: artifact SHA `82c8db74…`, HF revision `7a82cca1` (1.82 GB download)
- **Miss arm:** provider loads snapshot B after snapshot A's cache was written → `disk_miss_envelope`, `cached_prompt_tokens=0`.
- Same isolated lab setup. Live 8080 untouched.
- Samples saved on Studio at `~/.local/state/kvs-02/evidence/`.

**Result: PASS**

---

## What this work did NOT do

- Fleet KV cache default is still **off**.
- Live Pearl 8080 never had `kv_disk_cache` enabled at any point.
- No real buyer conversation keys were written to disk.
- Long-soak (KVS-04) and prewarm-mix (KVS-05) tests were not run. Those are later work, not part of this gate.
- SPEC-037-R013 is not marked conformant. No CLI release was cut from this branch.

---

## Decision — why this closes without merging to enable

KV survival is proven on the Studio lab. The cache behaves correctly: it survives restarts and invalidates correctly on model changes. The lab results are clean.

However, enablement on this Mac (as a serving product) or across the provider fleet is **not decided yet**. The blocker is a strategic positioning question:

Malibu's Zero Data Retention / privacy story conflicts with persisting conversation-reconstructible cache blobs on home Macs owned by individual providers. Private pool architectures (where the buyer and provider are the same party or trusted) may change this calculation. Until Malibu decides how the network is positioned, KV cache should not be turned on for live buyer traffic or as a fleet default.

This PR closes without merging. The lab evidence lives in the docs and is preserved here for when that strategic call is made.
