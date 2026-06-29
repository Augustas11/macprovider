# SPEC-020 v0.1.0 — Round 1 audit prompt (per-lane)

You are auditing **SPEC-020 v0.1.0 (2026-06-29, DRAFT)** — provider
autoupdate. This is the first audit round of a freshly-drafted SPEC.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM before the SPEC PR opens.**
Findings get absorbed and another round fires.

## What you are auditing

SPEC-020 v0.1.0 wires the existing manual self-update flow at
`phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` into automatic
invocation when the coordinator advertises a newer
`recommended_binary_version`. The SPEC does NOT replace the existing
cryptographic update mechanism (signed checksums, GitHub-host
validation, tarball safety, `self-test` gating, atomic rename) — those
are already implemented and the SPEC normatively wraps them as
invariants. The SPEC adds: trigger semantics, drain before swap,
backoff after failure, rollback after crash, opt-out, and observability.

The constraint from the operator that shaped this scope:

> "First of all we need autoupdate feature that providers would be
> updated to latest binary version. ... All new providers will run
> latest version anyways."

Translation: **autoupdate is the version-skew fix; provider capability
advertising is explicitly out of scope.** Future SPECs ship features
that assume all providers run the latest binary.

## Authoritative inputs (read these first)

1. **SPEC under audit**: `specs/SPEC-020-provider-autoupdate.md` at
   HEAD of `spec/020-provider-autoupdate` (worktree
   `/Users/augstar/macprovider-spec-020`). Read all sections + change log.
2. **BUILD prompt that produced it**:
   `specs/BUILD_SPEC_020_PROMPT.md`. Verify the SPEC honors every named
   constraint and flags every open question rather than silently picking.
