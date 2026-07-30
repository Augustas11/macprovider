# BUILD_SPEC — SPEC-026 IMPL Step 3: Onboarding UX polish + provider stats dashboard

Impl slice on top of #339 (SPEC v0.11) + #346 (coord) + #347 (App bundle).
Turns the already-shipped state machine into a real running-provider
experience: personalized earnings estimate during download, live stats
dashboard, thermal + queue-depth chips, wired GPU/latency metrics,
verified badge thresholds, live log tail, `.idle` copy fix.

**Nothing here needs new coordinator surface or new SPECs.** All work
composes with what SPEC-026 v0.11 + SPEC-005 earnings endpoint +
SPEC-023 rate-card + SPEC-025 already promise.

Path B (SPEC-016 §3 addendum for `provider_wallet_swaps`, SPEC-027
email OOB cancel, SPEC-028 MALIBU rewards emission ledger) is
explicitly deferred — DO NOT touch `setPayoutWallet()`, wallet-swap
cancel, or MALIBU withdrawable/locked splits here.

## Source of truth

- `specs/SPEC-026-browserless-provider-onboarding.md` v0.11
  - §6.1 step 8 success card (equal-visual-weight Add-wallet CTA,
    persistent MALIBU lock+microcopy in Provisional)
  - §6.2 steady-state invariants (menu-bar icon, persistent MALIBU
    lock, unclaimed-earnings badge $1/$10/$100 re-surface thresholds)
  - §6.4 error retry UX (retryable → Retry; non-retryable → Quit)
  - §7.5 onboarding state persistence (`onboarding.json` schema)
- `specs/SPEC-023-*` autotune rate-card locally-computed output
  (source of the personalized earnings estimate)
