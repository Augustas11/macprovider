# Audit summary — settlement receipt-key routing-gate exclusion

Branch: `fix/settlement-receipt-key-route-gate`. Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM
across code / security / architect lanes (codex, xhigh). Full-fix diff audited
(`origin/main` → HEAD), not incremental slices.

## Rounds

**Round 1** (commit `8e9624ea`)
- Convergent finding (architect HIGH×2, code HIGH, security MEDIUM×2): the receipt-key
  gate covered only `routing.EligibleCandidates`. Pinned (`validatePinnedProviderForRequest`)
  and slot-queue (`slotQueueCandidates`, `pollQueuedProvider`) paths re-derive
  eligibility by hand and bypassed it → empty-key provider selected then failed at
  the pre-dispatch guard (500) instead of excluded (503). Fail-closed integrity held.

**Round 2** (commit `a844b4b6`) — gate re-applied at all three paths (mirrors #768).
- Security: PASS, 0 findings all severities.
- Architect: 0 C/H/M; 1 LOW (observability).
- Code: 0 C/H; 1 MEDIUM — `receipt_key_missing` not surfaced on all-filtered 503 /
  queued failures (R-F5).

**Round 2 fix** (commit `72c8b276`) — shared `logReceiptKeyExcluded` event at every
exclusion site (mirrors `model_version_floor_excluded`); R-F5 updated; the
pre-existing "routing_decision not emitted on empty-candidate for ANY reason" gap
documented as out of scope.

**Round 3** (code lane only, per skip-passed-lanes) — APPROVE, 0/0/0/0/0. MEDIUM
resolved, no new defect.

## Final state: 0 C / 0 H / 0 M — all three lanes clean.

Carried: none above LOW. The empty-candidate `routing_decision` observability gap is
pre-existing, cross-cutting (all filter reasons), and out of scope; receipt-key
exclusions remain observable via the dedicated `receipt_key_missing_excluded` event.

Validation each round: `go test ./internal/routing ./internal/buyer` (incl. `-race`),
`go test ./...`, `git diff --check` — all passed.
