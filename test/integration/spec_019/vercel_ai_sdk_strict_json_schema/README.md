AC-31 Vercel AI SDK strict json_schema fixture.

Pinned package: @ai-sdk/openai-compatible@2.0.38.

Logical Zod schema:

```ts
z.object({ name: z.string(), age: z.number() })
```

The captured Vercel body may include a top-level `$schema`; v0.1.0 strips that key in the fixture normalization step because SPEC-019 v0.1.5 rejects `$schema`.
