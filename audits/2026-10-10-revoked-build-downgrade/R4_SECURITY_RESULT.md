# R4 (verification only) — SECURITY lane (omc ask codex)


H1 — FIXED — 4c3475ac3/e5af59e27: CoordinatorClient.swift:6387 executes authorization and synchronous mutation on the session actor; AutoUpdater.swift:1148 checks cancellation and policy before activation (:807) and restart (:873). No confirmed changed-line regression.
H2 — FIXED — 4c3475ac3: SelfUpdate.swift:433 rejects response-tag mismatch; :443 and :681 bind prepared provider version to that target, preserving the forward-only and policy checks at :260 and :264. No confirmed changed-line regression.
M1 — FIXED — e5af59e27: AutoUpdateMarker.swift:497 provides exclusive interprocess locking; :2623 locks policy read/merge/write; AutoUpdater.swift:1148 holds the same lock across final policy validation and activation/restart. No confirmed changed-line regression.
M2 — FIXED — 4c3475ac3: CoordinatorClient.swift:6337 restores local readiness and heartbeat for the held revoked session; :6447 reconciles before readiness finalization, and :6457 requires no pending transaction before retry. No confirmed changed-line regression.
C1 — FIXED — e5af59e27: CoordinatorClient.swift:2220 captures the restore epoch; :2251 gates error cleanup; :2554 rejects stale cleanup and :2559 advances the epoch on teardown. No confirmed changed-line regression.
C2 — FIXED — e5af59e27: AutoUpdateMarker.swift:2623 serializes persistence with AutoUpdater.swift:1148’s final policy-check/mutation boundary for both activation and restart. No confirmed changed-line regression.
VERDICT: C=0 H=0 M=0 L=0
