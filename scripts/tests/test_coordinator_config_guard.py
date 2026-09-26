#!/usr/bin/env python3
"""#1693 L0 one-writer guard: libraries, writer inventory, installed-writer manifest.

No Pearl, no root. The shell guard runs under a Python flock(1) shim (macOS has
no flock) with the Pearl lock paths redirected through the same environment
overrides coordinator-deploy-recover.sh honours; the Tier-2 activation writers
run end to end against a fake ssh that executes the remote command locally.
"""

from __future__ import annotations

import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

REPO = Path(__file__).resolve().parents[2]
SHELL_GUARD = REPO / "scripts/lib/coordinator-config-guard.sh"
PY_GUARD = REPO / "scripts/lib/coordinator_config_guard.py"
MANIFEST = REPO / "scripts/pricing-lane-installed-writers.txt"
INSTALLER = REPO / "ops/pearl-updater/install-pearl-updater.sh"

SPEC = importlib.util.spec_from_file_location("coordinator_config_guard", PY_GUARD)
assert SPEC is not None and SPEC.loader is not None
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)

REFUSAL_RE = (
    r"refusing: pricing transaction journal present at (\S+)/\.pricing-txn; "
    r"run scripts/catalog-content-release\.sh --recover-pricing-txn"
)

FLOCK_SHIM = """#!/usr/bin/env python3
import fcntl, os, sys, time
args = sys.argv[1:]
nonblock, wait = False, None
while args and args[0].startswith("-"):
    flag = args.pop(0)
    if flag in ("-n", "--nonblock"):
        nonblock = True
    elif flag in ("-w", "--wait", "--timeout"):
        wait = float(args.pop(0))
fd = int(args[0])
deadline = None if wait is None else time.time() + wait
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if (nonblock or deadline) else 0))
        sys.exit(0)
    except BlockingIOError:
        if nonblock or deadline is None or time.time() >= deadline:
            sys.exit(1)
        time.sleep(0.05)
"""


# ---------------------------------------------------------------------------
# Writer inventory. Every executable file that names the live coordinator
# config, the Pearl overlay, a <ROOT>/coordinator.yaml join or a HUP must be
# classified here; an unclassified one fails the test. GUARDED entries must
# carry the guard markers listed for them.
# ---------------------------------------------------------------------------
LIVE_WRITER_RE = re.compile(
    r'/opt/macprovider/coordinator\.yaml'
    r'|coordinator\.pearl-overlays\.yaml'
    r'|/ "coordinator\.yaml"'
    r'|\$\{?[A-Z_]*ROOT\}?/coordinator\.yaml'
    r'|kill -s HUP|kill -HUP|"HUP"'
)
TEST_PATH_RE = re.compile(r"(^|/)(tests?|test-support|fixtures)/|(^|/)test[-_]|_test\.|\.test\.sh$")
SKIP_PREFIXES = (".omc/", "audits/", "journeys/", "docs/", ".git/")
SKIP_SUFFIXES = (".md", ".html", ".json", ".go", ".example", ".service", ".conf",
                 ".yaml", ".txt", ".png", ".patch")

ACTIVATE_MARKERS = ('. "$CCG_LIB"', 'ccg_remote_guard_script "$CCG_LIB" "${REMOTE_CONFIG%/*}")',
                    'ccg_remote_guard_script "$CCG_LIB" "${REMOTE_CONFIG%/*}" 120)')
