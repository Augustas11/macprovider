import json
import os

from openai import OpenAI


# Security model: emitted `tool_calls[]` reflect model output, not provider-verified intent; buyer-side agent frameworks MUST validate before execution.
MODEL = os.getenv("MACPROVIDER_MODEL", "mlx-community/Qwen2.5-7B-Instruct-4bit")
BASE_URL = os.getenv("MACPROVIDER_BASE_URL", "https://api.streamvc.live/v1")
API_KEY = os.getenv("MACPROVIDER_API_KEY", "<key>")
PIN_PROVIDER = os.getenv("MACPROVIDER_PIN_PROVIDER")

default_headers = {}
if PIN_PROVIDER:
    default_headers["X-MacProvider-Pin-Provider"] = PIN_PROVIDER

client = OpenAI(
    base_url=BASE_URL,
    api_key=API_KEY,
    default_headers=default_headers or None,
)

resp = client.chat.completions.create(
    model=MODEL,
    messages=[
        {
            "role": "user",
            "content": (
                "Use the find_definition tool to answer. Call find_definition "
                "with symbol ToolCallParser and do not answer directly."
            ),
        }
    ],
    tools=[
        {
            "type": "function",
            "function": {
                "name": "find_definition",
                "description": "Find where a code symbol is defined",
                "parameters": {
                    "type": "object",
                    "properties": {"symbol": {"type": "string"}},
                    "required": ["symbol"],
                },
            },
        }
    ],
)

message = resp.choices[0].message
tool_calls = message.tool_calls or []
assert tool_calls, "expected at least one tool call"

call = tool_calls[0]
assert call.function.name == "find_definition", call.function.name

arguments = json.loads(call.function.arguments)
assert arguments.get("symbol") == "ToolCallParser", arguments

print(json.dumps([call.model_dump() for call in tool_calls], indent=2))
