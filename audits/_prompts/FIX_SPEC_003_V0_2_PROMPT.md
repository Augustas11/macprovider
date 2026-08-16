# Fix prompt — SPEC-003 redistribution audit findings → v0.3 / v1.2.1 / v1.1.1

Operator-paste prompt to apply the audit findings from
`specs/SPEC-003-audit.md` (Codex's report dated 2026-05-28T05:25:44Z)
to the three-spec corpus.

The audit produced **NEEDS REVISION** verdict with 4 CRITICAL, 7 MAJOR,
3 MINOR, and 1 QUESTION. All CRITICALs are redistribution-fidelity
issues (Category Z) or coordinator wire-consistency. No architecture
restart needed. The Q1 has an operator-decided answer baked into this
prompt.

Run in **Claude Code** (same model that performed the redistribution).
Expected duration: ~2 hours.

Output: three updated specs and a handback summary.

  SPEC-001 v1.2   → v1.2.1
  SPEC-002 v1.1   → v1.1.1
  SPEC-003 v0.2   → v0.3

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are revising three specs to address audit findings. The redistribution
of SPEC-003 v0.1 (commit d9dcb0d) into SPEC-001 v1.2 + SPEC-002 v1.1 +
SPEC-003 v0.2 was audited at commit d9dcb0d; the audit (commit
TBD-at-fix-time) found 4 CRITICAL + 7 MAJOR + 3 MINOR + 1 QUESTION.

The architecture is sound and the backward-compat invariant for M4/M1
holds. Findings are about: (a) wire-schema staleness, (b) lost
behavioral mappings during redistribution, (c) routing pseudocode gaps,
(d) cross-spec reference precision. This is targeted revision, not a
rewrite.

You will edit three files in place and bump versions:
  /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md → v1.2.1
  /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md   → v1.1.1
  /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md → v0.3

## Critical constraints (re-read before each edit)

**1. Backward-compat invariant is still load-bearing.** Every change
must preserve the SPEC-001 v1.2 backward-compat statement (verbatim)
and the § 6.6 normative scope clause. Phase 3 binaries v1.1.3/v1.1.4
(M4, M1) must remain MANDATORY-compliant after your edits.

**2. d-inference clean-room.** Do not inspect d-inference source.
Clean-room paragraphs in SPEC-001 § 7.2 and SPEC-002 § 8.2 stay
verbatim.

**3. Buyer API stability.** No observable change to
POST /v1/chat/completions, GET /v1/models, GET /healthz.

**4. No new design invented.** Every fix must trace either to (a) an
audit finding's explicit fix direction, (b) the original SPEC-003 v0.1
behavior being restored, or (c) the operator-decided Q1 answer below.

**5. Match the rigor pattern.** RFC 2119 normative keywords. Numeric
thresholds with rationale. Cross-references resolve.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md
   — the audit report. Read all 11 findings + 3 MINORs + Q1.

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md (v1.2)
3. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md (v1.1)
4. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md (v0.2)

5. SPEC-003 v0.1 reference (for restoring lost content):
     git show 0b4bbb7:specs/SPEC-003-open-onboarding.md > /tmp/spec003-v0.1.md
   Read /tmp/spec003-v0.1.md for FR-A4, FR-A8 specifically (CRITICALs
   C2 and C3 require restoring content from v0.1).

6. /Users/augstar/macprovider-poc/specs/REDISTRIBUTE_SPEC_003_V0_1_PROMPT.md
   — to confirm what the prior redistribution was supposed to preserve.

7. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — D7-D10 should be faithfully encoded in SPEC-002 § 10.

## Operator decision on Q1

Q1 in the audit asked: "Should unknown provisional providers be allowed
to self-report an HTTP endpoint?"

**Operator decision: NO.** Provisional providers operate exclusively in
WS-tunneled mode. Allowing self-reported endpoint_url from unknown
provider_ids opens an anti-abuse loophole — a Sybil attacker could
register N provisional providers each pointing endpoint_url at a
target server to amplify abuse, and the coordinator would forward
buyer traffic to that target. WS-tunneled is the only safe path for
unknown providers because the WS connection is operator-controlled.

Apply this decision in SPEC-002 v1.1.1 § 3 mode resolution: if a
provider is NOT in `config.providers[]` AND the hello message includes
a non-empty `endpoint_url`, the coordinator MUST log warn level and
IGNORE the self-reported endpoint_url, treating the provider as
WS-tunneled provisional. Document the rationale + close code is NOT
required (the provider still connects, just in WS-tunneled mode).

## Findings to fix

### CRITICAL — fix first

#### C1. SPEC-002 § 7.1 stale hello/hello_ack schemas

**Location:** SPEC-002 v1.1 § 7.1

**Problem:** § 7.1 republishes the wire schemas for hello and hello_ack
but doesn't include the v1.2 fields (`endpoint_url`, `tier`,
`recommended_binary_version`) that SPEC-002 § 3 mode resolution
depends on. Also still shows `"provider_id": "uuid-of-this-instance"`
contradicting SPEC-001 v1.1.2's stable provider_id normative text.

