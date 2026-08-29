# Adversarial review — RFC-001 watchdog architecture

You are an adversarial reviewer. Read `docs/rfcs/RFC-001-watchdog-architecture.md`
in this repo and attack it. This is a design RFC (issue #1203), not code; your job
is to find where its reasoning, recommendation, migration plan, or telemetry
requirements are wrong, incomplete, or unsafe — before it guides a code PR.

## Grounding (verify against code, do not trust the RFC's own citations blindly)
- Current watchdog: `ops/macprovider-watchdog/watchdog.sh`,
  `ops/macprovider-watchdog/live.malibu.provider-watchdog.template.plist`.
- Landed prior work the RFC assumes: PR #1208 commit `aee7d157` (Repair recovers
  stale watchdog + HOME ACL), PR #1228 commit `16b0fa4d` (watchdog no longer owns
  update/rollback). Confirm these actually did what the RFC claims.
- Provider launchd/install path: `phase3-binary/dist/install.sh`
  (`MACPROVIDER_REPAIR_EXISTING_INSTALL=1`), and its test
  `phase3-binary/dist/test/provider_upgrade_transaction.test.sh`.
- SPEC-020 (provider autoupdate) is the normative surface for update/rollback
  ownership and any staged-rollout non-goals.

## Attack these specific claims (each is a potential defect if wrong)
1. **"launchd KeepAlive cannot detect a wedged-but-alive provider (J1)."** Is that
   true? Is there any KeepAlive sub-key, WatchPaths/QueueDirectories, or
   launchd mechanism that could observe `/v1/health` or an app-advanced liveness
   token and restart on wedge — making Option B viable and the recommendation
   wrong?
2. **"An out-of-process prober is architecturally necessary" (constraints 1–2).**
   Is the self-supervision-paradox argument sound, or could a supervisor thread
   inside the provider + launchd KeepAlive-on-exit cover the wedge case (provider
   self-exits on internal watchdog trip)?
3. **The split (launchd owns exit-restart J2, prober owns wedge-restart J1).**
   Does moving J2 to launchd KeepAlive collide with J3/J4 cold-load grace or J5
   operator-pause? Concretely: after a reboot, does KeepAlive restart-on-exit
   race the boot-arming/lease logic and kill a legitimate 10–20 min cold load?
   Does operator-pause require the provider to *exit* (so KeepAlive would fight
   the pause)?
4. **Migration (§6).** Is bootout-legacy-then-bootstrap-new actually free of a
   double-kick window or a no-supervisor window? Could a reboot mid-migration
   strand a node? Is "ship via Repair path" sufficient for homes where Malibu.app
   cannot launch at all?
5. **Telemetry (§7).** Are the proposed events sufficient to *prove* recovery, or
   is there a silent-failure the events would miss (e.g., a node that flaps
   restart→wedge→restart looks identical to healthy in aggregate)?
6. **Scope creep / SPEC conflict.** Does the recommendation implicitly require a
   SPEC-020 change (e.g., staged rollout is a stated non-goal)? Does it loosen any
   signed-artifact integrity binding? Flag anything that is a spec change dressed
   as an architecture note.

## Output
- Findings as CRITICAL / HIGH / MEDIUM / LOW / INFO, each with: the exact RFC
  claim, why it's wrong/incomplete, code/spec evidence (`file:line`), and the
  minimal fix to the RFC.
- Explicitly answer: **is the recommended architecture (§5) correct, or should a
  different option win?** If you would change the recommendation, say to what and
  why.
- Do not propose loosening any trust/integrity gate. Improve correctness of the
  design reasoning, not the security posture.
