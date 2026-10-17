# GLM-5.3-Flash chat-template parity fixture (epic #2029)

- `chat_template.jinja`: the template shipped in `Jundot/GLM-5.3-Flash-oQ4e-mtp`
  @ `36defc5042d92a992a7948e83d6f110b8df69329` (MIT), byte-for-byte.
- `cases.json`: message lists (system + user, multi-turn, reasoning content,
  `<think>` in content, content parts, `reasoning_effort`, `clear_thinking`,
  tool definitions with tool calls and results, a tool-output list). Mapping
  keys are sorted: the provider builds request objects without key order and
  swift-jinja renders them sorted, so the reference uses the same order.
- `reference.json`: transformers 5.17.0 / Jinja2 3.1.6 `apply_chat_template`
  output (text and token ids) for each case, from
  `scripts/lab/cb-studio/glm53_template_reference.py`.

`GLM5NextChatTemplateTests` requires the provider's rendering (after the
`ChatTemplateCompatibility` rewrite) to equal the text byte for byte, and with
the real artifact (`MACPROVIDER_GLM53_ARTIFACT_DIR`) the token ids.
