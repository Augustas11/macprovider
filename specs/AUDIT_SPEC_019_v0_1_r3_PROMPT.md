# SPEC-019 v0.1.2 round-3 defensive audit — TIGHT

Audit `specs/SPEC-019-structured-output.md` v0.1.2 at commit `65d56f8`
on branch `spec/019-structured-output` (worktree
`/Users/augstar/macprovider-spec-019`).

**Defensive round** after r2 absorbed 6 HIGH + 9 MEDIUM + 3 minor across
12 themed blocks. r1 absorbed 3 CRITICAL + 14 HIGH + 14 MEDIUM
beforehand.

Two distinct tasks:

1. **Closure verification.** For your lane's r2 findings (in
   `specs/SPEC-019-v0_1-{lane}-r2-audit.md`), confirm each is closed
   in v0.1.2, partially closed, or regressed. Cite the v0.1.2 §
   that closes it.
2. **Regression probing.** r2 added 11 new normative blocks across
   §3/§4/§5/§6/§7. Look for blind spots the additions INTRODUCED — new
   ambiguity in `Composite render rule`, name-regex anchor semantics,
   empty-content override interactions, panic catch-all wording,
   counting-algorithm edge cases, gzip preservation wording.

Bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM** across all 6 lanes = READY TO LOCK
the SPEC body and open the SPEC-019 PR.

## What changed in `65d56f8` (only this commit's delta)

12 themed blocks per `specs/SPEC-019-v0_1-r2-FIX-PROMPT.md`:

- A. §4 composite render rule unified to ONE normative order
  (schema-adjusted ChatMessage → ToolPromptRenderer.renderMessages →
  UserInput; renderer no-op-short-circuit when no multi-turn).
- B. §3 `json_schema.name` rule made mandatory + anchored regex
  `^[A-Za-z0-9_-]{1,64}$` (was `[A-Za-z0-9_]+`, rejecting `person-v1`);
  AC added asserting rejection at provider + coordinator with
  adversarial fixtures.
- C. §5 empty-content `retryable:false` override (deterministic empty
  output no longer invites retry loops).
- D. §5 validator panic / fatal-error catch-all normative block (every
  postprocess failure path → terminal 502 with FaultBreakerQualifying).
- E. AC-30/AC-31 rewritten as paired `Person` fixture across
  openai-python Pydantic and Vercel Zod with canonical-schema parity
  + explicit allow-list for `title`/`description`.
- F. §6 schema-depth counting algorithm specified.
- G. AC-9 NFC/NFD adversarial security extension.
- H. §7 gzip body-byte preservation (forward Content-Encoding
  without decompression at gateway).
- I. §7 gateway double-settlement prevention for `malformed_json_response`
  and `json_schema_validation_failed`.
- J. §7 stale gateway citations corrected.
- K. §12 v0.1.1 + v0.1.2 change-log entries reference §1-§12 anchors,
  not §A.1/§B.1/etc theme codes.
- L. r2 narrative file `specs/SPEC-019-v0_1-r2-audit.md` written.

## Authoritative inputs

1. `specs/SPEC-019-structured-output.md` v0.1.2 (the absorbed draft).
2. `specs/SPEC-019-v0_1-r2-audit.md` (r2 aggregate).
3. `specs/SPEC-019-v0_1-{lane}-r2-audit.md` (your r2 findings).
4. `specs/SPEC-019-v0_1-r2-FIX-PROMPT.md` (absorption directive
   codex executed).
5. SPEC-001, SPEC-006, SPEC-015, SPEC-018 v0.2.4 LOCKED.
6. Current code state at `65d56f8`.

## Per-lane lens

You are ONE of these lanes. Stay in your lens.

### Architect

**Closure check**: confirm closure of architect r2 H-1 (composite render
order ambiguity). Does §4 now have exactly ONE normative order? Does
the prose match the numbered hook sequence? Read the entire composite-
render block top-to-bottom and confirm there is no remaining
contradictory wording.

**Regression probe**:
- The new "renderer no-op short-circuit when no multi-turn tool data"
  nuance: is the architectural implication clear? When tools are absent
  entirely (not just multi-turn-empty), does the same composite rule
  apply, or is there an implicit branch?
- §7 new gzip-preservation block: does it conflict with SPEC-006's
  gateway request-body handling? Cite SPEC-006 if it normatively
  decompresses bodies before validation.
- §7 new double-settlement prevention block: does it conflict with
  SPEC-018 §10d.7 settlement semantics for terminal 502s? Was SPEC-018
  silent on whether the gateway re-settles or just forwards?
- Cross-spec: does v0.1.2's new "validator panic catch-all" §5 block
  contradict SPEC-001's request-handler error-mode (which presumably
  has its own 500-on-panic semantics)?

### Code

