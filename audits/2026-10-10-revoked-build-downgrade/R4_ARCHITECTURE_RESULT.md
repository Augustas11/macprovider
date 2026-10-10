# R4 (verification only) — ARCHITECTURE lane (omc ask codex)


H1 — FIXED — 4c3475ac3: CoordinatorClient.swift:6337 restores local readiness and keepalive; :6447 reconciles before restoration health proof, then :6457 requires transaction retirement before retry. Update-only revocation remains intact. No regression identified in changed lines.

M1 — PARTIAL — 4c3475ac3: scripts/ops/cli-release.sh:423–429 rejects a suffix differing from the remote tag commit before mutation or completion, but never verifies P’s signed compatibility manifest or compares its full compatibility ID. The required signed-identity check remains missing. No additional regression identified in changed lines.

M2 — FIXED — 4c3475ac3: scripts/ops/cli-release.sh:420–421 includes the requested V revocation in pending-edit evaluation; :439 retains mismatch refusal. scripts/ops/test-entrypoints.sh:739–755 covers config installation followed by resumed `next --run`. No regression identified in changed lines.

C1 — FIXED — e5af59e27: CoordinatorClient.swift:2220 captures the restore epoch; :2251 gates error cleanup; :2554 checks it before teardown, whose :2559 increments the epoch. No regression identified in changed lines.

C2 — FIXED — e5af59e27: AutoUpdateMarker.swift:497 provides the exclusive policy lock; :2623 serializes read-merge-write. AutoUpdater.swift:1148–1159 holds that lock across final policy authorization and activation/restart. No regression identified in changed lines.

VERDICT: C=0 H=0 M=1 L=0
