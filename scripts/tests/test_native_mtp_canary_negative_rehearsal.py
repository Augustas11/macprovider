import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path

from scripts.native_mtp_canary_negative_rehearsal import (
    CANARY_RESULT_TYPE,
    NativeMTPCanaryFaultRelay,
    RelayConfig,
    encode_frame,
    mutate_canary_result,
    read_frame,
    validate_config,
    native_mtp_canary_result_digest,
)


def canary_object(**extra):
    payload = {
        "type": CANARY_RESULT_TYPE,
        "version": 1,
        "request_id": "canary-1",
        "provider_id": "provider-a",
        "assigned_id": "assigned-a",
        "request_digest": "6" * 64,
        "target_generation": 7,
        "provider_revision": "1.8.123",
        "runtime_revision": "mlx-swift-lm-e874140",
        "challenge_id": "challenge-a",
        "challenge_bank_sha256": "4" * 64,
        "nonce": "0123456789abcdef0123456789abcdef",
        "native_mtp_runtime_tuple_sha256": "919d2f171e70f1cca3bc93b88cb4234f13fe4cda883ad69b976a4169a3a3bc24",
        "expected_token_id_sha256": "5" * 64,
        "actual_token_id_sha256": "5" * 64,
        "terminal_reason": "passed",
        "counters": {"accepted": 2, "rejected": 1, "bonus": 0, "committed": 3},
        "committed_state_sha256": "2" * 64,
        "actual_decode_path": "native_mtp",
        "fallback_used": False,
        "runtime_tuple": {
            "model_id": "model-a",
            "model_hash": "a" * 64,
            "model_hash_algorithm": "macprovider.snapshot-manifest.v1",
            "provider_revision": "1.8.123",
            "runtime_revision": "mlx-swift-lm-e874140",
            "tokenizer_digest": "b" * 64,
            "artifact_digest": "c" * 64,
            "manifest_digest": "d" * 64,
            "sidecar_digest": "e" * 64,
            "provider_binary_sha256": "f" * 64,
            "runtime_cdhash": "1" * 64,
            "cache_namespace": "cache-a",
            "state_digest": "2" * 64,
            "proposal_depth": 2,
        },
    }
    payload["result_digest"] = native_mtp_canary_result_digest(payload)
    payload.update(extra)
    return payload


def canary_payload(**extra):
    return json.dumps(canary_object(**extra), separators=(",", ":")).encode()


class NativeMTPCanaryFaultRelayUnitTests(unittest.TestCase):
    def test_wrong_digest_mutates_actual_token_digest_and_recomputes_result_digest(self):
        mutated, matched = mutate_canary_result(canary_payload(), "wrong_digest")
        self.assertTrue(matched)
        obj = json.loads(mutated)
        self.assertEqual(obj["actual_token_id_sha256"], "0" * 64)
        self.assertEqual(obj["actual_decode_path"], "native_mtp")
        self.assertEqual(obj["result_digest"], native_mtp_canary_result_digest(obj))

        malformed, matched = mutate_canary_result(canary_payload(), "malformed_digest")
        self.assertTrue(matched)
        mobj = json.loads(malformed)
        self.assertNotEqual(mobj["result_digest"], native_mtp_canary_result_digest(mobj))

        unchanged, matched = mutate_canary_result(b'{"type":"heartbeat","token":"redacted"}', "wrong_digest")
        self.assertFalse(matched)
        self.assertEqual(unchanged, b'{"type":"heartbeat","token":"redacted"}')

    def test_actual_path_fallback_drop_and_delay_semantics(self):
        actual, matched = mutate_canary_result(canary_payload(), "actual_path")
        self.assertTrue(matched)
        aobj = json.loads(actual)
        self.assertEqual(aobj["actual_decode_path"], "ordinary")
        self.assertEqual(aobj["result_digest"], native_mtp_canary_result_digest(aobj))

        fallback, matched = mutate_canary_result(canary_payload(), "fallback")
        self.assertTrue(matched)
        fobj = json.loads(fallback)
        self.assertEqual(fobj["actual_decode_path"], "ordinary")
        self.assertTrue(fobj["fallback_used"])
        self.assertEqual(fobj["result_digest"], native_mtp_canary_result_digest(fobj))

        dropped, matched = mutate_canary_result(canary_payload(), "drop")
        self.assertTrue(matched)
        self.assertIsNone(dropped)

        delayed, matched = mutate_canary_result(canary_payload(), "delay")
        self.assertTrue(matched)
        dobj = json.loads(delayed)
        self.assertEqual(dobj["result_digest"], native_mtp_canary_result_digest(dobj))

    def test_config_refuses_live_or_non_lab_endpoints(self):
        validate_config(RelayConfig(
            listen_host="127.0.0.1",
            listen_port=19370,
            upstream_url="ws://127.0.0.1:19371/ws/provider",
            fault="wrong_digest",
        ))
        bad_configs = [
            RelayConfig("0.0.0.0", 19370, "ws://127.0.0.1:19371/ws/provider", "wrong_digest"),
            RelayConfig("127.0.0.1", 8080, "ws://127.0.0.1:19371/ws/provider", "wrong_digest"),
            RelayConfig("127.0.0.1", 19370, "wss://127.0.0.1:19371/ws/provider", "wrong_digest"),
            RelayConfig("127.0.0.1", 19370, "ws://coordinator.malibu.tech:19371/ws/provider", "wrong_digest"),
            RelayConfig("127.0.0.1", 19370, "ws://127.0.0.1:8080/ws/provider", "wrong_digest"),
        ]
        for cfg in bad_configs:
            with self.subTest(cfg=cfg):
                with self.assertRaises(ValueError):
                    validate_config(cfg)

    def test_frame_round_trip_masks_and_unmasks(self):
        async def run():
            reader = asyncio.StreamReader()
            raw = encode_frame(b'{"hello":"world"}', opcode=1, mask=True)
            reader.feed_data(raw)
            frame = await read_frame(reader, 1024)
            self.assertTrue(frame.masked)
            self.assertEqual(frame.payload, b'{"hello":"world"}')
            unmasked = encode_frame(frame.payload, opcode=1, mask=False)
            reader2 = asyncio.StreamReader()
            reader2.feed_data(unmasked)
            frame2 = await read_frame(reader2, 1024)
            self.assertFalse(frame2.masked)
            self.assertEqual(frame2.payload, frame.payload)
        asyncio.run(run())


