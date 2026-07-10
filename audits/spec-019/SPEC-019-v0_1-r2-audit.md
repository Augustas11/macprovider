# SPEC-019 v0.1.1 round-2 defensive audit — narrative

Round-2 defensive audit of `specs/SPEC-019-structured-output.md` v0.1.1 after
round-1 absorption. The lens was regression defense: prove r1 fixes were
normative, testable, and wired across provider, coordinator, and gateway
surfaces before lock.

## Aggregate tally

| Lane | C | H | M | m | Q | Verdict |
|---|---|---|---|---|---|---|
| codex architect | 0 | 1 | 0 | 0 | 0 | FIX REQUIRED |
| codex code | 0 | 0 | 3 | 1 | 0 | FIX REQUIRED |
| codex security | 0 | 2 | 1 | 0 | 0 | FIX REQUIRED |
| codex product-design | 0 | 2 | 1 | 0 | 0 | FIX REQUIRED |
| claude critic | 0 | 1 | 4 | 1 | 1 | FIX REQUIRED |
| claude narrative | 0 | 0 | 0 | 1 | 0 | FIX REQUIRED |
| **r2 TOTAL** | **0** | **6** | **9** | **3** | **1** | **FIX REQUIRED** |

## Top HIGHs

1. **Architect H-1** — Composite render was internally contradictory: prose
   said render tools first, numbered order said schema-adjusted messages first.
   Fix: single normative order at all `ModelRuntime.swift` hook sites:
   schema-adjusted `ChatMessage` values, then `ToolPromptRenderer`, then
   `UserInput` with original tools unchanged.

2. **Security F-1** — Validator panic / fatal-error paths could escape as empty
   HTTP 500s after inference, bypassing the SPEC-019 envelope and money-path
   classification. Fix: catch-all boundary converts all structured-output
   postprocess failures to terminal 502 with `inference_ran:true`,
   `settlement_ran:true`, `FaultBreakerQualifying`, no success receipt, no
   sticky success, and zero provider-positive credits.

3. **Security F-2 / critic F-1-F-2 / code M-2 / PD F-1** —
   `json_schema.name` was only a recommendation and incorrectly excluded
   OpenAI-compatible dashed names. Fix: provider and coordinator both enforce
   anchored `^[A-Za-z0-9_-]{1,64}$`, reject with
   `json_schema_invalid_name`, and accept `person-v1`.

4. **Product-design F-2** — SDK fixtures could false-green independently:
   OpenAI Pydantic and Vercel Zod paths were not the same logical schema.
   Fix: paired `Person { name, age }` fixtures with captured outbound bodies,
   canonical schema comparison, and explicit title/description allow-list.

5. **Product-design F-3** — Empty model output is deterministically buyer-fixable
   but inherited `malformed_json_response retryable:true`, risking retry-budget
   burn. Fix: empty-string subcase keeps the error code but overrides
   `retryable:false` with an actionable message.

6. **Critic F-3 / carried r1 M-5** — Gateway content-encoding handling was not
   pinned. Fix: preserve inbound compressed body bytes to coordinator and keep
   gateway, coordinator, and provider byte-equivalence invariants aligned.

## Convergent themes

- **Composite render single source of truth** — architect, code, and critic
  converged on order (A): schema-adjusted messages first, existing tool renderer
  second. This is implementable at current hook sites without inventing a
  post-render insertion API.

- **Name validation is security and compatibility, not style** — four lanes
  found that `json_schema.name` must be mandatory, OpenAI-compatible, tested at
  provider and coordinator, and treated as untrusted prompt data.

- **Post-inference failures are money-path failures** — empty output, validator
  internals, resource aborts, duplicate settlement, and receipt ordering all
  need one invariant: once inference starts, structured-output postprocess
  failures settle exactly once as downstream `FaultBreakerQualifying` outcomes.

- **Byte identity remains the backbone** — NFC/NFD key comparison, gzip body
  preservation, schema byte caps, JCS canonicalization, and prompt hashes must
  all preserve byte-distinct behavior instead of normalizing for convenience.

- **Fixtures must prevent false-green** — composite render needs both
  short-circuit and non-empty tool-history fixtures; SDK parity needs paired
  logical schemas; Vercel default path remains a separate `json_object` fixture.

## Recommendation

Absorb r2 into v0.1.2. Bump the spec version, address 6 HIGH + 9 MEDIUM + 3
minor findings, and preserve the r2 narrative beside the six per-lane reports.

After absorption, fire r3 defensive — same 6 lanes (`architect`, `code`,
`security`, `product-design`, `critic`, `narrative`), mirroring the r3 pattern
from SPEC-018 v0.2: adversarial confirmation that v0.1.2 has no contradictory
normative rules, no stale anchors, no untested money-path edges, and no
regression of r1/r2 fixes.
