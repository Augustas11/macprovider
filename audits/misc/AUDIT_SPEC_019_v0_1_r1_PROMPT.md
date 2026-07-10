# SPEC-019 v0.1.0 round-1 audit — TIGHT

Audit `specs/SPEC-019-structured-output.md` v0.1.0 at commit `1aa1d74` on
branch `spec/019-structured-output` (worktree `/Users/augstar/macprovider-spec-019`).

This is the first audit round of a freshly-drafted SPEC. Bar:
**0 CRITICAL + 0 HIGH + 0 MEDIUM** before the SPEC PR opens. Findings get
absorbed and another round fires.

## What you are auditing

A narrow product slice that lets buyers send OpenAI-style
`response_format: {"type":"json_schema", ...}` and get back a JSON
assistant-content string conforming to their schema. Bundled with a
`json_object` enforcement fix (currently a silent no-op).

Verbatim constraints the drafter operated under (from the BUILD prompt):

- Non-streaming only in v0.1.0; streaming deferred.
- Post-hoc parse + validate after inference (no constrained decoding —
  MLX-Swift has no logits-processor / grammar API).
- OpenAI strict-mode subset; reject `oneOf`/`anyOf`/`$ref`/etc.
- Fail-fast on validation failure (no internal retry).
- Schema-size cap 16 KiB UTF-8.
- Response cap reused from SPEC-018 §9 (2 MiB).
- Money-path = `FaultBreakerQualifying` on validation failure.
- Receipts: no SPEC-015 schema change — `PromptCanonicalizer.swift:16`
  already canonicalizes `response_format`.

## Authoritative inputs

1. `specs/SPEC-019-structured-output.md` — the draft.
2. `specs/BUILD_SPEC_019_v0_1_PROMPT.md` — the drafter's constraints.
3. `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED — the prior
   product surface; SPEC-019 cites §10b as precondition and reuses its
   envelope discipline (§10d.4, §10c).
4. `specs/SPEC-015-receipts.md` §1191-1204 — canonical-prompt schema
   (`response_format` already field-listed).
5. `specs/SPEC-006-buyer-api.md` line 1044 — `response_format` allow-listed
   at gateway boundary.
6. Current code state on this branch:
   - `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
     (ResponseFormat enum, parser, current `json_schema` reject)
   - `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift` (parser
     analog)
   - `phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift`
     (family-keyed prompt rendering — to be mimicked)
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (render
     hook sites + filter pipeline)
   - `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift`
     (JCS canonicalization)
   - `phase4-coordinator/internal/buyer/server.go` (allow-list at 3608-3615)
   - `phase4-coordinator/internal/buyer/billing_recorder.go` (money-path)
   - `phase4-coordinator/internal/billing/formula.go` (money-path)
   - `phase5-gateway/internal/router/chat_proxy.go` (pass-through)

## Per-lane lens

You are ONE of these lanes. Stay in your lens.

### Architect

- Cross-spec consistency: does SPEC-019 v0.1.0 contradict SPEC-001,
  SPEC-006, SPEC-015, or SPEC-018 v0.2.4? Cite §s on both sides for any
  finding.
- Scope boundary: does the slice stay narrow? Are there parts that should
  be deferred but slipped into v0.1.0?
- Forward-compatibility invariants (§9): adequate? Anything future
  versions will silently break?
- Tools × json_schema interaction (§1 + AC-14): is the precedence
  decision crisp enough for the IMPL phase? Will a Cline conversation
  with both `tools` and `response_format: json_schema` work
  deterministically?
- Receipt binding: AC-12's "no schema change to SPEC-015" claim — does it
  hold? Verify `response_format` is in the SPEC-015 canonical-prompt
  field list at the cited line.
- HTTP code choices (AC-9/AC-10 HTTP 502 for post-inference parse /
  validation failure): consistent with SPEC-018 v0.1.5's
  `malformed_tool_call_final_json` posture?

### Code

- Citations: every `file:line` and `file:line-line` in the SPEC body must
  resolve to real lines that match the SPEC's description. Grep for
  every citation in the worktree and confirm.
- Subset grammar (§3): is it implementable as written? Are the
  reject-list semantics unambiguous? Pick a half-dozen edge cases
  (nested `enum` of mixed types, array `items` schema, empty `required`,
  `const: null`) and trace whether the SPEC tells the implementer
  what to do.
- Validator behavior (§5): is the JSON-pointer extraction well-specified
  (RFC 6901)? What if the model emits valid JSON that matches the schema
  but contains non-UTF-8 bytes — is that covered? What if `required`
  lists a key not in `properties`?
