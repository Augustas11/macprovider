# Implementation audit prompt — SPEC-014 Phase 1B (Surface B + version feed)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / SPEC-014 review** of Phase 1B on branch
`feat/spec-014-provider-portal`.

Phase 1B delivers (changes are additive on top of Phase 1A):

| Files | Phase | Scope |
|---|---|---|
| `frontdoor/provider-portal/index.html` (extended) | 1B | Real `renderSetup()`: B.1 requirements grid (FR-D1 verbatim), B.1a RAM-to-model sizing card (FR-D2 + FR-D2.1), B.2 numbered setup steps (3 steps, copy-to-clipboard CTAs, NO autotune banner), B.3 GitHub Releases feed with 5-min cache + rate-limit/CORS fail-loud + plain-text body rendering |
| `frontdoor/provider-portal/README.md` (touched) | 1B | One-liner phase-status update |

SPEC-014 v0.8 is LOCKED. Phase 1A is LOCKED at commit 3cd7787 +
audit-loop fixes (round 2 closure, no open HIGH/MEDIUM). Phase 1C
has NOT landed.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. **Read-only**: Codex MUST NOT
modify any file, commit, push, or change git state. Only output is
the structured findings report appended to
`specs/SPEC-014-impl-audit.md` (or written as a new file if the
operator instructs otherwise — but DEFAULT is append).

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation audit of Phase 1B
of SPEC-014 v0.8 in the working tree at
`/Users/augstar/macprovider-poc`, on branch
`feat/spec-014-provider-portal`. Phase 1B extends the Phase 1A
single-file bundle at `frontdoor/provider-portal/index.html` with
Surface B (Setup & Updates) — see the Phase 1B BUILD prompt for
the exact deliverable contract.

Phase 1A is LOCKED. Findings that concern only Phase 1A surfaces
(Machine, sign-in, AUTH-3 loader) are out of scope UNLESS Phase 1B
edits have regressed them. Phase 1C has not landed — findings that
would only matter once Surface C/D/E lands are out of scope.

This is a **read-only review**. You MUST NOT edit any file, commit,
push, or modify the git state. Your only output is the structured
findings report.

## Context

Phase 1B's BUILD prompt is
`specs/BUILD_SPEC_014_IMPL_PHASE_1B_PROMPT.md`. The 9 critical
constraints are binding. Spec-binding sections are
`specs/SPEC-014-provider-portal.md` §4.2 (Surface B), §5.1 table (a)
B.3 rows, §5.2 table (b) B.1/B.1a/B.2 rows, §5.4 thresholds,
§7 non-goals, §8(a) Surface B ACs, §8(e Q2) AC.

Upstream binding specs:
- `specs/SPEC-003-open-onboarding.md` §5 FR-D1 (requirements list
  verbatim) + §5 FR-D2 / FR-D2.1 (sizing table) + §4 FR-C2 (install
  one-liner) + §6.2 (CLI subcommand table — verify `status`,
  `update`, `autotune` exist; `install` does NOT exist in §6.2).
- `specs/SPEC-013-cli-autotune.md` §6 / NFR-4 (autotune local-only
  egress contract — bundle MUST NOT render autotune output).

## Required reading (in order)

1. The current `frontdoor/provider-portal/index.html` end-to-end —
   focus on the new `releasesFetch()`, `renderSetup()`,
   `renderRequirementsGrid()`, `renderSizingCard()`,
   `renderSetupSteps()`, `renderReleasesFeed()`,
   `renderReleaseCard()`, `snippetNode()`, and any state/CSS
   added for Surface B.

2. `frontdoor/provider-portal/README.md` (touched).

3. `specs/SPEC-014-provider-portal.md` §4.2, §5.1, §5.2, §5.4,
   §7, §8(a) Surface B group, §8(e) Q2 AC.

4. `specs/SPEC-003-open-onboarding.md` §5 (FR-D1 + FR-D2 +
   FR-D2.1) + §4 (FR-C2 install one-liner) + §6.2 (CLI subcommand
   table).

5. `specs/SPEC-013-cli-autotune.md` §6 / NFR-4.

6. `specs/BUILD_SPEC_014_IMPL_PHASE_1B_PROMPT.md`.

7. `specs/SPEC-014-impl-audit.md` Phase 1A audit history — round 1
   and round 2 (closure of A.2 + C.4). Verify Phase 1B has not
   regressed either fix.

## Severity definitions

Same five-tier scale as Phase 1A:
- **CRITICAL** — silent SPEC-014 contract violation; security/privacy
  hole (HTML injection from remote `body`, operator-key leak, token
  persistence, remote command execution); paints Phase 1C into a
  corner; regresses a Phase 1A fail-CLOSED branch.