GUARDED = {
    # Tier-2 activation writers: patch + SIGHUP in one guarded remote shell,
    # rollback guarded + compare-and-swap.
    "scripts/activate-tier2-attestation.sh": ACTIVATE_MARKERS,
    "scripts/activate-tier2-behavioral-safety.sh": ACTIVATE_MARKERS,
    "scripts/activate-tier2-encrypted-leg.sh": ACTIVATE_MARKERS,
    # Pearl-installed Python writers: deploy lock under the updater lock, then
    # the journal refusal, for every mode.
    "ops/pearl-updater/macprovider-pearl-update": (
        "def coordinator_config_guard(",
        'CONFIG_GUARD_MODULE = Path("/usr/local/share/macprovider/scripts/coordinator_config_guard.py")',
        "with FileLock(updater.lock_path, required_uid=lock_uid), coordinator_config_guard(",
    ),
    "ops/pearl-updater/macprovider-tier2-enforcement-watchdog": (
        "class ConfigGuard:",
        'CONFIG_GUARD_MODULE = Path("/usr/local/share/macprovider/scripts/coordinator_config_guard.py")',
        "with FileLock(), ConfigGuard():",
    ),
    # Delegates every config write to the guarded watchdog; pins the installed
    # guard module and refuses up front while a journal exists.
    "scripts/enforce-tier2-hash.sh": (
        'PINNED_REMOTE_CONFIG_GUARD="/usr/local/share/macprovider/scripts/coordinator_config_guard.py"',
        "test ! -e /opt/macprovider/.pricing-txn",
        "macprovider-tier2-enforcement-watchdog",
    ),
    # Autotune `current` + SIGHUP writer: refuses an abandoned journal; its
    # publish runs under aa_publish's flock -n on the same lock set.
    "scripts/renew-autotune-static-feed.sh": (
        'PRICING_TXN="${REMOTE_AUTOTUNE_DIR%/*}/.pricing-txn"',
        "--recover-pricing-txn",
    ),
}
# S3 (the pricing lane slice) guards these itself.
S3_OWNED = {
    "phase4-coordinator/dist/deploy-pearl-vps.sh",
    "phase4-coordinator/dist/coordinator-deploy-recover.sh",
    "phase4-coordinator/dist/coordinator-pricing-recover",
    "scripts/catalog-content-release.sh",
    "scripts/lib/autotune-activate.sh",
}
RETIRED = {
    "phase4-coordinator/dist/deploy-malibu-emission-pearl.sh",
    "phase4-coordinator/dist/deploy-opoi-v0-pearl.sh",
}
NOT_WRITERS = {
    "scripts/lib/coordinator-config-guard.sh": "the guard itself",
    "scripts/lib/coordinator_config_guard.py": "the guard itself",
    "phase5-gateway/dist/deploy-pearl-vps.sh": "reads the installed coordinator config for the C2 pairing check",
    "phase4-coordinator/dist/install-micromdm-pearl.sh": "prints an operator hint only",
    "phase4-coordinator/dist/monitor/macprovider-monitor.py": "comment only; reads coordinator endpoints",
    "scripts/catalog-release.py": "repo coordinator.yaml; the splice writes --output, never the live path",
    "scripts/lab/1690-m6/write_configs.py": "#1690 M6 lab rig; writes $LAB/run/coordinator.yaml on the lab Mac",
    "scripts/lab/1690-m6/cases.py": "#1690 M6 lab rig; reads $LAB/run/coordinator.yaml for pool-rollback-preflight",
}


def repo_files() -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(REPO), "ls-files", "-co", "--exclude-standard"],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.split()


def live_writer_candidates() -> list[str]:
    found = []
    for relative in repo_files():
        if relative.startswith(SKIP_PREFIXES) or relative.endswith(SKIP_SUFFIXES):
            continue
        if TEST_PATH_RE.search(relative):
            continue
        path = REPO / relative
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if not (relative.endswith((".sh", ".py", ".yml", ".bash")) or text.startswith("#!")):
            continue
        if LIVE_WRITER_RE.search(text):
            found.append(relative)
    return sorted(found)


def read_manifest() -> list[tuple[str, str]]:
    entries = []
    for number, raw in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split(" ")
        if len(fields) != 2 or not all(fields):
            raise AssertionError(f"{MANIFEST.name}:{number}: want '<installed path> <repo path>'")
        entries.append((fields[0], fields[1]))
    return entries


