# Audit prompt — SPEC-015 v0.1 verifiable inference receipts

Operator-paste prompt to audit SPEC-015 v0.1
(`specs/SPEC-015-receipts.md`), MacProvider's first per-response
signed-receipt spec.

**Cross-model pattern:** the spec was drafted by Claude (executing
`specs/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md`). For independence,
the audit runs in **Codex CLI first** (via `omc ask codex` or the
ambient `ask` skill). After Codex round 1 lands, run the same prompt
in Claude as round 2; both audit reports go into
`specs/SPEC-015-audit.md` as separate sections, matching the
SPEC-001/002/006/008/013 audit history.

Expected duration: ~45–75 min per model. SPEC-015 v0.1 is shorter
than SPEC-006 (≤ 700 lines) but its failure modes are crypto- and
canonicalization-heavy; bias toward thoroughness on §3, §4, §5, §6,
§7 over the introductory sections.

History note: SPEC-015 is the project's first **cryptographic
contract** spec. The audit bar is the same as SPEC-001/002 (those
went through 3–5 rounds each), but the failure modes are different —
canonicalization ambiguity, signature-encoding edge cases, key-
lifecycle race conditions, and trust-root honesty.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session (round 1) or Claude Code session
(round 2) rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-015 v0.1, MacProvider's first per-response
signed-receipt spec at /Users/augstar/macprovider-poc/specs/SPEC-015-receipts.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, let the
operator decide fixes. The operator has read the spec; they need an
independent second (or third) opinion on what is missing, wrong, or
under-specified.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-015-audit.md

Format: structured audit report. Findings grouped by category, each
finding tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION) and
location (section number + line range if possible). Match the rigor of
the prior audit reports in this repo (specs/SPEC-006-audit.md,
specs/SPEC-008-audit.md, specs/SPEC-013-audit.md). If you are running
as round 2 (Claude after Codex), APPEND your section to the existing
file, do not overwrite Codex's round 1.

## Severity definitions

- **CRITICAL** — would cause verifier-side rejection of valid
  receipts, signature forgery surface, key leakage, OpenAI SDK
  incompatibility, irrecoverable canonicalization ambiguity, violation
  of a locked SPEC-001/SPEC-002/SPEC-005/SPEC-006/SPEC-008/SPEC-011
  invariant, or a misrepresentation of the v0.1 trust root that lets
  a buyer think they are getting a stronger guarantee than the spec
  delivers.
- **MAJOR** — would cause significant operator burden, predictable
  buyer confusion, race condition on key rotation, a v0.2 patch
  within first month of deployment, or an ambiguity that two
  conforming implementations could resolve differently and produce
  non-verifying receipts. Unjustified numeric thresholds (grace
  window, header size cap, ttft skew), hand-wavy requirements,
  "TBD"s disguised as OQs.
- **MINOR** — quality issues that don't block v0.1 but should be
  cleaned in v0.2. Naming inconsistencies, missing cross-references,
  underspecified edge cases that won't fire frequently, prose
  clarity.
- **QUESTION** — genuinely unresolved design choices the spec
  couldn't decide alone. Operator input required. Distinguish from
  the §15 Open Questions the spec already names — those are not
  findings unless they hide a CRITICAL/MAJOR underneath.

## Critical constraints to honor while auditing

