#!/usr/bin/env python3
"""Client cancel mid-window on the batched route, then health checks.
usage: cancel_probe.py PORT MODEL"""
import json, sys, time
sys.argv = sys.argv[:3]
exec(open("/Users/a1/lab-cb-step/stream_semantics_lib.py").read())
print(json.dumps({"probe": "cancel_c4", "results": concurrent([("Write a very long essay about rivers.", 512, 10)] * 4)}), flush=True)
time.sleep(2)
print(json.dumps({"probe": "cancel_mixed", "results": concurrent([("Write a very long essay about rivers.", 512, 10),
      ("Write a long essay about mountains.", 200)])}), flush=True)
time.sleep(2)
print(json.dumps({"probe": "health_after", "results": concurrent([("Say hello.", 32)] * 4)}), flush=True)
