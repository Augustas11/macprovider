# Fix prompt — SPEC-002 v1.1.2 → v1.1.3

Operator-paste prompt for the **Go / coordinator-spec stream** of the
three-stream patch cycle queued after Decision log Entries 19 + 20. Two
other prompts cover the Swift (SPEC-001 v1.2.2) and Distribution
(SPEC-003 v0.5) streams in parallel.

## What this stream owns

| Layer | From | To |
|-------|------|----|
| Spec document | SPEC-002 v1.1.2 | SPEC-002 v1.1.3 |
| Go implementation | already at HEAD (no code changes needed in this stream) | (no change) |

This is a **spec-text-only patch.** The behavior changes already shipped
in commit 47d6433 as the Day-2 production hotfix. The job here is to
catch the spec up to the implementation and add the audit-category
anti-pattern entry so the bug class is named in future audit prompts.

Three additions:

  A. **§ 7.1 `auth.require_provider_tokens`** — normative paragraph
     covering the config flag added in commit 47d6433. Default `false`.
     When `true`, pinned providers MUST send a valid bearer; coordinator
     MUST reject with WS close 4005 (invalid_token) if absent/invalid.

  B. **§ 7.1 "log every WS close"** — MUST-level requirement: the
     coordinator MUST log every provider WebSocket close at WARN level
     including the close code and human-readable reason. (The original
     `s.close()` was silent and concealed the production rejection for
     ~15 minutes.)

  C. **§ 11 audit category I** — new anti-pattern entry: "code path
     gated by a non-nil pointer where the pointer is always non-nil in
     production config." (The `WithTokenValidator(tokenStore)` was
     called unconditionally in `cmd/coordinator/main.go`; the
     conditional check at server.go line 168 was always true; the
     test environment passed because tests didn't exercise the
     pointer-set-to-nil path. Same shape: "code path that depends on
     production config being a specific way, not exercised in any
     test, fails silently.")

Run in **Claude Code**. Expected duration: ~30-45 min (spec text only;
no code, no toolchain).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are landing three spec-text additions to SPEC-002 that document
behavior already shipped in the Go coordinator (commit 47d6433). No
code changes in this stream; this is catch-up + anti-pattern naming.

You will edit two files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
  /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html  (append "Resolved in v1.1.3" section)

Version bump:
  SPEC-002 v1.1.2 → v1.1.3

## Cross-spec context (shared verbatim across the three-stream patch cycle)

Today's Day-3 distribution work landed `curl-pipe-bash` for strangers.
The first stranger-shaped install surfaced **four install.sh bugs (A–D,
Entry 20)** and the preceding Day-2 production deploy surfaced **two
silent regressions (Entry 19)**: (1) Swift reconnect-task lifecycle
after CoordinatorDrainComplete didn't fire; (2) Go coordinator's
`WithTokenValidator` was wired unconditionally and `s.close()` did not
log, causing 15 min of silent production rejection.

The audit-pattern lesson from both Entries: **code paths that look
locally correct but fail under real-world resource interactions**. Each
line read fine in isolation; failure modes only emerged when shell
environment / Task lifecycle / config-flag-absent paths were actually
exercised. Per-stream audits caught the design issues; only the
stranger-shaped end-to-end test catches the surface issues.

Three patch streams run in parallel against this context:

  - **SPEC-001 v1.2.2 + phase3-binary v1.2.3** (sibling prompt
    FIX_SPEC_001_V1_2_2_PROMPT.md) — Swift behavior fix + spec text for
    reconnect lifecycle, model_id casing, JSON-escape tolerance.

  - **SPEC-002 v1.1.3** (THIS PROMPT) — Go spec-text-only:
    auth.require_provider_tokens normative, log-every-WS-close MUST,
    anti-pattern audit category entry. The Go behavior already shipped
    in commit 47d6433.

  - **SPEC-003 v0.5** (sibling prompt FIX_SPEC_003_V0_5_PROMPT.md) —
    distribution polish: install.sh prints wire bytes on self-test
    failure; § 5 normative requirement; new audit category for
    "shell-script paths touching real OS resources."

Each stream owns a disjoint codebase. Coordinate via commits to main;
no file-level conflicts expected.

## Critical constraints

**1. Backward-compat invariant.** SPEC-002 v1.1.2 normative behavior
must remain valid for v1.1.2 deployments (the live Pearl VPS is
v1.1.2). Your additions describe v1.1.3 behavior; do not retroactively
constrain v1.1.2.

**2. Buyer API stability.** Zero observable change to the
buyer-facing surface: `POST /v1/chat/completions`, `GET /v1/models`,
`GET /healthz`. The token-validator changes are provider-side only.