**Closure check**: grep-verify the cited gateway lines in §7 are now
correct (code F-3 minor). The r2 fix replaced
`chat_proxy.go:997-1008` and `:601-607`. Confirm v0.1.2's citations
resolve to plausibly-named helpers in the current `chat_proxy.go`.

**Regression probe**:
- New `^[A-Za-z0-9_-]{1,64}$` regex: is the wording precise about
  "byte count" vs "character count" for non-ASCII? §3 says "1-64
  bytes". But ASCII bytes are 1-byte each, so the constraint conflates
  byte and char count for the ASCII subset. State explicitly.
- `json_schema_invalid_name` AC says "MUST be accepted: `person-v1`".
  Grep for the AC's actual position and verify it's in the right §2
  category (Request validation).
- §5 empty-content override block: does it cite the stop-token-filter
  function (`ModelRuntime.swift:811-828`) correctly? Re-grep.
- New §5 validator-panic catch-all block — is the fallback code
  mapping (`malformed_json_response` for parse internals,
  `json_schema_validation_failed` for validator internals)
  implementable? In Swift, a thrown error from `JSONSerialization` vs
  from a JSON-schema validator may not be cleanly distinguishable at
  the catch boundary. Does the SPEC require the implementation to
  classify, or is the IMPL allowed to use a single fallback code?
- §6 schema-depth counting algorithm: is the algorithm computable in
  O(schema bytes)? Walk it through `{"type":"object","properties":
  {"a":{"items":{"properties":{...}}}}}` — does the SPEC say items
  child of properties increments depth twice (once for properties.a,
  once for items), or once?

### Security

**Closure check**:
- security F-1 (panic catch-all): does §5 block cover thrown errors AND
  panics AND recursion overflow AND resource aborts? Re-read top-to-
  bottom.
- security F-2 (name regex anchoring): is `^...$` literally in the
  rule? Does AC assert non-anchored bypass (e.g. "good_name\n<script>")
  is rejected?
- security F-3 (NFC/NFD adversarial fixture): does AC-9 now name the
  adversarial case explicitly, or just append "adversarial extension"
  without spelling out the abuse?

**Regression probe**:
- New `json_schema_invalid_name` provider+coordinator parity: if
  provider's name regex differs from coordinator's by even one char,
  there's a bypass. Does §7 explicitly require *identical* anchored
  regex at both layers?
- gzip body-byte preservation §7: a hostile buyer sending `Content-
  Encoding: gzip` with a 14 KiB raw schema that decompresses to 100 MiB
  — does the §7 block address decompression bombs at the coordinator?
  Or is it left to the coordinator's existing request-body cap?
- Double-settlement prevention §7: malicious provider could try to
  emit `malformed_json_response` repeatedly to abuse the no-settle
  behavior. Is this safe because settlement is provider-side, not
  gateway-side? Trace.
- Validator panic catch-all: in the §5 block, does the language allow
  a partially-completed validator (e.g. validated 5/10 fields then
  panicked) to emit `json_schema_validation_failed` with a
  partially-truthful "offending JSON pointer"? Or must partial
  results be discarded?
- Schema depth-counting + 16 KiB byte cap interaction: can an attacker
  craft a 14 KiB schema with depth 32 that contains 10,000+ nested
  `additionalProperties` schemas at depth 31 (sibling sprawl, not
  vertical depth)? Schema-node count is NOT capped by depth. Is this
  a CPU DoS at the validator?

### Product-design

**Closure check**:
- PD F-1 (name regex): is the rule explicit about the OpenAI charset
  with hyphen? Does the AC accept `person-v1`?
- PD F-2 (SDK parity paired fixture): does AC-30 use `Person` AND
  AC-31 use the same `Person` translated to Zod? Does the canonical-
  schema-bytes comparison have a clear allow-list?
- PD F-3 (empty-content `retryable:false`): does §5 override block
  state the actionable message verbatim, or just gesture at it?

**Regression probe**:
- Empty-content `retryable:false` override: a non-deterministic model
  that emits empty content 50% of the time is now NOT retryable per
  v0.1.2. Is this the right call? Buyers who could legitimately retry
  with a different temperature seed will be blocked. State the
  rationale in §5 or note in §11 (open questions).
- AC-30/AC-31 paired `Person` schema: does Pydantic's strict-mode
  rewrite (adds `additionalProperties:false` + `required:["name","age"]`)
  match Vercel's Zod-emitted schema byte-for-byte? Test in your head:
  Pydantic emits `{type:object, properties:{...}, required:[...],
  additionalProperties:false, $defs:{}}`; Vercel emits
  `{type:object, properties:{...}, required:[...], additionalProperties:
  false}` (no $defs). Even with `title/description` allow-list, the
  $defs key may be a parity hole.
