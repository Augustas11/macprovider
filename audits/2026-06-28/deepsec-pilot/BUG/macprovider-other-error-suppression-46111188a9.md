# [BUG] Read endpoint database errors are reported as zero or empty data

**File:** [`phase4-coordinator/internal/billing/endpoints.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/endpoints.go#L101-L574) (lines 101, 109, 427, 444, 450, 486, 489, 526, 550, 563, 574)
**Project:** macprovider
**Severity:** BUG  •  **Confidence:** high  •  **Slug:** `other-error-suppression`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

The h.sum helper returns 0 for any database error, and several endpoint helpers return empty/nil values on query or decode failures. /admin/ledger/summary can therefore return HTTP 200 with zeroed totals during a database failure, while /providers/{id}/earnings can return 404 or partial zero earnings instead of the required JSON error envelope with no ledger data.

## Recommendation

Use sumErr or typed helper methods that distinguish NULL aggregates from query failures, and propagate failures to writeError with an appropriate 5xx response. Keep zero defaults only for successful NULL aggregate results.

## Revalidation

**Verdict:** true-positive

The helper h.sum calls h.sumErr and returns 0 on any error at lines 486-490, conflating a real query failure with a successful NULL aggregate. /admin/ledger/summary builds every numeric field with h.sum and then unconditionally writes HTTP 200, so a database error can produce a zeroed summary instead of the standard error envelope. The provider earnings path uses h.sum for the provider-existence check, so a database error on COUNT can become a 404 provider not found. The same endpoint also uses h.sum for total/current/fault/share values, and helpers like modelsServed, rateCardExcerpt, and lastPayout return empty or nil data on query, scan, or JSON decode failure. Admin auth and provider-token checks still protect these endpoints, so this is not an auth bypass, but it is a real observability and reconciliation-integrity bug. The current code has no mitigation that distinguishes database failure from valid empty results on these read paths.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-26)
