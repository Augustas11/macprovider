# AUDIT — Fix iss-191 (watchdog fleet-wide) — R1 ARCHITECT lane

## Scope

Same as CODE prompt — 8 files in
`/Users/augstar/macprovider-fix-191`. Read `git diff origin/main..HEAD`.

## Context

Same as CODE prompt. Key design choices to evaluate:

- **Inlined watchdog** (vs. shipping in the release tarball). The
  watchdog is duplicated between `ops/macprovider-watchdog/` and the
  inlined heredoc in `phase3-binary/dist/install.sh`. Adding it to
  the tarball would require updating the tarball allowlist + the
  build pipeline + the signing/notarization manifest. The duplication
  is deliberate but creates a drift risk.
- **netstat-based detection.** Catches only the half-open TCP wedge
  symptom from #189. The issue explicitly notes a different failure
  mode (TCP up but dropped from the `ready` pool) is NOT caught;
  added as future-work in OPS.md §11.
- **External LaunchAgent vs in-process bounded send (PR #204).**
  Both ship now. The in-process one is the primary detection; the
  external is belt-and-suspenders / catches future regressions.

## You are the ARCHITECT auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **0 C/H/M**.

Specifically check:

1. **Drift risk on duplicated watchdog body.** The standalone
   `ops/macprovider-watchdog/watchdog.sh` and the inlined
   heredoc in `install.sh:write_watchdog_script` must stay in
   sync. Is there a structural safeguard (test, CI check, lint
   rule) that catches a future edit-one-but-not-the-other? If not,
   what's the recommended minimal safeguard for this PR or a
   follow-up?
2. **Composability with in-process watchdog (PR #204).** The Swift
   in-process watchdog calls `Darwin.exit(1)` on stalled heartbeat
   liveness, relying on launchd's `KeepAlive` to respawn. The
   external watchdog calls `launchctl kickstart -k`. If both fire
   simultaneously, is the result deterministic, or can they race
   into a restart loop?
3. **Tolerance: 60s tick vs 90s coordinator drop.** The
   coordinator's `provider_inactive_threshold` is 90s. The watchdog
   ticks every 60s and kicks immediately on detection. Worst-case
   detection delay: 60s after the wedge starts. That's BELOW the
   coordinator drop — good. But the kick + relaunch + reconnect
   cycle itself takes 5-15s. Is the operator-visible recovery
   target acceptable? Document the target in OPS.md?
4. **Future-work signaling.** OPS.md §11 calls out the unsolved
   "coord-side drop while TCP ok" failure mode. Is this captured
   well enough that future readers find it and don't accidentally
   think the watchdog covers all wedge classes?
5. **Operator override.** `MACPROVIDER_NO_WATCHDOG=1` is the
   opt-out. Is the documented use case (expert / debug) clear,
   and does it interact correctly with `MACPROVIDER_NO_LAUNCHD=1`?
6. **Test coverage shape.** No automated tests for the watchdog
   scripts (shell smoke is hard). The diff includes a manual
   verification note (the author ran it locally and confirmed it
   correctly detected the healthy state). Is that the right
   coverage shape, or should a CI-level smoke test be added (e.g.
   `bash -n` in CI is already done for other scripts)?
7. **Uninstaller layering.** The main uninstaller now removes
   both the provider and the watchdog. The standalone
   `ops/macprovider-watchdog/uninstall.sh` exists for the
   case where the operator wants to remove the watchdog WITHOUT
   uninstalling the provider. Is that asymmetry documented and
   sensible?
8. **dist/ vs ops/ boundary.** The standalone scripts live in
   `ops/macprovider-watchdog/` (operator-facing). The inlined
   copy lives in `phase3-binary/dist/install.sh` (release-facing).
   Is the boundary clear? Should the inlined copy be generated
   from the standalone source at build time (e.g. via package.sh)
   to remove the drift risk?

Out of scope: anything outside the 8 files in the diff.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
