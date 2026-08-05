#!/usr/bin/env bash
set -euo pipefail

# Linux CI diagnostic: this suite is authored for macOS and drives the installer
# recovery path, some of which is Darwin-only and gated below. Historically a
# non-Darwin divergence could kill the suite under `set -e` with ZERO output
# (a silent ~1s death on the ubuntu runner), leaving nothing to debug. Turn on
# an execution trace ONLY on non-Darwin CI so the exact failing command is
# always visible; this is a no-op locally and on Darwin (zero behavior change,
# trace goes to stderr only when both CI=true and the platform is not Darwin).
if [ "${CI:-}" = "true" ] && [ "$(uname -s)" != "Darwin" ]; then
  export PS4='+ [${SECONDS}s ${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
cleanup_test_processes() {
  while IFS= read -r log_path; do
    awk -F'|' '{print $1}' "$log_path" | while read -r pid; do
      kill "$pid" >/dev/null 2>&1 || true
    done
  done < <(find "$TMP" -name manual-fixture.log -type f -print 2>/dev/null)
  rm -rf "$TMP"
}
trap cleanup_test_processes EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys
names = {
    "cleanup", "install_tx_path_matches", "stage_install_tx_path",
    "stage_lifecycle_snapshot",
    "write_install_recovery_artifacts", "begin_install_transaction",
    "mark_install_cutover_started", "discard_install_transaction_before_cutover",
    "rollback_install_transaction", "commit_install_transaction",
    "arm_install_recovery_agent", "disarm_install_recovery_agent",
    "release_install_lock",
    "launchd_label_is_disabled", "capture_manual_provider_for_recovery",
    "pid_is_live_non_zombie", "stop_owned_manual_provider",
    "validate_port_value", "ensure_port_free",
}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = 0
while i < len(lines):
    name = lines[i].split("()", 1)[0] if "()" in lines[i] else ""
    if name not in names:
        i += 1
        continue
    depth = 0
    while i < len(lines):
        line = lines[i]
        print(line)
        depth += line.count("{") - line.count("}")
        i += 1
        if depth == 0:
            break
PY
printf '%s\n' 'REFERRAL_REPLACE_INCUMBENT="${REFERRAL_REPLACE_INCUMBENT:-0}"' >> "$TMP/functions.sh"

# Emit a FULL-schema lifecycle-state record matching the real store's
# JSONEncoder(.sortedKeys) output (compact, alphabetically sorted keys). This is
# the shape ProviderLifecycleStateRecord serializes: authority, state,
# reason_code, writer, operation_id, sequence, transition_id,
# previous_transition_id, provider_id, model_id, operator_paused, version, plus
# last_update/last_restart/last_rejection significant-event sub-records.
# Its definition is also appended to the extracted install functions file so the
# inner transaction harness (a fresh `bash -c`) can author the FULL-schema live
# intermediate record during the mutation phase.
write_full_schema_record() {
  out_path="$1"; state="$2"; reason="$3"; writer="$4"; operation_id="$5"
  sequence="$6"; operator_paused="$7"; transition_id="$8"
  python3 - "$out_path" "$state" "$reason" "$writer" "$operation_id" \
    "$sequence" "$operator_paused" "$transition_id" <<'PY'
import json
import sys

(out_path, state, reason, writer, operation_id, sequence, operator_paused,
 transition_id) = sys.argv[1:]


def journal(kind):
    # Distinct significant-event sub-records per journal so rollback translation
    # can be shown to PRESERVE last_restart/last_rejection/last_watchdog and to
    # REPLACE last_update (Defect 3). Mirrors the Swift SignificantEvent shape.
    return {
        "sequence": int(sequence),
        "transition_id": transition_id,
        "transition_at": "2026-07-15T17:00:00.000Z",
        "state": state,
        "reason_code": "%s_%s" % (reason, kind),
        "writer": writer,
        "operation_id": "%s-%s" % (operation_id, kind),
    }


record = {
    "version": 1,
    "sequence": int(sequence),
    "transition_id": transition_id,
    "previous_transition_id": "00000000-0000-4000-8000-000000000000",
    "transition_at": "2026-07-15T17:00:00.000Z",
    "state": state,
    "reason_code": reason,
    "authority": "macprovider_cli",
    "writer": writer,
    "provider_id": "mac",
    "model_id": "qwen3-coder-30b-a3b-instruct",
    "operation_id": operation_id,
    "operator_paused": operator_paused == "true",
    "last_update": journal("update"),
    "last_restart": journal("restart"),
    "last_rejection": journal("rejection"),
    "last_watchdog": journal("watchdog"),
}
with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

# Emit a lifecycle LEASE record in the EXACT nested wire schema the Swift
# ProviderLifecycleLeaseStore serializes (JSONEncoder(.sortedKeys)): the owner
# is nested under `owner` (owner.pid / owner.process_start_us /
# owner.boot_session), NOT a flat owner_pid. The reconciler decodes this real
# shape (Defect 1). When a pid is given, owner.process_start_us and
# owner.boot_session are derived from that live process's EXACT MICROSECOND
# start and the current boot session, so the reconciler's exact-microsecond
# liveness check (see owner_is_live / process_start_microseconds in install.sh)
# can confirm the owner is live. The live-pid start is read via the SAME sysctl
# kinfo_proc.p_starttime path the reconciler uses, so the fabricated value is
# byte-identical to what owner_is_live() reads (a whole-second-scaled start
# would no longer match after the R8 exact-identity fix). This is a generated
# conformance artifact; the paired Swift test
# (ProviderLifecycleShellConformanceTests) proves this shape byte-decodes
# through the real store.
write_lease_record() {
  out_path="$1"; operation_id="$2"; kind="$3"; owner_pid="$4"
  # Optional record-window override (env, so the positional signature stays
  # backward-compatible for the existing A-05.1/.2/.3 callers). The default
  # window brackets `now`; LEASE_RECORD_WINDOW=expired issues the whole record
  # window in the past so it is STRUCTURALLY VALID (correct duration algebra)
  # yet NOT in-bracket. This proves the reconciler's shared-validity gate
  # (record_shared_validity_ok, mirroring Swift's validationFailure ~888..894)
  # removes an out-of-window record even when the owner is LIVE (the MEDIUM fix).
  LEASE_RECORD_WINDOW="${LEASE_RECORD_WINDOW:-}" \
  python3 - "$out_path" "$operation_id" "$kind" "$owner_pid" <<'PY'
import ctypes
import json
import os
import struct
import subprocess
import sys
import time

out_path, operation_id, kind, owner_pid_text = sys.argv[1:]
owner_pid = int(owner_pid_text)
record_window = os.environ.get("LEASE_RECORD_WINDOW", "")


def process_start_us(pid):
    # Read the EXACT microsecond process-start via the SAME sysctl kinfo_proc
    # path the reconciler's owner_is_live()/process_start_microseconds uses, so a
    # LIVE-owner fixture carries the byte-identical value owner_is_live() will
    # read (the R8 exact-identity fix rejects a whole-second-scaled start). A
    # dead/unknown pid emits a fixed non-live marker so owner-liveness rejects it.
    if pid <= 0 or pid > 2**31 - 1:
        return 1
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.sysctl.argtypes = [
            ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
        ]
        libc.sysctl.restype = ctypes.c_int
        mib = (ctypes.c_int * 4)(1, 14, 1, pid)  # CTL_KERN, KERN_PROC, KERN_PROC_PID, pid
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 4, None, ctypes.byref(size), None, 0) != 0 or size.value < 12:
            return 1
        buffer = ctypes.create_string_buffer(size.value)
        buffer_size = ctypes.c_size_t(size.value)
        if libc.sysctl(mib, 4, buffer, ctypes.byref(buffer_size), None, 0) != 0:
            return 1
        data = buffer.raw[:buffer_size.value]
        if len(data) < 12:
            return 1
        tv_sec, tv_usec = struct.unpack_from("=qi", data, 0)
    except (OSError, ValueError, struct.error):
        return 1
    if tv_sec <= 0 or not (0 <= tv_usec < 1_000_000):
        return 1
    return tv_sec * 1_000_000 + tv_usec


def boot_session():
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip() if result.returncode == 0 else ""
    return value or "00000000-0000-0000-0000-000000000000"


# Build a STRUCTURALLY VALID record window from the real current clocks so the
# reconciler's base structural validator (record_matches_swift_structure, which
# mirrors Swift's validateRecordStructure and now gates the ordinary live-owner
# preservation path too) accepts it: correct kind-specific duration bound and
# the exact monotonicDuration == wallDuration * 1_000_000 algebra Swift enforces.
# A 15-minute window is inside BOTH the startup (30 min) and maintenance (20 min)
# ceilings and currently brackets `now`. The live-foreign case therefore stays a
# genuine "Swift-valid record + live owner -> PRESERVED" test; the dead-owner and
# rollback cases remove regardless of structure.
wall_now = int(time.time() * 1_000)
mono_now = int(time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW))
if record_window == "expired":
    # Whole window shifted into the PAST: issued 20 min ago, expired 5 min ago.
    # Still a valid 15-min duration (inside both kind ceilings, monotonicDuration
    # == wallDuration * 1_000_000), so record_matches_swift_structure ACCEPTS it
    # -- the only reason to REMOVE is the shared-validity gate's wall/monotonic
    # window check, on BOTH axes (Swift's .wallExpired / .monotonicExpired).
    issued_wall = wall_now - 20 * 60 * 1_000
    expires_wall = wall_now - 5 * 60 * 1_000
    wall_duration = expires_wall - issued_wall
    issued_mono = mono_now - 20 * 60 * 1_000_000_000
    expires_mono = issued_mono + wall_duration * 1_000_000
else:
    issued_wall = wall_now - 5 * 60 * 1_000
    expires_wall = wall_now + 10 * 60 * 1_000
    wall_duration = expires_wall - issued_wall
    issued_mono = mono_now - 5 * 60 * 1_000_000_000
    expires_mono = issued_mono + wall_duration * 1_000_000

record = {
    "version": 1,
    "lease_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "operation_id": operation_id,
    "kind": kind,
    "owner": {
        "pid": owner_pid,
        "process_start_us": process_start_us(owner_pid),
        "boot_session": boot_session(),
    },
    "issued_wall_ms": issued_wall,
    "expires_wall_ms": expires_wall,
    "issued_monotonic_ns": issued_mono,
    "expires_monotonic_ns": expires_mono,
}
with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

# Emit a MAINTENANCE lease carrying a `.prepared` startup handoff, in the exact
# nested Swift wire schema. The wall/monotonic issue/expire windows are computed
# from the REAL current clocks (the same CLOCK_MONOTONIC_RAW the reconciler and
# the Swift .live environment read) so the reconciler's prepared-handoff
# exemption -- which mirrors validationFailure's `handoff.state == .prepared`
# branch and requires now to fall inside both the record and handoff windows --
# is exercised against a genuinely live window. The owner pid is passed dead on
# purpose: the whole point of the exemption is that a valid prepared handoff
# survives even though the preparer process has exited. `expiry` selects a valid
# (future) or already-expired handoff window.
write_prepared_handoff_lease_record() {
  out_path="$1"; operation_id="$2"; owner_pid="$3"; expiry="${4:-valid}"
  record_kind="${5:-maintenance}"
  # Optional wire-shape overrides (env, so the positional signature stays
  # backward-compatible for the existing A-05.4/.5/.6/.7 callers). These build
  # a store-READABLE-shaped record whose numeric wire types overflow the Swift
  # Codable field or whose identity fields carry a non-ASCII/whitespace scalar
  # Foundation would trim but Python str.strip would not -- both cases Swift's
  # JSONDecoder/validate rejects, so the reconciler MUST decline the exemption
  # and REMOVE the record (R5 CODE-M Findings 1 and 2):
  #   PREPARED_OVERRIDE_OWNER_PID          -> owner.pid (e.g. 2147483648 = Int32 overflow)
  #   PREPARED_OVERRIDE_PROCESS_START_US   -> owner.process_start_us (e.g. 2**63 = Int64 overflow)
  #   PREPARED_OVERRIDE_HANDOFF_OPERATION  -> handoff.operation_id (record.operation_id stays $2)
  #   PREPARED_OVERRIDE_SERVICE_IDENTITY   -> handoff.service_identity (e.g. interior space)
  #   PREPARED_OVERRIDE_TARGET_PATH        -> handoff.target_executable_path (e.g. a
  #                                           ".."-containing path Swift's
  #                                           standardizedFileURL guard rejects)
  #   PREPARED_OVERRIDE_RECORD_VERSION     -> record.version raw token (e.g. "true"
  #                                           to emit a JSON boolean the version
  #                                           field must reject; R6 CODE-M1)
  #   PREPARED_OVERRIDE_HANDOFF_VERSION    -> handoff.version raw token (same, M1)
  #   PREPARED_OVERRIDE_LIVE_OWNER         -> when set to a LIVE pid, owner.pid and
  #                                           owner.process_start_us are set so the
  #                                           reconciler's owner_is_live() returns
  #                                           True; used to prove structural
  #                                           validation runs BEFORE owner-liveness
  #                                           (R6 CODE-M4).
  PREPARED_OVERRIDE_OWNER_PID="${PREPARED_OVERRIDE_OWNER_PID:-}" \
  PREPARED_OVERRIDE_PROCESS_START_US="${PREPARED_OVERRIDE_PROCESS_START_US:-}" \
  PREPARED_OVERRIDE_HANDOFF_OPERATION="${PREPARED_OVERRIDE_HANDOFF_OPERATION:-}" \
  PREPARED_OVERRIDE_SERVICE_IDENTITY="${PREPARED_OVERRIDE_SERVICE_IDENTITY:-}" \
  PREPARED_OVERRIDE_TARGET_PATH="${PREPARED_OVERRIDE_TARGET_PATH:-}" \
  PREPARED_OVERRIDE_RECORD_VERSION="${PREPARED_OVERRIDE_RECORD_VERSION:-}" \
  PREPARED_OVERRIDE_HANDOFF_VERSION="${PREPARED_OVERRIDE_HANDOFF_VERSION:-}" \
  PREPARED_OVERRIDE_LIVE_OWNER="${PREPARED_OVERRIDE_LIVE_OWNER:-}" \
  python3 - "$out_path" "$operation_id" "$owner_pid" "$expiry" "$record_kind" <<'PY'
import ctypes
import json
import os
import struct
import subprocess
import sys
import time

out_path, operation_id, owner_pid_text, expiry, record_kind = sys.argv[1:]
owner_pid = int(owner_pid_text)
override_owner_pid = os.environ.get("PREPARED_OVERRIDE_OWNER_PID", "")
if override_owner_pid:
    owner_pid = int(override_owner_pid)
override_process_start_us = os.environ.get("PREPARED_OVERRIDE_PROCESS_START_US", "")
process_start_us = int(override_process_start_us) if override_process_start_us else 1


def _live_process_start_us(pid):
    # The EXACT microsecond process_start_us the reconciler's owner_is_live()
    # compares against, read via the SAME sysctl kinfo_proc.p_starttime path
    # (matching process_start_microseconds in install.sh). A LIVE pid with this
    # exact start makes owner_is_live() return True; the R8 exact-identity fix
    # rejects a whole-second-scaled start, so the fixture must carry the true
    # microsecond value.
    if pid <= 0 or pid > 2**31 - 1:
        return 1
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.sysctl.argtypes = [
            ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
        ]
        libc.sysctl.restype = ctypes.c_int
        mib = (ctypes.c_int * 4)(1, 14, 1, pid)  # CTL_KERN, KERN_PROC, KERN_PROC_PID, pid
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 4, None, ctypes.byref(size), None, 0) != 0 or size.value < 12:
            return 1
        buffer = ctypes.create_string_buffer(size.value)
        buffer_size = ctypes.c_size_t(size.value)
        if libc.sysctl(mib, 4, buffer, ctypes.byref(buffer_size), None, 0) != 0:
            return 1
        data = buffer.raw[:buffer_size.value]
        if len(data) < 12:
            return 1
        tv_sec, tv_usec = struct.unpack_from("=qi", data, 0)
    except (OSError, ValueError, struct.error):
        return 1
    if tv_sec <= 0 or not (0 <= tv_usec < 1_000_000):
        return 1
    return tv_sec * 1_000_000 + tv_usec


