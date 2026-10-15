# PR #2002 audit round 2 (codex, three lanes)

Code 0/0/0/3, security 0/0/0/0 (+3 INFO), architecture 0/0/1/1.

- ARCHITECTURE MEDIUM: the OpenRouter context aggregation dropped a busy provider with no free slot, because /poolz `routing_eligible` requires a free slot. Fixed: coordinator /poolz rows carry `serving_eligible` (routing_eligible apart from the free-slot term); the gateway aggregates context from ready/busy serving-eligible rows into a status-level map, so /v1/status is unchanged and a full provider keeps its context (SPEC-006 §5.3.2, SPEC-002 v1.6.17). Tests on both sides.
- ARCHITECTURE LOW: SPEC-019 quick-orientation/current-code sections read as current. Fixed: marked historical.
- CODE LOW: numeric `strict` vectors. Fixed for the coordinator (400 invalid_request); the provider's Foundation bool bridging is pre-existing and unreachable behind the coordinator check.
- CODE LOW: non-strict coverage through continuous-batch finalization and idle-timeout synthesis; opaque privacy frames before first content. Carried: both paths call the same `requiresStructuredValidation` / `validateStructuredCompletion` gates covered by unit tests; privacy frames carry no content delta and are bounded by first-token.
- SECURITY INFO (carried): Swift non-strict depth check after materialization (coordinator blocks first); schema text in the prompt is the requesting buyer's own; double tokenization on non-relay-blind long streams is bounded (Studio validation item).