**3. Match the shipped Go code.** The behavior in
`phase4-coordinator/cmd/coordinator/main.go` and
`phase4-coordinator/internal/ws/server.go` is the ground truth.
Read both, then describe what's already there in spec terms. If the
spec text would contradict the shipped code, the shipped code wins
(file a follow-up rather than spec'ing the contradiction).

**4. d-inference clean-room.** Do not inspect d-inference source.

**5. Surgical scope.** Three additions (A, B, C below) + the version
bump + change log. Do NOT make other edits to SPEC-002.

## Required reading

1. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   — full document, especially:
     - § 7.1 (auth + hello validation — where the token validator
       semantics belong)
     - § 6 (WS close codes — where 4005 invalid_token is defined; the
       close-logging requirement applies here too)
     - § 11 (audit categories I-N — where the anti-pattern entry
       belongs; identify the I category and read what's already there)

2. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — Entry 19, specifically the hotfix paragraph describing the
   `auth.require_provider_tokens` config flag and the `s.close`
   logging addition. This is the production evidence.

3. `/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go`
   — the actual switch on `cfg.Auth.RequireProviderTokens`. Read the
   exact behavior the spec must describe.

4. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/server.go`
   — the `s.close()` function and where it's called. Confirm the
   WARN-level log line and what fields it includes.

5. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go`
   — the `AuthConfig.RequireProviderTokens` field. Confirm YAML tag
   and default behavior.

6. `git log --oneline | head -20` — verify commit 47d6433 is in the
   history; this is the commit your spec text catches up to.

## Findings to fix

### A. § 7.1 — `auth.require_provider_tokens` normative paragraph

**Location:** `specs/SPEC-002-coordinator.md` § 7.1

**Problem (Entry 19 production bug):** SPEC-002 v1.1.2 § 7.1 implies
that the coordinator always validates a provider bearer token on the
WS handshake. The Go implementation initially honored this by calling
`WithTokenValidator(tokenStore)` unconditionally in
`cmd/coordinator/main.go`, which caused `server.go` line 168 to
reject ANY pinned provider (M4 + M1 don't predate the token system;
they connect with provider_id only) with WS close 4005 invalid_token.
The fix (commit 47d6433) added the `auth.require_provider_tokens`
config flag (default false) so the live deployment with pinned
providers works without a token system; opt-in to strict token
validation when the operator is ready.

**Fix (spec text):** Add a new subsection in § 7.1 after the existing
auth description:

> **§ 7.1.X Provider authentication mode**
>
> The coordinator supports two provider authentication modes,
> selected by the config field `auth.require_provider_tokens`
> (default: `false`).
>
> When `auth.require_provider_tokens` is `false`:
>
> - Pinned providers (those whose `provider_id` matches an entry in
>   `config.providers[]`, see § 7.1 F-2) are admitted on
>   `provider_id` match alone. The bearer token field in the WS
>   handshake is ignored.
> - Provisional providers (per § 7.1 F-2.b) follow the provisional
>   admission rate as normal.
>
> When `auth.require_provider_tokens` is `true`:
>
> - Pinned providers MUST present a bearer token in the WS
>   handshake matching the operator-issued token registered for
>   that `provider_id` in the coordinator's token store. Mismatch
>   or absence MUST result in WS close 4005 (invalid_token).
> - Provisional providers continue to be admitted without a token;
>   the token requirement applies only to the pinned tier.
>
> The default `false` reflects v1.1.2's tier-1 cooperative trust
> pool (per § 2): pinned providers are trusted by `provider_id`
> alone, and the token store exists for future expansion. Operators
> who add a token store SHOULD flip `require_provider_tokens` to
> `true` and re-issue tokens to all pinned providers as a single
> deployment step.
>
> **Implementation invariant:** every code path that depends on
> the token validator being configured MUST also handle the case
> where it is not. Failure to do so caused the Day-2 production
> outage cited in audit category I.X (see § 11).

### B. § 7.1 (or § 6) — "log every WS close" MUST

**Location:** wherever WS close codes are normatively defined in
SPEC-002 (likely § 6 or § 7.1; pick the location that already lists
the 40xx close codes)

**Problem (Entry 19 production bug):** The original `s.close()` in
`internal/ws/server.go` sent the close frame and returned without
emitting any log entry. When pinned providers were rejected with
close 4005 (Finding A's bug), the coordinator's only externally
visible record was nginx access logs showing "101 Switching
Protocols" — no rejection trace anywhere. ~15 minutes of production
silent-fail before the bug was diagnosed.

The fix (commit 47d6433) added a WARN-level log in `s.close()` that
emits `close_code` (int) and `reason` (string). This is now
universal across every close path in the file.

**Fix (spec text):** Add a normative paragraph in the WS-close
section:

> **WS-close logging requirement.** The coordinator MUST emit a
> log entry at WARN level for every provider WebSocket close it
> initiates, including:
>
> - The provider's `provider_id` (if known at close time)
> - The numeric close code (e.g., 4005)
> - A short human-readable `reason` string (e.g., "invalid_token",
>   "drain_complete", "heartbeat_timeout")
> - The remote address
>
> This requirement exists because silent close paths conceal
> production-breaking misconfigurations. A coordinator-initiated
> close is, by definition, a decision the coordinator made; it MUST
> be observable in the coordinator's own logs without correlating
> against external proxy logs.
>
> This requirement applies to coordinator-initiated closes only.
> Client-initiated closes MAY be logged at INFO or DEBUG at the
> operator's discretion.

### C. § 11 — audit category I anti-pattern entry

**Location:** `specs/SPEC-002-coordinator.md` § 11 (audit categories)

**Problem (Entry 19 root cause):** The Go integration audit didn't
catch the `WithTokenValidator(tokenStore)`-always-on bug because:

  - The `cfg.Auth.RequireProviderTokens` flag had `default: false`
  - But `cmd/coordinator/main.go` called `WithTokenValidator(tokenStore)`
    unconditionally
  - And `server.go` line 168's check `if s.tokenValidator != nil`
    was structurally correct but never false in any test environment

The bug class: **a code path is gated by a check (non-nil pointer,
boolean flag, env var) that is ALWAYS the gate-open value in any
test environment because the test setup unconditionally sets it.**
The gate exists in code but doesn't exist in practice.

**Fix (spec text):** Add a new bullet under audit category I (or
create a sub-category if I is already crowded):

> **I.X "Always-non-nil gate" anti-pattern.** Check for code paths
> gated by a non-nil pointer or a boolean that is set to the
> gate-open value unconditionally in every test setup. A test where
> the gate is in its closed state must exist; if the closed-state
> behavior cannot be exercised in unit tests, an integration test
> with the gate configured closed MUST exist. The 2026-05-28
> coordinator hotfix (Entry 19) is the reference example:
> `WithTokenValidator(tokenStore)` was called unconditionally,
> `s.tokenValidator != nil` was therefore always true, and no test
> exercised the "no token validator configured" path — so the
> production deployment with `auth.require_provider_tokens=false`
> caused unconditional pinned-provider rejection that no audit had
> caught. Generalize: every conditional in production code needs at
> least one test case for each branch, including the "this branch
> only fires when the operator chooses the rare config" branch.

## Output requirements

1. SPEC-002 updated in place. Version bumped to v1.1.3. Change log
   entry added at the top covering Findings A, B, C.

2. `phase4-coordinator/implementation-notes.html` gains a "Resolved
   in v1.1.3 (spec catch-up)" section noting that the behavior shipped
   in commit 47d6433 is now documented normatively.

3. No code changes in `phase4-coordinator/`. Verify with
   `git diff phase4-coordinator/ --stat` — should be empty for this
   stream (the implementation-notes.html change is in
   `phase4-coordinator/` but that's documentation, not code).

4. Handback summary at the end: 100-150 words covering what changed,
   what the spec now matches in code, and what audit category I now
   names that it didn't before.

## Self-verification checklist

- [ ] SPEC-002 version bumped 1.1.2 → 1.1.3 at the top.
- [ ] Change log entry covers Findings A, B, C in that order.
- [ ] § 7.1 has the `auth.require_provider_tokens` two-mode normative
      paragraph; default `false` is called out explicitly.
- [ ] WS-close section has the "MUST log at WARN" paragraph with the
      four required fields (provider_id, close_code, reason, remote).
- [ ] § 11 audit category I gains the "always-non-nil gate" entry
      with the Entry 19 reference example.
- [ ] No code changes in `phase4-coordinator/cmd/` or
      `phase4-coordinator/internal/`. Implementation matches spec by
      reading commit 47d6433.
- [ ] Backward-compat: a v1.1.2 deployment is still spec-conformant.

If your edits exceed ~150 lines of SPEC-002 changes, stop and re-check
scope — three surgical additions only.

When done, print the handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~5 min):

1. `git diff specs/SPEC-002-coordinator.md` — three additions + version bump + change log only.
2. `git diff phase4-coordinator/` — empty except for the implementation-notes.html append.
3. Sanity check: the `auth.require_provider_tokens` description in the spec matches the actual code in `cfg.Auth.RequireProviderTokens` (no contradictions).
4. § 11 audit category I now name-checks the "always-non-nil gate" anti-pattern with a citable reference.

Then commit. Suggested message:

```
SPEC-002 v1.1.3: catch spec up to coordinator hotfix + name anti-pattern

Three spec-text additions documenting behavior already shipped in
commit 47d6433 (Entry 19 production hotfix).

A. § 7.1   auth.require_provider_tokens normative paragraph: two
           modes (default false for tier-1 cooperative trust pool;
           opt-in true for token-enforced pinned providers).

B. § 6     WS-close logging MUST: every coordinator-initiated close
           emits WARN with provider_id + close_code + reason + remote.
           Prevents silent production rejection (Entry 19 concealment
           layer).

C. § 11    Audit category I gains the "always-non-nil gate"
           anti-pattern entry. Names the bug class for future audits.

No code changes — implementation is already at HEAD. Backward-compat
preserved: v1.1.2 deployments remain spec-conformant.
```

After commit, the spec corpus and Go implementation are aligned. No
further action on this stream until SPEC-004 (smart router) work
begins, at which point audit category I.X applies prophylactically.
