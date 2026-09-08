# Audit record R7 — BYOM signed-journey evidence tooling (#1248) — CLOSURE

Seventh codex pass, branch on `origin/main` `8e04e035`, 2026-09-08. R6 resolution (hostname exemption scoped to `$.harness.name`, no global allowlist) verified by all three lanes.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO |
| security-reviewer | 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO |
| architect | 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO |

Gate met. Carried by design (documented in R3, not re-reported since R5): single-label hostnames are not DNS-shaped and remain an operator redaction-review item in the runbook.

## Round summary

| Round | MEDIUM | Theme |
|---|---|---|
| R1 | 3 | builder trusted hand-authored evidence; captured docs scanned for credentials only; runbook signing command wrong |
| R2 | 2 | scanner narrower than the "any hostname / token-shaped" contract; governance did not re-open the source artifact |
| R3 | 1 | manifest-declared document schema not checked against parsed JSON |
| R4 | 1 | extra generic optional keys in a signed payload unbound to the source |
| R5 | 1 | extra artifact records unbound to the source |
| R6 | 1 | file-name allowlist applied globally by the hostname scanner |
| R7 | 0 | closure |

Lesson recorded: BYOM validators should have started from "signed payload is exactly the builder's closed projection" (sibling-validator parity) rather than field-by-field comparison; R5 made that structural and no further finding in that class appeared.
