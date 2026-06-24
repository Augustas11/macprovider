# Audit prompt — SPEC-015 v0.2 buyer-side verification

Operator-paste prompt to audit SPEC-015 v0.2 deltas in
`specs/SPEC-015-receipts.md`, MacProvider's buyer-side receipt
verification contract.

**Cross-model pattern:** the v0.2 deltas were drafted by Claude
(executing `specs/BUILD_SPEC_015_RECEIPTS_v0_2_VERIFY_PROMPT.md`).
For independence, the audit runs in **Codex CLI first** (via
`omc ask codex` or the ambient `ask` skill), three sequential
lenses: `code`, `security`, `architect`. After Codex round 1 (all
three lenses) lands, Claude does a round-2 pass for any lens that
Codex flagged with mixed verdicts. All audit reports go into
`specs/SPEC-015-v0-2-audit.md` as separate sections, matching
the v0.1 audit history in `specs/SPEC-015-audit.md`.

Expected duration: ~30–45 min per lens. v0.2 deltas are scoped:
§10 promotion (§§10.0-10.6), AC-18..AC-27 in §14, §15 Q2/Q4
updates, and the change log v0.2.0 block at the top. v0.1.x §§1-9,
§11-13, §14 AC-1..AC-17, §16 are LOCKED and **out of scope** for
this audit — surface any concern about them as a v0.3+ open
question, not a v0.2 finding.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session (round 1) or
Claude Code session (round 2) rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-015 v0.2 deltas, MacProvider's buyer-side
receipt verification contract at
/Users/augstar/macprovider-poc/specs/SPEC-015-receipts.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, let the
operator decide fixes. The operator has read the spec; they need an
independent second (or third) opinion on what is missing, wrong, or
under-specified in the v0.2 deltas.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-015-v0-2-audit.md

Format: structured audit report. Findings grouped by lens
(code / security / architect) and within each lens by category, each
finding tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION)
and location (section number + line range if possible). Match the
rigor of `specs/SPEC-015-audit.md` (the v0.1 audit) and the prior
audit reports in this repo (specs/SPEC-006-audit.md,
specs/SPEC-008-audit.md, specs/SPEC-013-audit.md). If you are
running as round 2 (Claude after Codex), APPEND your section to the
existing file, do not overwrite Codex's round 1.

## Scope — v0.2 deltas ONLY

The v0.2 changes are bounded:

1. **Change log v0.2.0** block at top of `SPEC-015-receipts.md`
   (above the v0.1.3 entry).
2. **§10 promotion from informative to NORMATIVE**, with new
   subsections:
   - §10.0 Core algorithm (preserved from v0.1)
   - §10.1 Result semantics (tri-state: valid / invalid / inconclusive)
   - §10.2 Pubkey resolution (3-source priority, 7-day cache TTL)
   - §10.2.1 Rotation-grace behavior (receipt_pubkey_prev)
   - §10.3 Canonicalization parity (bit-identical to §3.2/§4/§5;
     forbids "lenient" mode; mandates Swift↔Go JCS parity test)
   - §10.4 Inputs, outputs, exit codes
     - §10.4.1 Bundle JSON shape (strict mode, bundle_version pin)
     - §10.4.2 Output modes (human + JSON)
     - §10.4.3 Exit codes (0/1/2/64/65 per sysexits.h)
   - §10.5 Network behavior (no telemetry; /poolz only; 5s/no-retry)
   - §10.6 Trust boundary statement
3. **§14 AC-18 through AC-27** appended after AC-17.
4. **§15 Q2 and Q4** updated (replay-binding and timestamp
   honesty deferrals).
5. **Line 3** version bump from `0.1.3` to `0.2.0`.
6. **Line 4** Depends-on update (SPEC-001 v1.5 → v1.6; SPEC-002
   v1.4 candidate naming; SPEC-006 v0.9 candidate naming).

Any concern about v0.1.x clauses (§§1-9, §11-13, §14 AC-1..AC-17,
§15 Q1/Q3/Q5/Q6, §16) is **OUT OF SCOPE** for this audit. If you
believe a v0.1 clause is broken, file it as a v0.3+ open question,
NOT a v0.2 finding. v0.1.3 went through a 3-round audit loop
(see `specs/SPEC-015-audit.md`) and is LOCKED.

## Severity definitions

