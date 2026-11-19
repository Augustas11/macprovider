"""Offline checks for the parity-grid two-turn cell (--turns 2): messages, records, compare section."""
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1] / "lab" / "parity-grid"


def module(name):
    spec = importlib.util.spec_from_file_location(f"parity_turn2_{name}", HARNESS / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


compare = module("compare")
prompts = module("prompts")
client = module("provider_client")

from scripts.tests import test_parity_grid as grid_tests  # noqa: E402  (fake server, line builders)

MODEL = grid_tests.MODEL
A1 = "The keeper lit the lamp."
TEXT4 = "The keeper lit the"


def t2_ours(cached, ttft=0.5, ctx=200, out=4, rows=1, trial=0, row=0, error=None):
    return {"side": "provider", "kind": "row", "model": MODEL, "ctx_target": ctx, "max_tokens": out,
            "rows": rows, "row": row, "trial": trial, "turn": 2, "ttft_s": ttft,
            "cached_prompt_tokens": cached, "error": error, "assistant1": A1,
            "cell": prompts.cell_key(MODEL, ctx, out, rows)}


def t2_ref(cached, ttft=1.0, ctx=200, out=4, row=0, trial=0):
    return {"side": "reference", "kind": "row", "model": MODEL, "ctx_target": ctx, "max_tokens": out,
            "rows": 1, "row": row, "trial": trial, "turn": 2, "ttft_s": ttft,
            "cached_prompt_tokens": cached, "assistant1": A1}


class MessageShapeTests(unittest.TestCase):
    def test_turn2_messages(self):
        t1 = prompts.build_messages(200, 3)
        t2 = prompts.build_turn2_messages(200, 3, A1)
        self.assertEqual(t2[:1], t1)
        self.assertEqual([m["role"] for m in t2], ["user", "assistant", "user"])
        self.assertEqual(t2[1]["content"], A1)
        self.assertEqual(t2[2]["content"], prompts.FOLLOWUP)
        self.assertLess(len(prompts.FOLLOWUP), 120)  # about 20 tokens

    def test_load_assistant1_reads_turn2_rows_only(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "provider.jsonl")
            with open(path, "w") as f:
                for rec in (t2_ours(5, row=0), {**t2_ours(5, row=1), "assistant1": "second"},
                            {**t2_ours(5, row=0, trial=1), "assistant1": "later trial"},
                            {"kind": "aggregate", "turn": 2},
                            {**t2_ours(5, row=2), "assistant1": None}):
                    f.write(json.dumps(rec) + "\n")
            got = prompts.load_assistant1(path)
        self.assertEqual(got, {(200, 4, 0): A1, (200, 4, 1): "second"})


class ClientTurnTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), grid_tests._FakeServer)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        grid_tests._FakeServer.requests.clear()

    def test_turns_1_records_unchanged(self):
        records, agg = client.run_cell(self.port, "model-x", MODEL, 200, 4, 2, 0, True, "t")
        self.assertEqual(len(records), 2)
        self.assertTrue(all("turn" not in r and "assistant1" not in r for r in records))
        self.assertNotIn("turn", agg)
        self.assertEqual(len(grid_tests._FakeServer.requests), 2)

    def test_turns_2_tags_and_shape(self):
        records, agg = client.run_cell(self.port, "model-x", MODEL, 200, 4, 2, 0, True, "t", turns=2)
        self.assertEqual([(r["turn"], r["row"]) for r in records], [(1, 0), (1, 1), (2, 0), (2, 1)])
        self.assertEqual(agg["turn"], 1)  # the aggregate summarises turn 1 only
        t2 = [r for r in records if r["turn"] == 2]
        for r in t2:
            self.assertEqual(r["assistant1"], "The keeper lit the")
            self.assertIn("cached_prompt_tokens", r)
            self.assertIsNotNone(r["ttft_s"])
        bodies = grid_tests._FakeServer.requests
        self.assertEqual(len(bodies), 4)
        three = [b["messages"] for b in bodies if len(b["messages"]) == 3]
        self.assertEqual(len(three), 2)
        for m in three:
            self.assertEqual([x["role"] for x in m], ["user", "assistant", "user"])
            self.assertEqual(m[1]["content"], "The keeper lit the")
            self.assertEqual(m[2]["content"], prompts.FOLLOWUP)
        # turn 1 went out before any turn 2
        self.assertTrue(all(len(b["messages"]) == 1 for b in bodies[:2]))

    def test_turn2_without_turn1_text_is_an_error_row(self):
        t1 = [{"error": "http 500", "text": ""}]
        recs = client.run_turn2(self.port, "model-x", MODEL, 200, 4, 1, 0, True, "t", t1)
        self.assertEqual(recs[0]["turn"], 2)
        self.assertIn("no output", recs[0]["error"])
        self.assertEqual(grid_tests._FakeServer.requests, [])

    def test_default_sends_no_conversation_header_and_content_only(self):
        records, _ = client.run_cell(self.port, "model-x", MODEL, 200, 4, 2, 0, True, "t", turns=2)
        self.assertTrue(all(r["conversation_key_sent"] is False for r in records))
        self.assertEqual({r["turn2_history"] for r in records if r["turn"] == 2}, {"content"})
        for b in grid_tests._FakeServer.requests:
            for m in b["messages"]:
                self.assertNotIn("reasoning_content", m)