override_live_owner = os.environ.get("PREPARED_OVERRIDE_LIVE_OWNER", "")
if override_live_owner:
    owner_pid = int(override_live_owner)
    process_start_us = _live_process_start_us(owner_pid)
override_record_version = os.environ.get("PREPARED_OVERRIDE_RECORD_VERSION", "")
override_handoff_version = os.environ.get("PREPARED_OVERRIDE_HANDOFF_VERSION", "")


def _version_value(raw, default):
    # Interpret an override token as its JSON scalar: "true"/"false" -> bool,
    # otherwise an integer. Emitting a JSON boolean lets the fixture exercise the
    # record/handoff version field's non-bool integer predicate (R6 CODE-M1).
    if raw == "":
        return default
    if raw == "true":
        return True
    if raw == "false":
        return False
    return int(raw)


override_handoff_operation = os.environ.get("PREPARED_OVERRIDE_HANDOFF_OPERATION", "")
handoff_operation_id = override_handoff_operation or operation_id
override_service_identity = os.environ.get("PREPARED_OVERRIDE_SERVICE_IDENTITY", "")
service_identity = override_service_identity or "live.streamvc.macprovider"
override_target_path = os.environ.get("PREPARED_OVERRIDE_TARGET_PATH", "")
target_executable_path = (
    override_target_path
    or "/Applications/MacProvider.app/Contents/MacOS/macprovider-cli"
)


def boot_session():
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip() if result.returncode == 0 else ""
    return value or "00000000-0000-0000-0000-000000000000"


boot = boot_session()
wall_now = int(time.time() * 1_000)
mono_now = int(time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW))

# Record window: opened 5 minutes ago, closes 15 minutes from now (a
# maintenance lease, well inside its own bounds right now).
record_issued_wall = wall_now - 5 * 60 * 1_000
record_expires_wall = wall_now + 15 * 60 * 1_000
record_issued_mono = mono_now - 5 * 60 * 1_000_000_000
record_expires_mono = mono_now + 15 * 60 * 1_000_000_000

if expiry == "expired":
    # Handoff issued 10 minutes ago and already expired 1 minute ago: the
    # exemption must NOT apply, so the dead owner path removes the lease.
    handoff_issued_wall = wall_now - 10 * 60 * 1_000
    handoff_expires_wall = wall_now - 60 * 1_000
    handoff_issued_mono = mono_now - 10 * 60 * 1_000_000_000
    handoff_expires_mono = mono_now - 60 * 1_000_000_000
elif expiry == "expired_short":
    # A STRUCTURALLY VALID handoff window (3.5-min duration, inside the 5-min
    # handoff ceiling and contained by the record window) that is nonetheless
    # EXPIRED: issued 4 minutes ago, closed 30 seconds ago. Unlike "expired"
    # (whose 9-min duration record_matches_swift_structure would reject), this
    # passes structure so the ONLY reason to REMOVE is the handoff-window gate --
    # exactly Swift's ~900..901 .wallExpired / .monotonicExpired. Used with a
    # LIVE owner to prove a prepared-handoff record is governed SOLELY by the
    # handoff window, never by owner liveness (the remaining-surface fix).
    handoff_issued_wall = wall_now - 4 * 60 * 1_000
    handoff_expires_wall = wall_now - 30 * 1_000
    handoff_issued_mono = mono_now - 4 * 60 * 1_000_000_000
    handoff_expires_mono = mono_now - 30 * 1_000_000_000
else:
    # A live prepared handoff window that currently brackets `now` and stays
    # inside the record window (Swift requires handoff.expires <= record.expires).
    handoff_issued_wall = wall_now - 60 * 1_000
    handoff_expires_wall = wall_now + 4 * 60 * 1_000
    handoff_issued_mono = mono_now - 60 * 1_000_000_000
    handoff_expires_mono = mono_now + 4 * 60 * 1_000_000_000

handoff = {
    "version": _version_value(override_handoff_version, 1),
    "handoff_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "state": "prepared",
    "operation_id": handoff_operation_id,
    "provider_id": "provider-a",
    "service_identity": service_identity,
    "boot_session": boot,
    "target_executable_path": target_executable_path,
    "target_executable_sha256": "a" * 64,
    "issued_wall_ms": handoff_issued_wall,
    "expires_wall_ms": handoff_expires_wall,
    "issued_monotonic_ns": handoff_issued_mono,
    "expires_monotonic_ns": handoff_expires_mono,
    "startup_lease_duration_ms": 5 * 60 * 1_000,
}

record = {
    "version": _version_value(override_record_version, 1),
    "lease_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "operation_id": operation_id,
    # Default "maintenance" is the only kind Swift permits to carry a prepared
    # handoff. Tests pass "startup" to build a record that is store-READABLE but
    # structurally invalid per Swift's validateStartupHandoffStructure, so the
    # reconciler must decline the exemption and REMOVE it.
    "kind": record_kind,
    "owner": {
        # A dead pid: the preparer has exited. process_start_us is a fixed
        # non-live marker so the owner-liveness path would reject it -- proving
        # preservation here comes solely from the prepared-handoff exemption.
        # Both are override-able (env) to exercise the Int32/Int64 wire bounds.
        "pid": owner_pid,
        "process_start_us": process_start_us,
        "boot_session": boot,
    },
    "issued_wall_ms": record_issued_wall,
    "expires_wall_ms": record_expires_wall,
    "issued_monotonic_ns": record_issued_mono,
    "expires_monotonic_ns": record_expires_mono,
    "startup_handoff": handoff,
}
with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

# Make the full-schema record author available to the inner `bash -c` harness,
# which runs as a fresh shell that only sources the extracted install functions.
declare -f write_full_schema_record >> "$TMP/functions.sh"

make_case() {
  case_name="$1"
  root="$TMP/$case_name"
  home="$root/home"
  mkdir -p "$root/bin" "$home/macprovider" "$home/.local/bin" \
    "$home/.config/macprovider" "$home/Library/LaunchAgents" "$root/tx" \
    "$home/.local/share/macprovider-watchdog" "$home/Library/Application Support/macprovider"
  printf 'old-binary\n' > "$home/macprovider/macprovider-cli"
  printf 'old-resource\n' > "$home/macprovider/mlx.metallib"
  chmod +x "$home/macprovider/macprovider-cli"
  ln -s "$home/macprovider/macprovider-cli" "$home/.local/bin/macprovider-cli"
  printf 'model: old-model\nprovider_id: upgrade-provider\n' > "$home/.config/macprovider/config.yaml"
  printf 'upgrade-provider\n' > "$home/.config/macprovider/provider_id"
  printf '{"model_id":"old-model","generated_at":"old"}\n' > "$home/.config/macprovider/last-recommendation.json"
  printf '<plist>old</plist>\n' > "$home/Library/LaunchAgents/live.streamvc.macprovider.plist"
  printf 'old-watchdog\n' > "$home/.local/share/macprovider-watchdog/macprovider-health-monitor"
  printf '<plist>old-watchdog</plist>\n' > "$home/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
  printf '{"version":"old"}\n' > "$home/Library/Application Support/macprovider/install_manifest.json"
  # Seed a prior lifecycle-state file by default so rollback must restore its
  # exact prior contents; the lifecycle_absent_* cases delete it to exercise the
  # restore-prior-absence path. The directory (0700) and file (0600) match the
  # real CLI store posture the installer now validates before snapshotting; the
  # record is FULL-schema (authority/writer/operation_id/sequence/
  # transition_id/... plus operator_paused and version) to match real store
  # output, not a reduced fixture.
  lifecycle_dir="$home/Library/Application Support/macprovider/lifecycle"
  mkdir -p "$lifecycle_dir"
  chmod 700 "$home/Library/Application Support/macprovider" "$lifecycle_dir"
  write_full_schema_record \
    "$lifecycle_dir/state-v1.json" \
    serving install_committed installer serve-op-0001 41 false \
    '11111111-1111-4111-8111-111111111111'
  chmod 600 "$lifecycle_dir/state-v1.json"
  : > "$root/service-active"
  : > "$root/watchdog-service-active"
  : > "$root/launchctl.log"

  cat > "$root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
service_file="$CASE_ROOT/service-active"
disabled_file="$CASE_ROOT/service-disabled"
case "$*" in
  *macprovider-install-recovery*)
    service_file="$CASE_ROOT/recovery-service-active"
    disabled_file="$CASE_ROOT/recovery-service-disabled"
    ;;
  *macprovider-watchdog*)
    service_file="$CASE_ROOT/watchdog-service-active"
    disabled_file="$CASE_ROOT/watchdog-service-disabled"
    ;;
esac
case "$1" in
  print)
    [ -f "$service_file" ] || exit 1
    ;;
  print-disabled)
    printf 'disabled services = {\n'
    [ ! -f "$CASE_ROOT/service-disabled" ] || printf '  "live.streamvc.macprovider" => true\n'
    [ ! -f "$CASE_ROOT/watchdog-service-disabled" ] || printf '  "live.streamvc.macprovider-watchdog" => true\n'
    printf '}\n'
    ;;
  bootout)
    [ "${FAIL_ACTION:-}" != "bootout" ] || exit 41
    rm -f "$service_file"
    ;;
  bootstrap)
    if printf '%s' "$*" | grep -q 'macprovider-install-recovery'; then
      : > "$service_file"
      exit 0
    fi
    if [ "${FAIL_ONCE_ACTION:-}" = "bootstrap" ] && [ -f "$CASE_ROOT/fail-once" ]; then
      rm -f "$CASE_ROOT/fail-once"
      exit 42
    fi
    [ "${FAIL_ACTION:-}" != "bootstrap" ] || exit 42
    : > "$service_file"
    ;;
  kickstart)
    if printf '%s' "$*" | grep -q 'macprovider-install-recovery'; then
      exit 0
    fi
    if [ "${FAIL_ONCE_ACTION:-}" = "kickstart" ] && [ -f "$CASE_ROOT/fail-once" ]; then
      rm -f "$CASE_ROOT/fail-once"
      exit 43
    fi
    [ "${FAIL_ACTION:-}" != "kickstart" ] || exit 43
    ;;
  enable) rm -f "$disabled_file" ;;
  disable) : > "$disabled_file" ;;
esac
exit 0
EOF
  chmod +x "$root/bin/launchctl"

  cat > "$root/bin/cp" <<'EOF'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
if [ -f "$CASE_ROOT/fail-backup-cp" ] && printf '%s' "$last" | grep -q '\.staging/install-dir$'; then
  exit 51
fi
if [ -f "$CASE_ROOT/fail-restore-cp" ] && printf '%s' "$last" | grep -q '\.macprovider-restore\.'; then
  exit 52
fi
exec /bin/cp "$@"
EOF
  chmod +x "$root/bin/cp"

  cat > "$root/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ -f "$CASE_ROOT/fail-config-mv" ] && [ "${1:-}" = "$CASE_ROOT/home/.config/macprovider/config.yaml" ]; then
  exit 61
fi
exec /bin/mv "$@"
EOF
  chmod +x "$root/bin/mv"

  cat > "$root/bin/rm" <<'EOF'
#!/usr/bin/env bash
if [ -f "$CASE_ROOT/fail-retired-rm" ]; then
  for argument in "$@"; do
    case "$argument" in
      *.committed.*) exit 62 ;;
    esac
  done
fi
exec /bin/rm "$@"
EOF
  chmod +x "$root/bin/rm"

  cat > "$root/bin/lsof" <<'EOF'
#!/usr/bin/env bash
arguments="$*"
requested_pid=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then requested_pid="$argument"; fi
  previous="$argument"
done
manual_pid=""
if [ -n "$requested_pid" ] && kill -0 "$requested_pid" >/dev/null 2>&1; then
  manual_pid="$requested_pid"
elif [ -s "$CASE_ROOT/manual-current.pid" ]; then
  candidate="$(cat "$CASE_ROOT/manual-current.pid")"
  if kill -0 "$candidate" >/dev/null 2>&1; then manual_pid="$candidate"; fi
