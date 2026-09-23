# Adversarial plan review — issue #1693 (pricing through the catalog-content lane), MONEY PATH

Method constraint: this is a first-party software-correctness / design-proof review. Do NOT author or
construct malformed payloads or exploit inputs. Evaluate by reading source in this worktree and, if useful,
running EXISTING tests. Describe gaps abstractly (component + condition + consequence) in prose.

Worktree: the current directory (branch stacked on PR #1706 = #1688 catalog-content lane, HEAD 5c05b2e2).
Plan under review: `.omc/plans/issue-1693-plan.md`. Issue text: "Pricing corrections through the
catalog-content lane (MoneyTable-A overlay in same SIGHUP)" — acceptance: SPEC-005+SPEC-023 lockstep
amendment; pricing-only content release activates with no runtime release; MoneyTable-A parity holds before,
during, after and on rollback; tests for parity mismatch refused pre-mutation, half-applied HUP rolls back feed
and yaml together, billing snapshot consistent across forward and rollback; 3-lane audit 0 C/H/M.

You are an adversarial verifier. Try hard to REJECT the plan. Verify every "Verified fact" F1-F10 against the
code (cite file:line; flag any that are wrong). Then hunt for design defects, especially:
- any instant (disk or in-memory, boot or SIGHUP, forward/rollback/crash/interrupt/lease loss) where the
  money table RateFor uses can disagree with the served signed rate card, or a request can be priced at a
  table that was never reviewed;
- the splice of `rewards.rate_card` in the live base yaml: boundary detection, YAML parser differences
  (PyYAML vs yaml.v3), comments, preserving everything else, owner/mode, other writers of that file
  (deploy-pearl-vps.sh, pearl-updater, renew, manual edits, payout SIGHUP listener);
- the transaction journal / CAS / rollback / recovery: completeness, ordering, fsync, what if rollback itself
  fails, what the other lanes do while a journal exists;
- billing snapshot accounting (ledger_config_snapshots on every HUP), the applied-config record additions,
  evidence sufficiency, and whether the dry-load truly proves the reload will accept;
- content-gate scope (what counts as pricing vs globals), interaction with renewal continuity, window /
  previous releases, deploy preserve-live / apply-tracked, tracked dist/coordinator.yaml;
- spec/governance: whether SPEC-005 §5.6 / SPEC-023 §3.3.1 rule 9 / R008 / #1706's R013-R017 are respected,
  and whether the alternatives were rejected for sound reasons;
- missing tests for the acceptance criteria.

Output format (strict):
- One line per finding: `[CRITICAL|HIGH|MEDIUM|LOW] <id> <title>` then evidence (file:line) and a concrete
  required plan change.
- Then a final line exactly: `VERDICT: <APPROVE|APPROVE-WITH-CHANGES|REJECT> C=<n> H=<n> M=<n> L=<n>`

Round 10: the plan is now v10 (header lists dispositions for every prior round; W1 was redesigned to use frozen per-request ledger credits). Independently verify closure of R9-01..03 and hunt for NEW defects introduced by v10. Attribution discipline: NEW vs PRE-EXISTING; PRE-EXISTING is at most MEDIUM unless the plan makes it materially worse, and only if it concretely affects pricing correctness for this lane. Severity: HIGH/CRITICAL only for a concrete path to mis-billing, unreviewed pricing, or unrecoverable/unsafe state; MEDIUM for concrete evidenced correctness gaps; LOW for precision/wording. No scope/style inflation.
