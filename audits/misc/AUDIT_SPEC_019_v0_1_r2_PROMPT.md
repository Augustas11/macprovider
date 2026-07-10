# SPEC-019 v0.1.1 round-2 defensive audit — TIGHT

Audit `specs/SPEC-019-structured-output.md` v0.1.1 at commit `ffce39d` on
branch `spec/019-structured-output` (worktree
`/Users/augstar/macprovider-spec-019`).

**This is a DEFENSIVE audit.** v0.1.0 → v0.1.1 absorbed 3 CRITICAL + 14 HIGH
+ 14 MEDIUM findings (see `specs/SPEC-019-v0_1-r1-audit.md` for narrative and
the per-lane r1 files for granular findings).

Two distinct tasks:

1. **Closure verification.** For your lane's r1 findings, confirm each is
   closed in v0.1.1, partially closed, or regressed. Cite the SPEC §
   that closes it.
2. **Regression probing.** The r1 reshape was extensive (+264 lines, +9
   ACs, 12 new categories, 4 new error codes, restructured §0/§2).
   Look for blind spots the reshape INTRODUCED — new ambiguity in
   the new normative blocks, contradiction between old AC text and the
   regrouped AC numbering, new §5 error-codes table inconsistencies, etc.

Bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM** across all 6 lanes = READY TO LOCK
the SPEC body and open the SPEC-019 PR. If r2 returns 0/0/0 across the
board, no r3 is required (SPEC-018 v0.2 went r3→r4 because new MEDIUMs
appeared; the same defensive gate applies here).

## What changed in `ffce39d` (only this commit's delta)

Key diff areas (cite line numbers from v0.1.1 in your audit):

- §0 Quick orientation rewritten as plain-English lead; file:line evidence
  moved to new §1 Current code state subsection.
- §1 (Buyer-visible contract) gains: SPEC-001 cross-spec amendment note;
  `json_object` breaking-change label; (other in-line additions).
- §2 (ACs) regrouped into 12 categories. New ACs from r1 themes B/C/D/E/G.
  AC count: 25 → 34.
- §3 (Grammar) gains: strict-mode `required` ⊇ `properties` rule; const/enum
  type-conformance rule; NFC/NFD byte-comparison rule; `json_schema.name`
  untrusted-data rule.
- §4 (Family rendering) gains: composite tool×schema render-order rule
  (step-by-step ModelRuntime hook sequence); stateless-renderer rule.
- §5 (Validator) gains: receipt-after-validation ordering normative
  block; empty-content classification; new §5 error-codes table.
- §6 (Caps) gains: schema-depth cap = 32; response-cap pre-parse fail-closed
  rewording (reuses SPEC-018 `response_byte_cap_exceeded`).
- §7 (Coordinator/gateway) gains: SPEC-006 amendment for detail-on-wire
  allow-list (`malformed_json_response`, `json_schema_validation_failed`).
- §8 (Money path) AC-26 strengthened with order-of-operations rules.
- §9 (Forward-compat) gains: receipt canonical scope for `response_format`
  defaulted fields documented.
- §10 (Deferred) gains: explicit "v0.1.0 NOT a Cline drop-in target" note.
- §12 (Metadata) version bumped to 0.1.1; change-log entry added.
- §I.1: Quick orientation lead is plain English (was file:line wall).
- §I.2: AC ordering grouped into 12 categories.
- §I.3: minor wording / "Fail condition" preamble / cross-spec citation
  summaries.

## Authoritative inputs

1. `specs/SPEC-019-structured-output.md` v0.1.1 — the absorbed draft.
2. `specs/SPEC-019-v0_1-r1-audit.md` — the r1 aggregate (read this to
   know what findings to verify).
3. `specs/SPEC-019-v0_1-{architect,code,security,product-design,critic,
   narrative}-r1-audit.md` — your r1 findings.
4. `specs/SPEC-019-v0_1-r1-FIX-PROMPT.md` — the absorption directive
   codex executed.
