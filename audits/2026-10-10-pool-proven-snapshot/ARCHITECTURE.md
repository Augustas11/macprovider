Lane: ARCHITECTURE REVIEW, focus FIT WITH RETENTION (#1909) AND THE SPEC. Read
PR #1909's branch `origin/campaign/1793-sqlite-retention` (evidence_retention.go,
the payable-view change, settlement_finality.go) only as context. Does the rollup
keep R012 counts exact once retention deletes settled snapshot/verdict/output
rows, including partial deletion across batches? Is the "keep stored state when
evidence is gone" rule sound given retention only archives settled, finality-
closed requests? Is rebuildability adequate (version bump rebuilds from hot rows
only)? Does the design conflict with #1909 (triggers, view, compat floor,
incremental vacuum, rowid reuse after deletion with AUTOINCREMENT)? Does the read
/write handle split in server.go keep test and production wiring correct when the
route-read store is absent? Is the SPEC-047 R012 text (R009 limits: 10 s query
timeout, 100 000 ceiling, no partial snapshot, materialized every 15 minutes and
at startup) still satisfied, or does the 5-minute refresh budget need a SPEC
amendment? Is CONFORMANCE.json mapping accurate?
