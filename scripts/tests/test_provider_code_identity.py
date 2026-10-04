#!/usr/bin/env python3
"""Tests for scripts/provider-code-identity.py (issue #1842).

Fake `codesign` and `lipo` executables on PATH stand in for the Apple tools so
the producer's fail-closed parsing runs on any host.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "provider-code-identity.py"
TEAM = "ABCDE12345"
CDHASH = "0123456789abcdef0123456789abcdef01234567"
TAG = "v1.8.214"
ASSET = f"macprovider-cli-{TAG}-darwin-arm64.tar.gz"
BINARY = b"\xcf\xfa\xed\xfe fake signed arm64 macprovider-cli\n"

FAKE_CODESIGN = """#!/bin/sh
[ "$1" = -d ] && [ "$2" = --arch ] && [ "$4" = -vvv ] || { echo "unexpected codesign argv: $*" >&2; exit 2; }
cat "$FAKE_CODESIGN_OUTPUT" >&2
exit "${FAKE_CODESIGN_STATUS:-0}"
"""
FAKE_LIPO = """#!/bin/sh
[ "$1" = -archs ] || { echo "unexpected lipo argv: $*" >&2; exit 2; }
printf '%s\\n' "$FAKE_LIPO_ARCHS"
"""


def codesign_output(identifier: str = "live.malibu.provider.cli", team: str = TEAM, cdhash: str = CDHASH) -> str:
    return "\n".join(
        [
            "Executable=/tmp/macprovider-cli",
            f"Identifier={identifier}",
            "Format=Mach-O thin (arm64)",
            "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+2 location=embedded",
            f"CandidateCDHash sha256={cdhash}",
            f"CDHash={cdhash}",
            "Authority=Developer ID Application: Example (ABCDE12345)",
            f"TeamIdentifier={team}",
            "Runtime Version=15.5.0",
            "",
        ]
    )


class ProviderCodeIdentityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("codesign", FAKE_CODESIGN), ("lipo", FAKE_LIPO)):
            path = self.bin / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o755)
        self.codesign_output = self.root / "codesign.out"
        self.codesign_output.write_text(codesign_output(), encoding="utf-8")
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "FAKE_CODESIGN_OUTPUT": str(self.codesign_output),
            "FAKE_LIPO_ARCHS": "arm64",
        }
        self.env.pop("APPLE_NOTARY_TEAM_ID", None)
        self.tarball = self.root / ASSET
        self.make_tarball({"macprovider-cli": BINARY, "mlx.metallib": b"metal"})

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_tarball(self, members: dict[str, bytes], path: pathlib.Path | None = None, symlink: bool = False) -> None:
        path = path or self.tarball
        path.unlink(missing_ok=True)
        with tarfile.open(path, "w:gz") as archive:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                if symlink and name == "macprovider-cli":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "mlx.metallib"
                    archive.addfile(info)
                    continue
                info.size = len(data)
                info.mode = 0o755
                archive.addfile(info, io.BytesIO(data))

    def run_script(self, *arguments: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            env=env or self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def derive(self, *extra: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        return self.run_script(
            "--tarball", str(self.tarball), "--binary-version", "1.8.214", "--expected-team-id", TEAM, *extra, env=env
        )

    def assert_rejected(self, result: subprocess.CompletedProcess, message: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_derives_exact_identity_from_shipped_tarball(self) -> None:
        result = self.derive("--expect-sha256", hashlib.sha256(BINARY).hexdigest())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "asset": ASSET,
                "member": "macprovider-cli",
                "binary_version": "1.8.214",
                "binary_sha256": hashlib.sha256(BINARY).hexdigest(),
                "team_id": TEAM,
                "signing_identifier": "live.malibu.provider.cli",
                "slices": [{"arch": "arm64", "code_cdhash": CDHASH}],
            },
        )
        self.assertEqual(result.stdout, json.dumps(json.loads(result.stdout), sort_keys=True, separators=(",", ":")) + "\n")

    def test_expected_team_falls_back_to_notary_team_environment(self) -> None:
        env = {**self.env, "APPLE_NOTARY_TEAM_ID": TEAM}
        result = self.run_script("--tarball", str(self.tarball), "--binary-version", "1.8.214", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / "identity.json"
        result = self.run_script(
            "--tarball", str(self.tarball), "--binary-version", "1.8.214", "--output", str(output), env=env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text())["team_id"], TEAM)

    def test_missing_or_malformed_expected_team_fails_closed(self) -> None:
        result = self.run_script("--tarball", str(self.tarball), "--binary-version", "1.8.214")
        self.assert_rejected(result, "expected Team ID")
        result = self.run_script(
            "--tarball", str(self.tarball), "--binary-version", "1.8.214", "--expected-team-id", "abcde12345"
        )
        self.assert_rejected(result, "expected Team ID")

    def test_rejects_non_arm64_slice_sets(self) -> None:
        for arches in ("x86_64 arm64", "x86_64", "arm64e", ""):
            with self.subTest(arches=arches):
                result = self.derive(env={**self.env, "FAKE_LIPO_ARCHS": arches})
                self.assert_rejected(result, "not exact arm64")

    def test_rejects_wrong_signing_identifier(self) -> None:
        self.codesign_output.write_text(codesign_output(identifier="live.malibu.provider.cli.debug"), encoding="utf-8")
        self.assert_rejected(self.derive(), "Identifier is not live.malibu.provider.cli")

    def test_rejects_wrong_team(self) -> None:
        self.codesign_output.write_text(codesign_output(team="ZZZZZ99999"), encoding="utf-8")
        result = self.derive()
        self.assert_rejected(result, "TeamIdentifier does not match")
        self.assertNotIn("ZZZZZ99999", result.stderr)

    def test_rejects_unsigned_team(self) -> None:
        self.codesign_output.write_text(codesign_output(team="not set"), encoding="utf-8")
        self.assert_rejected(self.derive(), "TeamIdentifier does not match")

    def test_rejects_malformed_cdhash(self) -> None:
        for cdhash in (CDHASH.upper(), CDHASH[:-1], CDHASH + "0", "g" * 40):
            with self.subTest(cdhash=cdhash):
                self.codesign_output.write_text(codesign_output(cdhash=cdhash), encoding="utf-8")
                self.assert_rejected(self.derive(), "CDHash is not 40 lowercase hex")

    def test_rejects_duplicate_or_missing_codesign_fields(self) -> None:
        self.codesign_output.write_text(codesign_output() + f"CDHash={CDHASH}\n", encoding="utf-8")
        self.assert_rejected(self.derive(), "exactly one CDHash= line")
        self.codesign_output.write_text(
            "\n".join(line for line in codesign_output().splitlines() if not line.startswith("TeamIdentifier=")),
            encoding="utf-8",
        )
        self.assert_rejected(self.derive(), "exactly one TeamIdentifier= line")

    def test_codesign_failure_fails_closed(self) -> None:
        self.assert_rejected(self.derive(env={**self.env, "FAKE_CODESIGN_STATUS": "1"}), "codesign -d --arch arm64 failed")

    def test_rejects_sha256_mismatch(self) -> None:
        self.assert_rejected(self.derive("--expect-sha256", "0" * 64), "differs from --expect-sha256")

    def test_rejects_missing_duplicate_or_linked_member(self) -> None:
        self.make_tarball({"mlx.metallib": b"metal"})
        self.assert_rejected(self.derive(), "exactly one macprovider-cli member")
        self.make_tarball({"macprovider-cli": BINARY, "./macprovider-cli": BINARY})
        self.assert_rejected(self.derive(), "exactly one macprovider-cli member")
        self.make_tarball({"mlx.metallib": b"metal", "macprovider-cli": b""}, symlink=True)
        self.assert_rejected(self.derive(), "regular non-empty file")

    def test_rejects_unexpected_asset_name_and_version(self) -> None:
        renamed = self.root / "phase3-binary-m4-v1.8.214.tar.gz"
        self.make_tarball({"macprovider-cli": BINARY}, path=renamed)
        result = self.run_script(
            "--tarball", str(renamed), "--binary-version", "1.8.214", "--expected-team-id", TEAM
        )
        self.assert_rejected(result, "--tarball name must be")
        result = self.run_script("--tarball", str(self.tarball), "--binary-version", "v1.8.214", "--expected-team-id", TEAM)
        self.assert_rejected(result, "--binary-version must be X.Y.Z")


class EmitApprovedIdentityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.private_key = self.root / "private.pem"
        self.public_key = self.root / "public.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(self.private_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(self.private_key), "-pubout", "-out", str(self.public_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.metadata = self.root / "pearl-release.json"
        self.identity = {
            "asset": ASSET,
            "member": "macprovider-cli",
            "binary_version": "1.8.214",
            "binary_sha256": hashlib.sha256(BINARY).hexdigest(),
            "team_id": TEAM,
            "signing_identifier": "live.malibu.provider.cli",
            "slices": [{"arch": "arm64", "code_cdhash": CDHASH}],
        }
        self.write_metadata()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_metadata(self, **overrides: object) -> None:
        value = {
            "schema_version": 1,
            "release_lane": "pearl_runtime_catalog",
            "tag": TAG,
            "release_version": "1.8.214",
            "provider_advertised_version": "1.8.214",
            "provider_code_identity": self.identity,
        }
        value.update(overrides)
        self.metadata.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.private_key), "-out", str(self.metadata) + ".sig", str(self.metadata)],
            check=True,
        )

    def emit(self, expires_at: str = "2099-01-01T00:00:00Z") -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--emit-approved-identity",
                "--pearl-release-json",
                str(self.metadata),
                "--public-key",
                str(self.public_key),
                "--expires-at",
                expires_at,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_emits_yaml_entry_from_verified_metadata(self) -> None:
        result = self.emit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            f"# provider_code_identity from signed pearl-release.json {TAG} ({ASSET})\n"
            f"- team_id: {TEAM}\n"
            "  signing_identifier: live.malibu.provider.cli\n"
            f"  code_cdhash: {CDHASH}\n"
            '  binary_version: "1.8.214"\n'
            '  expires_at: "2099-01-01T00:00:00Z"\n',
        )
        self.assertNotIn("PRIVATE", result.stdout + result.stderr)

    def test_rejects_tampered_metadata(self) -> None:
        with self.metadata.open("a", encoding="utf-8") as handle:
            handle.write(" ")
        result = self.emit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature verification failed", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_rejects_metadata_without_or_with_invalid_identity(self) -> None:
        cases = {
            "does not carry provider_code_identity": None,
            "code_cdhash must be 40 lowercase hex": {**self.identity, "slices": [{"arch": "arm64", "code_cdhash": CDHASH.upper()}]},
            "signing_identifier is not live.malibu.provider.cli": {**self.identity, "signing_identifier": "other"},
            "asset does not match the release tag": {**self.identity, "asset": "macprovider-cli-v1.8.213-darwin-arm64.tar.gz"},
            "binary_version does not match": {**self.identity, "binary_version": "1.8.213"},
            "fields differ": {**self.identity, "extra": True},
        }
        for message, identity in cases.items():
            with self.subTest(message=message):
                if identity is None:
                    value = json.loads(self.metadata.read_text())
                    value.pop("provider_code_identity")
                    self.metadata.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
                    subprocess.run(
                        ["openssl", "dgst", "-sha256", "-sign", str(self.private_key), "-out", str(self.metadata) + ".sig", str(self.metadata)],
                        check=True,
                    )
                else:
                    self.write_metadata(provider_code_identity=identity)
                result = self.emit()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_rejects_past_or_malformed_expiry(self) -> None:
        for expires_at, message in (
            ("2000-01-01T00:00:00Z", "must be in the future"),
            ("2099-01-01", "RFC3339"),
            ("2099-13-01T00:00:00Z", "RFC3339"),
        ):
            with self.subTest(expires_at=expires_at):
                result = self.emit(expires_at)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)



def load_producer():
    import importlib.util

    spec = importlib.util.spec_from_file_location("provider_code_identity_under_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SharedContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.producer = load_producer()
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_identity_required_cutoff_is_after_1_8_213(self) -> None:
        for version in ("1.8.213", "1.8.48", "1.7.999", "0.0.1"):
            with self.subTest(version=version):
                self.assertFalse(self.producer.identity_required(version))
        for version in ("1.8.214", "1.8.1000", "1.9.0", "2.0.0", "v1.8.214", "1.8", "", None, "1.8.213-rc1"):
            with self.subTest(version=version):
                self.assertTrue(self.producer.identity_required(version))

    def make_tarball(self, data: bytes) -> pathlib.Path:
        path = self.root / ASSET
        with tarfile.open(path, "w:gz") as archive:
            info = tarfile.TarInfo("macprovider-cli")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        return path

    def test_member_sha256_streams_and_writes_exact_bytes(self) -> None:
        data = os.urandom(3 * self.producer.CHUNK_BYTES + 17)
        tarball = self.make_tarball(data)
        destination = self.root / "out"
        self.assertEqual(self.producer.member_sha256(tarball, "macprovider-cli", destination), hashlib.sha256(data).hexdigest())
        self.assertEqual(destination.read_bytes(), data)
        self.assertEqual(self.producer.member_sha256(tarball), hashlib.sha256(data).hexdigest())

    def test_member_size_cap_is_enforced(self) -> None:
        tarball = self.make_tarball(b"x" * 4096)
        self.producer.MAX_MEMBER_BYTES = 1024
        with self.assertRaises(self.producer.IdentityError):
            self.producer.member_sha256(tarball)


if __name__ == "__main__":
    unittest.main()