**Fix:** Update SPEC-002 § 7.1's replicated hello and hello_ack JSON
schemas to match SPEC-001 v1.2 § 6.5 EXACTLY. Specifically:
  - hello: add optional `endpoint_url` (string or null). Replace
    provider_id example value with `"m4-anon"` (or
    `"<operator-issued-provider-id>"` if you prefer a placeholder).
  - hello_ack: add optional `tier` ("pinned" or "provisional") and
    optional `recommended_binary_version` (string).
  - Add a single sentence near the schema: "These schemas mirror
    SPEC-001 v1.2 § 6.5; SPEC-001 is the authoritative source."

#### C2. FR-A8 lost the coordinator status-to-HTTP behavior mapping

**Location:** SPEC-002 v1.1 (currently missing); originally in SPEC-003
v0.1 FR-A8

**Problem:** v0.1 FR-A8 defined a mapping table from
`inference_response_end.status` to coordinator's buyer-facing HTTP
response (e.g., model_not_loaded → HTTP 503; error_queue_full →
HTTP 503 + try next provider). SPEC-001 v1.2 FR-27 retained the status
enum but the mapping table was lost. SPEC-002 v1.1 FR-P14 mentions
relay/accumulation but no status-to-HTTP mapping.

**Fix:** Restore the mapping table in SPEC-002 v1.1.1 FR-P14 (or as a
new sub-FR FR-P14.1, your choice). Source content: SPEC-003 v0.1
FR-A8 table (see /tmp/spec003-v0.1.md). Mapping minimum:

| `inference_response_end.status` | Coordinator behavior |
|---|---|
| `200` / `success` | Relay completion to buyer with HTTP 200 |
| `error_model_not_loaded` | Return HTTP 503 to buyer; do NOT try next provider |
| `error_queue_full` | Return HTTP 503 to buyer; try next provider |
| `error_context_too_large` | Return HTTP 400 to buyer with reason |
| `error_inference_internal` | Return HTTP 502 to buyer; do NOT try next |
| `aborted` (from cancel_request) | Close buyer connection cleanly |

Verify against v0.1 FR-A8 — the table above is reconstructed from the
audit text and may need adjustment.

Also add a normative line: "Provider-internal error messages MUST
NOT appear in the buyer-facing response body. Use generic error
descriptions."

#### C3. Request-id demux error handling weakened

**Location:** SPEC-001 v1.2 § 6.6 (and/or SPEC-002 v1.1 FR-P14)

**Problem:** v0.1 FR-A4 specified: "Messages with an unknown
request_id are logged at warn level and discarded." SPEC-001 v1.2
§ 6.6 keeps the correlation field but drops the unknown-request_id
behavior + says nothing about duplicate active request_id. These
are not polish — they decide whether stale/malicious provider frames
can corrupt the wrong buyer stream.

