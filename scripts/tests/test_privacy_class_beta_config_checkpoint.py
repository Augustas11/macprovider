from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "lab" / "privacy-class-beta" / "config-change-checkpoint.py"

spec = importlib.util.spec_from_file_location("privacy_lab_config_change_checkpoint", SCRIPT)
assert spec is not None and spec.loader is not None
checkpoint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checkpoint)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class PrivacyLabConfigCheckpointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(dir="/private/tmp" if os.path.isdir("/private/tmp") else None)
        self.root = Path(self.tmp.name) / "lab"
        self.root.mkdir(mode=0o700)
        self.config = self.root / "config.yaml"
        self.replacement = self.root / "config.next.yaml"
        self.config.write_bytes(b"old-config\n")
        self.replacement.write_bytes(b"new-config\n")
        os.chmod(self.config, 0o600)
        os.chmod(self.replacement, 0o600)
        self.replacement_hash = sha256_bytes(b"new-config\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def ready_frame(self, *, nonce: str = "nonce-ok", pid: int | None = None, root: Path | None = None) -> dict[str, object]:
        lab_root = root or self.root
        return {
            "event": checkpoint.READY_EVENT,
            "schema_version": checkpoint.SCHEMA_VERSION,
            "nonce": nonce,
            "pid": pid if pid is not None else os.getpid(),
            "root_digest": hashlib.sha256(os.fspath(lab_root).encode()).hexdigest(),
        }

    def run_controller_with_peer(
        self,
        frame: dict[str, object] | bytes | None,
        *,
        close_without_frame: bool = False,
        timeout_seconds: float = 0.25,
        replacement_hash: str | None = None,
        config: Path | None = None,
        replacement: Path | None = None,
        lab_root: Path | None = None,
        expected_pid: int | None = None,
    ) -> tuple[dict[str, object] | None, bytes]:
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if close_without_frame:
                right.close()
            elif isinstance(frame, bytes):
                right.sendall(frame)
            elif frame is not None:
                right.sendall(json.dumps(frame, sort_keys=True).encode() + b"\n")
            result = checkpoint.run_checkpoint(
                fd=left.fileno(),
                expected_pid=expected_pid if expected_pid is not None else os.getpid(),
                lab_root=lab_root or self.root,
                config_path=config or self.config,
                replacement_path=replacement or self.replacement,
                replacement_sha256=replacement_hash or self.replacement_hash,
                timeout_seconds=timeout_seconds,
            )
            ack = right.recv(4096)
            return result, ack
        finally:
            left.close()
            right.close()

    def run_controller_async(
        self,
        *,
        timeout_seconds: float = 1.0,
        replacement_hash: str | None = None,
    ) -> tuple[socket.socket, threading.Thread, dict[str, object]]:
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        state: dict[str, object] = {}

        def target() -> None:
            try:
                state["result"] = checkpoint.run_checkpoint(
                    fd=left.fileno(),
                    expected_pid=os.getpid(),
                    lab_root=self.root,
                    config_path=self.config,
                    replacement_path=self.replacement,
                    replacement_sha256=replacement_hash or self.replacement_hash,
                    timeout_seconds=timeout_seconds,
                )
            except BaseException as exc:  # noqa: BLE001 - test helper captures assertion target
                state["error"] = exc
            finally:
                left.close()

        thread = threading.Thread(target=target)
        thread.start()
        return right, thread, state

    def assert_config_unchanged(self) -> None:
        self.assertEqual(b"old-config\n", self.config.read_bytes())
        self.assertTrue(self.replacement.exists())

    def test_valid_ready_replaces_config_then_acks_same_nonce(self) -> None:
        result, ack = self.run_controller_with_peer(self.ready_frame(nonce="nonce-123"))
        self.assertEqual(b"new-config\n", self.config.read_bytes())
        self.assertFalse(self.replacement.exists())
        self.assertEqual("privacy_lab_config_change_checkpoint_replaced", result["event"])
        ack_doc = json.loads(ack.decode())
        self.assertEqual(
            {"event": checkpoint.ACK_EVENT, "schema_version": checkpoint.SCHEMA_VERSION, "nonce": "nonce-123"},
            ack_doc,
        )

    def test_invalid_peer_frames_do_not_mutate(self) -> None:
        cases = [
            {**self.ready_frame(), "extra": "nope"},
            {**self.ready_frame(), "event": "wrong"},
            {**self.ready_frame(), "schema_version": 2},
            {**self.ready_frame(), "schema_version": True},
            {**self.ready_frame(), "pid": os.getpid() + 1000},
            {**self.ready_frame(), "pid": True},
            {**self.ready_frame(), "root_digest": "0" * 64},
            {**self.ready_frame(), "nonce": ""},
            b"not-json\n",
            b'{"event":"privacy_lab_config_change_checkpoint_ready","schema_version":1,"nonce":"a","nonce":"b","pid":1,"root_digest":"x"}\n',
            b'{"event":"privacy_lab_config_change_checkpoint_ready","schema_version":1,"nonce":"a","pid":NaN,"root_digest":"x"}\n',
            b"[" + (b"x" * (checkpoint.MAX_FRAME_BYTES + 1)),
        ]
        for frame in cases:
            with self.subTest(frame=frame):
                self.replacement.write_bytes(b"new-config\n")
                os.chmod(self.replacement, 0o600)
                with self.assertRaises(checkpoint.CheckpointError):
                    self.run_controller_with_peer(frame)
                self.assert_config_unchanged()

    def test_eof_timeout_and_hash_drift_do_not_mutate(self) -> None:
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(None, close_without_frame=True)
        self.assert_config_unchanged()

        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            with self.assertRaises(checkpoint.CheckpointError):
                checkpoint.run_checkpoint(
                    fd=left.fileno(),
                    expected_pid=os.getpid(),
                    lab_root=self.root,
                    config_path=self.config,
                    replacement_path=self.replacement,
                    replacement_sha256=self.replacement_hash,
                    timeout_seconds=0.01,
                )
        finally:
            left.close()
            right.close()
        self.assert_config_unchanged()

        for invalid_timeout in (0, -1, float("nan")):
            with self.subTest(timeout=invalid_timeout):
                with self.assertRaises(checkpoint.CheckpointError):
                    self.run_controller_with_peer(self.ready_frame(), timeout_seconds=invalid_timeout)
                self.assert_config_unchanged()

        self.replacement.write_bytes(b"unexpected\n")
        os.chmod(self.replacement, 0o600)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame(), replacement_hash=self.replacement_hash)
        self.assert_config_unchanged()

    def test_root_and_path_safety_and_private_permissions(self) -> None:
        outside = Path(self.tmp.name) / "outside.yaml"
        outside.write_bytes(b"outside\n")
        os.chmod(outside, 0o600)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame(), config=outside)
        self.assert_config_unchanged()

        nested = self.root / "nested"
        nested.mkdir(mode=0o700)
        nested_config = nested / "config.yaml"
        nested_config.write_bytes(b"old-config\n")
        os.chmod(nested_config, 0o600)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame(), config=nested_config)
        self.assert_config_unchanged()

        os.chmod(self.root, 0o755)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame())
        os.chmod(self.root, 0o700)
        self.assert_config_unchanged()

        os.chmod(self.config, 0o644)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame())
        os.chmod(self.config, 0o600)
        self.assert_config_unchanged()

        os.chmod(self.replacement, 0o644)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame())
        os.chmod(self.replacement, 0o600)
        self.assert_config_unchanged()

        hardlink = self.root / "config-hardlink.yaml"
        os.link(self.config, hardlink)
        try:
            with self.assertRaises(checkpoint.CheckpointError):
                self.run_controller_with_peer(self.ready_frame())
        finally:
            hardlink.unlink()

        replacement_hardlink = self.root / "replacement-hardlink.yaml"
        os.link(self.replacement, replacement_hardlink)
        try:
            with self.assertRaises(checkpoint.CheckpointError):
                self.run_controller_with_peer(self.ready_frame())
        finally:
            replacement_hardlink.unlink()

        outside_replacement = Path(self.tmp.name) / "outside-replacement.yaml"
        outside_replacement.write_bytes(b"new-config\n")
        os.chmod(outside_replacement, 0o600)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(
                self.ready_frame(),
                replacement=outside_replacement,
                replacement_hash=sha256_bytes(b"new-config\n"),
            )
        self.assert_config_unchanged()

        self.replacement.unlink()
        os.mkfifo(self.replacement, 0o600)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame())
        self.assertEqual(b"old-config\n", self.config.read_bytes())
        self.assertTrue(self.replacement.exists())

    def test_symlink_paths_are_rejected_without_mutation(self) -> None:
        linked = self.root / "linked-config.yaml"
        linked.symlink_to(self.config)
        with self.assertRaises(checkpoint.CheckpointError):
            self.run_controller_with_peer(self.ready_frame(), config=linked)
        self.assert_config_unchanged()

    def test_non_socket_fd_is_rejected_without_mutation(self) -> None:
        fd = os.open(self.config, os.O_RDONLY)
        try:
            with self.assertRaises(checkpoint.CheckpointError):
                checkpoint.run_checkpoint(
                    fd=fd,
                    expected_pid=os.getpid(),
                    lab_root=self.root,
                    config_path=self.config,
                    replacement_path=self.replacement,
                    replacement_sha256=self.replacement_hash,
                    timeout_seconds=0.25,
                )
            self.assert_config_unchanged()
        finally:
            os.close(fd)

    def test_tcp_socket_fd_is_rejected_without_mutation(self) -> None:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        client = socket.create_connection(server.getsockname())
        conn, _ = server.accept()
        try:
            with self.assertRaises(checkpoint.CheckpointError):
                checkpoint.run_checkpoint(
                    fd=client.fileno(),
                    expected_pid=os.getpid(),
                    lab_root=self.root,
                    config_path=self.config,
                    replacement_path=self.replacement,
                    replacement_sha256=self.replacement_hash,
                    timeout_seconds=0.25,
                )
            self.assert_config_unchanged()
        finally:
            client.close()
            conn.close()
            server.close()

    def test_replacement_revalidated_after_ready_before_mutation(self) -> None:
        peer, thread, state = self.run_controller_async()
        try:
            time.sleep(0.05)
            self.replacement.write_bytes(b"tampered-after-initial-validation\n")
            os.chmod(self.replacement, 0o600)
            peer.sendall(json.dumps(self.ready_frame()).encode() + b"\n")
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
            self.assertIsInstance(state.get("error"), checkpoint.CheckpointError)
            self.assertEqual(b"old-config\n", self.config.read_bytes())
            self.assertEqual(b"tampered-after-initial-validation\n", self.replacement.read_bytes())
        finally:
            peer.close()
            thread.join(timeout=2)

    def test_replacement_swap_between_final_check_and_rename_is_not_acked(self) -> None:
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        real_replace = checkpoint.os.replace

        def swapping_replace(src: str, dst: str, *args: object, **kwargs: object) -> None:
            self.replacement.unlink()
            self.replacement.write_bytes(b"swapped-after-final-check\n")
            os.chmod(self.replacement, 0o600)
            real_replace(src, dst, *args, **kwargs)

        try:
            right.sendall(json.dumps(self.ready_frame()).encode() + b"\n")
            checkpoint.os.replace = swapping_replace
            with self.assertRaises(checkpoint.CheckpointError):
                checkpoint.run_checkpoint(
                    fd=left.fileno(),
                    expected_pid=os.getpid(),
                    lab_root=self.root,
                    config_path=self.config,
                    replacement_path=self.replacement,
                    replacement_sha256=self.replacement_hash,
                    timeout_seconds=0.25,
                )
            right.settimeout(0.1)
            with self.assertRaises(TimeoutError):
                right.recv(4096)
        finally:
            checkpoint.os.replace = real_replace
            left.close()
            right.close()

    def test_pinned_root_fd_prevents_path_redirected_mutation(self) -> None:
        peer, thread, state = self.run_controller_async()
        old_root = Path(self.tmp.name) / "lab.old"
        try:
            time.sleep(0.05)
            self.root.rename(old_root)
            self.root.mkdir(mode=0o700)
            redirected_config = self.root / "config.yaml"
            redirected_replacement = self.root / "config.next.yaml"
            redirected_config.write_bytes(b"redirected-old\n")
            redirected_replacement.write_bytes(b"redirected-new\n")
            os.chmod(redirected_config, 0o600)
            os.chmod(redirected_replacement, 0o600)

            old_replacement = old_root / "config.next.yaml"
            old_replacement.write_bytes(b"tampered-old-root\n")
            os.chmod(old_replacement, 0o600)
            peer.sendall(json.dumps(self.ready_frame()).encode() + b"\n")
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
            self.assertIsInstance(state.get("error"), checkpoint.CheckpointError)
            self.assertEqual(b"redirected-old\n", redirected_config.read_bytes())
            self.assertEqual(b"old-config\n", (old_root / "config.yaml").read_bytes())
        finally:
            peer.close()
            thread.join(timeout=2)

    def test_subprocess_inherited_fd_path(self) -> None:
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            proc = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--fd",
                    str(child.fileno()),
                    "--expected-pid",
                    str(os.getpid()),
                    "--lab-root",
                    str(self.root),
                    "--config",
                    str(self.config),
                    "--replacement",
                    str(self.replacement),
                    "--replacement-sha256",
                    self.replacement_hash,
                    "--timeout-seconds",
                    "1",
                ],
                pass_fds=(child.fileno(),),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            child.close()
            parent.sendall(json.dumps(self.ready_frame()).encode() + b"\n")
            ack = json.loads(parent.recv(4096).decode())
            stdout, stderr = proc.communicate(timeout=2)
            self.assertEqual(0, proc.returncode, stderr)
            self.assertEqual(checkpoint.ACK_EVENT, ack["event"])
            self.assertEqual(b"new-config\n", self.config.read_bytes())
            self.assertIn("privacy_lab_config_change_checkpoint_replaced", stdout)
        finally:
            parent.close()
            child.close()


if __name__ == "__main__":
    unittest.main()
