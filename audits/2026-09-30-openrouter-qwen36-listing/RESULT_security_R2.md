
**HIGH — Buyer-facing model-class aliases bypass the multi-turn tool gate**

File: [server.go:6828](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6828)

The gate compares `req.Model` only with concrete catalog IDs. Public model-class aliases are resolved later during provider selection and rewritten to the selected provider’s concrete model at [server.go:6263](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6263).

Concrete failure scenario: a class such as `mlx-fast` contains a catalogued non-SPEC-018 §3.8 model such as Llama 3.2. A buyer submits `model:"mlx-fast"` with `role:"tool"` or assistant `tool_calls`. The gate finds no concrete match and allows dispatch. Routing selects the unsupported provider, which rejects the request; the coordinator converts that failure to 502 and marks the provider degraded. Repeated requests can degrade class members, recreating the authenticated DoS condition this change intends to prevent.

Model classes are explicitly buyer-callable in [SPEC-004:351](/Users/augstar/macprovider-or-features/specs/SPEC-004-smart-router.md:351) and advertised through `/v1/models` at [server.go:2223](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:2223).

Fix: resolve model classes before idempotency reservation and dispatch. Apply the gate to every eligible catalogued class member, conservatively rejecting the request if any member lacks a SPEC-018 §3.8 profile. Add a regression asserting class-alias requests return 400, dispatch zero provider requests, and create no idempotency reservation.

## Round-1 verification

All reported R1 fixes were verified:

- Concrete aliases, free aliases, OpenRouter slugs, case variants, and bare keys are normalized.
- Empty assistant `tool_calls` arrays no longer trigger the gate.
- Probe listing membership and capability descriptors are checked exactly.
- `response_format` is now the required object descriptor.
- Structured-output and tool-family predicates are separated.
- SPEC-018 conformance mappings were added.
- The accepted predicate-duplication LOW was not re-raised.
- Pre-dispatch rejection occurs before idempotency reservation and does not create provider settlement, receipt, or buyer-debit side effects.

Targeted coordinator, gateway, and 98 probe tests passed; `git diff --check origin/main...HEAD` passed.

VERDICT: C=0 H=1 M=0 L=0.
