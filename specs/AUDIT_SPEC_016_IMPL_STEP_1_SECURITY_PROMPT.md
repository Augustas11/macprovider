# IMPL audit prompt — SPEC-016 Step 1, **SECURITY REVIEW lane**

Lane 2 of 3 parallel codex audit lanes for SPEC-016 Step 1 IMPL
(branch `impl/spec-016`, current SPEC v0.1.21 LOCKED at `f0152c0`,
Step 1 IMPL commit `1df0235`).

**House practice:** three codex lanes fire in parallel —
`code-reviewer` / `security-reviewer` / `architect`. This is the
security-reviewer lane. Findings from all three lanes consolidate
at the end of the round into the fix-pass triage.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Expected wall-clock: 30–45 min (signature-verification + replay-class
+ DSN-durability concerns warrant deeper probing than typical code
review).

This is **read-only** — codex MUST NOT modify any file, commit,
push, or change git state.

---

```
=== BEGIN PROMPT ===

You are the **security-reviewer** lane (2 of 3) auditing SPEC-016
Step 1 IMPL. Two sibling lanes (code-reviewer + architect) are
firing in parallel; you do NOT need to consider code-style or
architecture concerns — those are explicitly out-of-scope for your
lane so that the three lenses stay independent and diverse.

## Shared context

Read `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md` for the FULL
shared context block (PR consolidation note, version history
v0.1.19 → v0.1.21, Step 1 IMPL ∩ v0.1.21 deltas intersection,
threat model recap, required reading in order, file/LOC catalog of
what Step 1 added, severity scale, discipline rules). Treat that
file's lines 1–247 as your full context preamble.

The SPEC is LOCKED at `specs/SPEC-016-payout-pipeline.md` v0.1.21
on branch `impl/spec-016` at commit `f0152c0`. Step 1 IMPL is
commit `1df0235` on the same branch. Working tree is clean.

**This is money-OUT code.** A defect here can drain a hot wallet
that holds operator USDC. The threat model recap in the master
prompt names four adversaries — re-read it before drafting any
finding.

## Your lane scope: SECURITY REVIEW only

From `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md`, attend ONLY to
the **Dimension 2: SECURITY REVIEW** focus areas. Do NOT report
findings in code style or architecture — those land in the sibling
lanes' files.

Threat models (recap from master prompt):

- **Adversary A — stolen `provider_token`.** Owns a valid token
  but does NOT own the wallet being registered. The §3.2 EIP-712
  proof-of-possession is the gate; if verification is wrong,
  stolen-token → drain primitive.
- **Adversary B — malicious portal / on-path attacker.**
  Intercepts a legitimate signed request and replays it with a
  different `chain`, `ts_utc`, or `verifyingContract`. If
  decorative-field equality discipline is wrong, a captured
  signature stays valid forever.
- **Adversary C — DoS attacker.** Submits high volumes of
  well-formed-but-signature-invalid requests. Probes for resource
  exhaustion vectors in the EIP-712 verifier + nonce table +
  deny-list path.
- **Adversary D — operator-key compromise** (Step 1 scope-limited;
  Step 1 does not mount operator-key endpoints, but the schemas
  Step 1 ships are the foundation Steps 3 / 4 lean on; flag any
  Step 1 surface that would expand the Adversary D blast radius
  in later steps).

The Dimension 2 focus-area list in the master prompt covers:

1. **EIP-712 verification end-to-end** — re-derive the digest by
   hand for the test's known private key (`59c6...690d`), recompute
   the EIP-712 digest from test inputs, confirm decred's
   RecoverCompact yields the same signer. Cross-reference against
   an independent reference (ethers.js `signer.signTypedData`)
   conceptually — would Step 1's typed-data byte-encoding produce
   the SAME signature ethers.js would expect? A self-consistent
   IMPL test that's wrong against the reference is the
   highest-CRITICAL failure mode.
2. **Decorative-field replay** — verify every typed-data field
   (`providerId`, `address`, `chain`, `nonce`, `tsUtc`,
   `verifyingContract`) is byte-equal-asserted against the
   corresponding request body field. Test the case-sensitivity of
   `Chain` and `ProviderID` (per-byte hash, no case fold).
3. **Cross-provider replay table scoping** — anti-replay PK is on
   `(canonical_address, nonce)`, NOT `provider_id`. Walk the
   "Alice's sig replayed under Bob's provider_id" scenario through
   every Step 1 defense; confirm the decorative-field check is the
   load-bearing catch.
4. **EIP-55 backward-compat** for pure-uppercase + pure-lowercase
   acceptance with checksum SKIPPED — probe whether mixed-case
   that satisfies `pureLower || pureUpper` can bypass the checksum
   branch (look for boolean-flag conflations).
5. **EIP-712 RecoverCompact edge cases** — verify v ∈ {27,28} only,
   no silent acceptance of compressed-pubkey variants {31,32};
   probe with crafted signatures.
6. **Bearer extraction strict-trimming** — `bearerFromHeader` is
   the auth surface; probe for multi-line / folded-header bypass
   classes.
7. **Anti-replay DoS surface** — compute worst-case table size at
   the SPEC's allowed throughput; confirm the table cannot grow
   unbounded under adversarial nonce values; verify the pruner
   cadence (1 min) plus retention (10 min) bounds it.
8. **Migrations on operator-controlled DB file** — hostile-operator
   pre-existing `payout_attempts` with malicious indexes would
   slip past `CREATE INDEX IF NOT EXISTS`; document residual risk
   even if Step 1 deployment moots it for the first cutover.
9. **PRAGMA synchronous=FULL on every connection** — Step 1
   changed the DSN globally. Spin up multiple goroutines hitting
   the DB, read each conn's PRAGMA value, confirm none silently
   runs with NORMAL.
10. **Pre-auth pause check bypass timing** — SPEC §3.3 demands
    identical 503 bodies across the two callsites (pre-auth +
    in-txn re-check). Probe whether the timing differential
    between the two callsites lets an attacker distinguish via
    response-time oracle.
11. **v0.1.21 deny-list framing (newly in-scope per SPEC bump)** —
    the hot-wallet-as-funding-SOURCE denial lands in Step 3, but
    Step 1's `internal/payout/deny.go` denies the hot wallet as
    payout-destination from `SecurityConfig.HotWalletAddress`. Walk
    the v0.1.21 §3.2 deny-list framing against Step 1's deny-list
    construction to confirm Step 1 honors the destination side
    completely. Flag if Step 1's deny-list framing leaves any
    door open that Step 3 will have to close in a hurry.

Findings format (per master prompt Dimension 2 spec):

```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how the attacker exploits it>
  File: <path>:<line>
  Fix: <suggested remediation>
