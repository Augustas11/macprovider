# SPEC-019 v0.1.3 round-4 defensive audit — TIGHT

Audit `specs/SPEC-019-structured-output.md` v0.1.3 at commit `eee4282`
on branch `spec/019-structured-output` (worktree
`/Users/augstar/macprovider-spec-019`).

**Defensive round** after r3 absorbed 2 HIGH + 7 MEDIUM + 4 minor + 1 Q
across 8 themed blocks. r2 absorbed 6H+9M+3m. r1 absorbed 3C+14H+14M.
Codex code lane was the first READY TO LOCK at r3.

Two tasks:

1. **Closure verification.** For your lane's r3 findings (in
   `specs/SPEC-019-v0_1-{lane}-r3-audit.md`), confirm closure in
   v0.1.3.
2. **Regression probing.** r3 added 8 new edits — gzip 415 rejection,
   AC-31 Zod fixture rewrite, partial-validator-state discard,
   empty-content message rewrite, §6 dual-axis signpost AC fix, §6
   mixed worked example, retryable nuance, nested-Pydantic limitation.

Bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM** = READY TO LOCK.

## What changed in `eee4282` (only this commit's delta)

8 themed blocks per `specs/SPEC-019-v0_1-r3-FIX-PROMPT.md`:

- A. Gzip posture switched: §7 + AC-28a + §5 table + §10 — HTTP 415
  `request_content_encoding_unsupported`; deferred transparent decompression
  to v0.2.
- B. AC-31 Zod fixture rewritten: `z.number().int()` → `z.number()`;
  `$schema` strip step documented; §10 deferral for numeric bounds + `$schema`.
- C. §5 panic catch-all gains "partial-validator-state discard +
  error.param:''" rule.
- D. §5 empty-content message: `max_tokens` → `temperature` / `seed`.
- E. §6 dual-axis signpost cites AC-13 (not AC-27).
- F. §6 depth-counting gains mixed `items`/`properties` worked example.
- G. §5 empty-content `retryable:false` semantics clarified.
- H. §10 nested-Pydantic v0.1.0 limitation footnote.

## Per-lane lens

Per-lane closure checks: read your lane's r3 audit file and verify each
finding is closed in v0.1.3.

**Regression probes** (per lane):

- **Architect**: gzip 415 reject — does it actually conflict with
  SPEC-006 §1650-1657's request-body posture? Is 415
  `request_content_encoding_unsupported` the right HTTP code (vs 400
  invalid_request)? Does §10 deferral text imply v0.2 will need a
  decompressed-byte cap that v0.1 silently inherits via SPEC-006?
- **Code**: grep-verify the new `request_content_encoding_unsupported`
  appears in §7 normative + §5 table + AC-28a + §10. Does the new AC-31
  Zod fixture text match the actual Vercel AI SDK behavior with
  `z.number()`? Does the partial-validator-state rule cite the right
  envelope field (`error.param:""` vs the empty-string RFC 6901 root)?
- **Security**: 415 reject — can an attacker bypass by sending
  `Content-Encoding: identity` (which is technically the no-op
  encoding)? The new rule says `identity` is accepted; verify that's
  safe. Partial-validator-state + `error.param:""` — is the empty
  string the right RFC 6901 root, and does it bypass any §5 error
  envelope discipline?
- **Product-design**: AC-31 `$schema` strip step — does this normalize
  the captured Vercel body before comparison, or normalize at request
  time? Distinction matters for buyer behavior. Empty-content nuance
  — is the new "buyer MAY issue modified retry" guidance specific
  enough for SDK authors to act on, or is it advisory text that doesn't
  bind anyone?
- **Critic (Claude)**: r3 critic returned 1H+2M+1m+1Q — fresh blind
  spots in v0.1.3's 8 new blocks. Specifically: gzip 415 — does it
  break any OpenAI-compat assumption? AC-31 `$schema` strip — is the
  strip semantically lossless or could it hide schema differences?
  §10 deferral text now has 3 v0.2 promises (gzip decomp, numeric
  bounds, $schema acceptance) — are they coherent or accidentally
  contradictory?
- **Narrative (Claude)**: r3 narrative returned 0H+1M+2m. Verify §6
  AC-13 citation fix. Look at the full §10 deferred list — has it
  bloated past coherence?

## Output format

Write findings to `specs/SPEC-019-v0_1-{lane}-r4-audit.md`:

```
**Verdict:** {READY TO LOCK | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closure verified
{r3 findings: CLOSED / PARTIAL / REGRESSED, cite §}

## Fresh findings
{if any}

## Verdict justification
```

Bar: 0/0/0 across all 6 = READY TO LOCK → SPEC-019 PR opens.
