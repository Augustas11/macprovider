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

---

# Phase 1C audit — round 1

**Audited:** working tree on branch feat/spec-014-provider-portal (uncommitted Phase 1C)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1C, round 1 of N
**Date:** 2026-06-21
**Total findings:** 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 MINOR / 0 QUESTION
**Phase 1C readiness:** FIX REQUIRED
**check-bundle.sh status:** FAILS
**Single-PR readiness:** BLOCKED

---

## Executive summary

Phase 1C's portal surfaces are aligned with the locked SPEC-014 v0.8 contract. Surface C renders only the three aggregate credit cards plus the literal fiat-rail-deferred card; Surface D is a single static placeholder and adds no surface-triggered fetch or remote-loading element; Surface E renders only `provider_id`, tier, state, and coordinator base URL, with hardware/runtime and rotation/removal called out as deferred. Sidebar polish is also intact: Earn navigation warms the earnings cache with surface key `"earn"`, API Docs has both `noopener` and `noreferrer`, mobile close behavior remains wired, and sign-out clears pool, earn, releases, auth-failure state, and timers.

The only blocker is in `check-bundle.sh` self-protection. The script functionally exits 0 on the current bundle, exits 1 on a temp bundle containing `/poolz`, and exits 2 when `index.html` is missing. However, its own comments and failure messages contain literal `operator-key` / `operator_key` strings that match the required `operator[_-]?key` grep under a reasonable external scanner. That is a MEDIUM build-guard contract miss, not a portal runtime privacy leak.

Static verification evidence collected: `frontdoor/provider-portal/check-bundle.sh` printed `check-bundle: OK`; synthetic temp-script checks returned exit 1 for `/poolz` and exit 2 for missing `index.html`; targeted greps found no browser storage, no operator-keyed routes in `index.html`, no multi-machine copy, no fiat withdrawal UX, no `Access-Control-Allow-Origin`, no external `<script src>`, stylesheet link, `<img>`, or `<iframe>`; extracted inline JS passed `node --check`.

## Category A: Surface C — Earn

(no findings)

## Category B: Surface D — Monitoring

(no findings)

## Category C: Surface E — Identity

(no findings)

## Category D: Sidebar polish

(no findings)

## Category E: check-bundle.sh

### E.5  Guard script self-matches the operator-key pattern   MEDIUM
Location: check-bundle.sh line 5-50

The build guard correctly splits the operator route literals (`"/po""olz"`, `"/adm""in/blacklist"`, etc.) and splits the runtime regex assignment as `op_key_pat="oper""ator[_-]?key"`. But the script's own comments and failure messages still contain literal strings that match the same required external grep pattern:

- `operator-key` in comments and the route failure message.
- `operator_key` in the comment and operator-key failure message.

Evidence: `grep -Eni 'operator[_-]?key|/poolz|/admin/blacklist|/admin/provisional|/admin/promote|/admin/reject|/admin/ledger|your fleet|your machines|across machines|all machines|N machines|N/M|x3|machine grid' frontdoor/provider-portal/check-bundle.sh` matched lines 5, 13, 29, 30, 41, 46, and 50. This violates the Phase 1C audit requirement that the script's own source must not contain a literal that would match its own grep when an external tool scans the script file.

The current bundle scan still works: the script printed `check-bundle: OK` on the current `index.html`, returned exit 1 on a temp `index.html` containing `/poolz`, and returned exit 2 when run from a temp directory without `index.html`. The miss is self-protection under external guard scans, so MEDIUM matches the audit severity definition.

Recommendation: split or reword every script-source occurrence that matches `operator[_-]?key`, including comments and echo text, while preserving the emitted `FAIL [8(b)]: ...` semantics.

## Category F: Phase 1A + 1B regression check

(no findings)

## Category G: Privacy ACs (§8(d))

(no findings)

The only buyer-shaped text match in `index.html` is the required Surface D placeholder bullet naming the future privacy-redaction policy gap for buyer prompts, completions, identity, API keys, and IPs. It is not a rendered buyer field or data source.

## Category H: DOM hygiene + bundle hygiene + grep guards

(no findings)

## Category I: README + deploy quality

(no findings)

## Category O: Anything else

(no findings)

## Out of scope

- Spec edits (SPEC-014 / SPEC-005 / SPEC-002 LOCKED).
- v0.2 work (Surface D real cards; C.3/C.4; E rotation; A.1 update pill; notification opt-ins).
- d-inference internals.
- Operator deployment topology (Q7).
- The `.github/workflows/` CI YAML — operator follow-up after squash-merge.

---

# Phase 1C audit — round 2 closure verification

**Audited:** working tree on branch feat/spec-014-provider-portal (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1C, round 2 of N
**Date:** 2026-06-21
**Round 1 findings status:** E.5 CLOSED
**New findings:** 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 MINOR / 0 QUESTION
**Phase 1C readiness:** READY TO COMMIT
**check-bundle.sh status:** PASSES
**Single-PR readiness:** READY TO OPEN PR

## Closed findings

### E.5  Guard script self-matches the operator-key pattern   CLOSED

The self-protection fix closes E.5. The exact external source scan now returns no matches for `operator[_-]?key`, the privileged route literals, or the AC 8(f) multi-machine strings in `frontdoor/provider-portal/check-bundle.sh`; the same combined scan over `index.html` and `check-bundle.sh` also returns no matches.

Behavior is unchanged where required: `./frontdoor/provider-portal/check-bundle.sh` prints `check-bundle: OK` and exits 0 on the current bundle; a temp bundle containing `/poolz` exits 1 and prints `FAIL [8(b)]: bundle references privileged-key route: /poolz`; and a temp script directory with no `index.html` exits 2 with the missing-bundle message. A synthetic coverage loop also confirmed exit 1 for every BUILD prompt constraint-6 prohibited string: all six privileged routes, both `operator-key` / `operator_key` spellings, and all eight AC 8(f) multi-machine strings.

## New findings

(no findings)
