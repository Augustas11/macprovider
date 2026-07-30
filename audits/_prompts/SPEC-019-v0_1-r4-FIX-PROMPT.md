# SPEC-019 v0.1.4 — r4 absorption (TIGHT)

Edit `specs/SPEC-019-structured-output.md` to absorb r4 findings.
Target version: **v0.1.4**. Append a v0.1.4 change-log entry citing
`specs/SPEC-019-v0_1-r4-audit.md` (write narrative file too — see §G).

**No commits, no docs/runbook updates, no IMPL code. SPEC body edits only.
Low reasoning effort.**

Aggregate r4: 0 CRITICAL + 2 HIGH + 3 MEDIUM + 6 minor + 0 Q. Three of
six lanes returned READY TO LOCK at r4 (security, product-design,
narrative). The remaining 2 HIGHs are 1-line fixes.

## A. `Content-Encoding: identity` accepted (architect M-1 + critic H-1)

**Decision: accept `identity`** (RFC 9110 §8.4.1.1: no-op encoding).
Reject every other value.

Locate the §7 normative content-encoding posture (around `:750-764`).

Replace the current "any non-empty value" wording with this exact text:

```
**Inbound `Content-Encoding` posture (v0.1.0)**: the gateway and
coordinator MUST reject any request with a `Content-Encoding` header
whose normalized field value is not exactly `identity` (RFC 9110
§8.4.1.1 explicit no-op encoding). `Content-Encoding: identity` and
omitted `Content-Encoding` are accepted. All other values (`gzip`,
`deflate`, `br`, or any compressed encoding) return HTTP 415
`request_content_encoding_unsupported` with an actionable message
("v0.1.0 accepts `Content-Encoding: identity` or no `Content-Encoding`
header; compressed request bodies are deferred to v0.2 per §10.").
This sidesteps three problems with transparent decompression in v0.1.0:
(a) current gateway `parseChatRequest` reads `r.Body` directly without
`gzip.NewReader` (cite `phase5-gateway/internal/router/chat_proxy.go:
102-117`); (b) decompressed-byte caps would need a second tier of
limits; (c) gateway, coordinator, and provider would need identical
decompression semantics to preserve the `json_schema.schema` byte cap
and JCS canonicalization invariants. v0.1.0 keeps a single byte-domain
(uncompressed request body) for all three components. No SPEC-006 or
SPEC-001 amendment is required: SPEC-006 §1650-1657 already covers
request-body size limits and 413; this adds 415 for a separate
content-coding gate.
```

AC-28a already says `identity` is accepted — keep that wording as-is.

## B. AC-30 Pydantic `int` → `float` for schema parity (code H-1)

**Decision: change AC-30 Pydantic fixture from `int` to `float`** so
both fixtures emit `{"type":"number"}`. Minimal change. Avoids
allow-list bloat.

Locate AC-30 (around `:369-380`). Find the Pydantic model definition
`class Person(BaseModel): name: str; age: int`.

Replace with:

```
AC-30. openai-python paired fixture: `test/integration/spec_019/
openai_python_strict_json_schema/` contains:
- request body with `response_format.json_schema` for `Person`
  (Pydantic model: `class Person(BaseModel): name: str; age: float`
  — note v0.1.0 fixture uses `float` rather than `int` so that the
  emitted JSON Schema `{"type":"number"}` matches Vercel AI SDK's
  `z.number()` output for byte parity per AC-31),
- `openai==2.44.0`,
- captured outbound HTTP body (`fixture_request_body.json`),
- expected returned parsed `Person` model,
- golden OpenAI `gpt-4o-2024-08-06` response committed for
  side-by-side comparison.
The macprovider response parses into the same `Person` model and the
JCS-canonicalized `response_format.json_schema.schema` matches the
golden fixture modulo an explicit allow-list (`title`, `description`,
`$schema`).
```

## C. AC-31 cites wrong AC for rejected-keyword list (critic M-1)

Locate AC-31 (around `:382-399`). The current text says "v0.1.0 §3
rejects `$schema` (per AC-3 rejected-keyword list)". AC-3 is
`json_schema_missing_schema`. Verify the actual rejected-keyword AC
number (likely AC-5 — confirm by reading the AC list).

Fix the citation: replace "AC-3 rejected-keyword list" with the
correct AC number (most likely "AC-5 rejected-keyword list" — verify
against current SPEC).

Additionally: §3 should explicitly include `$schema` in the rejected-
keyword list (not reached only via "unknown keyword" fallthrough).
Locate §3 rejected keywords (around `:425`). Add `$schema` to the
explicit reject list if not already present.

## D. §10 dependency contradiction (critic M-2)

Locate the nested-Pydantic v0.1.0 limitation note in §10 (added in
r3). Current text says nested fixtures are deferred to "v0.2 when
$ref/$defs schema reuse is in scope". But $ref/$defs is itself
deferred to v0.3 elsewhere in §10.

