# FIX_SPEC — Exclude providers with no active settlement receipt key from covered paid routing

**Version:** 0.1 (2026-08-07, initial)
**Governing spec:** SPEC-022 — Verified model settlement (v0.1.6)
**Authority domain:** `verified-model-settlement` (owner: SPEC-022; contributors: SPEC-015)
**Requirements touched:** SPEC-022-R002 (R-2.4, R-2.5, R-2.6)
**Depends on:** SPEC-015 v0.4.2 (verifiable inference receipts — route-snapshot / provider receipt-key binding)
**Type:** Coordinator IMPL fix (routing eligibility), money-path. No SPEC normative change.

---

## 1. Summary

Under `verified_model_settlement_mode: enforce`, a provider whose **active** receipt
public key is empty is still selected as a routing candidate and only rejected
**after selection**, pre-dispatch, with `route snapshot insert failed / missing
provider receipt key`. This burns a real buyer request on a route that is
guaranteed to fail, emits an operator-visible 500, and — with a deterministic
router — can repeatedly re-select the same dead-weight provider.

The fix moves the receipt-key precondition **up to candidate eligibility**: under
enforce mode, a provider with no active `ReceiptPubkey` MUST be filtered out of
the covered-paid candidate set (new `FilteredCounts` reason `receipt_key_missing`),
exactly as model-version-floor and warm-swap-not-ready providers already are. In
observe mode, behaviour is unchanged (no exclusion).

## 2. Root cause (evidence)

- **Failure site:** `phase4-coordinator/internal/buyer/route_snapshot.go:51-52` —
  `if len(provider.ReceiptPubkey) == 0 { return skipOrEnforceError("missing provider receipt key") }`.
  Under enforce this returns a hard error **before provider dispatch**
  (`inference_ran:false`); the gateway treats a genuine first-attempt
  `route_snapshot_failed` as no-charge.
- **Why the active key is empty:** `phase4-coordinator/internal/pool/provider.go:947-976`
  `stageReceiptPublicationLocked` stages a first-seen / re-staged receipt key into
  `PendingReceiptPubkey` and leaves the **active** `ReceiptPubkey` empty unless the
  provider presents a signed previous-key continuity proof. A provider that never
  completes promotion to active (stale / unverified / churny node) stays routable
  but un-settleable.
