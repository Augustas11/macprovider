"""Deterministic chat prompts and grid cells shared by the reference and the provider client.

Both sides import this module so the chat messages are byte-identical. Sizing is
by characters, not tokens: the client side has no tokenizer. CHARS_PER_TOKEN is a
rough estimate for English prose with Llama/Qwen-class BPE tokenizers; every
result line records the real prompt_tokens, so the estimate only sets the target.
"""
import hashlib
import json

CHARS_PER_TOKEN = 4.0

# Fixed vocabulary for filler notes. Changing it changes every prompt.
_WORDS = (
    "harbor lantern keeper granite tide ledger copper meadow orchard river "
    "signal compass winter archive bridge foundry cellar market weaver canal "
    "quarry beacon glacier valley ferry orbit thicket summit furnace carriage "
    "pigment chapel cistern barley ember falcon garnet hollow island juniper "
    "kettle lagoon marble nectar osprey pewter quiver rafter saddle timber "
    "umber velvet walnut yarrow zephyr anchor bramble cinder dune estuary "
    "fjord gully heron inlet jetty kiln loom moor"
).split()

_INSTRUCTION = (
    "\n\nTask: using the notes above only as loose inspiration, write a very long, "
    "detailed, continuous story of at least 6000 words about the people who keep "
    "a remote coastal lighthouse. Write many chapters with dialogue and description. "
    "Do not summarize, do not conclude, do not add a closing remark, and do not stop "
    "early; keep writing the story."
)


def _filler(row, n_chars):
    """Deterministic pseudo-prose of exactly n_chars characters for this row."""
    out = []
    size = 0
    i = 0
    while size < n_chars:
        digest = hashlib.sha256(f"parity-grid:{row}:{i}".encode()).digest()
        words = [_WORDS[b % len(_WORDS)] for b in digest[:12]]
        sentence = " ".join(words).capitalize() + ". "
        out.append(sentence)
        size += len(sentence)
        i += 1
    return "".join(out)[:n_chars]


def build_messages(ctx_tokens, row):
    """Chat messages of about ctx_tokens tokens for prompt index `row`.

    The row tag comes first so distinct rows diverge right after the chat
    template preamble and do not share a prefix-cache entry.
    """
    if ctx_tokens <= 0 or row < 0:
        raise ValueError("ctx_tokens must be > 0 and row >= 0")
    header = f"Notebook {row:04d}. Field notes follow.\n\n"
    target = int(ctx_tokens * CHARS_PER_TOKEN)
    body = _filler(row, max(0, target - len(header) - len(_INSTRUCTION)))
    return [{"role": "user", "content": header + body + _INSTRUCTION}]


# Turn 2 of the two-turn cell: a short fixed follow-up (about 20 tokens).
FOLLOWUP = "Thanks. Now restate your answer in one sentence, then name one thing I should check next."


def build_turn2_messages(ctx_tokens, row, assistant1, reasoning=None):
    """Turn-2 chat: the turn-1 prompt, the assistant's turn-1 text, the fixed follow-up.

    With `reasoning` (not None) the assistant message also carries it as reasoning_content,
    as an OpenAI client that keeps the reasoning re-sends it.
    """
    assistant = {"role": "assistant", "content": assistant1}
    if reasoning is not None:
        assistant["reasoning_content"] = reasoning
    return build_messages(ctx_tokens, row) + [assistant, {"role": "user", "content": FOLLOWUP}]


def load_assistant1(provider_jsonl):
    """Map (ctx, max_tokens, row) -> the provider's turn-2 assistant1 text, first record wins.

    The reference replays the content history the provider's turn-2 request carried. Records
    keep no reasoning text for turn 2, so a provider run with --turn2-history verbatim is replayed
    without reasoning_content: its reference history differs from what the provider received.
    """
    out = {}
    with open(provider_jsonl) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("kind", "row") != "row" or r.get("turn") != 2 or not r.get("assistant1"):
                continue
            out.setdefault((r["ctx_target"], r["max_tokens"], r["row"]), r["assistant1"])
    return out


def cell_key(model, ctx, out, rows):
    return f"{model}|ctx{ctx}|out{out}|rows{rows}"


def load_grid(path):
    with open(path) as f:
        return json.load(f)


def expand_cells(grid, max_context=None):
    """Return (ctx_tokens, max_tokens, rows) tuples for one model.

    A context is skipped when ctx + output would exceed max_context.
    """
    cells = []
    for ctx in grid["contexts"]:
        for out in grid["outputs"]:
            if max_context and ctx["tokens"] + out > max_context:
                continue
            for rows in grid["rows"]:
                cells.append((ctx["tokens"], out, rows))
    return cells