Fix: change "v0.2 when $ref/$defs schema reuse is in scope" to "v0.3
when $ref/$defs schema reuse is in scope". Verify both nested-Pydantic
and $ref/$defs entries in §10 cite the same target version.

## E. §10 deferred bullet — name the code token (code minor m-1)

Locate the §10 deferred bullet for transparent decompression (around
`:854-857`). Currently mentions the v0.2 transparent-decomposition
work but does not name the v0.1.0 error code that replaces it.

Append to that bullet:

```
v0.1.0 returns HTTP 415 `request_content_encoding_unsupported` for
compressed bodies until v0.2 decompression semantics land.
```

## F. Minor cleanups (narrative + security + critic minor)

- Narrative minor: §10 bullet shape — verify all v0.2/v0.3 deferreds
  use the same bullet structure (target version → what's deferred →
  why if non-obvious). Standardize the 11 entries' shape.
- Critic minor F-4: AC-31 `$schema` strip is test-side only; add a
  one-sentence note that production Vercel buyers using
  `supportsStructuredOutputs:true` without normalization will receive
  HTTP 400 from §3's reject-list. Either in §10 (deferral note) or as
  an AC-31 footnote. Recommend AC-31 footnote — it's a v0.1.0 buyer-
  visible behavior.

## G. Change-log + r4 narrative

Update §12 metadata:

```
**Version:** 0.1.4 (2026-06-28, round-4 polish absorption)
**Status:** DRAFT — final defensive check pending OR locking target.
```

Add v0.1.4 entry to §12 change log:

```
- **v0.1.4 (2026-06-28, round-4 polish absorption):** Absorbed 2 HIGH +
  3 MEDIUM + 6 minor across 6 audit lanes. Three lanes (security,
  product-design, narrative) returned READY TO LOCK at r4. `Content-
  Encoding: identity` accept/reject contradiction resolved — §7 now
  rejects only non-`identity` non-empty values (architect + critic
  convergent). AC-30 Pydantic fixture changed from `int` to `float`
  so both Pydantic and Vercel Zod fixtures emit
  `{"type":"number"}` (code). AC-31 citation fix: rejected-keyword
  list AC reference corrected; §3 explicitly includes `$schema` in
  reject list (critic). §10 nested-Pydantic deferral target corrected
  from v0.2 to v0.3 to align with $ref/$defs deferral (critic).
  §10 transparent-decompression bullet names the v0.1.0 error code
  `request_content_encoding_unsupported` for traceability (code minor).
  AC-31 footnote: production Vercel buyers with
  `supportsStructuredOutputs:true` and no normalization receive HTTP
  400 in v0.1.0 (critic minor). §10 bullet-shape normalized (narrative
  minor). Round narrative: `specs/SPEC-019-v0_1-r4-audit.md`; per-lane
  findings: `specs/SPEC-019-v0_1-{architect,code,security,
  product-design,critic,narrative}-r4-audit.md`. Codex security,
  product-design, and Claude narrative lanes = first 3 READY TO LOCK
  at the same round.
```

Write `specs/SPEC-019-v0_1-r4-audit.md` (mirror of r3 narrative).
Keep tight (~80 lines). Highlight: 3-of-6 READY TO LOCK; 2 HIGHs
were both 1-line convergent fixes; very small absorption.

## Stop condition

Verify after editing:

1. `grep "Content-Encoding: identity" specs/SPEC-019-structured-output.md`
   appears in BOTH §7 normative AND AC-28a, consistent.
2. `grep "any non-empty value" specs/SPEC-019-structured-output.md`
   returns 0 (old wording gone).
3. `grep "age: int\\b" specs/SPEC-019-structured-output.md` returns 0
   in AC-30 (Pydantic now uses `float`).
4. `grep "age: float\\b" specs/SPEC-019-structured-output.md` returns
   at least 1 (Pydantic fixture updated).
5. AC-31 citation reference to rejected-keyword list points to the
   correct AC number (likely AC-5; verify by reading the current AC
   list).
6. `grep "\\$schema" specs/SPEC-019-structured-output.md` shows §3
   reject list explicitly includes `$schema`.
7. §10 nested-Pydantic deferral cites v0.3 (not v0.2).
8. §10 transparent-decompression bullet mentions
   `request_content_encoding_unsupported` literally.
9. AC-31 footnote acknowledges production-path 400.
10. §12 v0.1.4 entry references §1-§12 anchors only (no theme codes).

Report:
- Resulting line count.
- AC count (should be unchanged from v0.1.3).
- The actual AC number for rejected-keyword list (verify, don't
  guess).
- Any §A-§G fix you could not place — explain why.

Done. No commit. No re-audit. r5 defensive may follow but is
expected to be a final 0/0/0 check.
