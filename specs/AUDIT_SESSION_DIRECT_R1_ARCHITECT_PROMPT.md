# Session direct-push audit R1 — ARCHITECT lane

You are the **architect** lane of a three-lane audit (code / security /
architect) of the six direct-push commits landed in this working session
while smoke-testing Malibu.app onboarding through v1.8.5 → v1.8.9. The
bar for convergence is **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** across
all three lanes.

## Scope

Direct pushes to `main`, in order:

| Commit | Version | Intent |
|--------|---------|--------|
| `0495fd9` | v1.8.5 | Persist coord URL to `config.yaml`; new `FreePortProbe`, `MalibuOnboardingTimeouts`; LaunchProviderController wiring |
| `a97c236` | v1.8.6 | Wire CLI-side SPEC-026 §7 `identity_signature` handshake (new `CanonicalJSON` + `IdentitySignatureBridge`, control-socket frames, transcript SHA-256) |
| `23b3504` | v1.8.7 | Bridge timeout 30 s → 3 s |
| `4a5165a` | v1.8.8 | Pusher bypasses `ControlSocketConnection` actor via `writeFrameDirect(fd:frame:)` |
| `6cd2bfe` | v1.8.9 | Accept `"ready"` OR `"serving"` in Malibu state consumer |
| `c1d8be9` | (patch) | Strip debug prints |

Per-commit patches: `audits/2026-07-05/session-direct-r1/patch-0{1..6}-*.diff`.

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. IdentitySignatureBridge as a coupling primitive

The bridge is a public actor sitting between `CoordinatorClient` (CLI
network) and `ControlSocketServer` (CLI ↔ App IPC). It exists because
only the App has the identity key, and only the CLI has the coordinator
WS connection.

- Is the bridge the right abstraction, or a shortcut that hides a
  bigger design smell (e.g. the CLI should ask the App to sign proofs
  via a synchronous RPC instead of an out-of-band bridge)?
- What breaks if the App reconnects (new ControlSocketConnection) mid-
  auth? The bridge holds a `CheckedContinuation` from `requestSignature`
  and yields to an `AsyncStream` of subscribers. Trace the reconnect
  path.
- Contract clarity: `subscribe()` returns `(id, AsyncStream)`. Who owns
  cleanup of stale subscribers? Is there a memory leak surface if a
  subscriber terminates without unsubscribing?

### ARCH-2. Actor bypass — is it the right long-term design?

v1.8.8's fix bypassed the `ControlSocketConnection` actor because a
blocking `Darwin.read()` inside the actor held the serial queue and
starved the pusher's `send()`. The chosen fix: `Task.detached` +
`writeFrameDirect(fd:frame:)` writing to raw fd.

- Is this the ONLY read/write pair on the actor that has this
  problem? If yes, the targeted bypass is fine. If no, the architecture
  is broken (an actor whose serial queue can be held by blocking
  syscalls is not really giving you actor isolation) and the bypass is
  a workaround that will bite again the next time someone adds an
  async writer.
- Alternative designs to evaluate briefly:
  - Move receive off the actor entirely (dedicated read `Task`).
  - Use non-blocking I/O + `select`/`kqueue` instead of blocking read.
  - Split receive-actor and send-actor.
  Rank these vs the current bypass by (safety, complexity, test surface).
- Is there a comment in `ControlSocket.swift` warning future editors
  NOT to add another actor-async writer without first checking the
  bypass invariants? If not, high risk of regression.

### ARCH-3. State-name compatibility (v1.8.9)

The v1.8.9 fix accepts `"ready" || "serving"` on the App side because
the CLI's `SwapState` has `.loading / .ready / .draining` — no
`.serving`.

- This is a naming-drift symptom: CLI internally says `.ready`, App
  externally says `.serving`, coordinator (per Pearl journalctl)
  emits `state:"ready"`. Is there a canonical vocabulary defined in
  a SPEC? If yes, which side violates it? If no, that's the finding.
- Long-term: should the CLI rename its enum (`.ready → .serving`),
  should the App rename its consumer (`.serving → .ready`), or should
  there be a translation layer at the frame boundary? Recommend one.
- Discoverability: how would a new engineer learn that the frame
  carries `"ready"` but internal states elsewhere call the same thing
  `"serving"`? A grep-hostile pair like this is a design debt.

### ARCH-4. Timeout hierarchy

New file `MalibuOnboardingTimeouts` centralizes onboarding timeouts:

- `controlSocketConnectSec = 300`
- `firstServingFrameSec = 600`
- CLI-side bridge timeout: `identitySignatureTimeoutSeconds = 3`

Plus the coordinator side runs a ~10 s auth window. Are these
consistent? Rank each timeout against what happens if it fires:

- 3 s bridge timeout → CLI proceeds without signature → coordinator
  4003 → onboarding retries? Or hangs?
