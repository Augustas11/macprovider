# Audit: ISS-165 R3 security lens — verify R2 fixes

R2 returned 1 HIGH (SEC, convergent with code). R3 verifies on
commit `f0c5350`. Tree: `spec/iss-165-spec-016-followups`.

## R2 SEC findings to verify

- **HIGH** (convergent with code): scan cap saturation prefix-
  starvation. Fix: drop scan cap entirely; predicate-bounded SELECT.

## Security threat model (R3)

The R2 fix removes an explicit memory bound and trusts the WHERE
predicate. Adversarial questions:

1. Could an attacker (compromised operator key, malicious data
   ingest path) inflate the cancel-self-transfer + un-paged +
   stale-cutoff candidate set to millions of rows, causing OOM /
   slow scan / disk spill?
2. Is the SELECT's read-time-bounded by SQLite WAL or
   page-cache pressure? Could a huge scan starve other queries
   on the same DB handle?
3. Does the now-unbounded scan interact with the runner cycle
   timeout? Could a giant scan blow past the §4.3 cycle
   deadline?
4. Could the per-cycle WARN repetition itself become a journal
   DoS if backlog persists for hours? (Operator-DoS, not money-
   path.)
5. The `payout_spki_drain_skipped_unsupported_client` WARN is a
   new event but NOT yet in §7.1. Is that a config-drift class
   that could mask a real future bug? (Security-relevant because
   SPKI drain failure is a TLS pinning hardening regression.)

Find NEW security defects. Same severity + output format. End
with `## Convergence X/X/X/X → DECISION`.
