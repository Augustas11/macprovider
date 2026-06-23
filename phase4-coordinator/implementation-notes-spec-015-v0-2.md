# SPEC-015 v0.2 Implementation Notes

## Step 0 - Coordinator Receipt Key Resolver

- `GET /v1/receipt-keys/{provider_id}` is mounted on the buyer HTTP server, not the operator/provider server. It is public and uses the existing buyer error envelope for misses.
- The handler marshals an explicit four-field response struct: `provider_id`, `receipt_pubkey`, `receipt_pubkey_prev`, and `fetched_at`. It never marshals `pool.Provider` directly, so operator-only fields such as endpoint URL, hostname, capacity, and connection timestamps are not on the wire.
- Receipt public keys are read from the in-memory `pool.Registry` state populated by provider registration and receipt-key publication. Empty current keys are returned as JSON `null` for pre-v1.6 providers.
- The endpoint uses a coordinator-local, in-memory token bucket keyed by `RemoteAddr` source IP: burst 10, refill 10 tokens per second. This matches Step 0's single-coordinator scope and avoids adding persistent or distributed state. In multi-coordinator deployments, limits are per process unless a future spec revision introduces shared rate-limit storage at the gateway or coordinator layer.
- Limiter entries are evicted by age and capped by entry count to bound memory use under source-IP churn. Overage returns HTTP 429 with `Retry-After: 1`.
- Successful responses set `Cache-Control: public, max-age=300`; 404 and 429 responses do not set that cache header.

## Operator Review Notes

- Confirm whether deployments behind trusted reverse proxies should key the limiter on a sanitized forwarded-client-IP header. Step 0 keys on `RemoteAddr`, matching the existing buyer `/v1/pool/check` spoofing posture.
- Confirm nginx exposes `/v1/receipt-keys/*` on the public buyer path after this coordinator change is deployed.