- Family rendering (§4): is the render hook site call sequence
  prescribed? The IMPL needs to know exactly where to inject the schema
  instruction in `ModelRuntime.swift`.
- Caps (§6): cite-only or also normative? Reusing SPEC-018 §9 2 MiB
  response cap — does the SPEC say so unambiguously, or could an
  implementer plausibly read it as a separate constant?
- AC numbering: every AC has a clear pass/fail condition and a citation
  to the file being tested. Flag ACs that are too vague to test.
- Error envelope (AC-18): keys `error.inference_ran` and
  `error.settlement_ran` — are these existing SPEC-018 v0.2 envelope
  keys, or did the SPEC-019 drafter invent them? If invented, that is a
  cross-spec mismatch.

### Security

- Prompt-injection surface (AC-23): adequate? The schema body, the
  property `description`s, enum / const values, and `name` itself are
  all attacker-controlled if the buyer is hostile. Hostile schema MUST
  NOT be able to escape the schema-instruction block in the rendered
  chat template.
- Schema-size cap (16 KiB, AC-5, AC-17): is the cap enforced at parser
  AND coordinator? Are both layers cited? Could a slow JSON-validator be
  weaponized for compute DoS (algorithmic complexity) under valid-but-
  pathological 16 KiB schemas?
- Deep-nesting cap (AC-25, depth 32): reuse-from-SPEC-018 is correct
  posture, but does the SPEC enforce depth at BOTH schema parse and
  output validation?
- Duplicate-key fail-closed (AC-24): is the choice motivated? Will
  permissive parsers (e.g. JS `JSON.parse`) actually hit this code
  path, or is fail-closed silently relaxed by parser choice?
- Money-path: is `FaultBreakerQualifying` settlement protection
  guaranteed BEFORE the validator runs, so a validator panic / OOM
  cannot leak provider-positive credits? Trace the failure modes.
- Strict:false rejection (AC-22): defensible? Or is silent-treat-as-strict
  a foot-shot that should be reconsidered?
- Tool x schema: can a malicious model collude with a malicious buyer to
  emit something that looks like a valid tool call to bypass schema
  validation? (Tools precedence is a security knob, not just UX.)

### Product-design

- Cline drop-in claim: SPEC-018 v0.2 was justified by Cline drop-in
  narrative. SPEC-019 v0.1.0 is narrower (no streaming). Does Cline
  actually use `response_format: json_schema`? If so, will Cline use
  it with `stream:true`, and would AC-11's rejection break the use
  case?
- Strict-mode-only: does any real-world buyer SDK send `strict:false`
  by default? `openai-python` defaults — check. Vercel AI SDK defaults
  — check. If the default path of either SDK is `strict:false`,
  AC-22's hard reject is a foot-shot.
- json_object existing-buyer regression: any buyer sending
  `response_format: {"type":"json_object"}` today is getting unconstrained
  text. After AC-7 enforcement, those same buyers will get HTTP 502 on
  malformed JSON. Is that a documented breaking change?
- Streaming reject (AC-11): defensible v0.1.0 scope or a UX regression
  that will be the #1 buyer complaint?
- Error code names: are `streaming_json_schema_unsupported_in_v0_1` /
  `streaming_json_object_unsupported_in_v0_1` good buyer-facing
  identifiers, or do they bake a version into the wire surface that
  later versions will inherit awkwardly?
- 25 ACs total — any redundant or any obvious gap?

## Output format

Write findings to `specs/SPEC-019-v0_1-{lane}-r1-audit.md` where `{lane}` is
your lane name verbatim: `architect`, `code`, `security`, `product-design`.

```
**Verdict:** {READY TO LOCK | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Findings

### Finding 1: <title>
- Severity: {CRITICAL | HIGH | MEDIUM | minor}
- Location: SPEC §X (line N) and/or codebase file:line
- Issue: {one paragraph}
- Recommendation: {what to change}

### Finding 2: ...
```

If 0/0/0, write "No findings." under the Findings header.

Severity scale:

- CRITICAL: SPEC contradicts another spec, breaks money-path posture,
  introduces a forward-compat invariant that future versions cannot
  honor, or specifies behavior that has no implementable mapping in the
  current codebase.
- HIGH: SPEC ACs are not testable / ambiguous, citations don't resolve,
  scope drift past the resolved-decision list, or a buyer-visible foot
  shot.
- MEDIUM: wording ambiguity, missing AC for a real edge case, weak
  motivation for a defensible call.
- minor: typos, formatting.
- Q: question for the drafter, not a defect.

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM across all lanes = READY TO LOCK
the SPEC body and open the SPEC-019 PR.
