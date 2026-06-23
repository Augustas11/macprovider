#!/usr/bin/env python3
import os
import sys
from openai import OpenAI


def base_url(raw: str) -> str:
    raw = raw.rstrip("/")
    if raw.endswith("/v1"):
        return raw
    return raw + "/v1"


def require_content(value, label: str) -> None:
    if value is None or value == "":
        raise AssertionError(f"{label} returned empty content")


def main() -> int:
    endpoint = os.environ.get("MACPROVIDER_SPEC015_GATEWAY_URL")
    if not endpoint:
        print("MACPROVIDER_SPEC015_GATEWAY_URL is required", file=sys.stderr)
        return 2
    model = os.environ.get("MACPROVIDER_SPEC015_MODEL", "llama-3.2-3b-instruct")
    client = OpenAI(
        api_key=os.environ.get("MACPROVIDER_SPEC015_API_KEY", "test-key"),
        base_url=base_url(endpoint),
        timeout=30.0,
    )

    non_streaming = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": "SPEC-015 SDK non-streaming smoke"}],
        max_tokens=16,
    )
    require_content(non_streaming.choices[0].message.content, "non-streaming")

    saw_stream_chunk = False
    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": "SPEC-015 SDK streaming smoke"}],
        max_tokens=16,
        stream=True,
    )
    for chunk in stream:
        if chunk.choices:
            saw_stream_chunk = True
    if not saw_stream_chunk:
        raise AssertionError("streaming returned no chunks")

    print("openai-python SPEC-015 SDK compatibility smoke passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
