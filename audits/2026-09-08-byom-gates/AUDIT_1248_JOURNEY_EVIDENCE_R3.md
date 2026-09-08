# Audit record R3 — BYOM signed-journey evidence tooling (#1248)

Third codex pass on the branch rebased onto `origin/main` `49e71210`, 2026-09-08. R1/R2 resolutions were verified by all three lanes.

| Lane | Verdict | Findings |
|---|---|---|
| architect | 0 C / 0 H / 0 M / 0 L / 0 I | Clean; R2 resolutions confirmed. |
| security-reviewer | 0 C / 0 H / 0 M / 2 L / 0 I | LOW: raw document paths accepted absolute paths outside the manifest dir (digest/byte-count only, no bypass); LOW: shape-based hostname rule still cannot flag single-label hosts — inherent to any DNS-shape rule, carried. |
| code-reviewer | 0 C / 0 H / 1 M / 0 L / 0 I | MEDIUM: `_digest_document()` recorded the manifest-declared `schema` without checking the parsed captured JSON, so signed evidence could claim a step was backed by one CLI schema while the digested bytes were another document. |

## Resolution (commit after this record)

- **MEDIUM (schema trust):** `_digest_document()` now keeps the parsed value, requires a JSON object, and requires its top-level `schema` to equal the manifest entry's `schema`; tests `test_rejects_captured_document_whose_schema_differs_from_the_manifest`, `..._without_a_top_level_schema`, `..._that_is_not_a_json_object`.
- **LOW (path confinement):** document paths must be manifest-relative, no `..`, and must resolve under the manifest directory; tests `test_rejects_captured_document_with_an_absolute_path`, `..._path_escaping_the_manifest_directory`.
- **LOW (single-label hostnames):** carried. The scanner flags any `label.label…tld` shape, URLs, IPv4/IPv6 literals, localhost, absolute/home paths, and credential shapes; a bare single-label host name is indistinguishable from an ordinary word and is covered by the operator redaction review step in the runbook.

R4 re-run: see `AUDIT_1248_JOURNEY_EVIDENCE_R4.md`.
