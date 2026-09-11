# Product Build 3 — Independent Code Inspection

Review type: independent read-only implementation inspection; not the plan approval gate
Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Date: 2026-09-11

## Verdict

Build 3 production compute observations are not landed. The repository has substantial SPEC-036 leaf primitives and dormant settlement guardrails, but no live observation owner.

## Independent classifications

| Outcome | Classification | Independent evidence |
| --- | --- | --- |
| One model/runtime/profile pilot | **Missing** | No policy/config instance or concrete covered key. `internal/buyer/route_snapshot.go:computeIntegrityRouteBinding` constructs `NewDefaultPolicy()` and remains dormant. `computeintegrity/activation.go:ActivationCheck` requires the concrete model, tokenizer, entrypoint, profile, runtime class, corpus, threshold, references, calibration, disclosure, controls, stable identity authority, and cost model before enforce. |
| Actual probes | **Missing; adjacent sampler path blocked** | `computeintegrity/probe.go` supplies DTOs, bounds, digests, retries, and expiry, but no scheduler/transport/ingestion caller. SPEC-036 owns its settlement-bearing wire framing. The adjacent Swift losslessness handler always produces `inconclusive:unsupported_sampler` because the current runtime has no full-distribution MLX sampler hook. |
| Reference and calibration | **Partial primitives; production inputs missing** | `reference.go` validates quorum/freshness/independence and `threshold.go` validates calibration for enforce. No producer fleet, signed artifacts, durable store, config, migrations, or production evidence exists. |
| Generation, expiry, revocation | **Partial and memory-only** | `window.go` and `warmswap.go` cover generation-aware keys, TTLs, invalidation, overlays, swap laundering, and tombstones. The sole store is explicitly in-memory; no production model/reconnect/revocation wiring or restart recovery exists. |
| Sanitized status | **Partial contract; live source missing** | `status.go:StatusForKey` creates digest-only status. Provider/admin handlers return 503 when the injected source is nil. Coordinator startup does not inject `WithComputeIntegrityStatusSource`. Buyer/gateway model responses deliberately report unavailable. |
| Governed reward mapping | **Partial classifier; production mapping missing** | `rewards/read_model.go` has closed compute states. `rewards/projection.go:BuildProviderRewardProjection` hardcodes compute integrity to unknown and records that the mirror lacks a provider-independent freshness watermark. |
| Enforcement/economic activation | **Guardrail landed; activation blocked by design** | Immutable request-start capture and fail-closed settlement loading exist. Routing remains dormant without an authoritative source. SPEC-036 says enforce is maintainer-gated and not claimed reachable at current beta supply. No observation currently affects debit, credit, rewards, or payout. |

## Fresh commands executed by the independent inspector

All passed on the exact base. They prove staged primitives and fail-safe behavior only.

```bash
cd phase4-coordinator && go test ./internal/computeintegrity -count=1
cd phase4-coordinator && go test ./internal/ws -run 'ComputeIntegrity|Losslessness' -count=1
cd phase4-coordinator && go test ./internal/billing -run ComputeIntegrity -count=1
cd phase4-coordinator && go test ./internal/rewards -run 'ComputeIntegrity|Projection|Eligibility' -count=1
```

These runs are not the independent review of `build3-plan-v1` / `build3-test-v1`, actual MLX inference, a physical-Mac journey, Xcode application evidence, deployed-service evidence, or production qualification.
