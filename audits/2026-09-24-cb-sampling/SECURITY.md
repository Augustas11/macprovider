## Lane: SECURITY / MONEY PATH

Check:
- Cross-row isolation of randomness and logits.
- Seed predictability: a client chooses its own request ID. Can that affect
  another row or buyer?
- Replay and idempotency interaction: the seed derives from the request ID,
  and the fingerprint includes `samplerSeed`.
- Any change to usage, receipt or settlement accounting for sampled rows.
- Denial of service from per-row sampler cost at 8 rows.
- Fail-closed handling of unsupported parameters.
