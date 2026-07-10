# SPEC-018 v0.1.2 — Product narrative blind-spot pass

## Counts
CRITICAL: 0
HIGH: 0
MEDIUM: 0
MINOR: 5
QUESTIONS: 2

## Three readers — quote-grounded assessment

### READER 1 — Cline power user
Correctly concludes "wait for v0.2." §1.1 item 1 is unambiguous: "A real agent session running Cline / Cursor / Aider against macprovider will succeed on turn 1 and fail on turn 2." The title's "Agentic tool calling" briefly raises expectation, but §1's "first-turn OpenAI tool-call wire-shape compatibility certificate" lands the scope reset within the first paragraph. The §1 phrase "three normative deltas vs the as-built that the v0.1.2 IMPL prompt will patch" is author-process jargon a buyer doesn't need to parse, but they can skip past it to the plain-English §1.1 five-item limitation list without forming a wrong impression.

### READER 2 — Startup CTO
Concludes "real platform, not research project — but on a known roadmap, not production-ready for client-side agents today." The honest scope ("first-turn ... certificate"), the explicit §10c additive-only forward-compatibility invariant with AC-23 regression gate, the SPEC-008/011 model_hash infrastructure cited at file:line precision, and the seven §10a items naming exactly what v0.2 must deliver all signal "real platform." Two friction points: (1) `Status: Draft` on line 5 reads as research-project-y for a SPEC that ratifies code already serving production traffic — the CTO has to read into §1 to learn the SPEC describes shipped behavior, and (2) the change-log entry for v0.1.2 (line 9, ~30 lines of "Arch M-1 / Code M-1 / Sec m-2"-flavored prose) tells them nothing about product evolution, only audit hygiene; they scan it, get nothing, and move on. v0.2 has no committed date — defensible while v0.1 is the locking version but a real planning concern.

### READER 3 — v0.2 SPEC author
Mostly clear inheritance. The seven §10a items are explicit, the §10c additive invariant pins forward compatibility, AC-23 names the regression gate, and §10a #2 model-hash registry surfaces three design dimensions (registry location, curation model, fail-closed semantics). One small surprise: §10a #2 contains a normative "v0.2 MUST require unknown-or-unregistered model_hash to fail closed" — a binding constraint inside a "v0.2 deliverable" enumeration is structurally unusual and a v0.2 author may wonder whether the MUST is pre-locked or still open for v0.2 SPEC negotiation. Nothing else feels overspecified or underspecified.

## Findings

### m-1 — Change-log entry for v0.1.2 is audit-process prose, not product evolution
- Reader / narrative-coherence category: READER 2 | NARR-5
- SPEC location: Line 9 (change-log entry for v0.1.2); same pattern in line 10 v0.1.1 entry
- What the SPEC says: A ~600-word paragraph beginning "Round-2 returned 0 CRITICAL + 0 HIGH across all 4 lanes; product-design + security both READY TO LOCK; architect + code returned 5 MEDIUMs that v0.1.2 absorbs." The body enumerates "Arch M-1," "Code M-1," "Sec m-1," "PD Q-1," etc. — naming finding IDs from the audit lanes rather than what changed for the consumer of the SPEC.
- What the reader concludes / where comprehension breaks: A startup CTO (Reader 2) and a Cline user (Reader 1) both naturally scan the change log first to orient on "what's v0.1.2 vs v0.1.1?" The entry tells them the audit ratings improved and precision fixes landed; it does not tell them what v0.1.2 means for a buyer: e.g., "v0.1.2 expands the Qwen detection to cover Qwen3, removes a stray SDK-validation obligation, and commits to never breaking the v0.1.2 wire shape in future versions." Audit-process flavor is high signal for the SPEC author and zero signal for the consumer.
- Recommended fix: Add 2–4 buyer-facing bullets at the top of the v0.1.2 entry summarizing the product-visible deltas (Qwen3 detection, additive-only forward compatibility commitment via §10c + AC-23, three IMPL deltas vs the as-built). Keep the existing dense audit-trail prose below those bullets so it remains a record for SPEC continuity. Same treatment for v0.1.1.

