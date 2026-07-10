**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/2/4/3/2

## Findings

### Finding 1: "Quick orientation" buries the lead under file:line citations
- Severity: HIGH
- Location: SPEC §Quick orientation (lines 7-50)
- Issue: The preamble is named "Quick orientation" but the first concrete prose paragraph (lines 9-13) is the only sentence that orients a new reader on what the slice does. From line 23 onward, the preamble pivots into dense file:line evidence of current code state ("Current code anchors at `98336d9`...", "Receipt binding needs no SPEC-015 schema change..."). That material belongs in a "Current state of the world" subsection or in §7, not in an orientation. By the time a senior reviewer at 11pm reaches §1, they have parsed roughly twelve `phase3-binary/Sources/...:NNN` citations without having been told the v0.1 boundary in plain English. The four-bullet narrow-slice list at lines 15-22 is buried mid-paragraph rather than promoted to the top.
- Recommendation: Reorder. Open with the one-paragraph contract summary (lines 9-13), then promote the narrow-slice bullet list (lines 15-22) directly under it, then add a one-line "v0.1 status quo summary" ("the field is parsed but never consulted; current code rejects `json_schema` with HTTP 400") in plain prose. Move the file:line evidence wall (lines 23-50) into a new subsection named "Current code state" or fold it into §7. The SPEC-018 precondition paragraph (lines 45-50) should also move out of orientation — it is a dependency declaration already covered in the header `Depends on:` line and in §12.

### Finding 2: AC ordering jumps between request-parse, money-path, and fixtures without grouping
- Severity: HIGH
- Location: SPEC §2 (lines 110-244)
- Issue: The 25 ACs are not in a logical reading order for an IMPL engineer reviewing PR-by-PR. AC-1 through AC-6 are request-validation (good). AC-7 is the `json_object` runtime contract (output-validation, not request-validation). AC-8 is output-validation. AC-9, AC-10 are terminal-error envelopes. AC-11 jumps back to request-validation (`stream:true` rejection). AC-12 is receipt binding. AC-13 is family-rendering fixtures. AC-14 is tools-interaction (semantic, not parse). AC-15, AC-16 are SDK forward-compat. AC-17 is back to cap-edge testing (belongs near AC-5). AC-18 is error envelope (belongs near AC-9 / AC-10). AC-19 is money-path (would be cleaner grouped with AC-9 / AC-10). AC-20, AC-21 are coordinator/gateway (covered in §7 already). AC-22 is request-validation again (belongs near AC-6). AC-23, AC-24, AC-25 are output-validation fixtures (belong near AC-8 / AC-10). A reviewer scrolling §2 cannot say "ok, I am now in the request-validation block" and skim — the categories are interleaved. The brief at lines 121-159 explicitly asked for request-parse → request-validation → schema-validation → output-validation → caps → money-path → forward-compat → fixtures.
- Recommendation: Resort §2 to the brief's grouping. Suggested order: AC-1 (parse) → AC-2, AC-3, AC-22, AC-6 (field-presence + strict req) → AC-4 (keyword subset) → AC-5, AC-17 (cap edges) → AC-11 (stream pre-flight) → AC-20, AC-21 (coordinator/gateway parity) → AC-7, AC-8 (output contract) → AC-9, AC-10, AC-24 (parse/validation failures) → AC-25 (depth fixture) → AC-23 (prompt-injection fixture) → AC-13 (family fixtures) → AC-14 (tools interaction) → AC-18 (error envelope) → AC-19 (money path) → AC-12 (receipt binding) → AC-15, AC-16 (SDK regressions). Renumber so the order is the reading order, not a history of how the AC list grew during drafting.

### Finding 3: AC-1 "Fail condition" reads as a contradiction
- Severity: MEDIUM
- Location: SPEC §2 AC-1 (lines 112-115)
- Issue: AC-1 says `json_schema` "is accepted by the provider request parser and represented in the parsed request. Fail condition: current HTTP 400 `invalid_request` path remains for `json_schema`". A reviewer reading top-to-bottom will mis-parse this twice: first as "AC-1 asserts the current 400 must remain", then as "AC-1 asserts the new behavior plus a fail-condition statement that the current 400 must NOT remain after IMPL". The convention "fail condition = state that means the AC has failed" is correct but not stated anywhere in the SPEC, and the phrasing reads like a contradiction. SPEC-018 v0.2.4 either uses different language or makes the convention explicit, and an audit-reading reviewer who hasn't internalized that convention will flag this as a hole.
- Recommendation: Add one sentence at the top of §2: "Each AC's 'Fail condition' states the observable state that would mean the AC is not satisfied — typically the pre-SPEC-019 baseline behavior that IMPL must replace." Or rewrite AC-1 as "PASS: parsed request contains `response_format.type:"json_schema"`. FAIL: HTTP 400 `invalid_request` returned (current behavior at `ChatCompletionRequest.swift:371-379`)." Apply the same pattern to AC-7 (lines 139-142) and AC-14 (lines 179-184), which use the same convention.

