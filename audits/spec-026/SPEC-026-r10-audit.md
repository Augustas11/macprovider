# SPEC-026 R10 — 3-lane codex audit results + Claude adversarial pass

Round 10 fired SEC + ARCH only against SPEC-026 v0.10 (CODE at
PASS since R8, skipped).

## R10 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | *skipped — R8 PASS* |
| SECURITY  | 0 | 0 | 0 | 0 | 0 |
| ARCHITECT | 0 | 0 | 0 | 3 | 0 |
| **Combined R10** | **0** | **0** | **0** | **3** | **0** |

**BOTH ACTIVE LANES CLEAN.** v0.10 landed 0/0/0 across all
three lanes for the first time.

## Claude adversarial + product-design pass (post-R10)

After R10 converged, two Claude subagents ran in parallel as
last-call adversarial verification:

- **`critic` agent** (adversarial verification): 0/0/2/3/2.
  Two MEDIUMs on Entry 102 bookkeeping drift that survived the
  R9/R10 cleanup rounds (Entry 102 body still had "v0.9"
  wording where it should say "v0.10"; the v0.10 change log's
  own audit-file inventory claim was off by one — said
  "eight … r1-r8" but `SPEC-026-r9-audit.md` already existed).
  Also flagged §4.1 step 7 omitting the `provider_name NOT
  NULL` column in the `provider_tokens` DDL enumeration (LOW
  promoted to fix), and the §6.1 step 7c "freshly-minted
  identity" ambiguity around SPEC-023's separate HMAC identity
  (LOW promoted to fix).
- **`designer` agent** (product-design critique): 0/0/3/5/3.
  Three MEDIUMs on real user-facing gaps: (1) landing page
  still sells the CLI flow (out of SPEC-026 normative scope
  but flagged as launch-readiness in Entry 102), (2) success
  card and steady state have no persistent way for a first-run
  user to notice their unbound-wallet earnings are unclaimed,
  (3) non-withdrawable MALIBU caveat is a one-time whisper on
  the success card and would surprise a day-7 user with a
  MALIBU balance they cannot withdraw.

## v0.11 dispositions

Combined 5 MEDIUM findings closed in v0.11:

- **critic-M1 (Entry 102 stale wording).** v0.10 body said
  "v0.9 explicitly does NOT cover," "three rounds of 3-lane
  codex audit," and enumerated only through R6 with no R7/R8/R9
  stanzas. v0.11 Entry 102 bumps every reference to v0.11,
  fixes round count to "nine rounds," adds R7/R8/R9 per-round
  stanzas, and updates the audit-file inventory to nine
  (r1..r9).
- **critic-M2 (v0.10 change-log inventory).** v0.10 said
  "bumped … to eight round audit files (r1-r8)" while
  r9-audit.md already existed. v0.11 change-log fixes to
  "nine round audit files (r1-r9)."
- **designer-M1 (landing-page CLI-flow copy).** Not
  SPEC-026's normative scope (SPEC-025 §10 owns landing-page
  copy), but v0.11 Entry 102 gains an explicit launch-readiness
  note: landing-page App-track copy MUST ship in lockstep with
  §10 step 9's Sparkle release, or AC-026-02 fails at the
  marketing surface.
- **designer-M2 (unbound-wallet backlog invisibility).**
  v0.11 §6.1 step 8 rewrites the success-card wallet row to
  give the "Add wallet" affordance visual weight equal to the
  counters. §6.2 adds an "unclaimed-earnings badge invariant":
  once backlog crosses $1 USDC-equivalent while unbound, the
  menu-bar icon MUST carry a badge; re-surfaces at $10 and
  $100 thresholds after dismissal.
- **designer-M3 (non-withdrawable MALIBU one-time whisper).**
  v0.11 §6.1 step 8 adds a lock icon + "unlocks at Trusted"
  microcopy to the MALIBU counter itself. §6.2 adds a
  "Persistent MALIBU-locked display invariant" requiring the
  lock icon anywhere a MALIBU balance is rendered in
  Provisional tier — success card, menu-bar tooltip,
  dashboard. The lock disappears at Trusted unlock in the same
  render pass.
- **critic-Minor-1 promoted (§4.1 provider_name column).**
  Real DDL detail; v0.11 §4.1 step 7 enumerates
  `provider_name TEXT NOT NULL` and pins the App-track literal
  `"malibu-app"`.
- **critic-Minor-3 (§6.1 step 7c ambiguity).** v0.11 step 7c
  clarifies that SPEC-023 uses its own HMAC-derived
  diversification identity, distinct from and unchanged by
  the SPEC-026 Ed25519 identity key. The Ed25519 key never
  leaves the Keychain per §3.1.

## Merge candidate

v0.11 is the merge candidate. All prior audit findings closed
across R1-R10 (nine codex rounds) plus the Claude critic +
designer pass. No CRITICAL / HIGH / MEDIUM outstanding. LOW
and INFO carry-forward is documented in the PR body.