fi
[ -n "$manual_pid" ] || exit 1
if printf '%s\n' "$arguments" | grep -q -- '-d txt'; then
  printf 'p%s\nn%s\n' "$manual_pid" "$CASE_ROOT/home/macprovider/macprovider-cli"
elif printf '%s\n' "$arguments" | grep -q -- '-d cwd'; then
  printf 'p%s\nn%s\n' "$manual_pid" "$CASE_ROOT/manual-cwd"
elif printf ' %s ' "$arguments" | grep -q -- ' -t '; then
  [ ! -f "$CASE_ROOT/manual-never-bind" ] || exit 1
  printf '%s\n' "$manual_pid"
else
  printf 'COMMAND PID\nmacprovider-cli %s\n' "$manual_pid"
fi
EOF
  chmod +x "$root/bin/lsof"

  cat > "$root/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [ -s "$CASE_ROOT/manual-current.pid" ]; then
  pid="$(cat "$CASE_ROOT/manual-current.pid")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    printf '%s %s --port %s\n' "$pid" "$CASE_ROOT/home/macprovider/macprovider-cli" "$(cat "$CASE_ROOT/manual-port")"
    exit 0
  fi
fi
exit 1
EOF
  chmod +x "$root/bin/pgrep"
}

start_manual_fixture() {
  root="$1"
  port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  cat > "$root/manual-provider.c" <<'EOF'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void write_hex(FILE *log, const char *value) {
  for (const unsigned char *p = (const unsigned char *)value; *p != '\0'; p++) fprintf(log, "%02x", *p);
}

int main(int argc, char **argv) {
  int port = 0;
  const char *log_path = NULL;
  const char *bind_gate = NULL;
  for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "--port") == 0) port = atoi(argv[i + 1]);
  for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "--fixture-log") == 0) log_path = argv[i + 1];
  for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "--bind-gate") == 0) bind_gate = argv[i + 1];
  if (port <= 0 || log_path == NULL || bind_gate == NULL) return 2;
  int never_bind = access(bind_gate, F_OK) == 0;
  if (never_bind) {
    signal(SIGTERM, SIG_IGN);
  } else {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) return 3;
  }
  FILE *log = fopen(log_path, "a");
  if (!log) return 4;
  fprintf(log, "%d", getpid());
  for (int i = 1; i < argc; i++) {
    fprintf(log, "|");
    for (const unsigned char *p = (const unsigned char *)argv[i]; *p != '\0'; p++) fprintf(log, "%02x", *p);
  }
  fprintf(log, "\n");
  fclose(log);
  char cwd[4096];
  const char *context = getenv("MACPROVIDER_RECOVERY_CONTEXT");
  const char *path = getenv("PATH");
  char context_path[8192];
  if (getcwd(cwd, sizeof(cwd)) == NULL || context == NULL || path == NULL) return 5;
  if (snprintf(context_path, sizeof(context_path), "%s.context", log_path) >= (int)sizeof(context_path)) return 6;
  FILE *context_log = fopen(context_path, "a");
  if (!context_log) return 7;
  fprintf(context_log, "%d|", getpid());
  write_hex(context_log, cwd);
  fprintf(context_log, "|");
  write_hex(context_log, context);
  fprintf(context_log, "|");
  write_hex(context_log, path);
  fprintf(context_log, "\n");
  fclose(context_log);
  for (;;) pause();
}
EOF
  cc -O2 -o "$root/home/macprovider/macprovider-cli" "$root/manual-provider.c"
  shasum -a 256 "$root/home/macprovider/macprovider-cli" | awk '{print $1}' > "$root/manual-old.sha256"
  printf '%s\n' "$port" > "$root/manual-port"
  mkdir -p "$root/manual-cwd"
  # Literal shell syntax and lossy-ps edge cases prove argv is captured from
  # KERN_PROCARGS2 and replayed as bytes, never parsed or evaluated by a shell.
  # shellcheck disable=SC2016
  (
    cd "$root/manual-cwd"
    MACPROVIDER_RECOVERY_CONTEXT=$'exact context with spaces\tand tab; $(not evaluated)' \
      PATH="$root/bin:/usr/bin:/bin" \
      exec "$root/home/macprovider/macprovider-cli" --port "$port" --model old-model \
        --fixture-log "$root/manual-fixture.log" \
        --bind-gate "$root/manual-never-bind" \
        --whitespace $'two words\twith tab' \
        --quotes "say \"hello\" and 'goodbye'" \
        --backslashes 'C:\Models\Qwen\file' \
        --metacharacters ';touch ${IFS}'"$root/pwned"' & | $(printf nope) * ? [x]'
  ) &
  manual_pid=$!
  printf '%s\n' "$manual_pid" > "$root/manual-current.pid"
  for _ in $(seq 1 20); do
    kill -0 "$manual_pid" >/dev/null 2>&1 && [ -s "$root/manual-fixture.log" ] && return 0
    sleep 0.1
  done
  return 1
}

run_case() {
  case_name="$1"
  fail_action="${2:-}"
  pre_begin_fault="${3:-}"
  rollback_fault="${4:-}"
  install_phase="${5:-mutation}"
  prior_state="${6:-active}"
  manual_behavior="${7:-bind}"
  lifecycle_behavior="${8:-present}"
  root="$TMP/$case_name"
  make_case "$case_name"
  lifecycle_root_dir="$root/home/Library/Application Support/macprovider/lifecycle"
  lifecycle_state_file="$lifecycle_root_dir/state-v1.json"
  case "$lifecycle_behavior" in
    absent-before)
      # An incumbent that predates the lifecycle contract has no state file at
      # transaction start. Rollback must restore that absence exactly.
      rm -rf "$lifecycle_root_dir"
      ;;
    symlink-file)
      # S-M2: the state file is a symlink to an out-of-tree secret. The snapshot
      # must refuse it (no dereference) and abort pre-mutation.
      printf 'attacker-controlled\n' > "$root/outside-secret"
      rm -f "$lifecycle_state_file"
      ln -s "$root/outside-secret" "$lifecycle_state_file"
      ;;
    symlink-parent)
      # S-M2: the lifecycle directory itself is a symlink. Abort pre-mutation.
      rm -rf "$lifecycle_root_dir"
      mkdir -p "$root/elsewhere-lifecycle"
      chmod 700 "$root/elsewhere-lifecycle"
      write_full_schema_record "$root/elsewhere-lifecycle/state-v1.json" \
        serving install_committed installer serve-op-0001 41 false \
        '11111111-1111-4111-8111-111111111111'
      chmod 600 "$root/elsewhere-lifecycle/state-v1.json"
      ln -s "$root/elsewhere-lifecycle" "$lifecycle_root_dir"
      ;;
    wrong-mode)
      # S-M2: a world-readable state file (0644) must be rejected even though it
      # is otherwise a valid owned regular file.
      chmod 644 "$lifecycle_state_file"
      ;;
    oversized)
      # S-M2: a state file larger than the 1MB bound must be rejected.
      python3 -c 'import sys; open(sys.argv[1],"wb").write(b"{}\n"+b"x"*(1024*1024+16))' \
        "$lifecycle_state_file"
      chmod 600 "$lifecycle_state_file"
      ;;
    updater-snapshot)
      # A-01: the snapshot is an updater-written maintenance record with a dead
      # operation id. Rollback must translate it to an installer-owned record so
      # a restored lifecycle-aware CLI cannot be fenced.
      write_full_schema_record "$lifecycle_state_file" \
        update_in_progress update_admission_pending updater updater-dead-op-9999 55 false \
        '33333333-3333-4333-8333-333333333333'
      chmod 600 "$lifecycle_state_file"
      ;;
    serve-snapshot)
      # A-01: a serve-written snapshot restores byte-exact (serve can always
      # leave its own state; no fencing risk, no translation).
      write_full_schema_record "$lifecycle_state_file" \
        serving_buyers serving_ready serve serve-live-op-7777 60 false \
        '44444444-4444-4444-8444-444444444444'
      chmod 600 "$lifecycle_state_file"
      ;;
  esac
  if [ "$prior_state" = "disabled-inactive" ]; then
    rm -f "$root/service-active" "$root/watchdog-service-active"
    : > "$root/service-disabled"
    : > "$root/watchdog-service-disabled"
  fi
  if [ "$prior_state" = "manual" ]; then
    rm -f "$root/service-active"
    start_manual_fixture "$root"
  fi
  if [ "$install_phase" = "credential-self-test" ]; then
    printf 'model: old-model\n' > "$root/home/.config/macprovider/config.yaml"
  elif [ "$install_phase" = "ordinary-token-self-test" ]; then
    printf 'model: old-model\nprovider_id: upgrade-provider\nprovider_token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' \
      > "$root/home/.config/macprovider/config.yaml"
  fi
  [ -z "$pre_begin_fault" ] || : > "$root/$pre_begin_fault"

  set +e
  PATH="$root/bin:/usr/bin:/bin" \
    LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" FAIL_ACTION="$fail_action" FAIL_ONCE_ACTION="" \
    FUNCTIONS_PATH="$TMP/functions.sh" \
    PRE_BEGIN_FAULT="$pre_begin_fault" ROLLBACK_FAULT="$rollback_fault" INSTALL_PHASE="$install_phase" \
    MANUAL_BEHAVIOR="$manual_behavior" \
    MUTATION_LIFECYCLE_STATE="${MUTATION_LIFECYCLE_STATE:-}" \
    MUTATION_LIFECYCLE_WRITER="${MUTATION_LIFECYCLE_WRITER:-}" \
    MUTATION_LIFECYCLE_SEQUENCE="${MUTATION_LIFECYCLE_SEQUENCE:-}" \
    MUTATION_LIFECYCLE_OPERATOR_PAUSED="${MUTATION_LIFECYCLE_OPERATOR_PAUSED:-}" \
    MUTATION_LEASE_JSON="${MUTATION_LEASE_JSON:-}" \
    MUTATION_LEASE_RAW_PATH="${MUTATION_LEASE_RAW_PATH:-}" \
    MUTATION_LEASE_MODE="${MUTATION_LEASE_MODE:-}" \
    MUTATION_LEASE_HARDLINK="${MUTATION_LEASE_HARDLINK:-}" \
    MUTATION_LEASE_OPERATION_ID="${MUTATION_LEASE_OPERATION_ID:-}" \
    RECOVERY_LIFECYCLE_FAULT="${RECOVERY_LIFECYCLE_FAULT:-}" \
    bash -c '
      set -euo pipefail
      HOME="$CASE_ROOT/home"
      INSTALL_DIR="$HOME/macprovider"
      BIN_DIR="$HOME/.local/bin"
      BINARY_PATH="$BIN_DIR/macprovider-cli"
      CONFIG_DIR="$HOME/.config/macprovider"
      CONFIG_PATH="$CONFIG_DIR/config.yaml"
      PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
      RECOMMENDATION_PATH="$CONFIG_DIR/last-recommendation.json"
      INSTALL_LOCK_PATH="$CONFIG_DIR/install.lock"
      INSTALL_RECOVERY_LABEL="live.streamvc.macprovider-install-recovery"
      INSTALL_RECOVERY_PLIST_PATH="$HOME/Library/LaunchAgents/${INSTALL_RECOVERY_LABEL}.plist"
      PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
      WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
      WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
      WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
      MANIFEST_PATH="$HOME/Library/Application Support/macprovider/install_manifest.json"
      LIFECYCLE_STATE_PATH="$HOME/Library/Application Support/macprovider/lifecycle/state-v1.json"
      LIFECYCLE_LEASE_PATH="$HOME/Library/Application Support/macprovider/lifecycle/lease.json"
      LIFECYCLE_STATE_LOCK_PATH="$HOME/Library/Application Support/macprovider/lifecycle/.state-v1.json.lock"
      LIFECYCLE_LEASE_LOCK_PATH="$HOME/Library/Application Support/macprovider/lifecycle/.lease.json.lock"
      # The special parameter for this bash -c subprocess PID differs from the
      # parent test shell PID. Cases that need the reconciler to actually MATCH a
      # lease operation_id (belongs_to_rollback) must pin a deterministic
      # operation id shared with the fixture via MUTATION_LEASE_OPERATION_ID;
      # otherwise fall back to the historical per-subprocess default (correct for
      # dead-owner cases that never rely on the operation match).
      LIFECYCLE_INSTALL_OPERATION_ID="${MUTATION_LEASE_OPERATION_ID:-install:test-$$}"
      LOG_DIR="$HOME/Library/Logs/macprovider"
      TMPDIR_PATH="$CASE_ROOT/tx"
      PORT="$(cat "$CASE_ROOT/manual-port" 2>/dev/null || printf 18080)"
      MANUAL_PID=""
      DRY_RUN=0
      INSTALL_TX_ACTIVE=0
      INSTALL_TX_COMMITTED=0
      INSTALL_TX_BACKUP=""
      INSTALL_TX_SERVICE_WAS_ACTIVE=0
      INSTALL_TX_HAD_INSTALL_DIR=0
      INSTALL_TX_HAD_BINARY_PATH=0
      INSTALL_TX_HAD_CONFIG=0
      INSTALL_TX_HAD_PROVIDER_ID=0
      INSTALL_TX_HAD_RECOMMENDATION=0
      INSTALL_TX_HAD_PLIST=0
      INSTALL_TX_HAD_WATCHDOG_DIR=0
      INSTALL_TX_HAD_WATCHDOG_PLIST=0
      INSTALL_TX_HAD_MANIFEST=0
      INSTALL_TX_HAD_LIFECYCLE_STATE=0
      INSTALL_TX_LIFECYCLE_SNAPSHOT_WRITER=""
      INSTALL_TX_LIFECYCLE_SNAPSHOT_OPERATOR_PAUSED=false
      INSTALL_TX_SERVICE_WAS_DISABLED=0
      INSTALL_TX_WATCHDOG_WAS_ACTIVE=0
      INSTALL_TX_WATCHDOG_WAS_DISABLED=0
      INSTALL_TX_ROLLING_BACK=0
      INSTALL_TX_BINARY_KIND="symlink"
      CUTOVER_STARTED=0
      INSTALL_LOCK_HELD=0
      INSTALL_LOCK_TOKEN="test-lock-token"
      INSTALL_LOCK_HOLDER_PID=""
      log() { printf "[test] %s\n" "$*" >&2; }
      die() { code="$1"; shift; printf "[test] ERROR: %s\n" "$*" >&2; exit "$code"; }
      source "$FUNCTIONS_PATH"
      # Mutex ownership is covered by install_transaction_lock.test.sh. These
      # fixtures isolate transaction snapshot/rollback behavior without a live
      # background flock helper.
      assert_install_lock_ownership() { :; }
      trap cleanup EXIT
      begin_install_transaction
      if [ "$INSTALL_PHASE" = "pre-cutover" ]; then
        exit 9
      fi
      mark_install_cutover_started
      if [ "$INSTALL_PHASE" = "manual-self-test" ]; then
        ensure_port_free 1
        if [ "$MANUAL_BEHAVIOR" = "never-bind" ]; then
          printf "REC_MANUAL_READY_TIMEOUT_SECONDS=1\n" >> "$INSTALL_TX_BACKUP/state.sh"
          : > "$CASE_ROOT/manual-never-bind"
        fi
        printf "new-binary\n" > "$INSTALL_DIR/macprovider-cli.new"
        chmod +x "$INSTALL_DIR/macprovider-cli.new"
        mv "$INSTALL_DIR/macprovider-cli.new" "$INSTALL_DIR/macprovider-cli"
      else
        printf "new-binary\n" > "$INSTALL_DIR/macprovider-cli"
      fi
      printf "new-resource\n" > "$INSTALL_DIR/mlx.metallib"
      if [ "$INSTALL_PHASE" = "credential-self-test" ]; then
        printf "model: new-model\nprovider_id: mp-0123456789abcdef0123456789abcdef\nprovider_token: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" > "$CONFIG_PATH"
        printf "mp-0123456789abcdef0123456789abcdef\n" > "$PROVIDER_ID_PATH"
      elif [ "$INSTALL_PHASE" = "ordinary-token-self-test" ]; then
        printf "model: new-model\nprovider_id: upgrade-provider\nprovider_token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" > "$CONFIG_PATH"
        printf "upgrade-provider\n" > "$PROVIDER_ID_PATH"
      else
        printf "model: new-model\nprovider_id: upgrade-provider\n" > "$CONFIG_PATH"
        printf "new-provider\n" > "$PROVIDER_ID_PATH"
      fi
      printf "{\"model_id\":\"new-model\",\"generated_at\":\"new\"}\n" > "$RECOMMENDATION_PATH"
      printf "<plist>new</plist>\n" > "$PLIST_PATH"
      printf "new-watchdog\n" > "$WATCHDOG_DIR/macprovider-health-monitor"
      printf "<plist>new-watchdog</plist>\n" > "$WATCHDOG_PLIST_PATH"
      printf "{\"version\":\"new\"}\n" > "$MANIFEST_PATH"
      # The new install authors a fresh lifecycle state the legacy incumbent
      # cannot clear on rollback. Rollback must restore the reconciled prior
      # contents, or (for an incumbent that had no lifecycle file) the prior
      # absence. The live intermediate is FULL-schema. Cases can override the
      # live writer/pause via MUTATION_LIFECYCLE_* to exercise operator-pause
      # reconciliation set during the transaction.
      mkdir -p "$(dirname "$LIFECYCLE_STATE_PATH")"
      chmod 700 "$(dirname "$LIFECYCLE_STATE_PATH")"
      write_full_schema_record \
        "$LIFECYCLE_STATE_PATH" \
        "${MUTATION_LIFECYCLE_STATE:-rollback_in_progress}" \
        install_admission_failed \
        "${MUTATION_LIFECYCLE_WRITER:-installer}" \
        "install:test-$$" \
        "${MUTATION_LIFECYCLE_SEQUENCE:-183}" \
        "${MUTATION_LIFECYCLE_OPERATOR_PAUSED:-false}" \
        '22222222-2222-4222-8222-222222222222'
      chmod 600 "$LIFECYCLE_STATE_PATH"
      if [ -n "${MUTATION_LEASE_RAW_PATH:-}" ]; then
        # Byte-exact raw lease injection (R6 CODE-M2): NaN/duplicate-key/unpaired-
        # surrogate fixtures cannot survive an env-var + printf round-trip, so the
        # bytes are copied verbatim from a fixture file the parent shell built.
        cp "$MUTATION_LEASE_RAW_PATH" "$LIFECYCLE_LEASE_PATH"
        chmod "${MUTATION_LEASE_MODE:-600}" "$LIFECYCLE_LEASE_PATH"
      elif [ -n "${MUTATION_LEASE_JSON:-}" ]; then
        # Double quotes here: this block runs inside the single-quoted `bash -c`
        # harness, so a single-quoted format string would break out of the outer
        # quote and drop the backslash from \n.
        printf "%s\n" "$MUTATION_LEASE_JSON" > "$LIFECYCLE_LEASE_PATH"
        chmod "${MUTATION_LEASE_MODE:-600}" "$LIFECYCLE_LEASE_PATH"
      fi
      if [ -n "${MUTATION_LEASE_HARDLINK:-}" ] && [ -e "$LIFECYCLE_LEASE_PATH" ]; then
        # Storage-envelope negative (R6 CODE-M3): a second hard link makes
        # st_nlink == 2, which the Swift store rejects on read as .unsafeStorage
        # ("hard link"); the reconciler must REMOVE such a lease. The extra link
        # lives beside the lease so unlinking the lease path still leaves it (the
        # test asserts the lease path itself is gone).
        ln "$LIFECYCLE_LEASE_PATH" "${LIFECYCLE_LEASE_PATH}.hardlink"
      fi
      case "$INSTALL_PHASE" in
        plist|watchdog) exit 9 ;;
        bootstrap)
          launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
          : > "$CASE_ROOT/fail-once"
          FAIL_ONCE_ACTION=bootstrap launchctl bootstrap "gui/$UID" "$PLIST_PATH"
          ;;
        kickstart)
          launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
          launchctl bootstrap "gui/$UID" "$PLIST_PATH"
          : > "$CASE_ROOT/fail-once"
          FAIL_ONCE_ACTION=kickstart launchctl kickstart -k "gui/$UID/live.streamvc.macprovider"
          ;;
        manual-self-test) exit 9 ;;
        new-manual-self-test)
          cat > "$INSTALL_DIR/macprovider-cli" <<'MANUAL'