```

Severity scale (from master prompt):

- **CRITICAL** — money loss vector, signature-verification bypass,
  silent migration corruption, or any defect that lets a stolen
  `provider_token` register a wallet the holder doesn't control.
  MUST be fixed before next step.
- **MAJOR** — real bug with confirmed reproduction, not on the
  immediate money path. SHOULD be fixed or Appendix B.
- **MEDIUM** — defect or SPEC deviation that survives to
  production but does not obviously enable an immediate exploit.
  Fix before merge OR Appendix B.
- **LOW** — informational, hardening suggestion. MAY be deferred.

The audit-loop discipline at `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
§3 requires 0 CRITICAL / 0 MAJOR / 0 MEDIUM across **all three
lanes combined** before push/PR.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_1-security-audit.md`
with this structure:

```
# SPEC-016 IMPL Step 1 — codex SECURITY REVIEW lane, round 1

## Verdict (security review lane only)

<one-line summary: CLEAN | FIX-THEN-PROCEED | BLOCK>

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| <N>      | <N>   | <N>    | <N> |

## Findings

[sec:1.1] [SEVERITY] ...
[sec:1.2] [SEVERITY] ...

## Adversarial probes I ran

<list of explicit attack scenarios you tried (with results); e.g.
"Adversary A: forged signature with mutated chainId — defense
catches at <file:line>"; mark any probe as "verified pass" or
"defense gap" or "needs runtime verification">

## Tests run

<list of `go test -race`, fuzzing, manual probe invocations>

## SPEC drift catalog (security-side only)

<any normative SPEC §-paragraph that exists to close a security
class but Step 1 does not implement faithfully; cite SPEC line
numbers + IMPL file:line>

## What I didn't review

<files/areas you intentionally skipped, with rationale>

## Cross-cutting security observations

<patterns spanning multiple findings; threat-model implications>

## Note on sibling lanes

You are explicitly NOT reporting code-style or architecture
findings here. If a security observation overlaps with code or
architecture, note the overlap in "Cross-cutting security
observations" but defer the verdict to the sibling lane.
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Model the attacker explicitly. Without an attacker model, a
  finding is a code smell, not a security defect.
- Be conservative on CRITICAL — concrete attack + impact
  describable in one sentence.
- Honest uncertainty: MAJOR + "needs runtime verification" tag
  when you can't confirm without dynamic evidence.
- Cite the binding SPEC rule for every violation claim.
- Reference the threat-model adversary (A / B / C / D) for every
  finding so the consolidator can prioritise by blast radius.

You may run shell commands (git log, grep, find, `go vet`,
`go test -count=1 -race ./...`, fuzz harnesses). You MUST NOT
modify any file.

You may take up to 45 minutes wall-clock. If you finish earlier
with a clean report, that's fine — do not pad.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- This is **Lane 2 of 3** in the parallel codex audit fan-out.
  Sibling lanes:
  - `AUDIT_SPEC_016_IMPL_STEP_1_CODE_PROMPT.md` — code-reviewer lane
  - `AUDIT_SPEC_016_IMPL_STEP_1_ARCH_PROMPT.md` — architect lane
- Findings files:
  - `specs/SPEC-016-IMPL-STEP_1-code-audit.md`
  - `specs/SPEC-016-IMPL-STEP_1-security-audit.md` (this lane)
  - `specs/SPEC-016-IMPL-STEP_1-arch-audit.md`
- Loop until **all three lanes combined** return
  0 CRITICAL / 0 MAJOR / 0 MEDIUM before push/PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-016 v0.1.21 IMPL Step 1.
