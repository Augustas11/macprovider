# Design — re-scope #1312 into slices; Slice A = typed reward-verdict contract (v2)

v2 incorporates two adversarial reviews (fable-5 critic: REVISE; codex: REQUEST CHANGES).
Both agreed the direction is right and both flagged the same gaps: the boundary was too
narrow, the verdict conflated distinct authorities, and invariant #1 would regress legacy
Trusted users. v2 fixes those.

## Root cause (unchanged)
`consolidatedStatus` re-derives reward/trust truth from raw booleans (`trustTier`,
`malibuProjectionFresh`, `providerEarningsFresh`, `malibuWithdrawable`, `executableAction`)
instead of consuming one authoritative verdict. Rounds 5→6→7 patched one leak each; the next
round found another. Fix the shape.

## The three slices
- **Slice A (this design): typed reward-verdict contract** — one computation produces a
  SEMANTIC verdict; every money-path presenter surface projects from it. Own audit.
- **Slice B: CLI money-path merge fixes** — wallet `schema_version` drift wiping a fresh
  accrual (`ControlMetricsBuilder`/`ProviderWalletStatusSummary`); and the CLI→app
  back-compat bridge that loses legacy trust-criteria field presence (empty-vs-absent
  granular arrays, driving `hasGranularTrustCriteria`). Independent of A.
- **Slice C: P0–P3 presentation** on the Slice-A verdict. **Requires B** (or explicit
  end-to-end absent/empty/overlapping-E2/A3 trust-criteria tests), because C's trust
  rendering depends on the bridge integrity B fixes.

## Slice A — design (v2)

### One semantic verdict, computed once, consumed everywhere
Add `rewardVerdict(_ s:) -> RewardVerdict`, computed ONCE. It carries SEMANTIC fields
(enums/flags), NOT rendered copy:

```
struct RewardVerdict {
    enum MalibuWithdrawal { case unlocked, held(reason), capped(reason), lockedProvisional,
                                 epochDisposition(reason), unavailable, unknown, none }
    enum UsdcActivity     { case earning, idle, unavailable, none }
    enum TrustDisplay     { case trustedAuthoritative, trustedStaleNeutral, provisional, unknown }
    let reasonCode: ReasonCode           // enum, closed set + .unknown(String)
    let malibuWithdrawal: MalibuWithdrawal
    let usdcActivity: UsdcActivity
    let trustDisplay: TrustDisplay
    let trustProgress: (met: Int, required: Int)?   // sanitized (distinctPairProgress)
    let canClaimWithdrawable: Bool       // derived; == (malibuWithdrawal == .unlocked)
    // NO rendered strings here. A single renderer maps this -> copy for each surface.
}
```

Two authorities are modeled separately (codex HIGH): MALIBU withdrawal/reward authority
(`malibuWithdrawal`, `trustDisplay`) vs USDC activity (`usdcActivity`). Neither infers the
other. A single renderer produces label/meaning/nextAction per surface from the verdict.

### Single-computation topology (fable H2 — mandatory, not an open question)
`rewardVerdict` is the ONLY place reward/trust truth is decided. Everything else projects:
- `miningHealth(_:)` → derives its reward `reasonCode`/summary from the verdict (its
  availability front-half — idle/paused/error/battery/thermal — either stays or moves to
  the availability layer; DECIDE and document, since local blocks currently read
  `providerEarningsFresh` via `miningSkipCount` — fable finding, assign that read to one layer).
- `consolidatedStatus(_:)` → thin mapper from the verdict + a typed availability class.
- Menu bar (`MenuBarController.swift:171`), dashboard reward/trust rows
  (`DashboardWindow.swift:264,493`: `rewardSummary`, `trustSummary`, `malibuHoldLine`,
  `eligibilityLine`, trust disclosure, the provisional-lock color at :269) → all project
  from the same verdict. No surface reads raw reward booleans.

### Compiler-enforced boundary (both reviewers — replaces the grep test)
Raw reward inputs (`trustTier`, `malibuProjectionFresh`, `providerEarningsFresh`,
`malibuWithdrawable`, `malibuHeld`, `malibuHoldReasons`, `malibuRewardEligibility`,
`trustCriteriaMet/Required`, `economic/additionalCriteria`, `rewardTelemetryUnavailable`)
are readable ONLY by `rewardVerdict`. Enforce via a `fileprivate` reward-inputs accessor
so a new consumer cannot compile against the raw fields. The presenter mappers accept
`RewardVerdict` + a typed availability classification, NOT `AgentSnapshot`. `liveNextAction`
and `trustCriteriaAction`'s stale-counter fallback are DELETED — nextAction/trustProgress
come from the verdict.

### Invariants the verdict MUST guarantee (the normative spec → INVARIANTS.md)
1. **Withdrawable-honesty (leftover-exempt).** `malibuWithdrawal == .unlocked` (⇒ "unlocked"
   copy) iff: `malibuProjectionFresh ∧ ¬isRewardTelemetryUnavailable ∧ trustTier == .trusted
   ∧ malibuWithdrawable > 0 ∧ displayMalibuHoldReasons empty ∧
   (displayRewardEligibility == nil via the leftover-provisional exemption ∨
    withdrawalState == "withdrawable")`. The leftover-provisional carve-out
   (`shouldIgnoreLeftoverProvisionalLock`) is REQUIRED — a strict `!=nil && withdrawable`
   reading regresses legacy 1.8.102 Trusted earners. (fable H1 / codex M5; R6 Sec-M2)
