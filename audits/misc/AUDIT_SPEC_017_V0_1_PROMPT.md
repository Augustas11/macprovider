# Audit prompt — SPEC-017 v0.1 Network Stats API

Operator-paste prompt to audit SPEC-017 v0.1
(`specs/SPEC-017-network-stats-api.md`), MacProvider's first public
network-statistics HTTP contract.

**Cross-model pattern:** the spec was drafted by Claude (executing
`specs/BUILD_SPEC_017_NETWORK_STATS_API_v0_1_PROMPT.md`). Per
[[feedback-codex-only-audits]], audits MUST run in **Codex CLI only**
via `omc ask codex` (NOT in Claude internal subagents — the audit-loop
discipline depends on a diverse-model lens). Round N output goes to
`specs/SPEC-017-rN-audit.md`; subsequent rounds get their own file
(`specs/SPEC-017-r2-audit.md`, etc.) per
[[feedback-spec-audit-file-convention]] — do NOT inline narrative in the
SPEC body.

Expected duration: ~30–45 min per round. SPEC-017 v0.1 is shorter than
SPEC-015 / SPEC-016 (~600 lines) and contains no cryptography or
canonicalization — its failure modes cluster on (1) contract
ambiguity for partner clients, (2) earnings-visibility privacy model
under-specification, (3) rollup-pipeline freshness/late-event handling,
(4) cross-spec invariant drift against SPEC-002 / SPEC-005 / SPEC-006 /
SPEC-014 / SPEC-016.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-spec-017` (the SPEC-017 worktree off
origin/main).

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-017 v0.1, MacProvider's first public
network-statistics HTTP contract at
/Users/augstar/macprovider-spec-017/specs/SPEC-017-network-stats-api.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, let the
operator decide fixes. The operator has read the spec; they need an
independent second opinion on what is missing, wrong, or
under-specified.

Output:
  /Users/augstar/macprovider-spec-017/specs/SPEC-017-r1-audit.md
  (round 2 -> SPEC-017-r2-audit.md, etc; one file per round, NEW file each
  time. Do NOT inline narrative into the SPEC body.)

Format: structured audit report. Findings grouped by category, each
finding tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION) and
location (section number + line range when possible). Match the rigor
of the prior audit reports in this repo
(specs/SPEC-016-r9-audit.md through specs/SPEC-016-r21-audit.md,
specs/SPEC-015-audit.md). Each round writes a fresh file; do NOT
append to or overwrite previous rounds.

## Severity definitions

- **CRITICAL** — would cause partner/console/portal client breakage,
  ambiguous contract that two conforming implementations could resolve
  differently and serve incompatible JSON, privacy leak of exact
  earnings beyond §6's policy, missing handler isolation that lets
  a stats request reach billing/session OLTP tables, violation of a
  locked SPEC-002 / SPEC-005 / SPEC-006 / SPEC-014 / SPEC-016 invariant,
  trust-root misrepresentation, or scope creep that gates v0.1 LOCK on
  code existing in the repo.
- **MAJOR** — would cause significant operator burden, predictable
  partner confusion, a v0.2 patch within first month of deployment,
  rate-limit policy that's enforceable in one tier but not another,
  ambiguity in window/sort/limit semantics, unjustified numeric
  thresholds (cache TTLs, bucket boundaries, freshness budgets,
  rollup cadences), hand-wavy SHOULD where the spec needs MUST,
  drift from the BUILD-prompt MUST-pin list.
- **MINOR** — quality issues that don't block v0.1 but should be
  cleaned in v0.2. Naming inconsistencies, missing cross-references,
  underspecified edge cases that won't fire frequently, prose
  clarity, RFC-2119 misuse with minor impact.
- **QUESTION** — genuinely unresolved design choices the spec
  couldn't decide alone. Operator input required. Distinguish from
  the §11 Open Questions the spec already names — those are not
  findings unless they hide a CRITICAL/MAJOR underneath.

## Critical constraints to honor while auditing

1. **SPEC-002 v1.4, SPEC-005 v0.3, SPEC-006 v0.9, SPEC-014 v0.8,
   SPEC-016 v0.1.19 are LOCKED** (or the latest-pinned versions in
   each SPEC's line 3). SPEC-017 v0.1 layers on top of them. Any
   SPEC-017 clause that would REQUIRE a normative change to those
   locked specs is a CRITICAL finding ("scope creep across spec
   boundary") UNLESS the SPEC-017 clause cleanly defers to a candidate
   annotation on the dependency spec (the SPEC-014 v0.9 candidate for
   the earnings-visibility-toggle UI is one such clean deferral; verify
   it does not assume the v0.9 candidate is already merged).

2. **v0.1 is normative spec only, no implementation.** This spec
   does NOT ship code. Any clause that gates v0.1 LOCK on the rollup
   pipeline existing in the repo, on a Postgres role being created, on
   nginx config being deployed, on a portal toggle being shipped, etc.,
   is CRITICAL ("scope creep into BUILD_SPEC_017 territory"). The
   SPEC may describe MUST behaviors for the future implementation; it
   MUST NOT condition its own lock on those existing.

3. **Locked Q1–Q4 design picks (§2).** The four pillar decisions
   (separate rollup pipeline, public overview + optional keys on
   leaderboard, bucketed-default earnings + opt-in exact, embed in
   coordinator binary) are LOCKED at v0.1. The audit MAY challenge
   the DETAILS below each pick (bucket boundaries, key issuance UX,
   rollup cadence, isolation seam exactness) but MUST NOT challenge
   the pick itself — those go in the operator-questions section, not
   the findings, with `[Q on locked decision]` prefix.

4. **One contract, three consumers.** Per §1.5 C1, no field MAY exist
   only for console's or portal's UI convenience. Any clause that
   carves a console-only or portal-only field/projection into a
   non-partner shape = CRITICAL. The partner-key projection is the
   single exception — and even that returns a strict superset of the
   public schema.

5. **No request-path queries against billing/session OLTP** (§1.5 C3).
   Any clause that allows a `/v1/stats/*` handler to issue ad-hoc
   aggregates against billing_ledger, sessions, or pool tables = CRITICAL.

6. **Earnings privacy default.** Per §2.3, the default for new and
   existing providers is `bucketed`. Any clause that ships exact `$`
   on the public surface without provider opt-in = CRITICAL. Note:
   the partner-key projection deliberately surfaces exact `$` for ALL
   providers (§5.2 partner-key projection, §6.6 legal posture); this
   is an intentional design and is NOT a CRITICAL finding — it MAY be
   surfaced as an operator-question if you think the legal posture is
   under-specified.

7. **Same-origin behavior is uniform.** Per §6.4, the endpoint MUST
   NOT special-case `Origin: portal.malibu.tech` to surface exact-$.
   The portal exposes own-provider exact earnings via its OWN
   surfaces (SPEC-014), not via this endpoint. Any clause that makes
   `/v1/stats/leaderboard` Origin-sensitive for `$` exposure = MAJOR
   ("contract drift; portal becomes a privileged consumer").

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-spec-017/specs/SPEC-017-network-stats-api.md`
   v0.1 — the spec under audit. Read fully, all 12 sections,
   16 acceptance criteria. Bias toward reading §5 (Endpoints), §6
   (Earnings visibility), §7 (Hosting & isolation), §9 (Rollup
   pipeline) carefully — these encode the most precise commitments
   and the most contestable design choices.

2. `/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_017_NETWORK_STATS_API_v0_1_PROMPT.md`
   — the BUILD prompt with the operator's spec-writing instructions.
   The spec MUST honor every item under "What v0.1 MUST normatively
   pin" and every item under "What v0.1 MUST explicitly defer". Diff
   it against SPEC-017 §1–§9 and §11; any deviation = MAJOR finding
   ("BUILD prompt directive drift").

3. `/Users/augstar/macprovider-spec-017/specs/SPEC-002-coordinator.md`
   line 3 (locked version), plus §4 (provider state), §7 (HTTP
   surfaces). SPEC-017 mounts `/v1/stats/*` on the same binary;
   verify the mount does not collide with the existing path tree
   (`/poolz`, `/admin/explorer/*`, `/healthz`, etc.) and that the
   §4 internal-bearer-audit logging convention is honored.

4. `/Users/augstar/macprovider-spec-017/specs/SPEC-005-billing.md`
   line 3 + §5.1 + §11.4. The `work` $ figure in SPEC-017's
   leaderboard derives from SPEC-005's settlement formula; verify
   SPEC-017 does not redefine token accounting, refund matrix, or
   null-usage treatment. Any divergence = CRITICAL.

5. `/Users/augstar/macprovider-spec-017/specs/SPEC-006-buyer-api.md`
   line 3 + §2.2 + §17 (header strip / X-MacProvider-* allowlist).
   SPEC-017 does not extend the buyer surface but reuses the public-
   surface conventions (error envelope, version path prefix, CORS
   posture). Verify SPEC-017's response headers (`X-Stats-Generated-At`)
   do not collide with the buyer-surface allowlist semantics.

6. `/Users/augstar/macprovider-spec-017/specs/SPEC-014-provider-portal.md`
   line 3. SPEC-017 §6.3 says the earnings-visibility toggle UI is a
   SPEC-014 v0.9 follow-up. Verify the SPEC-014 v0.8 surface has a
   plausible home for the toggle (authentication, settings page, etc.)
   and that SPEC-017's storage-column and audit-log specification
   does not REQUIRE SPEC-014 v0.9 to be merged before SPEC-017 v0.1
   can lock.

7. `/Users/augstar/macprovider-spec-017/specs/SPEC-016-payout-pipeline.md`
   line 3. The `rewards` $ figure in SPEC-017's leaderboard derives
   from SPEC-016. SPEC-016 is in active flux (v0.1.19+); SPEC-017 v0.1
   cites SPEC-016 v0.1.19. Verify the rewards semantic SPEC-017 names
   is consistent with the SPEC-016 v0.1.19 settlement model (if
   SPEC-016 has moved beyond v0.1.19 in the repo at audit time,
   surface that as an operator question — do NOT silently re-anchor).

8. `/Users/augstar/macprovider-spec-017/phase4-coordinator/internal/explorer/handlers.go`
   — the existing internal-ops explorer surface. SPEC-017 reuses the
   window-parsing, bearer-auth, and in-process rate-limiter patterns
   from here. Verify SPEC-017 does not accidentally extend the
   explorer's surface (operator-bearer auth, `/admin/explorer/*` path)
   instead of building the new public surface.

9. `/Users/augstar/macprovider-spec-017/frontdoor/console/index.html`
   — the existing console stats grid. Verify SPEC-017's `/v1/stats/overview`
   JSON covers every field the current console renders. Missing fields
   = MAJOR ("contract gap — console would need a private endpoint").

10. `/Users/augstar/macprovider-spec-017/beta/DECISION_CRITERIA.md`
    most recent 5–10 entries — operator context for the current
    moment. SPEC-017 v0.1 ships into the same operational posture as
    SPEC-016 (small-network beta, money-path-careful). Verify the
    SPEC's deferrals (read-replica, full backfill, hostname pattern,
    bucket boundary anchoring) match the operator's current bias
    toward operationally-thin shipping.

11. `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md`
    — the prior codex advisor round establishing the four locked
    decisions. The SPEC §2 names these as LOCKED with the artifact as
    citation; verify the SPEC does not silently re-litigate any of
    the four picks.

## Audit categories — work through each

### Category A: BUILD-prompt directive fidelity (HIGHEST PRIORITY)

A.1  Walk through every item under
     `BUILD_SPEC_017_NETWORK_STATS_API_v0_1_PROMPT.md` "What v0.1 MUST
     normatively pin" (the 8 sub-sections §3 through §8). For each,
     locate the corresponding normative clause in SPEC-017 v0.1.
     Findings:
       - MISSING (item in BUILD prompt but absent from spec) = CRITICAL
       - SEMANTICALLY DRIFTED (present but with different content) = CRITICAL
       - WEAKENED (MUST in prompt became SHOULD in spec) = MAJOR
       - SCOPE EXPANDED (spec added clauses the prompt did not authorize) = MAJOR

A.2  Walk through every item under "What v0.1 MUST explicitly defer"
     (the 8 deferral bullets). For each, confirm the spec EITHER (a)
     defers cleanly with a citation to the deferring section, or (b)
     names the item in §11 Open Questions. Any partially-resolved
     deferral (e.g. spec quietly decides something the prompt said
     to defer) = MAJOR or CRITICAL.

A.3  Verify the spec contains NO implementation prescriptions beyond
     what's needed to define the contract. The §7.2 SQL migrations
     and the §6.5 audit table CREATE TABLE statement are normative
     because they pin a contract a future SPEC-014 v0.9 PR must
     honor; that's fine. But any clause like "the rollup job MUST be
     implemented using package X" or "the handler MUST be 200 lines"
     = MAJOR ("scope creep into BUILD territory").

### Category B: Endpoint contract correctness

B.1  `GET /v1/stats/overview` shape (§5.1): exactly the 13
     `network.*` fields named in §5.1.1. If the spec implies extra
     fields anywhere (e.g. references a 14th field in the prose) or
     uses a field inconsistently between §5.1, §5.1.1, and the
     example JSON = MAJOR.

B.2  Field types (§5.1.1): each field has a well-defined JSON type
     (int64, int32, float64). Any field whose type is ambiguous
     ("integer or string", "either form acceptable") = CRITICAL.

B.3  Timeseries shape (§5.1): exactly 30 points, null vs zero
     semantics for missing minutes. Verify the spec is unambiguous
     that `null` means "no data" and zero means "zero traffic" — this
     is the kind of detail a partner client will burn time on.

B.4  Window/sort/limit query semantics (§5.2): default values and
     validation rules. Verify error envelope for `limit=0` and
     `limit=101` (boundary cases). Any silent clamp = MAJOR.

B.5  Public vs partner projection (§5.2): the partner-key projection
     is a strict superset of public. Verify the spec does not
     accidentally rename or restructure a public field in the
     partner projection — if so = CRITICAL.

B.6  `exact_earnings*` null-vs-missing (§5.2 + AC-4 + AC-5): JSON
     null when bucketed, USD float when exact. Verify the spec says
     ALWAYS PRESENT (key always emitted) — partner clients fail
     differently on missing keys than on null values.

B.7  Health endpoint (§5.3): 200 even when components are degraded.
     Verify the spec is unambiguous on this — partners will treat 200
     as "data is fresh" if the spec leaves ambiguity. If unclear =
     MAJOR.

B.8  Error envelope (§5.8): closed code vocabulary, every non-2xx
     uses the same shape. Verify the §5.7 503 case (`stats_stale`)
     conforms; verify the §5.5 429 case conforms; verify no other
     status code is mentioned anywhere with a different envelope.

B.9  CORS (§5.6): the `*` policy on overview/health and the
     allowlist-echo policy on leaderboard partner projection.
     Verify the spec is unambiguous on what happens when an allowed
     partner key is sent with an Origin NOT on its allowlist (§5.6
     says the public projection is served and the key is rejected
     with 401 — verify this is consistent, not contradictory).

B.10 HEAD/OPTIONS handling (§4.3): MUST be supported on every GET.
     Verify ACs cover at least one of these.

### Category C: Earnings visibility model

C.1  Default state (§6.1): bucketed for new and existing providers
     at cutover. Verify the migration clause is unambiguous and
     compatible with SPEC-014 v0.8's current provider schema.

C.2  Bucket thresholds (§6.2): absolute USD thresholds per window.
     Verify the thresholds are internally consistent (24h $0.01..$5
     does not overlap with 7d) and that work + rewards bucketing
     per-axis vs combined-bucket disclosure (§6.2 + Q9) is handled
     unambiguously.

C.3  Provider opt-in flow (§6.3): SPEC-014 v0.9 candidate dependency.
     Verify SPEC-017 v0.1 does NOT require SPEC-014 v0.9 to exist —
     the storage column, audit table, and API behavior are all
     specifiable independently. If SPEC-017 v0.1 silently assumes
     v0.9 = CRITICAL.

C.4  Same-origin uniformity (§6.4): no Origin-based $-exposure.
     Verify no other section of the spec accidentally creates a
     special path for portal Origin to see exact $. If anywhere the
     spec implies "portal can see exact $ for any provider" =
     CRITICAL.

C.5  Audit table (§6.5): every visibility-mode change inserts a row.
     Verify the table covers operator-driven changes (legal hold)
     AND provider-driven changes. Verify retention is not specified
     (deferred to operator policy is fine for v0.1).

C.6  Legal posture (§6.6): explicit consent screen, audit-row
     evidence. Verify the spec is honest about what consent means —
     "click here to make your $ public, this is visible to anyone
     including partners' websites" is the bar.

C.7  Operator override direction (§6.6 final paragraph): operator MAY
     flip exact→bucketed but MUST NOT flip bucketed→exact without
     provider consent. Verify this is unambiguous and consistent with
     the audit table actor_kind constraint.

### Category D: Hosting and isolation

D.1  Mount path collision (§7.1): `/v1/stats/*` does not collide with
     `/admin/explorer/*`, `/poolz`, `/healthz`, or any other SPEC-002
     v1.4 path. Verify by grepping the locked SPEC-002 file.

D.2  Hostname pattern (§7.1 + Q6): both `stats.malibu.tech` and
     `coordinator.malibu.tech/v1/stats/*` work. Verify the spec
     does not pin a CNAME that doesn't exist yet (operator action) —
     the SPEC may describe the future hostname; it MUST NOT condition
     LOCK on it.

D.3  DB role isolation (§7.2): `stats_reader` SELECT-only on `stats_*`.
     Verify the CREATE/REVOKE/GRANT sequence is syntactically valid
     PostgreSQL and that the listed tables match §9.1's table list
     exactly. Mismatch = MAJOR.

D.4  Connection-pool separation (§7.2): separate `*sql.DB` instance.
     Verify the spec says MUST not MAY; verify a test is implied
     (AC-9).

D.5  Process isolation (§7.3): recover middleware on the stats subtree.
     Verify the spec does not require the recover middleware to be
     specifically named or specifically scoped beyond the §7.3 boundary.
     AC-11 covers this.

D.6  nginx config (§7.4): the limit_req_zone, log strip, and cache
     pattern. Verify the spec does not pin a specific nginx version
     or syntax (deployment portability).

D.7  Import-graph isolation (§7.6 + AC-16): `internal/stats` MUST NOT
     import `internal/billing` / `internal/explorer` / `internal/ws`.
     Verify this is mechanically checkable. If the lint mechanism is
     under-specified ("a CI lint MUST reject") = MINOR; if the
     boundary set is wrong = MAJOR.

### Category E: Versioning and deprecation

E.1  URL versioning (§8.1): `/v1` in path is the only version
     surface. Verify the spec does not contradict this anywhere
     (e.g. a header-based version negotiation snuck in).

E.2  Additive change rule (§8.2): unbumped new fields, new buckets.
     Verify the spec is internally consistent — if §8.2 says
     additive without bump but §6.2 implies a bucket addition is
     a bump = MAJOR.

E.3  Breaking change rule (§8.3): `/v2/*` with 6-month overlap.
     Verify the spec is honest that this is the operator commitment,
     not a guarantee enforceable by the audit.

E.4  Sunset header (§8.4): RFC 8594 conformance. Verify the example
     timestamp format and the `Link` rel value are RFC 8594-correct.
     If wrong = MINOR (cosmetic) or MAJOR (mis-cite).

E.5  Changelog location (§8.5): `docs/network-stats-api/CHANGELOG.md`.
     Verify the spec does not require that file to exist at LOCK time
     — it can be created by the implementation PR.

### Category F: Rollup pipeline

F.1  Cadence table (§9.1): per-table refresh intervals. Verify the
     intervals are internally consistent with the §9.4 staleness SLA
     (e.g. `stats_overview_current` at 30s + 120s 503 budget = 4x
     buffer, which is reasonable; verify other rows similarly).

F.2  Late-event correction (§9.2): 24h/7d full recompute, 30d/all
     incremental + nightly rebuild. Verify the 48h look-back for
     30d/all is justified (or flag as unjustified-threshold MAJOR).

F.3  All-time accumulation (§9.3): incremental + nightly reconcile.
     The 0.5% drift threshold for alerting — verify this is
     justified or flag as MAJOR unjustified-threshold.

F.4  Freshness SLA (§9.4): each window has a target + 503 budget.
     Verify the ratios are consistent (typically 2x–4x).

F.5  Failure modes (§9.5): missed tick, SQL error, panic. Verify each
     case has a defined behavior (continue serving stale snapshot,
     log + metric + retry, recover + restart). If any case is
     hand-wavy = MAJOR.

F.6  Backfill on cutover (§9.6): `partial_history_since` field
     escape hatch. Verify this field is added to the §5.2
     leaderboard schema OR is documented as additive and not
     listed in the schema example. If missing from both = MAJOR
     (additive field with no home).

### Category G: Acceptance criteria quality

G.1  Each AC must have a deterministic verification step (curl
     command, SQL check, fixture-driven test). Any AC that is
     hand-wavy ("the system should work") = MAJOR.

G.2  ACs must cover the named surfaces: each of 3 endpoints
     (overview, leaderboard, health), partner-key flow, bucketed-
     vs-exact rendering, audit table, rate limit, CORS, role
     isolation, panic recover, ETag, stale-503, log-redaction,
     import-graph lint. Verify each is covered by at least one AC.
     If any uncovered = MAJOR.

G.3  AC numbering: AC-1 through AC-16 are contiguous. Verify no
     ACs are missing (gap in numbering) or duplicated.

### Category H: Cross-spec invariant preservation

H.1  SPEC-002 v1.4 mount: the new `/v1/stats/*` path is reachable
     under the existing coordinator HTTP server. Verify against
     SPEC-002 §7 path conventions. If SPEC-002 pins a URL prefix
     pattern that `/v1/stats/*` violates = CRITICAL.

H.2  SPEC-005 v0.3 settlement parity: SPEC-017 `work` $ derives from
     `effective_completion_tokens × rate` per SPEC-005 §5.1 / §11.4.
     Verify SPEC-017 does not redefine this. If SPEC-017's leaderboard
     row has any `$` math that disagrees with SPEC-005 = CRITICAL.

H.3  SPEC-006 v0.9 surface: SPEC-017 reuses the error-envelope shape.
     Verify SPEC-017's §5.8 envelope is structurally compatible with
     SPEC-006's. Trivial cosmetic differences are MINOR; semantic
     differences (e.g. SPEC-006 uses `errors` array vs SPEC-017's
     single `error` object) = MAJOR.

H.4  SPEC-014 v0.8 portal contract: SPEC-017 §6.3 hands off the
     toggle UI to SPEC-014 v0.9. Verify the handoff is clean (storage
     column, audit table, API behavior are all specified in
     SPEC-017; only the UI is in SPEC-014). If SPEC-017 puts UI
     details in §6.3 = MAJOR ("contract bleed").

H.5  SPEC-016 v0.1.19 settlement parity: SPEC-017 `rewards` $
     derives from SPEC-016 §5.1. Verify SPEC-017 does not redefine
     payout-pipeline semantics. SPEC-016 may have moved beyond v0.1.19
     in the repo; if so, flag in operator-questions.

### Category I: Honesty about deferrals

I.1  §11 Open Questions: each Q is genuine and not hiding a pinned
     decision. If §11 lists a Q that the body of the spec actually
     decides = MAJOR.

I.2  v0.2+ deferrals (embed badge, WS/SSE, GraphQL, per-provider
     drill-down, partner dashboards, cross-region, webhooks): each
     is named in §1.3 with a clear out-of-scope statement. If a
     deferral is open-ended ("eventually") = MINOR.

I.3  Console field coverage: the spec's §5.1 JSON MUST cover every
     field currently rendered in `frontdoor/console/index.html`. If
     a console-rendered field is missing from `/v1/stats/overview` =
     MAJOR ("contract gap — console would need a private endpoint").

### Category J: Spec hygiene

J.1  Line 3 version-of-record present and correct
     (`**Version:** 0.1 (YYYY-MM-DD, ...)`)

J.2  Change log section present at top; per [[feedback-spec-audit-file-convention]]
     audit narrative MUST NOT be inlined. Verify v0.1 entry is a
     one-liner pointing at the (future) audit file.

J.3  `Depends on:` line cites locked dependency versions from line
     3 of each dependency. Verify each cited version matches line 3
     of the cited SPEC TODAY (in the worktree at audit time).

J.4  House-style numbered sections, MUST/SHOULD/MAY usage consistent
     with RFC 2119. If RFC-2119 keywords are misused (e.g. SHOULD
     where the spec actually requires MUST) = MINOR or MAJOR
     depending on impact.

J.5  No "TBD". v0.1 deferrals MUST be cleanly stated as either §11
     Open Questions or out-of-scope citations. If "TBD" literal
     appears = MAJOR.

J.6  Locked-decision citation: §2 cites the codex advisor artifact
     at `.omc/artifacts/ask/...`. Verify the cited file exists in
     the worktree. If the citation is broken = MINOR.

## Output format

Produce `/Users/augstar/macprovider-spec-017/specs/SPEC-017-r1-audit.md`
(or `SPEC-017-rN-audit.md` for round N) with this structure:

```
# SPEC-017 v0.1 audit report — Round N (Codex, 2026-MM-DDTHH:MM:SSZ)

## Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- L QUESTIONS

## CRITICAL findings

C1. [Title]
    **Location:** § X.Y, line range
    **Finding:** [description]
    **Why it matters:** [impact]
    **Suggested fix:** [if obvious; "operator decision" if not]

(repeat for each critical finding)

## MAJOR findings
M1. ...

## MINOR findings
m1. ...

## Operator questions surfaced
q1. ...

## Verdict
- READY TO LOCK (zero CRITICAL, zero MAJOR-blocking)
- READY WITH FIX PASS (CRITICALs all closable in narrow fix pass)
- ANOTHER DESIGN ROUND NEEDED (architectural CRITICALs, fix won't suffice)
```

## Self-verification before declaring audit complete

- [ ] Read every section of SPEC-017 v0.1 (§§1–12, ACs 1–16).
- [ ] Compared SPEC-017 against the BUILD prompt's "MUST normatively
      pin" and "MUST explicitly defer" lists. Drift documented.
- [ ] Walked each Category A through J. Even if no findings, noted
      "no findings" explicitly.
- [ ] Severity for each finding chosen against the definitions
      above, not subjectively.
- [ ] Location (section number, line range when applicable) on every
      finding.
- [ ] Suggested fix for CRITICAL findings (operator may accept or
      reject; the suggestion is data, not prescription).
- [ ] Verdict (READY / READY+FIX / DESIGN ROUND NEEDED) at end.

When done, print a 200-word handback summary:
- finding count by severity
- top 3 most impactful findings
- the verdict + one-sentence rationale

Then stop. Do NOT begin drafting a fix prompt. The operator decides
whether to fix, retry the audit, or escalate to a design round.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~20 min per round):

1. Read the codex round findings start to finish.
2. For each CRITICAL: confirm whether it's real or a false alarm.
3. For each MAJOR: same triage.
4. Apply fixes to SPEC-017 in place, bump to v0.1.1 / v0.2 per scope.
5. Write per-round file `specs/SPEC-017-r2-audit.md` for the fix-pass
   re-audit (one file per round, NEW file each time).
6. Re-run this same prompt. Loop until **0 CRITICAL, 0 MAJOR**.

## How to use the audit output

- **READY TO LOCK verdict**: lock at v0.1.N. Append a DECISION_CRITERIA
  entry, push branch, open PR.
- **READY WITH FIX PASS**: apply CRITICAL fixes, bump version, re-run
  this prompt (round N+1). Lock at next clean round.
- **ANOTHER DESIGN ROUND NEEDED**: re-open the design question
  surfaced by the auditor (likely one of the §11 Open Questions). v0.1
  is provisional pending that resolution.

Historic pattern from SPEC-001/002/006/008/013/015/016: round 1
typically surfaces 1–3 CRITICAL + 6–12 MAJOR + 5–10 MINOR on a
first-draft v0.1 of a new contract. SPEC-016 ran 21 rounds; SPEC-015
ran ~4 rounds; SPEC-006 ran ~5 rounds. SPEC-017 v0.1 is simpler
contract surface (no crypto, no settlement math) but the
earnings-visibility model is novel — expect 3–5 rounds.
