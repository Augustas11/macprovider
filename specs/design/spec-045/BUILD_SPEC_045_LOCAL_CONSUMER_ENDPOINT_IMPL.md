# BUILD_SPEC_045_LOCAL_CONSUMER_ENDPOINT_IMPL

Implement SPEC-045 local consumer endpoint mode as a staged set of small PRs. Do not implement the full endpoint from one prompt. Each slice below must land behind the same draft SPEC-045 authority and keep existing provider, gateway, billing, and catalog behavior unchanged unless the slice explicitly says otherwise.

## Target result

Ship `macprovider-cli consume` as a local development adapter: a macOS loopback-only OpenAI-compatible endpoint that lets local tools use a generated local token and loopback base URL while the CLI keeps the upstream buyer credential, model allowlist, local exposure controls, redacted status, and restart behavior.

## Slice order

1. `BUILD_SPEC_045_PHASE_1_ENDPOINT_SHELL.md`
   - command shape, loopback bind, startup output, local token, active endpoint descriptor, CLI status, credential source loading, and redaction foundations.
2. `BUILD_SPEC_045_PHASE_2_PROXY_SAFETY.md`
   - HTTP parser bounds, endpoint subset, path/query rejection, auth ordering, browser-origin denial, upstream origin/TLS/SSRF controls, header construction, proxying, and local error mapping.
3. `BUILD_SPEC_045_PHASE_3A_BUDGET_LEDGER_FOUNDATION.md`
   - budget flags, model admission ordering, fail-closed unpriced reservations, pinned micro-USD ledger, held reservation recovery, and truthful status.
4. `BUILD_SPEC_045_PHASE_3_BUDGET_LEDGER.md`
   - trusted pricing, conservative estimate math, chargeable proxy admission, settlement, `estimate_exceeded`, and restart/shutdown behavior.
5. `BUILD_SPEC_045_PHASE_3D_UPSTREAM_FORWARDING_SETTLEMENT.md`
   - non-streaming upstream forwarding, pinned dispatch, durable reservation settlement, failure provenance, and Phase 3D transport hardening.
6. `BUILD_SPEC_045_PHASE_3E_RESOURCE_ACCOUNTING.md`
   - aggregate response-spool, upstream worker-task, upstream socket/file-descriptor, and streaming-response slot admission.
7. `BUILD_SPEC_045_PHASE_3F_COMPRESSED_RESPONSE.md`
   - compressed non-streaming upstream response decode-to-identity, decoded response caps, and settlement from decoded usage.
8. `BUILD_SPEC_045_PHASE_3G_BUFFERED_SSE_FOUNDATION.md`
   - bounded buffered SSE upstream response relay, terminal `[DONE]` validation, and settlement from terminal stream usage evidence.
9. `BUILD_SPEC_045_PHASE_3H_LIVE_SSE_EMISSION.md`
   - local live SSE emission, event-line/event-frame bounds, idle read deadline refresh, and conservative local-disconnect settlement.
10. `BUILD_SPEC_045_PHASE_4_CONFORMANCE_JOURNEY.md`
   - required automated coverage, fake-gateway integration harness, staging/production signed journey, and promotion evidence.

## Required sequencing

- Phase 1 may land without chargeable proxying.
- Phase 2 may land with budgeted chat completions disabled unless Phase 3 has landed.
- Phase 3A must not forward chargeable requests; it only establishes fail-closed local budget-ledger foundations.
- Phase 3 must not forward chargeable requests until durable reservation append and conservative pricing admission are implemented.
- Phase 3D may land without streaming/SSE forwarding, aggregate response-spool/socket admission, compressed non-streaming decode-to-identity, or mutable upstream invalid-credential state; those remain required before Phase 4 can claim conformance.
- Phase 3E may land without streaming/SSE forwarding, compressed non-streaming decode-to-identity, or mutable upstream invalid-credential state; those remain required before Phase 4 can claim conformance.
- Phase 3F may land without streaming/SSE forwarding, mutable upstream invalid-credential state, or fake/real conformance journeys; those remain required before Phase 4 can claim conformance.
- Phase 3G may land without live incremental SSE flushing, disconnect cancellation, mutable upstream invalid-credential state, or fake/real conformance journeys; those remain required before Phase 4 can claim conformance.
- Phase 3H may land without fully incremental upstream socket relay, mutable upstream invalid-credential state, or fake/real conformance journeys; those remain required before Phase 4 can claim conformance.
- Phase 4 must not claim production readiness until Phases 1-3 are implemented and the signed real-gateway journey exists.

## Non-goals

- Do not create a public gateway, shared daemon, background login item, provider serving path, wallet session source, billing authority, settlement formula, model catalog authority, or provider payout rule.
- Do not add Linux, Windows, TLS-on-loopback, Unix-domain socket, or multi-user listener support.
- Do not implement extra `/v1` paths beyond those named by SPEC-045.

## Validation

For each slice, run local unit/integration tests that cover the slice's acceptance criteria plus the shared spec-governance checks:

- `git diff --check`
- `jq empty specs/AUTHORITY.json && jq empty specs/CONFORMANCE.json`
- `python3 scripts/gen_spec_index.py --check`
- `python3 scripts/gen_spec_index.py --lint`
- `python3 scripts/check_spec_governance.py --base-ref origin/main`
- `python3 -m unittest scripts.tests.test_spec_governance scripts.tests.test_spec_pr_declaration`

Audit each slice against its own implementation diff. Do not require reviewers to re-audit unrelated future-slice behavior.
