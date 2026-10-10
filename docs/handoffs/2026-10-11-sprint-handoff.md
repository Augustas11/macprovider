# Handoff 2026-10-11 — sprint close before operator travel

Written 2026-10-11 ~23:30Z. Live state, merged work and open items, so the next
session starts from facts rather than memory.

## Live in production

- Coordinator runtime **v1.8.239**: repository admission with 42 exact
  revocations (#1919); calendar-expiry removal, coordinator side (#1944);
  settlement-evidence retention ON by default (#1909; first nightly run
  03:00 UTC, not yet observed); pool-proven maintained rollup (#1950,
  snapshot builds); BYOM catalog graduation (#1945); log level honoured
  (#1942); on-call digest loaded; `pool.max_concurrency_ceiling` 32.
- Provider CLI **1.8.240** recommended fleet-wide (train complete: mirror and
  installer updated). Carries #1927 (MLX 3.32.3), #1947 (CB on by default,
  per-Mac self-check), #1946 (revoked-build rollback lever), #1944 (no expiry),
  #1956 (native-MTP admission survives restarts).
- Native-MTP release `published-2026-10-10-native-mtp-v238` active; the
  coordinator native-MTP canary **passes** against the re-baselined bank.
  Native MTP engages only at batch depth 1 (`max_native_active_rows: 1`), so
  under full runner load it is gated by design.
- Privacy release identities come from signed release metadata
  (`privacy_release_setup` done); no hand-added cdhash needed for new builds.
- Pearl disk: about 100G used of 242G; updater keeps 1 rollback snapshot.
- On-call readiness record for `production` signed and live.
- Buyer runner: about 1.8M tokens/hour (17:50–18:50Z), thermal back-off live.

## Merged to main, not yet released

Ship with the **next CLI release** (provider side):
- #1953 hybrid 16-step decode window
- #1960 CB self-check grants above 16 slots (**must not ship without #1974**)
- #1962 native-MTP canary visibility (provider log line)
- #1964 gpt-oss stop strings scoped to visible text (#1949)
- #1965 watchdog grace after an operator-pause resume (#1961)
- #1966 non-streaming decode stops at the buyer stop string (#1948)
- #1968 App Attest auto-trust: Malibu.app signing + CLI challenge/submit

Ship with the **next Pearl runtime release** (coordinator side):
- #1962 canary visibility (logs, `/admin/providers` field)
- #1967 privacy slot-aware selection and fair share (#1911)
- #1968 App Attest verifier fix (corrupt Apple root replaced), challenge/submit
  endpoints, recorder writes

Also merged: #1963 (privacy evidence scanner, #1959), the #1952 test fix
(direct to main).

## Open — needs the operator

1. **PR #1974 decode isolation** (CB-throughput session): per-forward decode
   row bound (Ultra 11, M3+ 12, M1/M2 non-Ultra 5), verify token bound,
   isolation by route class; R015 formal PASS on the final build; three-lane
   audit clean. Being rebased to SPEC-038 v0.3.18. **Merging needs operator
   approval.** It is a hard dependency of #1960's grants above 11: on the
   Studio a decode forward with 12+ rows flips buyer tokens (qmv→qmm).
2. **Next CLI release is PARKED** until the operator resumes work. When
   resumed and #1974 is merged: freeze main, the CB session runs its isolated
   e2e of the exact main SHA (two windows ≤25 min), then cut through
   `scripts/ops/cli-release.sh` one step at a time; Studio canary in an
   announced window. Plan and table: `docs/releases/cli-release-train.md`
   "Next CLI release".
3. **#1968 deploy** (after merge, before or with the runtime release):
   `pearl-runtime.sh` one-time step `app_attest_recorder` (no downtime; the
   admin DSN needs superuser or SET on logging parameters); add the two
   `location = /v1/providers/app-attest…` nginx blocks by hand
   (`nginx -t && systemctl reload nginx`); then the runtime release; then the
   post-cut e2e on the Studio (macOS 27, signed Developer ID Malibu.app) — the
   first live App Attest proof.
4. **#1955** production pool root / `production_activation` / public listing:
   blocked on a hardware-backed key.

## Open issues (tracked)

- #1971 CB self-check exactness probe too weak above the device's vector
  limit (take after #1974 lands). Lab evidence: on uncapped main the self-check
  granted 16 while a 16-row forward flips 30–38/256 tokens; #1974's capped build
  shows 0 divergent rows.
- #1972 hardware-trust bootstrap SQL refusals don't fail (`\quit 3`).
- #1973 flaky `TestAutotuneAdmissionCapV2GateOffUsesSingleObserveLookup`
  (test-only; fix goes straight to main).
- #1911 remaining: code-bound posture key, key rotation, pool privacy,
  real reject reason logging.
- #1793 Postgres money datastore: measure DB growth with retention first.

## Checks for the next session

- Retention's first nightly run (03:00 UTC): coordinator journal and
  `coordinator.db` size (18.0 GB before, 7.2 GB audit DB).
- After the runtime release: >1 enrolled provider serving private traffic
  through the gateway (#1967 live proof).
- Release rules learned this sprint: freeze main during a cut; run each
  release-train step by hand (no wrapper loops); merge PRs through one serial
  queue; don't push docs to main while PRs are merging.
