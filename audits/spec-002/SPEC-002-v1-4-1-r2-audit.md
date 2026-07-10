CLOSURE on round-1 findings:
  M1: PASS — `mint_failed` is now explicitly reserved/currently non-observable on registered `/poolz` rows, with close-before-registration behavior documented.
  M2: PASS — The exclusion rule now covers top-level `Pool.TotalProviders`, top-level `Pool.Ready`, per-model `ProviderCount`, `ReadyProviderCount`, slot totals, availability, and supported-model unions.
  M3: PASS — Auth-state-aware buyer-facing consumers are now explicitly forbidden from using coordinator `summary` fallback to repopulate excluded counters when detailed `pool` rows were present.
  L1: PASS — SPEC-003 provenance is split between the v0.8.3 base enum and the v0.8.4 reserved `mint_failed` value.
  L2: PASS — The spec now carries an explicit deferred SPEC-006 amendment pointer for the `/v1/status` aggregation invariant.
  Q1: PASS — The spec now decides buyer-facing `/v1/status` `total_providers` is routable-eligible, while operator-facing `/poolz` `summary.total_providers` remains raw coordinator-visible session count.
  Q2: PASS — The spec now answers that `mint_failed` is not currently operator-visible on registered `/poolz` rows.

NEW FINDINGS (round 2):
CRITICAL (0):
  None.

HIGH (0):
  None.

MEDIUM (0):
  None.

LOW (1):
  L-R2-1. Stale adjacent wording can still imply `summary` is the primary SPEC-006 gateway input.
      Evidence: `specs/SPEC-002-coordinator.md` still says "The `summary` block is the SPEC-006 v0.3 gateway input for `/v1/status`" immediately before the v1.4.1 rule, while the new rule requires buyer-facing aggregators to derive eligible counters from detailed `pool` rows when present and forbids summary fallback from repopulating excluded counters.
      Impact: Low. The new normative text below resolves the behavior, so implementers reading the full v1.4.1 section get the right rule. Tightening the older sentence would reduce scan-time confusion.
      Suggested fix: Change the older sentence to say `summary` remains the raw coordinator/operator summary and may only serve gateway fallback behavior when detailed `pool` rows are absent.

QUESTIONS (0):
  None.

VERDICT: READY TO LOCK v1.4.1
