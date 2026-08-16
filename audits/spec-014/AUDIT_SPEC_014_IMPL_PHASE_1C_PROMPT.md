# Implementation audit prompt — SPEC-014 Phase 1C (Surfaces C/D/E + sidebar polish + check-bundle.sh)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / SPEC-014 review** of Phase 1C on branch
`feat/spec-014-provider-portal`.

Phase 1C delivers (additive on top of Phase 1A + 1B):

| Files | Phase | Scope |
|---|---|---|
| `frontdoor/provider-portal/index.html` (extended) | 1C | `renderEarn()` (C.1 credit totals + C.2 fiat-not-specified card; no C.3/C.4), `renderMonitoring()` (single placeholder card; ZERO network), `renderIdentity()` (read-only card with provider_id / tier / state / coordinator base URL only), sidebar polish (sign-out clears releases too; API Docs link has `rel="noopener noreferrer"`; mobile breakpoint inherited from 1A) |
| `frontdoor/provider-portal/check-bundle.sh` (NEW, executable) | 1C | AC 8(b) + AC 8(f) build-time grep guard; exits 0 clean / 1 found / 2 missing |
| `frontdoor/provider-portal/README.md` (extended) | 1C | Deploy steps, CI hook, auth model summary, Phase 1C status |

SPEC-014 v0.8 is LOCKED. Phases 1A and 1B are LOCKED (round-2
closure verified). This is the final IMPL audit gate before the
single PR opens.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. **Read-only**: Codex MUST NOT
modify any file, commit, push, or change git state. Only output is
the structured findings report appended to
`specs/SPEC-014-impl-audit.md`.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation audit of Phase 1C
of SPEC-014 v0.8 in the working tree at
`/Users/augstar/macprovider-poc`, on branch
`feat/spec-014-provider-portal`. Phase 1C is the final
implementation sub-phase. The next gate after this audit is the
single PR opening.

Phase 1A is LOCKED (round 2 — both HIGH CLOSED).
Phase 1B is LOCKED (round 2 — both MEDIUM CLOSED).

Findings that concern only Phase 1A or 1B surfaces are out of scope
UNLESS Phase 1C edits have regressed them. v0.2 work is out of
scope.

This is a **read-only review**. No file edits, no commits, no
branches.

## Context

Phase 1C's BUILD prompt is
`specs/BUILD_SPEC_014_IMPL_PHASE_1C_PROMPT.md`. The 9 critical
constraints (Surfaces C / D / E, sidebar polish, check-bundle.sh,
README extension, privacy ACs) are binding. Spec-binding sections:
SPEC-014 §3 + §4.3 + §4.4 + §4.5 + §5.1 table (a) C.1/E.1 rows +
§5.2 table (b) C.2/D/E.1 rows + §5.3 table (c) all C.3/C.4/D/E
deferred rows + §7 non-goals + §8(a) C/D/E ACs + §8(b) operator-key
isolation + §8(d) privacy ACs + §8(e Q3/Q4/Q5/Q6/Q11) ACs +
§8(f) single-machine ACs.

## Required reading (in order)

1. The current `frontdoor/provider-portal/index.html` end-to-end —
   focus on the three new renderers (`renderEarn()`,
   `renderMonitoring()`, `renderIdentity()`), the sidebar mount
   hook for `earn` route (must call `earnFetch("earn")`), and the
   sign-out path.

2. `frontdoor/provider-portal/check-bundle.sh` end-to-end. Run it
   mentally and verify:
   - It exits 0 on the current clean bundle.
   - The string-concatenation idiom (`"/po""olz"` etc.) prevents
     the script's own source from matching the grep when the
     script is itself scanned by an external tool.
   - The patterns cover EVERY string in BUILD prompt constraint 6
     (op_routes + op_key + multi_machine).

3. `frontdoor/provider-portal/README.md` — deploy steps, CI note,
   auth model.

4. `specs/SPEC-014-provider-portal.md` §3, §4.3, §4.4, §4.5, §5.1,
   §5.2, §5.3, §7, §8(a) C/D/E groups, §8(b), §8(d), §8(e)
   Q3/Q4/Q5/Q6/Q11, §8(f).

5. `specs/SPEC-005-billing.md` §1.3 + §2.1 D1 (fiat / Stripe out
   of scope) — drives C.2 copy.

6. `specs/BUILD_SPEC_014_IMPL_PHASE_1C_PROMPT.md`.

7. `specs/SPEC-014-impl-audit.md` Phase 1A + 1B audit history.

## Severity definitions

Same five-tier scale as Phase 1A / 1B.

- **CRITICAL** — silent SPEC-014 contract violation; Surface D
  issues a network request; bundle exposes a buyer field (any
  per-request data, prompt, completion, IP, key); operator-key
  leak; Phase 1A/1B fail-CLOSED branch regression; check-bundle.sh
  exits 0 on a bundle that should fail.

