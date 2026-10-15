# PR #2002 audit round 3 (codex, three lanes, final)

Code 0/0/0/2, security 0/0/0/1, architecture 0/0/0/2. Gate (0 C/H/M) met on all three lanes.

- ARCHITECTURE LOW: routing/filter.go contract comment promised pre-Phase-C byte-identical selection. Fixed.
- ARCHITECTURE LOW: SPEC-006 depends-on line named SPEC-002 v1.5.4. Fixed (v1.6.17).
- Carried LOW (code): the estimator helper accepts several top-level JSON values; every caller passes a body the gateway/coordinator already parsed as one object.
- Carried LOW (code): no end-to-end test with the real provider tokenizer for the pre-commit 413; covered by `InferenceRelayTests` and listed as a Studio validation item.
- Carried LOW (security, pre-existing): the request-log identity fallback with a non-typed inserter does not apply the prompt bound; production wiring uses the typed store.
- Carried INFO: Swift non-strict depth check after materialization (coordinator rejects first); non-strict coverage for batched finalization and idle synthesis relies on the shared gate.
