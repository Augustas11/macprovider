# Audit record R6 — BYOM signed-journey evidence tooling (#1248)

Sixth codex pass, branch on `origin/main` `8e04e035`, 2026-09-08. R5 resolutions (single builder artifact record, decoded-value scan) verified by all three lanes.

| Lane | Verdict | Findings |
|---|---|---|
| architect | 0 C / 0 H / 0 M / 0 L / 0 I | Clean. |
| security-reviewer | 0 C / 0 H / 0 M / 0 L / 0 I | Clean. |
| code-reviewer | 0 C / 0 H / 1 M / 0 L / 0 I | MEDIUM: the file-name allowlist (`.go/.json/.md/.py/.sh/...`) was applied globally by the hostname scanner, so a DNS-shaped token whose final label is also a file extension (`provider-mac.sh`, `coordinator.md`) passed in any assertion or captured value, contradicting the "any DNS-shaped token" contract. |

## Resolution (commit after this record)

- **MEDIUM (global allowlist):** the global allowlist is removed; `reject_hostname_like_text` rejects every DNS-shaped token. Repository source file names are accepted only at the structurally validated JSON paths in `REPO_SOURCE_FILE_FIELDS` (`$.harness.name`), through `reject_unredacted_repo_source_file`, which still runs the secret/URL/path scans and requires a repository-relative file name with a known extension and no `..`. Tests: `test_file_name_shapes_are_hostnames_everywhere_except_the_harness_name_field`, `test_harness_name_field_still_requires_a_repository_source_file_name`, `test_a_file_name_shape_in_a_captured_document_value_fails_closed`; the capture-level acceptance test no longer places a file name inside a step assertion (that is now correctly rejected). Runbook redaction posture updated.
- Single-label hostnames LOW: carried by design (R3); not re-reported by any R6 lane.

R7 closure re-run: see `AUDIT_1248_JOURNEY_EVIDENCE_R7.md`.
