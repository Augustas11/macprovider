# Audit lane: CODE CORRECTNESS — fresh-install escaped-artifact-path fix (1.8.117)

Independent code auditor. Review the COMPLETE diff at
`audits/2026-08-31-install-path-escape/full-fix.diff` plus the live files it
touches. Context: fresh installs died 30 "no paid model cleared" because
ConfigApplier.yamlScalar wrote `model_artifact_path: "\/Users\/..."` (JSON
slash-escaping of a space-quoted path) and install.sh's read-back could not
parse the escaped value (its `case "$p" in /*)` absolute-path check failed).

Focus:
1. ConfigApplier.swift `yamlScalar`: does `.withoutEscapingSlashes` correctly
   stop slash-escaping while still safely quoting values with spaces/specials?
   Are there inputs where the quoted output is now INVALID YAML or ambiguous
   (backslashes, quotes, control chars, unicode, leading/trailing spaces, `#`,
   `:`)? Confirm the CLI's own ConfigLoader still round-trips every case.
2. install.sh read-back: the awk `gsub(/\\\//, "/", value)` on
   read_config_{artifact_path,model,catalog_model_id}. Is the regex correct in
   POSIX awk (matches only literal backslash-slash)? Could it corrupt a
   legitimate value that contains a real backslash-then-slash that is NOT an
   escape? Are model/sha/donor read-backs consistent (sha is hex, model has
   plain slashes)? Any value that should be unescaped but is missed, or should
   NOT be unescaped but is?
3. Both-ends consistency: with the new CLI (plain slashes) AND an old CLI
   (escaped slashes), does the install read-back now succeed in BOTH? Any case
   where the fix flips a previously-passing install to failing?
4. Version bump correctness (binaryVersion / project.yml / release-builds.tsv).

Per finding: SEVERITY (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, concrete
failure scenario, fix. End with `GATE: PASS` (0 C/H/M) or `GATE: FAIL`.
