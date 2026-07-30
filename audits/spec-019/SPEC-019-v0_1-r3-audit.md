# SPEC-019 v0.1.2 round-3 defensive audit — narrative

Round-3 defensive audit of `specs/SPEC-019-structured-output.md` v0.1.2 after
round-2 absorption. The lens was final lock defense: prove the r2 fixes were
implementable against current gateway/coordinator/provider code, did not create
fixture false-reds, and preserved buyer-visible recovery semantics.

## Aggregate tally

| Lane | C | H | M | m | Q | Verdict |
|---|---|---|---|---|---|---|
| codex architect | 0 | 0 | 1 | 0 | 0 | FIX REQUIRED |
| codex code | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| codex security | 0 | 0 | 2 | 1 | 0 | FIX REQUIRED |
| codex product-design | 0 | 1 | 1 | 0 | 0 | FIX REQUIRED |
| claude critic | 0 | 1 | 2 | 1 | 1 | FIX REQUIRED |
| claude narrative | 0 | 0 | 1 | 2 | 0 | FIX REQUIRED |
| **r3 TOTAL** | **0** | **2** | **7** | **4** | **1** | **FIX REQUIRED** |

## Top HIGHs

1. **Product-design H-1** — AC-31 could not pass with the pinned Vercel Zod
   fixture. `z.number().int()` emits numeric-bound keywords rejected by §3, and
   the captured Vercel schema includes top-level `$schema`. Fix: use the same
   logical `Person` contract with v0.1.0-compatible `z.number()`, strip
   `$schema` during fixture normalization, and defer numeric bounds / `$schema`
   acceptance to v0.2.

2. **Critic H-1** — The r2 gzip-preservation block was unimplementable against
   current gateway code. `parseChatRequest` reads `r.Body` directly and Go does
   not transparently call `gzip.NewReader`; compressed request bodies fail before
   pass-through. Fix: v0.1.0 rejects any `Content-Encoding` request header with
   HTTP 415 and defers transparent decompression to v0.2.

## Convergent themes

- **Gzip scope must be explicit and narrow** — critic, architect, and security
  all touched the r2 gzip block. The common conclusion was that v0.1.0 should
  keep one byte-domain for schema caps and JCS, reject `Content-Encoding`, and
  defer decompression plus decompressed-byte limits.

- **SDK fixtures must be both realistic and inside the v0.1.0 subset** —
  Vercel Zod and openai-python Pydantic remain valuable paired fixtures, but
  v0.1.0 needs explicit fixture normalization where SDKs emit keywords outside
  the accepted subset.

- **Fallback errors must avoid misleading precision** — security found that
  validator aborts can leave stale partial state; the catch-all must discard it
  and report the RFC 6901 root rather than a speculative field pointer.

- **Buyer recovery semantics need exact language** — empty-content
  `retryable:false` blocks blind SDK replay of the identical request, but still
  permits buyer-initiated modified retries with changed seed, temperature,
  prompt, or schema.

- **Narrative anchors should point to actual assertions** — the dual depth-cap
  signpost regressed by citing AC-27 for output-instance depth. AC-13 is the
  acceptance criterion that asserts the output-side cap.

## Recommendation

Absorb r3 into v0.1.3. Bump the spec version, address 2 HIGH + 7 MEDIUM + 4
minor + 1 Q findings, and keep this narrative beside the six per-lane reports.

After absorption, fire r4 defensive — same 6 lanes (`architect`, `code`,
`security`, `product-design`, `critic`, `narrative`) — focused on confirming
the 415 `Content-Encoding` posture, AC-31 fixture normalization, partial-state
discard, empty-content retry semantics, depth counting, and stale-anchor cleanup.

Note: the Codex code lane was the first lane to return READY TO LOCK in any
SPEC-019 v0.1 audit round.
