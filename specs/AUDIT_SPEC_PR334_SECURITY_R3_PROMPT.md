# AUDIT R3 — PR #334 SECURITY lane

Re-audit after R2. R2 flagged 1 MEDIUM (nonce-on-disk). Verify closed
and no regression. Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`).

R2 findings file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-r2-pr-334-security-lane-re-audit-after-the-r1-fix-pass-2026-07-03T07-10-29-043Z.md`

## R2 finding to verify closed

- **R2 S1-R2 (MEDIUM)** — Pending deep-link nonce was persisted to
  `~/Library/Application Support/Malibu/pending-link.state` with chmod
  0600. Same-user malware could read the file and replay the callback.
  Fix in
  `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`:
  the nonce is now held **only in a static process-lifetime variable**
  guarded by `NSLock`. No filesystem writes remain. `.file` was replaced
  with an in-memory `Pending` struct; `beginLink` sets it, `consume`
  takes+clears atomically, `discard` clears.
  UX trade-off: an app restart during the ~15 min link window forfeits
  the nonce and the user has to click "Continue in browser" again.

## Focus for this pass

1. Verify `pending-link.state` file is no longer created anywhere:
   - Grep the diff for `pending-link.state` / file writes in
     `PendingLinkState.swift`. Expect zero.
2. Static-var + NSLock — Sendable / thread-safety review:
   - Multiple concurrent `beginLink` calls: last-write-wins on the
     `Pending`. Previous nonce is discarded; is there a scenario
     where the discard is a security issue? Only if the user has two
     link flows going simultaneously.
   - Concurrent `beginLink` + `consume`: the lock serializes
     read-modify-write. Safe.
3. Process-lifetime memory secrecy — the nonce is in the app's heap.
   A same-user attacker who can attach a debugger to the Malibu.app
   process can still read heap memory. macOS taskgated + SIP protect
   most cases. Realistic residual risk? (Note: this is fundamentally
   what "in process memory" means — anything is exposed to a process
   with debugger privileges. Same-user malware would need to bypass
   the taskgated policy first.)
4. The R1 fixes (S1-S7) — recheck each is still intact after the R2
   churn on ControlSocketClient, MalibuApp, MalibuAgent:
   - S1 (deep-link nonce gate): still in place, now stronger.
   - S2 (unsetenv token): unchanged.
   - S3 (uninstall await): unchanged; `performUninstall` still awaits
     `agent.shutdown` first.
   - S4 (managed_by skip): unchanged in CoordinatorClient.
   - S5 (Keychain WhenUnlocked): unchanged in KeychainStore.
   - S6 (entitlements): unchanged in Malibu.entitlements.
   - S7 (login-item error surfaced): unchanged.
5. New `applicationShouldTerminate` path — does it expose any
   security-relevant window? During the 15-second graceful shutdown
   between the OS asking us to quit and NSApp.reply, the child CLI is
   sent shutdown_request and then SIGTERM/SIGKILL. Nothing sensitive
   flows in that window that wasn't already there.
6. `PendingLinkState` fallback branch — if `SecRandomCopyBytes` fails
   we fall back to `UInt8.random(in: 0...255)` which is not CS-random.
   Attackers cannot cause SecRandom to fail from user-space; this is
   a defense-in-depth branch. Confirm not exploitable.

## Skip

- Everything already skipped in R1/R2.
- LOW/INFO items and the SPEC-025 drift ledger (A9).

## Output format

Same as R1/R2 (S<n>, File, Risk, Attack scenario, Fix). Return
`0 CRITICAL, 0 HIGH, 0 MEDIUM` on convergence.
