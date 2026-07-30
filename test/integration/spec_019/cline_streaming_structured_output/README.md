AC-V2-5 Cline streaming structured-output fixture.

Static fixture; see `../KNOWN_GAPS.md`.

Upstream Cline pin:

- Repository: https://github.com/cline/cline
- Branch: main
- Commit: 4175677e712e429e1847964f4cd4884077c4ef66
- Package manager: bun@1.3.13

Cline's active SDK path at this commit imports `jsonSchema` and `streamText`
from `ai` in `sdk/packages/llms/src/providers/ai-sdk.ts`; it does not use
`streamObject` on the active call path. The package manifest declares
`@ai-sdk/openai-compatible: ^2.0.38` and `ai: ^6.0.144`; `bun.lock` resolves
`@ai-sdk/openai-compatible@2.0.51` and `ai@6.0.208`.

Fixture assertions:

- outbound body contains `"stream": true`
- outbound body contains `response_format.json_schema.name`, `schema`, and
  `strict:true`
- provider config is documented as `supportsStructuredOutputs:true`
- accumulated assistant output validates against the schema
- replayed receipt prompt hashes are byte-identical

Run:

```sh
python3 assert_fixture.py
```
