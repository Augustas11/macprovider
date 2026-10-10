#!/usr/bin/env python3
"""Offline `gh` stand-in for scripts/ops/test-entrypoints.sh.

Answers the read-only calls the entry points make from $GH_STUB_DIR/fixture.json
and applies --jq with the system jq, as gh does. Any other call exits 1.
Fixture keys:
  runs:        {workflow file: [run objects]}
  runs_later:  {workflow file: [run objects]} served from list call number
               `later_from` (0-based, default 1) on
  run:         {id: run object}            (gh api repos/R/actions/runs/ID)
  logs:        {id: text}                  (gh run view ID --log)
  artifacts:   {id: [artifact objects]}    (gh api .../runs/ID/artifacts)
  releases:    {tag: release object}       (gh release view TAG)
  latest_stable: tag                       (gh release list --exclude-pre-releases)
"""
import json
import os
import re
import subprocess
import sys

stub_dir = os.environ["GH_STUB_DIR"]
fx = json.load(open(os.path.join(stub_dir, "fixture.json")))
argv = sys.argv[1:]


def opt(name):
    if name in argv:
        i = argv.index(name)
        return argv[i + 1] if i + 1 < len(argv) else None
    return None


def emit(value):
    jq = opt("--jq")
    text = json.dumps(value)
    if jq:
        out = subprocess.run(["jq", "-r", jq], input=text, capture_output=True, text=True)
        sys.stdout.write(out.stdout)
        sys.exit(out.returncode)
    sys.stdout.write(text + "\n")
    sys.exit(0)


def count(key):
    path = os.path.join(stub_dir, "count-" + re.sub(r"[^A-Za-z0-9.-]", "_", key))
    n = int(open(path).read()) if os.path.exists(path) else 0
    open(path, "w").write(str(n + 1))
    return n


pos = [a for a in argv if not a.startswith("-")]
if pos[:2] == ["run", "list"]:
    wf = opt("-w")
    runs = fx.get("runs", {}).get(wf, [])
    if count("list-" + wf) >= fx.get("later_from", 1) and wf in fx.get("runs_later", {}):
        runs = fx["runs_later"][wf]
    emit(runs)
if pos[:2] == ["auth", "token"]:
    print("stub-gh-token")
    sys.exit(0)
if pos[:2] == ["workflow", "run"]:
    sys.exit(0)
if pos[:2] == ["run", "view"] and "--log" in argv:
    text = fx.get("logs", {}).get(pos[2])
    if text is None:
        sys.exit(1)
    sys.stdout.write(text)
    sys.exit(0)
if pos[:1] == ["api"]:
    m = re.match(r"repos/[^/]+/[^/]+/actions/runs/(\d+)(/artifacts)?$", pos[1])
    if m and m.group(2):
        emit({"artifacts": fx.get("artifacts", {}).get(m.group(1), [])})
    if m and m.group(1) in fx.get("run", {}):
        emit(fx["run"][m.group(1)])
    sys.exit(1)
if pos[:2] == ["release", "list"]:
    tag = fx.get("latest_stable")
    emit([{"tagName": tag}] if tag else [])
if pos[:2] == ["release", "view"]:
    rel = fx.get("releases", {}).get(pos[2])
    if rel is None:
        sys.stderr.write("release not found\n")
        sys.exit(1)
    emit(rel)
sys.stderr.write("gh stub: unhandled %r\n" % argv)
sys.exit(1)