- **CRITICAL** — would cause verifier-side rejection of valid
  receipts, signature-verification bypass, false `valid` reports on
  unrooted pubkeys, OpenAI SDK incompatibility (against the v0.1
  wire contract — verifier MUST NOT modify it), irrecoverable
  canonicalization ambiguity between Swift signer and Go verifier,
  network leakage against the §10.5 "no telemetry" promise, or a
  misrepresentation of the v0.2 trust boundary that lets a buyer
  think a `valid` result proves more than §10.6 commits to.
- **MAJOR** — would cause significant buyer confusion, predictable
  v0.2.x patch within first month of deployment, ambiguity that
  two conforming verifier implementations could resolve differently
  and produce different results on the same bundle, unjustified
  numeric thresholds (cache TTL, timeout, redirect policy),
  hand-wavy MUST/SHOULD splits, exit-code semantics that scripts
  cannot rely on, or scope creep (v0.2 silently deciding something
  the BUILD prompt said to defer).
- **MINOR** — quality issues that don't block v0.2 but should be
  cleaned in v0.2.1 / v0.3. Naming inconsistencies, missing
  cross-references, prose clarity, underspecified edge cases that
  won't fire frequently.
- **QUESTION** — genuinely unresolved design choices the spec
  couldn't decide alone. Operator input required. Distinguish from
  the §15 Open Questions the spec already names — those are not
  findings unless they hide a CRITICAL/MAJOR underneath.

## Critical constraints to honor while auditing

**1. v0.1.x normative content is LOCKED.** Any v0.2 clause that
would require changes to v0.1.x §§1-9, §11-13, §14 AC-1..AC-17, or
§16 (other than the §15 Q2/Q4 reference updates) is a CRITICAL
finding ("v0.2 deltas reach back into locked v0.1 content").

**2. The v0.1 wire contract is BIT-IDENTICAL.** v0.2 is a verifier
contract; it MUST NOT change `X-MacProvider-Receipt` header bytes,
the seven-field tuple, the JCS canonicalization rules in §3.2, or
the prompt/output canonical shapes in §§4-5. Any clause that
implies the wire contract changed = CRITICAL.

**3. The §10.6 trust boundary statement is the surface a security
auditor will hit hardest.** Any clause anywhere in v0.2 that
contradicts §10.6 (e.g. an AC implying timestamp attestation, a
flag implying model attestation, a default that silently accepts
an unrooted pubkey) = CRITICAL.

**4. `inconclusive` is a first-class result.** Any clause that
implies `inconclusive` collapses into `valid` or `invalid`, or any
default behavior that downgrades `inconclusive` silently, =
CRITICAL.

**5. The v0.2 verifier has no implementation yet.** This audit is
on the spec, not on code. Any finding that depends on "the code
will / won't do X" is out of scope; surface it as guidance for the
forthcoming `BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` instead.

**6. SPEC-001 v1.6, SPEC-002 v1.4 candidate, SPEC-006 v0.9
candidate** absorbed via PR #123 in v0.1.3 LOCK — the new line 4
references match those candidates. Any clause that conflicts with
the absorbed locked-spec authority = CRITICAL.

