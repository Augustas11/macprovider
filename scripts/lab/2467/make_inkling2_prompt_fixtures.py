#!/usr/bin/env python3
"""Inkling 2 prompt fixtures for Inkling2ChatEncodingTests (#2467).

Renders each case with Jinja2 from the publisher's chat_template.jinja the way
transformers' apply_chat_template does (its `tojson`, `raise_exception` and
`{% generation %}` block), and prints the cases as JSON: input messages,
tools, reasoning_effort, and the expected prompt. The Swift test embeds the
printed expectations.

Usage: make_inkling2_prompt_fixtures.py PATH/TO/chat_template.jinja

Nested argument and parameter keys are written sorted: the provider builds
template values with swift-jinja's Value(any:), which sorts dictionary keys.
"""
import json
import sys

import jinja2
from jinja2 import nodes
from jinja2.ext import Extension


class Generation(Extension):
    """transformers' AssistantTracker without mask tracking."""

    tags = {"generation"}

    def parse(self, parser):
        lineno = next(parser.stream).lineno
        body = parser.parse_statements(["name:endgeneration"], drop_needle=True)
        return nodes.CallBlock(self.call_method("_render"), [], [], body).set_lineno(lineno)

    def _render(self, caller):
        return caller()


def tojson(x, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
    return json.dumps(x, ensure_ascii=ensure_ascii, indent=indent, separators=separators, sort_keys=sort_keys)


def raise_exception(message):
    raise jinja2.exceptions.TemplateError(message)


READ_FILE = {
    "type": "function",
    "function": {
        "name": "read_file",
        "description": "Read a file from disk",
        "parameters": {"properties": {"path": {"type": "string"}}, "required": ["path"], "type": "object"},
    },
}
SEARCH = {
    "type": "function",
    "function": {
        "name": "search",
        "parameters": {
            "properties": {"limit": {"type": "integer"}, "query": {"type": "string"}},
            "type": "object",
        },
    },
}

CASES = [
    ("plainUserDefaultEffort", [{"role": "user", "content": "What is 17*23?"}], None, None),
    (
        "systemThenUserMediumEffort",
        [
            {"role": "system", "content": "You are terse."},
            {"role": "user", "content": "Héllo \"world\"\n/etc"},
        ],
        None,
        "medium",
    ),
    ("toolsDeclaredLowEffort", [{"role": "user", "content": "Read /etc/hosts."}], [READ_FILE, SEARCH], "low"),
    (
        "toolHistoryNoneEffort",
        [
            {"role": "user", "content": "Find files."},
            {
                "role": "assistant",
                "content": "",
                "reasoning_content": "Search first.",
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {
                            "name": "search",
                            "arguments": {"limit": 5, "query": "naïve \"q\"", "tags": ["a", "b"], "zeta": {"b": True, "a": 0}},
                        },
                    }
                ],
            },
            {"role": "tool", "tool_call_id": "call_1", "content": "[\"x.txt\"]"},
            {"role": "assistant", "content": "Found x.txt."},
            {"role": "user", "content": "Thanks"},
        ],
        [READ_FILE, SEARCH],
        "none",
    ),
    ("systemOnlyEffortAtEnd", [{"role": "system", "content": "Only system."}], None, "high"),
    (
        "assistantReasoningAndContent",
        [
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "Hello.", "reasoning_content": "Greet back."},
            {"role": "user", "content": "again"},
        ],
        None,
        "max",
    ),
]


def sort_nested(value):
    if isinstance(value, dict):
        return {key: sort_nested(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [sort_nested(item) for item in value]
    return value


def main():
    env = jinja2.Environment(trim_blocks=True, lstrip_blocks=True, extensions=[Generation, "jinja2.ext.loopcontrols"])
    env.filters["tojson"] = tojson
    env.globals["raise_exception"] = raise_exception
    template = env.from_string(open(sys.argv[1], encoding="utf-8").read())
    out = []
    for name, messages, tools, effort in CASES:
        messages = sort_nested(messages)
        context = {"messages": messages, "tools": tools, "add_generation_prompt": True}
        if effort is not None:
            context["reasoning_effort"] = effort
        out.append({"name": name, "effort": effort, "prompt": template.render(**context)})
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
