# SPEC-023 v0.1 Round 2 Audit

Date: 2026-07-01
Spec under audit: `specs/SPEC-023-installer-autotune-recommend.md`
Scope: three-lane Codex audit only: code, security, architect. No product-design lane was run per operator instruction.

## Result

Round 2 did not pass. The three requested audit lanes reported the following critical/high/medium findings:

| Lane | Critical | High | Medium | Low | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| code | 0 | 1 | 3 | 1 | Needs fix pass |
| security | 0 | 0 | 1 | 1 | Needs fix pass |
| architect | 1 | 0 | 0 | 2 | Needs fix pass |

## Blocking findings and resolutions

### CRITICAL-ARCH-01: donor-mode scope crossed the SPEC-023 boundary

Finding: the round 1 donor-mode fix introduced coordinator/gateway routing and settlement behavior while §2 says SPEC-023 does not change gateway billing or coordinator settlement.

Resolution:
- §8 now defines donor mode as a local provider-side override only for v0.1.
- SPEC-023 no longer specifies coordinator/gateway donor routing, heartbeat, or settlement changes.
- Applying donor mode for a non-recommendable row MUST NOT auto-start or auto-register a network-connected paid provider.
- Network-connected donor serving is deferred to a separate donor-routing/settlement spec or build prerequisite.
- AC-23 and the threat model now encode that boundary explicitly.

### HIGH-CODE-R2-001: `/v1/rate-card` risked money-path schema changes

Finding: the rate-card endpoint description could be implemented by changing `RateCardEntry`, YAML schema, billing, settlement, or ledger behavior.

Resolution:
- §3.3 now states `GET /v1/rate-card` is a read-only recommendation-only projection.
- It MUST NOT alter billing, settlement, routing, provider state, request logs, `RateCardEntry`, YAML schema, ledger schema, or settlement arithmetic.
- The endpoint derives its response from existing `Rewards.RateCard`, `Rewards.ProviderShare`, `Rewards.GlobalMultiplier`, and `stats.rollup.usd_per_million_credits` after config load.

### MEDIUM-SEC-01: donor mode could bypass runtime and deployability guardrails

Finding: donor mode bypass rules were too broad and could allow blocked, unsupported, unsafe, or non-deployable rows.

Resolution:
- §8 now says donor mode may skip only paid-yield and demand-rank `recommendable` default-selection gates.
- Donor mode MUST NOT bypass signed catalog metadata, `runtime_status != "blocked"`, model allowlist, digest checks when present, RAM headroom, no-swap, no-thermal, or runtime support.
- AC-22 now requires those checks before any local donor-mode commit.

### MEDIUM-CODE-R2-002: signature sidecar key validation was underspecified

Finding: §3.5 referenced `key_id` but did not define a sidecar schema, making key validation ambiguous.

Resolution:
- §3.5 now defines the detached signature sidecar as JSON with `key_id`, `alg`, and base64 `signature`.
- Verification rejects missing, malformed, wrong-key, wrong-algorithm, or failed-signature sidecars.

### MEDIUM-CODE-R2-003: donor-mode exclusion was not pinned to current surfaces

Finding: the donor-mode exclusion referenced routing/status behavior without a clear implementation boundary.

Resolution:
- The spec now uses a provider-side-only boundary for SPEC-023.
- Local config/status may reflect donor mode, but network-connected paid serving for non-recommendable donor rows is blocked until a separate prerequisite defines coordinator/gateway behavior.

### MEDIUM-CODE-R2-004: retune trigger named a nonexistent command

Finding: §9 referenced `macprovider upgrade`, while the current flow uses `macprovider-cli update` and installer rerun.

Resolution:
- §9 and AC-25 now use `macprovider-cli update` and installer rerun as the post-install retune triggers.

## Low findings handled opportunistically

- §3.2 now references §3.5 for integrity rules instead of the incorrect §3.4 reference.
- The demand-rank fallback wording now names Ed25519 detached-signature verification instead of generic checksum/signature language.

## Round 3 requirement

Run only the requested three Codex audit lanes again:

- code
- security
- architect

Continue fixing and re-auditing until all three lanes report zero critical, high, and medium findings.
