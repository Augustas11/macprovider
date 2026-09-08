# Audit — BYOM signed-journey evidence tooling (#1248, parent #1240)

METHOD CONSTRAINT (read first): this is a first-party software-correctness and governance-proof review. Do NOT author or construct malformed/adversarial payloads. Evaluate by reading source and running the EXISTING tests (`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_byom_journey_evidence`, `python3 scripts/check_spec_governance.py`). Describe any gap abstractly (field + condition) in prose.

Review the COMPLETE diff of this branch as it will land: `git diff origin/main...HEAD` (4 commits on `feat/1248-byom-journey-evidence`). Review every file.

## What the change does
Epic gate #1248 requires `JOURNEY-PROVIDER-BYOM-DISCOVERY` and `JOURNEY-NETWORK-MODEL-ADMISSION` signed evidence through the repo governance path before SPEC-046/047 conformance promotion. Today those journeys have contracts in `journeys/*.md` but no capture/build tooling and no governance registration. This branch adds:
- `scripts/byom_journey_evidence.py` — shared contract: journey tables, redaction scanner, run-manifest → redacted evidence, evidence → journey-result payload.
- `scripts/capture-byom-journey-evidence.py`, `scripts/build-byom-discovery-journey-result.py`, `scripts/build-network-model-admission-journey-result.py`.
- Registration of both journey ids and their step ids / requirement mapping / evidence schemas in `scripts/check_spec_governance.py`.
- Golden fixtures + 36 unit tests (`scripts/tests/test_byom_journey_evidence.py`), wired into `make test-dist`.
- `docs/runbooks/byom-journey-evidence.md` operator sequence (capture → build → sign with the acceptance key → preflight → promote → reconcile).
It does NOT touch `specs/CONFORMANCE.json` states or evidence, nor the SPEC texts, and does not sign anything.

## Invariants to verify (challenge them)
- Step ids and execution modes come verbatim from `journeys/JOURNEY-PROVIDER-BYOM-DISCOVERY.md` and `journeys/JOURNEY-NETWORK-MODEL-ADMISSION.md`; a manifest missing ANY normative step must be rejected (a partial hermetic run cannot yield promotable evidence).
- Per-step → requirement-id mapping is derived from SPEC-046 §3 / SPEC-047 §3; the union must cover all eight requirements per spec or capture fails. Check the mapping is faithful, not padded.
- `observations.money_path_zero_rows` (ten coordinator tables) must be integer 0 each; `False`/strings/missing must be rejected.
- Redaction: evidence must fail closed on any URL, absolute path, token-shaped string, or hostname; digests only, never captured CLI documents.
- Nothing here can promote a requirement or write evidence rows without a valid signature verified against `security/acceptance-candidate-signing-public.pem` via the existing `promote-signed-journey-result.py` path; the new builders must not create a bypass.
- No secrets, no key material, no new dependencies (stdlib only), noninteractive for CI.
- `check_spec_governance.py` changes must not weaken validation of the pre-existing journeys (run the neighbouring `scripts.tests.test_*journey*` suites).

## Lanes to report (this pass is: {{LANE}})
Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO. The merge bar is 0 CRITICAL, 0 HIGH, 0 MEDIUM.

- CODE: correctness of manifest→evidence→payload transforms; schema validity against `JOURNEY_RESULT_PAYLOAD_SCHEMA`; error paths; test adequacy (do the 36 tests actually exercise rejection paths, or only happy paths?); Makefile wiring.
- SECURITY: redaction completeness; any path by which unsigned or partial evidence becomes promotable; signature/key-id/fingerprint handling in the builders; injection via manifest fields into governance output; secret handling in the runbook.
- ARCHITECTURE: single source of truth for step ids / requirement mappings (duplicated between `byom_journey_evidence.py` and `check_spec_governance.py`?); consistency with the sibling builders (prebeta, local-consumer-endpoint); whether `environment.class` (hermetic-loopback vs physical-provider) is the right seam; drift between journey contracts and tooling.

End with a line `VERDICT: <N> CRITICAL / <N> HIGH / <N> MEDIUM / <N> LOW / <N> INFO`. Be specific: cite file:line. Do not invent issues to fill a lane.
