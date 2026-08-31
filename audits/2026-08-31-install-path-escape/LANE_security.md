# Audit lane: SECURITY — fresh-install escaped-artifact-path fix (1.8.117)

Independent security auditor. Review the COMPLETE diff at
`audits/2026-08-31-install-path-escape/full-fix.diff` plus touched files.

Focus:
1. Injection: install.sh now unescapes `\/`→`/` in config values that are later
   used as an absolute path (`case "$p" in /*)`) and passed onward. Can a
   crafted config value (the config is written by the CLI, mode 0600, but assume
   an attacker who can influence the model catalog / artifact path) inject a
   path traversal, command substitution, or absolute-path bypass via the
   unescape? Does unescaping WEAKEN any existing validation of the artifact path
   (signature/sha pinning, path canonicalization) done later in install.sh?
2. ConfigApplier `.withoutEscapingSlashes`: does emitting literal slashes in a
   JSON-quoted YAML scalar allow YAML injection (breaking out of the quoted
   string, injecting new keys)? Confirm quoting still escapes `"` and control
   chars.
3. Confirm the fix does not change trust/attestation, the artifact sha256
   verification, or Gatekeeper/notarization checks — only the path string
   serialization/parsing.
4. No secrets/tokens exposed by the change.

Per finding: SEVERITY, file:line, concrete exploit scenario, fix. End with
`GATE: PASS` (0 C/H/M) or `GATE: FAIL`.
