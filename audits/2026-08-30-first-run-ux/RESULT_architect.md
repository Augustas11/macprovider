# Architecture / UX-Coherence Audit Result

Scope reviewed: `audits/2026-08-30-first-run-ux/full-fix.diff`,
`AgentSnapshot.swift`, `DashboardWindow.swift`, `EarningsClient.swift`,
`MalibuAgent.swift`, and `ProviderEarningsClient.swift`.

## Findings

### 1. SEVERITY: MEDIUM

file: `phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift:1832`

Design risk: the trust-criteria disclosure treats `additionalCriteria` as a
single boolean and always renders it as "Time online" (`additionalDone =
!s.additionalCriteria.isEmpty`, then title `"Time online"`). That is not the
coordinator contract. The coordinator can satisfy multiple additional criterion
IDs: `A1` uptime, `A3` wallet balance, `A4` app attestation, and it also appends
`E1` into the additional bucket when receipt count reaches the threshold
(`phase4-coordinator/internal/rewards/unlock.go:131`). A common provider state
with 100 verified receipts and no uptime/app/wallet additional criterion can
therefore render both "Verified customer work" and "Time online" as done while
`trustLine` still says only 1 of 2 criteria are met. A provider satisfying app
attestation or wallet-balance can also be mislabeled as having completed time
online.

Recommended direction: map criterion IDs explicitly instead of booleanizing the
bucket. Only mark "Time online" done when `A1` is present; render `A3` and `A4`
under their own labels or use a generic "Second independent trust criterion"
row with ID-specific details. Ideally have the coordinator expose the exact
pending/display criteria or the selected unlock pair so the app does not
reimplement distinct-pair semantics.

### 2. SEVERITY: MEDIUM

file: `phase3-binary/app/Sources/Malibu/Dashboard/DashboardWindow.swift:126`

Design risk: the dashboard still has multiple independently-derived status
surfaces. The new card uses `consolidatedStatus`, but the header keeps using
`dashboardSubtitle`, `dashboardHeadline`, and `color(for: agent.snapshot.state)`
at lines 126-136. Those functions still derive from `publicStatus` and raw
state (`AgentSnapshot.swift:1185`, `AgentSnapshot.swift:1198`). For a
network-ready provider blocked by battery or thermal skip reasons, the
consolidated card can say "Blocked locally" with `needsAttention` tone while
the header still says "Provider is ready" and paints the serving state green.
For the new first-run no-telemetry path, the card avoids alarm wording, but the
header subtitle can still say "Ready for customer work - earnings unavailable"
(`AgentSnapshot.swift:1203`).

Recommended direction: make the header consume the same `ConsolidatedStatus`
display model for label/subtitle/tone, or remove the header status headline and
leave only identity/model chrome there. If `publicStatus` must remain for menu
bar or recovery, keep it out of the first-run dashboard status chrome unless it
is the backing source for `consolidatedStatus`.

### 3. SEVERITY: MEDIUM

file: `phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift:1034`

Design risk: `consolidatedStatus` only promotes three mining reason codes
(`local_on_battery`, `local_thermal_pressure`, `local_model_preparing`) into
`needsAttention`. Other reachable reward blockers from `miningHealth` and
`reward_eligibility` are ignored by the top-level model. A trusted provider
with provider/wallet daily cap, a generic hold, compute-integrity block, or
provider-token untrusted state can still get the top-level label
"Earning - Trusted" and meaning "MALIBU withdrawals are unlocked" because the
function branches only on `trustTier` after the local-block check. The concrete
next action from `miningHealth` is then dropped because `DashboardWindow.swift`
renders only `status.nextAction` at line 501, not `mining.nextAction`.

Recommended direction: derive the consolidated card from the same normalized
reward/mining reason model used by `miningHealth`, not just from trust tier.
Carry the single next action for capped, held, ineligible, unavailable, and
local-block states into `ConsolidatedStatus`, and make `phaseTone` a pure
mapping of that same model. Trusted should only say withdrawals are unlocked
when `reward_eligibility.withdrawal_state` is withdrawable or there is no
current withdrawal-blocking verdict.

### 4. SEVERITY: LOW

file: `phase3-binary/app/Sources/Malibu/Agent/EarningsClient.swift:124`

Design risk: reward reason vocabulary is mirrored manually in the app and CLI
models, and it is already behind the coordinator/spec surface. The coordinator
defines valid epoch-disposition reasons (`held_epoch_disposition`,
`excluded_epoch_disposition`, `burned_or_retired_epoch_disposition`) in
`phase4-coordinator/internal/rewards/read_model.go:31`, but the app-side
`allowedReasons` set does not include them. A valid current
`malibu_reward_eligibility.v1` frame carrying one of those reasons will be
collapsed to generic unavailable copy via schema-drift handling.

Recommended direction: add a contract test that round-trips every coordinator
reason through the app decoder, or generate/share the reason vocabulary instead
of maintaining parallel hand-written lists. Unknown future reasons should still
fall back safely, but known v1 reasons should not be treated as drift.

## Tradeoff Judgment

Adding the new trust-criterion fields to the provider earnings/control-socket
frame is acceptable for this app architecture. Malibu does not own the provider
bearer, and the same-user CLI control socket already carries non-secret
provider-visible earnings and reward projections. The coupling is display-heavy
but not a layer violation as long as these fields remain read-only projections
from coordinator-owned eligibility inputs and are covered by wire round-trip
tests.

GATE: FAIL