- **HIGH** — a §8(a) Surface B AC, a §8(e) Q2 AC, or a constraint
  from the BUILD prompt 9-list is not satisfied; a §5.4 threshold
  is wrong by more than ±10%; FR-D1 / FR-D2 / FR-C2 / FR-C3 / FR-C4
  cite-or-string drift; B.3 silently hides a CORS / rate-limit
  failure; the bundle reads `Access-Control-Allow-Origin`.

- **MEDIUM** — partial honoring (e.g. notice text close-but-not-
  identical to the SPEC literal; B.2 step body wording subtly
  imperative-mood-drifted); DOM hygiene issue that is latent today;
  cosmetic visual deviation from §6 tokens.

- **MINOR** — quality issues (naming, dead CSS rules, defensive
  reads that are redundant).

- **QUESTION** — design choice where SPEC was silent.

## Critical constraints

1. **SPEC-014 v0.8 + SPEC-003 v0.9.2 + SPEC-013 v0.3 are LOCKED.**
   Findings recommending spec edits are out of scope.

2. **Read-only.** No file edits, no commits, no branches.

3. **Phase 1B scope.** Do NOT raise Phase 1C findings (Surface C/D/E,
   `check-bundle.sh`). DO raise findings if Phase 1B regressed Phase 1A.

## Audit categories — work through each

### Category A: B.1 requirements grid (§4.2 B.1, §5.2 table (b))

A.1  Exactly 4 cards rendered.

A.2  Verbatim FR-D1 strings (character-for-character match):
     - "Apple Silicon Mac (M1, M2, M3, M4)"
     - "macOS 14 (Sonoma) or later"
     - "~4-8 GB free disk space"
     - "Internet connection"

A.3  Section header cites SPEC-003 §5 / FR-D1 (NOT FR-C2).

### Category B: B.1a RAM-to-model sizing card (§4.2 B.1a, §5.2)

B.1  Three rows matching FR-D2 + FR-D2.1 verbatim:
     - "8 GB"  / "Llama 3.2 3B"            / "Llama 3.2 3B"
     - "16 GB" / "Llama 3.2 3B / Qwen 2.5 7B" / "Qwen 2.5 7B"
     - "24 GB+"/ "+ Qwen 2.5 14B"          / "Qwen 2.5 14B"

B.2  Visually distinct from the requirements grid.

B.3  Footer note presents FR-D2 as a recommendation, not a hard
     requirement.

### Category C: B.2 setup steps (§4.2 B.2, §5.2, SPEC-013 NFR-4)

C.1  Exactly 3 steps in order: Install, Verify routable, Optional
     Autotune.

C.2  Step 1 snippet is exactly
     `curl -fsSL https://get.streamvc.live/install.sh | bash` and
     cites SPEC-003 §4 / FR-C2.

C.3  Step 2 snippet is exactly `macprovider-cli status` and cites
     SPEC-003 §4 / FR-C4 / §6.2. The bundle MUST NOT cite
     `macprovider-cli install` (not in §6.2).

C.4  Step 3 snippet is exactly `macprovider-cli autotune` and cites
     SPEC-013 §6 / NFR-4 (or SPEC-003 §6.2).

C.5  Step 3 body does NOT contain an "autotune result" / "tuning
     complete" / "your latest autotune recommended" banner. Static
     greps must be zero.

C.6  Each step is a single copy-to-clipboard CTA — no POST/PUT/DELETE
     button, no remote-execution affordance.

### Category D: B.3 GitHub Releases feed (§4.2 B.3, §5.1 table (a), §5.4, §8(e) Q2)

D.1  Endpoint is exactly
     `${RELEASES_HOST}/repos/${state.cfg.releases_repo_owner_name}/releases`
     where `RELEASES_HOST === "https://api.github.com"`. No
     other GitHub hosts or paths.

D.2  5 min in-memory cache TTL. Reads `Date.now() - state.releases.ts
     < RELEASES_TTL_MS` and skips refetch.

D.3  Fetched on first mount of Surface B (sidebar click into
     `setup` route). No wall-clock polling timer.

D.4  `X-RateLimit-Remaining: 0` handling:
     - Sets `state.releases.rateLimited = true`.
     - Sets the loud notice text exactly
       `"GitHub API rate limit reached — release feed paused; refresh later."`.
     - Does NOT clear `state.releases.list` (previously cached list
       continues to render).
     - Does NOT silently retry.

D.5  `fetch()` rejection (CORS failure / network error) handling:
     - Sets the loud notice text exactly
       `"GitHub Releases unavailable — release feed disabled; see SPEC-014 Open Q2."`.
     - Does NOT silently hide.
     - Does NOT read `Access-Control-Allow-Origin` as application
       header. Static grep MUST be zero.

