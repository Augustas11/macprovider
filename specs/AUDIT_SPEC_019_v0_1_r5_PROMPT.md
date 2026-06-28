# SPEC-019 v0.1.4 round-5 final defensive audit — TIGHT

Audit `specs/SPEC-019-structured-output.md` v0.1.4 at commit `9b4ec08`
on branch `spec/019-structured-output` (worktree
`/Users/augstar/macprovider-spec-019`).

**Final defensive round.** r4 absorbed 2 HIGH + 3 MEDIUM + 6 minor.
Three lanes (security, product-design, narrative) already returned
READY TO LOCK at r4. Codex code lane returned READY TO LOCK at r3.

Bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM** across all 6 lanes = READY
TO LOCK → SPEC-019 PR opens. If r5 returns 0/0/0 across the board,
v0.1.4 LOCKS as the SPEC PR anchor.

## What changed in `9b4ec08` (only this commit's delta)

7 themed blocks per `specs/SPEC-019-v0_1-r4-FIX-PROMPT.md`:

- A. §7 `Content-Encoding: identity` accepted (RFC 9110 §8.4.1.1
  no-op encoding). Reject only non-`identity` non-empty values.
- B. AC-30 Pydantic fixture: `age: int` → `age: float` so both
  Pydantic and Vercel Zod fixtures emit `{"type":"number"}`.
- C. AC-31 citation fix: rejected-keyword AC ref corrected to AC-5
  (was AC-3). §3 reject list explicitly includes `$schema`.
- D. §10 nested-Pydantic deferral target corrected v0.2 → v0.3 to
  align with $ref/$defs deferral.
- E. §10 transparent-decompression bullet names the v0.1.0 error
  code `request_content_encoding_unsupported`.
- F. AC-31 footnote: production Vercel buyers with
  `supportsStructuredOutputs:true` and no normalization receive HTTP
  400 in v0.1.0.
- G. §10 bullet-shape normalized + version metadata bumped to 0.1.4.

## Per-lane lens

For each lane, two tasks:

1. **Closure verification** of your r4 findings (in
   `specs/SPEC-019-v0_1-{lane}-r4-audit.md`). Confirm CLOSED /
   PARTIAL / REGRESSED with v0.1.4 §-citation.
2. **Regression probing**: do the 7 r4 edits introduce any new
   ambiguity?

Specifically:
- **Architect**: closure of M-1 (identity contradiction). Probe:
  does the RFC-9110 carve-out introduce any new cross-spec issue?
  Does §7 wording for non-empty-non-identity rejection cover edge
  cases like `Content-Encoding: ` (empty after trim) or whitespace-
  surrounded `identity`?
- **Code**: closure of H-1 (Pydantic int/float) + m-1 (§10 code
  token mention). Grep-verify `age: float` actually appears in
  AC-30. Verify AC-31 references AC-5 (not AC-3).
- **Security**: re-verify the 415 posture. Identity normalization —
  does "normalized field value is not exactly `identity`" need to
  spec case-folding (HTTP header values are case-insensitive per RFC
  9110 §5.5)? Probe: does an attacker bypass with `Content-Encoding:
  Identity` (capital I) or `Content-Encoding: identity, gzip`
  (multiple values)?
- **Product-design**: closure of r4 was READY TO LOCK; verify no
  regression in r4 edits. Probe: AC-31 footnote text — does it
  steer SDK authors toward a workaround, or does it leave them
  blocked?
- **Critic (Claude)**: closure of r4 H-1 + 2 MEDIUMs. Probe: r4
  introduced the RFC 9110 carve-out — is the §7 wording locking
  v0.1.0 to RFC 9110 specifically, or also accepting RFC 7231's
  earlier identity semantics?
- **Narrative (Claude)**: r4 was READY TO LOCK; verify no
  regression. Probe: §10 deferred list has many entries now (12+);
  is the v0.1.4 bullet-shape standardization actually consistent
  across all entries?

## Output format

Write findings to `specs/SPEC-019-v0_1-{lane}-r5-audit.md`:

```
**Verdict:** {READY TO LOCK | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closure verified
{r4 findings: CLOSED / PARTIAL / REGRESSED, cite §}

## Fresh findings
{if any — under "None." if 0/0/0}

## Verdict justification
```

Bar: 0/0/0 across all 6 = READY TO LOCK → SPEC-019 PR opens.