- **HIGH** — a §8(a) C/D/E AC, §8(b), §8(d), §8(e) Q3/Q4/Q5/Q6/Q11,
  or §8(f) AC is not satisfied; C.2 contains forbidden fiat copy
  (country selector, Stripe, "withdraw now"); E.1 contains a
  forbidden field (model_id / ram_gb / binary_version / attestation
  / endpoint_url / rotate-token / remove-machine / notification
  toggle); check-bundle.sh misses a required pattern from BUILD
  prompt constraint 6.

- **MEDIUM** — partial honoring (e.g. C.2 body text close-but-not-
  identical to the literal; D placeholder citation drifted; E
  identity grid layout swap that subtly hides the foot note);
  check-bundle.sh self-matches its own source under reasonable
  external grep tools; README missing the deploy / CI clause.

- **MINOR** — quality issues (dead CSS, naming, redundant guards).

- **QUESTION** — design choice where SPEC was silent.

## Critical constraints

1. **SPEC-014 v0.8 + SPEC-005 v0.3 + SPEC-002 v1.3.5 are LOCKED.**
   Findings recommending spec edits are out of scope.

2. **Read-only.** No file edits, no commits, no branches.

3. **Phase 1C scope.** Do NOT raise v0.2 findings (Surface D real
   sub-cards; C.3/C.4 breakdown; E rotation/removal; A.1 update
   pill; etc.). DO raise findings if Phase 1C regressed Phase 1A
   or 1B.

## Audit categories — work through each

### Category A: Surface C — Earn (§4.3, §5.1, §5.2, SPEC-005 §1.3 / §2.1 D1)

A.1  C.1 renders exactly three credit cards from
     `state.earn.data`:
     - "Lifetime credits" ← `total_credits` (integer).
     - "Current window" ← `current_window_credits` (integer).
     - "Last payout-ready window" ← `last_payout_ready.provider_credits`
       PLUS `window_start_utc` / `window_end_utc` in the footer.
     No fiat conversion. No "$" symbol. No "withdrawable balance"
     label. Display units match wire shape verbatim.

A.2  C.2 fiat-payout card renders the LITERAL body
     `"Fiat payout rail not yet specified — future spec."` and
     cites SPEC-005 §1.3 / §2.1 D1 + Open Q3.

A.3  C.2 contains NONE of: country selector, Stripe reference,
     "Link bank" button, account-type picker, "withdraw now" /
     "payout now" CTA, USD/EUR/fiat amount.

A.4  C.3 and C.4 are NOT rendered.

A.5  Mounting `route === "earn"` calls `earnFetch()` (warming the
     cache from the existing Phase 1A helper). Verify no DUPLICATE
     duplicate `setInterval` is spawned.

A.6  On 401/403/404 for `/providers/{id}/earnings`, the surface
     follows the existing Phase 1A AUTH-2 + stale-config guard
     (the second consecutive failure on the SAME surface key —
     `"earn"` here — must add the misconfig notice). Verify
     `earnFetch("earn")` is called with the surface key so the
     counter increments correctly.

### Category B: Surface D — Monitoring (§4.4)

B.1  ONE single placeholder card with three static bullets:
     - "Uptime history (24 h / 7 d / 30 d) — needs Open Q5
        (SPEC-002 amendment)."
     - "Current routing weight — needs Open Q5 (SPEC-002
        amendment)."
     - "Live request tail — needs Open Q5 AND a privacy-redaction
        policy decision (which fields a provider may see; what
        redaction applies to buyer prompts, completions, identity,
        API keys, and IPs)."
     Card title is `"Monitoring — coming after SPEC-002 amendment"`.

B.2  ZERO network requests are issued by the Monitoring renderer
     mount. The renderer MUST NOT call `earnFetch()`,
     `poolCheck()`, `releasesFetch()`, or any new fetch. The
     renderer MUST NOT mount `<img>`, `<iframe>`, `<link>`, or
     any element that would trigger a remote URL load.

B.3  Card body cites SPEC-014 §4.4.

### Category C: Surface E — Identity (§4.5)

C.1  Exactly four fields in a label/value grid:
     - `provider_id` (pasted session value, mono).
     - Tier (pool data; pill).
     - State (pool data; mono).
     - Coordinator base URL (`state.cfg.coordinator_base_url`;
       mono).

C.2  Footer line names hardware / runtime fields as deferred
     behind Open Q5 (and rotation / removal behind Open Q6 is
     acceptable but Open Q5 is the spec-required citation).

C.3  Card contains NONE of: rotate-token button, remove-machine
     button, notification opt-in toggles (email / Slack / push /
     SMS), hostname / model_id / model_params_b / ram_gb /
     max_context_tokens / max_concurrency / throughput_tps_estimate
     / binary_version / attestation / endpoint_url field.

C.4  Mounting the route issues NO new fetch — Identity reads
     `state.pool.data` lazily.

### Category D: Sidebar polish (§3)

D.1  "Sign out" stops `pool`, `earn`, `stamp` timers; clears
     `state.session`, `state.pool`, `state.earn`, `state.releases`
     (Phase 1B fix), `state.authFailBySurface`; sets
     `state.route = "machine"`; re-renders to sign-in.

D.2  "API Docs" link uses
     `href="https://api.malibu.tech/docs"`, `target="_blank"`,
     `rel="noopener noreferrer"`. Verify both rel tokens (the
     two are independent — `noopener` prevents reverse-tabnabbing;
     `noreferrer` strips the Referer header).

