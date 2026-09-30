
- **MEDIUM — Trusted Pool requests bypass the new native multi-turn gate.**  
  Files: [server.go:6854](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6854), [multi_turn_test.go:469](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/multi_turn_test.go:469)  
  Scenario: an authorized Trusted Pool buyer sends tool history to an unsupported catalog model such as Llama 3.2 over a native WebSocket provider. `multiTurnToolGateApplies` returns false whenever `poolID` is present, and the test explicitly preserves this pass-through. The provider rejection can therefore still collapse into `error_internal`/502—the availability path this change removes globally. If that failure enters provider degradation handling, provider state is shared rather than pool-scoped, potentially extending the blast radius beyond the requesting pool. Even without degradation, repeated requests create avoidable buyer-triggered 502s and provider load.  
  Fix: apply the same model/family gate to native Trusted Pool routes, retaining the exemption only for explicit non-native/BYOM engines. Alternatively, preserve unsupported-model provider errors as non-faulting 400 responses and prove that they cannot change provider health. Add an integration test asserting no dispatch and no provider-state mutation.

- **LOW — SPEC-018 family predicates remain duplicated across three enforcement surfaces.**  
  Files: [server.go:6879](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6879), [openrouter_models.go:389](/Users/augstar/macprovider-or-features/phase5-gateway/internal/router/openrouter_models.go:389), [openrouter_readiness_probe.py:138](/Users/augstar/macprovider-or-features/scripts/openrouter_readiness_probe.py:138)  
  Scenario: a future family addition is applied to only one predicate. OpenRouter could then advertise unsupported capabilities, or the coordinator could reject a model that the public catalog claims supports multi-turn tools. This is the accepted carried LOW.  
  Fix: generate all predicates from one canonical manifest, or add a conformance test that compares the three accepted model-family sets.

- **INFO — The R2 model-class alias bypass is fixed.**  
  Files: [server.go:6832](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6832), [server.go:6864](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:6864), [server.go:7145](/Users/augstar/macprovider-or-features/phase4-coordinator/internal/buyer/server.go:7145)  
  Mixed model classes are filtered to profiled SPEC-018 members on every selection/failover pass; classes without a profiled member receive a pre-dispatch 400. Targeted tests confirmed unsupported members are never dispatched.  
  Fix: none.

- **INFO — No settlement or public-document exposure issue found.**  
  The pre-dispatch 400 occurs before provider assignment and idempotency reservation. It creates a buyer-failure request-log entry but no provider credit, receipt, settlement output, or buyer debit. `/v1/openrouter/models` exposes only the paid Qwen3.6 model, with no free alias or provider infrastructure identifiers, and descriptors are family-gated.  
  Fix: none.

Targeted coordinator, gateway, and readiness-probe tests passed; `git diff --check origin/main...HEAD` also passed.

VERDICT: C=0 H=0 M=1 L=1.
