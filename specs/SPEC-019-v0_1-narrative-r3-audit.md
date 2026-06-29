**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/2/0

## Closure verified

For each r2 finding from the narrative lane:

- **r2 F-1 (§12 change-log uses appendix codes §A.1/§B.1/... with no anchor):**
  CLOSED. §12 v0.1.1 entry (lines 886-900) and v0.1.2 entry (lines 902-918)
  now use only numeric section anchors (§1, §2, §3, §4, §5, §6, §7, §9, plus
  AC-numbers). No `§A.1`/`§B.1`/`§C.1`/etc. remain in the body. A reader
  doing PR archaeology can navigate from each change-log bullet to the
  section it describes.

  Residual nit (not raised as a separate finding because it is a
  citation-accuracy quibble within the closed F-1 fix, not the structural
  issue F-1 named): the v0.1.1 entry says "`json_schema.name` rule added
  (§3 + §2 AC-33)", but the `json_schema.name` AC in v0.1.2 is AC-8a (line
  182), not AC-33 (which is the prompt-injection fixture). This is because
  v0.1.1's pre-r2 draft had no dedicated name AC and the closest hook was
  AC-33's prompt-injection coverage (which does include `json_schema.name`
  as a hostile-string source). For an external reviewer doing version-to-
  version diff archaeology, the AC-33 anchor is still navigable and the
  cross-section it lands in does discuss `json_schema.name`. Note here for
  the record; not gating.

- **r2 minor 1 (Schema-shape parity category misnomer):** CLOSED. Renamed
  to `Schema-shape & key-comparison` (§2, line 191). The category still
  contains only AC-9, but the broader header now correctly hosts a
  byte-comparison rule (which is what AC-9 asserts). Could fold into
  Output validation in a later pass, but no longer a misnomer.

- **r2 minor 2 (§6 dual depth-cap signpost):** PARTIAL → REGRESSED.
  §6 added the dual-axis signpost as recommended (lines 656-657 and
  lines 659-661), but introduced a NEW citation bug: line 659-660 reads
  "Both `json_schema_max_depth` (schema-side, §6) and **AC-27**
  (output-instance side) use the same constant 32 by design". AC-27 is
  the coordinator validation parity AC (line 340), not the output-depth
  cap. The correct anchors are AC-12 (schema-side fixture, line 219) and
  AC-13 (output-side fixture, line 222). Line 657 cites AC-13 correctly
  three lines above, which makes the contradictory AC-27 citation jarring
  for a reader who scrolls between them. See Fresh Finding 1.

## Fresh findings

### Finding 1: §6 dual-axis signpost cites the wrong AC for the output-side depth cap