class WriterInventoryTests(unittest.TestCase):
    def test_every_live_config_writer_is_classified(self):
        classified = set(GUARDED) | S3_OWNED | RETIRED | set(NOT_WRITERS)
        unclassified = [path for path in live_writer_candidates() if path not in classified]
        self.assertEqual(
            unclassified,
            [],
            "new live coordinator.yaml/overlay writer(s) without the #1693 L0 guard; "
            "wire scripts/lib/coordinator-config-guard.sh (or coordinator_config_guard.py) "
            "and classify them in this test",
        )

    def test_guarded_writers_carry_the_guard(self):
        for relative, markers in GUARDED.items():
            text = (REPO / relative).read_text(encoding="utf-8")
            for marker in markers:
                with self.subTest(path=relative, marker=marker):
                    self.assertIn(marker, text)

    def test_activation_writers_have_no_unguarded_remote_mutation(self):
        for relative in (
            "scripts/activate-tier2-attestation.sh",
            "scripts/activate-tier2-behavioral-safety.sh",
            "scripts/activate-tier2-encrypted-leg.sh",
        ):
            text = (REPO / relative).read_text(encoding="utf-8")
            with self.subTest(path=relative):
                self.assertNotIn("reload_remote_config", text)
                # Exactly two remote shells mutate: the patch (+HUP) and the
                # rollback (+HUP); both start with the guard prologue.
                self.assertEqual(text.count("ccg_remote_guard_script"), 2)
                self.assertEqual(text.count("systemctl kill -s HUP"), 2)
                for match in re.finditer(r"systemctl kill -s HUP", text):
                    preceding = text[: match.start()]
                    last_ssh = preceding.rfind('"${SSH[@]}" "')
                    self.assertTrue(
                        preceding[last_ssh:].startswith('"${SSH[@]}" "$(ccg_remote_guard_script'),
                        "SIGHUP outside the guarded remote shell",
                    )

    def test_enforce_script_never_writes_the_config_itself(self):
        text = (REPO / "scripts/enforce-tier2-hash.sh").read_text(encoding="utf-8")
        self.assertNotIn("systemctl kill", text)
        self.assertNotIn("os.replace", text)
        self.assertNotRegex(text, r"(cp|mv|install)\s[^\n]*\$q_remote_config")

    def test_retired_deploys_refuse_live_execution(self):
        for relative in sorted(RETIRED):
            with self.subTest(path=relative):
                result = subprocess.run(
                    ["bash", str(REPO / relative)],
                    env={**os.environ, "DRY_RUN": "0"},
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 5, result.stderr)
                self.assertIn("this coordinator-only Pearl deploy authority is retired", result.stderr)

    def test_retired_observe_helper_refuses_apply(self):
        result = subprocess.run(
            ["bash", str(REPO / "scripts/activate-tier2-observe.sh"), "--apply"],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--apply is retired", result.stderr)

    def test_classified_paths_exist(self):
        for relative in [*GUARDED, *S3_OWNED, *RETIRED, *NOT_WRITERS]:
            with self.subTest(path=relative):
                self.assertTrue((REPO / relative).is_file())


class InstalledWriterManifestTests(unittest.TestCase):
    def test_manifest_format_and_repo_paths(self):
        entries = read_manifest()
        self.assertEqual(len({installed for installed, _ in entries}), len(entries))
        for installed, repo_path in entries:
            with self.subTest(installed=installed):
                self.assertTrue(installed.startswith("/"))
                self.assertFalse(repo_path.startswith("/"))
                self.assertTrue((REPO / repo_path).is_file(), repo_path)

    def test_manifest_lists_the_pearl_installed_guard_bearing_writers(self):
        entries = dict(read_manifest())
        self.assertEqual(entries["/usr/local/sbin/macprovider-pearl-update"], "ops/pearl-updater/macprovider-pearl-update")
        self.assertEqual(
            entries["/usr/local/sbin/macprovider-tier2-enforcement-watchdog"],
            "ops/pearl-updater/macprovider-tier2-enforcement-watchdog",
        )
        self.assertEqual(
            entries["/usr/local/share/macprovider/scripts/coordinator_config_guard.py"],
            "scripts/lib/coordinator_config_guard.py",
        )
        self.assertEqual(
            entries["/opt/macprovider/coordinator-deploy-recover"],
            "phase4-coordinator/dist/coordinator-deploy-recover.sh",
        )
        # deploy-pearl-vps.sh installs the shell guard next to deploy-recover,
        # which sources it in --pre-start.
        self.assertEqual(
            entries["/opt/macprovider/coordinator-config-guard.sh"],
            "scripts/lib/coordinator-config-guard.sh",
        )
        for installed, repo_path in entries.items():
            if repo_path in GUARDED:
                text = (REPO / repo_path).read_text(encoding="utf-8")
                for marker in GUARDED[repo_path]:
                    self.assertIn(marker, text)

    def test_updater_installer_installs_each_updater_owned_manifest_entry(self):
        installer = INSTALLER.read_text(encoding="utf-8")
        for installed, repo_path in read_manifest():
            if not installed.startswith("/usr/local/"):
                continue  # /opt/macprovider entries are installed by deploy-pearl-vps.sh
            with self.subTest(installed=installed):
                self.assertIn(f'"$INSTALL_PREFIX{installed}"', installer)


class PythonGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.temporary.name))
        self.gid = self.root.stat().st_gid

    def tearDown(self):
        self.temporary.cleanup()

    def lock_set(self, **kwargs):
        return guard.LockSet(
            self.root,
            updater_lock=self.root / "updater.lock",
            required_uid=os.getuid(),
            required_gid=self.gid,
            **kwargs,
        )

    def test_refuse_if_pricing_txn(self):
        guard.refuse_if_pricing_txn(self.root)
        (self.root / ".pricing-txn").mkdir()
        with self.assertRaisesRegex(guard.PricingTransactionActive, REFUSAL_RE) as raised:
            guard.refuse_if_pricing_txn(self.root)
        self.assertEqual(raised.exception.path, self.root / ".pricing-txn")

    def test_dangling_journal_symlink_counts_as_present(self):
        (self.root / ".pricing-txn").symlink_to(self.root / "absent")
        with self.assertRaises(guard.PricingTransactionActive):
            guard.refuse_if_pricing_txn(self.root)

    def test_set_aside_journal_counts_as_present(self):
        # A journal left set aside by a killed --resolve-deploy-conflict is
        # still a pricing transaction for every Python writer.
        held = self.root / ".pricing-txn.conflict-held.4242.99"
        held.mkdir()
        with self.assertRaises(guard.PricingTransactionActive) as raised:
            guard.refuse_if_pricing_txn(self.root)
        self.assertEqual(raised.exception.path, held)
        with self.assertRaises(guard.PricingTransactionActive):
            with self.lock_set():
                pass

    def test_lock_set_holds_both_locks_in_lease_order_and_releases(self):
        with self.lock_set() as held:
            self.assertEqual(len(held.descriptors), 2)
            for name in ("updater.lock", ".coordinator-deploy.lock"):
                probe = os.open(self.root / name, os.O_RDWR)
                try:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(probe)
                self.assertEqual(os.stat(self.root / name).st_mode & 0o777, 0o600)
        with self.lock_set():
            pass

    def test_lock_set_refuses_journal_and_releases_locks(self):
        (self.root / ".pricing-txn").mkdir()
        with self.assertRaises(guard.PricingTransactionActive):
            with self.lock_set():
                self.fail("guarded body ran with a pricing journal present")
        (self.root / ".pricing-txn").rmdir()
        with self.lock_set():
            pass

    def test_busy_deploy_lock_releases_the_updater_lock(self):
        deploy = guard.acquire_lock(
            self.root / ".coordinator-deploy.lock", required_uid=os.getuid(), required_gid=self.gid
        )
        try:
            with self.assertRaisesRegex(guard.GuardLockBusy, "coordinator-deploy.lock"):
                with self.lock_set():
                    pass
            updater = guard.acquire_lock(
                self.root / "updater.lock", required_uid=os.getuid(), required_gid=self.gid
            )
            os.close(updater)
        finally:
            os.close(deploy)

    def test_hold_updater_false_takes_only_the_deploy_lock(self):
        with self.lock_set(hold_updater=False) as held:
            self.assertEqual(len(held.descriptors), 1)
            self.assertFalse((self.root / "updater.lock").exists())

    def test_unsafe_locks_are_refused(self):
        lock = self.root / ".coordinator-deploy.lock"
        lock.write_text("")
        os.chmod(lock, 0o644)
        with self.assertRaisesRegex(guard.GuardLockError, "unsafe coordinator config lock"):
            with self.lock_set(hold_updater=False):
                pass
        lock.unlink()
        lock.symlink_to(self.root / "elsewhere")
        with self.assertRaisesRegex(guard.GuardLockError, "cannot safely open"):
            with self.lock_set(hold_updater=False):
                pass
        lock.unlink()
        os.close(os.open(self.root / "other", os.O_CREAT | os.O_RDWR, 0o600))
        os.link(self.root / "other", lock)
        with self.assertRaisesRegex(guard.GuardLockError, "unsafe coordinator config lock"):
            with self.lock_set(hold_updater=False):
                pass
        with self.assertRaises(guard.GuardLockError):
            guard.acquire_lock(lock, required_uid=os.getuid() + 1, required_gid=None)

    def test_exit_code_contract(self):
        self.assertEqual((guard.EX_REFUSED, guard.EX_PRE_START_JOURNAL), (75, 76))


class ShellGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.temporary.name))
        self.install_root = self.root / "opt/macprovider"
        self.install_root.mkdir(parents=True)
        (self.root / "run/lock").mkdir(parents=True)
        self.updater_lock = self.root / "run/lock/macprovider-pearl-updater.lock"
        self.deploy_lock = self.install_root / ".coordinator-deploy.lock"
        shim = self.root / "flock"
        shim.write_text(FLOCK_SHIM)
        shim.chmod(0o755)
        self.env = {
            **os.environ,
            "MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE": str(self.updater_lock),
            "MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID": str(os.getuid()),
            "MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID": str(self.root.stat().st_gid),
            "MACPROVIDER_FLOCK": str(shim),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def sh(self, body, *, shell="sh"):
        return subprocess.run(
            [shell, "-c", f'. "{SHELL_GUARD}"\n{body}'],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_refuse_absent_present_and_pre_start(self):
        root = self.install_root
        self.assertEqual(self.sh(f"ccg_refuse_if_pricing_txn '{root}'").returncode, 0)
        (root / ".pricing-txn").mkdir()
        result = self.sh(f"ccg_refuse_if_pricing_txn '{root}'")
        self.assertEqual(result.returncode, 75)
        self.assertEqual(
            result.stderr,
            f"refusing: pricing transaction journal present at {root}/.pricing-txn; "
            "run scripts/catalog-content-release.sh --recover-pricing-txn\n",
        )
        self.assertEqual(self.sh(f"ccg_refuse_if_pricing_txn '{root}' --pre-start").returncode, 76)
        self.assertEqual(self.sh(f"ccg_refuse_if_pricing_txn '{root}' --bogus").returncode, 2)
        (root / ".pricing-txn").rmdir()
        self.assertEqual(self.sh(f"ccg_refuse_if_pricing_txn '{root}' --pre-start").returncode, 0)
        (root / ".pricing-txn").symlink_to(root / "absent")
        self.assertEqual(self.sh(f"ccg_refuse_if_pricing_txn '{root}'").returncode, 75)

    def test_shell_and_python_refusal_messages_match(self):
        (self.install_root / ".pricing-txn").mkdir()
        result = self.sh(f"ccg_refuse_if_pricing_txn '{self.install_root}'")
        self.assertEqual(result.stderr.strip(), guard.refusal_message(self.install_root / ".pricing-txn"))

    def test_lock_set_is_held_until_the_shell_exits(self):
        result = self.sh(
            f"ccg_take_lock_set '{self.install_root}' || exit 9\n"
            "python3 - <<'PY'\n"
            "import fcntl, os, sys\n"
            f"for p in ({str(self.updater_lock)!r}, {str(self.deploy_lock)!r}):\n"
            "    fd = os.open(p, os.O_RDWR)\n"
            "    try:\n"
            "        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
            "        sys.exit('lock not held: ' + p)\n"
            "    except BlockingIOError:\n"
            "        pass\n"
            "PY\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (self.updater_lock, self.deploy_lock):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            fd = os.open(path, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)

    def hold(self, path):
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd

    def test_busy_locks_refuse_and_release(self):
        fd = self.hold(self.updater_lock)
        try:
            result = self.sh(f"ccg_take_lock_set '{self.install_root}'")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Pearl updater lock held", result.stderr)
        finally:
            os.close(fd)
        fd = self.hold(self.deploy_lock)
        try:
            result = self.sh(
                f"ccg_take_lock_set '{self.install_root}' && exit 0\n"
                "rc=$?\n"
                f"python3 -c 'import fcntl,os,sys; fd=os.open(sys.argv[1], os.O_RDWR); "
                "fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)' "
                f"'{self.updater_lock}' || exit 8\n"
                "exit $rc"
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("coordinator deploy lock held", result.stderr)
        finally:
            os.close(fd)

    def test_wait_mode_acquires_once_released(self):
        fd = self.hold(self.deploy_lock)
        releaser = subprocess.Popen(["sleep", "0.5"])
        try:
            proc = subprocess.Popen(
                ["sh", "-c", f'. "{SHELL_GUARD}"\nccg_take_lock_set \'{self.install_root}\' 10'],
                env=self.env,
                text=True,
                stderr=subprocess.PIPE,
            )
            releaser.wait()
            os.close(fd)
            fd = None
            _, stderr = proc.communicate(timeout=20)
            self.assertEqual(proc.returncode, 0, stderr)
        finally:
            if fd is not None:
                os.close(fd)

    def test_unsafe_lock_is_refused(self):
        self.deploy_lock.write_text("")
        os.chmod(self.deploy_lock, 0o644)
        result = self.sh(f"ccg_take_lock_set '{self.install_root}'")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsafe coordinator config lock", result.stderr)

    def test_remote_guard_script_prologue(self):
        marker = self.root / "mutated"
        body = "$(ccg_remote_guard_script \"$LIB\" \"$ROOT\")"
        script = subprocess.run(
            ["bash", "-c", f'. "{SHELL_GUARD}"\nprintf "%s" "{body}"'],
            env={**self.env, "LIB": str(SHELL_GUARD), "ROOT": str(self.install_root)},
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        self.assertTrue(script.startswith("set -eu\n"))
        remote = script + f"\ntouch '{marker}'\n"
        result = subprocess.run(["bash", "-c", remote], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists())
        marker.unlink()
        (self.install_root / ".pricing-txn").mkdir()
        result = subprocess.run(["bash", "-c", remote], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 75)
        self.assertRegex(result.stderr, REFUSAL_RE)
        self.assertFalse(marker.exists())


# ---------------------------------------------------------------------------
# Per-writer refusal: the Tier-2 activation scripts end to end, remote shell
# executed locally by a fake ssh.
# ---------------------------------------------------------------------------
MODELS = {
    "data": [{"id": "mlx-community/test"}],
    "tier1_disclosure": {
        "provider_leg_encryption": "all",
        "hardware_attestation": "all",
        "tier2": {
            "encrypted_leg": {"state": "all", "encrypted_provider_count": 1,
                              "unencrypted_provider_count": 0, "scope": "coordinator_to_provider_only"},
            "attestation": {"state": "all", "attested_provider_count": 1, "unsupported_provider_count": 0},
        },
    },
}
MODELS["tier2"] = MODELS["tier1_disclosure"]["tier2"]
POOLZ = {"pool": [{"provider_id": "p", "model_id": "mlx-community/test", "binary_version": "1.2.6",
                   "state": "ready", "slots_free": 1, "encrypted_leg": True, "attestation_status": "attested"}]}
CONFIG = textwrap.dedent(
    """\
    server:
      address: 127.0.0.1
    tier2:
      catalog_path: /opt/macprovider/autotune/current/tier2-catalog.json
      catalog_public_key: test-key
      require_hash_verified: true
      require_encrypted_leg: true
      attestation_roots:
        - production-root
    pool:
      canary_enabled: false
    """
)
ACTIVATION_SCRIPTS = (
    "scripts/activate-tier2-attestation.sh",
    "scripts/activate-tier2-behavioral-safety.sh",
    "scripts/activate-tier2-encrypted-leg.sh",
)


class ActivationWriterRefusalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.temporary.name))
        self.install_root = self.root / "opt/macprovider"
        self.install_root.mkdir(parents=True)
        (self.root / "run/lock").mkdir(parents=True)
        self.config = self.install_root / "coordinator.yaml"
        self.config.write_text(CONFIG)
        os.chmod(self.config, 0o640)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.log = self.root / "remote.log"
        fakes = {
            "ssh": '#!/usr/bin/env bash\ncmd="${*: -1}"\nexec bash -c "$cmd"\n',
            "flock": FLOCK_SHIM,
            "verify": "#!/bin/sh\nexit 0\n",
            "curl": (
                "#!/usr/bin/env bash\nurl=\"${*: -1}\"\n"
                f"case \"$url\" in */v1/models) cat '{self.root}/models.json' ;; "
                f"*/poolz) cat '{self.root}/poolz.json' ;; *) echo '{{}}' ;; esac\n"
            ),
            "systemctl": f"#!/bin/sh\nprintf 'systemctl %s\\n' \"$*\" >>'{self.log}'\n"
                         "case \"$1\" in is-active) echo active ;; esac\n",
            "journalctl": (
                "#!/bin/sh\n"
                f"[ -z \"${{MUTATE_ON_JOURNAL:-}}\" ] || printf '# concurrent\\n' >>'{self.config}'\n"
                "[ \"${FAIL_JOURNAL:-0}\" = 1 ] || echo 'tier2 config reloaded'\n"
            ),
        }
        for name, body in fakes.items():
            path = bin_dir / name
            path.write_text(body)
            path.chmod(0o755)
        (self.root / "models.json").write_text(json.dumps(MODELS))
        (self.root / "poolz.json").write_text(json.dumps(POOLZ))
        (self.root / "key").write_text("")
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "SSH_BIN": str(bin_dir / "ssh"),
            "SSH_KEY": str(self.root / "key"),
            "VERIFY_SCRIPT": str(bin_dir / "verify"),
            "REMOTE_CONFIG": str(self.config),
            "DEMO_TOKEN": "demo",
            "OPERATOR_KEY": "operator",
            "MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE": str(self.root / "run/lock/macprovider-pearl-updater.lock"),
            "MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID": str(os.getuid()),
            "MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID": str(self.root.stat().st_gid),
            "MACPROVIDER_FLOCK": str(bin_dir / "flock"),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def apply(self, script, **extra):
        return subprocess.run(
            ["bash", str(REPO / script), "--apply"],
            env={**self.env, **extra},
            text=True,
            capture_output=True,
            timeout=120,
        )

    def hups(self):
        return self.log.read_text().count("kill -s HUP") if self.log.exists() else 0

    def test_every_activation_writer_refuses_with_an_abandoned_journal(self):
        (self.install_root / ".pricing-txn").mkdir(mode=0o700)
        for script in ACTIVATION_SCRIPTS:
            with self.subTest(script=script):
                result = self.apply(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, REFUSAL_RE)
                self.assertEqual(self.config.read_text(), CONFIG)
                self.assertEqual(list(self.install_root.glob("coordinator.yaml.*")), [])
                self.assertEqual(self.hups(), 0)

    def test_activation_writer_refuses_while_the_lock_set_is_held(self):
        fd = os.open(self.install_root / ".coordinator-deploy.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.apply("scripts/activate-tier2-attestation.sh")
        finally:
            os.close(fd)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("coordinator deploy lock held", result.stderr)
        self.assertEqual(self.config.read_text(), CONFIG)
        self.assertEqual(self.hups(), 0)

    def test_guarded_patch_hups_inside_the_lock_and_rolls_back_by_digest(self):
        result = self.apply("scripts/activate-tier2-attestation.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        patched = self.config.read_text()
        self.assertIn("  require_attestation: true\n", patched)
        self.assertIn(f"config_sha256={hashlib.sha256(patched.encode()).hexdigest()}", result.stderr)
        self.assertEqual(self.hups(), 1)

        self.config.write_text(CONFIG)
        result = self.apply("scripts/activate-tier2-attestation.sh", FAIL_JOURNAL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), CONFIG, result.stderr)
        self.assertEqual(self.hups(), 3)

    def test_rollback_refuses_when_the_config_moved_after_the_patch(self):
        result = self.apply("scripts/activate-tier2-attestation.sh", FAIL_JOURNAL="1", MUTATE_ON_JOURNAL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing rollback: live coordinator config changed since this run patched it", result.stderr)
        self.assertTrue(self.config.read_text().endswith("# concurrent\n"))
        self.assertIn("require_attestation: true", self.config.read_text())
        self.assertEqual(self.hups(), 1)

    def test_rollback_refuses_while_a_pricing_journal_exists(self):
        # A journal that appears after the patch (another writer's abandoned
        # transaction) blocks the restore too.
        journal = self.install_root / ".pricing-txn"
        fake = self.root / "bin/journalctl"
        fake.write_text(f"#!/bin/sh\nmkdir -p '{journal}'\nexit 1\n")
        result = self.apply("scripts/activate-tier2-attestation.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, REFUSAL_RE)
        self.assertIn("require_attestation: true", self.config.read_text())
        self.assertEqual(self.hups(), 1)


if __name__ == "__main__":
    unittest.main()