class _ReasoningServer(grid_tests._FakeServer):
    """Streams reasoning deltas then content deltas; records (conversation header, body) per request."""
    seen = []
    lock = threading.Lock()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with type(self).lock:
            type(self).seen.append((self.headers.get(client.CONVERSATION_HEADER), body))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        chunks = [{"reasoning_content": "Plan."}, {"reasoning_content": " Go."}, {"content": "Done."}]
        for delta in chunks:
            self.wfile.write(f"data: {json.dumps({'choices': [{'index': 0, 'delta': delta}]})}\n\n".encode())
        usage = {"prompt_tokens": 244, "completion_tokens": 3, "cached_prompt_tokens": 0}
        self.wfile.write(f"data: {json.dumps({'choices': [], 'usage': usage})}\n\ndata: [DONE]\n\n".encode())


class ConversationHeaderHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _ReasoningServer)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        _ReasoningServer.seen.clear()

    def row_of(self, body):
        return int(body["messages"][0]["content"].split()[1].rstrip("."))

    def test_header_same_id_per_conversation_distinct_across(self):
        for trial in range(2):
            records, _ = client.run_cell(self.port, "model-x", MODEL, 200, 4, 2, trial, True, "t", turns=2,
                                         conversation_header=True)
            self.assertTrue(all(r["conversation_key_sent"] is True for r in records))
            self.assertTrue(all(r["error"] is None for r in records))
        self.assertEqual(len(_ReasoningServer.seen), 8)
        self.assertTrue(all(h for h, _ in _ReasoningServer.seen))
        # The provider drops a key without the `conv:` prefix (validConversationKey).
        self.assertTrue(all(h.startswith("conv:") and len(h) > 5 for h, _ in _ReasoningServer.seen))
        ids = {}
        for i, (h, body) in enumerate(_ReasoningServer.seen):
            ids.setdefault((i // 4, self.row_of(body)), set()).add(h)  # 4 requests per trial
        self.assertEqual(len(ids), 4)
        self.assertTrue(all(len(v) == 1 for v in ids.values()))  # turn 1 and turn 2 share the id
        self.assertEqual(len({next(iter(v)) for v in ids.values()}), 4)  # distinct per (trial, row)

    def test_verbatim_history_carries_reasoning_content(self):
        records, _ = client.run_cell(self.port, "model-x", MODEL, 200, 4, 1, 0, True, "t", turns=2,
                                     turn2_history="verbatim")
        self.assertEqual(records[-1]["turn2_history"], "verbatim")
        t2 = [b for _, b in _ReasoningServer.seen if len(b["messages"]) == 3]
        self.assertEqual(len(t2), 1)
        self.assertEqual(t2[0]["messages"][1],
                         {"role": "assistant", "content": "Done.", "reasoning_content": "Plan. Go."})
        self.assertTrue(all(h is None for h, _ in _ReasoningServer.seen))

    def test_content_history_drops_reasoning(self):
        client.run_cell(self.port, "model-x", MODEL, 200, 4, 1, 0, True, "t", turns=2)
        t2 = [b for _, b in _ReasoningServer.seen if len(b["messages"]) == 3]
        self.assertEqual(t2[0]["messages"][1], {"role": "assistant", "content": "Done."})

    def test_reasoning_only_turn1_still_sends_turn2(self):
        t1 = [{"error": None, "text": "", "reasoning_text": "Plan."}]
        recs = client.run_turn2(self.port, "model-x", MODEL, 200, 4, 1, 0, True, "t", t1)
        self.assertIsNone(recs[0]["error"])
        self.assertEqual(_ReasoningServer.seen[0][1]["messages"][1], {"role": "assistant", "content": ""})


class CompareTurn2Tests(unittest.TestCase):
    def base(self):
        return [grid_tests.ref_line(200, 4, 100.0, i, text=TEXT4) for i in range(3)], \
            grid_tests.our_lines(200, 4, 1, [100.0, 100.0, 100.0], texts={0: TEXT4})

    def test_turns_1_summary_has_no_turn2(self):
        ref, ours = self.base()
        s = compare.evaluate(ref, ours)
        self.assertNotIn("turn2", s)
        self.assertNotIn("Turn 2", compare.markdown(s))

    def test_turn2_rows_do_not_touch_turn1_cells(self):
        ref, ours = self.base()
        plain = compare.evaluate(ref, ours)
        both = compare.evaluate(ref + [t2_ref(None)], ours + [t2_ours(180)])
        self.assertEqual(plain["cells"], both["cells"])
        self.assertTrue(both["pass"], both["failing"])

    def test_report_ratio_and_cached(self):
        ref, ours = self.base()
        s = compare.evaluate(ref + [t2_ref(150, ttft=1.0), t2_ref(150, ttft=1.0, trial=1)],
                             ours + [t2_ours(180, ttft=0.25), t2_ours(190, ttft=0.25, trial=1)])
        c = s["turn2"]["cells"][0]
        self.assertEqual((c["ours_ttft_s"], c["ref_ttft_s"], c["ttft_ratio"]), (0.25, 1.0, 0.25))
        self.assertEqual((c["ours_cached_median"], c["ours_cached_min"]), (185, 180))
        self.assertEqual(c["ref_cached"], "known")
        self.assertTrue(s["pass"])
        md = compare.markdown(s)
        self.assertIn("Turn 2", md)
        self.assertIn("0.250", md)

    def test_zero_cached_fails_the_cell(self):
        ref, ours = self.base()
        s = compare.evaluate(ref + [t2_ref(150)], ours + [t2_ours(0)])
        self.assertFalse(s["pass"])
        self.assertFalse(s["turn2"]["cells"][0]["pass"])
        self.assertIn("0 cached", s["failing"][-1]["reasons"][0])
        self.assertEqual(compare.evaluate(ref, ours)["pass"], True)

    def test_one_zero_row_among_several_fails(self):
        ref, ours = self.base()
        s = compare.evaluate(ref + [t2_ref(150)], ours + [t2_ours(180), t2_ours(0, trial=1)])
        self.assertFalse(s["pass"])

    def test_missing_cached_on_ours_fails(self):
        ref, ours = self.base()
        self.assertFalse(compare.evaluate(ref + [t2_ref(150)], ours + [t2_ours(None)])["pass"])

    def test_null_reference_cached_is_unknown_not_failure(self):
        ref, ours = self.base()
        s = compare.evaluate(ref + [t2_ref(None)], ours + [t2_ours(180)])
        c = s["turn2"]["cells"][0]
        self.assertEqual(c["ref_cached"], "unknown")
        self.assertIsNone(c["ref_cached_median"])
        self.assertTrue(s["pass"], s["failing"])
        self.assertIn("unknown", compare.markdown(s))

    def test_no_reference_turn2_rows_still_reports_ours(self):
        ref, ours = self.base()
        s = compare.evaluate(ref, ours + [t2_ours(180)])
        c = s["turn2"]["cells"][0]
        self.assertIsNone(c["ref_ttft_s"])
        self.assertIsNone(c["ttft_ratio"])
        self.assertTrue(s["pass"])


if __name__ == "__main__":
    unittest.main()
