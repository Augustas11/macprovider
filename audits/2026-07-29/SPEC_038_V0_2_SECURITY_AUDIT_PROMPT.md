# SPEC-038 v0.2 security-lane audit prompt

Audit the full branch diff for `SPEC-038` v0.2:

```bash
git diff origin/main -- specs/SPEC-038-continuous-batching.md specs/CONFORMANCE.json specs/README.md
```

Scope:

- SPEC-only change; no implementation files should be modified or required.
- Focus on buyer/provider money-path and isolation risk introduced by a shared
  forward: token attribution, cached prompt token eligibility, receipts,
  cancellation, duplicate settlement, reconnect idempotence, warm-swap model
  hash binding, and cross-request cache/block-table leaks.
- Check that unsupported cache, `kv_bits`, MoE expert dispatch, and missing
  local paged-engine capabilities fail closed or serial-route only under
  explicit operator policy with observable reason codes.
- Check clean-room boundaries: no dependency on `Layr-Labs/*` or
  `d-inference` source.

Money-path weighting:

- Treat any ambiguity that could misbill buyers, overpay/underpay providers,
  leak one request's state to another, or silently downgrade security-relevant
  capability gates as at least MEDIUM.

Output:

- Findings ordered by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO.
- Include exact file/line references.
- End with counts and a verdict: PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
