import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts import prod_failure_signatures as sig

# Synthetic lines in the shapes the gateway (Go slog, text and JSON) and the
# provider (stderr event=... lines) emit. Ids and accounts are made up.
GATEWAY_TEXT = """\
time=2026-01-02T10:00:00.000Z level=WARN msg="streaming coordinator idle timeout" request_id=req-a timeout_ms=10000 deadline_phase=decode_idle
time=2026-01-02T10:00:00.100Z level=INFO msg="chat completion" request_id=req-a account_id=acct-1 model=test/model stream=true wall_ms=95000 status=200 deadline_phase=decode_idle
time=2026-01-02T10:00:00.100Z level=INFO msg="gateway settlement used SPEC-006 § 17.7 fallback usage_events insert (settle_path failure)" request_id=req-a account_id=acct-1 outcome=provider_timeout settle_error="boom"
time=2026-01-02T10:00:20.000Z level=INFO msg="chat completion" request_id=req-b account_id=acct-1 model=test/model stream=true wall_ms=3 status=429 deadline_phase=""
time=2026-01-02T10:00:21.000Z level=INFO msg="chat completion" request_id=req-c account_id=acct-2 model=test/model stream=true wall_ms=3 status=429 deadline_phase=""
time=2026-01-02T10:02:30.000Z level=INFO msg="chat completion" request_id=req-d account_id=acct-1 model=test/model stream=true wall_ms=3 status=429 deadline_phase=""
time=2026-01-02T10:03:00.000Z level=INFO msg="chat completion" request_id=req-e account_id=acct-1 model=test/model stream=true wall_ms=9000 status=200 deadline_phase=""
"""

GATEWAY_JSON = "\n".join(
    json.dumps(o)
    for o in (
        {"time": "2026-01-02T11:00:00Z", "level": "WARN", "msg": "streaming coordinator idle timeout", "request_id": "req-j1", "timeout_ms": 10000, "deadline_phase": "decode_idle"},
        {"time": "2026-01-02T11:00:00Z", "level": "INFO", "msg": "chat completion", "request_id": "req-j1", "account_id": "acct-9", "status": 200, "deadline_phase": "decode_idle"},
        {"time": "2026-01-02T11:00:45Z", "level": "INFO", "msg": "chat completion", "request_id": "req-j2", "account_id": "acct-9", "status": 429, "deadline_phase": ""},
    )
)

GOLOG = """\
2026/01/02 12:00:00 WARN streaming coordinator idle timeout request_id=req-g1 timeout_ms=10000 deadline_phase=decode_idle
2026/01/02 12:00:00 INFO chat completion request_id=req-g1 account_id=acct-5 status=200 deadline_phase=decode_idle
2026/01/02 12:00:59 INFO chat completion request_id=req-g2 account_id=acct-5 status=429 deadline_phase=""
"""

PROVIDER = """\
event=kv_disk_cache action=capture_skipped reason=exceeds_promotion_ceiling decoded=9000000000 required=9100000000 cap=1073741824 knob=staging_max_bytes
event=kv_disk_cache action=capture_skipped reason=max_entry_bytes decoded=10 cap=5 knob=max_entry_bytes
event=conv_cache action=hit key_hash=kh-long cached_prompt_tokens=32169 prompt_tokens=108000 lcp=32169 trim_by=0 conv_cache_entries=0 conv_cache_tokens=0
event=conv_cache action=hit key_hash=kh-short cached_prompt_tokens=30000 prompt_tokens=40000 lcp=30000 trim_by=0 conv_cache_entries=0 conv_cache_tokens=0
event=conv_cache action=hit key_hash=kh-ok cached_prompt_tokens=98000 prompt_tokens=100000 lcp=98000 trim_by=0 conv_cache_entries=2 conv_cache_tokens=198000
event=kv_disk_cache action=capture_skipped reason=exceeds_promotion_ceiling decoded=1 required=overflow cap=1 knob=staging_max_bytes request_id=req-p9
"""


def run(text, **kw):
    return sig.scan([("t", text.splitlines(True))], **kw)["signatures"]


class SignatureTest(unittest.TestCase):
    def test_gateway_text_lines(self):
        s = run(GATEWAY_TEXT)
        # two lines for req-a carry decode_idle; counted once
        self.assertEqual(s["decode_idle_cut"], {"count": 1, "examples": ["req-a"]})
        self.assertEqual(s["provider_timeout"], {"count": 1, "examples": ["req-a"]})
        # req-b: same account 20 s later -> match; req-c: other account; req-d: 150 s later
        self.assertEqual(s["retry_429_after_timeout"], {"count": 1, "examples": ["req-b"]})

    def test_gateway_json_lines(self):
        s = run(GATEWAY_JSON)
        self.assertEqual(s["decode_idle_cut"]["count"], 1)
        self.assertEqual(s["retry_429_after_timeout"], {"count": 1, "examples": ["req-j2"]})

    def test_go_default_log_lines(self):
        s = run(GOLOG)
        self.assertEqual(s["retry_429_after_timeout"], {"count": 1, "examples": ["req-g2"]})
        self.assertEqual(run(GOLOG, window_seconds=30)["retry_429_after_timeout"]["count"], 0)

    def test_provider_cache_signatures(self):
        s = run(PROVIDER)
        self.assertEqual(s["capture_skipped_ceiling"]["count"], 2)
        self.assertEqual(s["capture_skipped_ceiling"]["examples"], ["t:1", "req-p9"])
        self.assertEqual(s["conv_cache_empty_long_hit"], {"count": 1, "examples": ["kh-long"]})
        self.assertEqual(run(PROVIDER, long_prompt_tokens=32768)["conv_cache_empty_long_hit"]["count"], 2)

    def test_clean_logs_have_no_signatures(self):
        clean = "\n".join(GATEWAY_TEXT.splitlines()[-1:] + PROVIDER.splitlines()[4:5])
        result = sig.scan([("t", clean.splitlines())])
        self.assertEqual(result["total"], 0)

    def test_cli_reads_files_and_fails_on_any(self):
        with tempfile.TemporaryDirectory() as tmp:
            gw = Path(tmp) / "gateway.log"
            pv = Path(tmp) / "provider.log"
            gw.write_text(GATEWAY_TEXT)
            pv.write_text(PROVIDER)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = sig.main([str(gw), str(pv), "--fail-on-any"])
            self.assertEqual(code, 1)
            out = json.loads(buf.getvalue())
            self.assertEqual(out["lines_scanned"], len(GATEWAY_TEXT.splitlines()) + len(PROVIDER.splitlines()))
            self.assertEqual(out["signatures"]["capture_skipped_ceiling"]["examples"][0], f"{pv}:1")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sig.main([str(gw)]), 0)


if __name__ == "__main__":
    unittest.main()