5. SPEC-001, SPEC-006, SPEC-015, SPEC-018 v0.2.4 LOCKED.
6. Current code state at `ffce39d`.

## Per-lane lens

You are ONE of these lanes. Stay in your lens.

### Architect

**Closure check**: confirm closure of architect r1 findings:
- C-1 (SPEC-001 supersession): does §1 cross-spec amendment text actually
  supersede the SPEC-001 row, or just claim to? Read the cited SPEC-001
  line and verify the supersession is clean.
- C-2 (SPEC-006 normalization): does §7 amendment actually authorize
  gateway pass-through for `malformed_json_response` +
  `json_schema_validation_failed`? Does it cite the SPEC-006 line it amends?
- H-1 (tool×schema composite render): does §4's composite render rule
  resolve the original ambiguity, OR does it introduce a new ambiguity
  about which order is correct (system-position injection BEFORE or AFTER
  ToolPromptRenderer.renderMessages)?

**Regression probe**:
- Does the new §1 cross-spec amendment text contradict anything in
  SPEC-006's response_format treatment?
- Does the new §7 SPEC-006 amendment authorize buyer-visible 502 codes
  that SPEC-006 elsewhere prohibits at the gateway boundary?
- Does the new §5 error-codes table list every code used in §2 ACs?
  Any code in an AC that's missing from the table is an inconsistency.
- Does the v0.1.0 → v0.1.1 metadata bump break receipt regression
  hashing? (Receipts don't see the SPEC version, but verify.)

### Code

**Closure check**: confirm closure of code r1 findings:
- H-1 (AC-15/AC-16 fixture artifacts): are the new fixture paths
  concrete (`test/integration/spec_019/openai_python_strict_json_schema/`,
  `test/integration/spec_019/vercel_ai_sdk_strict_json_schema/`)? Does the
  SPEC say what's in them (request body, schema, expected pydantic model,
  test file name)?
- M-1 (RFC 6901 root pointer `""`): every JSON-pointer reference in §5,
  AC-9/AC-10, error-codes table — is `""` the root, or does `"/"` still
  appear?
- M-2 (hook-site call sequence): is §4 unambiguous about when schema
  instruction is injected vs when `ToolPromptRenderer.renderMessages`
  runs? Grep `ModelRuntime.swift` at the hook-site line numbers and
  verify the SPEC's prescribed sequence is implementable as written.

**Regression probe**:
- Grep every `file:line` and `file:line-line` citation in v0.1.1. New
  citations may have been added (especially in the rewritten §0/§1/§5).
  Every citation must resolve to current `ffce39d` lines AND match the
  SPEC's claim about what's there. Flag any drift.
- §3 grammar: with 4 NEW rules added (strict-required-parity,
  const/enum type-conformance, NFC/NFD byte-comparison, name-untrusted),
  is the rule order still logical? Is any rule ambiguous about
  enforcement timing (request-parse vs pre-inference vs validation)?
- §5 new error-codes table: every code appears in at least one AC?
  Every AC code appears in the table? Any code listed in the table
  with a 5xx HTTP status but used in an AC with 4xx (or vice versa)?
- AC renumbering (25 → 34) may have left dangling references. Grep for
  `AC-N` references inside SPEC body and verify they point to the
  current AC numbers, not the old ones.

### Security

**Closure check**: confirm closure of security r1 findings:
- H-1 (schema depth/complexity cap): is `json_schema_max_depth = 32`
  in §6? Does AC explicitly cover schema-side depth (not just output)?
- H-2 (validator-exception → money-path leak): does AC-26's "validator
  exceptions, resource-limit aborts, and recursion overflow MUST be
  converted to terminal 502 with SPEC-019 code" close the leak path?
- M-1 (prompt-injection AC-23 omits `json_schema.name`): does §3 name
  rule + AC-23 amendment cover hostile names?

**Regression probe**:
- New `json_schema.name` ASCII-only regex constraint — does it bound
  name length AND character set strictly enough? What about Unicode
  characters in `name` — accepted or rejected?
