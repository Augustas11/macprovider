# Catalog chat templates for tool-call and history tests (#2107)

Byte-for-byte copies of the `chat_template` each catalog artifact ships, used
by `CatalogToolGrammarTests` to render tool history through the model's own
template and to parse the tool calls those templates render (SPEC-018 §3.1,
§3.6). GLM-5.3 uses `../glm53-chat-template/chat_template.jinja`.

| File | Source repository | Revision | From |
| --- | --- | --- | --- |
| `gpt-oss-20b.jinja` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | `773a7da77e569019bb0fd17a554b263738d669a3` | `chat_template.jinja` |
| `qwen3.8-27b.jinja` | `mlx-community/Qwen3.8-27B-4bit` | `10c35caafbb80f7dc6a7a432cdd11af10a6d4818` | `chat_template.jinja` |
| `glm-4.5-air.jinja` | `mlx-community/GLM-4.5-Air-4bit` | `60837794f3caafc4682dd1a9188a82c55a9100ef` | `chat_template.jinja` |
| `llama-3.1-8b-instruct.jinja` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `241a666dad6cb93c8ff213d39a7f34a36bf26db4` | `tokenizer_config.json` `chat_template` |
| `llama-3.2-3b-instruct.jinja` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` | `tokenizer_config.json` `chat_template` |
| `nemotron-3-nano-30b-a3b.jinja` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | `832f602eba5d22436c258c1462bdedc5afddb42b` | `chat_template.jinja` |
| `nemotron-3.5-lightning-30b-a3b.jinja` | `mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit` | `55ac8c89261109b36c04371cd3f479a4594208c8` | `chat_template.jinja` |
| `nemotron-3.5-bolt-74b-a9b.jinja` | `rapid-mlx/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-MLX-4bit` | `cbfda6be4e9ff9e8d3acf0c0a57c54c1a496ef81` | `chat_template.jinja` |
| `gemma-4-26b-a4b-it.jinja` | `mlx-community/gemma-4-26b-a4b-it-4bit` | `0d77464eeb233a2da68ebf9d7dc4edaac7db956d` | `chat_template.jinja` |
| `qwen3-8b.jinja` | `mlx-community/Qwen3-8B-4bit` | `545dc4251c05440727734bcd94334791f6ab0192` | `tokenizer_config.json` `chat_template` |
| `qwen3-coder-30b-a3b-instruct.jinja` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `6e302ea604ad9ab206367e2c501d1571023e7b6d` | `chat_template.jinja` |
| `qwen3.5-27b.jinja` | `mlx-community/Qwen3.5-27B-4bit` | `45797d2985a12c55e6473686e9ea91b95e959553` | `chat_template.jinja` (byte-identical to `Qwen3.5-35B-A3B-4bit@1e20fd8d`) |
| `qwen3.6-27b.jinja` | `mlx-community/Qwen3.6-27B-4bit` | `c000ac2c2057d94be3fa931000c31723aac53282` | `chat_template.jinja` (byte-identical to `Qwen3.6-35B-A3B-4bit@38740b84`) |

Each template remains under its model's license (Llama 3.1 / 3.2 Community
License, Gemma Terms of Use, NVIDIA Open Model License, OpenMDW-1.1, Apache-2.0, MIT); the
files are test inputs only and ship in no binary.

`ReasoningEffortTests` also renders the effort-aware GLM-5.3, gpt-oss and
Qwen3.8 templates and verifies the existing thinking switches. gpt-oss is
Apache-2.0; Qwen3.8 uses the license of its source model.

`ReasoningSwitchTests` renders every catalog template with a thinking switch
(Qwen3-8B, Qwen3.5, Qwen3.6, Qwen3.8, Nemotron-3, GLM-4.5, Gemma-4) for the
SPEC-018 v0.3.16 explicit-effort rule. Qwen3.5 and Qwen3.6 are Apache-2.0.