- Severity: MEDIUM
- Location: SPEC §6 (line 659-661)
- Issue: The new dual-axis signpost (added in v0.1.2 to close r2 narrative
  minor 2) reads: "Both `json_schema_max_depth` (schema-side, §6) and AC-27
  (output-instance side) use the same constant 32 by design — a schema at
  depth 32 can match an instance at depth 32." AC-27 (line 340) is
  *Coordinator validation parity*, which asserts coordinator-level
  enforcement of the 16_384-byte and 32-depth schema caps before dispatch.
  It is not the output-instance depth cap. The output-instance depth cap
  is AC-13 (line 222: "validation rejects output whose decoded JSON depth
  exceeds 32 with HTTP 502 `json_schema_validation_failed`"). The
  three-line-earlier sentence (lines 656-657) correctly cites AC-13:
  "Same constant as the output-validation depth cap in AC-13, by design."
  So the SPEC contradicts itself within four consecutive lines about
  which AC governs the output-instance depth cap. A first-time reader
  hitting line 659 may chase AC-27, find it is about coordinator parity
  (not output-instance), and conclude either (a) AC-27 also governs
  output-instance depth (false), or (b) the signpost block describes a
  three-axis cap (schema-side, coordinator-side, output-instance-side)
  rather than the intended two-axis. Either reading is wrong. This is
  the exact failure mode r2 minor 2 was raised against — reader conflates
  caps — and the v0.1.2 fix introduced a new variant of the same problem.
- Recommendation: change line 659-661 to "Both `json_schema_max_depth`
  (schema-side, §6, AC-12) and the output-instance JSON-depth cap (AC-13)
  use the same constant 32 by design — a schema at depth 32 can match
  an instance at depth 32." Drop the AC-27 reference here entirely;
  AC-27 belongs to the coordinator/gateway parity discussion in §2 and
  §7, not to the dual-axis depth signpost.

### Finding 2: §5 narrative order interleaves general/exception/general for empty-content and panic catch-all

- Severity: minor
- Location: SPEC §5 (lines 533-600)
- Issue: §5 now contains, in order:
  1. Numbered switch on `response_format.type` (lines 540-548)
  2. Normative ordering for receipt/sticky/billing (lines 550-555)
  3. Validator panic / fatal-error catch-all (lines 557-568)
  4. Empty content under `json_schema` / `json_object` — basic
     classification (lines 570-575)
  5. Empty-content subcase override — `retryable:false` (lines 577-584)
  6. Standard `malformed_json_response` envelope (lines 586-590)
  7. Standard `json_schema_validation_failed` envelope (lines 592-598)
  8. No internal retry (line 600)

  Two narrative-flow issues:
  - The empty-content basic classification (block 4) introduces
    `malformed_json_response`, then the override block (block 5)
    modifies its `retryable` flag, then the standard envelope for
    `malformed_json_response` (block 6) appears AFTER the modification.
    A reader meeting `malformed_json_response` first at block 4 has no
    canonical envelope to anchor on; the canonical envelope arrives two
    blocks later. The natural order is "standard rule" → "exception"
    or at minimum colocate them.
  - The validator panic catch-all (block 3) is a meta-rule that wraps
    ALL post-inference failure modes (parse, validation, empty content).
    Placed between the receipt-ordering block and the empty-content
    blocks, it interrupts the "after inference, here is what each
    failure mode looks like" flow. A reader expecting block 3 to be the
    next failure mode meets a wrapper instead, then has to mentally
    push the wrapper down before reading blocks 4-7.
- Recommendation: reorder to (1) → (2) → (6) `malformed_json_response`
  standard → (7) `json_schema_validation_failed` standard → (4) empty
  content classification → (5) empty-content override → (3) validator
  panic catch-all wrapper → (8) no internal retry. Or, less invasive:
  move the panic catch-all (block 3) to immediately before the SPEC-019
  error-codes table (line 602), so it sits as a meta-rule between the
  specific envelopes and the table summary. The current order works for
  a reader who reads top-to-bottom in one pass, but does not survive
  the more common skim-and-search reading pattern.

### Finding 3: §4 fixture requirements interrupt the normative-block flow

- Severity: minor
- Location: SPEC §4 (lines 468-531)
- Issue: §4 order is:
  1. Intro paragraph (470-472)
  2. Family-key mechanism + render hook sites (474-483)
  3. System-position placement + injection contents (485-495)
  4. Composite render rule (497-516) — main normative block
  5. Stateless renderer (518-520) — normative
  6. Qwen3 fixture requirement (522-523)
  7. Llama-3.3 fixture requirement (525-526)
  8. Untrusted prompt data block (528-531) — normative

  Blocks 6 and 7 are AC-21-style fixture requirements (one sentence each)
  sandwiched between the stateless-renderer normative rule and the
  untrusted-prompt-data normative rule. They feel orphaned: AC-21 (line
  278) already requires these fixtures more rigorously, and §4's
  one-sentence requirements add no normative force. A reader scanning
  §4 for normative rules hits two soft requirements that turn out to
  be redundant with AC-21.
- Recommendation: either delete blocks 6 and 7 (AC-21 covers them more
  precisely), or move both up to right after block 3 (system-position
  placement) where they belong as illustrative consequences of the
  injection rule. Currently they break the normative-rule chain.

## Verdict justification

The narrative reshape from v0.1.1 to v0.1.2 successfully closes r2 F-1
(the SPEC body no longer uses theme-code anchors) and r2 minor 1 (the
Schema-shape category is renamed). But r2 minor 2 (dual depth-cap
signpost) regressed: the new signpost block cites AC-27 for the
output-instance side of the dual-axis, when the correct AC is AC-13 —
and the SPEC cites AC-13 correctly three lines above, so the body
contradicts itself within four consecutive lines about which AC governs
output-instance depth. This is exactly the failure mode the r2 fix was
trying to prevent (reader conflates caps), in a new variant.

That regression is a MEDIUM and blocks lock. The two minors (§5
narrative order and §4 fixture-requirement interruption) are
nice-to-haves; they do not block but should ride along if a quick
narrative pass goes in for the MEDIUM.

921 lines remains navigable. The §2 12-category AC structure holds.
All r2-added ACs (AC-8a, AC-22a, AC-22b, AC-28a) land cleanly inside
their categories. The new §5 normative blocks (receipt ordering, panic
catch-all, empty-content override) are individually coherent, but their
intra-section order is non-obvious for a skim-reader (Finding 2). §4
normative blocks are individually coherent, but the two fixture
requirements at lines 522-526 interrupt the flow (Finding 3).

Bar for narrative lane: 0 C / 0 H / 0 M. Tally is 0 / 0 / 1, so verdict
is FIX REQUIRED. One MEDIUM blocks; two minors flagged for the same
pass.