D.6  Non-2xx (other than 0-remaining) shows `"HTTP <N> from GitHub Releases."`.

D.7  Response shape: array root; up to 12 entries.

D.8  Per entry:
     - `tag_name` (fallback `name`) in monospace.
     - `published_at` sliced to `YYYY-MM-DD`.
     - Release notes rendered as plain text via a `<pre>` (NOT
       `innerHTML` of remote `body`). White-space `pre-wrap`,
       max-height 200px, overflow auto.
     - Copy-to-clipboard CTA `macprovider-cli update` (SPEC-003
       FR-C3 / §6.2).

D.9  NO "currently installed" badge (Open Q5 — deferred).

D.10 Section header cites the resolved owner/name.

### Category E: B.4 NOT rendered (§4.2 B.4)

E.1  No broadcasts panel anywhere on Surface B.

### Category F: Phase 1A regression check

F.1  AUTH-3 loader still rejects non-true `require_provider_tokens`
     and renders `renderUnavailable_FlagFalse()`.

F.2  AUTH-2 401/403/404 handling unchanged.

F.3  Stale-config guard still fires at the second consecutive
     authenticated failure per surface.

F.4  Same-origin invariant for coordinator routes still holds —
     Phase 1B did NOT introduce any code path that calls
     `state.cfg.coordinator_base_url` as a fetch base for
     `/v1/pool/check` or `/providers/{id}/earnings`. Cross-origin
     fetch ONLY to `https://api.github.com`.

F.5  Sign-out clears the releases state (no stale list visible
     after a re-sign-in with a different account).

### Category G: DOM hygiene + bundle hygiene + grep guards

G.1  Bundle is still single-file, no CDN, no `<script src>`, no
     `<link rel="stylesheet" href>` to anything external.

G.2  `innerHTML` count at most equal to Phase 1A (target zero).

G.3  Greps return zero:
     - `localStorage|sessionStorage|document\.cookie|window\.indexedDB|indexedDB`
     - `/poolz|/admin/blacklist|/admin/provisional|/admin/promote|/admin/reject|/admin/ledger|operator[_-]?key`
     - `your fleet|your machines|across machines|all machines|N machines|N/M|x3|machine grid`
     - `your latest autotune|autotune result|tuning complete|withdrawable|withdraw now|link bank|stripe`
     - `Access-Control-Allow-Origin`

G.4  No `<link rel="preconnect">` to GitHub.

G.5  No service worker, no `navigator.sendBeacon`, no
     `XMLHttpRequest`, no WebSocket added by Phase 1B.

G.6  Release `body` is rendered via `document.createTextNode` /
     `el(...)`-style text-only construction (not assigned to
     `innerHTML`). Verify by reading the renderReleaseCard /
     plain-text body construction site.

### Category H: Visual tokens + accessibility (§6, §8(d))

H.1  No new color literal that isn't a `--*` token. Phase 1B may
     reuse `--accent`, `--accent-dim`, `--ok`, `--warn`, `--bad`
     but MUST NOT introduce a one-off hex.

H.2  All snippets are reachable with a focus ring (default).

H.3  Release notes details/summary widget is keyboard-operable
     (native `<details>` is fine).

### Category I: Forward-compatibility

I.1  Phase 1C will add Surface C (Earn) using
     `/providers/{id}/earnings` — the same endpoint Phase 1A
     already polls. Phase 1B should not re-use the `earn` cache
     under a conflicting name.

I.2  `check-bundle.sh` Phase 1C build-time grep guard will codify
     constraint 8 of Phase 1B's BUILD prompt. Phase 1B should not
     introduce any string the grep would falsely match.

### Category O: Anything else

Anything the operator should know that doesn't fit A-I.

## Output structure

Append to `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
a new top-level section:

```
---

# Phase 1B audit — round 1

**Audited:** working tree on branch feat/spec-014-provider-portal (uncommitted Phase 1B)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1B, round 1 of N
**Date:** 2026-06-21
**Total findings:** [N CRITICAL / N HIGH / N MEDIUM / N MINOR / N QUESTION]
**Phase 1B readiness:** [READY TO COMMIT | FIX REQUIRED]

---

## Executive summary

[2-3 paragraphs.]
```

Then for each category A-I + O, write a section with findings in
the Phase 1A format:

```
### A.1  [TITLE]   [CRITICAL | HIGH | MEDIUM | MINOR | QUESTION]
Location: index.html line N-M (or README.md)

[Body]
```

If category empty, write `(no findings)`.

## Out of scope

- Spec edits (SPEC-014 / SPEC-003 / SPEC-013 LOCKED).
- Phase 1C work (Surface C / D / E, `check-bundle.sh`).
- d-inference internals.
- Operator deployment topology (Q7).

=== END PROMPT ===
```
