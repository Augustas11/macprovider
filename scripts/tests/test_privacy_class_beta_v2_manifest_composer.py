from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
for entry in (str(SCRIPTS), str(SCRIPTS / "tests")):
    if entry not in sys.path:
        sys.path.insert(0, entry)

import privacy_class_beta_journey_evidence as contract  # noqa: E402

SCRIPT = SCRIPTS / "lab" / "privacy-class-beta" / "capture-v2-sources.py"
EXTRACTOR = SCRIPTS / "lab" / "privacy-class-beta" / "extract-primary-evidence.py"
SOURCE_BUNDLE = REPO_ROOT / "journeys/evidence/privacy-class-beta-20261006T043016Z"


def load_capture_module():
    spec = importlib.util.spec_from_file_location("privacy_v2_capture_under_test", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError("unable to load capture-v2-sources.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def fp(label: str) -> str:
    return b64url(hashlib.sha256(label.encode()).digest())


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")


def snapshot(captured: int, rows: dict[str, list[dict]] | None = None) -> dict:
    rows = rows or {}
    tables = {}
    for table in contract.V2_DB_TABLES:
        table_rows = rows.get(table, [])
        tables[table] = {
            "table": table,
            "columns": list(contract.V2_DB_COLUMNS[table]),
            "dropped_columns": [],
            "row_count": len(table_rows),
            "truncated": False,
            "rows": table_rows,
        }
    return {"captured_at_unix": captured, "tables": tables}


def key(provider: str, accepted: int, *, revoked: int | None = None) -> dict:
    return {
        "provider_id": provider,
        "kid": "kid-" + provider,
        "assigned_session": "session-" + provider,
        "key_record_digest": fp("key-" + provider),
        "not_before_unix": accepted - 5,
        "expires_at_unix": accepted + 1000,
        "accepted_at_unix": accepted,
        "revoked_at_unix": revoked,
        "revocation_retained_until_unix": None,
        "key_class": "privacy",
    }


def enrollment(provider: str, identity: str, se: str, enrolled: int, *, revoked: int | None = None) -> dict:
    return {
        "provider_id": provider,
        "identity_fingerprint": identity,
        "se_fingerprint": se,
        "team_id": "TEAMID1234",
        "signing_identifier": "live.malibu.provider.cli",
        "code_cdhash": "a" * 40,
        "binary_version": "1.8.215",
        "enrolled_at_unix": enrolled,
        "revoked_at_unix": revoked,
        "revoked_reason": "operator_reenroll" if revoked else None,
    }


def client_attempts(captured: int, attempts: list[dict]) -> dict:
    return {"captured_at_unix": captured, "attempts": attempts}


def success(case: str, provider: str, posture: int) -> dict:
    return {
        "case": case,
        "status": 200,
        "provider_id": provider,
        "response_excerpt": {"usage_macprovider_privacy": {"posture_verified_at_unix": posture}},
    }


def failure(case: str, provider: str | None, code: str) -> dict:
    return {"case": case, "status": 409, "provider_id": provider, "response_excerpt": {"error": {"code": code}}}


class ComposerFixture:
    def __init__(self) -> None:
        scratch = REPO_ROOT / "scratchpad" / "privacy-v2-composer-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        scratch.chmod(0o700)
        self.tmp = tempfile.TemporaryDirectory(dir=scratch)
        self.base = Path(self.tmp.name)
        self.root = self.base / "capture"
        self.root.mkdir(mode=0o700)
        self.module = load_capture_module()
        self.binding = (SOURCE_BUNDLE / "step-01-bind-signed-release/binding.txt").read_text()
        self.binding_path = self.base / "binding.txt"
        self.binding_path.write_text(self.binding)
        self.binding_values = contract.Checks(contract.Bundle("x", {"step-01-bind-signed-release/binding.txt": self.binding.encode()}, b"")).binding()
        self.private_key = self.base / "release.key"
        self.public_key = self.base / "release-public.pem"
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(self.private_key)], check=True, capture_output=True)
        subprocess.run(["openssl", "ec", "-in", str(self.private_key), "-pubout", "-out", str(self.public_key)], check=True, capture_output=True)
        self.trusted_hash = hashlib.sha256(self.public_key.read_bytes()).hexdigest()
        self.populate()

    def cleanup(self) -> None:
        self.tmp.cleanup()

    def raw_path(self, manifest: str, kind: str) -> Path:
        return self.root / contract.V2_SOURCE_CONTRACT[manifest][kind]

    def put(self, manifest: str, kind: str, value, *, raw: bytes | None = None) -> None:
        path = self.raw_path(manifest, kind)
        path.parent.mkdir(parents=True, exist_ok=True)
        if raw is None:
            write_json(path, value)
        else:
            path.write_bytes(raw)

    def sign(self, path: Path) -> bytes:
        sig = path.with_suffix(path.suffix + ".sig.tmp")
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.private_key), "-out", str(sig), str(path)], check=True, capture_output=True)
        data = sig.read_bytes()
        sig.unlink()
        return data

    def release_doc(self, valid: bool = True) -> dict:
        if not valid:
            return {"not_provider_code_identity": True}
        identity = self.binding_values
        return {
            "provider_code_identity": {
                "asset": f"macprovider-cli-v{identity['binary_version']}-darwin-arm64.tar.gz",
                "member": "macprovider-cli",
                "binary_version": identity["binary_version"],
                "binary_sha256": identity["binary_sha256"],
                "team_id": identity["team_id"],
                "signing_identifier": identity["signing_identifier"],
                "slices": [{"arch": "arm64", "code_cdhash": identity["code_cdhash"]}],
            }
        }

    def populate(self) -> None:
        bv = self.binding_values
        cases = {
            "automatic-eligible": (None, None, "privacy", ["privacy_class"], "p-auto-ok", []),
            "automatic-ineligible": (None, None, "ordinary", [], "p-auto-ineligible", ["missing_secure_enclave"]),
            "automatic-hardening-fallback": (None, None, "ordinary", [], "p-auto-hardening", ["configuration_changed"]),
            "explicit-optout": (False, None, "ordinary", [], "p-optout", []),
            "explicit-relay-blind": (None, True, "plain_relay_blind", [], "p-relay", []),
        }
        self.put("auto-mode.json", "auto_launch", {"cases": [{"name": name, "executable_sha256": bv["binary_sha256"], "arguments": {"privacy_class_beta": requested, "relay_blind_enabled": relay}, "started_at_unix": 110 + index} for index, (name, (requested, relay, *_)) in enumerate(sorted(cases.items()))]})
        self.put("auto-mode.json", "auto_config", {"cases": [{"name": name, "privacy_class_requested": requested, "relay_blind_requested": relay} for name, (requested, relay, *_rest) in sorted(cases.items())]})
        self.put("auto-mode.json", "auto_sessions", {"cases": [{"name": name, "provider_id": provider, "accepted_at_unix": 130 + index, "claims": claims, "effective_mode": mode} for index, (name, (_requested, _relay, mode, claims, provider, _reasons)) in enumerate(sorted(cases.items()))]})
        logs = []
        for name, (*_unused, reasons) in cases.items():
            if reasons:
                tag = "hardening_failed" if "hardening" in name else "ineligible"
                logs.append({"name": name, "stream": "stderr", "line": f"privacy_class auto_{tag} reasons={','.join(reasons)}"})
        self.put("auto-mode.json", "auto_logs", {"lines": logs})
        self.put("auto-mode.json", "auto_db_before", snapshot(100))
        self.put("auto-mode.json", "auto_db_after", snapshot(200, {"relay_blind_key_records": [key("p-auto-ok", 120)]}))

        e1, e2 = enrollment("p-enroll-1", fp("identity-1"), fp("se-1"), 310), enrollment("p-enroll-2", fp("identity-2"), fp("se-2"), 320)
        self.put("enrollment.json", "enrollment_before", snapshot(300))
        self.put("enrollment.json", "enrollment_after_first", snapshot(310, {"privacy_class_enrollment": [e1], "relay_blind_key_records": [key("p-enroll-1", 305)]}))
        self.put("enrollment.json", "enrollment_after_second", snapshot(320, {"privacy_class_enrollment": [e1, e2], "relay_blind_key_records": [key("p-enroll-1", 305), key("p-enroll-2", 315)]}))
        self.put("enrollment.json", "enrollment_after_reuse", snapshot(330, {"privacy_class_enrollment": [e1, e2], "relay_blind_key_records": [key("p-enroll-1", 305), key("p-enroll-2", 315)], "privacy_class_quarantine": [{"provider_id": "p-reuse", "reason": "privacy_enrollment_key_in_use", "quarantined_at_unix": 330, "expires_at_unix": 430}]}))
        self.put("enrollment.json", "enrollment_after_failed_posture", snapshot(340, {"privacy_class_enrollment": [e1, e2], "relay_blind_key_records": [key("p-enroll-1", 305), key("p-enroll-2", 315)], "privacy_class_quarantine": [{"provider_id": "p-reuse", "reason": "privacy_enrollment_key_in_use", "quarantined_at_unix": 330, "expires_at_unix": 430}]}))
        self.put("enrollment.json", "enrollment_clients", client_attempts(350, [success("first-admission", "p-enroll-1", 311), success("second-admission", "p-enroll-2", 321), failure("cross-provider-reuse", "p-reuse", "privacy_enrollment_key_in_use"), failure("failed-posture", "p-failed", "privacy_posture_failed")]))

        old = enrollment("p-reenroll", fp("old-identity"), fp("old-se"), 400)
        new = enrollment("p-reenroll", fp("new-identity"), fp("new-se"), 530)
        revoked_old = dict(old, revoked_at_unix=500, revoked_reason="operator_reenroll")
        self.put("reenroll.json", "reenroll_initial", snapshot(400, {"privacy_class_enrollment": [old], "relay_blind_key_records": [key("p-reenroll", 390)]}))
        self.put("reenroll.json", "reenroll_key_change", snapshot(450, {"privacy_class_enrollment": [old], "relay_blind_key_records": [key("p-reenroll", 390, revoked=445)], "privacy_class_quarantine": [{"provider_id": "p-reenroll", "reason": "privacy_enrollment_key_changed", "quarantined_at_unix": 445, "expires_at_unix": 460}]}))
        self.put("reenroll.json", "reenroll_expiry_retry", snapshot(470, {"privacy_class_enrollment": [old], "relay_blind_key_records": [key("p-reenroll", 390, revoked=445)], "privacy_class_quarantine": [{"provider_id": "p-reenroll", "reason": "privacy_enrollment_key_changed", "quarantined_at_unix": 465, "expires_at_unix": 500}]}))
        self.put("reenroll.json", "reenroll_operator_clear", snapshot(500, {"privacy_class_enrollment": [revoked_old], "relay_blind_key_records": [key("p-reenroll", 390, revoked=445)], "privacy_class_operator_clear": [{"provider_id": "p-reenroll", "cleared_at_unix": 500, "clear_generation": 1}], "relay_blind_reservations": [{"provider_id": "p-reenroll", "assigned_session": "s", "key_record_digest": "d", "kid": "k", "model": "m", "expires_at_unix": 499, "state": "rejected", "created_at_unix": 490, "privacy_class": 1, "terminal_code": "relay_blind_key_expired", "terminal_at_unix": 500}]}))
        self.put("reenroll.json", "reenroll_after", snapshot(540, {"privacy_class_enrollment": [revoked_old, new], "relay_blind_key_records": [key("p-reenroll", 530)]}))
        self.put("reenroll.json", "reenroll_clients", client_attempts(550, [success("post-reenroll-admission", "p-reenroll", 535)]))

        release = self.root / contract.V2_SOURCE_CONTRACT["release-derived-approval.json"]["release_metadata"]
        invalid = self.root / contract.V2_SOURCE_CONTRACT["release-derived-approval.json"]["release_invalid_metadata"]
        write_json(release, self.release_doc(True))
        write_json(invalid, self.release_doc(False))
        self.put("release-derived-approval.json", "release_signature", None, raw=self.sign(release))
        self.put("release-derived-approval.json", "release_invalid_signature", None, raw=self.sign(invalid))
        self.put("release-derived-approval.json", "release_public_key", None, raw=self.public_key.read_bytes())
        approved = {"team_id": bv["team_id"], "signing_identifier": bv["signing_identifier"], "code_cdhash": bv["code_cdhash"], "binary_version": bv["binary_version"]}
        self.put("release-derived-approval.json", "release_file_stats", {"metadata": {"regular": True, "symlink": False, "bytes": release.stat().st_size}, "signature": {"regular": True, "symlink": False, "bytes": len(self.raw_path("release-derived-approval.json", "release_signature").read_bytes())}, "public_key": {"regular": True, "symlink": False, "bytes": self.public_key.stat().st_size}})
        self.put("release-derived-approval.json", "release_eligibility", {"approved": {"approved_code_identities": [approved], "denied_cdhashes": [], "metadata_directory_present": True, "provider_id": "p-release", "client_status": 200, "client_response_excerpt": {"usage_macprovider_privacy": {"posture_verified_at_unix": 610}}}, "denied": {"approved_code_identities": [approved], "denied_cdhashes": [bv["code_cdhash"]], "metadata_directory_present": True, "provider_id": "p-release", "client_status": 409, "client_response_excerpt": {"error": {"code": "posture_denied_code_identity"}}}, "withdrawn": {"approved_code_identities": [], "denied_cdhashes": [], "metadata_directory_present": False, "provider_id": "p-release", "client_status": 409, "client_response_excerpt": {"error": {"code": "privacy_release_identity_absent"}}}, "invalid_metadata": {"approved_code_identities": [], "denied_cdhashes": [], "metadata_directory_present": True, "provider_id": "p-release", "client_status": 409, "client_response_excerpt": {"error": {"code": "privacy_release_identity_absent"}}}})
        self.put("release-derived-approval.json", "release_approved_db", snapshot(600))
        self.put("release-derived-approval.json", "release_denied_db", snapshot(650, {"privacy_class_quarantine": [{"provider_id": "p-release", "reason": "posture_denied_code_identity", "quarantined_at_unix": 650, "expires_at_unix": 750}], "relay_blind_key_records": [key("p-release", 600, revoked=650)]}))
        self.put("release-derived-approval.json", "release_withdrawn_db", snapshot(700))

        public, _ = contract.ed25519_sign(bytes(range(32)), b"")
        entries = []
        for label, revoked in (("dir-active", False), ("dir-revoked", True)):
            identity_key = hashlib.sha256(label.encode()).digest()
            entries.append({"identity_public_key": b64url(identity_key), "fingerprint": b64url(hashlib.sha256(identity_key).digest()), "se_public_key_fingerprint": fp(label + "-se"), "source": "enrolled", "enrolled_at_unix": 800, "revoked": revoked})
        entries.sort(key=lambda row: row["fingerprint"])
        payload = json.dumps({"version": "privacy-identity-directory-v1", "privacy_class": contract.PRIVACY_CLASS, "issued_at_unix": 800, "expires_at_unix": 1000, "entries": entries}, sort_keys=True, separators=(",", ":")).encode()
        signature = contract.ed25519_sign(bytes(range(32)), contract._frame(b"macprovider/spec049/identity-directory/v1") + contract._frame(payload))[1]
        envelope = {"version": "privacy-identity-directory-envelope-v1", "key_id": b64url(hashlib.sha256(public).digest()), "payload": b64url(payload), "signature": b64url(signature)}
        self.put("directory.json", "directory_envelope", envelope)
        self.put("directory.json", "directory_gateway_body", envelope)
        self.put("directory.json", "directory_public_key", {"algorithm": "ed25519", "public_key": b64url(public)})
        self.put("directory.json", "directory_gateway_headers", {"status": 200, "cache_control": "no-store", "content_type": "application/json", "captured_at_unix": 900, "store_error_code": "privacy_class_unavailable"})
        self.put("directory.json", "directory_clients", {"captured_at_unix": 1000, "attempts": [{"case": name, "accepted": False, "error_code": "privacy_directory_rejected"} for name in ("tampered", "expired", "revoked", "wrong_key")]})
        self.put("directory.json", "directory_store", {"enrollments": [{"provider_id": "p-dir-r" if row["revoked"] else "p-dir-a", "identity_fingerprint": row["fingerprint"], "se_fingerprint": row["se_public_key_fingerprint"], "enrolled_at_unix": row["enrolled_at_unix"], "revoked_at_unix": 850 if row["revoked"] else None} for row in entries], "quarantined_provider_ids": []})
        self.put("directory.json", "directory_disclosure", {"residual_risks": list(contract.PRIVACY_RESIDUAL_RISKS_V2)})

        for manifest, sources in contract.V2_SOURCE_CONTRACT.items():
            for kind, relative in sources.items():
                path = self.root / relative
                data = path.read_bytes()
                write_json(self.root / "capture-v2-inventory" / f"{kind}.json", {"schema_version": "macprovider.privacy-class-beta-v2-capture-source.v1", "kind": kind, "path": relative, "source_name": path.name, "output_path": relative, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "captured_at_unix": 1})
        for path in self.root.rglob("*"):
            if path.is_dir():
                path.chmod(0o700)

    def finalize(self) -> None:
        self.module.finalize(types.SimpleNamespace(out_root=str(self.root)))

    def compose(self) -> None:
        original = self.module.V2RawSourceView
        trusted = self.trusted_hash
        self.module.V2RawSourceView = lambda source_bytes, binding: contract.V2RawSourceView(source_bytes, binding, trusted)
        try:
            self.module.compose_source_manifests(types.SimpleNamespace(out_root=str(self.root), binding=str(self.binding_path)))
        finally:
            self.module.V2RawSourceView = original

    def extract(self) -> Path:
        needles = self.base / "needles.tsv"
        needles.write_text("prompt_canary\tNEEDLE-DO-NOT-EXPORT\n")
        out = self.base / "extract"
        completed = subprocess.run([sys.executable, str(EXTRACTOR), "--raw", str(self.root), "--out", str(out), "--needles", str(needles), "--home-prefix", ""], capture_output=True, text=True)
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        return out / "primary"


