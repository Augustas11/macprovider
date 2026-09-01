# CONTRACT / TRUST-INTEGRITY Audit Result

Scope: `audits/2026-08-30-first-run-ux/full-fix.diff` plus the contract, app
consumer, coordinator reward criteria, and SPEC-026 files named in
`LANE_contract.md`.

## Findings

### MEDIUM - Trust criteria buckets can display false completed criterion names

File: `phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift:1832`

Concrete scenario: `trustCriteria(_:)` reduces the coordinator's SPEC-026
criterion IDs to two booleans:

- `economicDone = !s.economicCriteria.isEmpty`
- `additionalDone = !s.additionalCriteria.isEmpty`

It then renders those buckets as `Verified customer work` and `Time online`
at `AgentSnapshot.swift:1849` and `AgentSnapshot.swift:1855`. This is only
faithful for the E1/A1 happy path. Per `phase4-coordinator/internal/rewards/unlock_types.go:7`,
`unlock.go:131`, and SPEC-026 section 5.2, the economic slot can also be E2
(wallet holds at least 100 USDC for 72h) or E3 (manual operator promotion),
and the additional slot can also be E1/E2/E3 as a second distinct economic
criterion, A3 (wallet balance 72h), or A4 (App Attest). A provider satisfying
E2+A4 with zero verified receipts and no 72h uptime would see checked rows for
`Verified customer work` and `Time online`, neither of which is true. The same
mislabel can happen for E3/A3 and other valid SPEC-026 pairs.

This violates the lane requirement that the app cannot show a provider as
meeting a criterion it has not met. The current tests only exercise E1 plus a
pending additional row (`AgentSnapshotPresenterTests.swift:1398`) and do not
cover E2/E3/A3/A4.

Remediation: render criteria from the actual IDs, or make the two rows generic
buckets that do not assert a specific satisfied condition. For example, show
`Economic criterion` with detail derived from E1/E2/E3 and `Additional
criterion` with detail derived from A1/A3/A4 or second distinct economic IDs.
Do not mark `Verified customer work` done unless E1 is present, and do not mark
`Time online` done unless A1 is present. Add tests for E2+A4, E3+A3, and E1 as
the second/additional criterion.

### MEDIUM - Reconstructors can silently emit a fresh frame with defaulted trust details

File: `phase3-binary/Sources/macprovider-cli/ProviderEarningsClient.swift:324`

Concrete scenario: `ProviderEarningsSummary.from(accrual:)` builds a
`malibuProjectionFresh: true` provider earnings frame from
`MalibuAccrualSummary`, but it does not carry the new
`economicCriteria`, `additionalCriteria`, `verifiedReceiptCount`, or
`appAttested` fields. The coordinator's accrual endpoint already emits those
authoritative fields at `phase4-coordinator/internal/rewards/endpoints.go:104`,
but `MalibuAccrualSummary` does not decode them, so the frame defaults to empty
arrays and nil counters. If the normal wallet-status fetch is unavailable,
schema-failed, or not configured, the app receives a fresh MALIBU projection
with trust counts/tier but no granular criterion details and can render the
new criteria disclosure as incomplete or generic despite the coordinator
having supplied the true IDs.

The same defaulting risk exists in `markingWalletStatusUnavailable()` at
`ProviderEarningsClient.swift:298`: it preserves the old aggregate
`trustCriteriaMet` and `trustCriteriaRequired` fields but omits the new
constructor arguments, so any previously carried granular fields are dropped
when the wallet-status path fails closed.

This is a contract-compatibility problem rather than a crash: old app/new CLI
and new app/old CLI decoding remain tolerant, but a new CLI can silently drop
the new optional fields on valid reconstruction paths while still marking the
projection fresh.

Remediation: extend `MalibuAccrualSummary` to decode the four optional fields
the accrual endpoint already emits and pass them through
`merging(accrual:)`/`from(accrual:)`. Also pass the current
`economicCriteria`, `additionalCriteria`, `verifiedReceiptCount`, and
`appAttested` through `markingWalletStatusUnavailable()` so fail-closed wallet
status does not erase already-known display-only criteria. Add tests for the
accrual-only producer path and the wallet-status schema-failure path after
granular criteria were present.

## Explicit Lane Checks

- Contract compatibility: decoder compatibility is good on the direct
  `provider_earnings` frame. Both CLI and app use `decodeIfPresent` plus safe
  defaults for the four new fields, and Swift `JSONDecoder` ignores unknown
  keys, so old app/new CLI and new app/old CLI do not crash. The findings above
  are about silent data loss/mislabeling on new-code paths.
- Other consumers: `rg` found `provider_earnings` consumption in the Swift
  CLI/app control-socket code and tests, plus unrelated config/test fixtures.
  No coordinator money path consumes the new nested frame.
- Money/settlement logic: no billing, settlement, quota, payout, coordinator,
  schema, or executable money-path files are changed by this diff. The changed
  Swift frame/app fields are display/relay only.
- Trust-label integrity: no normative tier labels were changed. The copy
  `Reaching Trusted unlocks MALIBU reward withdrawals. USDC earnings are
  unaffected.` is consistent with SPEC-026 section 5.1/5.2 and the current
  USDC provider earnings path. The criterion-name rendering is not faithful,
  as reported above.
- Calm-vs-alarm: genuine `state == .error`, `.idle`, `.paused`, executable
  recovery actions, and local block reason codes still map to `needsAttention`
  in `consolidatedStatus`. Non-network-ready providers do not take the
  warming-up branch. I did not find an outage/quarantine/not-admitted state
  recolored calm by this diff.
- Sensitive data: the new fields are criterion IDs, counts, and booleans.
  They do not expose tokens, private keys, wallet secret material, or new
  address fields. No new logging of these fields was introduced.

## SPEC-026 Status

No SPEC-026 normative change is needed. The implementation should be corrected
to display and relay the existing SPEC-026 criterion IDs faithfully.

## Validation

- Read `audits/2026-08-30-first-run-ux/full-fix.diff`.
- Inspected the named Swift producer/consumer/presenter files, control-socket
  encode/decode paths, reward coordinator endpoints, `unlock_types.go`,
  `unlock.go`, and SPEC-026 section 5.1/5.2.
- Ran `swift test --filter ProviderEarningsClientTests/testWalletStatusMergeForwardsAndEncodesTrustCriteria` from `phase3-binary`: passed, 1 test.
- Attempted `swift test --filter AgentSnapshotPresenterTests/testTrustCriteriaRenderByNameWithDoneAndPending`: SwiftPM reported no matching test cases, so this is not counted as passing evidence for app-side tests.

GATE: FAIL