- Schema-depth cap = 32 applies at parser AND coordinator. Does the SPEC
  enforce this at BOTH layers explicitly? §6 says "at provider and
  coordinator"; §7 must echo that.
- Receipt-after-validation ordering: can a validator exception bypass
  the ordering rule by panicking the request handler entirely? Is there
  a normative "all panics are terminal 502 FaultBreakerQualifying"
  catch-all, or could a bug land an empty 500 response with
  inconsistent settlement state?
- NFC/NFD byte-comparison rule: an attacker who controls both schema
  and model output could craft NFD/NFC pairs that confuse human
  reviewers. Does AC-N for the NFC/NFD fixture include a security
  scenario (not just a parity test)?
- `json_schema_invalid_name` code: is character-set enforcement
  identical at provider parser AND coordinator (parity)? If only at
  parser, a hostile request bypasses via direct coordinator path.

### Product-design

**Closure check**: confirm closure of PD r1 findings:
- H-1 (Vercel AC tests right path): is AC-16 explicit about
  `supportsStructuredOutputs:true`? Is AC-16b (default path) explicit
  about `json_object`?
- H-2 (`json_object` breaking change labeled): does §1 say "Breaking
  change for `json_object` buyers"? Does §10 require migration note
  in release notes?
- H-3 (versioned error codes dropped): zero `_in_v0_1` remnants?
- M-1 (Cline v0.1 boundary): does §10 explicitly state v0.1.0 is NOT
  a Cline structured-output drop-in?
- M-2 (streaming-reject envelope): is AC-11 explicit about
  `type:"invalid_request_error"`, `param:"stream"`, `retryable:false`?
- Q-1 (`strict:false` opt-out posture): documented either way?

**Regression probe**:
- `json_schema.name` 64-char ASCII regex: is this restrictive enough
  for openai-python and Vercel AI SDK to send-by-default-pass? Both
  SDKs generate machine names — check that their default name format
  fits within the regex. If openai-python uses `My Custom Schema`
  (with space) or unicode characters, the constraint breaks
  drop-in compatibility.
- New error codes (`json_schema_strict_requires_all_properties_required`
  etc.) — are these names too long for log-grep parity? Buyer SDKs
  often display `error.code` to humans; long underscored names are UX
  friction.
- §1 breaking-change note for `json_object`: does it actually quantify
  how to migrate? "Use omitted or `{"type":"text"}` for prose fallback"
  is the recipe but is it visible to a buyer reading the release note?
- §3 const/enum type-conformance rule + new code
  `json_schema_invalid_const_or_enum_type`: does it cover the case
  where `const: null` and `type: ["null","string"]` (multi-type)? §3
  may or may not allow `type` as an array.
- AC-15 fixture: `Person { name: str, age: int }` strict-mode — is this
  schema fixture genuinely Vercel/openai-python compatible, or does
  one SDK serialize it differently than the other (e.g., openai-python
  uses pydantic, Vercel uses Zod → JSON schema). Verify the chosen
  fixture shape produces byte-equivalent `response_format` JSON across
  both SDKs.

### Critic (Claude blind-spot)

**Closure check**: confirm closure of your r1 findings:
- C-1 (strict-mode `required` parity): is §3's new rule unambiguous
  that EVERY key in `properties` must appear in `required`?
- H-2 (receipt-vs-validation ordering): does AC-26 normatively
  require ordering, or just describe it?
- H-3 (empty-content classification): does §5 cover the empty string?
- H-4 (schema-depth cap): present?
- H-5 (response-cap pre-parse): does §6 wording now say "before JSON
  parsing or schema validation runs"?
- H-6 (stateless renderer): present in §4?
- M-1 (defaulted-`strict` idempotency): documented in §9?
- M-2 (const/enum type code): present in §3?
- M-3 (NFC/NFD byte-comparison): present in §3?

