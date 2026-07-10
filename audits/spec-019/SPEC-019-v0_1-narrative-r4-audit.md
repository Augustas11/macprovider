**Verdict:** READY TO LOCK
**Tally:** C/H/M/m/Q = 0/0/0/2/0

## Closure verified

For each r3 narrative-lane finding:

- **r3 F-1 (§6 dual-axis signpost cites AC-27 instead of AC-13):** CLOSED.
  Line 685-687 now reads: "Both `json_schema_max_depth` (schema-side, §6) and
  AC-13 (output-instance side) use the same constant 32 by design — a schema
  at depth 32 can match an instance at depth 32." The earlier signpost three
  lines above (line 683) continues to cite AC-13 correctly. No remaining AC-27
  reference in the §6 dual-axis context. `grep "AC-27\|AC-13" specs/SPEC-019-structured-output.md`
  confirms the only AC-27 hit in §6 vicinity is gone; AC-27 now only appears
  at its definition site (line 340, Coordinator validation parity). The
  three-line-apart self-contradiction r3 F-1 named is fully removed.

- **r3 minor 1 (§5 narrative order interleaves general/exception/general):**
  PARTIAL → ACCEPTABLE-AS-IS. v0.1.3 did not reorder §5 — the panic catch-all
  (lines 566-577) still sits between the normative-ordering block (lines 559-564)
  and the empty-content classification (lines 588-602), and the standard
  `malformed_json_response` / `json_schema_validation_failed` envelopes (lines
  611-623) still arrive after the empty-content override. r3 explicitly flagged
  this as minor, recommendation was "nice-to-have" reorder, and r3 absorption
  did not pick this up. Reading the v0.1.3 sequence end-to-end again, the
  interleaving is no longer as jarring as r3 read it — the panic catch-all is
  now followed immediately by the partial-validator-state rule (lines 579-586,
  added in r3), which thematically extends the catch-all. Then empty-content
  classification + override + retry semantics form a coherent three-block
  empty-content cluster. Then the standard envelopes land as table-row
  definitions. The flow now reads as: failure-mode wrapper (panic) → failure-
  mode wrapper extension (partial state) → specific subcase (empty content) →
  retry policy → reference definitions. That is defensible. Not blocking.

- **r3 minor 2 (§4 fixture requirements interrupt the normative-block flow):**
  NOT ADDRESSED. v0.1.3 did not edit §4. The two one-sentence Qwen3 / Llama-3.3
  fixture requirements that r3 flagged remain sandwiched between the
  stateless-renderer rule and the untrusted-prompt-data block. r3 recorded this
  as a minor and r3 absorption did not pick it up. Carrying forward as Finding 1.

## Fresh findings

### Finding 1: §10 deferred list — gzip item is verbose and self-referential

