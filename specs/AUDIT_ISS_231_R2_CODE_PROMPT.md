# Audit: ISS-231 R2 code lens — verify R1 fixes

R1 returned 0/0/2/0 (code). R2 verifies on commit `0d96a03`. Tree:
`spec/iss-231-spec-007-v04`. `git log --oneline -5`.

## R1 findings to verify

- **MEDIUM-1**: forensic audit row carried incomplete list on
  unbounded-query failure with no degraded flag. Fix: storage
  helper renamed + bounded at `ExplorerForensicMatchedAccountIDsCap+1`;
  payload's `forensic_truncated_at` field surfaces partial capture
  when scan hit the cap. On ferr, we still degrade to the bounded
  probe (`accountIDs`) BUT no incomplete-marker — re-verify.
- **MEDIUM-2**: `quotedCSV` replaced with `json.Marshal`. Both the
  truncation forensic emit AND the deprecation WARN payloads now
  go through `json.Marshal`. Coordinator side uses `json.Marshal`
  too (replacing Go `%q`).

## What I want (R2 code lens)

- Verify the storage→handler contract: when the forensic scan hits
  cap+1, does the handler correctly set `forensic_truncated_at`?
  When it returns ≤cap rows, does the handler skip that field?
- json.Marshal error returns — is the silent-skip on
  `json.Marshal` failure acceptable for the audit emit (it's
  best-effort) AND for the deprecation WARN coordinator-log
  payload (currently `payload, _ := json.Marshal(...)` then
  `stdLog.Println(string(payload))` — empty payload on error?
- ferr-fallback path still risks emitting an incomplete list as
  `event_payload.matched_account_ids` without a marker; does the
  payload need to distinguish "we got len ≤ cap because that's
  all there is" vs "we got len ≤ cap because the unbounded query
  errored"?

End with `## Convergence X/X/X/X → DECISION`.
