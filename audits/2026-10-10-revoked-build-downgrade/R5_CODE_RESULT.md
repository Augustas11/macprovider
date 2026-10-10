# R5 (verification only) — CODE lane (omc ask codex)


F1 — PARTIAL — The post-eviction restart assertion and both abort-event assertions detect removal of their respective protections (phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2404,2419–2422). However, removing the post-drain authorization check at AutoUpdater.swift:475 leaves the drain test passing: the activation gate refuses later, clears pending state, and emits the same reason. Assert the pre-backup refusal path and absence of backup creation.

F2 — FIXED — Signature verification uses the train’s key and SHA-256; validated metadata yields the full identity, compared before mutation and before reporting done (scripts/ops/cli-release.sh:418–432,477–503). The signed-identity mismatch test exercises refusal (scripts/ops/test-entrypoints.sh:776–779).

LOW — phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2402 — Pending-state assertion is vacuous: the helper’s TempHome is destroyed on return, deleting the files; readPending returns nil for a missing path — retain the fixture through assertions or inspect pending state inside the helper.

LOW — scripts/ops/test-entrypoints.sh:781 — Appending another JSON object makes the tampered metadata invalid JSON. Removing signature verification would still produce parser refusal, so this test cannot prove signature enforcement — modify a field while preserving valid JSON and retain the original signature.

VERDICT: C=0 H=0 M=1 L=2