**Fresh blind-spot probe** — look for what r1 critic and the codex lanes
likely overlooked AFTER the reshape:

- New §5 error-codes table: is there a code in the table that has no AC
  asserting it? (A code without an AC is dead weight.)
- Composite render rule §4: the prescribed sequence
  (1) schema-adjusted ChatMessage → (2) ToolPromptRenderer.renderMessages
  → (3) UserInput with unchanged tools — but ToolPromptRenderer in
  practice (SPEC-018 v0.2) MUTATES messages. Does the v0.1.1 sequence
  hold if ToolPromptRenderer rewrites the system message that contains
  the schema instruction?
- `json_schema_invalid_name` 64-char ASCII: does openai-python's
  pydantic-derived schema name include namespacing dots (e.g.,
  `MyApp.User`)? If so, ASCII regex `[A-Za-z0-9_]+` rejects valid
  openai-python output. Check.
- Empty-content `""` classification as `malformed_json_response`: this
  is `retryable:true`. Combined with a deterministic model that emits
  empty content for a given schema, buyers loop forever burning their
  retry budget. Is this acceptable, or should there be a
  separate `empty_completion` code with `retryable:false`?
- Receipt canonical scope §9 (defaulted-`strict` excluded): is this
  consistent with how `temperature`, `top_p`, `max_tokens` (other
  defaultable fields) are canonicalized? Either v0.1.1's choice is the
  current convention, or it's a new asymmetry.
- Schema-depth cap = 32 + AC requirement: the SPEC says "same constant
  as output validation". What about the case where the SCHEMA is depth
  32 but a valid object satisfying it must be depth 33 (e.g., one
  level for arrays)? Could a valid schema have no valid instance
  under the output depth cap?

### Narrative (Claude blind-spot)

**Closure check**: confirm closure of narrative r1 findings:
- H-1 (Quick orientation buries lead): does the new §0 lead with plain
  English in the first 4-5 lines? File:line citations only in §1
  Current code state subsection?
- H-2 (AC ordering categories): are the 12 categories present in §2?
  Are ACs in logical order within each category?
- M-1 (Fail condition convention): is there a §2 preamble explaining
  the "Fail condition" convention?
- M-2 (cross-spec citation summaries): does each `file:line` to
  SPEC-001/006/015/018 include a half-line summary of what's there?
- M-3 (`§3` reject-list count): does §3 state the count of rejected
  keywords?
- M-4 (§6 SPEC-018 citation deduplication): is the inheritance citation
  not repeated 3x?
- minor and Q items: noted.

**Fresh narrative probe**:
- Does the SPEC body still read coherently at 788 lines? Is there
  signposting between §2 (ACs) and §3-§9 (deep normative)?
- 12 categories in §2 — are categories internally consistent or do
  ACs cross-reference across categories in confusing ways?
- Is the §5 error-codes table self-contained or does the reader need
  to bounce between §3 and §5 to understand what each code means?
- Change-log entry in §12 — does it tell the v0.1.0 → v0.1.1 story
  coherently?

## Output format

Write findings to `specs/SPEC-019-v0_1-{lane}-r2-audit.md` where `{lane}` is
your lane name verbatim: `architect`, `code`, `security`, `product-design`,
`critic`, `narrative`.

```
**Verdict:** {READY TO LOCK | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closure verified

For each r1 finding from your lane, list status:
- r1 C-1: CLOSED (cite §) | PARTIAL (cite §, residual issue) | REGRESSED (cite §)
- r1 H-1: ...

## Fresh findings

### Finding 1: <title>
- Severity: {CRITICAL | HIGH | MEDIUM | minor | Q}
- Location: SPEC §X (line N) or code file:line
- Issue: one paragraph
- Recommendation: what to change

## Verdict justification
```

If 0/0/0 across closure and fresh findings, write "READY TO LOCK" and
verdict that the SPEC body is ready for PR.

Bar: 0/0/0 across all 6 = READY TO LOCK → SPEC-019 PR opens.