2. **Trust-display authority.** `trustDisplay == .trustedAuthoritative` (⇒ "Earning · Trusted")
   iff `malibuProjectionFresh ∧ ¬isRewardTelemetryUnavailable ∧ trustTier == .trusted`. A
   stale Trusted tier reads `.trustedStaleNeutral` → neutral "Live" (never "Provisional",
   never "Trusted/unlocked"). A stale *provisional* tier stays "Live · Provisional" because
   provisional is the fail-closed decoder default (asymmetry is intentional). (R7 HIGH; fable L3)
3. **USDC vs MALIBU separation.** `usdcActivity == .earning` never asserts MALIBU unlock;
   requires `providerEarningsFresh` (no stale-amount inference). MALIBU outage never hides
   truthful USDC earnings. (R6 HIGH; codex H2)
4. **Independent freshness.** A fresh MALIBU verdict is honored regardless of
   `providerEarningsFresh`; the earnings-unavailable branch requires all of
   {`!providerEarningsFresh`, `!hasObservedProviderEarnings`, `!malibuProjectionFresh`}. (R6 M(a))
5. **Authoritative precedence.** Held/capped/epoch-disposition (incl. `held_epoch_disposition`)
   outranks raw tier/amount (SPEC-021). (R5 H2)
6. **Explicit outage outranks calm.** An explicit `rewardTelemetryUnavailable` (or a fresh
   verdict with `withdrawalState == "unavailable"`) outranks the "warming up / No earnings yet"
   first-run copy, even with a fresh USDC frame. (fable M3; R5/R7 fail-closed rule)
7. **Closed reason set.** `reasonCode` is an enum; an unrecognized coordinator reason is
   `.unknown(String)` and maps to a defined neutral presentation, never a silent default. (M2)
8. **`.earning` phase semantics (defined).** `phase == .earning` ⇔ `trustDisplay ==
   .trustedAuthoritative` (tier-standing, not activity) — pick and test, since phase feeds
   badge/analytics. (fable M1)

### Frame-ingestion invariants (Slice B territory — NOT verdict guarantees)
- Legacy all-zero stub demotes `providerEarningsFresh`/`malibuProjectionFresh` (tests stay at
  `MalibuAgent` level). (R5 H1; fable M4)
- Slice A's honesty is CONDITIONAL on frame integrity: a wrong `hasGranularTrustCriteria`
  (empty-vs-absent) makes a correct verdict render "0 of 2" dishonestly. Fixed in Slice B.

### Availability/diagnostic layer (kept explicit)
- `primaryDiagnosticFinding(_:)` = the finding `publicStatus` actually surfaced (contract:
  "diagnostic surfaced by publicStatus", stated — not a separate classifier; fable L1/codex 6).
  Classify by signature: `.autoupdateInProgress` benign → `.live/neutral`; every other
  surfaced primary diagnostic (incl. action-less) → `.needsAttention`. (R6 M(b), R7 M)
- A non-diagnostic executable action on a network-ready provider is nonblocking (don't
  special-case action types); on a non-ready provider it accompanies a real problem. (R7 M)
- `.settingUp` only for genuine initial states; `isTemporarilyNotBuyerServing` → `.needsAttention`.
- Redaction: unknown criterion IDs render "additional requirement", never raw.

## Acceptance criteria (Slice A)
- No raw reward-boolean read is reachable from ANY network-ready presentation path — presenter
  helpers AND SwiftUI views included — enforced by the compiler boundary (fileprivate inputs),
  verified by review + a boundary test.
- Regression tests for invariants #1–#8, PLUS the crafted-frame cases from the audit corpus:
  stale-demoted Trusted; USDC-fresh + MALIBU-absent; accrual-only; `held_epoch_disposition`;
  Trusted + leftover-provisional-hold; overlapping E2/A3; action-less blocking diagnostic;
  explicit outage + fresh USDC.
- Malibu app xcodebuild green; dishonest-claim tests updated to honest expectations.
- 3-lane codex audit over the full Slice-A diff: 0 C/H/M.

## Sequencing
- Slice A first. Slice C requires B (or explicit bridge tests). Slice B independent of A.
- Distill the round-5/6/7 audit corpus into a committed `INVARIANTS.md` as the normative
  artifact the Slice-A audit prompts reference (the raw corpus doesn't state the
  leftover-provisional exemption as an invariant).

## Review disposition
- Direction: endorsed by both reviewers. HIGHs folded in (boundary→compiler-enforced +
  all surfaces; two-dimension semantic verdict; single computation; leftover-provisional
  invariant; Slice B gates C). MEDIUM/LOW folded (outage invariant #6, enum reasonCode,
  phase semantics, provisional-stale asymmetry, primaryDiagnostic contract wording).