**1. SPEC-001 v1.5, SPEC-002 v1.3.5, SPEC-005 v0.3, SPEC-006 v0.8.3,
SPEC-008 v0.3, SPEC-011 v0.5, SPEC-013 v0.3 are LOCKED.** SPEC-015
v0.1 layers on top of them. Any SPEC-015 clause that would require
changes to those locked specs is a CRITICAL finding ("scope creep
across spec boundary") UNLESS it is presented as a v0.x candidate
annotation in the SPEC-008-style pattern (additive, parser-optional,
non-breaking, named with the candidate target version). The two
annotated extensions in v0.1 are:

- SPEC-001 v1.6 candidate: `provider_receipt_public_key` on
  `auth_request` initial-stage frame.
- SPEC-002 v1.4 candidate: `receipt_pubkey` and
  `receipt_pubkey_prev` on `/poolz` provider rows.
- SPEC-006 v0.9 candidate: `X-MacProvider-Receipt` on the response-
  pass-through allowlist.

These three candidate annotations are legitimate. Any OTHER demand on
a locked spec is CRITICAL.

**2. OpenAI SDK drop-in MUST be preserved.** The OpenAI Python and
JavaScript SDKs MUST continue to work for `chat.completions.create()`
both streaming and non-streaming. Any clause that breaks SDK
compatibility (e.g. a streaming receipt encoding the SDK cannot
parse, a non-streaming response shape the SDK rejects) is CRITICAL.

**3. v0.1 is normative spec only, no implementation.** This spec
does NOT ship code. Any clause that gates v0.1 LOCK on code
existing in the repo is CRITICAL ("scope creep into BUILD_SPEC
territory").

**4. The trust root MUST be honestly described.** v0.1's pubkey
trust root is `/poolz`, which is operator-mutable. Any clause that
claims a stronger guarantee than this (e.g. "tamper-evident
publication", "cryptographic trust root", "buyer cannot be deceived")
is CRITICAL. The SPEC explicitly acknowledges this in §1.4 and §8.3;
verify the acknowledgement is not contradicted elsewhere.

**5. d-inference clean-room.** Do NOT inspect d-inference source.
Reading their LICENSE for cross-reference is allowed; reading their
README/docs is allowed but discouraged. Any SPEC-015 clause that
appears to require d-inference inspection is CRITICAL.

**6. SPEC-005 v0.3 settlement formula MUST NOT be modified.**
`tokens_out` in the receipt reuses
`effective_completion_tokens` from SPEC-005 §4 unchanged. Any clause
that redefines token accounting, refund matrix, or null-usage
treatment is CRITICAL ("operator pre-commitment violated:
SPEC-005 is locked").

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-015-receipts.md`
   v0.1 — the spec under audit. Read fully, all 16 sections, all
   18 acceptance criteria. Bias toward reading §3
   (Receipt content), §4 (Prompt canonicalization), §5 (Output
   canonicalization), §6 (Wire transport), and §7 (Keypair
   lifecycle) carefully — these encode the most precise
   commitments.

2. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md`
   — the BUILD prompt with the operator's spec-writing instructions.
   The spec MUST honor every item under "What v0.1 MUST normatively
   pin" and every item under "What v0.1 MUST explicitly defer". Diff
   it against SPEC-015 §1, §3–§8, §15; any deviation = MAJOR finding
   ("BUILD prompt directive drift").

3. `/Users/augstar/macprovider-poc/README.md` lines 1–137 — the
   thesis, the vapor claim at line 22, and the v1 receipt schema
   sketch at lines 117–128. The spec MUST close the vapor claim and
   either match or explain divergence from the schema sketch.

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.5 — the provider-side spec. Focus on §6.7 (v2 `auth_request`
   handshake) where SPEC-015's `provider_receipt_public_key` field
   annotates as a v1.6 candidate, and §6.4–§6.5 for streaming
   contract. The SPEC-015 candidate annotation MUST follow the
   SPEC-008 v0.3 §5.3/§5.7 SPEC-001 v2.0 annotation pattern
   (additive, parser-optional, non-breaking). Any deviation =
   MAJOR or CRITICAL.

5. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.5 — the coordinator spec. Focus on §7 (HTTP surfaces incl.
   `/poolz`) and §4 (provider state). The SPEC-015 candidate
   annotation on `/poolz` MUST preserve all v1.3.5 fields and add
   only the named new ones.

6. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md`
   v0.3 — settlement contract. Focus on §3 (X-1 null-usage row) and
   §4 (`effective_completion_tokens` derivation). SPEC-015 §7.6
   MUST agree with SPEC-005 X-1 settlement; any divergence =
   CRITICAL.

7. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.8.3 — gateway spec. Focus on §17 (header strip rules,
   X-MacProvider-* allowlist) and §C (OpenAI SDK compatibility).
   The SPEC-015 `X-MacProvider-Receipt` candidate annotation MUST
   slot cleanly into the §17 allowlist pattern.

8. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   v0.3 — Tier-2 trust layer. Focus on §5.5
   (`provider_ecdh_public_key` handling) for the candidate-
   annotation pattern, and §5–§8 for the Pillar A/B/C orthogonality
   claims SPEC-015 §1.3 makes.

9. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 — warm-swap spec. Focus on §3.3.1 (`model_hash` heartbeat)
   and §3.8 (drain semantics). SPEC-015 §7.4 receipt-drain
   invariant MUST be consistent with §3.8.

10. `/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md`
    v0.3 — for the RFC8785JCS reuse claim.

11. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`
    — the in-house JCS implementation SPEC-015 reuses. Verify the
    spec's §3.2 canonical-encoding claims match what this file
    actually does (NFC handling, U+FFFD escape, code-unit sort
    order).

12. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
    Entries 79–81 — the operator context for the 2-person beta
    posture in which v0.1 ships. v0.1 deferrals (model-hash,
    auto-rotation, on-chain anchoring) should match the operator's
    Entry 80 tier-2 posture deferral pattern.

13. `/Users/augstar/macprovider-poc/specs/SPEC-006-audit.md`,
    `specs/SPEC-008-audit.md`, `specs/SPEC-013-audit.md` — for
    tone and severity-bar continuity.

## Audit categories — work through each

### Category A: BUILD-prompt directive fidelity (HIGHEST PRIORITY)

A.1  Walk through every item under
     `BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md` "What v0.1 MUST
     normatively pin". For each, locate the corresponding normative
     clause in SPEC-015 v0.1. Findings:
       - MISSING (item in BUILD prompt but absent from spec) = CRITICAL
       - SEMANTICALLY DRIFTED (present but with different content) = CRITICAL
       - WEAKENED (MUST in prompt became SHOULD in spec) = MAJOR
       - SCOPE EXPANDED (spec added clauses the prompt did not authorize) = MAJOR

A.2  Walk through every item under "What v0.1 MUST explicitly
     defer". For each, confirm the spec EITHER (a) defers cleanly
     with a citation to the deferring section, or (b) names the
     item in §15 Open Questions. Any partially-resolved deferral
     (e.g. spec quietly decides something the prompt said to defer)
     = MAJOR or CRITICAL.

A.3  Verify the spec contains NO implementation prescriptions
     beyond what's needed to define the contract. Code-level
     prescriptions belong in BUILD_SPEC_015; any "the gateway
     handler MUST be implemented as ..." clause = MAJOR
     ("scope creep into BUILD territory").

### Category B: Receipt content correctness

B.1  Tuple shape (§3.1): exactly seven keys, no more, no less. If
     the spec implies or allows extra/missing keys anywhere = MAJOR.

B.2  Field types: each of the seven fields has a well-defined JSON
     type and a precise definition. Any field whose type is
     ambiguous ("integer or string", "either form acceptable") =
     CRITICAL.

B.3  `model_id` storage: the spec says "as it appears in the
     request" — verify this is internally consistent with §4.5
     (request body passed verbatim) and SPEC-001 v1.5 §6.4
     (case-insensitive matching but verbatim storage). If
     contradictory = MAJOR.

B.4  `prompt_hash`/`output_hash` encoding: 64 lowercase hex,
     no prefix. If the spec also accepts uppercase, `sha256:`
     prefix, or any other encoding anywhere = MAJOR.

B.5  `provider_pubkey` encoding: 44-char standard padded base64
     of 32 bytes ed25519. If anywhere the spec allows URL-safe
     base64 substitution or unpadded form = CRITICAL (verifier
     ambiguity).

B.6  Integer field encoding (§3.1 + §3.2): JCS canonical decimal,
     no fractional, no exponent. If allowed elsewhere = MAJOR.

B.7  Receipt size envelope (§3.4): the 4096-byte header cap is
     justified by a back-of-envelope calc. If the calc is wrong
     (sum of components exceeds the cap) = MAJOR.

### Category C: Canonicalization correctness

C.1  Prompt canonical object (§4.2): exactly ten keys, all named.
     Verify the list matches "what does the provider observe of the
     request" and excludes fields the spec explicitly excludes
     (`stream`, `user`, `metadata`, etc.). If a relevant field is
     missing from the ten that materially affects output (e.g.
     `frequency_penalty` affects sampling but is excluded) =
     MAJOR with operator-input requirement.

C.2  Message canonicalization (§4.3): the five-key shape and
     fallback `null` for absent fields. Verify this covers the
     OpenAI message shapes actually emitted by the OpenAI Python +
     JS SDKs. If a common SDK-emitted shape (e.g. assistant message
     with no `content`) doesn't fit = MAJOR.

C.3  Content array shape (§4.3.1): the multimodal cases. If a
     SDK-emitted shape (e.g. `image_url` with a buyer-supplied
     `detail: "auto"`) doesn't fit = MAJOR. If the spec admits
     buyer-supplied keys not on the named list = MAJOR (under-
     specified canonicalization).

C.4  NFC normalization (§4.3.1, §5.2): the spec normalizes once at
     end. Verify Swift's `String.precomposedStringWithCanonicalMapping`
     or equivalent is the named mechanism. Cross-implementation
     drift on NFC is a real failure mode; if the spec leaves
     the normalization library unspecified = MAJOR.

C.5  Newline handling (§4.3.2, §5.2): `\r\n` → `\n`, `\r` → `\n`,
     no whitespace stripping. Verify this is symmetric between
     prompt and output canonicalization. If asymmetric = MAJOR.

C.6  Streaming output canonicalization (§5.2): concatenation +
     end-of-stream NFC, intermediate normalization forbidden. The
     justification (NFC across chunk boundaries is not
     associative) is correct; verify the spec actually FORBIDS
     intermediate normalization, not just discourages it. If only
     SHOULD = MAJOR.

C.7  Tool-call commitment (§5.3): byte-exact `arguments` string
     in `tool_calls` inside `output_hash`. Verify the spec does
     not silently parse-and-recanonicalize the args, which would
     break verifier reproducibility. If ambiguous = MAJOR.

C.8  `output_hash` byte-equivalence invariant (§5.5): streaming
     and non-streaming for identical bytes produce identical hash.
     Verify this is internally consistent with §5.2's
     end-of-stream normalization.

### Category D: Wire transport

D.1  Header name uniqueness (§6.1): `X-MacProvider-Receipt` does
     not collide with any SPEC-002/SPEC-006/SPEC-008/SPEC-013
     existing X-MacProvider-* header. Verify by grepping every
     locked spec for `X-MacProvider-`.

D.2  Header value format (§3.4 + §6.1): `<b64>.<b64>` is
     unambiguous. If the spec allows whitespace, different
     separators, or other parsing flexibility = CRITICAL.

D.3  SSE shape (§6.3): `event: receipt` block before
     `data: [DONE]`. Verify this is valid SSE (RFC 8895 / WHATWG
     EventSource). If the framing diverges from SSE = CRITICAL.

D.4  OpenAI SDK compatibility on SSE (§6.3 + AC-R10): both SDKs
     must tolerate unknown `event:` blocks. If the SDKs actually
     break (verify by reading SDK source or testing) = CRITICAL.

D.5  Header forwarding (§6.2): gateway must forward
     `X-MacProvider-Receipt` untouched. Verify this is consistent
     with SPEC-006 v0.8.3 §17 header-strip rules and the candidate
     allowlist annotation.

D.6  Omission cases (§6.4): four named cases. Verify each is
     unambiguous and detectable by the buyer (header absence is
     the only signal). If a case is silently overlapping with
     "header present with empty value" = MAJOR.

D.7  Trailers (§6.3): spec explicitly rejects HTTP trailers.
     Verify this is consistent with how the gateway and SPEC-001
     v1.5 actually handle the response body.

### Category E: Keypair lifecycle

E.1  Keychain attributes (§7.1): `AfterFirstUnlockThisDeviceOnly`,
     `Synchronizable=false`. Verify these match the security
     posture (private key never leaves device, not iCloud-synced).
     If a more permissive attribute is named = CRITICAL.

E.2  First-launch race (§7.1): generation happens before first
     auth_request. If two `serve` processes can launch
     simultaneously and race on Keychain insert = MAJOR.

E.3  Publication on auth (§7.2): parser-optional on coordinator
     side. Verify SPEC-001 v1.5 §6.7.1 parser-required-fields list
     can accept this field as optional (the table at lines
     1769–1786 must not block additive optional fields). If the
     SPEC-001 frame validator rejects unknown additive fields =
     CRITICAL.

E.4  Coordinator storage (§7.3): SQLite additive column. Verify
     the ALTER TABLE is consistent with SPEC-002 v1.3.5 storage
     conventions and append-only-ish posture. If the column type
     or constraint conflicts with v1.3.5 schema = MAJOR.

E.5  Persistence-across-restart (§7.3): coordinator MUST keep the
     pubkey across restart. Verify the storage mechanism actually
     survives restart in the v1.3.5 coordinator design. If the
     in-memory pool only is implied = MAJOR.

E.6  Manual rotation flow (§7.5): the CLI flag, the control
     frame, the grace window. Verify each is unambiguous and
     verifier-friendly. Specifically, the grace window
     `min(7 days, 10000 requests)` is two thresholds — verify
     the spec defines which fires first and the operator can read
     a single `expires_at`. If ambiguous = MAJOR.

E.7  Rotate control frame (§7.5.1): `version: 1` is set, schema
     is defined. If the schema is missing any field a verifier
     needs to validate the rotation, or the validation checks are
     under-defined = MAJOR.

E.8  Replay-prevention on rotate (§7.5.1): ±300s timestamp
     check. If the check is missing, weaker, or absent under
     known reorder scenarios = CRITICAL (silent key takeover
     surface).

E.9  Null-usage receipts (§7.6): `tokens_out=0`, deterministic
     `output_hash` for empty content. Verify the computed hash is
     reproducible by a verifier following §5.1 → an empty
     canonical object's JCS is well-defined; spell-check whether
     the named hash is correct.

### Category F: Pubkey trust root

F.1  `/poolz` extension (§8.1): additive fields, no removal.
     Verify SPEC-002 v1.3.5 §7 fields are preserved.

F.2  Honesty about operator-mutability (§8.3): explicit
     acknowledgement that v0.1 trust root is operator. Verify no
     other section of the spec accidentally claims a stronger
     guarantee. If anywhere the spec says or implies
     "tamper-evident", "cannot be deceived", "cryptographic trust
     root", etc. = CRITICAL.

F.3  Forward-compat for trust-root migration (§8.4): wire format
     unchanged across trust-root strengthening. Verify no v0.1
     verification step bakes in a `/poolz`-specific contract that
     would force a wire change later.

F.4  Buyer fetch ergonomics (§8.2): cache window ≤ 60s. Verify
     SPEC-002 v1.3.5 §7 actually permits this caching cadence.

### Category G: Audit categories and observability

G.1  `receipt_issued` payload (§11): logs four scalar fields, NOT
     the full receipt value. Verify this is consistent with the
     SPEC-005 v0.3 §6 audit-sink shape. If the named fields
     duplicate existing audit-sink fields with conflicting names
     = MAJOR.

G.2  `receipt_omitted` reasons (§11): four named reasons.
     Verify each maps 1:1 to a §6.4 omission case. If a §6.4 case
     is missing from §11 (or vice versa) = MAJOR.

G.3  Audit log retention (§11 + §13 last paragraph): spec MUST
     NOT persist the full receipt server-side (offline-
     verifiability requirement). Verify no clause violates this.
     If anywhere implies the server stores the receipt = CRITICAL.

### Category H: Storage and persistence

H.1  Storage table (§13): each row is concrete and additive. If
     the spec implies a destructive schema change on the
     coordinator v1.3.5 DB = CRITICAL.

H.2  Provider Keychain item identifier: unique per
     `provider_id`. Verify reinstall semantics work as described.

H.3  Coordinator schema additions: three new columns. Verify
     they fit SPEC-002 v1.3.5 §10 storage conventions (column
     naming, nullable, append-only-ish).

### Category I: Cross-spec invariant preservation

I.1  SPEC-005 v0.3 settlement parity: SPEC-015 §7.6
     null-usage receipt does NOT change SPEC-005 X-1 settlement.
     Verify against SPEC-005 v0.3 §3 X-1 row.

I.2  SPEC-006 v0.8.3 header allowlist: candidate addition is
     correctly scoped. Verify §17 strip rule still applies to
     unknown `X-MacProvider-*` headers, just NOT to
     `X-MacProvider-Receipt`.

I.3  SPEC-008 v0.3 orthogonality: the §1.3 claim that
     receipt issuance is independent of Pillar A/B/C. Walk
     through SPEC-008 §5.3 (Pillar A), §6 (Pillar B), §7
     (Pillar C). For each, verify there is no path where Pillar
     enforcement could break receipt issuance, and vice versa.
     If a Pillar A model-hash rejection silently swallows the
     receipt path = CRITICAL.

I.4  SPEC-011 v0.5 drain invariant: §7.4 receipt-during-swap
     rule. Verify against SPEC-011 §3.8.4 drain semantics. If
     the receipt could be emitted from a different
     `ModelRuntime` instance than the one that produced the
     response = CRITICAL.

I.5  SPEC-013 v0.3 JCS reuse: §3.2 names the in-house Swift
     implementation. Verify the file
     `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`
     actually implements RFC 8785 §3.2.3 + §3.2.2.5 and the
     spec's claim about its escape behavior is accurate. If
     mismatched = MAJOR.

I.6  SPEC-001 v1.5 §6.7 frame-validator behavior: parser-
     required vs parser-optional. Verify the candidate
     annotation respects the existing validator's tolerance for
     unknown fields. If the validator REJECTS unknown additive
     fields = CRITICAL (SPEC-001 v1.6 candidate is then
     unimplementable without a SPEC-001 normative change).

### Category J: Acceptance criteria quality

J.1  Each AC must have a deterministic verification step
     (curl command, SDK invocation, computed hash check). Any AC
     that is hand-wavy ("the system should work") = MAJOR.

J.2  ACs must cover the named surfaces: keypair generation,
     pubkey publication, header presence, both streaming and
     non-streaming, signature verification, prompt-hash
     recompute, output-hash recompute, SDK compatibility,
     rotation, grace window, null-usage, gateway omission for
     pre-v1.6 providers, performance, parser-optional fallback.
     If any uncovered = MAJOR.

J.3  AC-R12 grace-window timing math: verify the −60s slack is
     justified. If the slack is wrong direction or wrong
     magnitude = MAJOR.

J.4  AC-R17 performance bound (>5 ms p95): verify the assertion
     about Apple Silicon ed25519+sha256 cost is plausible. If
     the threshold is unenforceable in practice = MINOR.

### Category K: Honesty about deferrals

K.1  §15 Open Questions: each Q is genuine and not hiding a
     pinned decision. If §15 lists a Q that the body of the
     spec actually decides = MAJOR.

K.2  v0.3+ deferrals (model-hash, on-chain, TUF, multi-segment):
     each is named with a clear gate condition. If a deferral
     is open-ended ("eventually") = MINOR.

K.3  The vapor-claim closure: the spec's §1 closes the README
     line 22 vapor claim. Verify the spec is internally honest
     about the gap between v0.1 (issuance only) and the
     README's product surface. If a README claim is silently
     left vaporware = MAJOR.

### Category L: Spec hygiene

L.1  Line 3 version-of-record present and correct
     (`**Version:** 0.1 (YYYY-MM-DD, ...)`)

L.2  Change log section present at top.

L.3  `Depends on:` line cites locked dependency versions from
     line 3 of each dependency. Verify each cited version
     matches line 3 of the cited SPEC TODAY.

L.4  House-style numbered sections, MUST/SHOULD/MAY usage
     consistent with RFC 2119. If RFC-2119 keywords are misused
     (e.g. SHOULD where the spec actually requires MUST) =
     MINOR or MAJOR depending on impact.

L.5  No "TBD". v0.1 deferrals MUST be cleanly stated as either
     §15 Open Questions or out-of-scope citations. If "TBD"
     literal appears = MAJOR.

## Output format

Produce `/Users/augstar/macprovider-poc/specs/SPEC-015-audit.md` with
this structure:

```
# SPEC-015 v0.1 audit report

## Round 1 (Codex, 2026-MM-DDTHH:MM:SSZ)

### Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- L QUESTIONS

### CRITICAL findings

C1. [Title]
    **Location:** § X.Y, line range
    **Finding:** [description]
    **Why it matters:** [impact]
    **Suggested fix:** [if obvious; "operator decision" if not]

(repeat for each critical finding)

### MAJOR findings
M1. ...

### MINOR findings
m1. ...

### Operator questions surfaced
q1. ...

### Verdict
- READY TO LOCK (zero CRITICAL, zero MAJOR-blocking)
- READY WITH FIX PASS (CRITICALs all closable in narrow fix pass)
- ANOTHER DESIGN ROUND NEEDED (architectural CRITICALs, fix won't suffice)

## Round 2 (Claude, 2026-MM-DDTHH:MM:SSZ)
(appended in round 2; do NOT overwrite round 1)
```

## Self-verification before declaring audit complete

- [ ] Read every section of SPEC-015 v0.1 (§§1–16, ACs R1–R18).
- [ ] Compared SPEC-015 against the BUILD prompt's "MUST normatively
      pin" and "MUST explicitly defer" lists. Drift documented.
- [ ] Walked each Category A through L. Even if no findings, noted
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

Operator's review checklist (~30 min per round):

1. Read the Codex round 1 findings start to finish.
2. For each CRITICAL: confirm whether it's real (Codex caught
   something Claude missed) or a false alarm (Codex misread the
   spec).
3. For each MAJOR: same triage.
4. After round 1: run the same prompt in Claude for round 2. Claude
   will read round 1 in the audit file and add round 2 below.
5. After round 2: cross-reference. Findings both audits agree on are
   high-confidence. Findings only one audit raised need operator
   triage.

## How to use the audit output

- **READY TO LOCK verdict from both rounds**: lock at v0.1. Append a
  DECISION_CRITERIA entry, push branch, open PR.
- **READY WITH FIX PASS**: apply CRITICAL fixes to SPEC-015 in place,
  bump to v0.1.1, re-run this same prompt (round 3 + 4 if needed).
  Lock at v0.1.1 or v0.2.
- **ANOTHER DESIGN ROUND NEEDED**: re-open the design question
  surfaced by the auditor (likely Q1 trust-root, Q2 replay, or Q3
  multi-segment). v0.1 is provisional pending that resolution.

Historic pattern from SPEC-001/002/006/008/013: round 1 typically
surfaces 1–3 CRITICAL + 6–12 MAJOR + 5–10 MINOR on a first-draft
v0.1 of a new contract. Round 2 confirms most CRITICALs and adds
3–5 new MAJORs the first auditor missed. Total ~3 audit cycles to
reach a locked spec.
