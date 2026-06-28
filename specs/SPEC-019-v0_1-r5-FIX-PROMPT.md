# SPEC-019 v0.1.5 — r5 polish (TIGHT — single fix)

Edit `specs/SPEC-019-structured-output.md` to absorb the single r5 MEDIUM.
Target version: **v0.1.5**. Append a v0.1.5 change-log entry citing
`specs/SPEC-019-v0_1-r5-audit.md` (write narrative file too — see §B).

**No commits, no docs/runbook updates, no IMPL code. SPEC body edits only.
Low reasoning effort.**

5 of 6 r5 lanes returned READY TO LOCK at v0.1.4. Codex architect lane
flagged ONE MEDIUM: AC-28a wording contradicts the §7 fix from r4.

## A. AC-28a — rewrite to match §7 (architect M-1)

Locate AC-28a (around `:354-361`).

Current text is internally contradictory: first sentence says "any
request with a `Content-Encoding` header returns HTTP 415", last
sentence says "`Content-Encoding: identity` is the only accepted value
(or omitted header)". A fixture implementer can cite AC-28a for either
an identity-rejection OR identity-acceptance test.

Replace AC-28a with this exact text:

```
AC-28a. `Content-Encoding` reject fixture: a request whose
`Content-Encoding` header has a normalized field value other than
exactly `identity` (RFC 9110 §8.4.1.1 no-op encoding) returns HTTP 415
`request_content_encoding_unsupported`, `param:"Content-Encoding"`,
`retryable:false`, `inference_ran:false`, `settlement_ran:false`,
identical at gateway and coordinator (parity). Both gzip-compressed
JSON bodies and a header-only fixture (no actual compression) MUST
reject; the SPEC does not require the gateway/coordinator to validate
the body's compression. Accepted: omitted `Content-Encoding` and
`Content-Encoding: identity` (case-insensitive per RFC 9110 §5.5;
optionally surrounded by whitespace, which the parser MUST strip
before comparison). Adversarial fixtures MUST include: `gzip`,
`deflate`, `br`, empty-after-trim (header present with whitespace-only
value), whitespace-surrounded `identity` (accepted after normalization),
case-variant `Identity` / `IDENTITY` (accepted), and a comma-separated
multi-value `identity, gzip` (rejected — not exactly `identity`).
```

## B. Change-log + r5 narrative

Update §12 metadata:

```
**Version:** 0.1.5 (2026-06-28, round-5 final polish)
**Status:** DRAFT — final defensive lock candidate.
```

Add v0.1.5 entry to §12 change log:

```
- **v0.1.5 (2026-06-28, round-5 final polish):** Absorbed the single
  r5 MEDIUM. AC-28a fixture wording rewritten to match the §7
  `Content-Encoding: identity` carve-out from r4 (architect M-1).
  AC-28a now defines a single coherent fixture: reject when
  normalized value is not exactly `identity`; accept omitted header
  and `identity` (case-insensitive, whitespace-tolerant). Adversarial
  fixture rows added for case-variants, whitespace surrounds, and
  multi-value `identity, gzip` rejection. 5 of 6 r5 lanes returned
  READY TO LOCK; only the architect lane found this fixture
  inconsistency. Round narrative: `specs/SPEC-019-v0_1-r5-audit.md`;
  per-lane findings: `specs/SPEC-019-v0_1-{architect,code,security,
  product-design,critic,narrative}-r5-audit.md`. Re-fire architect-
  only lane to confirm 0/0/0 closure before lock.
```

Write `specs/SPEC-019-v0_1-r5-audit.md` (mirror of r4 narrative).
Keep tight (~60 lines). Highlight: 5-of-6 READY TO LOCK; single
fixture-wording fix; pattern matches SPEC-018 v0.1.4 polish.

## Stop condition

Verify after editing:

1. `grep "normalized field value other than exactly" specs/SPEC-019-structured-output.md`
   appears in AC-28a (new wording).
2. `grep "any request with a Content-Encoding" specs/SPEC-019-structured-output.md`
   returns 0 (old wording gone).
3. AC-28a explicitly names case-insensitive + whitespace-tolerant
   `identity` acceptance.
4. AC-28a explicitly names `identity, gzip` rejection (multi-value
   test).
5. §12 v0.1.5 entry references §1-§12 anchors only.
6. Version header bumped to 0.1.5.

Report:
- Resulting line count.
- Confirmation that AC-28a is the ONLY edit to ACs (no other AC
  text changed).
- Any text you could not place — explain why.

Done. No commit. No re-audit. The architect-only re-fire is the
next step (separate codex call).
