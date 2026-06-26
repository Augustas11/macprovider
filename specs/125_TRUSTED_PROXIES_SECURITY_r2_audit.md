CLOSURE on round-1 findings:
  L1: PASS — `X-Real-IP` is now accepted only after `netip.ParseAddr` succeeds and returns `addr.String()`; malformed and port-bearing values fall through to `r.RemoteAddr` (`server.go:1000-1012`, tests at `trusted_proxies_test.go:203-238`).
  L2: PASS — `TrustedProxyPrefixes` rejects `Bits() == 0`, `Validate` calls it at startup, and IPv4/IPv6 default-route regression tests cover `0.0.0.0/0` and `::/0` (`config.go:623-641`, `config.go:656-662`, `config_test.go:255-270`).
  Q1: noted (deferred to follow-up) — `poolCheckClientKey` explicitly documents that WS unauth semaphore parity remains intentionally separate pending a future shared `httpip` helper (`server.go:967-972`).

NEW FINDINGS (round 2):
CRITICAL (0): None.
HIGH (0): None.
MEDIUM (0): None.
LOW (0): None.
QUESTIONS (0): None.

Notes:
- The X-Real-IP canonical-form change hardens bucket keying: valid alternate spellings of the same IP collapse to one canonical `netip.Addr.String()` value, while invalid spellings cannot become attacker-chosen keys.
- Default-route rejection closes the obvious universal-trust footgun. Wider-but-nondefault prefixes such as `0.0.0.0/1` remain operator policy rather than a startup validation failure; the config comments and YAML templates now warn that only actual proxy CIDRs belong in `proxy.trusted_proxies`.
- `mustParseTrustedProxies` now fail-fasts via `logger.Fatal()` if post-Validate parsing ever drifts, avoiding the prior silent "trust no proxy" downgrade (`main.go:410-415`).

Validation:
- `go test ./internal/config ./internal/buyer` passed from `phase4-coordinator`.

VERDICT: security lane READY TO MERGE
