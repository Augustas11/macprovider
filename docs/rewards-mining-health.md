# Provider reward presentation

The existing Mining Health panel separates customer-serving readiness, MALIBU
earning, accrued/held balance, withdrawal eligibility, and USDC activity.
`AgentSnapshotPresenter.RewardVerdict` remains the shared dashboard/menu-bar
interpreter. An existing eligible balance does not prove current earning;
unavailable work verification does not erase that balance's eligibility.
Historical ledger holds survive a trust promotion.

Both coordinator reward endpoints use `BuildProviderRewardProjection`. The CLI
selects a complete accrual response first, with a coherent wallet response as a
fallback. It does not combine one endpoint's amounts with another's eligibility.
Unavailable refreshes demote MALIBU freshness while preserving explicitly
last-known app values. USDC freshness is independent. Older peers without the
new history capability are not sent the new control request.

Reward activity uses the existing provider-token-authenticated audit endpoint,
relayed through the owner-only local control socket. Activity is paginated and
includes occurrence time, source, and hold information. Activity events are not
unique economic credits: a credit and its hold can create multiple events, so
the app does not sum activity into period totals or verified-work counts.

Hardware classification uses the existing hardware verification owner, its
configured TTL, current trust roots, and immutable evidence/profile matching.
It does not use the capacity cache or pool hash status. Production compute
integrity classification is still unavailable; a future integration must match
the complete covered model/runtime/profile key and freshness before using a
result. One passing key must not become provider-wide trust.

SPEC-021 §4.2.1 defines recent verified-work observation from the verified
settlement mirror over 30 minutes. Missing observations remain uncertain because
the v0.2 mirror has no authoritative fresh watermark. Recent work is not a
receipt-lifetime counter, wallet-update timestamp, reward issuance, or completed
payment.

This iteration validates the existing permitted v0.2 useful-work path. It does
not implement v0.4 epochs, change production emission/payout defaults, activate
economic rewards, or implement MALIBU payment execution. The UI describes
withdrawal eligibility without promising an available payment runner.
