# PR #2002 audit round 1 (codex, three lanes)

Code 0/3/2/4, security 0/0/2/0 (+1 INFO), architecture 0/0/0/5. Disposition, all fixed in the R1 fix commit unless noted:

- CODE HIGH: Harmony + non-strict json_schema became batch-representable. Fixed: the Harmony gate uses `isStructuredResponseFormat` (any json_object/json_schema).
- CODE HIGH: forwarded `provider_disconnected` used type `api_error`. Fixed: `server_error`; coordinator `provider_error` is normalized to `upstream_provider_error` (`api_error`) per SPEC-006 §17.
- CODE HIGH: buyer code vs settlement outcome divergence not listed in SPEC-006 §17.7.1. Fixed: named mappings added to §17.7.1 and to the network-harness reconciler with tests.
- CODE MEDIUM: coordinator bound used floor(bytes/4). Fixed: ceil, matching the gateway.
- CODE MEDIUM / SECURITY MEDIUM: relay-blind streaming tokenized twice; cancellation not observed after preflight. Fixed: relay-blind keeps the paged-KV check only (its preparation already tokenized and context-checked); a cancel during preflight ends the request before the opening chunk.
- SECURITY MEDIUM: class upper estimate under-reserved random letters / base64 / rare scripts. Fixed: mixed letter-digit runs, long letter runs and non-ASCII weights re-calibrated on 23 corpora including adversarial ones; upper estimate now at or above the tokenizer count on all of them (SPEC-006 §7.2.1).
- SECURITY INFO: Swift non-strict depth check runs after JSON materialization. Carried: the coordinator's iterative check rejects depth > 64 before dispatch; the pre-existing strict path has the same order.
- LOW (code/architecture): booleans priced as null (fixed); routing vs billed estimate mixed in observability state (fixed: `routingEstimatedTokens`); estimator duplication (fixed: byte-identity test across modules); SPEC-002 bytes/4 text (fixed: v1.6.17); SPEC-019 stale depth/metadata/open-question text (fixed); no integration case for the streaming pre-commit 413 (carried: the integration fake provider does not run the Swift relay; covered by `InferenceRelayTests`).