3. **Existing IMPL (the SPEC's foundation)**:
   - `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` — full
     existing manual update flow. The SPEC wraps this.
   - `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
     — `recommended_binary_version` notify-only branch at line ~1232;
     `binaryVersion` constant at line 168; auth-request handshake at
     line ~1640 (no SO capability field — confirms out-of-scope).
   - `ops/macprovider-watchdog/watchdog.sh` — the rollback observer
     candidate the SPEC names.
   - `phase3-binary/dist/install.sh` — operator-facing installer.
4. **Cross-spec references** (the SPEC must not contradict these):
   - `specs/SPEC-001-provider-discovery.md` — coordinator-side handshake.
   - `OPS.md` — operational context for fleet upgrades, watchdog,
     launchd plist layout.
5. **House style for SPEC structure** (header + sections + change log):
   recent locked specs `specs/SPEC-018-agentic-tool-calling.md`,
   `specs/SPEC-019-structured-output.md`.

## How to return your verdict

Return ONE of:
- `READY TO LOCK` — 0 CRITICAL + 0 HIGH + 0 MEDIUM. Minor / Note
  observations OK; list them under "Notes" but they do not block.
- `NEEDS REVISION` — at least one of CRITICAL / HIGH / MEDIUM. List
  each finding with:
    - ID (use your lane prefix: A-rN-C-K, B-rN-H-K, etc., where K is a
      monotonic counter scoped to your lane / round / severity)
    - Severity (CRITICAL / HIGH / MEDIUM / minor / Note)
    - File:section reference in the SPEC body
    - The bug or gap
    - The proposed fix (concrete text edits the SPEC author can absorb)

**Convergent findings across lanes are the strongest signal.** Phrase
your findings so they can be matched against other lanes' findings on
the same root cause.

---

## Lane-specific focus

You are ONE of the three lanes below. Stay in your lens. Do NOT
audit the other lanes' concerns.

### Lane A — Codex architect

- **Cross-spec consistency**: does SPEC-020 contradict SPEC-001
  (provider discovery) or SPEC-018 / SPEC-019 (active product surfaces)?
  Does any R-N.M imply changes to the coordinator-side payload schema
  that aren't called out?
- **Scope boundary**: the SPEC explicitly defers capability advertising,
  staging cohorts, prerelease channels. Did anything from those slip
  in implicitly through an R-N.M or AC?
- **Forward-compatibility**: future SPECs will assume "all providers
  run latest". Does v0.1.0 actually deliver that guarantee, or is there
  a population the spec doesn't cover (e.g., manually-installed
  provider with autoupdate opted out, watchdog-disabled rigs)?
- **Coordinator contract**: who is normatively responsible for setting
  `recommended_binary_version` on the coord? If the SPEC defines
  behavior triggered by this field but doesn't pin the field's
  authoritative source, that's a contract gap.
- **Drain protocol**: the SPEC defines drain semantics. Does it
  contradict or duplicate SPEC-001's `state_update`/`draining` model?
  Is "draining" already a defined provider state, or does this SPEC
  introduce a new one?
- **Watchdog responsibility**: the SPEC delegates rollback observation
  to the existing watchdog. Is that delegation crisp enough for the
  IMPL phase to know what watchdog code paths must change?
- **Version comparator**: SelfUpdate already has `compareSemver`.
  Does the SPEC normatively bind autoupdate decisions to that same
  comparator, or could a subtle drift create equality-vs-greater bugs?

### Lane B — Codex code

- **Citations**: every `file:line` or `file:line-line` citation in
  SPEC-020 body must resolve to real lines that match the SPEC's
  description. Grep each citation in `/Users/augstar/macprovider-spec-020`
  worktree and confirm. Flag drift as a finding.
- **R-N.M implementability**: pick the 5 most ambiguous R-N.Ms and
  trace whether an implementer could write the IMPL with the SPEC
  alone. Edge cases: what happens when coord sends
  `recommended_binary_version` that's equal to current? Less than
  current? Malformed (non-semver string)? Empty string? Missing field?
- **Drain timeout**: the SPEC proposes a soft + hard timeout. Are the
  values concrete? Are the units clear (seconds vs ms)? What's the
  expected behavior of an in-flight request when the hard timeout fires
  — clean abort, force-kill, or wait-forever?
- **Backoff math**: if exponential backoff is specified, is the
  formula concrete (base, multiplier, cap)? Is "cap at 1 hour" hard-coded
  or operator-tunable?
- **Rollback marker file path / format**: does the SPEC specify where
  the prior-binary backup lives and how rollback discovers it? Is
  there a race between two concurrent autoupdate attempts (e.g., coord
  reconnects mid-update)?
- **Observability format**: structured events — does the SPEC specify
  the schema (JSON keys, value enums) or leave it to IMPL? Past SPECs
  pinned envelope discipline; check parity.
- **Existing SelfUpdate.swift gaps**: scan the existing IMPL for
  behaviors the SPEC normatively requires but the IMPL doesn't yet do.
  Examples to look for: opt-out env var enforcement, structured event
  emission, drain-before-replace honoring a soft+hard timeout, backoff
  state persistence.

### Lane C — Codex security

- **Threat model rigor**: the SPEC has T-1 through T-7. Are any
  significant threats missing? Specifically consider:
    - T-X: replay of a previously-valid release tarball years later
      (if attacker can rewind operator's clock or expire signature
      grace period).
    - T-X: the `recommended_binary_version` value is supplied via
      coordinator session — is the SPEC clear about which trust state
      (provisional / pinned / Tier2-attested) the provider must be in
      before honoring it?
    - T-X: drain-before-swap creates an observability gap — during
      drain, can the provider be tricked into accepting an attestation
      request for a state that's about to change?
    - T-X: watchdog rollback path itself can be an attack surface
      (lazy delegation to launchctl from a privileged context).
- **Crypto invariants**: ECDSA P-256 pinned pubkey baked at compile
  time. Is the SPEC explicit that key rotation requires a new release
  built with the new key (and what happens to providers running with
  the old key when the new one is needed)?
- **Downgrade defense**: R-N.M states "refuse downgrades". Does this
  cover the historical-release-with-known-vuln case (release
  legitimately existed but is now considered dangerous)? Is there an
  allow-list / denylist surface?
- **Disk-space DoS**: if attacker can fill operator's disk to
  precisely the threshold the SPEC names, autoupdate fails. Is the
  failure mode safe (no half-applied update)?
- **Self-test bypass**: existing IMPL runs `self-test` on the new
  binary before swap. If the new binary's `self-test` is a no-op (e.g.,
  attacker shipped a stub self-test), does anything in SPEC-020 detect
  this?
- **Opt-out tamper**: an operator-set opt-out via config file or env
  var lives on the same machine. Threat model for "attacker with local
  write access" — is it complete and consistent with T-6?
- **Observability leakage**: the structured events the SPEC requires —
  do any of them log secret material (tokens, signing keys, etc.) by
  design?

---

## Output format

Begin your response with one of:

```
VERDICT: READY TO LOCK
```

or

```
VERDICT: NEEDS REVISION
CRITICAL: <count>
HIGH: <count>
MEDIUM: <count>
```

Then list findings (skip if 0/0/0). Each finding:

```
[ID] [SEVERITY] [SPEC section]
Bug: <one-paragraph statement of what's broken>
Fix: <concrete edit the SPEC author absorbs verbatim or near-verbatim>
```

End with "Notes:" listing minor / Note observations that do NOT block
the lock bar but are worth recording.

**Stay in your lane.** Do NOT raise architect concerns from the code
lane, etc. If you notice a finding that belongs to another lane, list
it under "Notes" with the lane prefix and a one-sentence summary.
