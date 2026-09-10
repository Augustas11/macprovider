# Reward Verdict Invariants

Slice A owns the app-side typed reward-verdict contract for existing money-path
surfaces. It does not implement the consolidated-status card from Slice C
(#1323), and it does not repair CLI wallet/bridge frame integrity from Slice B
(#1322). Frame-ingestion honesty remains conditional on `MalibuAgent.swift`
preserving the existing legacy-stub demotion rules.

`AgentSnapshotPresenter.rewardVerdict(_:)` is the only place MALIBU
earning, withdrawal/trust truth and USDC activity truth are decided. Dashboard and menu
bar surfaces must project from `RewardVerdict`; raw reward inputs stay behind
the `AgentSnapshot` fileprivate access wall.

1. Trusted legacy snapshots can carry leftover provisional lock metadata.
   Normalize only raw provisional/demotion metadata accompanying a fresh,
   coherent authoritative withdrawable projection with zero held balance.
   Never discard authoritative held/capped states or positive historical held
   balances after promotion (SPEC-021 §3). No client action clears ledger holds.
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
9. Earning and withdrawal are independent coordinator-owned axes. An earning
   reason (including runtime telemetry unavailable) cannot override coherent
   ledger withdrawal facts. Unknown schema/reasons and malformed whole
   projections remain unavailable. A withdrawable string alone is insufficient:
   schema, reason membership, trust, wallet, balance, holds and freshness apply.
10. Withdrawal eligibility is not an executable payout or completed payment.
    Serving readiness and USDC activity cannot prove current MALIBU earning.