- **Live correlation (2026-08-07, prod coordinator):** every route-snapshot
  failure mapped to a single node, `mp-c6ce46b97a755f1db6ddfa7d59bbdf6a` (M1 8GB,
  CLI 1.8.69, unverified) — **15 requests routed to it = 15 route-snapshot
  failures** in a 10-minute window, while `mp-1962…` (provider4) and `mp-2659…`
  (M5) settled cleanly. This is **not** a CLI version gap (both 1.8.69 and 1.8.88
  emit `provider_receipt_public_key`, added in SPEC-015 #123) and **not** flap-timing
  (the flapping node was offline). It is purely the empty-active-key state remaining
  a routable candidate.

## 3. Conformance gap this closes

SPEC-022 R-2 (routing preconditions) is normative that unsatisfiable-settlement
providers are **excluded from routing**, not selected-then-rejected:

- **R-2.4:** *"Providers with … missing, empty, stale, or ambiguous … state MUST be
  excluded from covered paid routing."*
- **R-2.5:** *"… MUST NOT be eligible for covered paid routing for the target model."*
- **R-2.6:** *"Ordinary routing filters still apply, including provider readiness …"*

The current implementation enforces the receipt-key precondition at
route-snapshot time (post-selection) rather than at eligibility, so an ineligible
provider is still *routed to*. The fix implements the R-2 "excluded from routing"
wording at the candidate-filter layer. The pre-dispatch guard in
`route_snapshot.go` is retained as fail-closed defence-in-depth.

## 4. The change

**File:** `phase4-coordinator/internal/routing/filter.go` — `EligibleCandidates` (first pass, ~line 176, alongside `ProviderMeetsModelVersionFloor`).

1. Add a `RejectionReason` `ReasonReceiptKeyMissing` (routing package) and its
   `FilteredCounts` string key `receipt_key_missing` (`routing/log.go:36`
   reason list + the `filtered_counts` interface map).
2. Extend `EligibilityChecker` with `ProviderHasSettlementReceiptKey(p pool.Provider) bool`.
   Contract: returns **true** unless settlement route mode is `enforce` **and**
   `len(p.ReceiptPubkey) == 0`. Implemented in `buyer/server.go`'s checker using
   the same `store.SettlementConfig(...)` / `billing.VerifiedModelSettlementMode(...)`
   source of truth as `route_snapshot.go` so the two gates cannot diverge.
3. In `EligibleCandidates` first pass, after the model-version-floor check and
   before the context check, add:
   ```go
   if !checker.ProviderHasSettlementReceiptKey(p) {
       res.Counts[ReasonReceiptKeyMissing]++
       continue
   }
   ```

**Ordering:** after model-mismatch / version-floor, before context / tier2 / quota,
so the reason is attributed precisely and a receipt-key-missing provider never
consumes a quota slot.

## 5. Behaviour requirements

- **R-F1 (enforce excludes):** In `enforce` mode a provider with empty active
  `ReceiptPubkey` MUST NOT appear in `EligibleCandidates.Eligible`, and MUST be
  counted once under `receipt_key_missing`.
- **R-F2 (observe unchanged):** In `observe` (or when settlement store/config is
  absent) the predicate MUST return true for all providers — zero behaviour change,
  no new exclusions. Mirrors the `skipOrEnforceError` observe path.
- **R-F3 (429-vs-503 parity):** When *every* otherwise-eligible candidate is
  excluded solely for `receipt_key_missing`, the request MUST surface as a
  retryable **503 no_provider_available** (a transient supply condition), NOT a
  quota 429 and NOT a 500 `route_snapshot_failed`. Wire `receipt_key_missing`
  into the same all-candidates-filtered decision `server.go` already applies to
  `not_ready` / `warming`.
- **R-F4 (defence-in-depth retained):** `route_snapshot.go`'s empty-key
  `skipOrEnforceError("missing provider receipt key")` guard MUST remain; it is
  now unreachable on the happy path but stays as the fail-closed backstop.
- **R-F5 (observability):** `routing_decision` `filtered_counts` MUST expose the new
  `receipt_key_missing` reason so operators can see excluded supply.

## 6. Non-goals

- **Not** changing `stageReceiptPublicationLocked` / the pending→active promotion
  state machine (`pool/provider.go`). Why some providers never promote is a
  separate investigation; this fix stops routing burning requests on them
  regardless of cause.
- **Not** auto-disconnecting or demoting the affected provider.
- **Not** touching SPEC-022 / SPEC-015 normative text (no `contract_change`); this
  is an IMPL reconciliation to already-normative R-2 wording.

## 7. Test plan (`phase4-coordinator/internal/routing/filter_test.go` + checker tests)

1. Enforce + empty `ReceiptPubkey` → excluded, `receipt_key_missing == 1`, absent
   from `Eligible`.
2. Enforce + non-empty `ReceiptPubkey` → eligible (no new exclusion).
3. Observe + empty `ReceiptPubkey` → eligible (R-F2 no-op).
4. All candidates empty-key under enforce → `server.go` returns 503
   no_provider_available, not 429 / not 500 (R-F3).
5. Reason ordering: a provider that is both version-floor-blocked and key-missing
   is counted once, under the earlier (version-floor) reason.
6. Regression: existing `EligibleCandidates` cases unchanged (model_mismatch,
   quota, tier2) — no drift in `FilteredCounts` for keyed providers.

## 8. Governance declaration (for the PR body)

```
SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "yes",
  "contract_change": "none",
  "specs": ["SPEC-022"],
  "requirements": ["SPEC-022-R002"],
  "authority_domains": ["verified-model-settlement"],
  "arbitration": ["CODE_BUG"],
  "tests": ["phase4-coordinator/internal/routing/filter_test.go"],
  "journeys": ["not-required"],
  "issue": "TBD"
}
SPEC-GOVERNANCE-DECLARATION-END
```

`contract_change: "none"` is correct: no change to AUTHORITY.json / CONFORMANCE.json /
canonical SPEC-NNN — this reconciles IMPL to already-normative SPEC-022 R-2.4/R-2.5.

## 9. Audit + landing

- Run the three Codex audit lanes (code / security / architect) against the FULL
  diff of the fix; iterate to 0 CRITICAL / 0 HIGH / 0 MEDIUM before PR (LOW/INFO
  may ship documented in the PR body).
- Money-path → PR (not direct push). `ci-required` + 1 approving review are the
  merge blockers; `spec-index / check` is advisory.
