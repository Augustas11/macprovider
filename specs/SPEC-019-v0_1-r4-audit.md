# SPEC-019 v0.1.3 round-4 defensive audit -- narrative

Round-4 defensive audit of `specs/SPEC-019-structured-output.md` v0.1.3 after
round-3 absorption. The lens was final polish before lock: confirm the r3
`Content-Encoding` posture, paired SDK fixture parity, deferred-version
targets, and buyer-visible Vercel behavior were internally consistent.

## Aggregate tally

| Lane | C | H | M | m | Q | Verdict |
|---|---|---|---|---|---|---|
| codex architect | 0 | 0 | 1 | 0 | 0 | FIX REQUIRED |
| codex code | 0 | 1 | 0 | 1 | 0 | FIX REQUIRED |
| codex security | 0 | 0 | 0 | 1 | 0 | READY TO LOCK |
| codex product-design | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| claude critic | 0 | 1 | 2 | 1 | 0 | FIX REQUIRED |
| claude narrative | 0 | 0 | 0 | 3 | 0 | READY TO LOCK |
| **r4 TOTAL** | **0** | **2** | **3** | **6** | **0** | **FIX REQUIRED** |

## Lock signal

Three of six lanes returned READY TO LOCK in the same round:
security, product-design, and narrative. This is the first SPEC-019 v0.1 audit
round with half the lanes at lock posture. The remaining findings are small:
both HIGHs are one-line convergent fixes, and the MEDIUM set is citation /
target-version cleanup rather than new architecture.

## Top HIGHs

1. **Code H-1** -- AC-30 used a Pydantic `int` field while AC-31 used Vercel
   `z.number()`. The two fixtures could not produce byte-equivalent canonical
   schemas because Pydantic emitted `{"type":"integer"}` and Zod emitted
   `{"type":"number"}`. Fix: change the AC-30 fixture to `age: float`.

2. **Critic H-1** -- §7 rejected any `Content-Encoding` header while AC-28a
   explicitly accepted `Content-Encoding: identity`. Fix: accept omitted
   encoding and the explicit RFC 9110 no-op `identity`; reject every other
   value with HTTP 415 `request_content_encoding_unsupported`.

## MEDIUM findings

- Architect M-1 converged with critic H-1 on the same `identity` contradiction.
  The architectural requirement is that v0.1.0 preserve a single byte-domain
  while allowing the HTTP-standard no-op coding.

- Critic M-1 found that AC-31 cited AC-3 for the rejected-keyword list even
  though AC-3 is the missing-schema check. The correct acceptance criterion is
  AC-5. The same fix makes `$schema` explicit in §3's reject list.

- Critic M-2 found that the nested-Pydantic limitation pointed to v0.2 for
  `$ref` / `$defs`, while §10 defers `$ref` / `$defs` reuse to v0.3. Fix:
  move the nested-Pydantic fixture target to v0.3.

## Minor findings

- Code m-1: §10's compressed-body deferral did not name the v0.1.0 error code.
  Add `request_content_encoding_unsupported` for grepable traceability.

- Security minor: the `identity` exception should be expressed tightly enough
  that compressed encodings remain impossible to smuggle into v0.1.0.

- Critic minor: AC-31's `$schema` strip is fixture-side only; production Vercel
  buyers using `supportsStructuredOutputs:true` without normalization receive
  HTTP 400 in v0.1.0.

- Narrative minors: normalize the §10 deferred-list bullet shape and leave the
  remaining carried-forward §4 / §5 readability issues as non-blocking lock
  polish.

## Recommendation

Absorb r4 into v0.1.4. The change is intentionally small: accept
`Content-Encoding: identity`, align AC-30 with AC-31 schema type parity, correct
the rejected-keyword citation, make `$schema` explicit in §3, align nested
Pydantic with the v0.3 `$ref` / `$defs` target, name the compressed-body error
code in §10, and add the production Vercel HTTP 400 footnote.

After absorption, fire r5 defensive as a final 0/0/0 check. Expected focus:
§7 and AC-28a consistency, AC-30/AC-31 schema parity, §3 `$schema` rejection,
§10 v0.2/v0.3 target consistency, and §12 changelog traceability.
