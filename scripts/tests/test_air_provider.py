"""Small offline checks of Air controller decisions; no SSH or provider runs."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = (ROOT / "scripts/ops/air-provider.sh").read_text()


def function(name, source=CONTROLLER):
    start = source.index(name + "() {")
    return source[start:source.index("\n}\n", start) + 3]


class AirProviderTests(unittest.TestCase):
    def shell(self, code):
        return subprocess.run(["bash", "-c", code], text=True, capture_output=True,
                              env={**os.environ, "MACPROVIDER_OPS_ENV": "/dev/null"})

    def test_interrupted_payload_selects_executable_restore_without_probe(self):
        result = self.shell(function("gather") + '''
settings() { :; }
marker_done() { return 0; }
marker_field() { case "$2" in air_recovery_dispatch) echo /safe/stage;; esac; }
q() { printf "'%s'" "$1"; }
studio_ssh() { return 1; }
set_next() { printf '%s %s %s' "$1" "$2" "$4"; }
helper() { echo 'unexpected helper call' >&2; return 99; }
VERSION=1.8.260
gather
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         "payload_recovery mutate scripts/ops/air-provider.sh _restore-payload")
        self.assertEqual(result.stderr, "")

    def test_stale_completion_and_restore_lock_refusal_leave_current_attempt_pending(self):
        for action, result_stage, rc, busy in (("recover-air", "/old/stage", 5, 0),
                                               ("recover-air", "/old/stage", 0, 0),
                                               ("restore-air", "/new/stage", 4, 0),
                                               ("recover-air", "/new/stage", 0, 1)):
            code = function("gather") + '''
settings() { :; }
marker_done() { return 0; }
q() { printf "'%s'" "$1"; }
marker_field() {
  if [ "$2" = air_recovery_dispatch ]; then echo /new/stage; return; fi
  case "$3" in
    *provider_id_sha256*) echo provider;;
    *stage*) echo "$RESULT_STAGE";;
    *action*) echo "$ACTION";;
    *exit_code*) echo "$RC";;
  esac
}
studio_ssh() { [ "$BUSY" = 1 ]; }
set_next() { printf '%s %s' "$1" "$2"; }
helper() { echo unexpected >&2; return 99; }
AIR_PROVIDER_SHA256=provider VERSION=1.8.260
gather
'''
            result = self.shell(f'ACTION={action} RESULT_STAGE={result_stage} RC={rc} BUSY={busy}\n' + code)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "payload_recovery mutate")
            self.assertEqual(result.stderr, "")

    def test_settings_keep_nested_proofs_on_air(self):
        result = self.shell(function("q") + function("settings") + '''
refuse() { exit 3; }
AIR_SSH=operator@air.invalid AIR_INSTALL_DIR=/safe/install AIR_CONFIG=/safe/config
AIR_JOURNAL=/safe/journal AIR_STATUS_PORT=50160
AIR_PROVIDER_SHA256=$(printf '%064d' 0) AIR_HANDOFF_SHA256=$(printf '%064d' 1)
STUDIO_SSH=wrong@studio.invalid MACPROVIDER_OPS_ENV=/private/profile
settings
printf '%s %s %s' "$STUDIO_SSH" "$STUDIO_STATUS_PORT" "$MACPROVIDER_OPS_ENV"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "operator@air.invalid 50160 /dev/null")

    def test_result_publication_distinguishes_original_refusal_from_restore_lock_busy(self):
        source = (ROOT / "scripts/ops/canary-swap.sh").read_text()
        setup = function("record_air_result", source) + '''
mark_done() { printf '%s' "$4"; }
stage=/current/stage AIR_RECOVERY_PROVIDER_SHA256=provider OPS_SCOPE=scope
'''
        for action, rc, published in (("recover-air", 4, True), ("recover-air", 5, True),
                                      ("restore-air", 4, False), ("restore-air", 6, False),
                                      ("restore-air", 5, True)):
            result = self.shell(setup + f"\nrecord_air_result {action} {rc}")
            self.assertEqual(result.returncode, 0, result.stderr)
            if published:
                self.assertEqual(json.loads(result.stdout), {"stage": "/current/stage",
                    "provider_id_sha256": "provider", "action": action, "exit_code": rc})
            else:
                self.assertEqual(result.stdout, "")

    def test_live_slots_must_match_signed_four_slot_tuple(self):
        path = ROOT / "phase3-binary/catalog/autotune/continuous-batching-policy.json"
        raw = path.read_bytes()
        policy = json.loads(raw)
        entry = next(x for x in policy["entries"] if x["model_key"] == "qwen3-8b")
        status = {"binary_version": "1.8.260", "model": "qwen3-8b", "model_loaded": True,
                  "network_state": "buyer_serving", "coordinator.connected": True,
                  "continuous_batching.active": True, "continuous_batching.policy.authorized": True,
                  "continuous_batching.policy.load_status": "live_verified",
                  "continuous_batching.policy.policy_sha256": hashlib.sha256(raw).hexdigest(),
                  "continuous_batching.policy.release_id": policy["release_id"],
                  "continuous_batching.policy.tuple_sha256": entry["tuple_sha256"],
                  "continuous_batching.self_check.model_sha256": entry["model_sha256"],
                  "continuous_batching.self_check.verified_k": 4,
                  "continuous_batching.self_check.served_slots": 4,
                  "continuous_batching.scheduler.slots_total": 4, "capacity.max_concurrency": 4}
        with tempfile.TemporaryDirectory() as directory:
            for slots, verified, expected in ((4, 4, 0), (3, 4, 1), (4, 1, 1), (4, 2, 1)):
                status["capacity.max_concurrency"] = slots
                status["continuous_batching.self_check.verified_k"] = verified
                Path(directory, "air-probe.json").write_text(json.dumps({"status": status}))
                result = self.shell(function("target_ready") +
                                    f'\nOPS_TMP_DIR="{directory}" REPO_ROOT="{ROOT}"\ntarget_ready')
                self.assertEqual(result.returncode, expected, result.stderr)


class AirDetachedRecoveryTests(unittest.TestCase):
    """Execute the actual detached helper with only macOS surfaces simulated."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.install = self.home / "macprovider"
        self.install.mkdir()
        self.config = self.home / "config.yaml"
        self.config.write_text("model: baseline\n")
        self.binary = self.install / "macprovider-cli"
        self.binary.write_text("#!/bin/sh\necho 1.8.258\n")
        self.binary.chmod(0o700)
        self.old_sha = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.config_sha = hashlib.sha256(self.config.read_bytes()).hexdigest()
        self.provider = "mp-fixture"
        self.provider_sha = hashlib.sha256(self.provider.encode()).hexdigest()
        self.stage = self.home / "stage"
        self.stage.mkdir()
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.loaded = self.home / "loaded"
        self.loaded.touch()
        agents = self.home / "Library/LaunchAgents"
        agents.mkdir(parents=True)
        (agents / "live.malibu.provider.plist").write_bytes(plistlib.dumps({
            "Label": "live.malibu.provider", "ProgramArguments":
            [str(self.binary), "serve", "--config", str(self.config)]}))
        scripts = {
            "date": '''#!/bin/sh
if [ -n "${FAKE_FIXED_TIMESTAMP:-}" ] && [ "$*" = '-u +%Y%m%dT%H%M%SZ' ]; then echo "$FAKE_FIXED_TIMESTAMP"; else exec /bin/date "$@"; fi
''',
            "sysctl": '#!/bin/sh\ncase "$*" in *hw.model*) echo Mac15,12;; *) echo 17179869184;; esac\n',
            "codesign": "#!/bin/sh\nexit 0\n",
            "launchctl": '''#!/bin/sh
case "$1" in
 print) [ -f "$HOME/loaded" ] || exit 113; printf '\\tpid = 111\\n';;
 bootout) /bin/rm -f "$HOME/loaded";;
 bootstrap) /usr/bin/touch "$HOME/loaded";;
esac
''',
            "curl": '''#!/bin/sh
[ -f "$HOME/loaded" ] && [ -f "$HOME/macprovider/macprovider-cli" ] || exit 7
v=$("$HOME/macprovider/macprovider-cli" --version)
printf '{"binary_version":"%s","provider_id":"mp-fixture","requests_in_flight":0,"coordinator":{"connected":false},"lifecycle":{"operator_paused":false}}' "$v"
''',
            "mv": '''#!/bin/sh
/bin/mv "$@" || exit $?
if [ "${FAIL_AFTER_MOVE:-}" = 1 ] && [ "$1" = "$HOME/macprovider" ]; then kill -KILL "$PPID"; fi
''',
            "cp": '''#!/bin/sh
if [ "${FAIL_DURING_COPY:-}" = 1 ]; then
 /bin/mkdir -p "$3"; /bin/cp "$2/macprovider-cli" "$3/"; kill -KILL "$PPID"; exit 1
fi
exec /bin/cp "$@"
''',
        }
        for name, content in scripts.items():
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o700)
        source = (ROOT / "scripts/ops/lib/canary-swap-remote.sh").read_text()
        start = source.index("verify_job_process() {")
        end = source.index("\n}\n", start) + 3
        # libproc is unavailable off the designated hardware. Keep real plist,
        # byte/config digest, ownership, journal and host-lock checks executable.
        source = source[:start] + '''verify_job_process() {
  verify_launch_plist && [ "$(job_pid)" = "$1" ] && printf 100
}
''' + source[end:]
        self.remote = self.home / "remote.sh"
        self.remote.write_text(source)

    def run_remote(self, action="restore-air", **extra):
        return subprocess.run(["bash", str(self.remote), str(self.stage / "candidate.tar.gz"),
                               "a" * 64, "1.8.260", str(self.install), "live.malibu.provider",
                               "/unused/socket", "50160", "2", "3", "2", "0", "0.1",
                               str(self.stage / ("result" if action == "recover-air" else "restore-result")),
                               self.provider_sha, str(self.config), self.old_sha, action, self.config_sha],
                              capture_output=True, text=True, timeout=12,
                              env={**os.environ, "HOME": str(self.home),
                                   "CANARY_REMOTE_PATH_PREFIX": str(self.bin), **extra})

    def arm(self):
        self.backup = self.home / "macprovider.pre-1.8.260-fixture"
        self.backup.mkdir()
        (self.backup / "macprovider-cli").write_bytes(self.binary.read_bytes())
        (self.backup / "macprovider-cli").chmod(0o700)
        (self.backup / "restored-resource").write_text("preserved")
        record = self.stage / "result.recovery.json"
        record.write_text(json.dumps({"schema_version": "macprovider.air_payload_recovery.v1",
            "phase": "armed", "backup_path": str(self.backup), "install_dir": str(self.install),
            "provider_id_sha256": self.provider_sha, "incumbent_binary_sha256": self.old_sha,
            "target_tarball_sha256": "a" * 64, "config_sha256": self.config_sha}))
        record.chmod(0o600)

    def test_never_launched_and_prearmed_worker_loss_cancel_delayed_original(self):
        for stale_lock in (False, True):
            with self.subTest(stale_lock=stale_lock):
                if stale_lock:
                    lock = self.home / ".macprovider-canary-swap.lock"
                    lock.mkdir()
                    (lock / "pid").write_text("99999999\n")
                result = self.run_remote()
                self.assertEqual(result.returncode, 5, result.stderr)
                self.assertEqual(self.binary.read_text(), "#!/bin/sh\necho 1.8.258\n")
                self.assertEqual((self.stage / "result.restored").read_text(), "5\n")
                delayed = self.run_remote("recover-air")
                self.assertEqual(delayed.returncode, 4, delayed.stderr)
                self.assertIn("cancelled/restored", delayed.stderr)

    def test_live_original_lock_refuses_restore_without_terminal_completion(self):
        lock = self.home / ".macprovider-canary-swap.lock"
        lock.mkdir()
        (lock / "pid").write_text(str(os.getpid()))
        result = self.run_remote()
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertFalse((self.stage / "result.restored").exists())
        self.assertFalse((self.stage / "result").exists())
        self.assertTrue(lock.exists())

    def test_loss_after_backup_before_arm_can_cancel_without_backup_collision(self):
        (self.home / "macprovider.pre-1.8.260-20000101T000000Z").mkdir()
        result = self.run_remote(FAKE_FIXED_TIMESTAMP="20000101T000000Z")
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertEqual(self.binary.read_text(), "#!/bin/sh\necho 1.8.258\n")

    def test_never_started_recovery_refuses_changed_baseline_config(self):
        self.config.write_text("model: externally-changed\n")
        result = self.run_remote()
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertFalse((self.stage / "result.restored").exists())

    def test_interruption_after_move_recovers_absent_install(self):
        self.arm()
        result = self.run_remote(FAIL_AFTER_MOVE="1")
        self.assertEqual(result.returncode, -9, result.stderr)
        self.assertFalse(self.install.exists())
        recovered = self.run_remote()
        self.assertEqual(recovered.returncode, 5, recovered.stderr)
        self.assertEqual((self.install / "restored-resource").read_text(), "preserved")
        self.assertEqual(self.config.read_text(), "model: baseline\n")

    def test_interruption_during_copy_recovers_partial_install(self):
        self.arm()
        result = self.run_remote(FAIL_DURING_COPY="1")
        self.assertEqual(result.returncode, -9, result.stderr)
        self.assertTrue(self.binary.exists())
        self.assertFalse((self.install / "restored-resource").exists())
        recovered = self.run_remote()
        self.assertEqual(recovered.returncode, 5, recovered.stderr)
        self.assertEqual((self.install / "restored-resource").read_text(), "preserved")


if __name__ == "__main__":
    unittest.main()