**Fix:** Restore three normative behaviors in SPEC-001 v1.2.1 § 6.6
(or duplicate in SPEC-002 v1.1.1 FR-P14 if the request_id state
lives on the coordinator side):

  1. **Unknown request_id.** Coordinator receiving an
     inference_response_chunk or inference_response_end with a
     request_id it didn't issue MUST log warn-level + discard the
     frame. Do NOT propagate to any buyer. Do NOT close the WS.

  2. **Duplicate active request_id.** Coordinator MUST NEVER reuse
     a request_id while the prior request is still in-flight. If
     a provider observes an inference_request with a request_id
     already in its active map, that is a protocol error — provider
     sends `nak` with code `duplicate_request_id` and the original
     request continues unaffected.

  3. **Completed request_id cleanup.** Coordinator removes a
     request_id from active map after either (a) receiving
     inference_response_end, or (b) coordinator-side timeout
     (default: SPEC-002 routing.request_timeout_s). Provider
     removes from active map upon sending inference_response_end
     OR receiving cancel_request.

#### C4. SPEC-003 AC-1 weakens the clean-Mac install pass condition

**Location:** SPEC-003 v0.2 § 5 (or wherever AC-1 lives)

**Problem:** v0.1 AC-8 required `coordinator connection succeeds`
as part of the install self-test pass. v0.2 AC-1 was weakened to
`coordinator connection succeeds OR warns`. That allows shipping an
installer that never joins the pool.

**Fix:** Restore the v0.1 normative behavior. SPEC-003 v0.3 AC-1 self-
test pass condition: `model loads, inference works, coordinator
connection succeeds`. Remove "or warns."

If you want to preserve a degraded-mode allowance (e.g., install on
a Mac without internet for later use), define it as a SEPARATE
acceptance criterion AC-1a "degraded install" that does NOT satisfy
build-complete. Mark it explicitly: "AC-1a is offered for diagnostic
purposes; AC-1 pass remains the build-complete gate."

### MAJOR — fix in same pass

#### M1. Provisional request quota not integrated into routing pseudocode

**Location:** SPEC-002 v1.1 § 5

**Fix:** Update the § 5 routing pseudocode to add a quota check before
returning either a pinned candidate or a routed candidate. Pseudocode
addition:

```
function check_provisional_quota(provider, request) -> bool:
    if provider.tier == "pinned":
        return true
    quota = COUNT(requests where provider_id == provider.id AND
                  ts > now() - 1 hour)
    if quota >= FR-P16.quota_per_hour:  # 100 default
        return false
    return true

# In main routing function:
candidates = filter(c for c in pool if check_provisional_quota(c, req))
```

Also define buyer-visible result when ALL candidates are quota-blocked:
HTTP 429 Too Many Requests with retry-after header.

#### M2. Routing pseudocode still case-sensitive on model_id

**Location:** SPEC-002 v1.1 § 5

**Fix:** Replace both occurrences of `provider.model_id != model` (or
`==`) with `model_id_equal(provider.model_id, model)`. Define
`model_id_equal` as a normative helper near the top of § 5:

```
function model_id_equal(a: string, b: string) -> bool:
    # Case-insensitive comparison per D9 (Decision log Entry 16+).
    # mlx_lm.server was case-insensitive; phase3-binary v1.1.x is
    # not — caused production 404 storm on M1 on 2026-05-28.
    return casefold(a) == casefold(b)
```

Add a sentence: "Canonical casing is preserved in `/poolz` and
`/v1/models` for display; comparisons are case-insensitive throughout
routing."

#### M3. OQ-2 duplicated as SPEC-001 OQ-5 and SPEC-002 OQ-10

**Location:** SPEC-001 v1.2 OQ-5; SPEC-002 v1.1 OQ-10; SPEC-003 v0.2 OQ note

