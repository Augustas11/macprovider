**Verdict:** READY TO LOCK
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified

- r4 product-design verdict: CLOSED / no regression. The two r4 product-design probes remain closed in v0.1.4. AC-31 still keeps Vercel fixture normalization scoped to fixture comparison while real v0.1.0 requests reject `$schema` through AC-5 / Section 3 (`$schema` is explicitly in the rejected-keyword list). AC-31 also still explains the v0.1.0-compatible Zod shape by substituting `z.number()` for `z.number().int()` because `.int()` emits rejected numeric-bound keywords (`minimum` / `maximum`). Section 10 preserves the forward path by deferring numeric-bound keywords and `$schema` acceptance to v0.2.

## Fresh findings

None.

## Verdict justification

The r5 AC-31 footnote steers SDK authors toward a workable v0.1.0 path instead of leaving them blocked. It identifies both incompatibilities produced by the Vercel AI SDK structured-output path: top-level `$schema` and numeric-bound keywords from `z.number().int()`. It then shows the temporary workaround shape: strip top-level `$schema` before comparison / submission normalization and use unconstrained `z.number()` until v0.2 accepts numeric bounds. The production warning is actionable because it states the failure mode for `supportsStructuredOutputs:true` without normalization: HTTP 400 from the Section 3 rejected-keyword list.

No r4 edits introduce a new product-design ambiguity. Vercel buyers who cannot normalize can still use the default path without `supportsStructuredOutputs:true`, which AC-32 keeps on `json_object`; buyers who need `json_schema` have a documented v0.1.0 normalization/substitution path and a named v0.2 removal target.
