Change under audit: issue #1312 "First-run provider dashboard: single truthful status model (P0-P3)".
Branch fix/first-run-provider-ux, one squashed commit on top of current origin/main.
Full fix diff to review: audits/2026-09-01-first-run-ux-round5/full-fix.diff (also reproducible with: git diff origin/main..HEAD).

What it does:
- Adds a single P0-P3 ConsolidatedStatus model for the Malibu first-run dashboard (AgentSnapshot.swift consolidatedStatus), replacing ad-hoc first-run status strings.
- Honest reward telemetry: preserves the authoritative reward projection; classifies reward-telemetry outages instead of showing stale/optimistic numbers (ProviderEarningsClient.swift, EarningsClient.swift, ControlMetricsSnapshot.swift, MalibuAccrualClient.swift, MalibuAgent.swift).
- Honest outage classification + tone: network_offline/coordinator_unavailable classified as needs-attention (never settingUp); interruption vs first-run distinction; blocker ordering.
- Trust-criteria back-compat.

Critical integration fact: this branch was rebased onto a main that now contains the #1199 diagnostics work (#1318/#1319/#1320): ProviderDiagnosticFindingAggregator, publicStatus() enriched with publicStatusForTopDiagnosticFinding, and a repair fence in canRepairProviderSoftware (repair is evidence-only until the provider serve advertises capability "provider_software_repair_from_protected_source_v1"). consolidatedStatus delegates to publicStatus, so it consumes diagnostics findings and must preserve the fence.

Money-path sensitivity: reward/earnings telemetry is money-adjacent. Verify no optimistic/stale reward or "unlocked/withdrawable" claim is shown while blocked/degraded/capped/held, and that the authoritative projection is never overwritten by a telemetry-outage placeholder.

Validation already done locally: Malibu app xcodebuild test = 526 tests, 0 failures (incl. MalibuAgentDiagnosticsTests fence, DashboardViewTests, AgentSnapshotPresenterTests). CLI ControlMetricsBuilderTests + ProviderEarningsClientTests = 17/17.

Report findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Merge bar is 0 CRITICAL / 0 HIGH / 0 MEDIUM. For each finding give file:line, the concrete failure scenario, and a fix. If you find nothing at C/H/M, say so explicitly.
