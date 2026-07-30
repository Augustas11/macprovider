You are performing an independent proof-review (SECURITY / settlement-safety lane)
of a finished normative specification in the macprovider repository. This is a
defensive review of an existing document — you are NOT asked to author, extend, or
build any attack. Report defects in the spec's safety properties only.

## Target
- Primary: `specs/SPEC-036-compute-integrity-receipt.md`.
- Composed primitive: `specs/SPEC-030-losslessness-probe.md` (§FR-3 transport/auth,
  §FR-4 replay binding, §FR-7 support selection, §FR-9 TV interval).
- Settlement contract it gates: `specs/SPEC-022-verified-model-settlement.md`.
- Receipt invariants it must not violate: `specs/SPEC-015-receipts.md`.

## What SPEC-036 is
An additive, coordinator-owned compute-integrity drift gate on paid settlement. In
enforce mode, a covered paid request whose request-start compute-integrity key is
`quarantined_compute_drift` MUST NOT create buyer debit, provider credit, earnings
visibility, sweep inclusion, or payout readiness. It compares a provider's
next-token distribution against a coordinator-held trusted reference (cross-node),
maps drift to SPEC-022 `outcome=quarantined`, `reason=compute_drift_quarantined`.

## Review dimensions (SECURITY / settlement-safety) — find where the spec fails to
## fail closed, or allows money to move when it must not.
1. Fail-closed completeness: enumerate every request-start compute-integrity state
   (`unknown`, `pending`, `verified`, `warn`, `quarantined_compute_drift`,
   every `blocked:<reason>`, `expired`, unreadable, stale, uncovered-profile) and
   verify each either is payable ONLY under the stated fresh-verified/fresh-warn
   prerequisites or maps to a non-payable settlement reason. Flag any state that
   could silently settle as payable.
2. Replay / nonce / expiry / digest binding: verify FR-6 rejects duplicate
   `probe_request_digest`, stale/expired probes, identity-echo mismatches, and
   cross-position/prefix substitution, and that a provider cannot get a payable
   verdict from a replayed or pre-computed result.
3. Reference trust: can a single, non-independent, stale, or self-attested trusted
   reference satisfy the two-reference enforce quorum? Verify independence rules
   (FR-5) actually prevent two sources sharing a runtime build / kernel / hardware
   failure domain / operator identity from both counting, and that a reference
   fault or missing quorum blocks (not silently passes) covered keys.
4. Provider-authoritative-verdict risk: verify the coordinator recomputes reference
   probabilities/tail mass and derives the verdict; the provider must never supply
   the authoritative TV verdict or the reference side of the comparison.
5. Laundering resistance: re-onboarding with a new `assigned_id`, target-generation
   churn, warm-swap, tokenizer/sampler/corpus/threshold changes — verify active
   quarantine/block state and sub-threshold accumulators (quarantine-candidate
   window, 24h abusive-inconclusive count, onboarding-failure count) are inherited
   by stable provider identity and cannot be reset by provider-originated actions.
6. Circuit-breaker + operator controls: verify a mode rollback (enforce→warn_only)
   and an `override_routing_only` record CANNOT make already-captured or currently
   held non-payable rows payable; only a `cleared` transition (quiet window + fresh
   reference admission + dual approval + audit fields) releases the hold for future
   rows; the 4-hour override cap and dual-approval requirements are sound.
7. Money-path invariants: SPEC-036 adds NO fields to SPEC-015 v0.4 receipts/usage
   and introduces NO fifth SPEC-022 top-level outcome in v0.1; `zero_settled` is
   never used for drift; the SPEC-015 crypto verifier result stays orthogonal and
   cannot override the quarantine gate.
8. Disclosure honesty / threat-model integrity: verify the spec forbids
   "proved honest computation" / "cryptographic proof" / hardware/binary-integrity
   claims, and that the threat model correctly disclaims overt-probe evasion and
   detection lag (time-to-quarantine SLO).
9. Non-billable funding: probes/references never bill buyers, never appear in
   SPEC-015 usage, never draw uncapped MALIBU rewards.

## Output format
For each finding: SEVERITY (CRITICAL / HIGH / MEDIUM / LOW / INFO), short title,
exact file + line/section, the concrete failure scenario (state/inputs → wrong
money outcome), and the minimal fix. Rank most-severe first. If a dimension is
clean, say so in one line. Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM.
