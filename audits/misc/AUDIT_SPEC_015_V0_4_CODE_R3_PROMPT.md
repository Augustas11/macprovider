# AUDIT_SPEC_015_V0_4_CODE_R3_PROMPT

You are re-auditing `specs/SPEC-015-receipts.md` from the CODE lane.

Audit target: v0.4.2-draft deltas only, centered on §N
"Settlement-capable receipts". Treat v0.1/v0.2/v0.3 locked history as fixed
unless a v0.4 clause contradicts it.

R2 CODE findings to verify closed:

- `CODE-H-1`: v0.4 non-streaming `output_hash` was not deterministically
  implementable because §N.5 defined streaming `stream_output_prefix_v1` but
  allowed non-streaming implementations to use the legacy §5 three-key object
  when "byte-equivalent", which cannot be true.
- `CODE-H-2`: v0.4 `attempt_n` used one-based numbering while locked
  SPEC-002/SPEC-005/current ledger identity uses zero-based route attempts.

Also confirm the v0.4.2 fix did not reopen any R1 CODE high/medium finding:
strict usage schema, route-snapshot digest/fields, streaming output
canonicalization, deterministic chargeability, receipt-key binding,
timestamp policy, and runnable acceptance criteria.

Lock bar: 0 critical, 0 high, 0 medium.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`CODE-C-1`, `CODE-H-1`, `CODE-M-1`, etc.). Cite
SPEC text and concrete repo/spec evidence.
