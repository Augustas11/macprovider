#!/usr/bin/env python3

import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "lib" / "c2c_runtime_proof.py"
SPEC = importlib.util.spec_from_file_location("c2c_runtime_proof", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)

HEX_A = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
HEX_B = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
HEX_C = "89abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567"


class RuntimeProofTests(unittest.TestCase):
    def test_last_duplicate_assignment_wins(self):
        first = "invalid-but-overridden"
        effective = HEX_A
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service.env"
            path.write_text(f"SERVICE_TOKEN={first}\nSERVICE_TOKEN={effective}\n", encoding="utf-8")
            self.assertEqual(proof.effective_env_value(path, "SERVICE_TOKEN"), effective)
            self.assertEqual(
                proof.credential_digest(path, "SERVICE_TOKEN"),
                hashlib.sha256(effective.encode()).hexdigest(),
            )

    def test_export_syntax_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service.env"
            path.write_text(f"export SERVICE_TOKEN={HEX_A}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsupported export syntax"):
                proof.effective_env_value(path, "SERVICE_TOKEN")

    def test_running_process_environment_uses_last_assignment(self):
        effective = HEX_A
        environ = b"SERVICE_TOKEN=short\0OTHER=value\0SERVICE_TOKEN=" + effective.encode() + b"\0"
        self.assertEqual(
            proof.effective_process_env_value(environ, "SERVICE_TOKEN", "example.service"),
            effective,
        )

    def test_multiple_process_credentials_use_one_stable_snapshot(self):
        environ = f"SERVICE_TOKEN={HEX_B}\0OPERATOR_KEY={HEX_C}\0".encode()
        with mock.patch.object(proof, "service_main_pid", side_effect=[123, 123]) as main_pid, mock.patch.object(
            Path, "read_bytes", return_value=environ
        ) as read_bytes:
            self.assertEqual(
                proof.running_service_env_values(
                    "example.service", ("SERVICE_TOKEN", "OPERATOR_KEY")
                ),
                (HEX_B, HEX_C),
            )
            self.assertEqual(main_pid.call_count, 2)
            read_bytes.assert_called_once()

    def test_deploy_modes_use_future_file_and_current_peer_sources(self):
        with mock.patch.object(proof, "credential_digest", side_effect=lambda path, name: f"digest:{name}") as file_digest, mock.patch.object(
            proof,
            "service_credential_digests",
            side_effect=lambda service, names: tuple(f"digest:{name}" for name in names),
        ) as process_digest:
            self.assertEqual(
                proof.deployment_digests("coordinator-deploy", "CO", "CS", "GS", "GO"),
                ("digest:CO", "digest:CS", "digest:GS", "digest:GO"),
            )
            self.assertEqual(
                proof.deployment_digests("gateway-deploy", "CO", "CS", "GS", "GO"),
                ("digest:CO", "digest:CS", "digest:GS", "digest:GO"),
            )
            self.assertIn(mock.call(proof.COORDINATOR_ENV, "CO"), file_digest.call_args_list)
            self.assertIn(mock.call(proof.COORDINATOR_ENV, "CS"), file_digest.call_args_list)
            self.assertIn(mock.call(proof.GATEWAY_ENV, "GS"), file_digest.call_args_list)
            self.assertIn(mock.call(proof.GATEWAY_ENV, "GO"), file_digest.call_args_list)
            self.assertIn(mock.call(proof.COORDINATOR_SERVICE, ("CO", "CS")), process_digest.call_args_list)
            self.assertIn(mock.call(proof.GATEWAY_SERVICE, ("GS", "GO")), process_digest.call_args_list)

    def test_peer_file_process_drift_fails_closed(self):
        with mock.patch.object(proof, "credential_digest", return_value="a" * 64), mock.patch.object(
            proof, "service_credential_digests", return_value=("b" * 64, "a" * 64)
        ):
            with self.assertRaisesRegex(ValueError, "differs between its EnvironmentFile and running process"):
                proof.deployment_digests("gateway-deploy", "CO", "CS", "GS", "GO")

    def test_inline_current_peer_credentials_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "requires gateway coordinator.service_token to use env:NAME"):
            proof.deployment_digests("coordinator-deploy", "CO", "CS", "-", "GO")
        with self.assertRaisesRegex(ValueError, "requires coordinator auth.operator_key to use env:NAME"):
            proof.deployment_digests("gateway-deploy", "-", "CS", "GS", "GO")
        with self.assertRaisesRegex(ValueError, "requires coordinator auth.gateway_service_token to use env:NAME"):
            proof.deployment_digests("gateway-deploy", "CO", "-", "GS", "GO")

    def test_missing_and_invalid_values_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service.env"
            path.write_text("OTHER=value\nSERVICE_TOKEN=short\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "expected 64-hex"):
                proof.effective_env_value(path, "SERVICE_TOKEN")
            with self.assertRaisesRegex(ValueError, "missing requested runtime credential"):
                proof.effective_env_value(path, "MISSING")

    def test_non_hex_and_placeholder_values_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service.env"
            path.write_text(
                "NON_HEX=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n"
                "PLACEHOLDER=REPLACE_ME_REPLACE_ME_REPLACE_ME_REPLACE_ME\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "expected 64-hex"):
                proof.effective_env_value(path, "NON_HEX")
            with self.assertRaisesRegex(ValueError, "placeholder"):
                proof.effective_env_value(path, "PLACEHOLDER")

    def test_weak_64_hex_values_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service.env"
            path.write_text(
                f"REPEATED={'d' * 64}\n"
                f"ZERO={'0' * 64}\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "low_entropy"):
                proof.effective_env_value(path, "REPEATED")
            with self.assertRaisesRegex(ValueError, "repeated_zero"):
                proof.effective_env_value(path, "ZERO")

    def test_errors_redact_bearer_shaped_env_names(self):
        secret_shaped_name = "A" * 40
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service.env"
            path.write_text("OTHER=value\n", encoding="utf-8")
            with self.assertRaises(ValueError) as file_error:
                proof.effective_env_value(path, secret_shaped_name)
            self.assertNotIn(secret_shaped_name, str(file_error.exception))
            with self.assertRaises(ValueError) as process_error:
                proof.effective_process_env_value(b"OTHER=value\0", secret_shaped_name, "example.service")
            self.assertNotIn(secret_shaped_name, str(process_error.exception))


if __name__ == "__main__":
    unittest.main()