**7. d-inference clean-room.** Do NOT inspect d-inference source.

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-015-receipts.md`
   v0.2.0 — the spec under audit. Read fully. Bias toward reading
   §10 (Verification) carefully — this is the entire v0.2 contract.

2. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_015_RECEIPTS_v0_2_VERIFY_PROMPT.md`
   — the BUILD prompt with the operator's v0.2 spec-writing
   instructions. The spec MUST honor every item under "What v0.2
   MUST normatively add" and every item under "What v0.2 MUST
   explicitly defer". Diff it against SPEC-015 §10 and §14
   AC-18..AC-27; any deviation = MAJOR finding ("BUILD prompt
   directive drift") or CRITICAL ("BUILD prompt MUST became SPEC
   SHOULD").

3. `/Users/augstar/macprovider-poc/specs/SPEC-015-audit.md` — the
   v0.1 audit history (3 rounds). v0.2 MUST NOT regress anything
   the v0.1 audit closed. Specifically check that v0.2 §10 does
   not re-introduce concerns the v0.1 audit cleared.

4. `/Users/augstar/macprovider-poc/README.md` lines 1–137 — the
   thesis. v0.2 is what makes the README's "verifiable inference"
   promise actionable for a buyer. The trust boundary §10.6 MUST
   match what the README does (and does not) promise.

5. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.8.3 — house style for a buyer-facing surface, and the §17
   header allowlist that v0.1's `X-MacProvider-Receipt` extends.
   Verify v0.2 §10.4.1 bundle shape is consistent with what
   SPEC-006 says a buyer can capture from the response.

6. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.5 — the coordinator spec. Focus on §7 (`/poolz`). v0.2 §10.2
   pubkey resolution depends on `/poolz` shape; verify the resolver
   only reads fields the SPEC-002 v1.4 candidate exposes
   (`receipt_pubkey`, `receipt_pubkey_prev`) and does NOT read fields
   v0.1.3 did not annotate.

7. `/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md`
   v0.3 — for CLI house style. The `macprovider verify` subcommand
   in v0.2 §10.4 MUST follow the same flag conventions
   (`--bundle`, `--json`, `--offline`, `--quiet`, etc.) without
   inventing new patterns.

8. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`
   — the in-house Swift JCS implementation. v0.2 §10.3 mandates a
   bit-identical Go port. Verify §10.3's parity-test requirement
   names this file as the source of truth.

9. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   Entries 79–82 — operator context (Entry 82 is the v0.1.3 LOCK
   entry). v0.2 deferrals (model-hash, timestamp skew, stronger
   trust root, replay-binding) MUST match the operator's posture
   in these entries.

## Audit categories — work through each lens, then each category

### Lens 1 — CODE (impl-feasibility / API design)

C.1  **Bundle JSON shape (§10.4.1).** Verify every field has a
     stated type and stated required/optional disposition. Check
     `bundle_version: 1` strict-mode rejection of unknown keys is
     unambiguous. Check that the suggested OpenAI request/response
     shapes match what a buyer would actually capture from
     `chat.completions.create()`.

C.2  **Output schema (§10.4.2).** Verify the JSON schema fields
     are completely specified: `result` enum, `reason` string
     freedom, `trust_source` enum exhaustive, `details` block
     shape for `invalid`. Check the human-mode output lines are
     consistent with the JSON-mode payload.

C.3  **Exit codes (§10.4.3).** Verify 0/1/2/64/65 are unambiguous
     and each maps to exactly one verifier state. Check the
     ">65 reserved for v0.3+" rule is normative enough that a
     v0.3+ spec author can rely on it.

C.4  **CLI flags surface (§10.4).** Verify `--receipt`,
     `--prompt-hash`, `--output-hash`, `--bundle`, `--pubkey`,
     `--json`, `--offline`, `--quiet`, `--explain`,
     `--coordinator`, `MACPROVIDER_COORDINATOR` env var are
     mutually consistent. Check no flag combination produces
     undefined behavior.

C.5  **Header+hashes mode (§10.4 mode 1).** Verify the buyer can
     actually use this mode — i.e. the spec says where the
     pre-canonicalization happens (in another tool? in
     macprovider-verify itself? if elsewhere, where is the
     canonicalization tool spec'd?). This is a likely MINOR or
     MAJOR depending on how unambiguous the answer is.

C.6  **Algorithm (§10.0).** Verify the 9-step algorithm matches
     v0.1's §10 sketch except where v0.2 explicitly diverges
     (step 5 → §10.2 resolution; step 9 timestamp check removed).
     Check the divergences are tagged in the change log.

### Lens 2 — SECURITY (cryptographic claims, threat model, trust boundary)

S.1  **Trust boundary statement (§10.6).** This is the highest-
     scrutiny clause in v0.2. Walk through every "DOES NOT prove"
     line. Verify each negative claim is precise, not hand-wavy.
     Specifically:
     - "model attestation" — is the SPEC-011 v0.5 §3.3.1
       `model_hash` reference correct?
     - "timestamp honesty" — is the §15 Q4 reference forward-
       compatible (i.e. v0.3+ can add skew-check without breaking
       v0.2 verifiers)?
     - "privacy" — is SPEC-008 / Cluster E the right citation?
     - "pubkey trustworthiness" — does §15 Q1 (TUF / on-chain) cover
       the right v0.3+ work?
     - "replay" — does §10.6 "delivered to the buyer who is now
       verifying it" line match §15 Q2's update?

S.2  **`inconclusive` distinctness (§10.1).** Verify the spec
     forbids collapsing `inconclusive` into `valid` (CRITICAL if
     there's any wiggle room). Verify the `inconclusive` →
     `invalid` boundary in §10.1 is sharp: if `/poolz` returns a
     `receipt_pubkey` that DIFFERS from the receipt's
     `provider_pubkey`, is that `invalid` (coordinator-rejected) or
     `inconclusive` (no match)? §10.1's "invalid (not inconclusive)
     is correct when…" list MUST cover this exactly.

S.3  **Pubkey resolution priority (§10.2).** Verify the explicit
     `--pubkey` source always wins (offline-first). Verify the
     divergence-warning behavior between explicit and live is
     specified for every output mode (`--json`, default, `--quiet`).
     Verify the stale-cache fallback rule in §10.2.2 ("MAY be used
     to produce `valid` only if the receipt's `unix_ts` predates
     the cache entry's `fetched_at`") is sound — does this open a
     subtle attack (operator rotates key, then sets clock back)?

S.4  **Network surface (§10.5).** Verify "no network call beyond
     `/poolz`" is enforceable. Check the redirect-policy clause
     ("MUST NOT follow redirects beyond the operator-named
     coordinator host"). Verify the configurable coordinator
     (`--coordinator`, `MACPROVIDER_COORDINATOR`) is safe — does it
     let a buyer accidentally trust a wrong coordinator? Should
     non-default coordinators trigger a `trust_source` annotation?

S.5  **Canonicalization parity (§10.3).** Verify the bit-identical
     requirement is enforceable. Check the "forbids lenient mode"
     clause is unambiguous (CRITICAL if a verifier could plausibly
     ship `--lenient` and still claim v0.2 compliance). Verify the
     parity test (`testdata/jcs_parity.json`) is named with enough
     specificity that the IMPL prompt can pick it up.

S.6  **Rotation-grace correctness (§10.2.1).** Verify the
     `receipt_pubkey_prev` lookup rule is sound. What if `/poolz`
     returns BOTH `receipt_pubkey` and `receipt_pubkey_prev` and
     the receipt's `provider_pubkey` matches the previous one but
     the receipt's `unix_ts` is OUTSIDE the 7-day grace window?
     §10.2.1 should be explicit about timestamp-vs-grace-window
     interaction.

S.7  **Exit-code reliability (§10.4.3 + AC-25).** Verify scripts
     can depend on the exit-code mapping. Is there any case where
     a verifier would exit 0 with `result: "inconclusive"` or
     similar? AC-25's reachability test should cover this.

### Lens 3 — ARCHITECT (scope creep, locked-dep consistency, future-proof)

A.1  **BUILD-prompt fidelity (HIGHEST PRIORITY for this lens).**
     Walk through every item under
     `BUILD_SPEC_015_RECEIPTS_v0_2_VERIFY_PROMPT.md`
     "What v0.2 MUST normatively add". For each, locate the
     corresponding normative clause in SPEC-015 v0.2. Findings:
       - MISSING (item in BUILD prompt but absent from spec) = CRITICAL
       - SEMANTICALLY DRIFTED (present but with different content) = CRITICAL
       - WEAKENED (MUST in prompt became SHOULD in spec) = MAJOR
       - SCOPE EXPANDED (spec added clauses the prompt did not authorize) = MAJOR

A.2  Walk through every item under "What v0.2 MUST explicitly
     defer". Confirm the spec EITHER (a) defers cleanly with a
     citation, or (b) names the item in §15 Open Questions. Any
     partial-resolution (spec quietly decides something the prompt
     said to defer) = MAJOR or CRITICAL. Specifically check:
     - Bulk verify (`verify-all`) → defer to v0.3
     - Receipt explorer (`explain <receipt>`) → defer to v0.3
     - Model-hash binding → defer to v0.3+ (§15 Q6)
     - HSM / hardware-backed trust roots → defer
     - Cross-provider chain verification → defer
     - `/poolz` signing / TUF-style root → defer (§15 Q1)
     - Buyer SDK integration → defer (separate work item)

A.3  **Locked-dep consistency.** Verify line 4 dep updates match
     what PR #123 actually absorbed (SPEC-001 v1.6, SPEC-002 v1.4
     candidate `receipt_pubkey_prev`, SPEC-006 v0.9 candidate
     allowlist). No new v0.2 demands on locked specs.

A.4  **Implementation-prescription leakage.** Verify v0.2 contains
     NO implementation prescriptions beyond defining the verifier
     contract. The §10.4 "Go port" mention is a v0.3 IMPL hint that
     belongs in the IMPL prompt — verify it does not creep into the
     spec as a normative "the verifier MUST be written in Go." Same
     for "phase7-verify/" path (impl detail, not normative).

A.5  **§10 placement vs §17.** v0.1 had §10 as informative-with-
     v0.2-promise. v0.2 promoted §10 in place rather than adding
     a new §17. Verify this is the right choice — does any v0.1.x
     forward-reference assume §10 stays informative? Audit §11-§16
     for any cross-reference to "§10 (informative)" that's now
     stale.

A.6  **Forward-compatibility with v0.3+.** Verify v0.2's
     `bundle_version: 1` strict-mode lets v0.3 add fields without
     breaking v0.2 verifiers on old bundles. Verify exit codes
     are pinned tightly enough that v0.3 cannot accidentally
     overload them. Verify `trust_source` enum is closed enough
     that v0.3 cannot add a new source without breaking JSON-
     parsing consumers.

A.7  **README compatibility (§16).** v0.2 does NOT update §16. Is
     this correct? The README v1 schema sketch was about
     issuance, not verification — so v0.2 has nothing to map
     against. Confirm.

A.8  **§14 AC numbering continuity.** AC-18 through AC-27 follow
     AC-17. Verify no AC is named "AC-9" (was dropped per v0.1.2 M2)
     or otherwise out of sequence. Check each new AC is
     independently verifiable from outside the spec (i.e. an
     implementer who has not read this prompt can execute it).

A.9  **§15 Q2 / Q4 update text.** Verify the deferrals are
     written so they could go either way in v0.3 (the spec is not
     pre-committing v0.3 to a particular skew window or replay
     binding). Both updates should be neutral.

A.10 **Trust-boundary completeness.** §10.6 lists 5 "DOES NOT
     prove" clauses. Are there any others that belong? Specifically:
     - Does `valid` prove the prompt/output was NOT tampered in
       transit between provider and buyer? (it does — confirm §10.6
       doesn't accidentally over- or under-claim this)
     - Does `valid` prove that the *same* buyer who is verifying
       was the *original* recipient? (it does NOT — §10.6 already
       names this via the "delivered to the buyer who is now
       verifying it" clause; check it's clear)
     - Does `valid` prove that no other receipt was also issued
       for the same response? (it does NOT — but the spec is
       probably silent on this; flag as MINOR or QUESTION)

## Reporting format

Open `specs/SPEC-015-v0-2-audit.md`. Append a section for each
lens you ran. Each lens section has the structure:

```
## Lens: <code | security | architect> — round <N> by <Codex | Claude>

**Verdict:** <READY TO LOCK | READY WITH FIX PASS | DESIGN ROUND
NEEDED | DROP AND RESTART>

**Counts:** N CRITICAL, M MAJOR, P MINOR, Q QUESTIONS

### CRITICAL findings

#### C1. <Short title>
**Location:** §X.Y line N–M (or AC-NN, etc.)
**Finding:** <one paragraph describing the problem precisely>
**Why it matters:** <one paragraph on impact>
**Suggested fix:** <one paragraph; do not rewrite the spec, just
sketch the direction>

(repeat for each CRITICAL)

### MAJOR findings
(same structure as CRITICAL)

### MINOR findings
(same structure but more compact — one paragraph total per finding
is fine)

### QUESTIONS
(genuinely open questions for the operator)
```

The verdict thresholds:
- **READY TO LOCK** — 0 CRITICAL, 0 MAJOR. v0.2 ships.
- **READY WITH FIX PASS** — 0 CRITICAL, ≤2 MAJOR with named fixes.
  v0.2.1 ships after one fix pass.
- **DESIGN ROUND NEEDED** — ≥1 CRITICAL or ≥3 MAJOR. v0.3 design
  loop, not a v0.2.x patch.
- **DROP AND RESTART** — the audit reveals the §10 promotion is
  the wrong shape entirely (e.g. tri-state result is the wrong
  primitive). v0.2 design re-thought from BUILD prompt.

## After all three lenses complete

Cross-reference findings: if `code.C2`, `security.C3`, and
`architect.A1` all flag the same root cause, the audit's effective
severity is the highest of the three. Mark such convergent findings
explicitly in a final "Convergent findings" section at the bottom
of the file — these are the highest-confidence fixes for the next
round.

Stop. Hand back to the operator. The operator will decide whether
to fix and re-audit, or accept the verdict and move on to the
BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md.

=== END PROMPT ===
```
