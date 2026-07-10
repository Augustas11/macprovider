**Verdict:** READY TO LOCK
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified

- r3 Finding 1: CLOSED. AC-31 now uses the same logical `Person` contract through a v0.1.0-compatible Zod shape, `z.object({ name: z.string(), age: z.number() })`, and explicitly documents why `z.number().int()` is out of the v0.1.0 fixture because it emits `minimum` / `maximum` (§2 AC-31; §3 rejected keywords). The `$schema` handling is scoped to fixture comparison: the captured Vercel outbound body is normalized by stripping the top-level `$schema` before canonical-schema comparison, while real v0.1.0 requests still reject `$schema` under the §3 subset. §10 separately defers direct `$schema` acceptance and numeric-bound keywords to v0.2, preserving the buyer-visible distinction between "SDK fixture normalization" and "request-time provider normalization."
- r3 Finding 2: CLOSED. §5 now binds the empty-content subcase to `retryable:false` only for the returned envelope and requires an actionable message naming `temperature` / `seed`, prompt, or schema changes before retry. The new retry-semantics paragraph gives SDK authors an operational rule: do not blindly replay the identical request, but a deliberately modified retry with different `seed`, different `temperature`, relaxed schema, or clarifying prompt is permitted after the buyer's own retry policy decision (§5).

## Fresh findings

None.

## Verdict justification

The two r4 product-design probes do not reveal a remaining lock blocker. AC-31 no longer implies macprovider silently accepts SDK-emitted `$schema`; it confines the strip to the captured Vercel fixture comparison and keeps v0.1.0 request validation narrow. The retryable nuance is specific enough for SDK behavior because `retryable:false` is no longer overloaded as "never try again"; it now means "no automatic identical replay," with concrete examples of acceptable buyer-modified recovery.
