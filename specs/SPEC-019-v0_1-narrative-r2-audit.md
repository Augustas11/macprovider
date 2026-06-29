**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/2/0

## Closure verified

For each r1 finding from the narrative lane:

- **r1 H-1 (Quick orientation buries lead under file:line citations)**: CLOSED.
  New §0 "Quick orientation" (lines 7-17) leads with a plain-English contract
  paragraph (lines 9-13) followed by the v0.1 narrow-slice summary (lines 15-17).
  All file:line evidence has been moved to the new §1.0-equivalent "Current code
  state" subsection (lines 19-56). The first 11 lines of the body are now
  prose-only, with the first file:line citation appearing at line 22 inside the
  dedicated "Current code state" section. Lead is no longer buried.

- **r1 H-2 (AC ordering interleaved categories)**: CLOSED. §2 now contains
  exactly 12 category headers (lines 142-366): Request parsing (AC-1..4),
  Request validation (AC-5..8), Schema-shape parity (AC-9), Caps (AC-10..13),
  Output validation (AC-14..19), Streaming reject (AC-20), Family rendering
  (AC-21..23), Tool × schema interaction (AC-24), Money path & receipt
  ordering (AC-25..26), Coordinator / gateway parity (AC-27..28), Buyer-facing
  UX (AC-29), Forward-compat regression fixtures (AC-30..34). Within each
  category, ACs are in logical reading order (e.g. Request validation walks
  unsupported-keyword → strict-required-additional-properties-false → strict-
  required-all-properties-required → invalid-const-or-enum-type, which mirrors
  natural rule application).

- **r1 M-1 (Fail condition convention)**: CLOSED. §2 opens with a preamble
  (lines 138-140): "Every AC includes a 'Fail condition' when an existing
  behavior could falsely appear to satisfy the new contract. The fail condition
  names the old behavior that must be proven absent." Convention is now stated
  before its first use in AC-1.

- **r1 M-2 (cross-spec citations lack summaries)**: CLOSED. SPEC-001 citation
  at lines 65-67 includes "which defines the prior `response_format` object
  default, allowed values, hint behavior, and unknown value rejection."
  SPEC-015 citation at lines 43-44 includes "canonical prompt JSON object
  fields." SPEC-006 citation at lines 47-49 includes "allowed chat-completions
  request fields." SPEC-018 citation at lines 53-56 includes "release note and
  implementation commit anchors" and "follow-on surface list." All four primary
  cross-spec references now carry a half-line summary.

- **r1 M-3 (§3 reject-list count)**: CLOSED. §3 line 388 states "Rejected
  keywords in v0.1.0: count = 33." Reader does not need to count manually.

- **r1 M-4 (§6 SPEC-018 citation deduplication)**: CLOSED. §6 cites SPEC-018
  §10d.7 once for the response cap (lines 582-583) and once for the depth
  constant location in ToolCallParser.swift (lines 593-594). Two distinct
  references for two distinct constants, not a triplicated repetition.

- **r1 minor / Q items**: Largely absorbed (AC-12 reworded into AC-25 with
  cleaner antecedent; §1 list items 1-3 now followed by an explicit JSON
  shape block before prose). Not blocking.

## Fresh findings

### Finding 1: Change-log labels (§A.1, §B.1, §C.1, ...) point at appendix codes that do not exist in the SPEC body

- Severity: MEDIUM
- Location: SPEC §12 change-log (lines 774-786)
- Issue: The v0.1.1 change-log entry cites theme IDs §A.1, §A.2, §B.1, §C.1,
  §C.2, §D.1, §E.1, §E.2, §F, §G.1, §I.1, §I.2. None of those labels exist in
  the SPEC body, which is organized as numeric §1 through §12. A reader who
  follows the change log to find "Composite tool×schema render order (§E.1)"
  has no anchor to navigate to. These appear to be FIX-PROMPT theme codes from
  the r1 absorption directive, not SPEC sections. The change log is the
  primary version-to-version navigation aid for an external reviewer doing
  diff archaeology; opaque section codes defeat that role.
