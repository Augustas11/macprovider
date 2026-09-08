# Audit record R4 — BYOM signed-journey evidence tooling (#1248)

Fourth codex pass, branch on `origin/main` `49e71210`, 2026-09-08. R3 resolutions (captured-document schema check, manifest-relative path confinement) verified by all three lanes.

| Lane | Verdict | Findings |
|---|---|---|
| architect | 0 C / 0 H / 0 M / 2 L / 0 I | LOW: captured CLI documents parsed with plain `json.loads` (duplicate keys last-wins) while committed evidence uses the duplicate-rejecting hook; LOW: single-label hostnames (carried). |
| security-reviewer | 0 C / 0 H / 0 M / 2 L / 0 I | Same two LOWs. |
| code-reviewer | 0 C / 0 H / 1 M / 1 L / 0 I | MEDIUM: the generic signed-result schema permits optional fields (`harness`, `config_before`, `candidate`, `candidate_identity`, `eip712`, `signer`) that BYOM source re-validation never binds to the evidence, so a hand-signed BYOM payload could carry unbound, unscanned data; LOW: single-label hostnames (carried). |

## Resolution (commit after this record)

- **MEDIUM (unbound optional keys):** `BYOM_JOURNEY_RESULT_PAYLOAD_KEYS` in `scripts/byom_journey_evidence.py` is the single closed key set; the builder asserts its own output equals it, and `_validate_byom_journey_source` in `scripts/check_spec_governance.py` rejects any signed BYOM payload whose key set is not exactly that set (extra or missing) before source comparison. Tests: `test_rejects_signed_payload_carrying_generic_optional_fields` (six optional keys), `test_rejects_signed_payload_missing_a_builder_key`. The governance-source test helper now emits the real signed shape (with `schema_version`, as the signer requires).
- **LOW (duplicate JSON keys):** `_digest_document()` parses captured documents with `object_pairs_hook=_unique_json_object` and fails closed on `DuplicateJSONKeyError`; test `test_rejects_captured_document_with_duplicate_json_keys`.
- **LOW (single-label hostnames):** carried by design (see R3).

R5 re-run: see `AUDIT_1248_JOURNEY_EVIDENCE_R5.md`.
