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
MACPROVIDER_TOOL_E2E_BASE_URL=https://api.malibu.tech/v1 \
MACPROVIDER_TOOL_E2E_API_KEY=<real buyer key> \
MACPROVIDER_TOOL_E2E_PIN_PROVIDER=<provider-id-running-this-branch> \
MACPROVIDER_TOOL_E2E_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit \
bash test/integration/tool_calling/run_e2e.sh
```

The runner installs the same hashed OpenAI Python SDK dependency set used by
the SPEC-015 SDK compatibility smoke. It asserts:

- OpenAI Python SDK parses non-streaming `message.tool_calls[]`.
- `finish_reason` is `tool_calls`.
- `find_definition` arguments parse as JSON and contain `symbol: ToolCallParser`.
- Streaming emits `delta.tool_calls[]` and does not leak raw delimiters.
- Unsupported v1 inputs return expected 400 codes for non-`auto`
  `tool_choice`, assistant `tool_calls`, and `tool` role messages.

Security model: emitted `tool_calls[]` reflect model output, not provider-verified intent; buyer-side agent frameworks MUST validate before execution.

By default the JSON artifact is written to
`artifacts/tool-calling-e2e-<timestamp>.json`. Secrets are not printed.

## Model Compatibility

Tool schemas are passed into the MLX chat template for any served model, but
MacProvider only emits OpenAI `tool_calls[]` when the model output uses a
recognized tool-call delimiter format:

- Qwen-style `<tool_call>...</tool_call>` output, with either JSON tool-call
  bodies or scalar Python-style keyword calls such as
  `find_definition(symbol="ToolCallParser")`.
- Llama 3.3-style `<|python_tag|>...<|eom_id|>` output, with either JSON
  bodies or the same scalar Python-style keyword calls.

Other HuggingFace MLX models may work if their chat template produces one of
those raw formats. Models that answer in prose, or use a different tool-call
syntax, safely fall back to normal assistant text instead of structured
`tool_calls[]`.
