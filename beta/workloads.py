"""
Workload library for the Phase 2 buyer harness.

Each workload returns a dict the harness can splat into the OpenAI-compatible
request body:
    {
        "messages": [...],
        "max_tokens": int,
        "stream": bool,
    }

Token counts in docstrings are approximate (rough word-count heuristic, not
tokenizer-accurate). The harness records the real prompt_tokens from the
server's response.usage payload anyway, so the descriptions here are only a
hint about workload shape.
"""

from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timezone

_logger = logging.getLogger(__name__)

# Mapping from workload name to corpus category.
_WORKLOAD_CORPUS_MAP = {
    "short_chat": "short",
    "medium_with_system": "medium",
    "long_context": "long",
    "code_completion": "code",
    "agent_style": "agent",
    "streaming_check": "short",
}


def _corpus_seed(workload_name: str) -> int:
    """Deterministic seed from date + hour + workload name. Same workload in
    the same hour gets the same prompt; varies across hours/days."""
    now = datetime.now(timezone.utc)
    key = "{}-{}-{}".format(now.strftime("%Y-%m-%d-%H"), workload_name, "phase2")
    return int(hashlib.md5(key.encode()).hexdigest()[:8], 16)


def _try_corpus(workload_name: str):
    """Try to sample a prompt from corpus. Returns dict or None on failure."""
    category = _WORKLOAD_CORPUS_MAP.get(workload_name)
    if not category:
        return None
    try:
        import corpus
        return corpus.sample(category, seed=_corpus_seed(workload_name))
    except Exception as e:
        _logger.info("corpus fallback for %s: %s", workload_name, e)
        return None


# A chunk of ~2K tokens of realistic prose. Reused by the medium and long
# workloads. Lifted from the same colony-themed filler used in Phase 1 stress
# tests so output is at least mildly varied across workloads.
_PROSE_BLOCK = """\
The colony scouts returned at dusk with reports of a beetle carcass beside the
river stones. The queen, who tracks foraging routes through a chemical memory
older than the colony itself, weighed the report against the patrols' notes
from the southern boundary. Worker bees from a neighboring hive sometimes
share pollen sources during dry seasons; the colony's records suggested this
year would be one of those. Soldiers patrolled the inner chambers throughout
the night shift without incident.

Younger ants learned trail-laying behavior from the experienced foragers they
shadowed. Temperature gradients near the surface tunnels signaled approaching
weather changes; fungus gardens required precise humidity control maintained
by specialized workers. The colony's defensive perimeter expanded gradually
each summer as numbers grew, and aphid herding produced a steady honeydew
supply during the dry midsummer weeks.

Communication pheromones varied in volatility depending on the urgency of the
message. Tunnel architecture evolved over generations to optimize airflow and
traffic patterns; some workers specialized in undertaking, removing fallen
colony members to the midden. The boundary disputes with the rival colony
rarely escalated beyond ritual posturing, though the older soldiers
remembered the long summer when they had. Seed harvesting expeditions
required coordination across multiple foraging columns. Repair crews
mobilized within minutes of any structural damage to the main galleries.
"""


def short_chat() -> dict:
    """~50 tokens in, ~100 out. Basic Q&A — the cheapest signal of life."""
    prompt = _try_corpus("short_chat")
    if prompt:
        messages = []
        if prompt.get("system"):
            messages.append({"role": "system", "content": prompt["system"]})
        messages.append({"role": "user", "content": prompt["user"]})
        return {"messages": messages, "max_tokens": 120, "stream": False}
    return {
        "messages": [
            {"role": "user", "content": "In two sentences, what is the difference between a list and a tuple in Python?"},
        ],
        "max_tokens": 120,
        "stream": False,
    }


def medium_with_system() -> dict:
    """~2K in, ~200 out. System prompt + question — typical chat shape."""
    prompt = _try_corpus("medium_with_system")
    if prompt and prompt.get("system"):
        return {
            "messages": [
                {"role": "system", "content": prompt["system"] + "\n\nContext the user has already shared:\n" + _PROSE_BLOCK},
                {"role": "user", "content": prompt["user"]},
            ],
            "max_tokens": 220,
            "stream": False,
        }
    system = (
        "You are a senior backend engineer answering questions for a junior teammate. "
        "Keep answers concrete, mention tradeoffs, and prefer examples over abstractions.\n\n"
        "Context the user has already shared:\n" + _PROSE_BLOCK
    )
    return {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": "What's a good rule of thumb for when to reach for a queue versus a direct HTTP call between services?"},
        ],
        "max_tokens": 220,
        "stream": False,
    }


