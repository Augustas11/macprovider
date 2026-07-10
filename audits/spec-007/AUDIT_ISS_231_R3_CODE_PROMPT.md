# Audit: ISS-231 R3 code lens — verify R2 fix-pass

R2 returned 0/0/1/0 (code). R3 verifies on `e831c52`. Tree:
`spec/iss-231-spec-007-v04`. `git log --oneline -6`.

## R2 code finding to verify

- **MEDIUM**: ferr-degraded forensic indistinguishable from real
  "exactly cap+1" case. Fix: storage carries
  `MatchedAccountIDsForensicDegraded bool`; handler emits
  `forensic_source: "response_probe"` on degraded vs
  `"forensic_select"` on healthy.

Expect 0/0/0/N. Look for any remaining defect introduced by the
rename or the forensic_source marker. Confirm:

- Field rename `Untrimmed → ForensicSample` complete across
  storage + router + tests.
- New TestExplorerAccountIDsForRequest_ForensicCapAtN101 seeds 105
  rows and asserts forensic-sample len == cap+1.
- payload `forensic_source` distinguishes both paths.

End with `## Convergence X/X/X/X → DECISION`.
