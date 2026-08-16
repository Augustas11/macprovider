# Fix prompt — SPEC-003 v0.6 → v0.7 (install.sh battle-hardening)

Operator-paste prompt to close 6 install.sh findings surfaced during the
v1.2.4 partner-upgrade cycle (M4 partner + augustar's self-canary).
Single coordinated SPEC-003 + install.sh patch BEFORE BUILD_PHASE5
unlocks the gateway implementation.

Version bumps:
  SPEC-003 v0.6 → v0.7
  install.sh: no version (served from main; landing on push)

Findings count: 6 MAJOR (all reproducibility-validated by either
operator self-canary or M4 partner upgrade today).

Run in **Claude Code** or **Codex CLI**. Expected duration: ~1-2 days
(install.sh edits + spec text + hardware verification + self-canary).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying 6 install.sh findings to make provider upgrade
paths handle real-world partner state. The findings come from two
independent reproductions: (1) operator self-canary v1.2.3 → v1.2.4
on augustass-macbook-air today; (2) M4 partner upgrade from v0.1.0
era to v1.2.4 (registered as `air5`) today.

You will edit two files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md  v0.6 → v0.7
  /Users/augstar/macprovider-poc/phase3-binary/dist/install.sh  (no version field; landing on push)

Optionally update:
  /Users/augstar/macprovider-poc/phase3-binary/dist/uninstall.sh
  (only if any of the fixes change install layout in a way that
  uninstall must mirror)

## Critical constraints

**1. install.sh distribution stays decoupled per SPEC-003 v0.5 § 4.**
install.sh is served from main via `get.malibu.tech` → raw.github
redirect. No tarball repackaging required for install.sh-only fixes;
the next `curl get.malibu.tech/install.sh | bash` carries the fix.

**2. SPEC-001, SPEC-002, SPEC-006 stay UNTOUCHED.** Verify with
`git diff` after edits.

**3. Backward-compat for existing v1.2.3/v1.2.4 installs.** The
fixes MUST work for: (a) fresh install on a Mac with no prior
state; (b) upgrade-in-place on a Mac currently running v1.2.3+
with the operator's standard layout; (c) upgrade on M4-pattern Mac
with prior install state at non-standard layout. Test all three.

**4. d-inference clean-room.** Do not inspect d-inference source.

**5. The 6 findings have specific reproductions in the field.** The
spec text should reference SPEC-006 v0.5 launch as the trigger for
expected install volume (justifying the v0.7 cycle). Audit category
should reference Entry 22 follow-ups.

**6. Hardware verification gate.** Do not declare done without
exercising the new install.sh in three scenarios (see "Verification
gate" below). The gate is mechanical, not discretionary.

## Required reading

1. `specs/SPEC-003-open-onboarding.md` v0.6 — current spec under
   revision.

2. `phase3-binary/dist/install.sh` — current install.sh. Read fully
   to find the 6 patch points.

3. `beta/DECISION_CRITERIA.md` Entries 20 (install.sh bugs A/B/C/D
   from initial stranger curl-pipe-bash), 21 (Day-3 close), and 22
   (SPEC-006 corpus lock; the open-follow-ups for SPEC-003 v0.7
   are not yet filed here but should be referenced in v0.7's
   change log).

4. The 6 findings inline below — each has been reproduced today.

## Findings to fix

### F-603-V7-1 (v0.7-1) — install.sh doesn't read existing config to detect port.

**Location:** install.sh, `PORT` initialization at the top.

**Reproduction:** operator self-canary today; running
`curl get.malibu.tech/install.sh | bash` on a Mac with existing
v1.2.3 on port 18080 defaulted to port 8080 (because MACPROVIDER_PORT
wasn't set in env) → port collision detected, install refused.

**Fix:**

```bash
# In install.sh, replace:
PORT="${MACPROVIDER_PORT:-8080}"

# With:
detect_existing_port() {
  if [ -f "$CONFIG_PATH" ]; then
    awk -F: '/^port:/ {gsub(/ /, "", $2); print $2; exit}' "$CONFIG_PATH" 2>/dev/null
  fi
}

if [ -n "${MACPROVIDER_PORT:-}" ]; then
  PORT="$MACPROVIDER_PORT"
elif EXISTING_PORT="$(detect_existing_port)" && [ -n "$EXISTING_PORT" ]; then
  PORT="$EXISTING_PORT"
  log "Detected existing config port: $PORT (override with MACPROVIDER_PORT=N)"
else
  PORT="8080"
fi
```

Acceptance:
- Fresh install with no MACPROVIDER_PORT, no config → port 8080
- Upgrade on existing install at 18080 → detects 18080
- Explicit MACPROVIDER_PORT override → uses override

### F-603-V7-2 (v0.7-2) — `ensure_port_free` blocks own-service upgrade.

**Location:** install.sh, `ensure_port_free()` function.

**Reproduction:** operator self-canary + M4 partner today. The
function detected the existing install's macprovider-cli process
holding the configured port → refused to proceed.

**Fix:**

```bash
# In ensure_port_free(), after holding_cmd is set, add:
# Check whether the holder is our own existing service.
if pgrep -lf 'macprovider-cli.*--port' | grep -qE "(^|[[:space:]])$holding_pids([[:space:]]|$)"; then
  log "Existing macprovider-cli holding port $PORT; stopping it for upgrade-in-place."
  launchctl bootout "gui/$UID" "$PLIST_PATH" 2>/dev/null || true
  sleep 2
  # Re-check whether port freed
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
    log "Port $PORT still held after launchctl bootout; trying pkill of own-service PID."
    kill -TERM "$holding_pids" 2>/dev/null || true
    sleep 2
  fi
  # If still holding, fail with clearer message
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
    die 6 "could not stop existing macprovider-cli on port $PORT; please stop manually and retry"
  fi
  log "Port $PORT freed; proceeding with upgrade."
  return
fi
# Original logic for non-own-process holders:
log "ERROR: port $PORT is already in use by ${holding_cmd:-another process}."
[ ... rest of existing error path ... ]
```

Acceptance:
- Fresh install (no prior process) → ensure_port_free is no-op
- Upgrade in place (own service holding port) → bootout + proceed
- Foreign process holding port → original error path, exit 6
- Edge case: launchctl bootout fails (e.g., service not in expected
  domain) → falls through to kill -TERM by PID

### F-603-V7-4 (v0.7-4) — plist invokes symlink path; Swift bundle resolution fails on some macOS environments.

**Location:** install.sh, `render_plist()` function, `binary_path`
substitution.

**Reproduction:** M4 partner today. The launchd plist invoked the
binary via `~/.local/bin/macprovider-cli` (symlink to
`~/macprovider/macprovider-cli`). Swift's Bundle resolution used the
symlink path as the search root rather than the dereferenced
location, so `.bundle` directories at `~/macprovider/` weren't
found → "Failed to load the default metallib" exit 255 silently.

Running the binary directly from `~/macprovider/macprovider-cli`
worked cleanly on the same Mac.

**Fix:**

```bash
# In render_plist(), replace:
binary_path="$(xml_escape "$BINARY_PATH")"

# With:
# Use the REAL binary path (target of the symlink) so Swift Bundle
# resolution finds adjacent .bundle directories. The symlink at
# $BINARY_PATH (~/.local/bin/macprovider-cli) stays for PATH
# discoverability but launchd invokes the real path.
binary_path="$(xml_escape "$INSTALL_DIR/macprovider-cli")"
```

Verify the WorkingDirectory in the rendered plist is also
`$INSTALL_DIR` (already the case in v0.6).

Acceptance:
- Plist file references `~/macprovider/macprovider-cli` directly
- `.local/bin/macprovider-cli` symlink remains for shell PATH
- Existing v1.2.3+ installs already pointing at symlink will get
  the corrected plist on next install.sh run (idempotent)

### F-603-V7-5 (v0.7-5) — 300s self-test deadline too short for cold model downloads.

**Location:** install.sh, `wait_for_local_model()` function.

**Reproduction:** M4 partner today. Qwen 7B 4-bit is ~4-5GB. On
M4's residential bandwidth, download took ~10 minutes. install.sh
gave up at 300s with "Local self-test failed" while MLX was still
downloading; the binary completed load several minutes later
without operator action.

**Fix:** Detect whether the model is already in the HuggingFace
cache. If yes, keep the 300s deadline. If no (cold install),
extend to 20 minutes with proportional progress messaging.

```bash
wait_for_local_model() {
  local model="$1"
  local cache_check="$HOME/.cache/huggingface/hub/models--${model//\//--}"
  local deadline
  if [ -d "$cache_check" ]; then
    deadline=$(( $(date +%s) + 300 ))   # warm: 5 min
    log "Waiting up to 5 min for local /v1/models (model cache detected)."
  else
    deadline=$(( $(date +%s) + 1200 ))  # cold: 20 min
    log "Waiting up to 20 min for local /v1/models (first-time install; downloading ${model} ~4-5GB)."
  fi
  # ... rest of existing logic with progress messages every 60s ...
}
```

Acceptance:
- Warm install (model cached) → 5 min deadline, fast green
- Cold install (model not cached) → 20 min deadline, progress
  message every 60s noting download in progress

### F-603-V7-6 (v0.7-6) — "Local self-test failed" message alarms users when binary is fine.

**Location:** install.sh, the failure path after
`wait_for_local_model()` returns false.

**Reproduction:** M4 partner today. After 91s of "still waiting"
messages, install.sh printed "Local self-test failed" → M4
concluded the install was broken. The binary was actually still
loading.

**Fix:** Replace the generic failure message with a diagnostic-rich
explanation:

```bash
# Replace existing failure block with:
log ""
log "==========================================================="
log "Self-test timeout reached. THIS DOES NOT NECESSARILY MEAN"
log "THE BINARY FAILED. macprovider-cli is likely still loading"
log "the model in the background."
log ""
log "To check if the binary is alive:"
log "  ps aux | grep macprovider-cli | grep -v grep"
log ""
log "To check if the model is still downloading:"
log "  du -sh ~/.cache/huggingface/hub/"
log "  (run twice 30s apart; growing = downloading)"
log ""
log "To check for errors:"
log "  tail -30 $LOG_DIR/macprovider.err.log"
log ""
log "Once the binary fully loads, it joins the pool. You can"
log "verify from the coordinator side via /v1/pool/check (see docs)."
log "==========================================================="
log ""
exit 6
```

Acceptance:
- Failure path explicitly distinguishes "timeout" from "actual
  failure"
- Three diagnostic commands embedded in the output
- User left with clear next steps instead of "broken, give up"

### F-603-V7-7 (v0.7-7) — install.sh doesn't refuse to install into non-empty unrelated directories.

**Location:** install.sh, `install_binary()` (or wherever
$INSTALL_DIR is first written to).

**Reproduction:** M4 partner today. `~/macprovider/` already
contained Python venv files (`bin/`, `include/`, `lib/`,
`pyvenv.cfg`) from May 26. install.sh placed binary + bundles
ALONGSIDE these without warning. Not the cause of M4's failure
but visible filesystem mess + potential conflict source.

**Fix:** Detect non-empty INSTALL_DIR with unrelated contents and
warn (don't fail by default; preserve the unblock-the-upgrade
property, but inform the user).

```bash
check_install_dir_clean() {
  if [ ! -d "$INSTALL_DIR" ]; then
    return 0  # doesn't exist; safe to create
  fi
  local entries
  entries=$(ls -A "$INSTALL_DIR" 2>/dev/null | grep -vE '^(macprovider-cli(\.v[0-9.]+\.bak)?|.*\.bundle)$' | head -20)
  if [ -n "$entries" ]; then
    log "WARNING: $INSTALL_DIR contains non-macprovider entries:"
    while IFS= read -r entry; do
      log "  - $entry"
    done <<< "$entries"
    log "These will not be modified by install.sh, but you may want"
    log "to clean up the directory after the upgrade. Continuing..."
  fi
}
```

Call this from main() before install_binary.

Acceptance:
- Empty or macprovider-only INSTALL_DIR → no warning
- INSTALL_DIR with unrelated content → warning lists entries; install
  continues
- User left with awareness of mixed state, not an actual error

### Spec text catch-up for SPEC-003 v0.7

Add to SPEC-003 v0.7's change log + § 5 onboarding UX:

> **§ 5.X v1.2.4 partner-upgrade lessons.** Install.sh upgrade-in-
> place was exercised at scale for the first time during the
> v1.2.4 partner upgrade (Entry 22 follow-up). Six findings
> surfaced from operator self-canary + M4 partner reproduction,
> all closed in v0.7 (F-603-V7-1 through F-603-V7-7, excluding
> retracted F-603-V7-3 and F-603-V7-8). The findings clustered
> around three classes:
>
> 1. **Existing-state detection** — install.sh assumed fresh
>    install paths; upgrade-in-place required reading prior config
>    (port) and stopping prior service (launchctl bootout).
> 2. **Swift Bundle resolution edge case** — launchd plist
>    invoked the symlink path, which Swift's Bundle.main resolved
>    incorrectly on some macOS environments (M4's specific Mac).
>    Fixed by invoking the real binary path from the plist.
> 3. **User-facing failure clarity** — "Local self-test failed"
>    alarmed users when the binary was still loading. Diagnostic-
>    rich timeout message + cold-cache deadline extension shipped.

Add to audit categories section:

> Inherits and reinforces the "shell-script paths touching real
> OS resources need integration tests, not code review" audit
> category from v0.5. v0.7 specifically adds: **"upgrade-in-place
> paths exercise different OS-resource interactions than fresh
> installs and require their own integration testing."**

Update "Depends on:" line — unchanged (still SPEC-001 v1.2.3,
SPEC-002 v1.1.4).

## Verification gate (MANDATORY before declaring done)

Test all 6 fixes against three concrete scenarios. **Do not declare
v0.7 ready without all three green.**

### Scenario 1: Fresh install on clean Mac (or simulated clean state)

```bash
# Simulate clean state by removing prior install
launchctl bootout gui/$UID ~/Library/LaunchAgents/live.malibu.provider.plist 2>/dev/null
rm -rf ~/macprovider/ ~/.config/macprovider/ ~/.local/bin/macprovider-cli ~/Library/LaunchAgents/live.malibu.provider.plist
# Run install fresh
curl -fsSL https://get.malibu.tech/install.sh | bash
# Expected: clean fresh install, model downloads, binary starts, joins pool
```

### Scenario 2: Upgrade in place from existing v1.2.4 install

```bash
# With existing v1.2.4 install on augustass-macbook-air (where this
# session is running), re-run install.sh.
curl -fsSL https://get.malibu.tech/install.sh | bash
# Expected: detect existing port (18080); bootout existing service;
# upgrade in place; service comes back on same port with same config
```

### Scenario 3: M4-pattern mixed-state directory

```bash
# Create a venv-like mixed state in a test directory
mkdir -p /tmp/test-install-dir/bin /tmp/test-install-dir/lib
touch /tmp/test-install-dir/pyvenv.cfg
# Override INSTALL_DIR via env (if install.sh supports it) or
# manually verify the warning logic against /tmp/test-install-dir/
# Expected: warning printed, install continues
```

For each scenario, document:
- Did install.sh complete?
- Did binary boot + join pool?
- Were the F-603-V7-X fixes exercised correctly?
- Did the user-facing output match the spec's expected message?

## Output requirements

1. SPEC-003 updated. Version 0.6 → 0.7. Change log entry references
   Entry 22 follow-ups + all 6 F-* findings.

2. install.sh updated with all 6 fixes. Each fix has a comment
   referencing the corresponding F-* finding.

3. The verification gate's 3 scenarios are exercised on a real
   machine (augustass-macbook-air is the obvious candidate, plus
   the simulated tests). Document results.

4. (Optional but recommended) Update install.sh "Why" comments
   that reference the discipline lesson — explain WHY the
   port-detection or plist-real-path change exists, so future
   readers don't undo it accidentally.

## Self-verification checklist

- [ ] SPEC-003 version 0.6 → 0.7.
- [ ] Change log references Entry 22 + Entry 20 (prior install.sh
      cycle); cites the 6 F-* findings.
- [ ] install.sh has all 6 fixes; each commented with the F-*
      label.
- [ ] SPEC-001 v1.2.3 untouched (empty diff).
- [ ] SPEC-002 v1.1.4 untouched (empty diff).
- [ ] SPEC-006 v0.5 untouched (empty diff).
- [ ] uninstall.sh updated only if any of the fixes change install
      layout (most don't).
- [ ] Verification gate's 3 scenarios all green.
- [ ] Self-test deadline behavior verified in both warm and cold
      scenarios (operator may need to clear ~/.cache/huggingface/
      to test cold path).

If your edits exceed ~150 added lines in install.sh or ~100 in
SPEC-003, stop and re-check scope. The patches are surgical.

When done, print a 250-word handback summary:
- Six findings closed status
- Verification gate's 3 scenarios with pass/fail
- Any remaining concerns
- Whether SPEC-003 v0.7 is READY TO LOCK
- Whether install.sh is ready for next partner upgrade (M1 when
  they reconnect, or future strangers)

Then stop. Operator decides next move (probably: lock v0.7,
proceed to BUILD_PHASE5).

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~20 min):

1. `git diff specs/SPEC-003-open-onboarding.md` — version + change log + 6 findings sections.
2. `git diff phase3-binary/dist/install.sh` — all 6 fixes with F-* labels.
3. `git diff specs/SPEC-001-phase3-binary.md specs/SPEC-002-coordinator.md specs/SPEC-006-buyer-api.md` — all empty.
4. Review the verification gate output. If any scenario failed, investigate before commit.
5. If all green: commit + push (install.sh lands immediately via the get.malibu.tech redirect; no release needed).

Then commit. Suggested message:

```
SPEC-003 v0.7 + install.sh hardening: six v1.2.4 partner-upgrade findings

Closes six install.sh findings reproduced today during M4 partner
upgrade + operator self-canary (Entry 22 follow-ups):

F-603-V7-1  Read existing config to detect port (no more port-8080
            default when existing install is on 18080)
F-603-V7-2  ensure_port_free now stops own existing service before
            erroring (upgrade-in-place no longer blocked by self)
F-603-V7-4  Plist invokes real binary path (~/macprovider/...) so
            Swift Bundle resolution finds adjacent .bundle dirs;
            symlink at ~/.local/bin/ stays for PATH discoverability
F-603-V7-5  Cold-cache deadline 20 min (was 5); detects cache
            presence to avoid alarming wait
F-603-V7-6  Self-test timeout message now diagnostic-rich; tells
            user how to verify binary alive vs actually crashed
F-603-V7-7  Warns when INSTALL_DIR contains non-macprovider files
            (e.g., M4's leftover Python venv); does not block

Verification gate: 3 scenarios passed (fresh install, upgrade
in place, mixed-state dir warning).

SPEC-001 v1.2.3, SPEC-002 v1.1.4, SPEC-006 v0.5 untouched.

install.sh changes land immediately via get.malibu.tech →
raw.githubusercontent.com redirect. No release tag bump needed.
```

After commit, decide:

- **Lock SPEC-003 v0.7** and proceed to BUILD_PHASE5. Spec corpus
  fully clean for the gateway implementation.
- **One light regression check** (Codex, ~20 min) on the install.sh
  patch only — recommended given six fixes is on the larger side
  for a single-pass FIX cycle.

After verification clears: BUILD_PHASE5 unlocks; the spec-design
phase is genuinely done; the customer-facing product becomes a
code problem.
