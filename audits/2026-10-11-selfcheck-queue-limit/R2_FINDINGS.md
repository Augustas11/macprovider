# R2 findings (PR #1960)

Code 0/0/2/0, security 0/0/1/1, architecture 0/0/1/1. All R1 findings
verified CLOSED except the grant-preservation point below.

- M (code 1, security 1): the pause check compared against the decision's
  slots, but an owner pin can serve above them (up to the verified width).
  Fixed: the current served count (`capacity.maxConcurrency`) is part of the
  prior grant the verified prefix is compared against.
- M (code 2; arch L2): `reconcile`'s no-gain backoff could push the
  incomplete-ladder re-measurement past 1 h. Fixed: the earlier of the two
  deadlines wins.
- M (arch 1): a completed queue-bounded ladder clamps a wider prior grant to
  its `verified_k`. Kept by design and stated in SPEC-038 FR-CB10 item 2: the
  ladder bound is configuration like the scheduler rows (which already cap a
  prior grant), item 4 forbids serving above `verified_k`, and a raised bound
  re-runs the ladder (`ladderBoundGrew`). Leaving the prior grant unverified
  indefinitely is the state #1958 reports.
- L (security 2): audit prompts named a local checkout path. Fixed: prompts
  use repository-relative wording.
