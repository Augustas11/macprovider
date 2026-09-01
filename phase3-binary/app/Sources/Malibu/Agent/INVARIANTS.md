# Reward Verdict Invariants

Slice A owns the app-side typed reward-verdict contract for existing money-path
surfaces. It does not implement the consolidated-status card from Slice C
(#1323), and it does not repair CLI wallet/bridge frame integrity from Slice B
(#1322). Frame-ingestion honesty remains conditional on `MalibuAgent.swift`
preserving the existing legacy-stub demotion rules.

`AgentSnapshotPresenter.rewardVerdict(_:)` is the only place MALIBU
withdrawal/trust truth and USDC activity truth are decided. Dashboard and menu
bar surfaces must project from `RewardVerdict`; raw reward inputs stay behind
the `AgentSnapshot` fileprivate access wall.

1. Trusted legacy snapshots can carry leftover provisional locks from 1.8.102.
   When a fresh Trusted snapshot has withdrawable MALIBU and only leftover
   provisional hold evidence (`trust_tier_provisional`,
   `demotion_cooldown`, `held_provisional_trust_tier`, or
   `held_demotion_cooldown`), the verdict must ignore that stale lock and
   allow withdrawable MALIBU.
2. Stale Trusted trust telemetry is neutral `Live`. It must not render Trusted,
   earning, withdrawable, or unlocked MALIBU.
3. USDC earning is separate from MALIBU withdrawal. Earning requires fresh
   provider earnings evidence and must not imply MALIBU unlock.
4. Provider-earnings freshness and MALIBU-projection freshness are independent.
   Fresh MALIBU verdicts can render while USDC projection is stale, and fresh
   USDC can render while MALIBU projection is unknown.
5. Explicit coordinator non-withdrawable reasons outrank raw amounts. Held,
   capped, and epoch-disposition reasons must prevent withdrawable/unlocked
   copy even if an amount field is positive.
6. Explicit reward telemetry outage outranks calm warming-up/no-earnings copy.
7. Coordinator reason handling is closed over known semantic cases and retains
   `.unknown(String)` for future non-rendered semantics.
8. Trust progress is sanitized before rendering. Granular economic/additional
   criteria count distinct unlock slots, while legacy counters are clamped.
   Slice C owns phase-card rendering; Slice A must not add it.
