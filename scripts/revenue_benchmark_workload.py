#!/usr/bin/env python3
"""Load, pin, and plan the fixed coding-agent revenue benchmark workload (issue #1734).

Offline only: this module renders request plans and never sends traffic. A
workload version is immutable once pinned here; any content change needs a new
version file and a new pin.
"""

import argparse
import hashlib
import json
import re
import sys
import uuid
from pathlib import Path

WORKLOAD_DIR = Path(__file__).resolve().parent / "revenue_benchmark"
WORKLOAD_SCHEMA = "malibu.revenue_benchmark_workload.v1"
WORKLOAD_ID = "coding-agent-revenue"
PINNED_SHA256 = {
    1: "9cba901e1fa3d8972ec97019c91e6505016589e13b0512dc5ad7d809dc46141c",
}
LONG_COMPLETION_FLOOR = 512
MIN_LONG_COMPLETION_CASES = 3
REQUEST_ID_NAMESPACE = uuid.UUID("2c6f7a1e-9d3b-5c41-8f0e-1734c0de0001")
RUN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{7,63}$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{0,63}$")
CASE_KEYS = {"case_id", "category", "language", "max_tokens", "min_completion_tokens",
             "temperature", "stream", "user_lines"}
TOP_KEYS = {"schema", "workload_id", "version", "description", "system_lines", "cases"}


def canonical_sha256(doc):
    body = json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(body).hexdigest()


def workload_path(version):
    return WORKLOAD_DIR / "coding_agent_workload_v{}.json".format(version)


def validate(doc):
    if set(doc) != TOP_KEYS:
        raise ValueError("workload keys must be exactly {}".format(sorted(TOP_KEYS)))
    if doc["schema"] != WORKLOAD_SCHEMA or doc["workload_id"] != WORKLOAD_ID:
        raise ValueError("unexpected workload schema or id")
    if not isinstance(doc["version"], int) or isinstance(doc["version"], bool) or doc["version"] < 1:
        raise ValueError("version must be a positive integer")
    if not doc["system_lines"] or not all(isinstance(line, str) for line in doc["system_lines"]):
        raise ValueError("system_lines must be non-empty strings")
    seen = set()
    long_cases = 0
    for case in doc["cases"]:
        if set(case) != CASE_KEYS:
            raise ValueError("case keys must be exactly {}".format(sorted(CASE_KEYS)))
        cid = case["case_id"]
        if not SLUG_RE.match(cid) or cid in seen:
            raise ValueError("case_id {!r} is invalid or duplicated".format(cid))
        seen.add(cid)
        if case["stream"] is not False:
            raise ValueError("case {} must be non-streaming".format(cid))
        if case["temperature"] != 0:
            raise ValueError("case {} must use temperature 0".format(cid))
        floor, budget = case["min_completion_tokens"], case["max_tokens"]
        for name, value in (("min_completion_tokens", floor), ("max_tokens", budget)):
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                raise ValueError("case {} {} must be a positive integer".format(cid, name))
        if floor > budget:
            raise ValueError("case {} min_completion_tokens exceeds max_tokens".format(cid))
        if not case["user_lines"] or not all(isinstance(line, str) for line in case["user_lines"]):
            raise ValueError("case {} user_lines must be non-empty strings".format(cid))
        if floor >= LONG_COMPLETION_FLOOR:
            long_cases += 1
    if long_cases < MIN_LONG_COMPLETION_CASES:
        raise ValueError("workload needs at least {} cases with a {}+ completion floor".format(
            MIN_LONG_COMPLETION_CASES, LONG_COMPLETION_FLOOR))
    return doc


def load(version=1, path=None):
    """Load a workload version and fail closed unless it matches its pin."""
    pinned = PINNED_SHA256.get(version)
    if pinned is None:
        raise ValueError("workload version {} is not pinned".format(version))
    with open(path or workload_path(version), encoding="utf-8") as f:
        doc = validate(json.load(f))
    if doc["version"] != version:
        raise ValueError("workload file declares version {}, expected {}".format(doc["version"], version))
    digest = canonical_sha256(doc)
    if digest != pinned:
        raise ValueError("workload v{} digest {} does not match pin {}; bump the version instead of editing".format(
            version, digest, pinned))
    return doc


def identity(doc):
    return {"workload_id": doc["workload_id"], "version": doc["version"], "sha256": canonical_sha256(doc)}


def cases_by_id(doc):
    return {case["case_id"]: case for case in doc["cases"]}


def request_id(doc, run_id, candidate_id, case_id, repetition):
    name = "{}/v{}/{}/{}/{}/{}".format(doc["workload_id"], doc["version"], run_id, candidate_id, case_id, repetition)
    return str(uuid.uuid5(REQUEST_ID_NAMESPACE, name))


def request_body(doc, case, model):
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": "\n".join(doc["system_lines"])},
            {"role": "user", "content": "\n".join(case["user_lines"])},
        ],
        "max_tokens": case["max_tokens"],
        "temperature": case["temperature"],
        "stream": case["stream"],
    }


def plan(doc, run_id, candidates, repetitions=1):
    """Render the deterministic request plan for every candidate x case x repetition.

    candidates: list of {"candidate_id", "model"}; every candidate gets the identical case set.
    """
    if not RUN_ID_RE.match(run_id):
        raise ValueError("run_id must match {}".format(RUN_ID_RE.pattern))
    if not isinstance(repetitions, int) or repetitions < 1:
        raise ValueError("repetitions must be a positive integer")
    ids = [c["candidate_id"] for c in candidates]
    if not ids or len(set(ids)) != len(ids) or not all(SLUG_RE.match(i) for i in ids):
        raise ValueError("candidate ids must be unique slugs")
    workload = identity(doc)
    rows = []
    for candidate in candidates:
        for repetition in range(repetitions):
            for case in doc["cases"]:
                rid = request_id(doc, run_id, candidate["candidate_id"], case["case_id"], repetition)
                rows.append({
                    "run_id": run_id,
                    "workload": workload,
                    "candidate_id": candidate["candidate_id"],
                    "case_id": case["case_id"],
                    "repetition": repetition,
                    "request_id": rid,
                    "min_completion_tokens": case["min_completion_tokens"],
                    "method": "POST",
                    "path": "/v1/chat/completions",
                    "headers": {"X-Request-ID": rid},
                    "body": request_body(doc, case, candidate["model"]),
                })
    return rows


def parse_candidate(text):
    candidate_id, sep, model = text.partition("=")
    if not sep or not model:
        raise argparse.ArgumentTypeError("candidate must be ID=MODEL")
    return {"candidate_id": candidate_id, "model": model}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    digest = sub.add_parser("digest", help="print the pinned workload identity")
    digest.add_argument("--version", type=int, default=1)
    render = sub.add_parser("plan", help="print the request plan as JSONL; does not send anything")
    render.add_argument("--version", type=int, default=1)
    render.add_argument("--run-id", required=True)
    render.add_argument("--candidate", action="append", type=parse_candidate, required=True, help="ID=MODEL")
    render.add_argument("--repetitions", type=int, default=1)
    args = parser.parse_args(argv)
    doc = load(args.version)
    if args.command == "digest":
        print(json.dumps(identity(doc), sort_keys=True))
        return 0
    for row in plan(doc, args.run_id, args.candidate, args.repetitions):
        sys.stdout.write(json.dumps(row, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
