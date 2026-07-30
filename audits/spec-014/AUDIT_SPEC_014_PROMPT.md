# Audit prompt — the current SPEC-014 draft (Provider Portal — seller-facing web surface)

Operator-paste prompt to audit the current SPEC-014 draft
(`specs/SPEC-014-provider-portal.md`).

**Cross-model pattern:** the current SPEC-014 draft was drafted by Claude (Opus)
on 2026-06-21 per `specs/BUILD_SPEC_014_PROMPT.md` v0.12. Audit
runs in **Codex CLI** for independence. The audit report goes into
`specs/SPEC-014-audit.md`. Re-audit each subsequent revision
(`v0.2 → round 2`, `v0.3 → round 3`, …) until 0 CRITICAL / 0 HIGH /
0 MEDIUM remain.

**Expected duration:** ~30-45 min per Codex round. SPEC-014 is a
read-side web surface over already-existing endpoints; the highest-
leverage checks are (i) every UI field is sourced from an
endpoint or static artifact that actually exists today, (ii) no
operator-keyed endpoint can be reached from browser code, (iii) no
fiat / Stripe / withdrawal UI sneaks into Surface C, (iv) deployment-
mode gating is binding and fail-CLOSED, (v) every deferred field
has an explicit owning Open Q in §5 table (c).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing the current SPEC-014 draft, the Provider Portal (seller-facing
web surface) spec at
/Users/augstar/macprovider-poc/specs/SPEC-014-provider-portal.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, and let
the operator decide fixes. The operator has read the spec; they
want an independent second opinion on what is missing, wrong, or
under-specified before any implementation work starts.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-014-audit.md

Format: structured audit report. Findings grouped by category
below, each finding tagged with severity (CRITICAL / HIGH /
MEDIUM / MINOR / QUESTION) and location (section number + line
range when possible). Match the rigor and tone of prior audit
reports (specs/SPEC-013-audit.md, specs/SPEC-010-audit.md,
specs/SPEC-011-audit.md).

## Severity definitions

- **CRITICAL** — would cause production failure on rollout, silent
  regression of locked spec behavior, scope creep into a locked
  upstream spec (SPEC-001 v1.3, SPEC-002 v1.3.5, SPEC-003 v0.9.2,
  SPEC-005 v0.3, SPEC-009 v0.1, SPEC-013 v0.3), security regression
  (operator key reachable from browser, browser-callable operator
  endpoint cited as a portal source), or violation of the locked
  product framings — specifically:
    - any UI element that implies fiat withdrawal is imminent or
      available (SPEC-005 §1.3 + §2.1 D1 lock),
    - any multi-Mac aggregation surface in v0.1 (Open Q1 lock),
    - any path that bypasses the deployment-mode gating
      (`auth.require_provider_tokens` MUST be `true` for the portal
      to function),
    - any token rotation or machine removal UI invented inside
      SPEC-014 (Open Q6 defers).

- **HIGH** — would cause significant implementer confusion, a
  predictable v0.2 patch within the first month of v1 rollout,
  citation of a non-existent spec section / endpoint / JSON path,
  a UI field with no §5 row (or a §5 row pointing at an endpoint
  that does not return the named JSON path), an AC that cannot be
  verified as written, or a privacy / auth boundary defined
  loosely enough that a reasonable implementer would weaken it.

- **MEDIUM** — quality issues that don't block v0.1 but should be
  cleaned in v0.2. Naming inconsistencies, citation typos
  (`§7.4` vs `§7.5`), prose drift inside an otherwise-precise
  surface description, AC text that is verifiable but ambiguous.

- **MINOR** — wording, formatting, or stylistic drift that does
  not affect implementation or contract correctness.

- **QUESTION** — genuinely unresolved design choices the spec
  couldn't decide alone. Distinguish from the §9 Open Qs the spec
  already names — those are not findings unless they hide a
  CRITICAL / HIGH underneath (e.g. the Q is actually a load-
  bearing decision v0.1 cannot defer).

## Critical constraints to honor while auditing

