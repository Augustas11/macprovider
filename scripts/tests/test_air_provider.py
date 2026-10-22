"""Small offline checks of Air controller decisions; no SSH or provider runs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = (ROOT / "scripts/ops/air-provider.sh").read_text()


def function(name):
    start = CONTROLLER.index(name + "() {")
    return CONTROLLER[start:CONTROLLER.index("\n}\n", start) + 3]


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
                  "continuous_batching.self_check.served_slots": 4,
                  "continuous_batching.scheduler.slots_total": 4, "capacity.max_concurrency": 4}
        with tempfile.TemporaryDirectory() as directory:
            for slots, expected in ((4, 0), (3, 1)):
                status["capacity.max_concurrency"] = slots
                Path(directory, "air-probe.json").write_text(json.dumps({"status": status}))
                result = self.shell(function("target_ready") +
                                    f'\nOPS_TMP_DIR="{directory}" REPO_ROOT="{ROOT}"\ntarget_ready')
                self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
