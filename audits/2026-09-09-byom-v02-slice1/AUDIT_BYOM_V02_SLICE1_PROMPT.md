# Audit — BYOM v0.2 slice 1: `openai_compatible_loopback` discovery adapter + hermetic discovery-journey driver (#1453)

METHOD CONSTRAINT: first-party software-correctness review. Do NOT author adversarial payloads. Evaluate by reading source and running the EXISTING tests (`cd phase3-binary && swift test --filter BYOM`, `make test-byom-discovery-journey`, `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_discovery_journey_driver scripts.tests.test_byom_journey_evidence`). Describe gaps abstractly (field + condition).

Review the COMPLETE diff `git diff origin/main...HEAD` on branch `feat/byom-v02-slice1-openai-compat-adapter`. Every file.

## What the change does
1. Adds the SPEC-046-R002 `openai_compatible_loopback` discovery adapter to the Swift CLI: operator-supplied loopback origin only (`--openai-compatible-origin`, no default), `GET /v1/models` through the SHARED safety layer (`BYOMLoopbackOriginValidator`, `BYOMDiscoveryHTTPBounds`, `BYOMURLSessionHTTPClient`, strict parser, `isSafeRuntimeModelReference`), producing candidates with `identity_state: opaque_endpoint`, `locality: opaque_local_endpoint`, `catalog_model_key: null`, null capabilities, a local non-earning admission state, and the closed warning codes. Evaluation reuses the existing chat-completions path.
2. Adds `test/e2e/byom/run-discovery-journey.py`: a hermetic driver that executes all ten `JOURNEY-PROVIDER-BYOM-DISCOVERY` steps against loopback stubs and emits `run-manifest.json` (`macprovider.byom-journey-run.v1`) + captured CLI documents, wired as `make test-byom-discovery-journey` which also runs capture → build → preflight from `scripts/`.

## Invariants to verify (challenge them)
- Gate #1246: the adapter reimplements NO URL admission, redirect policy, redaction, parser bound, or timeout logic; every rejection/bound in the #1446 matrix holds for the new origin flag; the origin never appears in JSON, stderr, warnings, or captured documents.
- SPEC-046-R003 closed schema: no new fields; every enum value used exists in the spec; `candidate_id` construction unchanged; opaque candidates cannot reach `catalog_model_key`, `catalog_matched`, or any earning path; provider_guidance is truthful and localization-safe.
- Model ids from `/v1/models` are untrusted: host/IP/path/credential-shaped ids are redacted through the shared guard, never emitted raw; nesting/size bounds apply.
- The absent flag means the adapter is not attempted (no default origin, no probing, no port scan).
- Driver truthfulness: every manifest observation is set from the driver's OWN checks, not hardcoded; step assertions and captured documents contain no URL/absolute path/hostname/IP/localhost/credential (capture's scanner must pass on real output); mutation checks actually hash the fixture dirs; step-04 asserts the stub received zero requests; step-10 reaches `local_only`/`offerable`/`not_offered` through the CLI's real ladder.
- The driver cannot be used to fabricate evidence: it does not accept overrides for observations or step statuses; failed steps fail the run.
- CI wiring: the new target runs where `test-byom-e2e` runs; no path-detection gap.
- Old-client compatibility: no wire/schema change for existing adapters; `models list`/browse unchanged.

## Lanes to report (this pass is: {{LANE}})
Report CRITICAL / HIGH / MEDIUM / LOW / INFO; merge bar 0 C / 0 H / 0 M.
- code-reviewer: adapter correctness vs the Ollama adapter; envelope exactness; test adequacy (do tests assert the pre-conditions, not just happy paths?); driver correctness and manifest shape vs the golden fixture and `byom_journey_evidence.py` contract.
- security-reviewer: SSRF/loopback escape via the new flag; redaction of endpoint/model ids; evidence-fabrication paths in the driver; secrets in stubs/fixtures.
- architect: harness reuse vs duplication; whether the driver is the right seam for physical runs later; CI/Makefile placement; runbook accuracy.

End with `VERDICT: <N> CRITICAL / <N> HIGH / <N> MEDIUM / <N> LOW / <N> INFO`. Cite file:line. Do not invent issues to fill a lane.
