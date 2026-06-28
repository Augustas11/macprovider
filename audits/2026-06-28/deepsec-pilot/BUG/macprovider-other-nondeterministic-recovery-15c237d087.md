# [BUG] Malformed non-503 timestamps are recovered using the current time

**File:** [`phase4-coordinator/internal/billing/recovery.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/recovery.go#L112-L251) (lines 112, 114, 157, 251)
**Project:** macprovider
**Severity:** BUG  •  **Confidence:** high  •  **Slug:** `other-nondeterministic-recovery`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

When RecoverLedger cannot parse request_log.ts_utc, it substitutes time.Now().UTC(). That makes recovery nondeterministic and can select the wrong config snapshot/rate card for billing, or write quarantine rows with a recovery-time timestamp instead of failing or quarantining the malformed source row. The 503 path is filtered before parsing, but non-503 malformed rows can still be billed or classified using the wrong time.

## Recommendation

Treat malformed non-503 timestamps as a deterministic quarantine reason or fail the reconciliation run; do not substitute the wall-clock time for billing or snapshot selection.

## Revalidation

**Verdict:** true-positive

RecoverLedger selects non-503 request_log rows and then parses rl.ts_utc with time.Parse(time.RFC3339Nano). If parsing fails, the code assigns ts = time.Now().UTC() and continues instead of failing or quarantining deterministically. That substituted timestamp is then used for snapshotAtTx, HotPathInput.TSUtc, insertQuarantineTx, and insertRequestCreditTx, so the same persisted request_log row can use a different rate snapshot or quarantine timestamp depending on when recovery runs. The SQL status != 503 filter does preserve the intentional malformed-503 skip behavior, but it does nothing for malformed non-503 rows. Normal requestlog.Insert writes a valid formatted time.Time, so I did not find a public buyer/provider path that directly sets malformed ts_utc in current code. However, the schema stores ts_utc as unconstrained TEXT, recovery is explicitly for persisted ledger/request-log repair, and malformed legacy/manual/corrupt non-503 rows are handled nondeterministically today. This is a real recovery integrity bug with a narrower precondition than a remotely supplied timestamp.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-26)
