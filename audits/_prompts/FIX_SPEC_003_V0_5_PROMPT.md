# Fix prompt — SPEC-003 v0.4 → v0.5

Operator-paste prompt for the **Distribution / install.sh stream** of
the three-stream patch cycle queued after Decision log Entries 19 + 20.
Two other prompts cover the Swift (SPEC-001 v1.2.2) and Go (SPEC-002
v1.1.3) streams in parallel.

## What this stream owns

| Layer | From | To |
|-------|------|----|
| Spec document | SPEC-003 v0.4 | SPEC-003 v0.5 |
| install.sh | already at HEAD with sed + deadline fixes | small polish: wire-bytes-on-failure |

Three additions, one small shell-script polish:

  A. **§ 5 onboarding-UX normative requirement** — install.sh self-test
     failure path MUST print the first 200 bytes of the actual
     `/v1/models` response on grep mismatch. Today's "Local self-test
     failed" was a generic message that hid the JSON-escape mismatch
     (Bug D) for two release cycles.

  B. **§ 4 distribution-channel decoupling** — make explicit the
     architecture property that `install.sh` is served from `main` via
     `get.malibu.tech` and is NOT bundled into the release tarball.
     A one-line install.sh patch lands without re-running the GitHub
     release action. (This is what made today's same-day landing of
     four bugs cheap; worth preserving as a spec property.)

  C. **New audit category** — "shell-script paths that touch real OS
     resources (tty, fd, port, FS layout, JSON over loopback) MUST
     have integration tests that actually exercise them; code review
     alone does not catch this bug class." Reference: Entry 20 four
     bugs.

Plus one install.sh polish:

  D. **install.sh self-test failure path** — on grep mismatch in
     `wait_for_local_model`, print the first 200 bytes of the raw
     /v1/models response so the next bug like D (wire-format mismatch)
     diagnoses itself.

Run in **Claude Code**. Expected duration: ~45-60 min (mostly spec
text + a ~15-line install.sh change + one end-to-end retest).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are landing three spec-text additions to SPEC-003 + one small
install.sh polish so the next install-time failure surfaces the wire
format directly instead of a generic message.

You will edit these files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
  /Users/augstar/macprovider-poc/phase3-binary/dist/install.sh
  /Users/augstar/macprovider-poc/phase5-onboarding/implementation-notes.html
    (append "Resolved in v0.5" section)

Version bump:
  SPEC-003 v0.4 → v0.5

## Cross-spec context (shared verbatim across the three-stream patch cycle)

Today's Day-3 distribution work landed `curl-pipe-bash` for strangers.
The first stranger-shaped install surfaced **four install.sh bugs (A–D,
Entry 20)** and the preceding Day-2 production deploy surfaced **two
silent regressions (Entry 19)**: (1) Swift reconnect-task lifecycle
after CoordinatorDrainComplete didn't fire; (2) Go coordinator's
`WithTokenValidator` was wired unconditionally and `s.close()` did not
log, causing 15 min of silent production rejection.

The audit-pattern lesson from both Entries: **code paths that look
locally correct but fail under real-world resource interactions**. Each
line read fine in isolation; failure modes only emerged when shell
environment / Task lifecycle / config-flag-absent paths were actually
exercised. Per-stream audits caught the design issues; only the
stranger-shaped end-to-end test catches the surface issues.

Three patch streams run in parallel against this context:

  - **SPEC-001 v1.2.2 + phase3-binary v1.2.3** (sibling prompt
    FIX_SPEC_001_V1_2_2_PROMPT.md) — Swift behavior fix + spec text for
    reconnect lifecycle, model_id casing, JSON-escape tolerance.

  - **SPEC-002 v1.1.3** (sibling prompt FIX_SPEC_002_V1_1_3_PROMPT.md)
    — Go spec-text-only: auth.require_provider_tokens normative,
    log-every-WS-close MUST, anti-pattern audit category entry. The
    Go behavior already shipped in commit 47d6433.

  - **SPEC-003 v0.5** (THIS PROMPT) — distribution polish: install.sh
    prints wire bytes on self-test failure; § 5 normative requirement;
    new audit category for "shell-script paths touching real OS
    resources."

Each stream owns a disjoint codebase. Coordinate via commits to main;
no file-level conflicts expected.

## Critical constraints

**1. Backward-compat invariant.** install.sh changes must remain
backward-compatible with v1.2.2 release tarballs (the current
"latest" release). The wire-bytes-on-failure addition is a new log
line; it does not change any exit code or success condition.

