#!/usr/bin/env python3
"""Build a private SPEC-036 FR-20 prompt corpus for compute-integrity scoring.

  python3 -I scripts/compute-integrity-corpus.py --topics PRIVATE_TOPICS_FILE
      [--count 400] [--version NAME] [--out PATH] [--seed N]

The corpus is coordinator-only: a provider that can recognize verification
prompts can answer them honestly while substituting a cheaper model for buyers.
The phrasing templates below are public and deliberately buyer-like, so a
template match says nothing; what keeps the corpus private is the operator's
topic list (one topic per line, at least 16, kept outside the repository) and
a random draw from the template x topic space.

The output goes OUTSIDE the repository, by default under
~/.config/macprovider/operator-secrets/compute-integrity/ (directory 0700, file
0600, never overwritten), in the format the coordinator loads
(internal/computeintegrity/scoring_corpus.go) and checked with the same rules
the ops entry point applies (scripts/ops/lib/pearl-cli-config.py
validate-corpus). Only the path, prompt count and sha256 are printed; never
corpus content. Install it with:

  COMPUTE_INTEGRITY_CORPUS=<path> PEARL_RUNTIME_TASK=compute-integrity-enable \
    scripts/ops/pearl-runtime.sh status
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import random
import secrets
import sys

REPO = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEFAULT_DIR = os.path.expanduser("~/.config/macprovider/operator-secrets/compute-integrity")
MIN_TOPICS = 16
MAX_TOPIC_CHARS = 200

SYSTEMS = [
    "You are a helpful assistant.",
    "You are a concise assistant. Answer clearly.",
    "You are a friendly assistant that explains things simply.",
    "You are an expert assistant. Be accurate and direct.",
    "You are a patient tutor.",
    "You are a practical assistant who focuses on what works.",
    "You are a careful assistant. Say when something is uncertain.",
    "You are a knowledgeable assistant who writes in plain English.",
    "You help people understand everyday topics.",
    "You are a thoughtful assistant. Keep answers well organized.",
]

USERS = [
    "Explain {t}.",
    "Can you explain {t} to me?",
    "What should a beginner know about {t}?",
    "Give me an overview of {t}.",
    "What are the main ideas behind {t}?",
    "What are three common misconceptions about {t}?",
    "Summarize {t} in a few sentences.",
    "How would you describe {t} to someone new to it?",
    "What are the pros and cons of {t}?",
    "Why does {t} matter?",
    "What is a good way to get started with {t}?",
    "List a few practical tips about {t}.",
    "What questions should I ask when learning about {t}?",
    "Compare {t} with a related idea and explain the difference.",
    "What are typical mistakes people make with {t}?",
    "Write a short explanation of {t} for a newsletter.",
    "I keep hearing about {t}. What is it, briefly?",
    "Describe how {t} works, step by step.",
    "What is the history of {t} in a nutshell?",
    "Give me a simple example that illustrates {t}.",
    "How has {t} changed over time?",
    "What would an expert want me to understand about {t}?",
    "Help me prepare a two-minute talk on {t}.",
    "What are the key terms I need to know for {t}?",
]


def load_validator():
    path = os.path.join(REPO, "scripts", "ops", "lib", "pearl-cli-config.py")
    spec = importlib.util.spec_from_file_location("pearl_cli_config", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def inside_repo(path):
    """True inside this repository or any other git work tree."""
    real = os.path.realpath(path)
    if real == REPO or real.startswith(REPO + os.sep):
        return True
    d = real if os.path.isdir(real) else os.path.dirname(real)
    while True:
        if os.path.lexists(os.path.join(d, ".git")):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


def read_topics(path):
    if inside_repo(path):
        sys.exit("refused: the topics file is inside the repository; keep it private and outside it")
    with open(path, encoding="utf-8") as f:
        topics = []
        for line in f:
            t = " ".join(line.split())
            if t and not t.startswith("#") and t not in topics:
                if len(t) > MAX_TOPIC_CHARS:
                    sys.exit("refused: a topic is longer than %d characters" % MAX_TOPIC_CHARS)
                topics.append(t)
    if len(topics) < MIN_TOPICS:
        sys.exit("refused: the topics file needs at least %d distinct topics, has %d" % (MIN_TOPICS, len(topics)))
    return topics


def build(topics, count, version, rng):
    space = len(SYSTEMS) * len(USERS) * len(topics)
    if count > space:
        sys.exit("refused: --count %d exceeds the %d distinct prompts these topics allow" % (count, space))
    prompts = []
    for i in rng.sample(range(space), count):
        s, rest = divmod(i, len(USERS) * len(topics))
        u, t = divmod(rest, len(topics))
        prompts.append({"system": SYSTEMS[s], "user": USERS[u].format(t=topics[t])})
    return {"version": version, "prompts": prompts}


def write_private(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--topics", required=True, help="private topics file, one topic per line")
    p.add_argument("--count", type=int, default=400, help="number of prompts (default 400)")
    p.add_argument("--version", help="corpus version (default private-<date>-<random>)")
    p.add_argument("--out", help="output file (default under %s)" % DEFAULT_DIR)
    p.add_argument("--seed", type=int, help="draw seed (default: random; a fixed seed makes the corpus reproducible)")
    args = p.parse_args(argv)
    if args.count < 1:
        sys.exit("refused: --count must be at least 1")
    version = args.version or "private-%s-%s" % (
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d"), secrets.token_hex(4))
    if not version.strip() or len(version) > 128 or any(c in version for c in "/\\\0\n"):
        sys.exit("refused: --version must be a short name without slashes or newlines")
    out = os.path.abspath(os.path.expanduser(args.out or os.path.join(DEFAULT_DIR, "corpus-%s.json" % version)))
    if inside_repo(out) or inside_repo(os.path.dirname(out)):
        sys.exit("refused: the corpus must be written outside the repository")
    if os.path.lexists(out):
        sys.exit("refused: %s exists; choose another --out or --version" % out)
    rng = random.Random(args.seed) if args.seed is not None else random.SystemRandom()
    doc = build(read_topics(args.topics), args.count, version, rng)
    data = (json.dumps(doc, ensure_ascii=False, indent=1) + "\n").encode("utf-8")
    validator = load_validator()
    try:
        validator.parse_corpus(data)
    except validator.Refused as exc:
        sys.exit("refused: the generated corpus fails the coordinator's corpus rules: %s" % exc)
    write_private(out, data)
    print(json.dumps({"path": out, "prompts": len(doc["prompts"]),
                      "sha256": hashlib.sha256(data).hexdigest()}, sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1:])
