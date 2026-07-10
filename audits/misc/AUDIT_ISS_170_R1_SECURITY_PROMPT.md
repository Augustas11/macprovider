You are auditing `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` from
a SECURITY lens. This is a BUILD prompt — paste-ready instructions
for an implementer LLM session to ship SPEC-004 v0.3.1 Pillars B / C
/ D / A in the coordinator.

# Repository context

- Branch `spec/004-build-prompt-bcda` in `Augustas11/macprovider`.
- SPEC-004 is the coordinator's smart-router contract. It writes
  `request_log.retried` (money-path read by SPEC-005), takes
  buyer-supplied input via `X-MacProvider-Retry` and request
  body `model` field (Pillar D), and consumes
  gateway-derived `routing_internal.conversation_key` (Pillar A).
- A BUILD prompt CAN introduce security risk indirectly: the
  implementer LLM follows the prompt. If the prompt is ambiguous
  on a security-critical wiring, the implementer makes a
  judgment call that the audit later catches OR misses.

# Audit scope (SECURITY lens)

For each phase, verify:

- **Auth/authz boundaries.** Does the prompt make explicit which
  paths are buyer-facing (rate-limited, body-capped, OpenAI-shape)
  vs admin/operator-facing? Pillar D adds `routing.model_classes`
  config but the alias resolution runs on BUYER input — is the
  prompt clear about treating the request body's `model` field as
  hostile?
- **Pillar A namespace gating (FR-SR-2).** The
  `routing_internal.conversation_key` MUST be in `conv:<opaque-id>`
  namespace; values that don't begin with `conv:` MUST be
  rejected or treated as absent. Does the BUILD prompt EMPHASIZE
  this so the implementer doesn't accidentally accept buyer-
  spoofed `X-MacProvider-Conversation` headers as sticky keys?
- **Sticky map memory bounds (FR-SR-5).** The map MUST be
  bounded by `routing.sticky_max_entries`. Does the BUILD prompt
  warn the implementer about unbounded-map DoS if eviction is
  buggy?
- **Mutex coverage for sticky operations.** FR-SR-5 paragraph 2
  enumerates: read, write, last_used_at update, TTL expiry, LRU
  eviction. Does the BUILD prompt require the mutex cover ALL
  five operations? Or could the implementer protect only the map
  itself and leave TTL/LRU races?
- **Dispatch-time model rewrite (FR-SR-7a).** The body that
  reaches the provider has the alias REWRITTEN to the chosen
  concrete model. Is the BUILD prompt explicit that this rewrite
  is SECURITY-RELEVANT (test discipline: assert on the body
  delivered to the provider)? A class alias that survives
  rewrite means the provider observes a different model than
  the coordinator selected — a class of inconsistency that could
  hide a routing bug.
- **Retry double-emit (FR-SR-12 / FR-SR-13 / FR-SR-14).** Pillar
  D's retry rules forbid post-commit retry and forbid double-emit.
  Does the BUILD prompt make these invariants visible at the
  TOP of the Phase D section, or are they buried in a list?
- **`request_log.retried` write authority.** Per C5 in the
  prompt: only SPEC-004 explicit retry increments it; F-4 does
  not. Does the BUILD prompt make this column-write boundary
  clear enough that the implementer cannot accidentally bump
  the column from F-4 plumbing?
- **Randomization audit-explainability (FR-SR-17).** Every
  randomized decision MUST log the candidate set + seed/draw.
  Is the BUILD prompt explicit that this is NOT optional? An
  implementer who treats "logging" as a nice-to-have weakens
  the SPEC-004 audit story.
- **Body cap (FR-SR-7c).** The 1 MiB cap is already enforced;
  the BUILD prompt acknowledges it. Does the prompt's mention
  of "future operator-tunable knob" risk inviting the implementer
  to expand this in-scope and accidentally relax the default?
- **F-4 / FR-P11a composition.** Per C6: filter FIRST, then
  sort/select. Does the BUILD prompt give the implementer a
  pattern that makes it MECHANICALLY IMPOSSIBLE to route to a
  breaker-held provider? Or does it leave room for a fast-path
  shortcut that bypasses the filter?
- **d-inference clean-room.** Per C8: don't inspect d-inference
  source. Is this warning prominent enough that an implementer
  searching for "balanced routing" reference doesn't accidentally
  open the wrong file?

# Severity vocabulary

- **CRITICAL** = the BUILD prompt's wording would produce an
  exploitable security defect in the IMPL (auth bypass, money
  loss, double-emit, breaker-held leak).
- **HIGH** = the BUILD prompt has a security-relevant gap that
  the implementer would likely fill INCORRECTLY.
- **MEDIUM** = a hardening item the BUILD prompt should explicitly
  name to harden the IMPL.
- **LOW** = wording or framing that opens a mistake class.

# Output

```
[SEVERITY] <short title>

Location: <heading or topic>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Audit the BUILD prompt AS WRITTEN. Do not invent unrelated security
requirements.
