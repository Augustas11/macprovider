# Audit record R5 — BYOM signed-journey evidence tooling (#1248)

Fifth codex pass, branch on `origin/main` `8e04e035`, 2026-09-08. R4 resolutions (closed payload key set, duplicate-key rejection) verified by all three lanes.

| Lane | Verdict | Findings |
|---|---|---|
| architect | 0 C / 0 H / 0 M / 1 L / 0 I | LOW: single-label hostnames (carried). |
| security-reviewer | 0 C / 0 H / 0 M / 2 L / 0 I | LOW: captured-document redaction scanned serialized JSON text only, so JSON string escapes could hide a URL/path/hostname from the regexes; LOW: single-label hostnames (carried). |
| code-reviewer | 0 C / 0 H / 1 M / 1 L / 0 I | MEDIUM: `_validate_byom_journey_artifacts` only required the primary artifact id to be present, so a hand-signed BYOM payload could carry additional hash-bound artifact records (or extra fields on the one record) that nothing compares to the builder projection; LOW: single-label hostnames (carried). |

## Resolution (commit after this record)

- **MEDIUM (unbound artifact records):** BYOM validators now mirror the sibling journeys exactly: `signed.artifacts` must be exactly one object with exactly `{id, sha256, source}`, `id` equal to the reviewed artifact, `source` under the journey prefix; only then is the source re-validated. Tests `test_rejects_signed_payload_with_an_extra_artifact_record`, `test_rejects_signed_artifact_record_with_an_extra_field`. With keys, steps, observations, metadata, and artifacts all pinned to the builder projection, no field of a signed BYOM payload is left unbound to the source evidence.
- **LOW (escaped values):** `_digest_document()` now also walks the decoded JSON values through the shared redaction scan; test `test_rejects_captured_document_hiding_a_url_behind_json_escapes`.
- **LOW (single-label hostnames):** carried by design (see R3).

R6 closure re-run: see `AUDIT_1248_JOURNEY_EVIDENCE_R6.md`.