class V2ManifestComposerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = ComposerFixture()

    def tearDown(self) -> None:
        self.fx.cleanup()

    def test_roundtrip_finalized_raw_to_extractor_to_all_v2_predicates(self) -> None:
        self.fx.finalize()
        self.fx.compose()
        primary = self.fx.extract()
        files = {"step-01-bind-signed-release/binding.txt": self.fx.binding.encode()}
        for path in primary.rglob("*"):
            if path.is_file():
                files["primary/" + path.relative_to(primary).as_posix()] = path.read_bytes()
        bundle = contract.Bundle("synthetic", files, b"")
        checks = contract.Checks(bundle, contract.PROFILE_V2, trusted_release_public_key_sha256=self.fx.trusted_hash)
        predicates = ["v2_auto_mode", "v2_enrollment", "v2_key_change_reenroll", "v2_release_approval", "v2_directory"]
        self.assertEqual({name: [] for name in predicates}, {name: checks.run(name) for name in predicates})
        self.assertEqual(set(contract.V2_SOURCE_CONTRACT), {path.name for path in (self.fx.root / "evidence" / "v2-source").iterdir()})

    def test_compose_requires_finalized_and_current_inventory_before_writing(self) -> None:
        with self.assertRaisesRegex(self.module_error(), "FINALIZED"):
            self.fx.compose()
        self.assertFalse((self.fx.root / "evidence" / "v2-source").exists())
        self.fx.finalize()
        self.fx.raw_path("auto-mode.json", "auto_logs").write_text('{"lines":[]}\n')
        with self.assertRaisesRegex(self.module_error(), "drifted|stale"):
            self.fx.compose()
        self.assertFalse((self.fx.root / "evidence" / "v2-source").exists())

    def test_compose_rejects_bad_binding_and_existing_outputs_without_partial_write(self) -> None:
        self.fx.finalize()
        self.fx.binding_path.write_text(self.fx.binding.replace(self.fx.binding_values["binary_sha256"], "0" * 64))
        with self.assertRaisesRegex(self.module_error(), "tested executable bytes"):
            self.fx.compose()
        self.assertFalse((self.fx.root / "evidence" / "v2-source").exists())
        self.fx.binding_path.write_text(self.fx.binding)
        self.fx.compose()
        with self.assertRaisesRegex(self.module_error(), "refusing to overwrite"):
            self.fx.compose()

    def test_compose_rejects_raw_drift_between_finalized_check_and_read_without_output(self) -> None:
        self.fx.finalize()
        original_require = self.fx.module.require_finalized_current

        def mutate_after_finalized_check(out_root: Path):
            rows = original_require(out_root)
            path = self.fx.raw_path("enrollment.json", "enrollment_clients")
            path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            return rows

        self.fx.module.require_finalized_current = mutate_after_finalized_check
        try:
            with self.assertRaisesRegex(self.module_error(), "finalized source drifted before compose"):
                self.fx.compose()
        finally:
            self.fx.module.require_finalized_current = original_require
        self.assertFalse((self.fx.root / "evidence" / "v2-source").exists())

    def test_compose_preflights_later_existing_manifest_without_partial_write(self) -> None:
        self.fx.finalize()
        source_root = self.fx.root / "evidence" / "v2-source"
        source_root.mkdir(mode=0o700)
        preexisting = source_root / "release-derived-approval.json"
        preexisting.write_text("preexisting\n", encoding="utf-8")
        with self.assertRaisesRegex(self.module_error(), "refusing to overwrite"):
            self.fx.compose()
        self.assertEqual(["release-derived-approval.json"], sorted(path.name for path in source_root.iterdir()))
        self.assertEqual("preexisting\n", preexisting.read_text(encoding="utf-8"))

    def test_compose_rejects_v2_mutations(self) -> None:
        cases = [
            ("lack_configuration_changed", lambda: self.fx.raw_path("auto-mode.json", "auto_logs").write_text('{"lines":[]}\n'), "configuration_changed"),
            ("tamper_signed_metadata", lambda: self.fx.raw_path("release-derived-approval.json", "release_metadata").write_text(json.dumps(self.fx.release_doc(True)).replace(self.fx.binding_values["binary_sha256"], "0" * 64) + "\n"), "tested binary bytes"),
            ("directory_body", lambda: self.fx.raw_path("directory.json", "directory_gateway_body").write_text('{"not":"the envelope"}\n'), "byte-identical"),
        ]
        for name, mutate, message in cases:
            with self.subTest(name=name):
                self.tearDown()
                self.setUp()
                mutate()
                for manifest, sources in contract.V2_SOURCE_CONTRACT.items():
                    for kind, relative in sources.items():
                        path = self.fx.root / relative
                        inventory = self.fx.root / "capture-v2-inventory" / f"{kind}.json"
                        doc = json.loads(inventory.read_text())
                        doc["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                        doc["bytes"] = path.stat().st_size
                        write_json(inventory, doc)
                self.fx.finalize()
                with self.assertRaisesRegex(self.module_error(), message):
                    self.fx.compose()
                self.assertFalse((self.fx.root / "evidence" / "v2-source").exists())

    def test_cli_has_no_trusted_release_key_override_and_requires_binding(self) -> None:
        completed = subprocess.run([sys.executable, str(SCRIPT), "--out-root", str(self.fx.root), "--compose-source-manifests"], capture_output=True, text=True)
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--binding is required", completed.stderr)
        completed = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(0, completed.returncode)
        self.assertNotIn("trusted-release", completed.stdout)

    @staticmethod
    def module_error():
        return RuntimeError


if __name__ == "__main__":
    unittest.main()
