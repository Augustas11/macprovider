## Lane: ARCHITECTURE — contracts, SPEC conformance, layering, operability.

Hunt specifically for:
- SPEC-001 v1.9.20 FR-27 and SPEC-038 v0.2.4: do code and spec agree across
  provider relay, coordinator (`writeWSEndError`, `wsEndHTTPStatus`, re-route)
  and gateway (`gatewayRetryableByCode`, `setGatewayRetryAfter`)? Any consumer
  that depends on these codes arriving as `error_internal`?
- Is `compiledDecode: false` on the serve path the right boundary, given
  `MSBThroughputCommand` and other callers still use the compiled path?
- The lab waiver: is a product-code bypass for lab tooling the right layer, and
  is it narrow and observable enough?
- `CBTrace`: acceptable as a permanent env-gated diagnostic in the serve path?
- The lazy-record change alters `PagedKVContiguousCacheBridge` semantics
  (snapshot-at-record → read-at-materialize); is that consistent with
  SPEC-039 FR-PKV10 and every caller's expectation?