**Fix:** Apply the audit's recommended split — keep both but make the
domain split explicit and update SPEC-003's OQ-mapping note:

  - SPEC-001 OQ-5: **provider-side** WS write buffer sizing
    (gobwas/ws config on the binary). Add explicit scope sentence.
  - SPEC-002 OQ-10: **coordinator-side** WS write buffer sizing
    (per-provider buffer in the coord). Add explicit scope sentence.
  - SPEC-003 v0.3 OQ note: "v0.1 OQ-2 was split into provider-side
    (SPEC-001 OQ-5) and coordinator-side (SPEC-002 OQ-10) because the
    two buffers have different tuning constraints."

#### M4. SPEC-003 broken clean-room cross-reference

**Location:** SPEC-003 v0.2 § 7.3 (clean-room paragraph)

**Problem:** References "SPEC-001 v1.2 § 8.2" — but SPEC-001 v1.2's
clean-room section is § 7.2.

**Fix:** Change `SPEC-001 v1.2 § 8.2` to `SPEC-001 v1.2 § 7.2`.
Verify SPEC-002 reference (§ 8.2) is correct.

#### M5. SPEC-002 nak behavior contradicts backward-compat fallback

**Location:** SPEC-002 v1.1 § 7.1; SPEC-001 v1.2 change log

**Problem:** SPEC-001 v1.2 change-log says coordinator observing
`nak unknown_message_type` in response to § 6.6 dispatch MUST mark
the routing-mode resolution buggy and NOT retry. SPEC-002 § 7.1
generic nak behavior says "Do NOT disconnect the provider. A nak is
informational" — which conflicts with the special case.

**Fix:** Add a SPEC-002 v1.1.1 § 7.1 paragraph distinguishing
the two cases:

  "**Special case: nak `unknown_message_type` in response to § 6.6
  message dispatch.** When the coordinator dispatches an
  inference_request (or other § 6.6 message) and the provider replies
  with `nak code=unknown_message_type`, this indicates a routing-mode
  resolution bug: the coordinator believed the provider supported
  WS-tunneled mode when it does not. The coordinator MUST mark the
  provider's effective routing mode as `http_forwarding_only` for
  the remainder of this WS session (until the provider reconnects
  with a fresh hello), MUST NOT retry the failed request via §
  6.6, and SHOULD return HTTP 503 to the buyer for this request.
  See SPEC-001 v1.2 backward-compat statement."

Add a corresponding AC: SPEC-002 v1.1.1 AC-15 (or appropriate
number): "Coordinator dispatches inference_request to a mock
provider that responds nak unknown_message_type. Coordinator MUST
mark provider routing mode http_forwarding_only and respond HTTP 503
to the buyer."

#### M6. OQ rationale paragraphs shortened during redistribution

**Location:** SPEC-001 v1.2 OQ-4, OQ-5; SPEC-002 v1.1 OQ-6, OQ-8, OQ-9, OQ-10

**Fix:** Restore each OQ's rationale paragraph from SPEC-003 v0.1
(/tmp/spec003-v0.1.md § 11). Verbatim or near-verbatim. The
operator needs the full context to decide each OQ without re-research.

Specifically:
  - OQ-4 (frame size): restore the non-streaming max_tokens bound
    analysis and the gobwas/ws note from v0.1 OQ-1.
  - OQ-5 (provider WS buffer): restore v0.1 OQ-2 rationale.
  - OQ-6 (tier visibility to buyers): restore v0.1 OQ-3 rationale.
  - OQ-8 (promotion persistence): restore v0.1 OQ-6 rationale.
  - OQ-9 (identity verification): restore v0.1 OQ-7 rationale.
  - OQ-10 (coord-side buffer): split v0.1 OQ-2 rationale appropriately.

#### M7. SPEC-001 OQ-3 is decidable and stale

**Location:** SPEC-001 v1.2 OQ-3

**Problem:** OQ-3 asks "How does the binary reach contributors?
Options: GitHub Releases, Homebrew tap, direct link." SPEC-003 v0.2
§ 4 (FR-C1/FR-C2) answers this: GitHub Releases + get.malibu.tech/
install.sh.