### m-2 — "Draft" status alongside ratification of production code
- Reader / narrative-coherence category: READER 2 | NARR-6
- SPEC location: Line 5 (`**Status:** Draft`)
- What the SPEC says: Status field reads "Draft," but §1 ratifies behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`, `OutputCanonicalizer.swift`, `ModelRuntime.swift`, `HTTPServer.swift`, `InferenceRelay.swift`, and coordinator + gateway pass-through code already running production traffic.
- What the reader concludes / where comprehension breaks: A CTO scanning the front matter reads "Draft" as a research-project signal. They have to read into §1 to discover the SPEC ratifies shipped code with three pending IMPL deltas. If the SPEC project uses a defined status vocabulary (e.g. "Locked vN.M" elsewhere), "Draft" without further qualification underestimates how stable v0.1.2 actually is.
- Recommended fix: Either add a parenthetical to the Status line ("Draft — ratifies as-built behavior; v0.1.2 IMPL prompt patches three §1-enumerated normative deltas") or use whatever the SPEC repo's interim term is between "audited and locked but pending IMPL absorption" and "Approved."

### m-3 — §3.2 rationale assumes reader knows why model_hash beats modelID
- Reader / narrative-coherence category: NARR-3 | READER 2
- SPEC location: §3.2 line 132 ("v0.2 closes the residual case — a tool-call-capable model echoing hostile content — via the §10a model-hash → family registry binding and the prompt-echo guard.")
- What the SPEC says: §3.2 names the residual prompt-echo case and says v0.2 closes it via model-hash. §1.1 #4 names "cryptographic binding to the loaded model hash." Neither section explains in one sentence why model_hash is qualitatively stronger than modelID — that the provider freely chooses the modelID string they advertise, whereas model_hash is computed over the loaded weights and verified by SPEC-008.
- What the reader concludes / where comprehension breaks: A CTO unfamiliar with SPEC-008/011 reads "model_hash" as "a different identifier" rather than "an identifier the provider cannot lie about." The §10a #2 buyer-facing sentence ("prevents a provider from advertising a tool-call-capable model family while running a different model or grammar") lands the point, but only readers who chain §1.1 → §3 → §10a get it. A reader who stops at §3.2 misses the "why."
- Recommended fix: Add one parenthetical to §3.2 rationale, e.g. "(modelID is a self-declared string; model_hash is verified by SPEC-008 Pillar A against the loaded weights, so a malicious provider cannot advertise a tool-capable family while serving different weights)."

### m-4 — "family-family priority" typo
- Reader / narrative-coherence category: NARR-6
- SPEC location: §3 line 117 ("Any detector, sentinel, modelID match, grammar path, or family-family priority not represented in §3 is non-compliant until a SPEC-018 version bump.")
- What the SPEC says: "family-family priority" — appears to be a stray word duplication. §3.6 uses "Multi-family priority and mixed sentinels."
- What the reader concludes / where comprehension breaks: Mild — a careful reader notices the doubled word and pauses. Doesn't change comprehension but trips eye-flow inside a normative invariant sentence.
- Recommended fix: Change "family-family priority" to "multi-family priority" (matching §3.6 heading) or "family priority."

### m-5 — §1 mixes product framing with IMPL-prompt scaffolding
- Reader / narrative-coherence category: READER 1 | NARR-6
- SPEC location: §1 lines 32–40
- What the SPEC says: §1 opens with the certificate framing and Ring 2/3 out-of-scope, but lines 32–40 then enumerate "three normative deltas vs the as-built that the v0.1.2 IMPL prompt will patch" and instruct the IMPL prompt to add AC-20 documentation locations to specific code paths. Both are SPEC-author-internal concepts mixed into a buyer-facing scope section.
- What the reader concludes / where comprehension breaks: A Cline power user reading §1 cold sees author-process exposition (file paths and IMPL-prompt instructions) inside the section that should answer "what does this product do?" They CAN skip it and reach §1.1, but it adds drag.
- Recommended fix: Move the as-built-vs-normative IMPL-delta enumeration and the AC-20 documentation-locations paragraph into a new §1.2 "v0.1.2 IMPL prompt scope" subsection. Keep §1's body to product framing, buyer-side obligation, and Ring 2/3 out-of-scope. Leaves §1 readable to consumers; §1.2 stays explicit for SPEC continuity.

## Questions

### Q-1 — Is the v0.2 unknown-hash fail-closed MUST intentionally locked in v0.1.2?
- Reader: READER 3
- SPEC location: §10a #2 line 371
- Observation: A normative MUST that binds the v0.2 SPEC, placed inside a "v0.2 deliverable" enumeration in v0.1.2, is structurally unusual. The v0.2 author inherits a constraint they did not write. This is defensible (security-driven, audit reasoning was strong, the constraint is small) but reads as "v0.1.2 forecloses one v0.2 design decision." Worth confirming intentional. If yes, consider naming it as a "v0.1.2-locked v0.2 invariant" or moving it into §10c so the v0.2 author understands it is not negotiable.

### Q-2 — Should §10a or §11 carry a v0.2 target window?
- Reader: READER 2
- SPEC location: §10a (no date), §11 (no date)
- Observation: §10a names exactly what v0.2 must deliver but no when. A startup CTO evaluating "integrate at v0.1 first-turn-only now, switch to v0.2 multi-turn later" wants a calendar or version-dependency anchor (e.g., "v0.2 targeted post-SPEC-011 v0.6 amendment per Q5"). Absent that, integration planning is open-ended.

## Verdict
READY TO LOCK
