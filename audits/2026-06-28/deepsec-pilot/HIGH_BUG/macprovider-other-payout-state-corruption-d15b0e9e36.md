# [HIGH_BUG] Payout can be irreversibly consumed without external payout evidence

**File:** [`phase4-coordinator/internal/billing/payout.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/payout.go#L28-L37) (lines 28, 30, 36, 37)
**Project:** macprovider
**Severity:** HIGH_BUG  •  **Confidence:** high  •  **Slug:** `other-payout-state-corruption`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

ClaimPayoutReady transitions a ready payout to consumed when the gross amount matches, but it does not require payoutExternalID or payoutCurrency to be non-empty. Because nullString converts empty strings to NULL, a caller can permanently consume a payout row with no external transaction id and/or no currency. The terminal-status trigger then prevents repairing the status, leaving a payout that appears consumed but cannot be reconciled to an external rail.

## Recommendation

Reject empty payoutExternalID and payoutCurrency before the UPDATE. For the current payout rail, enforce the canonical currency value expected by the caller, or at minimum require non-empty strings and add tests for empty values.

## Revalidation

**Verdict:** true-positive

ClaimPayoutReady validates that the payout exists, is ready, and has the expected gross amount, but it does not validate payoutExternalID or payoutCurrency before the UPDATE. It passes both values through nullString at lines 36-37, and nullString converts empty strings into sql.NullString with Valid=false. The ledger_payout_ready schema explicitly allows payout_currency and payout_external_id to be NULL while status can become consumed. The terminal-status trigger prevents moving a consumed row back to ready or voided, and ClaimPayoutReady itself cannot be called again because the row is no longer status='ready'. I found no current production endpoint directly exposing this method outside tests/spec consumers, so this is an API-level money-out primitive bug rather than a remote unauthenticated path. It is still real for any payout rail or operator caller: passing an empty tx id or currency can mark funds as consumed without durable external payout evidence.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-01)