D.3  Mobile (<720 px) hamburger toggles `state.sidebarOpen`;
     scrim closes; nav-item tap closes. No Phase 1C regression.

### Category E: check-bundle.sh (NEW)

E.1  Exits 0 on the current clean bundle.

E.2  Exits 1 on a synthetic bundle containing `/poolz`.

E.3  Exits 2 when `index.html` is missing.

E.4  Patterns cover EVERY string in BUILD prompt constraint 6:
     - `/poolz`, `/admin/blacklist`, `/admin/provisional`,
       `/admin/promote`, `/admin/reject`, `/admin/ledger`.
     - case-insensitive `operator[_-]?key`.
     - case-insensitive `"your fleet"`, `"your machines"`,
       `"across machines"`, `"all machines"`, `"N machines"`,
       `"N/M"`, `"x3"`, `"machine grid"`.

E.5  Self-protection: the script's own source MUST NOT contain
     a literal that would match its own grep when an EXTERNAL
     tool greps the script file. The required idiom is string
     concatenation (`"/po""olz"`, etc.).

E.6  `set -euo pipefail` set.

E.7  Exit codes match the BUILD prompt: 0 / 1 / 2.

E.8  Output on clean: `check-bundle: OK`. Output on match:
     `FAIL [8(b)]: ...` or `FAIL [8(f)]: ...`.

### Category F: Phase 1A + 1B regression check

F.1  AUTH-3 fail-CLOSED still works for missing config / unknown
     key / non-true flag.

F.2  AUTH-2 401/403/404 still identical-copy. Stale-config guard
     still fires on second consecutive failure per surface (the
     surface key `"earn"` is now ALSO a valid bucket).

F.3  Same-origin invariant for coordinator routes still holds.

F.4  Surface A (Machine) unchanged. A.2 counters and A.3
     needs-attention still wired correctly.

F.5  Surface B (Setup) unchanged. B.3 GitHub Releases feed still
     handles rate-limit + CORS fail-loud + plain-text body.

### Category G: Privacy ACs (§8(d))

G.1  Bundle displays ONLY provider-owned fields:
     - `provider_id` (path subject).
     - `tier` (pool tier).
     - `state` (pool state).
     - `total_credits`, `current_window_credits`,
       `last_payout_ready.*` (earnings rollups; no per-request
       data; no buyer attribution).
     - GitHub Releases `tag_name` / `published_at` / `body`
       (public artifact).

G.2  Bundle MUST NOT render any buyer field (`request_id`, buyer
     account id, prompt text, completion text, IP, API key).
     Grep for buyer-shaped identifiers and confirm absence.

### Category H: DOM hygiene + bundle hygiene + grep guards

H.1  Bundle still single-file, no CDN, no `<script src>`, no
     `<link rel="stylesheet" href>` to anything external.

H.2  `innerHTML` count is zero (or matches Phase 1B baseline).

H.3  Greps return zero:
     - browser-storage
     - operator-keyed routes / `operator_key`
     - multi-machine copy
     - autotune banner / fiat UX
     - `Access-Control-Allow-Origin`

H.4  No new `setInterval` / `setTimeout` not already documented.

H.5  No new cross-origin fetch besides Phase 1B's GitHub Releases.

### Category I: README + deploy quality

I.1  README documents `check-bundle.sh` and the CI hook.

I.2  README documents the three deploy steps (copy config,
     reverse proxy, run check-bundle.sh).

I.3  README documents the AUTH-1/2/3 model summary.

I.4  Phase status section reflects Phase 1A + 1B + 1C all
     landed.

### Category O: Anything else

Anything the operator should know that doesn't fit A-I.

## Output structure

Append to `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
a new top-level section:

```
---

# Phase 1C audit — round 1

**Audited:** working tree on branch feat/spec-014-provider-portal (uncommitted Phase 1C)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1C, round 1 of N
**Date:** 2026-06-21
**Total findings:** [N CRITICAL / N HIGH / N MEDIUM / N MINOR / N QUESTION]
**Phase 1C readiness:** [READY TO COMMIT | FIX REQUIRED]
**check-bundle.sh status:** [PASSES | FAILS]
**Single-PR readiness:** [READY TO OPEN PR | BLOCKED]

---

## Executive summary

[2-3 paragraphs.]
```

Then for each category A-I + O, write a section with findings in
the Phase 1A / 1B format:

```
### A.1  [TITLE]   [CRITICAL | HIGH | MEDIUM | MINOR | QUESTION]
Location: index.html line N-M (or check-bundle.sh, or README.md)

[Body]
```

If category empty, write `(no findings)`.

## Out of scope

- Spec edits (SPEC-014 / SPEC-005 / SPEC-002 LOCKED).
- v0.2 work (Surface D real cards; C.3/C.4; E rotation; A.1
  update pill; notification opt-ins).
- d-inference internals.
- Operator deployment topology (Q7).
- The `.github/workflows/` CI YAML — operator follow-up after
  squash-merge.

=== END PROMPT ===
```