**1. SPEC-001 v1.3, SPEC-002 v1.3.5, SPEC-003 v0.9.2, SPEC-005
v0.3, SPEC-009 v0.1, SPEC-013 v0.3 are LOCKED.** Any SPEC-014
clause that requires a normative edit to one of these locked
specs (other than as a named Open Q amendment) is a CRITICAL
finding ("scope creep across spec boundary"). v0.1 names amendments
as dependencies; SPEC-014 does not author them.

**2. The deployment-mode gating is BINDING.** The portal is
available ONLY when the coordinator runs with
`auth.require_provider_tokens = true`. Rationale: SPEC-005 §11.5
disables `GET /providers/{id}/earnings` at the route layer in
`false` mode; the only remaining economics surface
(`/admin/ledger/providers`) is operator-keyed and forbidden from
browser code. Any clause that allows the portal to function in
`false` mode (degraded mode, partial UI, "skip earnings", etc.)
is CRITICAL.

**3. The portal MUST NEVER reach an operator-keyed endpoint.**
`/poolz` (FR-O2), `/admin/blacklist`, `/admin/provisional`,
`/admin/promote/*`, `/admin/reject/*`, `/admin/ledger/*` are all
gated by an operator key the portal MUST NEVER see. Any clause
that references one of these paths as a portal data source or as
a fallback is CRITICAL. SPEC-014 §8(b) + §8(c) require a build-
time grep — verify the AC exists and is unambiguous.

