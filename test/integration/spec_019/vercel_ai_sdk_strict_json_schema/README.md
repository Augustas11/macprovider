AC-31 Vercel AI SDK strict json_schema fixture.

Pinned package: @ai-sdk/openai-compatible@2.0.38.

Add `supportsStructuredOutputs: true` to the `createOpenAICompatible(...)`
config before capturing the outbound request.

Logical Zod schema:

```ts
z.object({ name: z.string(), age: z.number() })
```

The captured Vercel body may include a top-level `$schema`; v0.1.0 strips that key in the fixture normalization step because SPEC-019 v0.1.5 rejects `$schema`.

```sh
jq 'del(.response_format.json_schema.schema."$schema")' \
  captured_request_body.json \
  > fixture_request_body.json
```

Expected outcome: the fixture request is accepted as a strict SPEC-019
`json_schema` request after `$schema` normalization.