- Severity: minor
- Location: SPEC §10 (lines 854-857)
- Issue: §10's section header on line 846 reads "Deferred to v0.2:" — every
  bullet under it is implicitly "deferred to v0.2". The new gzip bullet
  (lines 854-857) reads "Transparent gateway-side decompression of
  `Content-Encoding: gzip` / `deflate` / `br` request bodies with a
  decompressed-byte cap is deferred to v0.2. v0.1.0 keeps the single
  uncompressed byte-domain invariant for caps and JCS;". The "is deferred to
  v0.2" phrase is redundant with the section header; the trailing "v0.1.0
  keeps..." sentence is a justification that doesn't fit the bullet's parallel
  shape with the other 5 v0.2 bullets (which are all noun phrases like
  "streaming structured output with partial-JSON-prefix validation per
  chunk"). The nested-Pydantic bullet (lines 861-863) has the same shape
  issue: "AC-30 uses a flat Pydantic model. Nested Pydantic models emit..."
  is a two-sentence explanation, not a noun-phrase deferred item. The numeric-
  bounds bullet (lines 858-860) does end with a `to v0.2 to enable...`
  justification but is structurally one sentence.
- Reader impact: a skim-reader looking at §10 to answer "what is deferred?"
  hits 5 tight noun phrases, then 3 multi-sentence prose paragraphs of
  unequal shape. The section reads as if r3 stapled three items on without
  matching the existing list-item discipline.
- Recommendation: normalize the 3 r3-added bullets to noun-phrase shape
  matching the original 5. E.g. "transparent gateway-side request-body
  decompression (`Content-Encoding: gzip` / `deflate` / `br`) with a
  decompressed-byte cap;", "`minimum` / `maximum` / `multipleOf` numeric-
  bound keywords and top-level `$schema` acceptance in §3;", "AC-30 nested-
  Pydantic fixture variant (currently requires `$ref` / `$defs` rejected in
  v0.1.0)." The justifications can live in a one-line note under the list
  or be dropped entirely (they are already explained in the v0.1.3 change-log
  entry). Not blocking.

### Finding 2: §4 Qwen3 / Llama-3.3 fixture requirements (carried from r3 minor 2)

- Severity: minor
- Location: SPEC §4 (lines around 522-526 in v0.1.2; line numbers will have
  shifted by ~+15 in v0.1.3 due to §5/§6/§10 additions — same blocks, same
  issue)
- Issue: see r3 narrative Finding 3 — two one-sentence fixture requirements
  break the normative-rule chain between stateless-renderer and untrusted-
  prompt-data. Recommendation unchanged: delete (AC-21 covers them more
  precisely) or move up to right after the system-position placement block.
  Not blocking.

## Verdict justification

The r3 narrative MEDIUM (dual-axis signpost AC-27 misreference) is fully
closed at line 685. The signpost block now reads coherently, the three-line-
apart self-contradiction is gone, and a reader hitting the dual-axis paragraph
no longer chases AC-27 into the wrong section. This is the one finding that
blocked lock at r3, and v0.1.3 absorbed it cleanly.

The two carried-forward minors (§5 narrative interleaving, §4 fixture
interruption) and the one fresh minor (§10 deferred-list bullet shape) do
not block lock. The §5 interleaving issue r3 flagged actually reads better
in v0.1.3 because r3's other absorptions (partial-validator-state rule, retry
semantics block) added thematic glue between the existing blocks.

Fresh probe results:

- **§10 deferred list (11 items: 6 v0.2, 5 v0.3) — coherent but bullet-shape
  inconsistent.** The 3 r3-added items are individually well-scoped (gzip
  decomp, numeric bounds + $schema, nested Pydantic) and they map cleanly to
  the v0.2 promise. There is no contradiction across the 3 new items — gzip
  decomp is independent of §3 numeric-bound widening which is independent of
  nested-Pydantic `$ref` support. The list is not yet bloated past coherence.
  The only narrative issue is bullet shape (Finding 1, minor).

- **992 lines — still navigable.** §2's 12-category AC structure holds. New
  v0.1.3 content (§5 partial-state rule, §5 retry semantics, §6 mixed
  worked example, §7 gzip 415 block, §10 three new deferrals) lands inside
  existing sections without spawning new headings. The Quick orientation
  (lines 7-17) still leads with two short paragraphs of plain English. The
  Current code state (lines 19-56) is dense with file:line anchors but
  thematically belongs there.

- **v0.1.3 change-log entry (lines 936-955) is coherent.** Uses only numeric
  anchors (§5, §6, §10, AC-13, AC-30, AC-31), not theme codes. Each absorbed
  finding is one sentence, attributed to the originating lane, with anchor.
  The bracketing "first READY TO LOCK at any round" credit to codex code lane
  reads as a meaningful operational signal, not noise. Pattern matches v0.1.1
  and v0.1.2 entries.

- **Quick orientation still leads with plain English.** Lines 9-17 give the
  buyer-visible outcome ("Buyers can send `response_format`... and receive
  assistant `content` that conforms to their schema, or a structured 502") and
  the v0.1.0 scope narrowing in three sentences. A reader can answer "what is
  this SPEC for?" without scrolling past the orientation block.

Bar for narrative lane: 0 C / 0 H / 0 M. Tally is 0 / 0 / 0 / 2 / 0. Verdict
is **READY TO LOCK**. The two minors flagged are nice-to-haves that should
ride along in a future narrative pass but do not gate v0.1.3 lock.
