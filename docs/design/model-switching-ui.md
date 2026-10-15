# Design

## Source of truth

- Status: Draft
- Last refreshed: 2026-08-09
- Primary surfaces: Malibu dashboard, model switcher sheet, and Models settings.
- Evidence: `specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md`, current model-management SwiftUI, the checked-in capability manifest, string catalog, brand components, and app tests.
- No visual mockup or prior repo-root design contract was found. No clean-room `d-inference` source was inspected.

## Observed facts

- Malibu is a compact macOS operator utility. Its model UX uses native controls, monospaced exact model IDs, secondary explanatory text, subtle rounded panels, and restrained Malibu brand accents.
- The dashboard already exposes the current model and `Change Model…`; the switcher separates Current, Ready, Needs preparation, and Blocked; Models settings already contains the durable background-recommendations preference.
- Recommendation capabilities are enabled only when the checked-in manifest and a fresh provider peer agree on the installed-only check contract and the typed, journaled adoption transaction.

## Assumptions

- The primary user is a provider who wants safe model improvements without Terminal and without interrupting active serving.
- Recommendations should feel like quiet maintenance advice, not marketing or a revenue promise.
- Native macOS typography remains the default; model IDs stay exact, selectable, and monospaced.

## Brand

- Personality: calm, precise, local-control, operator-grade.
- Trust signals: exact current and target IDs, concrete guard reasons, visible capability/update guidance, and explicit provider-owned transactions.
- Existing accents: deep teal `#143A45`, cream `#FFFBF2`, coral `#FF6E5B`, sunny yellow `#FFC629`.
- Avoid modal promotion, decorative gradients, vague disabled actions, arbitrary marketplace behavior, and app-side config mutation.

## Product goals

- Goals: proactive installed-only recommendation checks, a non-intrusive actionable callout, one-tap explicit adoption through CLI authority, reversible snooze/opt-out, and clear local history.
- Non-goals: app-owned trust or billing logic, arbitrary model installation, hidden downloads, default force overrides, or false cancellation.
- Success means a provider can understand, adopt, defer, or stop a recommendation entirely inside Malibu, with reversible pre-commit failure and truthful post-commit reconciliation.

## Personas and jobs

- Provider/operator: keep serving, understand whether a better installed model is available, adopt it safely, and recover from blocked states.
- Support operator: inspect compact redacted outcomes without exposing secrets or raw subprocess logs.

## Information architecture

- Dashboard: current model first, status/guard second, action third; show structurally valid recommendations, while unsupported drafts or safety warnings remain visibly advisory with adoption disabled.
- Switcher: current runtime state, recommendation callout, categorized model rows, previous-model revert, and activity history.
- Settings: unconditional durable background toggle plus last check/next eligibility status.
- Callout actions: `Adopt`, `Not now`, and `Stop background recommendations`; it never steals focus.

## Design principles

- Model state is infrastructure state, not a preference.
- Recommendations are hints; adoption is explicit and provider-authoritative.
- Background work is installed-only, power/thermal gated, low priority, and non-modal.
- Every disabled action has a concrete textual reason. State never relies on color alone.

## Visual language

- Reuse native SwiftUI utility typography, compact 12–20 point spacing, stable rows, subtle gray fills, and 7–8 point radii.
- Use brand color sparingly for attention and transition; keep operational content dominant.
- Use restrained native progress and announce meaningful phase changes rather than decorative motion.

## Components

- Reuse `ModelSwitcherSheet`, `ModelRowView`, dashboard panel styling, and Models settings.
- Add a proactive recommendation callout, recommendation check progress/status, `Adopt` action, snooze/stop controls, and adoption rollback states.
- States: checking, no recommendation, recommended, stale/blocked, adopting, config apply, switching, rollback, rolled back, rollback failed, completed.
- Ownership: Malibu presents consent/progress and persists UI-only schedule/dismissal state; the CLI/runtime validates, applies, switches, verifies, and rolls back.

## Accessibility

- All recommendation actions are keyboard and VoiceOver reachable.
- A new callout is announced non-disruptively without moving focus.
- Progress and terminal transitions are announced; color is paired with text.
- Every new string uses `String(localized:)`; sizes, durations, counts, and rates use locale-aware formatting.

## Responsive behavior

- Support resizable macOS windows and sheets.
- Long IDs wrap or middle-truncate without becoming action input; action controls remain visible.
- Hover/help is supplemental, never the only explanation.

## Interaction states

- Loading keeps the current model visible.
- Empty states distinguish no installed recommendation from capability or gate failures.
- Errors keep the incumbent visible and provide retry/update guidance.
- Success updates current/previous model, clears the adopted recommendation, and records history.
- Cancellation is offered only while the protocol says work is cancellable; a failed pre-commit config step explicitly cancels and consumes its prepared runtime authority.
- If runtime commit succeeds but config verification or repair fails, never claim the incumbent is still active; say the target may already be live and refresh provider truth before enabling another action.

## Content voice

- Plain, specific, non-promotional: `Recommended`, `Adopt`, `Not now`, `Stop background recommendations`, `Cooling down for 8 seconds`.
- Never claim a model is better without trusted recommendation output.
- Disclose candidate scope and heavyweight work before it begins.

## Implementation constraints

- SwiftUI/AppKit macOS application.
- Actions require agreement between the checked-in manifest and fresh launchd-owned provider evidence.
- Background checks require external power, a fresh power sample, nominal/fair thermal state, no active operation, and the installed-only adapter.
- Recommendation adoption never calls app-side config persistence.
- One-tap adoption carries the recommendation's context, concurrency, and KV-bit knobs in the transaction authority and installs them atomically with the target runtime model.
- UI state/logs exclude tokens, provider keys, serials, MACs, UUIDs, raw hardware fingerprints, HMAC secrets, hidden hardware hashes, and raw CLI output.
- Tests cover capability floors, schema rejection, scheduler gates, installed-only command construction, snooze/opt-out, adoption terminal/rollback states, accessibility, and localization.
