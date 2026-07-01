# AUDIT_SPEC_015_V0_4_PRODUCT_PROMPT

You are auditing `specs/SPEC-015-receipts.md` as a PRODUCT DESIGN critic.

Audit target: v0.4 deltas only, centered on the new `0.4.0-draft` header
and §N "Settlement-capable receipts". Treat v0.1/v0.2/v0.3 locked history as
fixed unless a v0.4 clause contradicts it.

Controlling context:

- `specs/SPEC-015-receipts.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
- SPEC-022 v0.1.4 requirements quoted or referenced by §N

Lock bar: 0 critical, 0 high, 0 medium.

Focus:

- Does v0.4 support buyer trust for agentic/streaming traffic without
  overclaiming what receipts prove?
- Are buyer/provider/operator states explainable: pending, verified,
  quarantined, zero-settled, late receipt, streaming partial, failover?
- Are provider-facing deadline expectations clear enough to avoid surprise
  non-settlement?
- Are product disclosures explicit that v0.4 verifies provider-reported
  request-start hash against the route-time catalog snapshot and does not
  detect falsified local hash measurement?
- Does the spec avoid framing quarantine, pending, or model-integrity failures
  as buyer fault?
- Is this enough to unblock a future SPEC-022 implementation prompt from a
  product/UX perspective?

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`PD-C-1`, `PD-H-1`, `PD-M-1`, etc.). Cite SPEC text
and concrete repo/spec evidence.
