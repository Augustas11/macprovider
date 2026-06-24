import json
import os

from openai import OpenAI


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
    messages=[{"role": "user", "content": "What is the weather in Vilnius?"}],
    tools=[
        {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get the current weather for a city",
                "parameters": {
                    "type": "object",
                    "properties": {"city": {"type": "string"}},
                    "required": ["city"],
                },
            },
        }
    ],
)

message = resp.choices[0].message
tool_calls = message.tool_calls or []
assert tool_calls, "expected at least one tool call"

call = tool_calls[0]
assert call.function.name == "get_weather", call.function.name

arguments = json.loads(call.function.arguments)
assert arguments.get("city", "").lower() == "vilnius", arguments

print(json.dumps([call.model_dump() for call in tool_calls], indent=2))
