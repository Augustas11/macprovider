# SPEC-015 Acceptance Runner

This directory is the CI lock gate for SPEC-015 §14.

Run the full Step 11 acceptance script from the repository root with:

```sh
bash test/integration/spec015/run_acceptance.sh
```

The script executes the per-AC Go, Swift, gateway, coordinator, SDK,
and nginx checks used by the `spec-015-acceptance` CI job. The Go tests
in this package also validate that AC-1 through AC-17 remain represented
with deterministic commands, CI jobs, and concrete evidence anchors.
