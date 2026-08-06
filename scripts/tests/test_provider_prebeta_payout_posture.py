from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from scripts.check_provider_prebeta_payout_posture import validate


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = (
    ROOT
    / "journeys/evidence/provider-prebeta-payout-posture-m4pro-20260806T073417Z.partial.json"
)


class ProviderPrebetaPayoutPostureTests(unittest.TestCase):
    def test_current_artifact_passes_address_onboarded_gate(self) -> None:
        self.assertEqual(validate(ARTIFACT, "address-onboarded"), [])

    def test_current_artifact_fails_post_cooling_gate(self) -> None:
        errors = validate(ARTIFACT, "post-cooling-address-eligible")
        self.assertTrue(any("cooling window has not cleared" in error for error in errors), errors)

    def test_post_cooling_gate_passes_when_capture_is_after_pending_until(self) -> None:
        payload = json.loads(ARTIFACT.read_text(encoding="utf-8"))
        adjusted = copy.deepcopy(payload)
        adjusted["captured_at"] = "2026-08-07T05:40:00Z"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "post-cooling.json"
            path.write_text(json.dumps(adjusted, indent=2) + "\n", encoding="utf-8")
            self.assertEqual(validate(path, "post-cooling-address-eligible"), [])

    def test_secret_like_values_are_rejected(self) -> None:
        payload = json.loads(ARTIFACT.read_text(encoding="utf-8"))
        adjusted = copy.deepcopy(payload)
        adjusted["provider"]["provider_id_sha256"] = "mp-0123456789abcdef0123456789abcdef"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "leaky.json"
            path.write_text(json.dumps(adjusted, indent=2) + "\n", encoding="utf-8")
            errors = validate(path, "address-onboarded")
            self.assertTrue(any("forbidden secret-like pattern" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
