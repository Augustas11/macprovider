#!/usr/bin/env python3
"""Paste the rewards.rate_card block for a rate card into the tracked
phase4-coordinator/dist/coordinator.yaml (run in a scratch checkout).

  sync-dist-rate-card.py            # from phase3-binary/dist/static/rate-card.json
  sync-dist-rate-card.py --source   # from rate-card-source.json (before `generate`)

The block is catalog-release.py coordinator_rate_card_yaml (what
`emit-coordinator-rate-card` prints) and it is pasted with the lane's own
splice-coordinator-rate-card, i.e. the runbook's "Author the PR" step.
"""
import os, pathlib, runpy, subprocess, sys, tempfile
# The splice tool is the #1693 lane's (the pre-#1693 base does not carry it).
SPLICER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts", "catalog-release.py")
cr = runpy.run_path("scripts/catalog-release.py")
if "--source" in sys.argv:
    cand = cr["validate_candidate"](pathlib.Path("phase3-binary/catalog/autotune/autotune-candidates.json").read_bytes(), require_provenance=True)
    card = cr["validate_rate_card"](cr["resolve_rate_card"]({}, cand))
else:
    card = cr["validate_rate_card"](pathlib.Path("phase3-binary/dist/static/rate-card.json").read_bytes())
block = cr["coordinator_rate_card_yaml"](card)
y = pathlib.Path("phase4-coordinator/dist/coordinator.yaml")
with tempfile.TemporaryDirectory() as d:
    b = pathlib.Path(d, "block.yaml"); b.write_text(block)
    o = pathlib.Path(d, "out.yaml")
    subprocess.run([sys.executable, SPLICER, "splice-coordinator-rate-card", "--live-config", str(y),
                    "--block", str(b), "--output", str(o)], check=True, stdout=subprocess.DEVNULL)
    y.write_bytes(o.read_bytes())