### Finding 4: §1 / §3 / §10 overlap on what "rejected keywords" means
- Severity: MEDIUM
- Location: SPEC §1 (lines 82-86), §3 (lines 267-274), §10 (lines 462-466)
- Issue: §1 says `strict:false` "MUST fail before inference with HTTP 400 `json_schema_non_strict_unsupported_in_v0_1`". §3 lists the rejected-keyword set but does not include the `strict:false` rejection, which is in §1 only. §10 ("Deferred to v0.3 or later") then lists "non-strict mode (`strict:false`) as observability without enforcement". A reader who lands on §3 to look up "which keywords get the 400" will not find `strict:false` there. A reader who lands on §10 to look up deferred features will see "non-strict mode" deferred to v0.3 but not see the v0.1 short-term rejection rule. The three sections need cross-references.
- Recommendation: In §3, add a sentence after the rejected-keyword list: "Note: `strict:false` is also rejected pre-inference per §1 with a dedicated error code `json_schema_non_strict_unsupported_in_v0_1`, not via `json_schema_unsupported_keyword`." In §10, when listing "non-strict mode (`strict:false`)", add a parenthetical: "(in v0.1.0, `strict:false` is rejected pre-inference per §1 and AC-22; v0.3+ may relax this to observability-only)."

### Finding 5: §1 tools interaction lacks symmetric wording for the empty-tools case
- Severity: MEDIUM
- Location: SPEC §1 tools-interaction paragraph (lines 101-108)
- Issue: "when both `tools` and `response_format.type == "json_schema"` are supplied, tool calls take precedence" plus "If the model does not emit a tool call, the assistant content MUST satisfy this SPEC" handles only the "tools present" case. It does not say what happens when `tools` is absent but `response_format:json_schema` is present — which is the most common case and the one a fresh reader is most likely to be searching for. The §5 numbered procedure (lines 327-336) covers it (step 1 is "if valid tool calls AND request tools are enabled"), but a reader looking at §1 alone will not know whether the "tool calls take precedence" rule even applies. The current text implicitly forks behavior on whether `tools` is in the request but never says so.
- Recommendation: In §1, before the "Tools interaction" paragraph, add: "When `tools` is not supplied in the request, the assistant content path always applies and `response_format` is enforced as defined in §5." Then keep the current tools-interaction paragraph for the both-supplied case.

### Finding 6: Cross-document citations are file:line-only without summarizing why
- Severity: MEDIUM
- Location: SPEC throughout — SPEC-015 at lines 38-43, 170-171, 454-457; SPEC-006 at lines 42-43; SPEC-018 at lines 45-50, 205, 244, 391
- Issue: SPEC-015 citations point at `specs/SPEC-015-receipts.md:1191-1204` without saying what that range contains. A reader who has never opened SPEC-015 cannot tell whether SPEC-019's receipt-binding claim relies on a normative rule (the canonical prompt object schema) or a non-normative example. SPEC-018 §10b at `specs/SPEC-018-agentic-tool-calling.md:671-675` is cited as the precondition release-gate without naming what §10b is called or what it says — a reviewer would need to open SPEC-018 to confirm SPEC-019 isn't misciting. SPEC-006 line range `1036-1047` is cited as "buyer API allow-list" but the allow-list's normative force is left implicit. The brief at lines 263-267 asked for "Match SPEC-018 v0.2.4's tone: terse, numbered AC list, file:line citations". Terse is good; cite-without-summarize is not. The user explicitly flagged this in the audit lens.
- Recommendation: For each cross-spec citation, add a half-line summary in parentheses. Examples: "(SPEC-015 §X canonical prompt object schema lists `response_format` as a required field at line 1191-1204)", "(SPEC-018 §10b 'Follow-on slices promoted after streaming-incremental stabilizes', lines 671-675)", "(SPEC-006 §X buyer-API request-field allow-list at lines 1036-1047)". A 11pm reviewer should be able to read SPEC-019 without opening four other SPECs to confirm the citations.