- §4 composite render no-op short-circuit: when tools array is empty
  AND multi-turn flag is false, what's the user-facing behavior? Does
  Cline use empty `tools:[]` even when not in tool-use mode? If so,
  the short-circuit short-cuts itself away from the documented
  composite order — is that correct or surprising?

### Critic (Claude blind-spot)

**Closure check**: confirm closure of your r2 findings:
- F-1 (`json_schema_invalid_name` no AC): is there an AC asserting
  the code now?
- F-2 (regex needs hyphen): present?
- F-3 (gzip body-byte preservation): present in §7?
- F-4 (composite render ToolPromptRenderer short-circuit nuance):
  documented in §4?
- F-5 (depth counting ambiguity): algorithm spec present in §6?
- F-6 (gateway settleBeforeResponse): block present in §7?
- F-7 (name-length unit): clarified?

**Fresh blind-spot probe** — what might r2 have introduced:

- §4 composite render rule says "renderer is no-op short-circuit when
  `containsMultiTurnToolData == false`". What if `tools:[]` is sent
  but no `messages` contain tool-call history — is multi-turn data
  "false"? Tools schema is itself buyer-controlled; ignoring tools
  array in the rendering decision could be a security boundary issue.
- §5 panic catch-all says "thrown errors, runtime panics or fatal
  assertions, recursion / stack-overflow, resource-limit aborts" —
  what about `OutOfMemoryError` causing the coordinator process to
  abort entirely? Is the receipt-write transaction marked-aborted at
  the database layer, or could it be partially committed?
- §5 empty-content override: the actionable message reads "Model
  emitted zero tokens... modify the prompt, increase `max_tokens`, or
  relax the schema". But `max_tokens` is not normally what causes
  empty output (max_tokens=0 would be an explicit zero-token request).
  More likely: temperature, top_p, seed. Is the advice text correct?
- §7 gzip block: it says "gateway MUST forward inbound request body
  bytes... without decompressing any Content-Encoding (gzip, deflate,
  br)". But the v0.1.1 SPEC-006-amendment block said gateway parses
  enough to enforce quotas. If gateway can't decompress, how does
  it parse the body to enforce quotas? Cite SPEC-006 if request-body
  parsing happens after decompression.
- AC-30/AC-31 paired fixture: openai-python's Pydantic-derived
  schema emits property descriptions and class-level title. Vercel's
  Zod-derived schema does not emit either. The "allow-list for
  `title`/`description`" handles those. But what about Pydantic's
  `$defs` for nested classes? Vercel inlines nested schemas. This is
  a real parity hole.
- Schema depth counting algorithm: a schema like `{"type":"array",
  "items":{"type":"array","items":{"type":"object","properties":{...}}}}`
  — is "items" inside "items" depth 1 step, or depth 2 steps? The §6
  algorithm says "items subtree" increments by 1. So array-of-array-of-
  object is depth 3 (root array → items array → items object). Sanity-
  check this is what an implementer would naturally compute.

### Narrative (Claude blind-spot)

**Closure check**:
- narrative r2 F-1 (§12 theme-code anchors): are §A.1/§B.1/etc gone?
- narrative r2 minor 1 (Schema-shape category name): renamed?
- narrative r2 minor 2 (§6 dual depth-cap signpost): added?

**Fresh narrative probe**:
- 921 lines (up from 788). Is the SPEC still navigable, or has it
  developed sprawl? Look for repetition or contradiction between r2
  additions and existing v0.1.1 body.
- §5 now has receipt-ordering + empty-content override + validator
  panic catch-all + standard validator behavior in one section. Is
  the order coherent? Does the reader hit a "wait, weren't we
  talking about X already" moment?
- §4 composite render rule + family rendering hook sites + stateless
  renderer rule — does the §4 narrative still flow, or has it become
  a list of normative-block stanzas without connective tissue?
- New ACs added in r2 — are they grouped under existing §2 categories
  or did they slip outside? Is the category structure still coherent?

## Output format

Write findings to `specs/SPEC-019-v0_1-{lane}-r3-audit.md` where `{lane}` is
your lane name verbatim: `architect`, `code`, `security`, `product-design`,
`critic`, `narrative`.

```
**Verdict:** {READY TO LOCK | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closure verified

For each r2 finding from your lane, list status:
- r2 F-1: CLOSED (cite §) | PARTIAL (cite §, residual issue) | REGRESSED (cite §)
- r2 F-2: ...

## Fresh findings

### Finding 1: <title>
- Severity: {CRITICAL | HIGH | MEDIUM | minor | Q}
- Location: SPEC §X (line N) or code file:line
- Issue: one paragraph
- Recommendation: what to change

## Verdict justification
```

If 0/0/0, write "READY TO LOCK" with `0/0/0/0/0` and verdict that the
SPEC body is ready for PR.

Bar: 0/0/0 across all 6 = READY TO LOCK → SPEC-019 PR opens.
