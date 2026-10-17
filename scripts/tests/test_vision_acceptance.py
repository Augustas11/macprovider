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
    def test_absent_facade_rejects_media_but_missing_chat_route_fails(self):
        error = {"error": {"code": "invalid_request", "message": "not found"}}
        for path in ("/v1/responses", "/v1/messages"):
            with self.subTest(path=path):
                vision.check_rejection(path, 404, error)
                vision.check_rejection(path, 400, error)
                with self.assertRaises(vision.AcceptanceError):
                    vision.check_rejection(path, 404, "not found")
                with self.assertRaises(vision.AcceptanceError):
                    vision.check_rejection(path, 503, error)
        with self.assertRaises(vision.AcceptanceError):
            vision.check_rejection("/v1/chat/completions", 404, error)
        for status in (400, 413, 415, 422):
            vision.check_rejection("/v1/chat/completions", status, error)

    def test_unknown_model_accepts_only_structured_model_not_found(self):
        missing = {"error": {"code": "model_not_found", "message": "Model not found"}}
        vision.check_rejection("/v1/chat/completions", 404, missing, kind="unknown_model")
        for status, data in ((400, {"error": {"code": "unsupported_media"}}), (404, {"error": {"code": "invalid_request"}}),
                             (200, missing), (400, missing)):
            with self.subTest(status=status, data=data), self.assertRaises(vision.AcceptanceError):
                vision.check_rejection("/v1/chat/completions", status, data, kind="unknown_model")
        with self.assertRaises(vision.AcceptanceError):
            vision.check_rejection("/v1/chat/completions", 404, missing)

    def test_text_only_model_must_reject_media_not_the_model_name(self):
        for status in (400, 413, 415, 422):
            vision.check_rejection("/v1/chat/completions", status, {"error": {"code": "unsupported_media"}},
                                   kind="text_only_media")
        for status, data in ((404, {"error": {"code": "model_not_found"}}), (404, {"error": {"code": "invalid_request"}}),
                             (400, {"error": {"code": "model_not_found"}}), (500, {"error": {"code": "internal"}}),
                             (200, {"error": {"code": "unsupported_media"}}), (400, "unsupported")):
            with self.subTest(status=status, data=data), self.assertRaises(vision.AcceptanceError):
                vision.check_rejection("/v1/chat/completions", status, data, kind="text_only_media")
        # The gateway's text-only case uses the strict media rules: never a 404.
        with self.assertRaises(vision.AcceptanceError):
            vision.check_rejection("/v1/chat/completions", 404, {"error": {"code": "model_not_found"}})

    def test_suites_send_the_right_model_names(self):
        red = vision.image(vision.circle_png((255, 0, 0)))["image_url"]["url"]
        blue = vision.image(vision.circle_png((0, 0, 255)))["image_url"]["url"]
        sent = []

        def fake_post(origin, path, payload, token, stream=False, disconnect=False):
            model = payload.get("model")
            sent.append((model, payload))
            if disconnect:
                return 200, {"disconnected_after_content": True}
            if model == vision.UNLOADED_MODEL:
                return 404, {"error": {"code": "model_not_found"}}
            if model == "text-only":
                return 400, {"error": {"code": "unsupported_media"}}
            content = (next(m for m in payload["messages"] if m["role"] == "user")["content"]
                       if path == "/v1/chat/completions" else None)
            if isinstance(content, str):
                return 200, {"choices": [{"message": {"content": "hello"}}]}
            urls = [p["image_url"]["url"] for p in content or [] if p.get("type") == "image_url"]
            if urls and len(urls) <= 2 and set(urls) <= {red, blue}:
                return 200, {"choices": [{"message": {"content": " ".join(
                    "red" if u == red else "blue" for u in urls)}}]}
            return 400, {"error": {"code": "invalid_request"}}

        with patch.object(vision, "post", side_effect=fake_post):
            local = [r["case"] for r in vision.run_suite("http://127.0.0.1:18016", None, "text-only")]
            local_models = {m for m, _ in sent}
            sent.clear()
            gateway = [r["case"] for r in vision.run_suite("http://127.0.0.1:18018", None, "text-only", gateway=True)]
            gateway_models = {m for m, _ in sent}
        self.assertIn("unloaded_model_name", local)
        self.assertNotIn("unsupported_model_mixed", local)
        self.assertEqual(local_models, {vision.MODEL, vision.UNLOADED_MODEL})
        self.assertIn("unsupported_model_mixed", gateway)
        self.assertNotIn("unloaded_model_name", gateway)
        self.assertEqual(gateway_models, {vision.MODEL, "text-only"})

    def test_text_only_provider_needs_its_own_port_and_a_text_only_model(self):
        base = ["vision-acceptance.py", "--provider-url", "http://127.0.0.1:18016", "--expected-host-name", "h",
                "--candidate-pid", "1", "--candidate-binary", "b", "--candidate-sha256", "0" * 64,
                "--source-commit", "0" * 40, "--text-only-pid", "2", "--output", "/nonexistent/out.json"]
        for extra in (["--text-only-provider-url", "http://127.0.0.1:18016", "--unsupported-model", "text-only"],
                      ["--text-only-provider-url", "http://127.0.0.1:8080", "--unsupported-model", "text-only"],
                      ["--text-only-provider-url", "http://127.0.0.1:18019", "--unsupported-model", vision.MODEL],
                      ["--text-only-provider-url", "http://127.0.0.1:18019",
                       "--unsupported-model", vision.UNLOADED_MODEL]):
            with self.subTest(extra=extra), patch.object(vision.sys, "argv", base + extra), \
                    patch.object(vision, "verify_host") as host, patch("sys.stderr"):
                self.assertEqual(vision.main(), 2)
                host.assert_not_called()

    def test_text_only_suite_records_cases(self):
        def fake_post(origin, path, payload, token, stream=False, disconnect=False):
            if isinstance(payload["messages"][0]["content"], list):
                return 415, {"error": {"code": "unsupported_media"}}
            return 200, {"choices": [{"message": {"content": "hello"}}]}

        with patch.object(vision, "post", side_effect=fake_post):
            results = vision.run_text_only_suite("http://127.0.0.1:18019", None, "text-only")
        self.assertEqual([r["case"] for r in results],
                         ["text_only_provider_mixed", "text_only_provider_image_only", "text_only_provider_text"])

        def by_name(origin, path, payload, token, stream=False, disconnect=False):
            return 404, {"error": {"code": "model_not_found"}}

        with patch.object(vision, "post", side_effect=by_name), self.assertRaises(vision.AcceptanceError):
            vision.run_text_only_suite("http://127.0.0.1:18019", None, "text-only")

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

    def test_circle_fixture_is_in_limits_and_small(self):
        red, blue = (vision.circle_png(c) for c in ((255, 0, 0), (0, 0, 255)))
        for data, color in ((red, (255, 0, 0)), (blue, (0, 0, 255))):
            self.assertEqual(struct.unpack(">II", data[16:24]), (224, 224))
            self.assertLess(len(data), 1024 * 1024)
            pixels = zlib.decompress(data[data.index(b"IDAT") + 4:data.index(b"IEND") - 8])
            row = 1 + 224 * 3
            at = lambda x, y: pixels[y * row + 1 + x * 3:y * row + 4 + x * 3]
            self.assertEqual(at(112, 112), bytes(color))
            self.assertEqual(at(0, 0), b"\xff\xff\xff")
            self.assertEqual(at(112, 112 + 81), b"\xff\xff\xff")
        self.assertLessEqual(2 * 224 * 224, 4194304)
        body = json.dumps(vision.request([vision.image(red), vision.image(blue)]))
        self.assertLess(len(body), 1024 * 1024 // 4)

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