class NativeMTPCanaryFaultRelayIntegrationTests(unittest.TestCase):
    def test_loopback_relay_intercepts_only_canary_result_and_sanitizes_status(self):
        async def run():
            upstream_seen = []

            async def upstream(reader, writer):
                await reader.readuntil(b"\r\n\r\n")
                writer.write(
                    b"HTTP/1.1 101 Switching Protocols\r\n"
                    b"Upgrade: websocket\r\n"
                    b"Connection: Upgrade\r\n"
                    b"Sec-WebSocket-Accept: test\r\n\r\n"
                )
                for _ in range(2):
                    frame = await read_frame(reader, 4096)
                    upstream_seen.append(json.loads(frame.payload))
                writer.close()
                await writer.wait_closed()

            upstream_server = await asyncio.start_server(upstream, "127.0.0.1", 19381)
            with tempfile.TemporaryDirectory() as td:
                status_path = Path(td) / "relay-status.json"
                relay = NativeMTPCanaryFaultRelay(RelayConfig(
                    listen_host="127.0.0.1",
                    listen_port=19380,
                    upstream_url="ws://127.0.0.1:19381/ws/provider",
                    fault="wrong_digest",
                    status_path=status_path,
                ))
                relay_task = asyncio.create_task(relay.serve())
                await asyncio.sleep(0.05)
                reader, writer = await asyncio.open_connection("127.0.0.1", 19380)
                writer.write(
                    b"GET /ws/provider HTTP/1.1\r\n"
                    b"Host: 127.0.0.1:19380\r\n"
                    b"Upgrade: websocket\r\n"
                    b"Connection: Upgrade\r\n"
                    b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                    b"Sec-WebSocket-Version: 13\r\n\r\n"
                )
                await writer.drain()
                await reader.readuntil(b"\r\n\r\n")
                writer.write(encode_frame(b'{"type":"heartbeat","authorization":"secret"}', opcode=1, mask=True))
                writer.write(encode_frame(canary_payload(result_digest="b" * 64), opcode=1, mask=True))
                await writer.drain()
                deadline = time.time() + 2
                while len(upstream_seen) < 2 and time.time() < deadline:
                    await asyncio.sleep(0.01)
                writer.close()
                await writer.wait_closed()
                relay_task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await relay_task
                upstream_server.close()
                await upstream_server.wait_closed()
                self.assertEqual(upstream_seen[0]["type"], "heartbeat")
                self.assertEqual(upstream_seen[0]["authorization"], "secret")
                self.assertEqual(upstream_seen[1]["type"], CANARY_RESULT_TYPE)
                self.assertEqual(upstream_seen[1]["actual_token_id_sha256"], "0" * 64)
                self.assertEqual(upstream_seen[1]["result_digest"], native_mtp_canary_result_digest(upstream_seen[1]))
                status = json.loads(status_path.read_text())
                self.assertEqual(status["canary_results_seen"], 1)
                self.assertEqual(status["canary_results_faulted"], 1)
                self.assertNotIn("secret", status_path.read_text())
                self.assertNotIn("heartbeat", status_path.read_text())
        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
