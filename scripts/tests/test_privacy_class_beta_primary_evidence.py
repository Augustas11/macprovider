from __future__ import annotations

import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
for entry in (str(SCRIPTS), str(SCRIPTS / "tests")):
    if entry not in sys.path:
        sys.path.insert(0, entry)

import privacy_class_beta_journey_evidence as contract  # noqa: E402
import privacy_primary_fixture as fixture  # noqa: E402

EXTRACTOR = SCRIPTS / "lab" / "privacy-class-beta" / "extract-primary-evidence.py"
SOURCE = "journeys/evidence/privacy-class-beta-20261006T043016Z.redacted.json"
BUNDLE = "journeys/evidence/privacy-class-beta-20261006T043016Z"
PRIMARY_PREDICATES = sorted(
    {name for names in contract.STEP_PREDICATES.values() for name in names if name.startswith("primary_")}
)


def remanifest(bundle_dir: Path) -> None:
    rows = []
    for path in sorted(bundle_dir.rglob("*"), key=lambda item: ("./" + item.relative_to(bundle_dir).as_posix()).encode()):
        relative = path.relative_to(bundle_dir).as_posix()
        if path.is_file() and relative != contract.MANIFEST_NAME:
            import hashlib

            rows.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  ./{relative}\n")
    (bundle_dir / contract.MANIFEST_NAME).write_text("".join(rows), encoding="utf-8")


def run_extractor(raw: Path, out: Path, facts: dict, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(EXTRACTOR), "--raw", str(raw), "--out", str(out), "--needles", str(facts["needles_path"]), "--kit-script", str(facts["kit"]), *extra],
        capture_output=True,
        text=True,
    )


class Fixture:
    """A temp repo root holding a copy of the reviewed bundle plus synthetic primary exports."""

    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root = base / "repo"
        for relative in ("specs/CONFORMANCE.json", contract.JOURNEY_PATH, SOURCE):
            (self.root / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_ROOT / relative, self.root / relative)
        # Synthetic primary exports replace the committed real ones.
        shutil.copytree(REPO_ROOT / BUNDLE, self.root / BUNDLE, ignore=shutil.ignore_patterns("primary"))
        self.bundle = self.root / BUNDLE
        fixture.rewrite_identity(self.bundle)
        self.raw = base / "run2-raw"
        self.facts = fixture.build_raw(self.raw, self.bundle)
        self.out = base / "extract"
        completed = run_extractor(self.raw, self.out, self.facts)
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        shutil.copytree(self.out / "primary", self.bundle / "primary")
        remanifest(self.bundle)

    def cleanup(self) -> None:
        self.tmp.cleanup()

    def load(self) -> contract.Bundle:
        return contract.load_bundle(self.root, BUNDLE)

    def errors(self, name: str) -> list[str]:
        return contract.Checks(self.load()).run(name)

    def edit_json(self, relative: str, edit) -> None:
        path = self.bundle / "primary" / relative
        doc = json.loads(path.read_text())
        edit(doc)
        path.write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n")
        remanifest(self.bundle)


class ExtractorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fx = Fixture()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fx.cleanup()

    def test_writes_the_expected_exports(self) -> None:
        primary = self.fx.out / "primary"
        for relative in (
            "summary.json",
            "db/inventory.json",
            "db/request-id-crossref.json",
            "db/relay-blind.db/relay_blind_reservations.json",
            "db/relay-blind.db/relay_blind_key_records.json",
            "db/coordinator.db/settlement_route_snapshots.json",
            "db/coordinator.db/settlement_receipt_verdicts.json",
            "db/coordinator.db/spec022_payable_request_credits.json",
            "db/coordinator.db/provider_rewards.json",
            "db/gateway.db/quota_reservations.json",
            "db/gateway.db/usage_events.json",
            "db/provider_connection_events.db/provider_connection_events.json",
            "logs/coordinator-events.json",
            "logs/proxy-events.json",
            "logs/provider-plain-lines.json",
            "logs/unified-provider-96156.json",
            "procedure/dyld.json",
            "sweep/salted-needle-digests.json",
            "sweep/raw-files.json",
        ):
            self.assertTrue((primary / relative).is_file(), relative)
        summary = json.loads((primary / "summary.json").read_text())
        self.assertEqual(5, len(summary["not_recoverable"]))

    def test_never_exports_credentials_needles_or_home_paths(self) -> None:
        primary = self.fx.out / "primary"
        quota = json.loads((primary / "db/gateway.db/quota_reservations.json").read_text())
        self.assertIn("api_key_hash", quota["dropped_columns"])
        self.assertFalse(any("api_key_hash" in row for row in quota["rows"]))
        self.assertFalse((primary / "db/coordinator.db/provider_tokens.json").exists())
        reservations = json.loads((primary / "db/relay-blind.db/relay_blind_reservations.json").read_text())
        self.assertTrue(all(set(row["buyer_binding"]) == {"sha256"} for row in reservations["rows"]))
        blob = "\n".join(path.read_text() for path in primary.rglob("*.json"))
        self.assertNotIn("/Users/", blob)
        self.assertNotIn("\\/Users\\/", blob)
        self.assertIn("<lab-home>/journey-1839/provider/privacy/config.yaml", blob)
        for needle in self.fx.facts["needles"].values():
            self.assertNotIn(needle, blob)
        outputs = json.loads((primary / "db/coordinator.db/settlement_attempt_outputs.json").read_text())
        self.assertTrue(all(row["settlement_output_canonical_json"] == "" for row in outputs["rows"]))
        logged = json.loads((primary / "logs/coordinator-events.json").read_text())["events"]
        self.assertFalse(any("unrelated routine line" in str(event) for event in logged))
        self.assertTrue(all(event["time_utc"].endswith("Z") for event in logged))

    def test_opens_databases_read_only(self) -> None:
        before = {path.name: path.read_bytes() for path in (self.fx.raw / "db").iterdir()}
        out = Path(self.fx.tmp.name) / "again"
        self.assertEqual(0, run_extractor(self.fx.raw, out, self.fx.facts).returncode)
        self.assertEqual(before, {path.name: path.read_bytes() for path in (self.fx.raw / "db").iterdir()})

    def test_refuses_and_removes_output_when_a_needle_would_be_exported(self) -> None:
        needle = self.fx.facts["needles"]["prompt_canary"]
        log = self.fx.raw / "logs" / "coordinator.log"
        original = log.read_text()
        try:
            log.write_text(original + json.dumps({"time": "2026-10-05T21:31:00-07:00", "provider_id": "journey-1839-privacy", "message": "privacy posture: response rejected " + needle}) + "\n")
            out = Path(self.fx.tmp.name) / "refused"
            completed = run_extractor(self.fx.raw, out, self.fx.facts)
            self.assertNotEqual(0, completed.returncode)
            self.assertIn("needle present", completed.stderr)
            self.assertFalse(out.exists())
        finally:
            log.write_text(original)

    def test_does_not_follow_symlinked_raw_inputs(self) -> None:
        outside = Path(self.fx.tmp.name) / "outside.db"
        with sqlite3.connect(outside) as db:
            db.execute("CREATE TABLE relay_blind_reservations (privacy_class INTEGER, request_id TEXT, internal_request_id TEXT)")
            db.execute("INSERT INTO relay_blind_reservations VALUES (1, 'outside-secret-id', 'outside-secret-id')")
        db.close()
        link = self.fx.raw / "db" / "linked.db"
        link.symlink_to(outside)
        try:
            out = Path(self.fx.tmp.name) / "symlinked"
            completed = run_extractor(self.fx.raw, out, self.fx.facts)
            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertIn("symlink refused", completed.stderr)
            blob = "\n".join(path.read_text() for path in out.rglob("*.json"))
            self.assertNotIn("outside-secret-id", blob)
        finally:
            link.unlink()

    def test_refuses_an_existing_output_directory(self) -> None:
        self.assertNotEqual(0, run_extractor(self.fx.raw, self.fx.out, self.fx.facts).returncode)


class PrimaryPredicateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = Fixture()

    def tearDown(self) -> None:
        self.fx.cleanup()

    def test_every_primary_predicate_holds_on_consistent_exports(self) -> None:
        checks = contract.Checks(self.fx.load())
        self.assertEqual({name: [] for name in PRIMARY_PREDICATES}, {name: checks.run(name) for name in PRIMARY_PREDICATES})

    def test_attestation_signature_and_binding_are_verified(self) -> None:
        def tamper(doc):
            row = next(row for row in doc["rows"] if row["key_class"] == "privacy")
            row["privacy_attestation_json"]["code_cdhash"] = "0" * 40

        self.fx.edit_json("db/relay-blind.db/relay_blind_key_records.json", tamper)
        errors = self.fx.errors("primary_key_attestation")
        self.assertTrue(any("signature must verify" in error for error in errors), errors)
        self.assertTrue(any("release code identity" in error for error in errors), errors)

    def test_receipt_checks_recompute_from_rows(self) -> None:
        def duplicate(doc):
            doc["rows"].append(dict(doc["rows"][0], id=999))

        self.fx.edit_json("db/coordinator.db/settlement_receipt_verdicts.json", duplicate)
        self.assertTrue(self.fx.errors("primary_receipts"))

    def test_receipt_output_must_be_content_free_and_digest_bound(self) -> None:
        def content(doc):
            doc["rows"][0]["settlement_output_canonical_json"] = {"omitted_sha256": "0" * 64, "bytes": 10}

        self.fx.edit_json("db/coordinator.db/settlement_attempt_outputs.json", content)
        self.assertTrue(self.fx.errors("primary_receipts"))

    def test_snapshot_digest_and_order_are_recomputed(self) -> None:
        request = self.fx.facts["enforce"][0]["internal_request_id"]

        def late(doc):
            row = next(row for row in doc["rows"] if row["request_id"] == request)
            row["route_decision_ts_unix_ms"] += 60_000

        self.fx.edit_json("db/coordinator.db/settlement_route_snapshots.json", late)
        self.assertTrue(any("must precede the signed receipt" in error for error in self.fx.errors("primary_enforce")))

    def test_snapshot_canonical_digest_mismatch_fails(self) -> None:
        def mutate(doc):
            doc["rows"][0]["route_snapshot_canonical_json"] += " "

        self.fx.edit_json("db/coordinator.db/settlement_route_snapshots.json", mutate)
        self.assertTrue(any("canonical JSON" in error for error in self.fx.errors("primary_receipts")))

    def test_buyer_debit_must_equal_credit(self) -> None:
        request = self.fx.facts["enforce"][0]["internal_request_id"]

        def mutate(doc):
            next(row for row in doc["rows"] if row["request_id"] == "gw-" + request)["prompt_tokens"] += 1

        self.fx.edit_json("db/gateway.db/usage_events.json", mutate)
        self.assertTrue(any("debit must equal" in error for error in self.fx.errors("primary_enforce")))

    def test_reward_or_verified_rows_during_enforce_fail(self) -> None:
        start = fixture.results(self.fx.bundle)["step-12-kill-switch"]

        def reward(doc):
            doc["rows"].append({"id": 1, "provider_id": "journey-1839-privacy", "amount": 1, "created_at_utc": fixture.utc_text(start + 20)})

        self.fx.edit_json("db/coordinator.db/provider_rewards.json", reward)
        self.assertTrue(self.fx.errors("primary_counters"))

    def test_held_request_must_be_refunded(self) -> None:
        digest = self.fx.facts["held"]["envelope_digest"]

        def debit(doc):
            next(row for row in doc["rows"] if row["relay_blind_envelope_digest"] == digest)["status"] = "settled"
            next(row for row in doc["rows"] if row["relay_blind_envelope_digest"] == digest)["settled_tokens"] = 5

        self.fx.edit_json("db/gateway.db/quota_reservations.json", debit)
        self.assertTrue(any("no buyer quota may be charged" in error for error in self.fx.errors("primary_kill_switch_refund")))

    def test_quarantined_case_with_payable_credit_fails(self) -> None:
        request = self.fx.facts["cases"]["fault-tamper-field"]["internal_request_id"]

        def credit(doc):
            doc["rows"].append({"id": 99, "request_id": request, "provider_id": "journey-1839-plain", "prompt_tokens": 1, "completion_tokens": 1, "provider_credits": 1, "settlement_policy_mode": "enforce"})
            doc["row_count"] += 1

        def count(doc):
            doc["databases"]["coordinator.db"]["spec022_payable_request_credits"] += 1

        self.fx.edit_json("db/coordinator.db/spec022_payable_request_credits.json", credit)
        self.fx.edit_json("db/inventory.json", count)
        self.assertTrue(any("no payable credit" in error for error in self.fx.errors("primary_receipt_quarantine")))

    def test_fault_build_must_target_the_loopback_coordinator(self) -> None:
        def remote(doc):
            doc["lines"].append({"line": 99, "text": "  coordinator_url: wss://coordinator.invalid/ws/provider"})

        self.fx.edit_json("logs/provider-plain-lines.json", remote)
        self.assertTrue(self.fx.errors("primary_fault_isolation"))

    def test_posture_rejection_fails(self) -> None:
        def rejected(doc):
            doc["events"].append({"line": 99, "provider_id": "journey-1839-privacy", "message": "privacy posture: response rejected", "time_utc": "2026-10-06T04:31:00.000000Z"})

        self.fx.edit_json("logs/coordinator-events.json", rejected)
        self.assertTrue(self.fx.errors("primary_posture"))

    def test_needle_in_a_committed_file_fails_the_salted_recheck(self) -> None:
        needle = self.fx.facts["needles"]["completion_canary"]
        path = self.fx.bundle / "step-07-canary-stream" / "canary-stream.meta"
        path.write_text(path.read_text() + needle + "\n")
        remanifest(self.fx.bundle)
        self.assertTrue(any("contains a swept needle" in error for error in self.fx.errors("primary_canary_recheck")))

    def test_dyld_procedure_must_set_both_variables(self) -> None:
        def strip(doc):
            for line in doc["kit_script"]["dyld_lines"]:
                line["text"] = line["text"].replace("DYLD_PRINT_LIBRARIES=1", "")

        self.fx.edit_json("procedure/dyld.json", strip)
        self.assertTrue(self.fx.errors("primary_dyld_procedure"))

    def test_raw_sweep_hits_fail_integrity(self) -> None:
        def hit(doc):
            doc["files"][0]["needle_matches"] = 1
            doc["total_needle_matches"] = 1

        self.fx.edit_json("sweep/raw-files.json", hit)
        self.assertTrue(self.fx.errors("primary_integrity"))

    def test_row_exports_must_match_the_inventory(self) -> None:
        def drop(doc):
            doc["rows"].pop()
            doc["row_count"] -= 1

        self.fx.edit_json("db/coordinator.db/settlement_receipt_verdicts.json", drop)
        self.assertTrue(any("every row the inventory counts" in error for error in self.fx.errors("primary_receipts")))

    def test_salted_digests_must_cover_every_class(self) -> None:
        def drop(doc):
            doc["digests"] = [item for item in doc["digests"] if item["class"] != "completion_canary"]

        self.fx.edit_json("sweep/salted-needle-digests.json", drop)
        self.assertTrue(self.fx.errors("primary_integrity"))

    def test_forged_key_record_fails(self) -> None:
        def tamper(doc):
            row = next(row for row in doc["rows"] if row["key_class"] == "privacy")
            row["record_json"]["models"] = ["other-model"]

        self.fx.edit_json("db/relay-blind.db/relay_blind_key_records.json", tamper)
        errors = self.fx.errors("primary_key_attestation")
        self.assertTrue(any("key record signature" in error for error in errors), errors)

    def test_fault_case_served_by_an_unaccepted_session_fails(self) -> None:
        def other(doc):
            for row in doc["rows"]:
                if row.get("provider_session_id") == "sess-fault":
                    row["provider_session_id"] = "sess-elsewhere"

        self.fx.edit_json("db/coordinator.db/settlement_route_snapshots.json", other)
        self.assertTrue(self.fx.errors("primary_fault_isolation"))

    def test_bare_hostnames_fail_redaction(self) -> None:
        for text in (b"peer=collector.example.xyz\n", b"service.example.co ok\n", b"coordinator.malibu.tech\n"):
            with self.assertRaises(contract.PrivacyEvidenceError):
                contract.assert_bundle_redacted(contract.Bundle("x", {"a.txt": text}, b""))
        contract.assert_bundle_redacted(contract.Bundle("x", {"a.txt": b"live.malibu.provider.cli results.tsv com.apple.network\n"}, b""))

    def test_missing_route_decision_time_fails(self) -> None:
        request = self.fx.facts["enforce"][0]["internal_request_id"]

        def drop(doc):
            next(row for row in doc["rows"] if row["request_id"] == request)["route_decision_ts_unix_ms"] = None

        self.fx.edit_json("db/coordinator.db/settlement_route_snapshots.json", drop)
        self.assertTrue(any("must precede the signed receipt" in error for error in self.fx.errors("primary_enforce")))

    def test_key_record_structure_is_enforced(self) -> None:
        def blank(doc):
            row = next(row for row in doc["rows"] if row["key_class"] == "privacy")
            row["record_json"]["kid"] = "short"

        self.fx.edit_json("db/relay-blind.db/relay_blind_key_records.json", blank)
        self.assertTrue(any("kid" in error for error in self.fx.errors("primary_key_attestation")))

    def test_private_temp_paths_and_single_letter_hosts_fail_redaction(self) -> None:
        for text in (b"root /var/folders/ab/xyz/T/\n", b"peer=node.a\n"):
            with self.assertRaises(contract.PrivacyEvidenceError):
                contract.assert_bundle_redacted(contract.Bundle("x", {"a.txt": text}, b""))
        contract.assert_bundle_redacted(contract.Bundle("x", {"a.txt": b"tcp_input flags=[S.E] v1.8.215 3.2\n"}, b""))

    def test_missing_primary_exports_fail_closed(self) -> None:
        shutil.rmtree(self.fx.bundle / "primary" / "db")
        remanifest(self.fx.bundle)
        checks = contract.Checks(self.fx.load())
        for name in ("primary_receipts", "primary_enforce", "primary_key_attestation", "primary_integrity"):
            self.assertTrue(checks.run(name), name)

    def test_network_flow_identifiers_are_not_ip_literals(self) -> None:
        bundle = contract.Bundle("x", {"a.txt": b"[C1.1.1.1 IPv4#289b0c85:443 initial path]\n"}, b"")
        contract.assert_bundle_redacted(bundle)
        with self.assertRaises(contract.PrivacyEvidenceError):
            contract.assert_bundle_redacted(contract.Bundle("x", {"a.txt": b"peer 1.1.1.1:443\n"}, b""))

    def test_first_network_flow_before_process_start_fails(self) -> None:
        def early(doc):
            doc["network_events"][0]["time_utc"] = "2026-10-06T04:00:00.000000Z"

        self.fx.edit_json("logs/unified-provider-96156.json", early)
        self.assertTrue(any("first network flow" in error for error in self.fx.errors("primary_first_connect")))

    def test_missing_not_recoverable_record_fails(self) -> None:
        self.fx.edit_json("summary.json", lambda doc: doc["not_recoverable"].pop())
        self.assertTrue(self.fx.errors("primary_integrity"))

    def test_composed_evidence_validates_with_primary_exports(self) -> None:
        evidence = contract.compose_evidence(self.fx.root, BUNDLE)
        (self.fx.root / SOURCE).write_text(json.dumps(evidence, indent=2) + "\n")
        contract.validate_evidence(self.fx.root, SOURCE, evidence)
        self.assertTrue(all(evidence["observations"][name] for name in contract.TRUE_OBSERVATIONS))


if __name__ == "__main__":
    unittest.main()