### Finding 7: AC-12 calls itself a "no-schema-change regression" without defining the term
- Severity: minor
- Location: SPEC §2 AC-12 (lines 167-171)
- Issue: "This is a no-schema-change regression against SPEC-015's `response_format` canonical prompt field" is dense. A reviewer who hasn't read SPEC-015 won't know if "no-schema-change" modifies "regression" (no SPEC-015 schema change required for SPEC-019) or modifies the test type (a regression test that asserts no schema change occurred). It's the former, but the wording inverts the modifier.
- Recommendation: Reword to "AC-12 asserts a receipt-binding regression test. Because SPEC-015's canonical prompt object already includes `response_format` (`specs/SPEC-015-receipts.md:1191-1204`), no SPEC-015 schema change is required; only a regression-test is needed to prove `prompt_hash` changes when `response_format.json_schema.schema` changes byte."

### Finding 8: §6 caps section repeats the SPEC-018 inheritance twice
- Severity: minor
- Location: SPEC §6 (lines 371-390)
- Issue: The `2_097_152` response cap inheritance is correctly stated and cited at lines 381-387. The depth cap of 32 is then stated at line 389-390 with its own SPEC-018 citation, which uses the same `SPEC-018 §10d.7` family of citations and the same file:line reference (`ToolCallParser.swift:4-6`). A reader sees the same citation twice in 10 lines, which suggests sloppy editing. The §11 audit hooks and AC-25 also reference the same range, for a third repetition.
- Recommendation: Consolidate. State both inheritances in one sentence: "SPEC-019 inherits two SPEC-018 §10d.7 constants without redefinition: `SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP = 2_097_152` for response content size, and decoded JSON depth `<= 32` for output validation. Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-6`; `specs/SPEC-018-agentic-tool-calling.md:963-975`."

### Finding 9: "Quick orientation" claims v0.1 is "narrow" but does not state the v0.1 vs v0.2 boundary in one place
- Severity: minor
- Location: SPEC §Quick orientation lines 15-22; §1 lines 94-99; §10 lines 462-475
- Issue: A reader looking for "what is in v0.1 and what is not" must read three places: the bullet list at §Quick orientation lines 15-22 (positive scope), the streaming-rejection paragraph at §1 lines 94-99 (negative scope), and §10 (negative scope, future versions). They don't conflict but they don't reconcile either. There is no "scope table" or one-place summary.
- Recommendation: Optional but high-leverage. Add a small "Scope summary" subsection or table between §Quick orientation and §1: two columns ("in v0.1.0" / "deferred"), rows for streaming, schema subset, json_object enforcement, family rendering, money-path, retry policy, SDK matrix.

### Finding 10: Open Question — should §11 list rejected design alternatives, not just audit-probes?
- Severity: Q
- Location: SPEC §11 (lines 477-506)
- Issue: §11 is titled "Open questions / audit hooks". Some entries (#3 `json_object` top-level rule, #4 `strict:false` rejection, #5 scalar root schemas) are not audit-hooks in the adversarial sense — they are open design questions the SPEC has tentatively resolved one way and invites the audit to re-litigate. Mixing those with adversarial probes (#1 canonicalization edges, #2 prompt-injection) blurs the audit's job. A reviewer cannot tell which entries are "find a CVE here" versus "tell me if my call was wrong".
- Recommendation: Consider splitting §11 into §11a "Open design questions" (#3, #4, #5) and §11b "Audit-adversarial probes" (#1, #2, #6, #7, #8, #9, #10). Not blocking — flagging as a question because §11 currently works but the split would help a 11pm reviewer triage faster.

### Finding 11: Open Question — should the doc enumerate the rejected-keyword count?
- Severity: Q
- Location: SPEC §3 (lines 267-274)
- Issue: The rejected-keyword list at lines 267-274 contains ~30 keywords. A reviewer cross-referencing against OpenAI's strict-mode docs to confirm coverage will count manually. A one-line "Rejection covers 30 keywords across polymorphism, refs, numeric/length/array constraints, conditionals, metadata, and unknown" would help quick verification.
- Recommendation: Optional. Adding a sentinel count and a category summary would help, but the current list is exhaustive and grep-able. Flag only as a Q for the user to decide.

### Finding 12: Typo / formatting — §1 list item 3 schema example is split awkwardly
- Severity: minor
- Location: SPEC §1 list items 1-3 (lines 57-86)
- Issue: The three-value enumeration at lines 57-62 lists items "1. omitted", "2. json_object", "3. json_schema", then the SPEC immediately drops into a code block for `json_schema` shape, then list-item-style prose continues at lines 82-99. Visually the section reads like the list ended at item 3 but the prose treats the json_schema block as still under item 3. The numbered list and the prose paragraphs about `json_schema.name`, `json_schema.description`, `json_schema.strict`, `json_schema.schema` should be either explicit sub-bullets under item 3 or promoted to their own subsection §1.1.
- Recommendation: Promote to §1.1 "json_schema field requirements" subsection or use explicit sub-bullets. Cosmetic but improves readability for a tired reviewer.
