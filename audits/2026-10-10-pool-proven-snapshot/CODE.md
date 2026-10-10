Lane: CODE REVIEW, focus CORRECTNESS OF THE COUNT. Compare the new counting
predicate with the old query line by line (join keys including account scope and
route_snapshot_digest, policy version, enforce mode, payable outcome incl. the
relay-blind branch, verified label, positive gross and provider credits, finality
window, ORDER/LIMIT/ceiling). Check the high-water-mark capture for missed or
double-captured snapshots (commit order vs id order across the 4-connection
route-snapshot writer pool and the journal materializer; INSERT OR IGNORE;
cursor monotonicity; first-pass catch-up across passes). Check the
re-evaluation freeze rule (rows whose stored finality is before the window start
are never re-read): can a verdict's finality time move forward, or a non-counted
row become counted with finality in a later window? Check NULL/bool scanning,
change detection, empty table, version reset, context cancellation mid-pass, and
the tests' adequacy.
