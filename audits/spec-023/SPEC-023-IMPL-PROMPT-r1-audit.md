# SPEC-023 Implementation Prompt Audit — Round 1

Date: 2026-07-02

Scope: `specs/BUILD_SPEC_023_v0_1_IMPL_PROMPT.md`

Auditor lanes run: code, security, architect. No product-design lane was run.

## Verdict

NEEDS FIX PASS

| Lane | Critical | High | Medium | Low | Verdict |
| --- | ---: | ---: | ---: | ---: | --- |
| Code | 0 | 2 | 1 | 0 | NEEDS FIX PASS |
| Security | 0 | 1 | 0 | 0 | NEEDS FIX PASS |
| Architect | 0 | 0 | 0 | 0 | READY TO BUILD |

## Findings And Fixes Applied

### CODE-H1 — CLI rate-card fetch and baked fallback path missing

Severity: HIGH

The implementation prompt described the coordinator `GET /v1/rate-card` endpoint and rate-card lookup, but did not explicitly require the Swift CLI to fetch `https://coordinator.malibu.tech/v1/rate-card`, validate the schema, fall back to a baked snapshot, emit `rate_card_fallback_used`, persist `rate_card_version`, and test AC-5 fallback paths.

Fix applied: Slice B now requires a CLI rate-card input fetcher, schema validation, baked fallback on network/HTTP/malformed/schema/value failures, warning emission, stored `rate_card_version`, and tests for failed fetch plus schema-validation failure.

### CODE-H2 — Static JSON schema-validation fallback missing

Severity: HIGH

The implementation prompt required signature/freshness checks for `demand-rank.json` and `autotune-candidates.json`, but did not explicitly require schema validation before admitting fetched JSON. This could let a conforming implementer accept signed but invalid static inputs.

Fix applied: Slice B now requires schema validation for locked source, constants, timestamps, enum/range checks, required row fields, required metadata for downloadable rows, fallback warning emission on schema failure, and tests for AC-4/AC-6 schema-validation failure.

### CODE-M1 — Provider quota policy non-goal omitted

Severity: MEDIUM

SPEC-023 v0.1 treats `min_provider_target` as operator-planning metadata, not as a recommendation quota or live-provider-count policy. The prompt did not say this explicitly, leaving room for incompatible scoring or eligibility behavior.

Fix applied: Out-of-scope text now forbids provider quota/coverage allocation policy and live provider-count queries. Slice C now requires `min_provider_target` parse/preserve only and tests proving it does not affect v0.1 scoring or eligibility.

### SEC-H1 — Cache-poisoning guard not test-explicit

Severity: HIGH

The implementation prompt required benchmark status, binary identity, and catalog metadata, but did not explicitly require cached benchmark reuse to be fail-closed on all cache identity dimensions.

Fix applied: Slice C now requires cached benchmark reuse only when selected `candidate_catalog_sha256`, binary version, model ID, HMAC-derived hardware identity hash, and benchmark age all match, with negative tests for every mismatch and age greater than 7 days.

## Round 2 Requirement

Run the same three read-only audit lanes against the revised implementation prompt. Continue fixing and re-auditing until code, security, and architect all report 0 critical / 0 high / 0 medium findings.
