CRITICAL (0):
  (none)

HIGH (0):
  (none)

MEDIUM (1):
  M1. Trusted-proxy policy is not discoverable from shipped operator docs/templates
      Evidence: phase4-coordinator/internal/config/config.go:42 adds the security-sensitive `proxy.trusted_proxies` surface, phase4-coordinator/internal/config/config.go:451 sets the loopback default, and phase4-coordinator/cmd/coordinator/main.go:284 wires it into buyer rate-limit keying; however phase4-coordinator/coordinator.yaml.example:1 and phase4-coordinator/dist/coordinator.yaml.example:7 still go directly from `listen` to `pool` with no `proxy` block, while specs/SPEC-002-coordinator.md:2519 documents `/v1/pool/check` rate limiting without naming the source-IP derivation and specs/SPEC-015-receipts.md:2476 plus specs/SPEC-015-receipts.md:3333 only say "per source IP".
      Fix:     Add a commented `proxy.trusted_proxies: ["127.0.0.0/8", "::1/128"]` block with the spoof/collapse warning to both coordinator YAML templates, and add SPEC-002 / SPEC-015 notes that public coordinator endpoint rate-limit source IP is derived through `proxy.trusted_proxies` (default loopback only).

LOW (3):
  L1. Buyer/WS IP-helper asymmetry is deliberate but should remain tracked boundary debt
      Evidence: phase4-coordinator/internal/buyer/server.go:967 explicitly defers unification to a future shared `httpip` helper, while phase4-coordinator/internal/ws/server.go:1366 still implements only loopback `X-Real-IP` and specs/SPEC-002-coordinator.md:2775 keeps WS pre-upgrade controls at the proxy layer.
      Fix:     Leave the asymmetry for this PR; if WS later needs non-loopback proxy tiers, extract an `internal/httpip` package (Option A), not a miscellaneous mid-level utility package.

  L2. Trusted-proxy membership is not quite a single predicate inside buyer
      Evidence: phase4-coordinator/internal/buyer/server.go:1022 implements `(s *Server).isTrustedProxy`, while phase4-coordinator/internal/buyer/server.go:1066 repeats the same prefix loop inside `rightmostUntrustedXFF`.
      Fix:     Prefer a package-level pure `isTrustedProxy(addr, trusted)` helper and have both `poolCheckClientKey` and `rightmostUntrustedXFF` call it; keep `poolCheckClientKey` as the Server method because it derives keys for Server-owned buckets.

  L3. Startup parse fallback weakens the config validation contract
      Evidence: phase4-coordinator/internal/config/config.go:648 rejects invalid `proxy.trusted_proxies` during `Validate`, but phase4-coordinator/cmd/coordinator/main.go:408 reparses and silently substitutes nil on error, changing an invalid trusted-proxy config into "trust no proxy".
      Fix:     Treat a post-Validate parse error as fatal or return it from startup wiring; an operator config that fails trusted-proxy parsing should not silently collapse proxied clients into the proxy's bucket.

QUESTIONS (0):
  (none)
