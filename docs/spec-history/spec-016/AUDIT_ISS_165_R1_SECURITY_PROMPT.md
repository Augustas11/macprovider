# Audit: ISS-165 R1 security lens

Issue #165 closes two LOW arch advisories deferred from PR #164:
- **A1**: `ProduceStaleOutboxRows` LIMIT + `payout_stale_outbox_backlog`
  WARN gauge.
- **A2**: `ChronicOutageTracker` + `TrackingRPCClient` wrapper +
  `payout_rpc_chronic_outage` PAGE.

Tree at HEAD: `spec/iss-165-spec-016-followups` (`git log --oneline -2`).

## Files in scope

- `phase4-coordinator/internal/payout/orphans.go` (modified)
- `phase4-coordinator/internal/payout/chronic.go` (new)
- `phase4-coordinator/internal/payout/runner.go` (modified)
- `phase4-coordinator/cmd/coordinator/main.go` (modified)
- `phase4-coordinator/internal/payout/iss165_a1_test.go` (new)
- `phase4-coordinator/internal/payout/iss165_a2_test.go` (new)
- `specs/SPEC-016-payout-pipeline.md` (v0.1.22 change-log + §7.1)

## Threat model

Money path — the §4.7 producer governs which stale-cancel rows
become operator PAGE events. The chronic-outage tracker is the
operator's only signal for chronic single-RPC failure (the disagreement
detector at §4.4 doesn't fire when one side is silently failing).

Specifically watch for:

1. **Suppression / silencing**: can A1's LIMIT cause an indefinite
   delay in PAGEing a stale cancel? Could backlog grow faster than
   the runner drains so a row never gets paged? Could the COUNT(*)
   failure mask the backlog?
2. **PAGE-storm / DoS-on-operator**: can A2 emit excessive PAGEs?
   Does the cooldown protect the journal? Can an adversary force a
   PAGE by inducing one-sided RPC errors (e.g. via TLS pin mismatch
   on one side only) and what's the cost?
3. **Tracker poisoning / state staleness**: can samples accumulate
   without bound? Are samples pruned correctly? Is the per-label
   mutex held across blocking operations?
4. **Secret leakage**: do any log fields expose RPC URLs, SPKI pins,
   wallet bytes, or signed tx bytes? `rpc_label` is documented as
   non-secret (e.g. "primary"/"secondary") but verify.
5. **Race conditions**: `TrackingRPCClient` is wired around the
   primary + secondary clients used by every payout cycle, the reorg
   poller, AND the bootstrap chain-balance worker. Confirm safety
   under those concurrent callers.
6. **Wrong-classification of errors**: TransactionReceipt's
   (nil, nil) "not found" is documented as SUCCESS not error.
   Re-derive: is that classification consistent with §4.7's "RPC
   error is NOT a stale signal"? Are there RPC outcomes that the
   wrapper miscounts in either direction?

Find **SECURITY DEFECTS**. Stay narrow to security — separate code +
architect lanes cover correctness + design.

Severity:
- CRITICAL: silent money loss / unauthorized access / secret exposure.
- HIGH: operator decision corruption, page storm, or denial of
  detection.
- MEDIUM: defense weakening, missing best-effort hardening.
- LOW: deferrable hardening.

Output format identical to the code lens: severity-headed findings
plus a `## Convergence X/X/X/X → DECISION` summary line.
