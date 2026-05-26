"""
Per-model stop-token derivation from HuggingFace tokenizer_config.json.

Fetches the tokenizer config for each model, extracts special tokens
(eos_token, bos_token, added_tokens_decoder entries with special=true),
and builds a compiled regex for detecting leaked stop tokens in output.

Caches fetched configs to beta/.cache/tokenizer_configs/<sanitized>.json.
Falls back to a hardcoded list on network failure.
"""

from __future__ import annotations

import json
import logging
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

BETA_DIR = Path(__file__).resolve().parent
CACHE_DIR = BETA_DIR / ".cache" / "tokenizer_configs"

# Fallback — same list from the original harness.py
FALLBACK_STOP_TOKENS = [
    "<|eot_id|>",
    "<|end_of_text|>",
    "<|endoftext|>",
    "<|im_end|>",
    "<|end|>",
    "<|start_header_id|>",
    "<|end_header_id|>",
]
_FALLBACK_RE = re.compile("|".join(re.escape(t) for t in FALLBACK_STOP_TOKENS))

# In-memory cache: model_id -> compiled regex
_model_regex_cache: dict[str, re.Pattern] = {}


def _sanitize_model_id(model_id: str) -> str:
    """Sanitize model_id to a safe filesystem name."""
    sanitized = re.sub(r'[^a-zA-Z0-9._-]', '_', model_id)
    sanitized = sanitized.strip('.')
    return sanitized or "unknown_model"


def _extract_token_value(token_entry) -> Optional[str]:
    """Extract string value from a token entry (str or {"content": str})."""
    if isinstance(token_entry, str):
        return token_entry
    if isinstance(token_entry, dict) and "content" in token_entry:
        return token_entry["content"]
    return None


def fetch_tokenizer_config(model_id: str) -> Optional[dict]:
    """Fetch tokenizer_config.json from HuggingFace, with local caching."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file = CACHE_DIR / "{}.json".format(_sanitize_model_id(model_id))

    # Try cache first
    if cache_file.exists():
        try:
            with cache_file.open() as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    # Fetch from HuggingFace
    url = "https://huggingface.co/{}/resolve/main/tokenizer_config.json".format(model_id)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "macprovider-harness/0.1"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        # Cache it
        with cache_file.open("w") as f:
            json.dump(data, f, indent=2)
        return data
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError, ValueError) as e:
        logger.warning("stop_tokens: failed to fetch tokenizer config for %s: %s", model_id, e)
        return None


def extract_special_tokens(config: dict) -> list[str]:
    """Extract all special token strings from a tokenizer config."""
    tokens = set()

    # eos_token, bos_token
    for key in ("eos_token", "bos_token"):
        val = _extract_token_value(config.get(key))
        if val:
            tokens.add(val)

    # added_tokens_decoder: entries where "special" is true
    atd = config.get("added_tokens_decoder") or {}
    for _id, entry in atd.items():
        if isinstance(entry, dict) and entry.get("special"):
            content = entry.get("content")
            if content:
                tokens.add(content)

    # Filter out empty strings and very common tokens like spaces
    return [t for t in tokens if t.strip() and len(t) > 1]


def get_leak_regex(model_id: str) -> re.Pattern:
    """Get a compiled regex for detecting leaked stop tokens for a model.
    Falls back to the hardcoded list on failure."""
    if model_id in _model_regex_cache:
        return _model_regex_cache[model_id]

    config = fetch_tokenizer_config(model_id)
    if config:
        special = extract_special_tokens(config)
        if special:
            pattern = "|".join(re.escape(t) for t in sorted(special, key=len, reverse=True))
            compiled = re.compile(pattern)
            _model_regex_cache[model_id] = compiled
            return compiled

    logger.info("stop_tokens: using fallback regex for %s", model_id)
    _model_regex_cache[model_id] = _FALLBACK_RE
    return _FALLBACK_RE