- `specs/SPEC-025-*` §3.2 menu-bar icon states, §11 metrics wiring
  gate (not blocking this slice — we surface what's already emitted)
- `specs/SPEC-005-*` earnings endpoint `GET /providers/{id}/earnings`
  (existing; used unchanged)
- Current App tree at HEAD `66f372e` — post-#347 state:
  - `phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift`
    (state machine complete, 412 lines)
  - `phase3-binary/app/Sources/Malibu/Onboarding/OnboardingWindow.swift`
    (OnboardingRootView with 10 stage renders, disabled Add-wallet)
  - `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift`
    (`snapshot: AgentSnapshot` 15s poll, control-socket metrics)
  - `phase3-binary/app/Sources/Malibu/Agent/EarningsClient.swift`
    (GET earnings; SPEC-005 endpoint)
  - `phase3-binary/app/Sources/Malibu/Agent/ControlFrame.swift`
    (GPU/latency parsed from `metricsResponse` frames, currently
    dropped on floor)
  - `phase3-binary/app/Sources/Malibu/MenuBar/MenuBarController.swift`
    (5-state icon + earnings badge + dismiss action)
  - `phase3-binary/app/Sources/Malibu/Dashboard/DashboardWindow.swift`
    (earnings card + disabled Add-wallet + `LogTailView` static
    placeholder)

## Scope IN — ordered impl items

### Item 1. Personalized earnings estimate during `.downloadingModel`

**Goal.** Replace the download-window dead time (longest single wait
in the flow, often 3–10 minutes) with a concrete "here's what you'll
earn" moment. Salad's proven pattern; adapts directly to Malibu.

**Copy.** Under the progress bar, a single secondary-tone line:

> `Llama-3.1-8B-Q4 on your M3 Max typically earns ~$X.XX–$Y.YY/day
> at current demand.`

- Chip name resolved via `sysctl hw.model` + Apple's chip lookup
  (existing helper — grep `chipMarketingName` or introduce one).
- Model name + quant from the current `.downloadingModel(name, pct)`
  state.
- Range from SPEC-023 rate-card output that autotune already computes
  locally. IF the rate-card output is not currently surfaced to the
  App target: expose it via a `AutotuneOutput` value type on the
  existing autotune pipeline (`RecommendedModel` or equivalent);
  DO NOT add new coordinator RPC.
- IF rate-card range is unavailable for any reason (missing feed,
  autotune degraded, etc.): omit the line entirely. Do NOT show a
  fake range or "estimated" placeholder — false precision harms
  trust more than absence.

**Placement.** Same NSWindow, same OnboardingRootView, same
progress-ring row. Renders only during `.downloadingModel` — hidden
in all other states.

**Files.** `Onboarding/OnboardingWindow.swift` (render), the
autotune output plumbing (source), possibly a new
`ChipMarketingName.swift` helper if none exists.

### Item 2. Full provider stats dashboard

**Goal.** Turn `DashboardWindow.swift` into the actual provider
control center. Today it shows only an earnings card + disabled
Add-wallet + static log placeholder. All fields below MUST be
visible when the provider is `.live`; each MUST degrade gracefully
to "—" when the source signal is absent (not to zero — SPEC-025
convention: zero = "0 served," "—" = "not yet reported").

Fields (menu-bar column below is item 5's summary; dashboard column
is the full-view):

| Field | Format | Refresh | Source | Menu-bar | Dashboard |
|---|---|---|---|---|---|
| Running model | `Llama-3.1-8B · Q4_K_M · 4.2GB` | on change | control-socket | chip line | chip line + weights-path expandable |
| Requests served (today / all-time / rate) | `142 today · 8,204 all-time · 3.1 req/min` | 10s | control-socket + local aggregate | today count only | full row |
| Tokens served (in / out, today / all-time) | `1.2M in / 3.8M out today` | 30s | control-socket | — | stacked bar chart or two nums |
| USDC earned (today / week / pending / lifetime) | `$4.12 today · $18.40 wk · $6.90 pending · $211.00 life` | 30s (today) / on-load (rest) | coord `GET /providers/{id}/earnings` | today | full row |
| MALIBU earned (today / all-time) | `12 MALIBU today (locked)` — persistent lock+microcopy in Provisional per §6.2 | 30s | coord earnings endpoint | today | full row |
| Trust tier + unlock path | `Provisional — 1 of 2 criteria met · Unlock Trusted →` | on tier event / poll | coord (§5.2 criteria if surfaced; else static tier only) | badge only | full row with criteria breakdown IF surfaced |
| Uptime (7d) / declines / restarts | `99.2% uptime (7d) · 3 declined · 1 restart` | 60s + local aggregate | control-socket + local | — | full row |
| Queue depth (item 3) | `0 queued` or `3 queued` chip | real-time push | control-socket (control-frame `queue_depth`) | dot when >0 | chip |
| Thermal state (item 4) | `Nominal` / `Throttled` chip | event-driven | IOKit thermal | dot when throttled | chip |

**No new coordinator surface.** IF a field's data is not currently
available from the existing endpoints + control-socket, that field
degrades to "—" in this slice and gets a `// SPEC-005 §N follow-up`
one-liner in code. DO NOT invent RPCs.

**Layout.** Dashboard split ~40% top-left earnings card (existing +
extended), ~40% top-right running-model + trust-tier card, ~20%
bottom log tail (item 6). No modal dialogs. Everything reactive to
`MalibuAgent.snapshot` on the `@MainActor`.

**Files.** `Dashboard/DashboardWindow.swift` (major expansion),
`Agent/MalibuAgent.swift` (new `AgentSnapshot` fields if needed,
strictly Optional to preserve "not reported" vs "0"),
`Agent/ControlFrame.swift` (parse + expose additional fields —
item 3 overlap), `Agent/EarningsClient.swift` (extend fetch to
capture week/pending/lifetime if endpoint already returns them;
else degrade to "—" and leave a follow-up comment).

### Item 3. Wire control-frame GPU / latency / queue-depth off floor

**Goal.** Explore survey found these fields are already parsed off
`metricsResponse` control-frames but immediately dropped. Route
them into `AgentSnapshot` and render as dashboard chips.

- `gpu_utilization_pct` → dashboard "GPU: 62%" chip (menu-bar hidden)
- `latency_p50_ms` / `latency_p99_ms` → dashboard chip
  "p50 42ms · p99 180ms"
- `queue_depth` → menu-bar dot when >0, dashboard chip always

Zero-cost win — pure parse-to-render plumbing, no new wire format.

**Files.** `Agent/ControlFrame.swift`, `Agent/MalibuAgent.swift`
(`AgentSnapshot` field additions), `Dashboard/DashboardWindow.swift`
(chip renders), `MenuBar/MenuBarController.swift` (queue-depth dot
overlay).

### Item 4. Thermal-state chip

**Goal.** Home-Mac-specific failure mode no competitor handles:
silent thermal throttle degrades tokens/sec invisibly. Surface it
so the provider knows to move the Mac to better airflow, unplug
lid-closed setup, etc.

- Source: `IOKit` `IOPMCopyCPUPowerStatus` OR `NSProcessInfo`'s
  `thermalState` (already public, no entitlements). Prefer
  `NSProcessInfo.thermalState` for simplicity + no additional
  entitlements.
- Values map: `.nominal` → "Nominal" (green), `.fair` → "Fair"
  (neutral), `.serious` → "Serious" (amber), `.critical` →
  "Throttled" (amber+bold). Never red — red is reserved for
  `.failed` per §6.4.
- Dashboard: always-visible chip.
- Menu-bar: amber icon-tint variant when `.serious`+, otherwise
  no change (per Ollama-style "distinct stuck vs idle" pattern —
  don't dilute the running-state icon).

**Files.** New `System/ThermalMonitor.swift` (~50 lines,
NotificationCenter observer on `.thermalStateDidChangeNotification`
publishing an `@Published` state), plumbed into `AgentSnapshot`,
rendered in Dashboard + MenuBar.

### Item 5. Verify + refine menu-bar unclaimed-earnings threshold behavior

**Goal.** §6.2 mandates unclaimed-earnings badge re-surface at $1 /
$10 / $100 USDC-equivalent thresholds after user dismissal. Explore
survey noted the "Dismiss Unclaimed Badge" action + threshold
policy exists in code, but threshold behavior is unverified.

- Read `MenuBar/MenuBarController.swift` current dismissal logic.
- Confirm: dismissal at threshold N persists across app restarts
  until threshold N+1 fires; then badge re-surfaces.
- Confirm: threshold is `unpaid_ledger_backlog_usdc +
  unpaid_ledger_backlog_malibu_usdc_equivalent`.
- If dismissal state does not persist across restarts, fix.
- If threshold ratchet is not implemented (dismissal permanently
  silences), fix.
- Add unit test `MenuBarBadgeThresholdTests` covering $1 fire →
  dismiss → $9.99 stays silent → $10 fire → dismiss → $99.99 silent
  → $100 fire → dismiss → silent (no threshold #4).
- Copy: existing "You have unclaimed earnings — add a wallet"
  stays.

**Files.** `MenuBar/MenuBarController.swift`,
`Tests/MalibuTests/MenuBarBadgeThresholdTests.swift` (new).

### Item 6. Live log tail replaces static placeholder

**Goal.** Explore survey found `LogTailView` renders "Logs stream
here." Static text. Dashboard's lower ~20% is dead space today.

- Source: existing CLI stdout/stderr pipe (the App already spawns
  `macprovider-cli`; find where the process is `Process()` +
  attach a `Pipe` reader if not already attached).
- Render: monospace, ~200 line ring buffer, auto-scroll to bottom
  unless user scrolled up (Terminal.app pattern).
- Copy: no header; just the tail.
- Filter: no filtering in this slice — full raw tail. Filtering /
  search comes later.
- Performance: ring-buffer bound at 200 lines; no all-history
  retention (avoids memory bloat on long-running providers).
- Redaction: strip any lines containing `provider_token`,
  `identity_signature`, `Authorization:` header — defensive belt +
  suspenders; the CLI SHOULD NOT emit these but the log tail is a
  UI surface and must not leak them.

**Files.** `Dashboard/DashboardWindow.swift` (LogTailView expanded),
possibly new `System/LogTailReader.swift` if pipe reader doesn't
exist yet.

### Item 7. `.idle` copy fix — pre-empt "do I need crypto?"

**Goal.** Cheap high-leverage copy fix. Salad's setup UX doesn't
address the #1 first-run question ("do I need a wallet / crypto to
start?"). Malibu can, in one line.

- Below the primary "Launch Provider" button on the `.idle` state,
  add one secondary-tone line:

  > `No wallet needed to start — add one anytime after.`

- Placement: OnboardingRootView `.idle` branch, existing render.
- Do NOT link out to docs, wallet pages, or FAQs. One line, done.

**Files.** `Onboarding/OnboardingWindow.swift` (single copy add).

## Scope OUT

**Path B — deferred to separate SPEC + IMPL cycles:**
- `LaunchProviderController.setPayoutWallet()` real body — blocked
  on SPEC-016 §3 addendum for `provider_wallet_swaps` state
  machine + SPEC-027 email OOB cancel channel.
- "Add wallet" button `.disabled(true)` stays disabled — enabling
  it requires the SPEC-016 §3 addendum + browser wallet extension
  copy path. Deferred to the addendum PR.
- MALIBU withdrawable-vs-locked breakdown display — blocked on
  SPEC-028 `provider_rewards_ledger` primitives. Persistent
  "MALIBU + lock icon + `unlocks at Trusted`" per §6.2 is the
  correct Provisional-tier display for this slice; the split
  breakdown lands with SPEC-028.
- Wallet-swap pending-row UI — §6.2 forbids Cancel affordance
  before SPEC-027; read-only display of a pending swap is
  optional and out of scope for this slice.
- Cluster / demand-share stat ("Serving 0.02% of network demand
  this hour") — needs a coord `network_stats`-style endpoint;
  deferred pending that surface.

**Other deferrals:**
- E2E XCUITest scaffold (launch → live happy path + failure
  retry) — deferred to its own IMPL step. Rationale: XCUITest
  target creation + coord dev-mode stub setup is scope creep for
  the stats slice; better as its own audit-loop unit. Item 5's
  MenuBarBadgeThresholdTests unit test still ships here.
- New coordinator RPCs of any kind — none needed for this slice.
- Sparkle/release-channel work — none.
- Provider-portal changes — none (portal is not in this repo).

## Key constraints

1. **No coordinator surface added.** Every field either comes from
   existing endpoints / control-socket frames, or degrades to "—"
   with a follow-up comment.
2. **`setPayoutWallet()` untouched.** It stays throwing "not
   implemented" — Path B territory.
3. **Persistent MALIBU lock+microcopy in Provisional (§6.2)** —
   MUST render on success card, menu-bar tooltip, dashboard MALIBU
   line, ANY new copy that surfaces a MALIBU value. Grep-gated by
   audit-loop review.
4. **Unclaimed-earnings badge $1/$10/$100 threshold ratchet (§6.2)**
   — persists across restarts, silent until next threshold, no
   threshold #4.
5. **"Not reported" ≠ "0"** — every metric field is Optional in
   `AgentSnapshot`; UI renders "—" when `nil`, actual value
   otherwise. Never fabricate zero for missing data.
6. **`.idle` copy addition MUST NOT open any wallet UI** — SPEC-026
   §1.1 non-goal invariant. The line is text-only.
7. **Log tail redaction** — `provider_token`, `identity_signature`,
   `Authorization:` header MUST NOT leak into the UI log tail even
   if the CLI emits them.
8. **Thermal chip amber only** — red reserved for `.failed` per §6.4.
9. **No new dependencies.** Everything ships against Foundation +
   CryptoKit + IOKit + AppKit + SwiftUI already in the target.
10. **Feature flag `MALIBU_ONBOARD_V2`** — item 1 (personalized
    earnings estimate) is inside the OnboardingRootView which
    already respects the flag. Items 2–7 are steady-state / dashboard
    / menu-bar surface that runs regardless of flag (a provider
    reaches `.live` under either onboarding path). No new flag.

## Audit-loop discipline

Per `[[feedback-build-audit-loop]]` + `[[feedback-audit-build-prompts-before-impl]]`:

1. **This BUILD prompt itself gets a 3-lane codex audit-loop pass FIRST**
   before codex executes it. Audit prompts at:
   - `specs/AUDIT_BUILD_SPEC_026_IMPL_STEP_3_CODE_AUDIT_PROMPT.md`
   - `specs/AUDIT_BUILD_SPEC_026_IMPL_STEP_3_SECURITY_AUDIT_PROMPT.md`
   - `specs/AUDIT_BUILD_SPEC_026_IMPL_STEP_3_ARCHITECT_AUDIT_PROMPT.md`
2. Converge prompt to 0 CRITICAL / 0 HIGH / 0 MEDIUM across all
   three lanes; narrative in
   `specs/SPEC-026-IMPL-STEP-3-BUILD-PROMPT-audit.md`.
3. Codex executes the audited prompt → IMPL diff on this branch
   `feat/spec-026-ux-stats-slice`.
4. Write 3-lane IMPL audit prompts:
   - `specs/AUDIT_SPEC_026_IMPL_STEP_3_CODE_AUDIT_PROMPT.md`
   - `specs/AUDIT_SPEC_026_IMPL_STEP_3_SECURITY_AUDIT_PROMPT.md`
   - `specs/AUDIT_SPEC_026_IMPL_STEP_3_ARCHITECT_AUDIT_PROMPT.md`
5. Fire, fix, re-fire, converge; narrative in
   `specs/SPEC-026-IMPL-STEP-3-audit.md`.
6. DRAFT → Ready → merge.

## Test coverage per item

- **Item 1:** `EarningsEstimateFormatterTests` for chip + model +
  range → copy string; nil range → line hidden.
- **Item 2:** `DashboardViewTests` (SwiftUI ViewInspector or
  behavior-level) confirming every field renders "—" when Optional
  and actual value when populated; MALIBU line ALWAYS renders lock
  in Provisional.
- **Item 3:** `ControlFrameTests` extended for gpu / latency /
  queue-depth fields parse → `AgentSnapshot` propagation.
- **Item 4:** `ThermalMonitorTests` mocking
  `NSProcessInfo.thermalState` transitions → chip state.
- **Item 5:** `MenuBarBadgeThresholdTests` full ratchet coverage
  (per Item 5 body above).
- **Item 6:** `LogTailReaderTests` covering ring-buffer bound +
  redaction of sensitive substrings.
- **Item 7:** No test — pure copy add. Cover in Item 2's dashboard
  render tests if the `.idle` render is included.

## Definition of done

- CI green on `phase3-binary (swift test)` and any spec-015-acceptance
  gates that assert the App composes cleanly.
- All 6 new/extended test files pass.
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- Manual smoke on a live M-series Mac in `.live` state:
  - Dashboard shows populated model chip + requests/tokens counters
    (or "—" if CLI hasn't emitted metrics yet)
  - MALIBU line shows lock icon + "unlocks at Trusted" microcopy
  - Thermal chip renders "Nominal" and updates on `NSProcessInfo`
    notification (verify by artificially stressing CPU / running
    `yes` on all cores until state changes)
  - Log tail streams live CLI output; test-emit a line containing
    `Authorization: Bearer test` and confirm it's redacted in UI
  - Menu-bar badge dismissal persists across app restart; $1
    threshold fires, silences on dismiss, re-fires at $10
- `.idle` screen shows "No wallet needed to start — add one anytime
  after." copy under the button.
- No new files in the tree contain "IMPLEMENTER:" or "TODO" markers
  (the SPEC-016/027/028 follow-up comments MAY use
  "// Path B follow-up (SPEC-XXX)" formulation instead).
- Ready to convert DRAFT → Ready for review.

## Reference

- Parent SPEC: `specs/SPEC-026-browserless-provider-onboarding.md` v0.11
- Sibling shipped IMPL: #346 (coord), #347 (App bundle)
- Base branch for this PR: `main` (66f372e or later)
- Adjacent locked specs: SPEC-005 (earnings endpoint), SPEC-023
  (rate-card), SPEC-025 (menu-bar icon states, §11 metrics
  wiring gate)