**Fix:** Close SPEC-001 v1.2.1 OQ-3 as "RESOLVED in SPEC-003 v0.2
FR-C1, FR-C2. Distribution channel is GitHub Releases via
https://get.malibu.tech/install.sh." Either remove from the open-
questions list or move to a "Resolved questions" appendix.

### MINOR — fix opportunistically

#### m1. SPEC-003 D8 cross-reference too narrow

**Location:** SPEC-003 v0.2 § 8

**Fix:** Change `D8 (drain conflation) -> SPEC-002 v1.1 FR-P14` to
`D8 (drain conflation) -> SPEC-002 v1.1 § 10 D8 + SPEC-001 v1.2 FR-30`.

#### m2. SPEC-001 hello text locally confusing on absent endpoint_url

**Location:** SPEC-001 v1.2 § 6.5

**Fix:** Replace the paragraph on absent/null endpoint_url with:
"When `endpoint_url` is absent or null in hello, this is the provider-
side signal for WS-tunneled mode. The coordinator's final mode
determination uses BOTH the hello field AND the static
config.providers[] map; see SPEC-002 v1.1 § 3 for the complete mode
resolution rule."

#### m3. SPEC-003 v0.2 misses 1200-1500 line target without note

**Location:** SPEC-003 v0.2 (whole doc)

**Fix:** Add a one-paragraph note near the top (§ 2 Scope or change-log):
"v0.2 final length (752 lines) is below the 1200-1500 target from the
redistribution prompt. Justification: Parts C (distribution) and D
(onboarding) are genuinely smaller than the WS protocol (Part A) and
admission tier (Part B) content that moved out to SPEC-001 v1.2 § 6.6
and SPEC-002 v1.1 § 3 / § 5 / § 7. The integration narrative in § 3
adds context without inflating to artificial length."

### Operator decision on Q1 (applied — see "Operator decision" above)

Apply the operator's answer to Q1 in SPEC-002 v1.1.1 § 3.

## Process

1. Read all source materials in the order listed above.

2. Outline your edits per spec in a scratchpad. Group by spec, not by
   finding severity, since you'll edit each file once.

3. Edit SPEC-001 v1.2 → v1.2.1:
   - Update version + change-log header
   - Apply C3 (partial — request_id semantics if you choose SPEC-001
     as the home; otherwise put in SPEC-002)
   - Apply M6 (restore OQ-4 + OQ-5 rationales)
   - Apply M7 (close OQ-3)
   - Apply m2 (clarify hello text)

4. Edit SPEC-002 v1.1 → v1.1.1:
   - Update version + change-log header
   - Apply C1 (refresh wire schemas in § 7.1)
   - Apply C2 (restore FR-A8 mapping table)
   - Apply C3 (the other half — coord-side request_id handling)
   - Apply M1 (quota in routing pseudocode)
   - Apply M2 (case-insensitive model_id comparison)
   - Apply M3 (split OQ-2 scope between SPEC-001/SPEC-002, clarify both)
   - Apply M5 (nak fallback paragraph + new AC)
   - Apply M6 (restore OQ-6, OQ-8, OQ-9, OQ-10 rationales)
   - Apply Q1 operator decision in § 3 mode resolution

5. Edit SPEC-003 v0.2 → v0.3:
   - Update version + change-log header
   - Apply C4 (restore AC-1 coordinator-connection-succeeds; split AC-1a if needed)
   - Apply M4 (fix SPEC-001 § 7.2 reference)
   - Apply M6 (update OQ-mapping note for M3 split)
   - Apply m1 (broaden D8 reference)
   - Apply m3 (add line-count justification note)