**4. No fiat, no Stripe, no checkout. Period.** SPEC-005 §1.3
and §2.1 D1 lock this. Any Surface C element that implies fiat
withdrawal is imminent or available (country selector, "Link
bank via Stripe" button, account-type picker, payout-now CTA) is
CRITICAL. The future payout rail lives behind Open Q3 and ships
as a static "future spec" badge ONLY.

**5. Single-machine in v0.1.** Multi-Mac aggregation (machine
grid, "N/M machines online" header, "x3 machines" attention chip,
"your fleet" copy) is OUT of scope and deferred to Open Q1. Any
clause that reintroduces a multi-Mac concept in v0.1 surfaces is
CRITICAL.

**6. No invention.** Every UI field in §4 MUST live in exactly
one §5 table (a) endpoint-backed, (b) static / spec-backed, or
(c) deferred. Inventing endpoints, JSON shapes, or spec sections
inside SPEC-014 is HIGH. A field that resists categorisation
goes in (c) — there is no fourth bucket.

**7. Clean-room boundary (Darkbloom screenshots).** The user
shared screenshots from a competitor seller portal (Darkbloom).
SPEC-014 §10.3 records the stance. Any clause that cites Darkbloom
as normative, copies strings verbatim, or requires inspecting
Darkbloom source is CRITICAL. (the current SPEC-014 draft is not expected to
copy Darkbloom; flag any such reference.)

**8. Telemetry / privacy invariant (Surface B.2 autotune).**
SPEC-013 §6 / NFR-4 forbids any non-HF egress during autotune.
Surface B.2 step 3 is therefore copy-to-clipboard CTA ONLY — no
autotune results banner, no autotune ingestion. Any clause that
implies the portal renders autotune output is CRITICAL.

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-014-provider-portal.md`
   v0.1 — the spec under audit. Read all 11 sections + all six AC
   groups fully. Bias toward reading §2 (auth + deployment-mode
   gating), §4 (surface inventory), §5 (field-source tables +
   thresholds), and §8 (ACs) most carefully — these are the
   binding surface. §6 (visual tokens) is inherited from
   SPEC-009; §10 + §11 are coupling / phasing.

2. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_014_PROMPT.md`
   — the ORIGINATING prompt that commissioned the current SPEC-014 draft (v0.12
   per the prompt header). This is the source-of-truth for what
   the operator asked for. The five surfaces, the deployment-mode
   gating, the eleven Open Qs, the four §5 tables, the layered
   ACs, the six critical constraints, and "what the spec must NOT
   do" all come from this prompt. If the current SPEC-014 draft contradicts the
   originating prompt or omits a required surface / Open Q / AC
   group, that is a CRITICAL coverage gap (the spec was
   commissioned with an explicit FR list and a missing FR is a
   contract violation).

3. `/Users/augstar/macprovider-poc/CLAUDE.md` and
   `/Users/augstar/macprovider-poc/AGENTS.md` — project
   conventions, especially the PR workflow rule, the Augustas11
   git identity rule, and the spec naming pattern.

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.3 — focus on:
   - §6.5 hello / hello_ack message schemas — confirm which fields
     SPEC-014 §4 / §5 cite are actually present in the hello
     payload (`provider_id`, `hostname`, `model_id`,
     `model_params_b`, `ram_gb`, `max_context_tokens`,
     `max_concurrency`, `throughput_tps_estimate`, `binary_version`,
     `attestation`, `endpoint_url`).
   - §6.4 `/v1/health` response shape — confirm that SPEC-014 does
     NOT claim `/v1/health` returns rate or latency histograms it
     doesn't actually return.
   - Confirm the "WS-only, not browser-callable" claim for the
     hello fields holds (no shadow browser-callable endpoint
     existed).

5. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.5 — focus on:
   - §7.3 Token storage — opaque 32-byte random hashed as SHA-256;
     no introspection possible.
   - §7.4 Operator endpoints — `/poolz` operator-keyed (FR-O2);
     `/v1/pool/check` PUBLIC (no auth) returning `{provider_id,
     tier, state}`; `/admin/blacklist` operator-keyed.
   - §7.5 Provisional admission endpoints — operator-keyed.
   - FR-P12 bearer-token validation; the auth.require_provider_tokens
     flag semantics (`false` vs `true`).
   - Confirm the "no browser-callable per-machine detail endpoint
     exists today" claim that SPEC-014's Open Q5 deferrals rely on.

6. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   v0.9.2 — focus on:
   - §4 / FR-C2 install.sh contract — step 10 generates
     `~/.config/macprovider/provider_id`.
   - §5 / FR-D1 requirements list — confirm SPEC-014 B.1 cites
     the four fields verbatim (Apple Silicon Mac, macOS 14+,
     ~4-8 GB free disk, Internet connection).
   - §5 / FR-D2 RAM-to-model sizing — confirm SPEC-014 B.1a
     is a recommendation, not a hard requirement, and cites the
     RAM tiers correctly (8 GB → 3B, 16 GB → 7B default,
     24 GB+ → 14B default).
   - §6.2 macprovider-cli subcommand table — verify SPEC-014 does
     NOT cite a non-existent CLI verb. The table lists `serve`,
     `self-test`, `status`, `update`, `update --check`,
     `uninstall`. `install` is NOT a subcommand.
   - FR-C7 advisory version nudge — confirm SPEC-014 treats it as
     advisory only, never a hard floor.
   - FR-C9 self-mint provisional token path — confirm the
     two-source-of-token rationale in §2.1 AUTH-1 is accurate.
   - FR-C9.3 binary token persistence — confirm the file/key the
     spec names (`~/.config/macprovider/config.yaml` top-level
     `provider_token:`) matches FR-C9.3 verbatim.

7. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md`
   v0.3 — focus on:
   - §1.3 out-of-scope (Stripe, fiat, checkout, refunds).
   - §2.1 D1 donation-only.
   - §2.11 D11 no-new-auth / no new-delivery infra.
   - §11.4 `GET /providers/{id}/earnings` JSON shape — confirm
     SPEC-014 cites the exact response keys
     (`total_credits`, `current_window_credits`,
     `last_payout_ready.window_start_utc`,
     `last_payout_ready.window_end_utc`,
     `last_payout_ready.provider_credits`).
   - §11.5 Provider endpoint authorization — confirm SPEC-014
     mirrors the 401 / 403 / 404 semantics and the
     "do not enumerate valid providers" property.
   - §11.5 route-disabled mode in `auth.require_provider_tokens
     = false` — confirm SPEC-014's deployment-mode-gating
     rationale is correctly grounded.
   - §13 `endpoints.provider_earnings.rate_limit_per_minute = 60` —
     confirm SPEC-014's thresholds table cites the right key.

8. `/Users/augstar/macprovider-poc/specs/SPEC-009-console-v2.md`
   v0.1 — focus on:
   - §2 ASCII layout style — confirm SPEC-014's §3 layout matches
     the geometry and conventions.
   - §6 visual tokens — confirm SPEC-014's §6 "inherits verbatim"
     claim is honest (no covert deviation that should have been
     listed).

9. `/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md`
   v0.3 — focus on:
   - §6 / NFR-4 telemetry / privacy contract — confirm SPEC-014's
     B.2 step 3 "autotune banner prohibited" rationale is correctly
     grounded.

10. `/Users/augstar/macprovider-poc/phase3-binary/README.md` —
    confirm SPEC-014 does NOT cite a README section that does not
    exist. The current top-level sections are "Join the Network",
    "Distribution Files", "Trust Caveat", "Provider economics".
    There is no "Requirements" section in this README — the
    canonical requirements list lives in SPEC-003 §5 / FR-D1.

## Audit categories — work through each

### Category A: Deployment-mode gating + auth boundary (HIGHEST PRIORITY)

A.1  Walk §2 AUTH-3 + §2.4 deployment-mode gating. Confirm the
     portal CANNOT function in `auth.require_provider_tokens =
     false` mode. Critical question: is there ANY path through
     §4 (any surface) that admits a "partial" or "degraded" mode
     when the flag is `false`? If yes = CRITICAL.

A.2  Walk §2 AUTH-1. Confirm both `provider_id` AND
     `provider_token` are required to sign in. The portal MUST
     NOT attempt token-only sign-in (tokens are opaque; SPEC-002
     §7.3). If §2.1 leaves room for a "token only" path = HIGH.

A.3  Walk §2 AUTH-2. Confirm 401 / 403 / 404 are handled WITHOUT
     leaking whether the provider_id exists (SPEC-005 §11.5).
     If any AC or prose distinguishes 403 from 404 in user-visible
     text = HIGH.

A.4  Walk §2 AUTH-3 stale-config guard. Confirm:
       - portal-config.json fetch failure → fail CLOSED, not
         permissive default;
       - in `true` mode, persistent 401/403/404 does NOT silently
         flip the UI to unavailable-mode page; surfaces an
         explicit "deployment may be misconfigured" notice.
     If either is missing = HIGH.

A.5  Walk §8(b) and confirm the bundle-grep AC enumerates
     `/poolz`, `/admin/blacklist`, `/admin/provisional`,
     `/admin/promote`, `/admin/reject`, `/admin/ledger`. If any
     operator-keyed path is omitted from the grep list = HIGH.

A.6  Walk §10.4 operator runbook. Confirm `portal-config.json`
     and `auth.require_provider_tokens` are both named, and the
     diff-before-flip step is normative. If runbook is missing
     or hand-wavy = MEDIUM.

### Category B: No-invention check (§5 tables exhaust §4 fields)

B.1  Walk every UI field in §4 (A.1 through E.1, plus the D
     placeholder). For each, confirm it lives in EXACTLY ONE of
     §5 (a), (b), or (c). If a field is missing from all three
     = HIGH. If a field is in multiple = MEDIUM.

B.2  Walk every row in §5 (a) endpoint-backed. For each:
       - Does the cited endpoint exist (verify against SPEC-002
         §7.4 / SPEC-005 §11.4 / GitHub Releases API)?
       - Does the cited JSON path appear in the documented
         response shape?
       - Is the polling cadence + cache policy plausible against
         the upstream rate limit (SPEC-005 §13 60/min;
         GitHub 60/IP/hr)?
     Any mismatch = HIGH.

B.3  Walk every row in §5 (b) static / spec-backed. For each:
       - Does the cited source artifact (spec section, README
         heading, or portal-config.json key) exist?
       - Is the display mode reasonable?
     Any mismatch = HIGH.

B.4  Walk every row in §5 (c) deferred. For each:
       - Does the row name a concrete Open Q (Q1-Q11)?
       - Does the Open Q in §9 actually cover this deferral?
     A row pointing at an Open Q that doesn't list the field is
     HIGH (the writer cited Q5 generically when it should have
     been Q10, etc.).

B.5  Walk §5.4 thresholds. For each variable:
       - Is the default value listed?
       - Is the source SPEC-002 config key cited (or "new" /
         Open Q)?
       - Is the override path documented?
     Any threshold without a config-key source or a TBD pointing
     at a specific Open Q = HIGH.

### Category C: Operator-keyed endpoint safety

C.1  Grep §4 + §5 + §8 + §10 for `/poolz`, `/admin/`,
     `coordinator-cli`, `operator key`, `operator bearer`. Any
     citation of an operator-keyed endpoint as a portal data
     source = CRITICAL. Citations as forbidden ("MUST NEVER call")
     are fine.

C.2  Walk §10.1 SPEC-002 dependency description. Confirm the
     read paths (`/v1/pool/check`, `/providers/{id}/earnings`)
     are the ONLY coordinator endpoints SPEC-014 touches. If a
     phantom dependency on `/poolz` or `/admin/*` slipped in =
     CRITICAL.

C.3  Walk §11 phasing. Confirm each phase's "read paths" stay on
     the public + provider-bearer endpoints only. If a phase
     proposes calling an operator-keyed path = CRITICAL.

### Category D: No-fiat enforcement (Surface C)

D.1  Walk §4.3 Surface C. Confirm:
       - C.1 is three credit cards displaying integer credits
         verbatim;
       - C.2 is a static "future spec" badge ONLY;
       - C.3 + C.4 are NOT rendered;
       - no country selector / "Link bank" / account-type picker /
         Stripe button appears in any AC or prose.
     Any contradiction = CRITICAL.

D.2  Walk §8(a) Surface C ACs. Confirm the negative ACs (no
     country selector, no Stripe, no payout-now CTA) exist and
     are unambiguous. Missing negative ACs = HIGH.

D.3  Walk §4.3 C.5 API surface. Confirm the only endpoint cited
     is `/providers/{id}/earnings`. Any additional endpoint =
     HIGH.

### Category E: Single-machine enforcement

E.1  Grep §4 + §8 + §11 for "fleet", "machines" (plural), "across
     machines", "all machines", "N/M", "x3". Any v0.1 usage =
     CRITICAL (multi-Mac scope creep).

E.2  Walk §8(f) Single-machine ACs. Confirm a build-time grep AC
     enforces the prohibited strings. Missing = HIGH.

E.3  Walk §4.1 A.3 needs-attention panel. Confirm there is NO
     machine-count chip per row. Any "(x3)" or similar = CRITICAL.

### Category F: Surface inventory completeness

F.1  Walk every surface A through E and confirm:
       - All A.1, A.2, A.3 fields are sourced.
       - A.4 lives entirely in §5 table (c) and is NOT rendered
         as a greyed-out placeholder in v0.1.
       - B.1 cards exactly mirror FR-D1.
       - B.1a is a separate adjacent card (not a fifth
         requirements card).
       - B.2 steps cite real CLI verbs (no `macprovider-cli
         install`).
       - B.3 lists releases; no per-entry "currently installed"
         comparison badge.
       - B.4 broadcasts panel is NOT rendered.
       - C is C.1 + C.2 only.
       - D is ONE placeholder card with three bullets, zero API
         calls.
       - E.1 is provider_id + tier + state + coordinator_base_url
         only.

F.2  Walk Open Q5 body. Confirm every SPEC-001 hello field that
     appears in §5 (c) is named verbatim in Q5's enumeration. If
     a deferred field cites Q5 but Q5 doesn't list it = HIGH.

F.3  Walk Open Q5 body for the SPEC-001 metrics-shape amendment
     (rate / latency histograms). Confirm it is explicitly named.
     If missing = MEDIUM.

### Category G: Acceptance criteria correctness

G.1  Walk each AC in §8(a)-(f). For each, write down (in the
     audit) the exact test setup and assertion that would
     verify it. If you cannot do this in 3-5 lines, the AC is
     ambiguous = HIGH per ambiguous AC.

G.2  Coverage gap check: walk every surface in §4 and confirm at
     least one AC exercises it. Walk every Open Q and confirm
     §8(e) has a corresponding "if not answered, portal does X"
     line. Missing coverage = HIGH.

G.3  Privacy ACs §8(d): confirm no buyer-identifying field is
     rendered anywhere. If any §5 (a) JSON path includes buyer
     data = CRITICAL.

G.4  Field-source AC §8(c): confirm the "every UI field appears
     in exactly one §5 table" property is verifiable (e.g. by
     enumerating components against §5 rows). If unverifiable as
     written = HIGH.

### Category H: Open Q hygiene

H.1  Walk Q1 through Q11. For each:
       - Question stated.
       - Why-it-matters stated.
       - Who-decides stated.
       - Spec-assumes stated.
       - Portal-renders-if-unanswered stated.
     Any missing field = MEDIUM.

H.2  Confirm Q5 is the omnibus that covers all of: hostname /
     model / RAM / binary_version / capacity / attestation /
     endpoint_url; signing tier; heartbeat history; per-provider
     routing weight; request tail + privacy-redaction policy;
     coordinator-broadcast relay; SPEC-001 metrics-shape
     amendment. Missing items = HIGH.

H.3  Confirm Q10 is the browser-local bridge (CORS + port-
     discovery + HTTPS mixed-content for `/v1/health`). Missing
     framing = MEDIUM.

H.4  Confirm Q11 is the future notification-delivery spec; SPEC-
     014 does NOT invent email/Slack/push/SMS infra inline.
     Missing constraint = HIGH (D11 violation risk).

### Category I: Citation accuracy

I.1  Spot-check every SPEC-002 §7.x citation. Common errors:
     `/admin/blacklist` is in §7.4 (operator endpoints), NOT
     §7.5; `/v1/pool/check` is §7.4. Mis-citation = MEDIUM.

I.2  Spot-check every SPEC-005 §11.x citation. §11.4 is
     `/providers/{id}/earnings`; §11.5 is "Provider endpoint
     authorization". §1.3 is out-of-scope; §2.1 is D1. §2.11 is
     D11. §13 is configuration.

I.3  Spot-check every SPEC-003 citation. §4 / FR-C2 is install.sh.
     §5 / FR-D1 is requirements list. §5 / FR-D2 is RAM-to-model
     sizing. §6.2 is CLI subcommands. FR-C7 is advisory version
     nudge. FR-C9.x is provisional self-mint chain.

I.4  Spot-check every SPEC-001 citation. §6.5 is hello /
     hello_ack. §6.4 is `/v1/health`.

I.5  Spot-check every SPEC-013 / SPEC-009 citation. §6 / NFR-4 in
     SPEC-013 is telemetry / privacy. SPEC-009 §6 is visual
     tokens.

### Category J: Layout + visual-token inheritance

J.1  Walk §3 layout. Confirm sidebar geometry (220 px), sidebar
     item ordering, mobile-collapse breakpoint match SPEC-009
     §2. Any silent deviation = MEDIUM.

J.2  Walk §6 visual tokens. Confirm "inherits SPEC-009 §6
     verbatim" claim is honest (no deviations or all listed).
     Silent deviation = MEDIUM.

J.3  Walk §3 host string + Open Q7. Confirm the implementation is
     host-agnostic and `provider.streamvc.live` is only a proposal,
     not hard-coded. If §11 phasing names the host as a binding
     decision = HIGH.

### Category K: Threats / privacy / data-handling

K.1  Walk §2.1 AUTH-1 storage. Confirm token storage is in-memory
     ONLY in v0.1 (no `localStorage`, no `sessionStorage`, no
     cookie). Any deviation = HIGH.

K.2  Walk §4.3 Surface C. Confirm no buyer-identifying data is
     rendered. Any reference to buyer `request_id`, buyer account,
     prompt text, completion text, IP, API key in the portal =
     CRITICAL.

K.3  Walk §4.1 A.3 + §4.2 B.3 CTAs. Confirm copy-to-clipboard
     only; no remote execution path. Any "click to update" /
     "click to restart" button = CRITICAL.

### Category L: Phasing realism

L.1  Walk §11 Phase 1A. Confirm it covers scaffolding + auth +
     deployment-mode + Surface A.1/A.2/A.3 only. If the phase
     mixes in Surface B or C work = MEDIUM (a single-PR phase
     should stay narrow).

L.2  Walk §11 Phase 1B. Confirm it adds Surface B and the
     GitHub Releases feed only. Mixed phases = MEDIUM.

L.3  Walk §11 Phase 1C. Confirm it adds Surface C aggregate +
     Surface D placeholder + Surface E + sidebar polish. Missing
     surface = MEDIUM.

L.4  Confirm each phase ends with an IMPL audit gate per the
     audit-loop rule. Missing gate = MEDIUM.

### Category M: Anything else (length budget, style, dependencies, etc.)

M.1  Length budget. Soft target was 450-700 lines (BUILD prompt).
     If the spec is significantly over (>900 lines without
     justification), flag as MINOR.

M.2  Style. No emojis, no "we believe / we feel / we think",
     declarative voice, max line length 120. Any violation =
     MINOR.

M.3  §10.3 clean-room paragraph: confirm the Darkbloom stance is
     documented; the screenshots are not normative; no source
     inspection. Missing = HIGH (Constraint #6 violation).

M.4  Anything else the operator should know that doesn't fit
     A-L.

## Output structure

Write to `/Users/augstar/macprovider-poc/specs/SPEC-014-audit.md`.
Top-of-file frontmatter:

```
# the current SPEC-014 draft — Audit Report

**Audited:** the current SPEC-014 draft (specs/SPEC-014-provider-portal.md)
**Auditor model:** [Codex / GPT-5 / etc.]
**Audit round:** 1 of N
**Date:** 2026-06-21
**Total findings:** [N CRITICAL / N HIGH / N MEDIUM / N MINOR / N QUESTION]

---

## Executive summary

[2-4 paragraphs. State whether the current SPEC-014 draft is ready to lock as
drafted, ready with the CRITICAL findings addressed, or needs
structural revision. Be specific about what the operator should
do next.]
```

Then for each category A-M, write a section. For each finding:

```
### A.2  [SHORT TITLE]   [CRITICAL | HIGH | MEDIUM | MINOR | QUESTION]
Location: §X.Y, line ~NNN-MMM

[What the spec says or fails to say. 1-3 sentences.]

[Why it matters. 1-3 sentences. Reference a concrete failure
scenario or a specific reader confusion.]

[Recommendation. 1-2 sentences. What v0.2 should do — but don't
rewrite the spec for the operator.]
```

If a category has zero findings, write `(no findings)` under the
category header — don't omit the section.

## Out of scope for this audit

- Inspecting Darkbloom source (clean-room boundary; see
  Constraint #7)
- Rewriting the spec
- Implementing the portal
- Auditing SPEC-001 v1.3, SPEC-002 v1.3.5, SPEC-003 v0.9.2,
  SPEC-005 v0.3, SPEC-009 v0.1, SPEC-013 v0.3 themselves
  (they are locked; SPEC-014 layers on top)
- Re-litigating the "single-machine in v0.1" framing
  (Constraint #5)
- Re-litigating the "no fiat / no Stripe" framing (Constraint #4)
- Designing the v0.2 audit-response (separate session after v0.1
  audit closes)
- Choosing the portal host string (Open Q7 — operator decides)

## Done criteria

You are done when:

- /Users/augstar/macprovider-poc/specs/SPEC-014-audit.md exists
- Every category A-M has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Executive summary states a clear "lock as-is" / "lock with these
  CRITICAL/HIGH/MEDIUM findings closed" / "needs structural
  revision" verdict
- Total CRITICAL / HIGH / MEDIUM counts are honest (do not
  under-report to avoid a revision round; do not over-report to
  seem rigorous)

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `omc ask codex` on the host that has the repo checked
  out (per memory note `feedback-spec-audit-loop-before-pr`).
- Expected wall-clock: 30-45 min per Codex round.
- Loop discipline: each round writes to `specs/SPEC-014-audit.md`
  (overwrite the file or append a section per round — pick one
  and stick to it; the SPEC-013 audit file is the precedent).
- Fix discipline: each round's findings get fixed in
  `specs/SPEC-014-provider-portal.md` and the version bumps
  (v0.1 → v0.2 → …) with an audit-history entry in the header.
- Do NOT open a PR until 0 CRITICAL / 0 HIGH / 0 MEDIUM remain.
- After lock, append a decision-log entry to
  `beta/DECISION_CRITERIA.md` summarising: trigger, single-machine
  framing, what shipped (Surfaces A.1/A.2/A.3, B, C aggregate, D
  placeholder, E identity), what was deferred to v0.2 (Open Qs
  1-11).
- After lock, generate phased build prompts
  (`BUILD_SPEC_014_v1_0_IMPL_PHASE_1A_PROMPT.md`, etc.) per the
  spec's §11 phasing. Each phase ends with its own IMPL audit
  gate (`AUDIT_SPEC_014_v1_0_IMPL_PHASE_*_PROMPT.md`) before its
  PR opens.
