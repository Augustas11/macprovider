"""
Public-corpus prompt sampler for Phase 2 cooperative workloads.

Provides deterministic sampling from pre-curated JSONL files under beta/corpus/.
Each category maps to a workload shape (short, medium, code, long, agent).

Usage:
    from corpus import sample
    prompt = sample("short", seed=42)
    # -> {"system": None, "user": "...", "source": "curated/short"}
"""

from __future__ import annotations

import json
import logging
import random
from pathlib import Path

logger = logging.getLogger(__name__)

CORPUS_DIR = Path(__file__).resolve().parent / "corpus"
CATEGORIES = ("short", "medium", "code", "long", "agent")

# In-memory cache: category -> list of dicts
_cache: dict[str, list[dict]] = {}


def _load_category(category: str) -> list[dict]:
    if category in _cache:
        return _cache[category]
    path = CORPUS_DIR / "{}.jsonl".format(category)
    if not path.exists():
        logger.warning("corpus: %s not found, returning empty", path)
        _cache[category] = []
        return []
    entries = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    _cache[category] = entries
    return entries


def sample(category: str, seed: int = None) -> dict:
    """
    Return a prompt dict: {"system": str|None, "user": str, "source": str}.
    Deterministic given a seed. Raises ValueError if category is unknown.
    """
    if category not in CATEGORIES:
        raise ValueError("unknown category: {} (expected one of {})".format(category, CATEGORIES))
    entries = _load_category(category)
    if not entries:
        raise FileNotFoundError("no corpus data for category '{}'".format(category))
    rng = random.Random(seed)
    return rng.choice(entries)