**2. Curl-pipe-bash invariant.** The install MUST continue to work
under `curl ... | bash` (no controlling tty other than /dev/tty,
stderr/stdout interleaved through the pipe). Don't introduce reads
from stdin or escape sequences that break in this mode.

**3. d-inference clean-room.** Do not inspect d-inference source.

**4. Don't re-introduce Bugs A/B/C/D.** Those four are already fixed
in commits c37c60b + d1093de + 7aae075. Read them before editing
install.sh so you don't accidentally regress.

**5. Test end-to-end with curl-pipe-bash after the install.sh
change.** Uninstall, then run:

    curl -fsSL https://get.malibu.tech/install.sh | \\
      MACPROVIDER_PORT=18080 MACPROVIDER_NO_PROMPT=1 bash

The install MUST go green end-to-end in <30s on warm cache. If you
deliberately break /v1/models to test Finding D's diagnostic output,
the wire bytes MUST appear in the failure log before the script exits.

## Required reading

1. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   — full document. Note especially:
     - § 4 (distribution & lifecycle)
     - § 5 (onboarding UX)
     - § 9 (acceptance criteria — for adding a new AC)
     - The audit-categories section (find where to add the new
       category, or add a new one if there's no existing list)

2. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — Entry 20 in full (Bugs A/B/C/D with diagnoses). Entry 19 for the
   distribution-channel-decoupling property (the same-day v1.2.2
   install.sh patch wouldn't have been cheap if install.sh were inside
   the release tarball).

3. `/Users/augstar/macprovider-poc/phase3-binary/dist/install.sh`
   — full file. Note especially:
     - `wait_for_local_model()` function (around line 588) — where
       Finding D's polish lives
     - `read_line()`, `ensure_port_free()`, install_binary's
       bundle-co-location block — these are Bugs C/B/A fixes; do not
       regress them

4. `git log --oneline phase3-binary/dist/install.sh` — see the recent
   commits c37c60b, d1093de, 7aae075. Confirm the current state of
   install.sh matches all four bug fixes before adding the polish.

5. `/Users/augstar/macprovider-poc/.github/workflows/release.yml`
   — to confirm Finding B's distribution-channel-decoupling claim:
   the workflow only packages binaries + bundles + signatures into the
   tarball; install.sh is NOT in the asset list. (If it IS, that's a
   bug to file separately — but the layout described in BUILD_DISTRIBUTION_PROMPT.md
   makes clear install.sh is served from main via raw.githubusercontent.com.)

## Findings to fix

### A. § 5 — self-test failure path MUST print wire bytes

**Location:** `specs/SPEC-003-open-onboarding.md` § 5 (onboarding UX
normative requirements)

**Problem (Entry 20 Bug D, root-cause delay):** When the install.sh
self-test failed against the v1.2.1 + v1.2.2 binaries, the script
printed a generic message:

    [macprovider-install] Local self-test failed. Check logs: tail -f \
      /Users/augstar/Library/Logs/macprovider/macprovider.err.log

The actual bug (Swift's `\/` escape vs unescaped grep pattern) was
invisible from this message. The operator chased a "deadline too short"
hypothesis for one whole retest cycle before realizing the deadline
wasn't the issue. The wire-format mismatch was sitting one curl away
from being visible.

**Fix (spec text):** Add a normative paragraph in § 5:

> **§ 5.X Self-test failure diagnostics.**
>
> When `install.sh`'s local self-test (`wait_for_local_model`) fails,
> the script MUST print the first 200 bytes of the actual
> `/v1/models` response in addition to the generic failure message,
> labelled clearly as "raw response". This requirement exists because
> wire-format mismatches between the installer's grep patterns and
> the binary's JSON encoder are the dominant failure mode for
> self-test false negatives (see Entry 20 Bug D). The 200-byte cap
> avoids dumping multi-kilobyte responses while reliably exposing
> the JSON structure that the grep is checking.
>
> If the `/v1/models` endpoint returned no response (port unbound),
> the script MUST instead print the binary's stderr log path and the
> last 200 bytes of stderr if non-empty. This ensures every failure
> mode produces a self-diagnosing message.

**Fix (implementation):** See Finding D below.

### B. § 4 — distribution-channel decoupling explicit

**Location:** `specs/SPEC-003-open-onboarding.md` § 4 (distribution &
lifecycle)

**Problem (Entry 20 lesson):** SPEC-003 v0.4 documents the release
process (GitHub Releases + signed tarball) but does not state, as an
intentional architecture property, that `install.sh` is served
separately from the release tarball — via `main` branch through the
`get.malibu.tech` → raw.githubusercontent.com redirect. This
property is what allowed the v1.2.2 install.sh fix to land in seconds
without a 5-10 minute release-action rerun, and it's worth naming
because future contributors might be tempted to "tidy up" by bundling
install.sh into the tarball.

**Fix (spec text):** Add a normative paragraph in § 4 immediately
after the release-artifact list:

> **§ 4.X Distribution channel decoupling.**
>
> `install.sh` is served from `main` via the `get.malibu.tech` →
> `raw.githubusercontent.com/<owner>/<repo>/main/phase3-binary/dist/install.sh`
> redirect. It is NOT bundled into the release tarball. This is an
> intentional architecture property:
>
> - Installer bugs (parse errors, sed quoting, environment-handling)
>   can be fixed by a one-line commit to `main`; the next
>   `curl ... | bash` carries the fix in seconds.
> - Binary releases are tagged + signed + immutable; an installer
>   patch does not require re-running the GitHub Action or
>   re-signing.
> - Strangers running `curl get.malibu.tech/install.sh | bash`
>   always get the latest installer, but the installer fetches a
>   specific signed binary release tag and verifies it.
>
> The release tarball MUST NOT contain `install.sh`. Re-bundling it
> would reintroduce the slow-iterate path and is explicitly out of
> scope.

### C. New audit category — shell-script integration testing

**Location:** `specs/SPEC-003-open-onboarding.md` audit-category list
(find the existing list under § 9 or wherever SPEC-003 enumerates
audit categories; if no list exists, create § 10 "Audit categories
for SPEC-003+ revisions" with this as the first entry)

**Problem (Entry 20 meta-lesson):** All four Day-3 install bugs were
in shell-script code that no audit reviewer would flag because each
line was locally correct. The bug class was the interaction with a
real OS resource:

  - Bug A: filesystem layout (mlx-swift expects bundles adjacent to
           executing binary)
  - Bug B: pipe-environment semantics (env vars on which side of `|`)
  - Bug C: controlling tty in a pipe (`/dev/tty` as fd vs stdin)
  - Bug D: JSON wire encoding (RFC 8259 `\/` legal escape)

Each interaction is correct under code review and broken under
real-world execution. The defense against this class is integration
testing that actually exercises the resource, not code review.

**Fix (spec text):** Add the new audit category:

> **Audit category Z (or whatever the next letter is): Shell-script
> paths that touch real OS resources require integration tests, not
> code review.**
>
> Any shell-script path in the installer or related tooling that
> touches a real OS resource MUST have an integration test that
> actually exercises the resource. "Real OS resource" includes but
> is not limited to:
>
> - Controlling tty (`/dev/tty`, `read -p`, prompt redirection)
> - File descriptor manipulation (`exec 4</dev/tty`, fd inheritance
>   across subshells, `<&-`)
> - Port binding (`lsof -iTCP`, `nc -l`, launchd `Sockets`)
> - Filesystem layout assumptions (binary-adjacent resource loading,
>   bundle co-location, symlink behavior under `cp -L` / `tar -h`)
> - JSON parsing over loopback (RFC 8259 escape choices that vary by
>   producer)
> - Pipe-environment semantics (`A=1 cmd1 | cmd2` env scoping)
> - macOS-specific behavior (com.apple.quarantine, launchd plist
>   bootstrap, codesign verification)
>
> Audit findings that say "this line looks correct" without an
> accompanying integration-test step MUST be downgraded to
> "needs integration test" rather than "approved." Reference:
> Entry 20 Bugs A/B/C/D, all four of which were independently
> code-review-clean and all four of which broke on first
> stranger-shaped execution.

### D. install.sh polish — print wire bytes on self-test failure

**Location:** `phase3-binary/dist/install.sh`, function
`wait_for_local_model` and the call-site in `main()`

**Problem:** Generic "Local self-test failed" message hid the JSON-escape
mismatch for two release cycles. See Finding A.

**Fix (implementation):** Modify the failure path. Currently around
the call site in `main()`:

```bash
  if ! wait_for_local_model "$model"; then
    log "Local self-test failed. Check logs: tail -f $LOG_DIR/macprovider.err.log"
    exit 6
  fi
```

Change to capture the last raw response from `/v1/models` (or the
last stderr from the binary if /v1/models gave nothing) and print
the first 200 bytes:

```bash
  if ! wait_for_local_model "$model"; then
    log "Local self-test failed."
    # Surface the actual wire format so JSON-escape / id-format
    # mismatches diagnose themselves (Bug D class).
    raw_response="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
    if [ -n "$raw_response" ]; then
      log "Raw /v1/models response (first 200 bytes):"
      printf "  %.200s\n" "$raw_response"
      log "If 'owned_by:macprovider' is present but the model id"
      log "is not matching, this is likely a wire-format mismatch."
    else
      log "/v1/models did not respond. Binary may not have bound port ${PORT}."
      if [ -s "$LOG_DIR/macprovider.err.log" ]; then
        log "Last 200 bytes of macprovider.err.log:"
        tail -c 200 "$LOG_DIR/macprovider.err.log" | sed 's/^/  /'
      fi
    fi
    log "Full logs: $LOG_DIR/macprovider.err.log"
    exit 6
  fi
```

(Implementer is free to tighten the diagnostic; the requirement is
that on failure, either the wire bytes or stderr's last 200 bytes
appear in the log before exit.)

## Output requirements

1. SPEC-003 updated in place. Version bumped to v0.5. Change log
   entry added at the top covering Findings A, B, C.

2. install.sh updated with Finding D's diagnostic polish. No
   regression in Bugs A/B/C/D paths.

3. `phase5-onboarding/implementation-notes.html` gains a "Resolved
   in v0.5" section covering A/B/C/D.

4. End-to-end retest:
   - `curl ... uninstall.sh | MACPROVIDER_NO_PROMPT=1 bash`
   - `curl ... install.sh | MACPROVIDER_PORT=18080 MACPROVIDER_NO_PROMPT=1 bash`
   - Verify the install goes green and the new "Raw /v1/models
     response" log line does NOT appear on the green path (it's
     only for failures).
   - (Optional) Manually break the model variable in install.sh
     temporarily to a wrong string, run install, confirm the wire-
     bytes diagnostic appears, then revert.

5. Handback summary at the end: 150 words covering the three spec
   additions, the install.sh diagnostic addition, and the end-to-end
   retest result.

## Self-verification checklist

- [ ] SPEC-003 version bumped 0.4 → 0.5 at the top.
- [ ] Change log entry covers Findings A, B, C in that order.
- [ ] § 5 has the self-test-diagnostics MUST paragraph.
- [ ] § 4 has the distribution-channel-decoupling paragraph.
- [ ] Audit-category list has the "shell-script paths touch real OS"
      entry referencing Entry 20.
- [ ] install.sh's self-test failure path prints raw response or
      stderr bytes before exit 6.
- [ ] Bugs A/B/C/D fixes are still in place — no regression in
      bundle co-location, port collision, /dev/tty handling, or
      JSON-slash normalization.
- [ ] End-to-end curl-pipe-bash test green on warm cache; the
      diagnostic addition fires when manually broken.

If your edits exceed ~200 lines of SPEC-003 changes or ~50 lines of
install.sh changes, stop and re-check scope.

When done, print the handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~10 min):

1. `git diff specs/SPEC-003-open-onboarding.md` — three additions + version bump + change log.
2. `git diff phase3-binary/dist/install.sh` — diagnostic polish only; the four prior bug fixes are intact.
3. Run uninstall + curl-pipe-bash install end-to-end; verify green and `<30s` on warm cache.
4. (Optional) Temporarily break the model variable to force a self-test failure, verify the new wire-bytes diagnostic appears.

Then commit. Suggested message:

```
SPEC-003 v0.5 + install.sh diagnostics: wire-byte print + decoupling property + audit category

Three normative additions to SPEC-003 + one install.sh polish.

A. § 5  Self-test failure path MUST print first 200 bytes of
        /v1/models response. Would have cut Entry 20 Bug D
        root-cause attribution from two retest cycles to zero.

B. § 4  Distribution-channel decoupling explicit: install.sh is
        served from main via get.malibu.tech; NOT bundled into
        the release tarball. Preserves the same-day-fix property.

C. Audit  New category: "shell-script paths that touch real OS
        resources need integration tests, not code review."
        Names the bug class behind Entry 20's four bugs.

D. install.sh  failure path now prints wire bytes (or stderr tail).
        Backward-compatible; affects failure path only.

Backward-compat invariant: preserved. Buyer API surface: unchanged.
```

After commit, the three-stream patch cycle is done. The spec corpus
matches the implementations; the audit-pattern lessons are encoded.
Next: monitor pool health for 24h, then proceed to SPEC-004 / SPEC-005
/ SPEC-007 design pass (operator decides priority).