def long_context() -> dict:
    """
    ~8K in, ~100 out. Push the hardware — Phase 1 showed 8K is viable on M1 8GB
    at ~47s prefill. M4 should handle this comfortably; if it doesn't, that's
    itself a finding worth logging.
    """
    prompt = _try_corpus("long_context")
    if prompt and prompt.get("system"):
        # Use the corpus system prompt (already long) padded with prose to reach ~8K
        big_context = prompt["system"] + "\n\n" + (_PROSE_BLOCK + "\n\n") * 2
        return {
            "messages": [
                {"role": "system", "content": big_context},
                {"role": "user", "content": prompt["user"]},
            ],
            "max_tokens": 120,
            "stream": False,
        }
    # Repeat the ~2K block four times to land in the 8K neighborhood.
    big_context = (_PROSE_BLOCK + "\n\n") * 4
    return {
        "messages": [
            {"role": "system", "content": "You are a careful summarizer."},
            {"role": "user", "content": big_context + "\nIn one paragraph, summarize the colony's seasonal rhythm."},
        ],
        "max_tokens": 120,
        "stream": False,
    }


def code_completion() -> dict:
    """~500 in, ~100 out. Coder-style continuation."""
    prompt = _try_corpus("code_completion")
    if prompt:
        messages = []
        if prompt.get("system"):
            messages.append({"role": "system", "content": prompt["system"]})
        messages.append({"role": "user", "content": prompt["user"]})
        return {"messages": messages, "max_tokens": 240, "stream": False}
    snippet = (
        "def parse_iso8601(s: str) -> datetime:\n"
        "    \"\"\"Parse an ISO-8601 timestamp with optional fractional seconds and timezone.\n"
        "    Accepts: 2026-05-26T12:34:56, 2026-05-26T12:34:56.789, 2026-05-26T12:34:56Z,\n"
        "             2026-05-26T12:34:56+02:00. Rejects anything else with ValueError.\n"
        "    \"\"\"\n"
        "    # TODO: implement\n"
    )
    return {
        "messages": [
            {"role": "system", "content": "You write production Python. No prose, just code blocks."},
            {"role": "user", "content": "Finish the function below. Use only the standard library.\n\n```python\n" + snippet + "```"},
        ],
        "max_tokens": 240,
        "stream": False,
    }


def agent_style() -> dict:
    """
    ~3K in, ~300 out. System prompt + 'tool catalog' + user query.
    Mimics the shape of an agent-framework call (Claude Code, Cursor, etc.)
    without actually wiring up tool-calling — we just want the prefill cost.
    """
    prompt = _try_corpus("agent_style")
    if prompt and prompt.get("system"):
        system = prompt["system"] + "\n\nConversation history with the user:\n" + _PROSE_BLOCK
        return {
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": prompt["user"]},
            ],
            "max_tokens": 320,
            "stream": False,
        }
    system = (
        "You are an agent with access to the following tools:\n"
        "- read_file(path): returns file contents\n"
        "- list_dir(path): returns directory entries\n"
        "- run_shell(cmd): executes a shell command and returns stdout+stderr\n"
        "- search_web(query): returns top 5 results\n"
        "- send_email(to, subject, body): sends an email\n\n"
        "Rules:\n"
        "1. Always think step by step before calling a tool.\n"
        "2. Never invoke run_shell without first explaining the intent.\n"
        "3. Stop and ask the user for confirmation before any destructive operation.\n"
        "4. Prefer read_file over run_shell('cat ...').\n\n"
        "Conversation history with the user:\n" + _PROSE_BLOCK
    )
    return {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": "The colony report mentions a fungus garden humidity problem. Outline the steps you'd take to investigate, listing which tool calls you'd make and in what order. Don't actually call the tools."},
        ],
        "max_tokens": 320,
        "stream": False,
    }


def streaming_check() -> dict:
    """
    Small request, stream=True. Used to measure TTFT — the wall-time gap
    between request send and first SSE token.
    """
    prompt = _try_corpus("streaming_check")
    if prompt:
        messages = []
        if prompt.get("system"):
            messages.append({"role": "system", "content": prompt["system"]})
        messages.append({"role": "user", "content": prompt["user"]})
        return {"messages": messages, "max_tokens": 80, "stream": True}
    return {
        "messages": [
            {"role": "user", "content": "Count from 1 to 12 in English words, one per line."},
        ],
        "max_tokens": 80,
        "stream": True,
    }


# Registry consumed by harness.py. Keep names stable — they're foreign keys
# in runs.sqlite.
REGISTRY: dict[str, callable] = {
    "short_chat": short_chat,
    "medium_with_system": medium_with_system,
    "long_context": long_context,
    "code_completion": code_completion,
    "agent_style": agent_style,
    "streaming_check": streaming_check,
}