- 300 s control-socket connect timeout → onboarding fails after 5 min.
  Reasonable for fresh install (CLI download included). Verify.
- 600 s first-serving-frame timeout → onboarding fails after 10 min.
  This is where model download + autotune sits; the earlier PR #396
  raised autotune to 7260 s. Does 600 s cover the 7260 s autotune?
  If NOT, the timeout will fire and kill onboarding mid-autotune.
- Are all these values defined in ONE place or scattered?

### ARCH-5. Config persistence contract

`ProviderConfig.saveProviderIdentity(...)` now persists
`coordinatorWSURL` to `config.yaml`. Historically config was
CLI-authored; now the App also writes it.

- Two-writer file: what if the CLI and the App both write to
  `config.yaml`? Is there a lock, a versioned schema, or a "single
  writer" rule?
- Field ownership: which fields does each writer own? A misconfigured
  merge could silently drop `coordinator_url` or `provider_id`.
- Migration: existing installs with a config.yaml that lacks
  `coordinator_url` — how do they upgrade to v1.8.9? Does the CLI
  fall back to a default, refuse to start, or auto-write on next
  bootstrap?

### ARCH-6. Orphan-child on SIGTERM (SEPARATE VERIFICATION QUESTION)

Prior audit round R2 raised **CODE-M-2: CLI-side orphan-child on
SIGTERM** — a concern that the CLI's `--recommend` autotune path
spawns a child (or the App spawns the CLI, which spawns a child)
that survives when the parent receives SIGTERM. The finding was
NOT addressed in this session's direct pushes.

**Verify whether this concern is real, and if real, whether it is
safe to leave un-fixed. Read the following files, determine if a
concrete orphan scenario exists, and rate its severity:**

- CLI: `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
  (if present) or the subprocess-spawning path used by autotune's
  `--recommend` flag.
- App: any `Process` / `Foundation.Process` usage that launches the
  CLI, especially `AutotuneRecommendationRunner.swift` or equivalent.
- Signal handling: does the CLI install a SIGTERM handler that
  forwards to its children (setpgid + killpg pattern)?

**Answer these three questions explicitly:**

1. **Is there a real orphan scenario?** Trace one concrete flow: App
   spawns CLI; CLI spawns model runtime child; App is force-quit or
   crashes; does the model runtime child survive? Cite file:line
   evidence for each step.
2. **If yes, what's the blast radius?** (Zombie processes eating GPU
   memory / port collisions on next launch / operator confusion /
   nothing serious?)
3. **Recommendation:** SAFE_TO_LEAVE / FIX_NEXT_CYCLE / FIX_NOW,
   with a specific reason. If FIX_NOW, sketch the fix
   (`Foundation.Process` doesn't cleanly expose PGID control on
   macOS; you'd typically need to run through `sh -c` with `setsid`
   or use `posix_spawn` with `POSIX_SPAWN_SETPGROUP`; alternatively
   the App can call `killpg` on the pid it launched by making
   `-pgid` = pid, which requires `setsid` in the child).

This orphan-child question is EXPLICITLY part of your verdict. If you
recommend SAFE_TO_LEAVE, that recommendation must survive the other
two lanes' review — but you are the primary lane for it.

### ARCH-7. Coupling with SPEC-026 / SPEC-020

- Do the six direct-push commits satisfy SPEC-026 §7 (identity_signature
  handshake) as written, or do they change the contract in ways that
  the spec now under-specifies?
- Is a SPEC-026 v0.X follow-up warranted to codify (a) the bridge
  design, (b) the actor bypass rationale, (c) the state-name
  compatibility rule, (d) the timeout hierarchy?

## Response format

Write findings to
`audits/2026-07-05/session-direct-r1/session-direct-r1-architect-findings.md`:

```
# Session direct-push R1 — ARCHITECT lane findings

## Verdict
PASS / FAIL

## Orphan-child on SIGTERM verification (ARCH-6)
- Real orphan scenario? YES / NO — evidence
- Blast radius: <impact>
- Recommendation: SAFE_TO_LEAVE / FIX_NEXT_CYCLE / FIX_NOW — reason

## Findings

### ARCH-C-1 (CRITICAL) <title>
- File: <path:line>
- Design concern: <what breaks conceptually>
- Evidence: <references>
- Recommendation: <specific direction>

### ARCH-H-1 (HIGH) <...>
### ARCH-M-1 (MEDIUM) <...>
### ARCH-L-1 (LOW) <...>
### ARCH-I-1 (INFO) <...>
```

Stay in your lane: no line-level code-style opinions, no CVE-style
threat modeling — those are the other two lanes. Focus on design
coupling, abstraction fitness, contract clarity, and long-term
maintainability. If verdict is PASS, still write the file with the
ARCH-6 verification block and a one-paragraph "what I looked at"
narrative for the audit trail.
