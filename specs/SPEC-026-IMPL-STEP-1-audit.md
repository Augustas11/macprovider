# SPEC-026 Implementation Step 1 Audit

Status: converged to 0 Critical / 0 High / 0 Medium across code, security, and architecture lanes.

Scope:
- Coordinator App-track `/v1/providers/register` implementation.
- SPEC-026 identity schema, replay cache, App Attest verifier, JCS fixture, metrics, nginx route, and startup wiring.
- SPEC-001 v1.6 proof-stage `identity_signature` verifier integration.
- SPEC-026 §4.3 provider auth-policy admin exemption and Phase 1b cutover seeding surface.

Validation evidence:
- `cd phase4-coordinator && go test -count=1 ./internal/stats/migrations ./internal/onboarding ./internal/ws ./cmd/coordinator`
- `cd phase4-coordinator && go test -count=1 ./...`
- `cd phase4-coordinator && go vet ./internal/ws ./internal/onboarding ./internal/stats/migrations ./cmd/coordinator ./internal/config ./internal/auth ./internal/stats/metrics`
- `git diff --check`

Audit convergence:
- Code lane: `CODE LANE: 0 C/H/M findings`
- Security lane: `SECURITY LANE: 0 C/H/M findings`
- Architecture lane: `ARCHITECTURE LANE: 0 C/H/M findings`

Blocking findings closed during the loop:
- CLI proof-stage auth initially trusted a self-declared receipt key from the unsigned initial frame. Fixed by resolving CLI identity signatures against the stored current receipt key from the pool registry, with only constrained rotation-candidate handling.
- Auth-policy dual control initially trusted `requested_by` / `approved_by` JSON body fields. Fixed by deriving actors from per-operator `auth.operator_keys`, rejecting legacy shared `auth.operator_key` for these endpoints, and rejecting body actor mismatches.
- Cutover seeding was initially rerunnable. Fixed with a Postgres singleton `provider_auth_policy_cutover_runs` row inserted in the seed transaction before any exemption rows are written.
- Renewal-cap enforcement initially had race and accounting gaps. Fixed with provider-scoped advisory transaction locks, grant-history rows for migration seeding, unique incident IDs, and summed 30-day exposure checks for all grants.

Residual notes:
- Incident IDs allow the >7 day TTL path but do not bypass the cumulative 30 day exposure cap until a separate verified rotation-event object exists.
- `/register` still does not write `provider_auth_policy`; only Phase 1b cutover seeding and dual-control operator approvals populate exemption state.