#!/usr/bin/env bash
trap "" TERM
while :; do sleep 1; done
MANUAL
          chmod +x "$INSTALL_DIR/macprovider-cli"
          "$INSTALL_DIR/macprovider-cli" &
          MANUAL_PID=$!
          printf "%s\n" "$MANUAL_PID" > "$CASE_ROOT/new-manual.pid"
          kill -0 "$MANUAL_PID"
          exit 9
          ;;
        self-test|credential-self-test|ordinary-token-self-test)
          launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
          launchctl bootout "gui/$UID" "$WATCHDOG_PLIST_PATH" >/dev/null 2>&1 || true
          launchctl enable "gui/$UID/live.streamvc.macprovider"
          launchctl enable "gui/$UID/$WATCHDOG_LABEL"
          launchctl bootstrap "gui/$UID" "$PLIST_PATH"
          launchctl kickstart -k "gui/$UID/live.streamvc.macprovider"
          launchctl bootstrap "gui/$UID" "$WATCHDOG_PLIST_PATH"
          launchctl kickstart -k "gui/$UID/$WATCHDOG_LABEL"
          exit 9
          ;;
        commit-cleanup)
          : > "$CASE_ROOT/fail-retired-rm"
          commit_install_transaction
          exit 0
          ;;
        commit-clean)
          commit_install_transaction
          exit 0
          ;;
      esac
      case "$ROLLBACK_FAULT" in
        fail-restore-cp|fail-config-mv) : > "$CASE_ROOT/$ROLLBACK_FAULT" ;;
      esac
      exit 9
    ' > "$root/stdout.log" 2> "$root/stderr.log"
  case_rc=$?
  set -e
  printf '%s\n' "$case_rc" > "$root/rc"
  if [ "$case_rc" -eq 1 ]; then
    cat "$root/stderr.log" >&2
  fi
  if { [ "$install_phase" = "manual-self-test" ] || [ "$install_phase" = "new-manual-self-test" ]; } \
      && [ "$case_rc" -ne 9 ]; then
    cat "$root/stderr.log" >&2
  fi
}

# Assert the non-lifecycle installation was rolled back. Cases whose snapshot is
# translated (updater-written) restore a rollback_in_progress record on purpose,
# so those assert files only and check the lifecycle record separately.
assert_old_install_files() {
  root="$1"
  home="$root/home"
  grep -F 'old-binary' "$home/macprovider/macprovider-cli" >/dev/null
  grep -F 'old-resource' "$home/macprovider/mlx.metallib" >/dev/null
  grep -F 'model: old-model' "$home/.config/macprovider/config.yaml" >/dev/null
  grep -F 'upgrade-provider' "$home/.config/macprovider/provider_id" >/dev/null
  grep -F '"model_id":"old-model"' "$home/.config/macprovider/last-recommendation.json" >/dev/null
  grep -F '<plist>old</plist>' "$home/Library/LaunchAgents/live.streamvc.macprovider.plist" >/dev/null
  grep -F 'old-watchdog' "$home/.local/share/macprovider-watchdog/macprovider-health-monitor" >/dev/null
  grep -F '<plist>old-watchdog</plist>' "$home/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist" >/dev/null
  grep -F '"version":"old"' "$home/Library/Application Support/macprovider/install_manifest.json" >/dev/null
  [ "$(readlink "$home/.local/bin/macprovider-cli")" = "$home/macprovider/macprovider-cli" ]
}

assert_old_install() {
  root="$1"
  home="$root/home"
  assert_old_install_files "$root"
  # The lifecycle-state file is part of the transaction: for an installer- or
  # serve-written snapshot rollback restores the exact prior serving state,
  # never the newer install/rollback state.
  grep -F '"state":"serving"' "$home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
  if grep -F '"state":"rollback_in_progress"' "$home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null; then
    echo "rollback left the newer lifecycle state behind instead of restoring the prior one" >&2
    return 1
  fi
}

recovery_dir() {
  find "$1/home/.config/macprovider" -maxdepth 1 -type d -name 'install-recovery-*' ! -name '*.staging' -print -quit
}

assert_recovery_preserved() {
  root="$1"
  recovery="$(recovery_dir "$root")"
  [ -n "$recovery" ]
  [ -s "$recovery/state.sh" ]
  [ -s "$recovery/recover.sh" ]
  [ -x "$recovery/observe.sh" ]
  grep -F 'REC_INSTALL_RECOVERY_LABEL=live.streamvc.macprovider-install-recovery' "$recovery/state.sh" >/dev/null
  grep -F 'fcntl.flock(lock_fd, fcntl.LOCK_EX)' "$recovery/observe.sh" >/dev/null
  grep -F "Run exactly: bash '$recovery/recover.sh'" "$root/stderr.log" >/dev/null
}

# Happy rollback: every old path and the active service are verified before the
# durable recovery bundle is removed. The original admission error is retained.
run_case success
[ "$(cat "$TMP/success/rc")" -eq 9 ]
assert_old_install "$TMP/success"
[ -f "$TMP/success/service-active" ]
[ -f "$TMP/success/watchdog-service-active" ]
[ -z "$(recovery_dir "$TMP/success")" ]
grep -F 'bootstrap gui/' "$TMP/success/launchctl.log" >/dev/null
grep -F 'kickstart -k gui/' "$TMP/success/launchctl.log" >/dev/null

# (a) Lifecycle-state rollback restores the exact prior contents byte-for-byte.
# The mutation phase overwrote the file with an installer-written
# rollback_in_progress state a legacy incumbent could never clear; because the
# snapshot was installer-written and unpaused, a healthy rollback restores the
# full-schema serving record byte-exact (no translation, no pause reconcile).
write_full_schema_record "$TMP/success/expected-serving.json" \
  serving install_committed installer serve-op-0001 41 false \
  '11111111-1111-4111-8111-111111111111'
lifecycle_old_hash="$(shasum -a 256 "$TMP/success/home/Library/Application Support/macprovider/lifecycle/state-v1.json" | awk '{print $1}')"
[ "$lifecycle_old_hash" = "$(shasum -a 256 "$TMP/success/expected-serving.json" | awk '{print $1}')" ]
# The restored file keeps the store's owned 0600 posture after rollback.
# Platform-branched mode read: GNU stat treats `-f` as a VALID flag
# (filesystem status, exit 0, garbage output), so a BSD-first
# `stat -f || stat -c` fallback never falls through on Linux — branch on
# uname instead. If the read fails (file unexpectedly absent), capture
# MISSING and fail loudly rather than tripping `set -e` silently.
if [ "$(uname -s)" = "Darwin" ]; then
  restored_perm="$(stat -f '%Lp' "$TMP/success/home/Library/Application Support/macprovider/lifecycle/state-v1.json" 2>/dev/null || printf MISSING)"
else
  restored_perm="$(stat -c '%a' "$TMP/success/home/Library/Application Support/macprovider/lifecycle/state-v1.json" 2>/dev/null || printf MISSING)"
fi
if [ "$restored_perm" != "600" ]; then
  echo "FAIL: restored lifecycle-state file mode is '$restored_perm' (expected 600); file likely absent or wrong-mode after rollback" >&2
  exit 1
fi

# (b) Lifecycle-state rollback restores prior ABSENCE. An incumbent with no
# lifecycle file must not gain a stranded state file after rollback; the file
# (and no leftover restore/candidate siblings) must be gone.
run_case lifecycle_absent_restore "" "" "" self-test active bind absent-before
root="$TMP/lifecycle_absent_restore"
[ "$(cat "$root/rc")" -eq 9 ]
grep -F 'old-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" ]; then
  echo "rollback stranded a lifecycle-state file where the incumbent had none" >&2
  exit 1
fi
if compgen -G "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json.macprovider-restore.*" >/dev/null; then
  echo "rollback left a lifecycle restore candidate behind" >&2
  exit 1
