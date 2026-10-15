"""Pure harness guards/fixture checks: no network, model, GPU, or host probes."""

import importlib.util
import json
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import zlib


SPEC = importlib.util.spec_from_file_location(
    "vision_acceptance", Path(__file__).resolve().parents[1] / "vision-acceptance.py")
vision = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vision)


class VisionAcceptanceTests(unittest.TestCase):
    def test_endpoint_guard_refuses_live_redirectable_and_operator_targets(self):
        for value in ("https://api.malibu.tech", "http://localhost:18016",
                      "http://127.0.0.1:8080", "http://127.0.0.1",
                      "http://127.0.0.1:18016/path", "http://user@127.0.0.1:18016",
                      "http://127.0.0.1:18016?target=live", "http://192.168.1.1:18016"):
            with self.subTest(value=value), self.assertRaises(vision.AcceptanceError):
                vision.endpoint(value)
        self.assertEqual(vision.endpoint("http://127.0.0.1:18016"), ("127.0.0.1", 18016))
        self.assertEqual(vision.endpoint("http://[::1]:18016"), ("::1", 18016))

    @patch.object(vision.platform, "system", return_value="Darwin")
    def test_host_guard_rejects_operator_even_when_asserted_as_designated(self, _):
        with patch.object(vision, "command", side_effect=["Augustas-Air.local", "Mac17,3"]):
            with self.assertRaises(vision.AcceptanceError):
                vision.verify_host("Augustas-Air.local")

    @patch.object(vision.platform, "system", return_value="Darwin")
    def test_host_guard_requires_both_expected_host_and_studio_family(self, _):
        data = json.dumps({"SPHardwareDataType": [{"machine_name": "Mac mini"}]})
        with patch.object(vision, "command", side_effect=["test-host", "Mac14,12", data]):
            with self.assertRaises(vision.AcceptanceError):
                vision.verify_host("test-host")
        data = json.dumps({"SPHardwareDataType": [{"machine_name": "Mac Studio", "serial_number": "private"}]})
        with patch.object(vision, "command", side_effect=["test-host", "Mac15,14", data]):
            self.assertEqual(vision.verify_host("test-host"), {"designated_studio_verified": True})
        with patch.object(vision, "command", side_effect=["other-host", "Mac15,14"]):
            with self.assertRaises(vision.AcceptanceError):
                vision.verify_host("test-host")

    def test_fixture_pixels_and_chunk_checksums_are_real(self):
        for color in ((255, 0, 0), (0, 0, 255)):
            data = vision.png(color, 2, 2)
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            offset, pixels = 8, None
            while offset < len(data):
                length = struct.unpack(">I", data[offset:offset + 4])[0]
                kind = data[offset + 4:offset + 8]
                body = data[offset + 8:offset + 8 + length]
                checksum = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
                self.assertEqual(checksum, zlib.crc32(kind + body))
                if kind == b"IDAT":
                    pixels = zlib.decompress(body)
                offset += length + 12
            self.assertEqual(pixels, (b"\0" + bytes(color) * 2) * 2)

    def test_joined_candidate_requires_exact_literal_loopback_and_isolated_credentials(self):
        argv = ["candidate", "serve", "--isolate-lifecycle", "--credential-store", "protected_file",
                "--coordinator", "ws://127.0.0.1:18017/ws"]
        vision.verify_isolation(argv, "ws://127.0.0.1:18017/ws")
        for url in ("wss://coordinator.malibu.tech/ws", "ws://127.0.0.1:8080/ws",
                    "ws://localhost:18017/ws", "ws://127.0.0.1:18018/ws"):
            with self.subTest(url=url), self.assertRaises(vision.AcceptanceError):
                vision.verify_isolation(argv, url)
        with self.assertRaises(vision.AcceptanceError):
            vision.verify_isolation(argv + ["--no-join"], "ws://127.0.0.1:18017/ws")
        vision.verify_isolation(["candidate", "serve", "--no-join", "--autotune-candidate"], None)

    def test_color_assertions_reject_generic_or_reversed_answers(self):
        for content in ("a colored image", "blue red", "red blue red"):
            with self.assertRaises(vision.AcceptanceError):
                vision.check_labels(content, ["red", "blue"])
        vision.check_labels("red, blue", ["red", "blue"])


if __name__ == "__main__":
    unittest.main()
