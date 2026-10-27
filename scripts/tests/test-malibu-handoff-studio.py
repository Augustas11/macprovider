#!/usr/bin/env python3
"""Isolated Studio GUI acceptance for the #2155 Malibu handoff.

Run only on the designated Studio as its console user. The script creates an
ad-hoc-signed test fixture under one temporary directory; it never reads,
stops, or modifies the live provider payload or its LaunchAgent. Production
signature enforcement remains in the app unit tests: this fixture's verifier
accepts exact runner-supplied CDHashes only, scoped to its temporary root.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
from dataclasses import dataclass
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HANDOFF = ROOT / "phase3-binary/app/Sources/Malibu/System/AppInstanceHandoff.swift"
VERSION = ROOT / "phase3-binary/app/Sources/Malibu/System/ProviderCLIVersion.swift"
FIXTURE = ROOT / "scripts/tests/malibu-handoff-fixture.swift"
DEVELOPER_DIR = Path.home() / "Applications/Xcode.app/Contents/Developer"
XCODEGEN = Path("/opt/homebrew/bin/xcodegen")
LABEL = "live.malibu.provider"


def run(command: list[str], *, check: bool = True, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, text=True, **kwargs)  # type: ignore[arg-type]


def require_studio() -> None:
    model = run(["sysctl", "-n", "hw.model"], capture_output=True).stdout.strip()
    if Path("/dev/console").stat().st_uid != os.getuid():
        raise RuntimeError("acceptance requires the active GUI console user")
    if model != "Mac15,14":
        raise RuntimeError(f"refusing non-Studio host model {model!r}")
    if not DEVELOPER_DIR.is_dir() or not XCODEGEN.is_file():
        raise RuntimeError("required Studio Xcode or pinned xcodegen is unavailable")


def provider_pid() -> str:
    uid = str(os.getuid())
    output = run(["launchctl", "print", f"gui/{uid}/{LABEL}"], capture_output=True).stdout
    for line in output.splitlines():
        if line.strip().startswith("pid = "):
            return line.split("=", 1)[1].strip()
    raise RuntimeError("live provider is not running; refusing acceptance")


def cdhash(bundle: Path) -> str:
    target = bundle / "Contents/MacOS/Malibu" if bundle.is_dir() else bundle
    result = run(["codesign", "-d", "--verbose=4", str(target)], capture_output=True, check=False)
    text = result.stderr + result.stdout
    for line in text.splitlines():
        if line.startswith("CDHash="):
            return line.split("=", 1)[1].strip().lower()
    raise RuntimeError(f"could not read fixture CDHash for {bundle}")


def fixture_stub(path: Path) -> None:
    path.write_text(
        "import Foundation\n"
        "enum CLIUpdateRunner {\n"
        " static let runningAppVersion: String? = nil\n"
        " static func isUpdaterOwnedMalibuInstall(_: URL) -> Bool { false }\n"
        " static func validateMalibuAppCodeSignature(at _: URL) -> Bool { false }\n"
        "}\n",
        encoding="utf-8",
    )


def build_fixture(stage: Path) -> Path:
    fixture_stub(stage / "CLIUpdateRunner.swift")
    binary = stage / "Malibu"
    environment = os.environ | {"DEVELOPER_DIR": str(DEVELOPER_DIR)}
    run([
        "nice", "-n", "10", "swiftc", "-target", "arm64-apple-macos14.0", "-D", "MALIBU_HANDOFF_STUDIO_FIXTURE", "-framework", "AppKit", "-framework", "Security",
        "-o", str(binary), str(FIXTURE), str(HANDOFF), str(VERSION), str(stage / "CLIUpdateRunner.swift"),
    ], env=environment)
    return binary


def build_untrusted(stage: Path) -> Path:
    source = stage / "untrusted.swift"
    source.write_text(
        "import AppKit\nimport Foundation\nimport Darwin\n"
        "final class D: NSObject, NSApplicationDelegate {\n"
        " var item: NSStatusItem?\n"
        " func applicationDidFinishLaunching(_: Notification) {\n"
        "  item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)\n"
        "  item?.button?.title = \"Untrusted fixture\"\n"
        "  print(\"pid=\\(ProcessInfo.processInfo.processIdentifier) untrusted-status-item-created\"); fflush(stdout)\n"
        " }\n"
        " func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply { .terminateLater }\n"
        "}\n"
        "_ = Darwin.nice(10); let a = NSApplication.shared; let d = D(); a.setActivationPolicy(.accessory); a.delegate = d; withExtendedLifetime(d) { a.run() }\n",
        encoding="utf-8",
    )
    binary = stage / "UntrustedMalibu"
    run(["nice", "-n", "10", "swiftc", "-target", "arm64-apple-macos14.0", "-framework", "AppKit", "-o", str(binary), str(source)],
        env=os.environ | {"DEVELOPER_DIR": str(DEVELOPER_DIR)})
    return binary


def make_bundle(root: Path, relative: str, binary: Path, version: str, bundle_id: str = "tech.malibu.app") -> Path:
    bundle = root / relative
    executable = bundle / "Contents/MacOS/Malibu"
    executable.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, executable)
    plist = {
        "CFBundleIdentifier": bundle_id,
        "CFBundlePackageType": "APPL",
        "CFBundleName": "Malibu" if bundle_id == "tech.malibu.app" else "Almost Malibu",
        "CFBundleExecutable": "Malibu",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version.rsplit(".", 1)[-1],
        "LSUIElement": True,
    }
    with (bundle / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(plist, handle)
    run(["codesign", "--force", "--sign", "-", str(bundle)])
    return bundle


@dataclass
class LaunchedApp:
    launcher: subprocess.Popen[str]
    log: Path
    root: Path

    @property
    def pid(self) -> int:
        text = self.log.read_text(errors="replace") if self.log.exists() else ""
        match = re.search(r"pid=(\d+)", text)
        if not match:
            raise RuntimeError("fixture did not report its process identity")
        return int(match.group(1))

    def poll(self) -> int | None:
        return self.launcher.poll()

    def wait(self, timeout: float) -> int:
        return self.launcher.wait(timeout=timeout)

    def send_signal(self, value: int) -> None:
        # open -W owns the app lifecycle. Check the exact owned executable
        # location before cleanup; never signal its launcher PID as an app.
        identity = self.pid
        result = run(["ps", "-p", str(identity), "-o", "comm="], check=False, capture_output=True)
        executable = Path(result.stdout.strip()).resolve()
        if result.returncode == 0 and executable.is_relative_to(self.root.resolve()):
            os.kill(identity, value)
        elif self.launcher.poll() is None:
            raise RuntimeError("refusing cleanup of an unverified fixture process")


def launch(bundle: Path, root: Path, mode: str, trusted: list[str], log: Path) -> LaunchedApp:
    command = ["nice", "-n", "10", "open", "-n", "-W", "-g", "--stdout", str(log), "--stderr", str(log)]
    for key, value in {
        "MALIBU_HANDOFF_ROOT": str(root),
        "MALIBU_HANDOFF_MODE": mode,
        "MALIBU_HANDOFF_TRUSTED_CDHASHES": ",".join(trusted),
    }.items():
        command += ["--env", f"{key}={value}"]
    command.append(str(bundle))
    return LaunchedApp(subprocess.Popen(command, text=True), log, root)


def wait_for(log: Path, text: str, provider: str, timeout: float = 12) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log.exists() and text in log.read_text(encoding="utf-8", errors="replace"):
            return
        assert_provider_unchanged(provider)
        time.sleep(0.2)
    raise AssertionError(f"did not observe {text!r}")


def wait_exit(process: LaunchedApp, provider: str, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return
        assert_provider_unchanged(provider)
        time.sleep(0.25)
    raise AssertionError(f"fixture PID {process.pid} did not exit")


def sleep_with_provider(seconds: float, provider: str) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        assert_provider_unchanged(provider)
        time.sleep(max(0, min(0.25, deadline - time.monotonic())))


def alive(process: LaunchedApp) -> bool:
    return process.poll() is None


def terminate(processes: list[LaunchedApp]) -> None:
    for process in processes:
        if alive(process):
            process.send_signal(signal.SIGKILL)
    for process in processes:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def assert_provider_unchanged(expected: str) -> None:
    actual = provider_pid()
    if actual != expected:
        raise AssertionError("live provider PID changed during isolated app acceptance")


def assert_single_status_item(survivor: LaunchedApp) -> None:
    output = run(["ps", "-axo", "pid=,comm="], capture_output=True).stdout
    peers = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and Path(fields[1]).resolve().is_relative_to(survivor.root.resolve()):
            peers.append(int(fields[0]))
    if peers != [survivor.pid]:
        raise AssertionError(f"expected one owned app process, found {len(peers)}")
    if survivor.log.read_text().count("status-item-created") != 1:
        raise AssertionError("surviving app did not create exactly one status item")
    print("process-list count=1; surviving status-item creation count=1", flush=True)


def activation_case(root: Path, binary: Path, provider: str) -> None:
    old = make_bundle(root, "Applications/Malibu.app", binary, "1.8.272")
    old_hash = cdhash(old)
    old_log = root / "legacy.log"
    legacy = launch(old, root, "legacy", [old_hash], old_log)
    try:
        wait_for(old_log, "status-item-created", provider)
        if (root / "registry" / f"{legacy.pid}.json").exists():
            raise AssertionError("legacy fixture unexpectedly published a handshake")
        sleep_with_provider(3, provider)
        moved = root / f"Applications/.Malibu.app.activation-{uuid.uuid4()}"
        old.rename(moved)
        current = make_bundle(root, "Applications/Malibu.app", binary, "1.8.274")
        current_hash = cdhash(current)
        current_log = root / "successor.log"
        successor = launch(current, root, "successor", [old_hash, current_hash], current_log)
    except BaseException:
        terminate([legacy])
        raise
    try:
        started = time.monotonic()
        wait_for(current_log, "claim-ready", provider)
        wait_exit(legacy, provider, 48)
        elapsed = time.monotonic() - started
        if elapsed < 40:
            raise AssertionError(f"legacy predecessor exited before the 40-second force deadline ({elapsed:.1f}s)")
        if not alive(successor):
            raise AssertionError("successor exited while retiring legacy predecessor")
        if "legacy-terminate-later-forever" not in old_log.read_text():
            raise AssertionError("legacy process did not enter its hung quit drain")
        assert_single_status_item(successor)
        if "force=true" not in current_log.read_text(encoding="utf-8", errors="replace"):
            raise AssertionError("legacy moved predecessor was not force-exited after the real deadline")
        assert_provider_unchanged(provider)
        print(f"PASS activation legacy hung drain: one process/status item remains; elapsed={elapsed:.2f}s", flush=True)
    finally:
        terminate([legacy, successor])


def production_gate_case(root: Path, binary: Path, provider: str) -> None:
    bundle = make_bundle(root, "production-gate/Malibu.app", binary, "1.8.274")
    log = root / "production-gate.log"
    process = launch(bundle, root, "verify-production-gate", [cdhash(bundle)], log)
    try:
        wait_for(log, "production-team-gate-rejected-adhoc", provider)
        wait_exit(process, provider, 12)
        assert_provider_unchanged(provider)
        print("PASS production Team-ID gate rejects ad-hoc fixture")
    finally:
        terminate([process])


def same_version_case(root: Path, binary: Path, provider: str) -> None:
    bundle = make_bundle(root, "same/Malibu.app", binary, "1.8.274")
    trusted = [cdhash(bundle)]
    first_log, second_log = root / "same-first.log", root / "same-second.log"
    first = launch(bundle, root, "successor", trusted, first_log)
    processes = [first]
    try:
        wait_for(first_log, "claim-ready", provider)
        sleep_with_provider(3, provider)
        second = launch(bundle, root, "successor", trusted, second_log)
        processes.append(second)
        wait_for(second_log, "claim-ready", provider)
        wait_exit(first, provider, 12)
        if not alive(second):
            raise AssertionError("same-version elected successor exited")
        assert_single_status_item(second)
        assert_provider_unchanged(provider)
        print("PASS second same-version launch: one process/status item remains")
    finally:
        terminate(processes)


def rollback_case(root: Path, binary: Path, provider: str) -> None:
    newer = make_bundle(root, "rollback/newer/Malibu.app", binary, "1.8.275")
    older = make_bundle(root, "rollback/Applications/Malibu.app", binary, "1.8.274")
    trusted = [cdhash(newer), cdhash(older)]
    newer_log, older_log = root / "newer.log", root / "older.log"
    winner = launch(newer, root, "successor", trusted, newer_log)
    processes = [winner]
    try:
        wait_for(newer_log, "claim-ready", provider)
        sleep_with_provider(3, provider)
        rollback = launch(older, root, "successor", trusted, older_log)
        processes.append(rollback)
        wait_exit(rollback, provider, 12)
        if not alive(winner):
            raise AssertionError("rollback launch displaced newer app")
        assert_single_status_item(winner)
        if "signal pid=" in older_log.read_text(encoding="utf-8", errors="replace"):
            raise AssertionError("rollback launch signaled newer app")
        assert_provider_unchanged(provider)
        print("PASS rollback: newer process/status item survives")
    finally:
        terminate(processes)


def negative_case(root: Path, binary: Path, untrusted_binary: Path, provider: str) -> None:
    similar = make_bundle(root, "negative/AlmostMalibu.app", binary, "1.8.200", "tech.malibu.almost")
    untrusted = make_bundle(root, "negative/Untrusted.app", untrusted_binary, "1.8.200")
    current = make_bundle(root, "negative/Current.app", binary, "1.8.274")
    trusted = [cdhash(current)]
    similar_log, untrusted_log, current_log = root / "similar.log", root / "untrusted.log", root / "negative-current.log"
    similar_process = launch(similar, root, "passive", trusted, similar_log)
    processes = [similar_process]
    try:
        untrusted_process = launch(untrusted, root, "legacy", trusted, untrusted_log)
        processes.append(untrusted_process)
        wait_for(similar_log, "status-item-created", provider)
        wait_for(untrusted_log, "untrusted-status-item-created", provider)
        sleep_with_provider(3, provider)
        successor = launch(current, root, "successor", trusted, current_log)
        processes.append(successor)
        wait_for(current_log, "claim-ready", provider)
        sleep_with_provider(46, provider)
        if not alive(similar_process) or not alive(untrusted_process):
            raise AssertionError("non-Malibu or untrusted same-bundle process was targeted")
        if "signal pid=" in current_log.read_text(encoding="utf-8", errors="replace"):
            raise AssertionError("successor signaled an excluded process")
        assert_provider_unchanged(provider)
        print("PASS negatives: similar-name and untrusted same-bundle processes survive")
    finally:
        terminate(processes)


def run_cases(root: Path, provider: str) -> None:
    binary = build_fixture(root)
    untrusted_binary = build_untrusted(root)
    production_gate_case(root, binary, provider)
    activation_case(root, binary, provider)
    same_version_case(root, binary, provider)
    rollback_case(root, binary, provider)
    negative_case(root, binary, untrusted_binary, provider)
    assert_provider_unchanged(provider)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, help="private directory for retained fixture logs")
    arguments = parser.parse_args()
    require_studio()
    provider = provider_pid()
    if arguments.output_dir:
        root = arguments.output_dir.resolve()
        root.mkdir(mode=0o700, parents=True, exist_ok=False)
        run_cases(root, provider)
    else:
        with tempfile.TemporaryDirectory(prefix="malibu-2155-handoff-") as directory:
            run_cases(Path(directory), provider)
    print("PASS all #2155 Studio handoff acceptance cases")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
