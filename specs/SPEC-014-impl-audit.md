# SPEC-014 implementation audit — Phase 1A

**Audited:** working tree on branch feat/spec-014-portal-phase-1a (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1A, round 1 of N
**Date:** 2026-06-21
**Total findings:** 0 CRITICAL / 2 HIGH / 0 MEDIUM / 0 MINOR / 1 QUESTION
**Phase 1A readiness:** FIX REQUIRED

---

## Executive summary

Phase 1A is close to the locked SPEC-014 v0.8 and BUILD prompt contract: the bundle is single-file, same-origin for coordinator calls, uses an in-memory session, renders Surface A only, keeps the B/C/D/E surfaces stubbed, matches the required root visual tokens, and passes the static hygiene greps for browser storage, operator-keyed routes, multi-machine copy, and `innerHTML`.

Two HIGH blockers remain before commit. First, the `require_provider_tokens` non-true failure path does not render the required AUTH-3 explanation; the dedicated `false` page exists but is unreachable because generic config-error rendering wins. Second, the stale-config guard cannot reach the second-failure notice through the actual sign-in flow because `submitSignIn()` resets `authFailBySurface` on every retry after the first auth rejection signs the user out.

There is one non-blocking QUESTION about `autocomplete="off"` on the provider token input. That choice minimizes browser-managed token persistence, but the operator may prefer password-manager ergonomics in a future round.

## Category A: AUTH-3 deployment-mode loader

### A.2  Non-true `require_provider_tokens` values miss the required unavailable explanation   HIGH
Location: index.html line 408-413, line 654-660, line 726-733, line 747-763

`validateConfig()` sets `state.flagFalse = true` and throws `flag-false` for `require_provider_tokens === false`, but `loadConfig()` also stores that failure in `state.configError`. `render()` checks `state.configError` before `state.flagFalse`, so `renderUnavailable_FlagFalse()` is unreachable; `"true"`, `1`, and `null` also fall through to the generic invalid-field copy.

This violates the BUILD prompt's AUTH-3 constraint and SPEC-014 §2.3 / §2.4 requirement that unsupported deployment mode render the explanatory fail-CLOSED page citing SPEC-002 FR-P12 and SPEC-005 §11.5 route disablement. The branch still fails closed, so this is not a fail-open security issue, but the required operator guidance is absent.

Recommendation: Route `flag-false` and other non-true `require_provider_tokens` failures to the dedicated AUTH-3 explanation before generic config errors, and keep the zero-subsequent-network-call behavior.

## Category B: AUTH-1 sign-in + session model

### B.5  Token input disables autocomplete   QUESTION
Location: index.html line 766-767

Both sign-in fields use `autocomplete="off"`, including the password-type `provider_token` input. This is a defensible privacy-preserving default because SPEC-014 requires in-memory-only portal session state and prohibits browser storage.

The SPEC is silent on browser-managed password manager behavior, and the audit prompt explicitly calls out `autocomplete="off"` versus `current-password` as an operator preference question. `current-password` may improve repeated sign-in ergonomics, but it increases browser-managed token persistence.

Recommendation: Keep `autocomplete="off"` for Phase 1A unless the operator explicitly chooses password-manager convenience for provider tokens.

## Category C: AUTH-2 status handling + stale-config guard

### C.4  Stale-config notice cannot be reached after an auth retry   HIGH
Location: index.html line 456-458, line 522-523, line 538-550, line 597-609

`coordFetch()` increments `state.authFailBySurface[surface]` on authenticated 401/403/404, and `handleAuthRejection()` reads that count correctly. However, the first auth rejection signs the user out, and the next submit path resets `state.authFailBySurface = {}` before starting pollers again.

SPEC-014 §2.3 and §8(b) require the second consecutive authenticated provider-endpoint failure on the same surface to add the deployment-misconfiguration notice while preserving the 403/404-identical sign-in rejection copy. With the current reset on every sign-in retry, each failed retry is treated as the first failure, so the stale-config notice never appears through the real UI flow.

Recommendation: Preserve the per-surface auth-failure counter across auth-rejection sign-in retries in the same browser session, and reset it only on a successful authenticated provider-endpoint response or an explicit full sign-out/new-session boundary.

## Category D: Same-origin proxy fail-loud

(no findings)

## Category E: Polling + cache + stale stamp

(no findings)

## Category F: Surface A — Machine

(no findings)

## Category G: Sidebar shell

(no findings)

## Category H: Non-goals enforced

(no findings)

## Category I: Visual tokens

(no findings)

## Category J: DOM hygiene + bundle hygiene

(no findings)

## Category K: Forward-compatibility

(no findings)

## Category L: README + example-config quality

(no findings)

## Category O: Anything else

(no findings)

## Out of scope for this audit

- Spec drift / spec content edits (SPEC-014 v0.8 LOCKED).
- Phase 1B work (Surface B, GitHub Releases feed).
- Phase 1C work (Surfaces C/D/E, `check-bundle.sh`).
- d-inference internals (clean-room).
- Operator nginx / DNS / Pearl VPS deployment topology (Open Q7).

---

# Round 2 — closure verification

**Audited:** working tree on branch feat/spec-014-portal-phase-1a (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1A, round 2 of N
**Date:** 2026-06-21
**Round 1 findings status:** A.2 CLOSED, C.4 CLOSED
**New findings:** 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 MINOR / 0 QUESTION
**Phase 1A readiness:** READY TO COMMIT

## A.2 closure
Status: CLOSED

`validateConfig()` now treats any `require_provider_tokens !== true` value as flag-false at index.html line ~411, and `loadConfig()` no longer stores that branch in `state.configError`, so the dedicated unavailable page is reachable. The unavailable copy cites SPEC-002 FR-P12 and SPEC-005 §11.5 at index.html line ~746, and an in-memory fetch-spy check confirmed `false`, `"true"`, `1`, and `null` make only `/portal-config.json` with no `/v1/pool/check`, earnings, or GitHub calls.

## C.4 closure
Status: CLOSED

`submitSignIn()` no longer resets `state.authFailBySurface`, while successful authenticated 2xx responses reset the relevant surface counter and `signOut()` clears it explicitly at index.html line ~453 and line ~580. A two-retry harness confirmed the first 403 shows only the identical sign-in rejection copy, and the second consecutive 403 on the same surface also renders `signinMisconfigNotice`.

## New findings (round 2)

(no findings)

---

# Phase 1B audit — round 2 closure verification

**Audited:** working tree on branch feat/spec-014-provider-portal (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1B, round 2 of N
**Date:** 2026-06-21
**Round 1 findings status:** C.4 CLOSED, H.1 CLOSED
**New findings:** 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 MINOR / 0 QUESTION
**Phase 1B readiness:** READY TO COMMIT

## C.4 closure

Status: CLOSED

Step 3 now cites only `SPEC-013 §6 / NFR-4`, with no `SPEC-003 §6.2` suffix. Step 1 still cites `SPEC-003 §4 / FR-C2`, and Step 2 still cites `SPEC-003 §4 / FR-C4 (per SPEC-003 §6.2)`; SPEC-003 §6.2 was rechecked and does not list `autotune`.

## H.1 closure

Status: CLOSED

The Phase 1B `.snippet code` rule and `.release-card pre.rel-body` rule now both use `background:var(--bg)`. A diff-only hex-literal sweep over Phase 1B CSS additions returned no matches, so the closure edits did not introduce any new raw hex literal in the added Phase 1B CSS.

## New findings (round 2)

(no findings)
