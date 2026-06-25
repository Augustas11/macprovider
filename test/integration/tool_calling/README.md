# Tool-Calling E2E Runner

This runner captures the PR #143 merge-blocker evidence for the OpenAI
tool-calling vertical slice.

Run against a local provider built from the PR branch:

```sh
MACPROVIDER_TOOL_E2E_BASE_URL=http://127.0.0.1:18080/v1 \
MACPROVIDER_TOOL_E2E_API_KEY=local-dev \
MACPROVIDER_TOOL_E2E_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit \
bash test/integration/tool_calling/run_e2e.sh
```

Run through the public gateway after pinning an upgraded provider:

```sh
MACPROVIDER_TOOL_E2E_BASE_URL=https://api.streamvc.live/v1 \
MACPROVIDER_TOOL_E2E_API_KEY=<real buyer key> \
MACPROVIDER_TOOL_E2E_PIN_PROVIDER=<provider-id-running-this-branch> \
MACPROVIDER_TOOL_E2E_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit \
bash test/integration/tool_calling/run_e2e.sh
```

The runner installs the same hashed OpenAI Python SDK dependency set used by
the SPEC-015 SDK compatibility smoke. It asserts:

- OpenAI Python SDK parses non-streaming `message.tool_calls[]`.
- `finish_reason` is `tool_calls`.
- `get_weather` arguments parse as JSON and contain `city: Vilnius`.
- Streaming emits `delta.tool_calls[]` and does not leak raw delimiters.
- Unsupported v1 inputs return expected 400 codes for non-`auto`
  `tool_choice`, assistant `tool_calls`, and `tool` role messages.

By default the JSON artifact is written to
`artifacts/tool-calling-e2e-<timestamp>.json`. Secrets are not printed.
