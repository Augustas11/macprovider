## Lane: SECURITY / MONEY PATH

Check:
- **Cross-conversation or cross-account leakage.** Auto-prefix keys are shared
  by all conversations with the same scaffold. Can a checkpoint restore leak
  one buyer's content or state into another buyer's turn under the same key,
  beyond the SPEC-024 FR-CI isolation baseline? What exactly is shared, and is
  it only the common prefix?
- **`cached_prompt_tokens` correctness.** Is it ever larger than what was
  truly reused, which would under-bill on sticky hits?
- **Billing and receipt field parity** between serial hits and batched-origin
  entries.
- **Timing-oracle implications** of the much faster first token (SPEC-024 §13).
- **Memory denial of service:** roughly 300 MiB of checkpoints per entry,
  bounded by LRU/TTL.
- **Fail-closed behaviour** when snapshot or materialize fails.
