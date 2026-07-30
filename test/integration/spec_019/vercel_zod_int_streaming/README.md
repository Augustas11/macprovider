AC-V2-12 Vercel AI SDK `z.number().int()` streaming fixture.

Static fixture; see `../KNOWN_GAPS.md`.

Pinned package versions are in `package.json`.

Logical Zod schema:

```ts
z.object({ age: z.number().int() })
```

The committed `captured_request_body.json` preserves the SDK-emitted top-level
`$schema` and integer bounds. No SDK-side rewrite or normalization is applied.

Run:

```sh
python3 assert_fixture.py
```