- Recommendation: Rewrite each parenthetical citation to use the numeric
  section the change actually landed in. Example: "Cross-spec amendments to
  SPEC-001 (§1) and SPEC-006 (§7). New strict-mode parity rule (§3) and new
  error codes (§5). Schema-depth cap added (§6). Money-path receipt-ordering
  normative (§5, AC-26). Empty-content classification (§5). Composite
  tool×schema render order (§4). Stateless renderer required (§4). Concrete
  AC-15/AC-16 fixtures (§2 Forward-compat regression fixtures, AC-30..31).
  Versioned error-code suffixes dropped (§9). Quick orientation + AC
  categories restructured (§0, §2)." A reader can then navigate.

### Finding 2: §2 category "Schema-shape parity" is a misnomer for what AC-9 actually asserts

- Severity: minor
- Location: SPEC §2 (lines 182-188)
- Issue: The category "Schema-shape parity" sits between "Request validation"
  and "Caps" and contains exactly one AC, AC-9, which asserts that NFC vs NFD
  property-name byte sequences are distinct keys under `additionalProperties:
  false`. That is a UTF-8 byte-comparison policy for output validation against
  schema, not a "shape parity" rule. A reader scanning §2 category headers for
  "where do I look up Unicode normalization handling" would not navigate to
  "Schema-shape parity"; they would expect that header to host shape-of-request
  vs shape-of-runtime parity rules. The current header also makes the
  single-AC category look orphaned.
- Recommendation: Rename to "Property-name byte comparison" or fold AC-9 into
  "Output validation" (since it's a validation-time rule), then drop the
  one-AC category. Either fixes the misnomer.

### Finding 3: §6 contains both schema-depth cap and output-depth cap with same constant; the dual-axis is not signposted

- Severity: minor
- Location: SPEC §6 (lines 576-580 and 592-594)
- Issue: Lines 576-580 define `json_schema_max_depth = 32` as the SCHEMA
  nesting cap at parse time. Lines 592-594 then state "Decoded output JSON
  depth is capped at `32`, matching SPEC-018's public depth constant." A
  reader skimming §6 may conflate the two (both are 32) into a single rule
  and miss that there are two distinct enforcement points: schema depth at
  request parse, output depth at post-inference validation. The line 579-580
  parenthetical "Same constant as the output-validation depth cap in AC-13,
  by design" partially flags this but does not name the two axes plainly.
- Recommendation: Add one sentence after line 580: "This is the SCHEMA-side
  depth limit, evaluated at request parse. The OUTPUT-side decoded JSON depth
  limit is also 32 (see below and AC-13); both checks must pass."

## Verdict justification

The reshape from v0.1.0 to v0.1.1 successfully closes both narrative HIGHs
(§0 lead, §2 categories) and all four narrative MEDIUMs (Fail-condition
preamble, cross-spec summaries, reject-count, citation dedup). The SPEC body
at 788 lines reads in coherent top-to-bottom order: orientation → current
code → buyer contract → ACs (12 categories) → grammar → family rendering →
validator → caps → coordinator/gateway → money path → forward-compat →
deferred → open questions → metadata. No new sprawl. The new §5 error-codes
table serves the reader and is self-contained.

However, one MEDIUM remains: the change-log entry uses appendix codes
(§A.1, §B.1, ...) that have no anchor in the SPEC body. For a change log that
is the primary version-to-version reader's compass, that is a real
comprehension blocker for an external reviewer doing PR archaeology. This
should be fixed before lock. The two minors (category name, dual-depth
signposting) are nice-to-have and not blockers in isolation, but if a quick
pass is going in for the MEDIUM, both can ride along.

Bar for narrative lane: 0 C / 0 H / 0 M. Tally is 0 / 0 / 1, so verdict is
FIX REQUIRED. One MEDIUM blocks; minors are flagged for the same pass.
