# Audit lane: ARCHITECTURE / COMPLETENESS — escaped-artifact-path fix (1.8.117)

Independent architecture auditor. Review the COMPLETE diff at
`audits/2026-08-31-install-path-escape/full-fix.diff` plus touched files.

Focus:
1. Right layer / completeness: the fix touches BOTH the writer (ConfigApplier)
   and the reader (install.sh read-back). Are there OTHER serializers that write
   config paths (e.g. semantic_merge_config, other CLI config writers) that
   still slash-escape? Are there OTHER install.sh read-back sites of
   model_artifact_path/model/catalog that were missed and would still fail?
   Sweep both sides.
2. Is `.withoutEscapingSlashes` the correct minimal root fix, or does the real
   bug indicate the config should not be JSON-encoding YAML scalars at all?
   Judge whether the chosen fix is durable vs a future regression.
3. Back/forward compatibility across CLI/app versions and the fleet: an old CLI
   (escaped) + new install.sh (unescapes) works; new CLI (plain) + old
   install.sh — does that combination occur in any real path, and does it still
   work? The app pins the pkg version; confirm the release story is coherent.
4. Test adequacy for the fix.

Per finding: SEVERITY, file:line, concrete scenario, remediation. End with
`GATE: PASS` (0 C/H/M) or `GATE: FAIL`.