fi
[ -z "$(recovery_dir "$root")" ]

# (c) An interrupted rollback that is completed by re-running the recovery
# script (the same path the armed LaunchAgent and orphan scan use) must still
# restore the lifecycle contents. A rename fault aborts the first rollback with
# the durable bundle preserved and the newer lifecycle state still live; a
# fault-free rerun of recover.sh must converge to the prior serving state.
run_case lifecycle_interrupted_recovery "" "" fail-config-mv
root="$TMP/lifecycle_interrupted_recovery"
[ "$(cat "$root/rc")" -eq 70 ]
grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
assert_recovery_preserved "$root"
lifecycle_recovery="$(recovery_dir "$root")"
rm -f "$root/fail-config-mv"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$lifecycle_recovery/recover.sh" > "$root/lifecycle-retry.stdout.log" 2> "$root/lifecycle-retry.stderr.log"
lifecycle_retry_rc=$?
set -e
[ "$lifecycle_retry_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
if grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null; then
  echo "resumed recovery left the newer lifecycle state behind" >&2
  exit 1
fi
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null

# (d) Forward-success: on commit the lifecycle file keeps the new-install state
# and the snapshot is discarded with the retired recovery bundle. Rollback must
# not fire.
run_case lifecycle_forward_success "" "" "" commit-clean
root="$TMP/lifecycle_forward_success"
[ "$(cat "$root/rc")" -eq 0 ]
grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
if grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null; then
  echo "forward-success incorrectly reverted the lifecycle state to the prior snapshot" >&2
  exit 1
fi
[ -z "$(recovery_dir "$root")" ]
if compgen -G "$root/home/.config/macprovider/install-recovery-*.committed.*" >/dev/null; then
  echo "clean commit did not retire the recovery bundle carrying the lifecycle snapshot" >&2
  exit 1
fi

# A failed artifact prefetch exits before the durable cutover marker. Cleanup
# may restore the suspended watchdog, but it must never boot out, replace, or
# restart the healthy incumbent provider.
run_case pre_cutover_prefetch_failure "" "" "" pre-cutover
[ "$(cat "$TMP/pre_cutover_prefetch_failure/rc")" -eq 9 ]
assert_old_install "$TMP/pre_cutover_prefetch_failure"
[ -f "$TMP/pre_cutover_prefetch_failure/service-active" ]
[ -f "$TMP/pre_cutover_prefetch_failure/watchdog-service-active" ]
[ -z "$(recovery_dir "$TMP/pre_cutover_prefetch_failure")" ]
if grep -F 'bootout gui/' "$TMP/pre_cutover_prefetch_failure/launchctl.log" \
    | grep -F 'live.streamvc.macprovider.plist' >/dev/null; then
  echo "pre-cutover failure stopped the incumbent provider" >&2
  exit 1
fi
grep -F 'Cutover never started; incumbent provider files and process were left untouched.' \
  "$TMP/pre_cutover_prefetch_failure/stderr.log" >/dev/null

# A backup copy/disk failure occurs before any replacement or service stop.
run_case backup_cp_failure "" fail-backup-cp
[ "$(cat "$TMP/backup_cp_failure/rc")" -eq 70 ]
assert_old_install "$TMP/backup_cp_failure"
[ -f "$TMP/backup_cp_failure/service-active" ]
[ -f "$TMP/backup_cp_failure/watchdog-service-active" ]
if grep -F 'bootout gui/' "$TMP/backup_cp_failure/launchctl.log" >/dev/null; then
  echo "backup failure stopped the existing service" >&2
  exit 1
fi

# A restore copy failure leaves the failed new install untouched and preserves
# the complete durable backup plus an exact, rerunnable recovery command.
run_case restore_cp_failure "" "" fail-restore-cp
[ "$(cat "$TMP/restore_cp_failure/rc")" -eq 70 ]
grep -F 'new-binary' "$TMP/restore_cp_failure/home/macprovider/macprovider-cli" >/dev/null
grep -F 'model: new-model' "$TMP/restore_cp_failure/home/.config/macprovider/config.yaml" >/dev/null
[ -f "$TMP/restore_cp_failure/service-active" ]
assert_recovery_preserved "$TMP/restore_cp_failure"

# A permission-like rename failure never deletes the blocked path. Earlier
# swaps retain both the restored old path and the displaced new path durably.
run_case permission_failure "" "" fail-config-mv
[ "$(cat "$TMP/permission_failure/rc")" -eq 70 ]
grep -F 'model: new-model' "$TMP/permission_failure/home/.config/macprovider/config.yaml" >/dev/null
assert_recovery_preserved "$TMP/permission_failure"
permission_recovery="$(recovery_dir "$TMP/permission_failure")"
grep -R -F 'new-binary' "$permission_recovery/failed-current" >/dev/null
grep -F 'old-binary' "$TMP/permission_failure/home/macprovider/macprovider-cli" >/dev/null

# launchd failures are fatal after file restoration, and the verified backup is
# retained instead of being silently discarded.
for action in bootstrap kickstart; do
  run_case "${action}_failure" "$action"
  root="$TMP/${action}_failure"
  [ "$(cat "$root/rc")" -eq 70 ]
  assert_old_install "$root"
  assert_recovery_preserved "$root"
done

# Failures at every post-admission mutation boundary restore both launchd
# services and all provider/watchdog/manifest files. bootstrap and kickstart
# fail once during installation so the recovery attempts themselves can prove
# the prior services are restartable.
for phase in plist watchdog bootstrap kickstart self-test; do
  run_case "install_${phase}_failure" "" "" "" "$phase"
  root="$TMP/install_${phase}_failure"
  [ "$(cat "$root/rc")" -eq 9 ] || [ "$(cat "$root/rc")" -eq 42 ] || [ "$(cat "$root/rc")" -eq 43 ]
  assert_old_install "$root"
  [ -f "$root/service-active" ]
  [ -f "$root/watchdog-service-active" ]
  [ -z "$(recovery_dir "$root")" ]
done

# Ordinary operator-issued credentials are already present in the previous
# config snapshot. The bootstrap-preservation helper must leave them to normal
# rollback rather than treating a non-mp provider ID as a recovery error.
run_case ordinary_token_restore "" "" "" ordinary-token-self-test
root="$TMP/ordinary_token_restore"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install "$root"
grep -F 'provider_token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  "$root/home/.config/macprovider/config.yaml" >/dev/null
[ -z "$(recovery_dir "$root")" ]

# A bootstrap bearer may already be durably confirmed before a later local
# readiness failure. Rollback restores the last-known-good payload and service
# files without deleting the newly confirmed provider identity and token.
run_case confirmed_credential_restore "" "" "" credential-self-test
root="$TMP/confirmed_credential_restore"
[ "$(cat "$root/rc")" -eq 9 ]
grep -F 'old-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
grep -F 'old-resource' "$root/home/macprovider/mlx.metallib" >/dev/null
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
grep -F 'provider_id: "mp-0123456789abcdef0123456789abcdef"' \
  "$root/home/.config/macprovider/config.yaml" >/dev/null
grep -F 'provider_token: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  "$root/home/.config/macprovider/config.yaml" >/dev/null
[ "$(cat "$root/home/.config/macprovider/provider_id")" = 'mp-0123456789abcdef0123456789abcdef' ]
grep -F '<plist>old</plist>' "$root/home/Library/LaunchAgents/live.streamvc.macprovider.plist" >/dev/null
grep -F 'old-watchdog' "$root/home/.local/share/macprovider-watchdog/macprovider-health-monitor" >/dev/null
grep -F '"version":"old"' "$root/home/Library/Application Support/macprovider/install_manifest.json" >/dev/null
[ -z "$(recovery_dir "$root")" ]

# Once commit atomically retires the active bundle, a best-effort rm failure is
# only cleanup debt: EXIT must not roll the admitted new install back.
run_case commit_cleanup_failure "" "" "" commit-cleanup
root="$TMP/commit_cleanup_failure"
[ "$(cat "$root/rc")" -eq 0 ]
grep -F 'new-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
grep -F 'new-resource' "$root/home/macprovider/mlx.metallib" >/dev/null
grep -F 'model: new-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
committed_recovery="$(find "$root/home/.config/macprovider" -maxdepth 1 -type d \
  -name 'install-recovery-*.committed.*' -print -quit)"
[ -n "$committed_recovery" ]
[ -s "$committed_recovery/state.sh" ]
grep -F 'WARNING: install committed but retired recovery data could not be removed' "$root/stderr.log" >/dev/null
if grep -F 'Install did not pass admission' "$root/stderr.log" >/dev/null; then
  echo "retired recovery cleanup failure triggered rollback" >&2
  exit 1
fi

# A newly launched manual provider can ignore TERM. Admission failure must
# escalate to KILL, prove the exact owned pid is dead, and only then replace
# its files with the previous installation.
run_case new_manual_term_ignoring "" "" "" new-manual-self-test
root="$TMP/new_manual_term_ignoring"
[ "$(cat "$root/rc")" -eq 9 ]
new_manual_pid="$(cat "$root/new-manual.pid")"
if kill -0 "$new_manual_pid" >/dev/null 2>&1; then
  echo "TERM-ignoring newly installed manual provider survived rollback" >&2
  exit 1
fi
assert_old_install "$root"
[ -z "$(recovery_dir "$root")" ]

# Enabled/disabled and active/inactive launchd state is part of the transaction,
# not just plist contents.
run_case disabled_inactive_restore "" "" "" self-test disabled-inactive
root="$TMP/disabled_inactive_restore"
assert_old_install "$root"
[ ! -f "$root/service-active" ]
[ ! -f "$root/watchdog-service-active" ]
[ -f "$root/service-disabled" ]
[ -f "$root/watchdog-service-disabled" ]
[ -z "$(recovery_dir "$root")" ]

# ---------------------------------------------------------------------------
# S-M2: the lifecycle snapshot follows no symlinks, validates owner/type/nlink/
# mode/size, and aborts the transaction closed (before any live mutation) on
# violation. Each negative fixture leaves the incumbent install byte-for-byte
# untouched (begin_install_transaction dies before cutover), no recovery bundle
# is published, and the tell-tale attacker secret is never dereferenced.
# ---------------------------------------------------------------------------
assert_snapshot_aborted_pre_mutation() {
  root="$1"
  reason="$2"
  # begin_install_transaction dies 70 before marking cutover; the inner harness
  # propagates that. The incumbent binary/config/service are left intact.
  [ "$(cat "$root/rc")" -eq 70 ]
  grep -F 'old-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
  grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
  [ -f "$root/service-active" ]
  # No durable recovery bundle survives a pre-mutation snapshot failure.
  [ -z "$(recovery_dir "$root")" ]
  grep -F "$reason" "$root/stderr.log" >/dev/null
  # The incumbent provider was never stopped.
  if grep -F 'bootout gui/' "$root/launchctl.log" \
      | grep -F 'live.streamvc.macprovider.plist' >/dev/null; then
    echo "snapshot failure stopped the incumbent provider" >&2
    exit 1
  fi
}

run_case lifecycle_symlink_file "" "" "" self-test active bind symlink-file
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_symlink_file" lifecycle_state_symlink
# The out-of-tree secret behind the symlink was never copied anywhere.
if find "$TMP/lifecycle_symlink_file/home/.config/macprovider" -type f \
    -name 'lifecycle-state-v1.json' -exec grep -l 'attacker-controlled' {} + 2>/dev/null | grep -q .; then
  echo "snapshot dereferenced a symlinked state file" >&2
  exit 1
fi

run_case lifecycle_symlink_parent "" "" "" self-test active bind symlink-parent
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_symlink_parent" lifecycle_parent_symlink

run_case lifecycle_wrong_mode "" "" "" self-test active bind wrong-mode
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_wrong_mode" lifecycle_state_mode

run_case lifecycle_oversized "" "" "" self-test active bind oversized
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_oversized" lifecycle_state_oversized

# ---------------------------------------------------------------------------
# A-01(a): a stale-valid updater-written snapshot with a dead operation id is
# NOT raw-restored (that would fence a restored lifecycle-aware CLI). Rollback
# translates it under the lock into an installer-owned rollback_in_progress
# record: writer installer, fresh installer operation id, reserved reason code,
# provider_id/model_id/operator_paused/version preserved, sequence advanced past
# both the snapshot (55) and the live intermediate (183).
# ---------------------------------------------------------------------------
run_case lifecycle_updater_translated "" "" "" self-test active bind updater-snapshot
root="$TMP/lifecycle_updater_translated"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install_files "$root"
[ -z "$(recovery_dir "$root")" ]
python3 - "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
def require(condition, message):
    if not condition:
        raise SystemExit("translated record %s: %r" % (message, record))
require(record["writer"] == "installer", "must be installer-owned")
require(record["state"] == "rollback_in_progress", "must be rollback_in_progress")
require(record["reason_code"] == "install_rollback_restored_translated", "reserved reason code")
require(record["authority"] == "macprovider_cli", "authority preserved")
require(record["version"] == 1, "version preserved")
require(record["provider_id"] == "mac", "provider_id preserved")
require(record["model_id"] == "qwen3-coder-30b-a3b-instruct", "model_id preserved")
require(record["operator_paused"] is False, "operator_paused preserved false")
require(record["operation_id"].startswith("install-rollback:"), "fresh installer op id")
require(record["operation_id"] != "updater-dead-op-9999", "dead op id not reused")
require(record["sequence"] > 183, "sequence advanced past live intermediate")
require(record["sequence"] > 55, "sequence advanced past snapshot")
# transition_id is a fresh lowercase UUID distinct from the snapshot's.
tid = record["transition_id"]
require(tid == tid.lower() and len(tid) == 36, "fresh lowercase uuid transition id")
require(tid != "33333333-3333-4333-8333-333333333333", "new transition id")
require(record.get("previous_transition_id") == "33333333-3333-4333-8333-333333333333",
        "previous_transition_id chains snapshot")

# Defect 3: the journal fields Malibu displays must survive the translation. The
# snapshot (updater, sequence 55) carried four distinct journals. Rollback is an
# installer-written update-state transition, so the Swift constructor REPLACES
# last_update with this transition and PRESERVES last_restart/last_rejection/
# last_watchdog unchanged. Require every one.
snap_restart = {
    "sequence": 55,
    "transition_id": "33333333-3333-4333-8333-333333333333",
    "transition_at": "2026-07-15T17:00:00.000Z",
    "state": "update_in_progress",
    "reason_code": "update_admission_pending_restart",
    "writer": "updater",
    "operation_id": "updater-dead-op-9999-restart",
}
snap_rejection = dict(snap_restart)
snap_rejection["reason_code"] = "update_admission_pending_rejection"
snap_rejection["operation_id"] = "updater-dead-op-9999-rejection"
snap_watchdog = dict(snap_restart)
snap_watchdog["reason_code"] = "update_admission_pending_watchdog"
snap_watchdog["operation_id"] = "updater-dead-op-9999-watchdog"
require(record.get("last_restart") == snap_restart, "last_restart preserved from snapshot")
require(record.get("last_rejection") == snap_rejection, "last_rejection preserved from snapshot")
require(record.get("last_watchdog") == snap_watchdog, "last_watchdog preserved from snapshot")
# last_update is refreshed to THIS installer rollback transition, not the
# snapshot's updater journal.
lu = record.get("last_update")
require(isinstance(lu, dict), "last_update present")
require(lu.get("writer") == "installer", "last_update refreshed to installer writer")
require(lu.get("state") == "rollback_in_progress", "last_update state is rollback_in_progress")
require(lu.get("reason_code") == "install_rollback_restored_translated",
        "last_update reserved reason code")
require(lu.get("operation_id") == record["operation_id"], "last_update carries the fresh op id")
require(lu.get("sequence") == record["sequence"], "last_update sequence matches transition")
require(lu.get("transition_id") == record["transition_id"], "last_update transition id matches")
require(lu.get("transition_at") == record["transition_at"], "last_update transition_at matches")
require(lu != snap_restart, "last_update is not the stale updater journal")
PY

# A-01(b): a serve-written snapshot restores byte-exact (serve can always leave
# its own state; no fencing risk, no translation).
run_case lifecycle_serve_byte_exact "" "" "" self-test active bind serve-snapshot
root="$TMP/lifecycle_serve_byte_exact"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install_files "$root"
write_full_schema_record "$root/expected-serve.json" \
  serving_buyers serving_ready serve serve-live-op-7777 60 false \
  '44444444-4444-4444-8444-444444444444'
serve_restored_hash="$(shasum -a 256 "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" | awk '{print $1}')"
[ "$serve_restored_hash" = "$(shasum -a 256 "$root/expected-serve.json" | awk '{print $1}')" ]
[ -z "$(recovery_dir "$root")" ]

# ---------------------------------------------------------------------------
# S-M2 (Defect 2): the snapshot must prove the DESTINATION holds every captured
# byte before it publishes had=1. A short write to the destination (injected via
# LIFECYCLE_SNAPSHOT_FAULT=short-write) must abort with the snapshot failure
# code (70) and must NOT leave a had=1 meta file, so a truncated snapshot can
# never be published or later restored.
snap_root="$TMP/snapshot_short_write"
snap_lc_dir="$snap_root/lifecycle"
mkdir -p "$snap_lc_dir"
chmod 700 "$snap_root" "$snap_lc_dir"
write_full_schema_record "$snap_lc_dir/state-v1.json" \
  serving install_committed installer serve-op-0001 41 false \
  '55555555-5555-4555-8555-555555555555'
chmod 600 "$snap_lc_dir/state-v1.json"
: > "$snap_lc_dir/.state-v1.json.lock"
chmod 600 "$snap_lc_dir/.state-v1.json.lock"
snap_meta="$snap_root/snapshot-meta"
snap_dest="$snap_root/staged-state-v1.json"
set +e
(
  set -euo pipefail
  # Only the snapshot function is needed; source the extracted install functions.
  . "$TMP/functions.sh"
  LIFECYCLE_SNAPSHOT_FAULT=short-write \
    stage_lifecycle_snapshot \
      "$snap_lc_dir/state-v1.json" "$snap_lc_dir/.state-v1.json.lock" \
      "$snap_dest" "$snap_meta"
)
snap_rc=$?
set -e
[ "$snap_rc" -eq 70 ] || {
  echo "short-write snapshot did not abort with code 70 (rc=$snap_rc)" >&2
  exit 1
}
if [ -f "$snap_meta" ] && grep -qx 'had=1' "$snap_meta" 2>/dev/null; then
  echo "short-write snapshot published had=1 despite a truncated destination" >&2
  exit 1
fi

# A-01(c): a durable operator pause set DURING the transaction (live file
# operator_paused true while the snapshot was unpaused) survives rollback. The
# restored record preserves operator_paused: true even though the snapshot did
# not carry it.
MUTATION_LIFECYCLE_OPERATOR_PAUSED=true \
  run_case lifecycle_pause_survives "" "" "" self-test
root="$TMP/lifecycle_pause_survives"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install_files "$root"
python3 - "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
if record.get("operator_paused") is not True:
    raise SystemExit("durable operator pause set during the transaction was lost on rollback: %r" % record)
# The installer-written unpaused snapshot's other fields are otherwise preserved.
if record.get("writer") != "installer" or record.get("state") != "serving":
    raise SystemExit("pause reconciliation altered unrelated fields: %r" % record)
PY
[ -z "$(recovery_dir "$root")" ]

# A-01(e): lock contention. When the store lock cannot be acquired at restore
# time, recovery fails closed with the bundle preserved and the newer lifecycle
# state still live. A rerun of recover.sh after the lock is released converges.
run_case lifecycle_lock_contended "" "" fail-config-mv
root="$TMP/lifecycle_lock_contended"
[ "$(cat "$root/rc")" -eq 70 ]
lock_recovery="$(recovery_dir "$root")"
assert_recovery_preserved "$root"
rm -f "$root/fail-config-mv"
# Hold the store lock from an external process, then confirm recover.sh fails
# closed (lock_contended) with the bundle preserved.
lifecycle_lock_path="$root/home/Library/Application Support/macprovider/lifecycle/.state-v1.json.lock"
: > "$lifecycle_lock_path"
chmod 600 "$lifecycle_lock_path"
python3 - "$lifecycle_lock_path" > "$root/lock-holder.status" 2>/dev/null <<'PY' &
import fcntl
import os
import sys
import time

fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
sys.stdout.write("held\n")
sys.stdout.flush()
# Hold longer than the restore's bounded lock timeout so the contended retry
# fails closed rather than waiting the holder out. The test kills this holder
# immediately after asserting the fail-closed outcome.
time.sleep(60)
PY
lock_holder_pid=$!
for _ in $(seq 1 40); do
  grep -qx held "$root/lock-holder.status" 2>/dev/null && break
  sleep 0.1
done
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$lock_recovery/recover.sh" > "$root/lock-retry.stdout.log" 2> "$root/lock-retry.stderr.log"
lock_retry_rc=$?
set -e
kill "$lock_holder_pid" >/dev/null 2>&1 || true
wait "$lock_holder_pid" 2>/dev/null || true
[ "$lock_retry_rc" -eq 70 ]
grep -F 'lifecycle_lock_contended' "$root/lock-retry.stderr.log" >/dev/null
# The bundle is preserved and the newer live state is still present.
[ -n "$(recovery_dir "$root")" ]
grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
# With the lock released, a rerun converges to the restored serving state.
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$lock_recovery/recover.sh" > "$root/lock-retry2.stdout.log" 2> "$root/lock-retry2.stderr.log"
lock_retry2_rc=$?
set -e
[ "$lock_retry2_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null

# ---------------------------------------------------------------------------
# S-M3: durability fault injection. A fault BETWEEN the move-aside and the
# move-in preserves the bundle; a clean rerun converges. A forced post-swap
# verification failure likewise preserves the bundle.
# ---------------------------------------------------------------------------
run_case lifecycle_fault_between "" "" fail-config-mv
root="$TMP/lifecycle_fault_between"
[ "$(cat "$root/rc")" -eq 70 ]
between_recovery="$(recovery_dir "$root")"
assert_recovery_preserved "$root"
rm -f "$root/fail-config-mv"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  RECOVERY_LIFECYCLE_FAULT=between-aside-and-move-in \
  bash "$between_recovery/recover.sh" > "$root/between.stdout.log" 2> "$root/between.stderr.log"
between_rc=$?
set -e
[ "$between_rc" -eq 70 ]
grep -F 'lifecycle_restore_interrupted_between_aside_and_move_in' "$root/between.stderr.log" >/dev/null
[ -n "$(recovery_dir "$root")" ]
# Clean rerun (no fault) converges to the restored serving state.
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$between_recovery/recover.sh" > "$root/between2.stdout.log" 2> "$root/between2.stderr.log"
between2_rc=$?
set -e
[ "$between2_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null

run_case lifecycle_fault_postswap "" "" fail-config-mv
root="$TMP/lifecycle_fault_postswap"
[ "$(cat "$root/rc")" -eq 70 ]
postswap_recovery="$(recovery_dir "$root")"
rm -f "$root/fail-config-mv"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  RECOVERY_LIFECYCLE_FAULT=post-swap-verify-failure \
  bash "$postswap_recovery/recover.sh" > "$root/postswap.stdout.log" 2> "$root/postswap.stderr.log"
postswap_rc=$?
set -e
[ "$postswap_rc" -eq 70 ]
grep -F 'lifecycle_restore_post_swap_verification_forced' "$root/postswap.stderr.log" >/dev/null
[ -n "$(recovery_dir "$root")" ]
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$postswap_recovery/recover.sh" > "$root/postswap2.stdout.log" 2> "$root/postswap2.stderr.log"
postswap2_rc=$?
set -e
[ "$postswap2_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null

# ---------------------------------------------------------------------------
# A-05: lease reconciliation after rollback. The lock files are synchronization
# primitives and must remain byte-stable; only lease.json is reconciled.
# ---------------------------------------------------------------------------
# All lease fixtures below use the REAL nested Swift wire schema
# (owner.pid / owner.process_start_us / owner.boot_session) authored by
# write_lease_record, proving the reconciler decodes what the Swift store
# actually writes (Defect 1), not a flat owner_pid it never emits.
#
# Every fixture writer here (write_lease_record /
# write_prepared_handoff_lease_record) reads an EXACT-microsecond process start
# via the Darwin sysctl kinfo_proc.p_starttime ABI (ctypes libc.sysctl) and the
# boot session via `/usr/sbin/sysctl -n kern.bootsessionuuid`. Both are
# Darwin-only: on glibc Linux `libc.sysctl` is absent (AttributeError, uncaught)
# and `/usr/sbin/sysctl` cannot answer kern.bootsessionuuid, so the very first
# fixture (A-05.1) would abort the whole script within ~1s under `set -e`. The
# reconciler under test (install.sh recover.sh) only ever runs on macOS, so
# these cases are Darwin-only. They are wrapped in a function and invoked only on
# Darwin (see the uname guard at the end); portable CI still exercises every
# non-lease rollback case above.
run_darwin_lease_reconciliation_cases() {
# (A-05.1) A stale lease from the rolled-back install operation is removed.
lease_fixture="$TMP/lease_stale_operation.json"
write_lease_record "$lease_fixture" "install:test-$$" maintenance 999999
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_stale_operation "" "" "" self-test
root="$TMP/lease_stale_operation"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "stale rolled-back-operation lease survived rollback" >&2
  exit 1
fi
[ -z "$(recovery_dir "$root")" ]

# (A-05.2) A dead-owner lease (foreign operation but the PID is not alive) is
# removed.
lease_fixture="$TMP/lease_dead_owner.json"
write_lease_record "$lease_fixture" someone-else startup 999999
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_dead_owner "" "" "" self-test
root="$TMP/lease_dead_owner"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "dead-owner lease survived rollback" >&2
  exit 1
fi

# (A-05.3) A live foreign-owner lease (not part of this transaction) is
# preserved. The owner block carries the live pid's EXACT microsecond start
# (read via the same sysctl kinfo_proc path the reconciler uses) and the current
# boot session so the exact-microsecond liveness check confirms it. The lock
# files are never mutated byte-wise.
sleep 300 &
foreign_pid=$!
lease_fixture="$TMP/lease_live_foreign.json"
write_lease_record "$lease_fixture" unrelated-live startup "$foreign_pid"
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_live_foreign "" "" "" self-test
root="$TMP/lease_live_foreign"
[ "$(cat "$root/rc")" -eq 9 ]
if [ ! -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "live foreign-owner lease was incorrectly removed" >&2
  kill "$foreign_pid" >/dev/null 2>&1 || true
  exit 1
fi
grep -F 'unrelated-live' "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" >/dev/null
# The synchronization lock files exist and were never emptied/rewritten by the
# reconciler (they are 0-length primitives the CLI never treats as content).
for lock in .state-v1.json.lock .lease.json.lock; do
  lock_path="$root/home/Library/Application Support/macprovider/lifecycle/$lock"
  [ -f "$lock_path" ]
  [ ! -s "$lock_path" ] || {
    echo "lock file $lock was written with content by recovery" >&2
    kill "$foreign_pid" >/dev/null 2>&1 || true
    exit 1
  }
done
kill "$foreign_pid" >/dev/null 2>&1 || true
wait "$foreign_pid" 2>/dev/null || true
[ -z "$(recovery_dir "$root")" ]

# ---------------------------------------------------------------------------
# A-05.4 / A-05.5 / A-05.6: the prepared-handoff exemption. The Swift lease
# store intentionally exempts an unexpired `.prepared` startup handoff from the
# owner process-start liveness check so launchd can adopt it AFTER the
# maintenance process that prepared it has exited (validationFailure ->
# `handoff.state == .prepared` in ProviderLifecycleLease.swift). The reconciler
# must mirror that: a foreign lease carrying a structurally valid, unexpired
# prepared handoff on the current boot session survives rollback even though its
# owner is dead; an expired handoff does not; and a rollback-bound lease is
# removed regardless of any handoff it carries.
# ---------------------------------------------------------------------------

# (A-05.4) Valid prepared handoff + dead owner + foreign operation -> PRESERVED.
lease_fixture="$TMP/lease_prepared_handoff_valid.json"
write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-1" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_valid "" "" "" self-test
root="$TMP/lease_prepared_handoff_valid"
[ "$(cat "$root/rc")" -eq 9 ]
if [ ! -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "valid prepared-handoff lease with dead owner was incorrectly removed" >&2
  exit 1
fi
grep -F '"state":"prepared"' "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" >/dev/null
grep -F 'provider-restart-1' "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" >/dev/null

# (A-05.5) Expired prepared handoff + dead owner + foreign operation -> REMOVED.
lease_fixture="$TMP/lease_prepared_handoff_expired.json"
write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-2" 999999 expired
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_expired "" "" "" self-test
root="$TMP/lease_prepared_handoff_expired"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "expired prepared-handoff lease with dead owner survived rollback" >&2
  exit 1
fi

# (A-05.6) Valid prepared handoff BUT operation is the rolled-back transaction
# -> REMOVED. The rollback is undoing exactly this operation, so its handoff
# authorization must not survive even though the handoff window is live. The
# fixture and the harness share ONE deterministic operation id
# (MUTATION_LEASE_OPERATION_ID) so belongs_to_rollback actually matches -- a
# `$$`-derived id would differ between the parent shell and the `bash -c`
# harness and never match, silently downgrading this to a non-rollback case.
rollback_op="install:test-prepared-handoff-rollback"
lease_fixture="$TMP/lease_prepared_handoff_rollback.json"
write_prepared_handoff_lease_record "$lease_fixture" "$rollback_op" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
MUTATION_LEASE_OPERATION_ID="$rollback_op" \
  run_case lease_prepared_handoff_rollback "" "" "" self-test
root="$TMP/lease_prepared_handoff_rollback"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "rollback-bound prepared-handoff lease survived rollback" >&2
  exit 1
fi

# (A-05.7) Store-READABLE but STRUCTURALLY INVALID prepared handoff + dead owner
# + foreign operation -> REMOVED. The auditor's example: kind "startup" carrying
# a `.prepared` startup handoff. The JSON parses (it round-trips through json),
# but Swift's validateStartupHandoffStructure rejects state=="prepared" unless
# record.kind == .maintenance -> .invalidField("startup_handoff_state"). If the
# reconciler PRESERVED this record, the restored CLI's inspect() would later
# reject it as .invalidField, its fallback only re-acquires on
# handoffNotPrepared, and the provider would restart-loop. The reconciler must
# therefore DECLINE the exemption (record_matches_swift_structure returns False)
# and REMOVE the record so a fresh lease can be minted.
lease_fixture="$TMP/lease_prepared_handoff_invalid_kind.json"
write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-3" 999999 valid startup
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_invalid_kind "" "" "" self-test
root="$TMP/lease_prepared_handoff_invalid_kind"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "structurally invalid prepared-handoff lease (kind startup) survived rollback" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# A-05.8 .. A-05.11: R5 CODE-M parity-class closures. Each fixture is a
# store-READABLE-shaped record with a live prepared handoff and a dead owner --
# so the ONLY reason to preserve it would be the exemption -- but a single wire
# field carries a value that must NOT preserve. Two distinct kinds of coverage
# live here, and they rest on DIFFERENT guarantees:
#
#   * SWIFT-REJECTION evidence (A-05.8, A-05.9, A-05.10): the value is one the
#     real Swift store can never emit AND its JSONDecoder/validate would REJECT
#     (Int32/Int64 overflow decode failure; a Foundation-trimmed leading U+200B
#     failing the store's `trimmed == value` guard). Preserving these would
#     restart-loop the provider because Swift's inspect() rejects them; the
#     shell mirror MUST decline the exemption for correctness parity.
#
#   * STRICT-SUBSET POLICY coverage (A-05.11): an interior-space service_identity
#     is actually ACCEPTED by Swift's validateHandoffIdentity
#     (ProviderLifecycleLease.swift ~774: trimmingCharacters trims only the ends,
#     so `value == trimmed` holds for an interior space, and 0x20 passes the
#     `>= 0x20` scalar rule). It is rejected ONLY by our deliberately STRICTER
#     shell ASCII 0x21..0x7e rule. This is NOT a Swift-rejection case; it is a
#     strict-superset policy the reconciler applies knowing the store never
#     WRITES a spaced service identity (launchd labels contain no spaces), so the
#     at-most-theoretical false-removal is a bounded availability delay, never a
#     restart loop. It is covered here to lock the stricter policy in place, not
#     because Swift would reject the value.
#
# In every case record_matches_swift_structure MUST decline the exemption and
# the reconciler MUST REMOVE the file.
# ---------------------------------------------------------------------------

# (A-05.8) owner.pid = 2147483648 (2**31): passes an unbounded positivity check
# but overflows Swift Int32 in JSONDecoder -> REMOVED (Finding 1).
lease_fixture="$TMP/lease_prepared_handoff_pid_int32_overflow.json"
PREPARED_OVERRIDE_OWNER_PID=2147483648 \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-4" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_pid_int32_overflow "" "" "" self-test
root="$TMP/lease_prepared_handoff_pid_int32_overflow"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with Int32-overflow pid survived rollback" >&2
  exit 1
fi

# (A-05.9) owner.process_start_us = 2**63: overflows Swift Int64 in JSONDecoder
# -> REMOVED (Finding 1).
lease_fixture="$TMP/lease_prepared_handoff_process_start_int64_overflow.json"
PREPARED_OVERRIDE_PROCESS_START_US=9223372036854775808 \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-5" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_process_start_int64_overflow "" "" "" self-test
root="$TMP/lease_prepared_handoff_process_start_int64_overflow"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with Int64-overflow process_start_us survived rollback" >&2
  exit 1
fi

# (A-05.10) operation_id prefixed with U+200B (ZERO WIDTH SPACE): Foundation's
# trimmingCharacters(.whitespacesAndNewlines) strips it so Swift's
# trimmed == value guard fails, but Python str.strip does NOT strip it -- a
# str.strip mirror would false-preserve. The strictly-stricter ASCII rule
# rejects it -> REMOVED (Finding 2). The U+200B is on BOTH record and handoff
# operation_id (via $2) so the record is otherwise well-formed and the ASCII
# rule is the sole rejection cause.
lease_fixture="$TMP/lease_prepared_handoff_zwsp_operation.json"
write_prepared_handoff_lease_record "$lease_fixture" $'​provider-restart-6' 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_zwsp_operation "" "" "" self-test
root="$TMP/lease_prepared_handoff_zwsp_operation"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with U+200B-prefixed operation_id survived rollback" >&2
  exit 1
fi

# (A-05.11) service_identity with an interior space: any whitespace scalar is
# rejected by the ASCII 0x21..0x7e rule (whitespace of any kind anywhere fails)
# -> REMOVED (Finding 2). The Swift store only ever writes launchd-label service
# identities, which never contain a space.
lease_fixture="$TMP/lease_prepared_handoff_service_identity_space.json"
PREPARED_OVERRIDE_SERVICE_IDENTITY="live.streamvc macprovider" \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-7" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_service_identity_space "" "" "" self-test
root="$TMP/lease_prepared_handoff_service_identity_space"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with interior-space service_identity survived rollback" >&2
  exit 1
fi

# (A-05.12) target_executable_path containing a ".." component
# ("/Applications/MacProvider.app/Contents/MacOS/../MacOS/macprovider-cli"):
# Swift's validateTargetExecutablePath rejects any path where
# path != URL(fileURLWithPath: path).standardizedFileURL.path, and
# standardizedFileURL resolves the ".." away. The previous shell mirror used
# os.path.normpath == value, which ALSO happens to reject a ".." here -- but the
# whole point of the R6 remaining-surface closure is that the shell rule is now
# conservative component rules (no ".." component anywhere), not a normalizer
# mirror. A store never emits a ".."-containing target_executable_path (it
# persists an already-standardized executablePath(pid)), so this is corruption:
# the reconciler MUST decline the exemption and REMOVE the file (removal
# self-heals via fresh acquisition, never a restart loop). This case also
# mutation-guards the new rule: allowing ".." components would false-PRESERVE
# and fail this test.
lease_fixture="$TMP/lease_prepared_handoff_target_path_dotdot.json"
PREPARED_OVERRIDE_TARGET_PATH="/Applications/MacProvider.app/Contents/MacOS/../MacOS/macprovider-cli" \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-8" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_target_path_dotdot "" "" "" self-test
root="$TMP/lease_prepared_handoff_target_path_dotdot"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with '..'-component target_executable_path survived rollback" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# A-05.13 .. A-05.19: R6 CODE-M parity-class closures. As above, each fixture is
# a store-READABLE-shaped record whose sole defect is a value/envelope the real
# Swift store rejects (JSONDecoder bool-for-Int, lax JSON constants/duplicate
# keys/surrogates, or a storage envelope validateOpenFile refuses). Preserving
# any of these would restart-loop the provider, so the reconciler MUST REMOVE
# the file -- and must never CRASH on the malformed input (removal, not exit).
# ---------------------------------------------------------------------------

# (A-05.13, R6 CODE-M1) record.version = JSON boolean `true`. Python's
# `record.get("version") != 1` alone would pass (True == 1), but Swift's
# JSONDecoder rejects `true` for an Int field -> .unsupportedVersion. The
# non-bool integer predicate on the version field must reject it -> REMOVED.
lease_fixture="$TMP/lease_prepared_handoff_record_version_true.json"
PREPARED_OVERRIDE_RECORD_VERSION=true \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-9" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_record_version_true "" "" "" self-test
root="$TMP/lease_prepared_handoff_record_version_true"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with boolean record.version survived rollback" >&2
  exit 1
fi

# (A-05.14, R6 CODE-M1) handoff.version = JSON boolean `true`. Same defect on the
# handoff version field -> REMOVED.
lease_fixture="$TMP/lease_prepared_handoff_handoff_version_true.json"
PREPARED_OVERRIDE_HANDOFF_VERSION=true \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-10" 999999 valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_prepared_handoff_handoff_version_true "" "" "" self-test
root="$TMP/lease_prepared_handoff_handoff_version_true"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with boolean handoff.version survived rollback" >&2
  exit 1
fi

# (A-05.15, R6 CODE-M2) a NaN extra field. Python's default json.loads accepts
# NaN; Foundation's JSONDecoder rejects it. The strict loader (parse_constant)
# rejects it, and the reconciler treats the parse failure as REMOVAL without
# crashing.
lease_fixture="$TMP/lease_prepared_handoff_valid_for_nan.json"
write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-11" 999999 valid
raw_fixture="$TMP/lease_prepared_handoff_nan.raw.json"
python3 - "$lease_fixture" "$raw_fixture" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, "r", encoding="utf-8").read().rstrip("\n")
# Insert a NaN-valued extra field just inside the top-level object. The default
# Python json encoder would emit NaN, but we inject it as raw text so the bytes
# are unambiguous regardless of encoder settings.
assert text.startswith("{") and text.endswith("}")
mutated = "{" + '"extra":NaN,' + text[1:]
open(dst, "w", encoding="utf-8").write(mutated + "\n")
PY
MUTATION_LEASE_RAW_PATH="$raw_fixture" \
  run_case lease_prepared_handoff_nan "" "" "" self-test
root="$TMP/lease_prepared_handoff_nan"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with NaN field survived rollback" >&2
  exit 1
fi

# (A-05.16, R6 CODE-M2) a duplicate "version" key ("version":2,"version":1).
# Python's default json.loads keeps the LAST value (1, valid); Foundation keeps
# the FIRST (2, .unsupportedVersion). The strict loader's object_pairs_hook
# rejects duplicate keys outright -> REMOVED, never a false preserve, never a
# crash.
raw_fixture="$TMP/lease_prepared_handoff_dupkey.raw.json"
python3 - "$lease_fixture" "$raw_fixture" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, "r", encoding="utf-8").read().rstrip("\n")
assert text.startswith("{") and '"version":1' in text, text[:40]
# Prepend a second, DIFFERENT version value (order-independent: the record is
# sorted-keys, so "version" is last, but keep-first vs keep-last disagreement
# only needs two entries with the same key). The strict loader rejects the
# duplicate key regardless of which value each parser would otherwise keep.
mutated = '{"version":2,' + text[1:]
open(dst, "w", encoding="utf-8").write(mutated + "\n")
PY
MUTATION_LEASE_RAW_PATH="$raw_fixture" \
  run_case lease_prepared_handoff_dupkey "" "" "" self-test
root="$TMP/lease_prepared_handoff_dupkey"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with duplicate version key survived rollback" >&2
  exit 1
fi

# (A-05.17, R6 CODE-M2) an unpaired surrogate escape in an identity field. Python
# json accepts \ud800 and yields a lone surrogate; Foundation rejects it, and a
# lone surrogate can later raise an uncaught UnicodeEncodeError inside a
# validator (value.encode("utf-8")) -- which would CRASH the reconciler. The
# strict loader's surrogate scan rejects it -> REMOVED, never a crash.
raw_fixture="$TMP/lease_prepared_handoff_surrogate.raw.json"
python3 - "$lease_fixture" "$raw_fixture" <<'PY'
import json
import sys
src, dst = sys.argv[1:]
record = json.loads(open(src, "r", encoding="utf-8").read())
# Put a lone high surrogate escape in the handoff provider_id. Emit with
# ensure_ascii so the escape is literal \ud800 bytes (valid JSON text, invalid
# scalar) rather than raw surrogate bytes.
record["startup_handoff"]["provider_id"] = "\ud800provider"
open(dst, "w", encoding="ascii").write(
    json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"
)
PY
MUTATION_LEASE_RAW_PATH="$raw_fixture" \
  run_case lease_prepared_handoff_surrogate "" "" "" self-test
root="$TMP/lease_prepared_handoff_surrogate"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "prepared-handoff lease with unpaired surrogate survived rollback" >&2
  exit 1
fi

# (A-05.18, R6 CODE-M3) storage envelope: >16 KiB, mode 0644, and a hard link
# (nlink 2). Each is a record the Swift store's validateOpenFile rejects on read
# (.unsafeStorage: "record too large" / "mode is not 0600" / "hard link"), so the
# reconciler's pre-parse storage gate must REMOVE it. A live foreign owner is
# used for these so the ONLY reason to preserve would be a lax storage gate --
# which is exactly the defect these guard.
sleep 300 &
m3_pid=$!

# >16 KiB padded valid record.
lease_fixture="$TMP/lease_storage_oversized.json"
write_lease_record "$lease_fixture" storage-oversized-live startup "$m3_pid"
oversized_fixture="$TMP/lease_storage_oversized.raw.json"
python3 - "$lease_fixture" "$oversized_fixture" <<'PY'
import json
import sys
src, dst = sys.argv[1:]
record = json.loads(open(src, "r", encoding="utf-8").read())
# A padding field pushes the file well past the 16 KiB ceiling while keeping the
# record otherwise valid (so removal is provably the storage gate, not structure).
record["padding"] = "x" * (16 * 1024 + 64)
open(dst, "w", encoding="utf-8").write(
    json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
)
PY
MUTATION_LEASE_RAW_PATH="$oversized_fixture" \
  run_case lease_storage_oversized "" "" "" self-test
root="$TMP/lease_storage_oversized"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "oversized (>16KiB) live-owner lease survived rollback" >&2
  kill "$m3_pid" >/dev/null 2>&1 || true
  exit 1
fi

# mode 0644 (world/group readable): Swift rejects "mode is not 0600".
lease_fixture="$TMP/lease_storage_mode0644.json"
write_lease_record "$lease_fixture" storage-mode-live startup "$m3_pid"
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
MUTATION_LEASE_MODE=644 \
  run_case lease_storage_mode0644 "" "" "" self-test
root="$TMP/lease_storage_mode0644"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "mode-0644 live-owner lease survived rollback" >&2
  kill "$m3_pid" >/dev/null 2>&1 || true
  exit 1
fi

# hard link (nlink 2): Swift rejects "hard link".
lease_fixture="$TMP/lease_storage_hardlink.json"
write_lease_record "$lease_fixture" storage-hardlink-live startup "$m3_pid"
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
MUTATION_LEASE_HARDLINK=1 \
  run_case lease_storage_hardlink "" "" "" self-test
root="$TMP/lease_storage_hardlink"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "hard-linked (nlink 2) live-owner lease survived rollback" >&2
  kill "$m3_pid" >/dev/null 2>&1 || true
  exit 1
fi

kill "$m3_pid" >/dev/null 2>&1 || true
wait "$m3_pid" 2>/dev/null || true

# (A-05.19, R6 CODE-M4) A LIVE-OWNER record with ONE structurally invalid field
# (record.version = boolean `true`) -> REMOVED. This is the direct mutation guard
# for the decision-order fix: Swift validates structure FIRST for EVERY record,
# so a live owner can NEVER rescue a structurally invalid record. If the
# reconciler evaluated owner-liveness BEFORE structure (the pre-fix order), this
# live-owner lease would be PRESERVED and Swift's inspect() would then reject it
# as .unsupportedVersion -> restart loop. The owner is genuinely live (the sleep
# pid with its exact microsecond process-start), so owner_is_live() returns True;
# only the structure-first ordering makes this REMOVED.
sleep 300 &
m4_pid=$!
lease_fixture="$TMP/lease_live_owner_invalid_version.json"
PREPARED_OVERRIDE_LIVE_OWNER="$m4_pid" \
PREPARED_OVERRIDE_RECORD_VERSION=true \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-11-live" "$m4_pid" valid
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_live_owner_invalid_version "" "" "" self-test
root="$TMP/lease_live_owner_invalid_version"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "live-owner lease with structurally invalid version survived rollback (structure must gate liveness)" >&2
  kill "$m4_pid" >/dev/null 2>&1 || true
  exit 1
fi
kill "$m4_pid" >/dev/null 2>&1 || true
wait "$m4_pid" 2>/dev/null || true

# (A-05.20, MEDIUM) A LIVE-OWNER record whose record wall/monotonic window is
# EXPIRED -> REMOVED. This is the direct mutation guard for the shared-validity
# gate: Swift's validationFailure runs the record boot/wall/monotonic window
# checks (~888..894) AFTER structure and BEFORE either preservation branch, so a
# live owner can NEVER rescue an out-of-window record. owner_is_live() checks
# only pid/boot/process-start, NOT the record's clock windows, so WITHOUT the new
# record_shared_validity_ok gate this live-owner lease would be PRESERVED yet
# Swift's inspect() would reject it as .wallExpired -> restart loop for a
# handoff-bearing lease. The record stays STRUCTURALLY VALID (correct duration
# algebra), so the ONLY thing that makes it REMOVED is the shared-window gate.
# The owner is genuinely live (the sleep pid with its real process-start
# second), so owner_is_live() returns True; only the window gate makes this
# REMOVED. Disabling record_shared_validity_ok (or dropping its wall/monotonic
# checks) would false-PRESERVE and fail this test.
sleep 300 &
m5_pid=$!
lease_fixture="$TMP/lease_live_owner_expired_window.json"
LEASE_RECORD_WINDOW=expired \
  write_lease_record "$lease_fixture" unrelated-live-expired startup "$m5_pid"
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_live_owner_expired_window "" "" "" self-test
root="$TMP/lease_live_owner_expired_window"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "live-owner lease with expired record window survived rollback (shared-validity gate must remove it)" >&2
  kill "$m5_pid" >/dev/null 2>&1 || true
  exit 1
fi
kill "$m5_pid" >/dev/null 2>&1 || true
wait "$m5_pid" 2>/dev/null || true

# (A-05.21, MEDIUM remaining-surface) A LIVE-OWNER record carrying a `.prepared`
# handoff whose HANDOFF window is EXPIRED (but structurally valid + record window
# valid) -> REMOVED. In Swift's validationFailure the owner process-start
# liveness check (~904) is reached ONLY in the ELSE / no-prepared-handoff case: a
# record WITH a prepared handoff is governed SOLELY by the handoff-window check
# (~896..901), which returns .wallExpired for an expired handoff regardless of
# owner liveness. So a prepared-handoff record must route EXCLUSIVELY through the
# exemption; a live owner must NOT rescue an expired-handoff lease. WITHOUT the
# prepared/owner branch split (record_has_prepared_handoff) owner_is_live() would
# fire first and PRESERVE this lease, yet Swift's inspect() rejects it ->
# restart loop. The owner is genuinely live (the sleep pid with its exact
# microsecond process-start), so owner_is_live() would return True; only routing
# prepared-handoff records through the handoff-window gate makes this REMOVED.
sleep 300 &
m6_pid=$!
lease_fixture="$TMP/lease_live_owner_expired_handoff.json"
PREPARED_OVERRIDE_LIVE_OWNER="$m6_pid" \
  write_prepared_handoff_lease_record "$lease_fixture" "provider-restart-live-expired" "$m6_pid" expired_short
MUTATION_LEASE_JSON="$(cat "$lease_fixture")" \
  run_case lease_live_owner_expired_handoff "" "" "" self-test
root="$TMP/lease_live_owner_expired_handoff"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "live-owner lease with expired prepared handoff survived rollback (handoff window must govern, not owner liveness)" >&2
  kill "$m6_pid" >/dev/null 2>&1 || true
  exit 1
fi
kill "$m6_pid" >/dev/null 2>&1 || true
wait "$m6_pid" 2>/dev/null || true
}

run_darwin_manual_recovery_cases() {
# A non-launchd provider holding the configured port is a real protected
# process state: capture it before stop, restore the exact prior binary and
# argv on self-test failure, and never evaluate shell metacharacters stored in
# an argument.
run_case manual_provider_restore "" "" "" manual-self-test manual
wait "$manual_pid" 2>/dev/null || true
root="$TMP/manual_provider_restore"
[ "$(cat "$root/rc")" -eq 9 ]
for _ in $(seq 1 20); do
  [ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -ge 2 ] && break
  sleep 0.1
done
initial_pid="$(head -n 1 "$root/manual-fixture.log" | cut -d'|' -f1)"
restored_pid="$(tail -n 1 "$root/manual-fixture.log" | cut -d'|' -f1)"
[ "$initial_pid" != "$restored_pid" ]
if kill -0 "$initial_pid" >/dev/null 2>&1; then
  echo "original manual provider survived protected stop" >&2
  exit 1
fi
kill -0 "$restored_pid"
[ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -eq 2 ]
python3 - "$root/manual-fixture.log" "$root" "$(cat "$root/manual-port")" <<'PY'
import os
import sys

log_path, root, port = sys.argv[1:]
with open(log_path, "r", encoding="ascii") as handle:
    lines = [line.rstrip("\n").split("|") for line in handle]
if len(lines) != 2:
    raise SystemExit(f"expected original and restored argv records, got {len(lines)}")
decoded = [[bytes.fromhex(argument) for argument in line[1:]] for line in lines]
expected = [
    b"--port", port.encode("ascii"),
    b"--model", b"old-model",
    b"--fixture-log", os.fsencode(root + "/manual-fixture.log"),
    b"--bind-gate", os.fsencode(root + "/manual-never-bind"),
    b"--whitespace", b"two words\twith tab",
    b"--quotes", b"say \"hello\" and 'goodbye'",
    b"--backslashes", b"C:\\Models\\Qwen\\file",
    b"--metacharacters", os.fsencode(";touch ${IFS}" + root + "/pwned & | $(printf nope) * ? [x]"),
]
if decoded[0] != expected:
    raise SystemExit(f"fixture did not start with expected exact argv: {decoded[0]!r}")
if decoded[1] != decoded[0]:
    raise SystemExit(f"restored argv differs from exact original: {decoded!r}")
PY
python3 - "$root/manual-fixture.log.context" "$root" <<'PY'
import os
import sys

log_path, root = sys.argv[1:]
with open(log_path, "r", encoding="ascii") as handle:
    lines = [line.rstrip("\n").split("|") for line in handle]
if len(lines) != 2 or any(len(line) != 4 for line in lines):
    raise SystemExit(f"expected original and restored process context records, got {lines!r}")
decoded = [[bytes.fromhex(field) for field in line[1:]] for line in lines]
expected = [
    os.fsencode(os.path.realpath(root + "/manual-cwd")),
    b"exact context with spaces\tand tab; $(not evaluated)",
    os.fsencode(root + "/bin:/usr/bin:/bin"),
]
if decoded[0] != expected:
    raise SystemExit(f"fixture did not start with expected cwd/environment: {decoded[0]!r}")
if decoded[1] != decoded[0]:
    raise SystemExit(f"restored cwd/environment differs from exact original: {decoded!r}")
PY
[ ! -e "$root/pwned" ]
[ "$(shasum -a 256 "$root/home/macprovider/macprovider-cli" | awk '{print $1}')" = "$(cat "$root/manual-old.sha256")" ]
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
[ -z "$(recovery_dir "$root")" ]
kill "$restored_pid"

# A restored process that remains alive but never binds is not a successful
# rollback. It ignores TERM to exercise the KILL fallback; recovery must prove
# it is dead, preserve the bundle, and permit a clean retry with no orphan.
run_case manual_provider_never_binds "" "" "" manual-self-test manual never-bind
wait "$manual_pid" 2>/dev/null || true
root="$TMP/manual_provider_never_binds"
[ "$(cat "$root/rc")" -eq 70 ]
assert_recovery_preserved "$root"
[ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -eq 2 ]
failed_restored_pid="$(sed -n '2s/|.*//p' "$root/manual-fixture.log")"
for _ in $(seq 1 20); do
  ! kill -0 "$failed_restored_pid" >/dev/null 2>&1 && break
  sleep 0.1
done
if kill -0 "$failed_restored_pid" >/dev/null 2>&1; then
  echo "never-binding restored provider survived recovery cleanup" >&2
  exit 1
fi
recovery="$(recovery_dir "$root")"
[ ! -e "$recovery/manual-restored.pid" ]
rm -f "$root/manual-never-bind"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$recovery/recover.sh" > "$root/retry.stdout.log" 2> "$root/retry.stderr.log"
retry_rc=$?
set -e
[ "$retry_rc" -eq 0 ]
for _ in $(seq 1 20); do
  [ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -ge 3 ] && break
  sleep 0.1
done
[ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -eq 3 ]
retry_pid="$(sed -n '3s/|.*//p' "$root/manual-fixture.log")"
[ "$retry_pid" != "$failed_restored_pid" ]
kill -0 "$retry_pid"
[ "$(cat "$recovery/manual-restored.pid")" = "$retry_pid" ]
first_argv="$(sed -n '1s/^[^|]*|//p' "$root/manual-fixture.log")"
failed_argv="$(sed -n '2s/^[^|]*|//p' "$root/manual-fixture.log")"
retry_argv="$(sed -n '3s/^[^|]*|//p' "$root/manual-fixture.log")"
[ "$failed_argv" = "$first_argv" ]
[ "$retry_argv" = "$first_argv" ]
if kill -0 "$failed_restored_pid" >/dev/null 2>&1; then
  echo "failed restored provider was orphaned after successful retry" >&2
  exit 1
fi
kill "$retry_pid"
}

# The A-05 lease-reconciliation cases and the manual-provider argv-replay cases
# both depend on Darwin-only primitives: the sysctl kinfo_proc.p_starttime ABI
# (exact process-start microseconds) and kern.bootsessionuuid for the lease
# fixtures, and Darwin's KERN_PROCARGS2 argv contract for the manual-provider
# cases. The reconciler under test only runs on macOS. Portable CI still
# exercises every other rollback case above; the macOS lane runs these.
if [ "$(uname -s)" = "Darwin" ]; then
  run_darwin_lease_reconciliation_cases
  run_darwin_manual_recovery_cases
else
  echo "SKIP: Darwin-only lease reconciliation cases (A-05.1..A-05.21) -- reconciler is macOS-only (sysctl kinfo_proc process-start + kern.bootsessionuuid)"
  echo "SKIP: Darwin-only manual provider argv recovery cases -- KERN_PROCARGS2 exact argv capture/replay is macOS-only"
fi

echo "upgrade evidence rollback fault matrix ok"