6. Cross-spec consistency self-review pass:
   - Every audit finding has been addressed
   - C1's schema update doesn't drift from SPEC-001 § 6.5
   - C2's mapping table doesn't conflict with SPEC-001 FR-27 status enum
   - C3's request_id rules are stated in exactly ONE spec (with a
     cross-reference from the other)
   - All cross-references resolve
   - Backward-compat invariant still holds (SPEC-001 statement
     verbatim, § 6.6 scope clause intact, SPEC-002 § 3 mode resolution
     unchanged for pinned providers)
   - Numeric thresholds unchanged unless an audit finding required it
   - No new normative content invented beyond audit fix directions
     and the operator's Q1 answer

7. Print a 400-word handback summary to stdout listing:
   - Version bumps applied
   - One-sentence summary per CRITICAL finding fix
   - One-sentence summary per MAJOR finding fix
   - Operator Q1 application location (SPEC-002 v1.1.1 § 3)
   - Confirmation: backward-compat invariant still holds
   - Any finding you couldn't fully resolve (these become next-round
     audit findings)

8. Do NOT commit. Operator reviews + commits all three files in one
   coordinated commit.

## What NOT to do

- Do NOT invent new design choices beyond the audit fix directions
  and the operator's Q1 answer.
- Do NOT remove design choices not flagged in the audit.
- Do NOT modify SPEC-001 v1.1.4 message types in ways that break
  v1.1.x binary wire compat. (You're only ADDING fields and clarifying
  scope.)
- Do NOT touch d-inference references.
- Do NOT skip the verbatim backward-compat statement preservation.
- Do NOT change the buyer-facing API surface.
- Do NOT commit. The operator commits.
- Do NOT delete OQs — restore rationales, close decidable ones (M7),
  keep open ones open.

When done, print the 400-word handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist:

1. Verify all 4 CRITICALs addressed (C1 schema refresh, C2 mapping
   table, C3 request_id semantics, C4 AC-1 restored).
2. Spot-check the SPEC-002 § 7.1 schemas now mirror SPEC-001 § 6.5
   exactly (run `diff` or visual compare).
3. Confirm Q1 operator answer is implemented in SPEC-002 § 3.
4. Confirm backward-compat statement still verbatim in SPEC-001 v1.2.1
   change-log (don't let the version bump break the verbatim text).
5. Confirm all 7 MAJORs + 3 MINORs addressed.
6. Verify OQ rationales restored (compare against v0.1 § 11).

Then commit as one coordinated commit covering all three files.
Suggested commit message:

```
SPEC-001 v1.2.1 + SPEC-002 v1.1.1 + SPEC-003 v0.3: audit-driven fixes

Resolves 4 CRITICAL + 7 MAJOR + 3 MINOR findings from the SPEC-003
redistribution audit (specs/SPEC-003-audit.md).

CRITICALs:
  C1  SPEC-002 § 7.1 wire schemas refreshed to mirror SPEC-001 v1.2
  C2  FR-A8 status-to-buyer-HTTP mapping restored in SPEC-002 FR-P14
  C3  Unknown/duplicate request_id semantics restored in SPEC-001 § 6.6
  C4  SPEC-003 AC-1 restored to require coordinator connection success

Operator Q1 answer applied: provisional providers (unknown provider_id)
operate exclusively in WS-tunneled mode; self-reported endpoint_url is
ignored.

[detailed MAJOR + MINOR summary...]

Backward-compat verified: v1.1.x binaries (M4, M1) remain MANDATORY-
compliant. Verbatim backward-compat statement preserved.
```

After commit, decide:
- If the fix introduced low-risk changes only → write `AUDIT_SPEC_003_V0_3_PROMPT.md`
  for a narrower second-round audit covering only the changed sections.
- If confidence is high after spot-check → skip second audit and
  proceed to build prompts (BUILD_SPEC_001_V1_2_PROMPT.md,
  BUILD_SPEC_002_V1_1_PROMPT.md, BUILD_SPEC_003_V0_3_PROMPT.md).

The audit pattern from SPEC-001/002 (3-4 rounds total) suggests one
more round here. The fix scope is narrow enough that round 2 will
likely close cleanly.
