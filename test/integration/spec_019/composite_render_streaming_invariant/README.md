AC-V2-14 composite-render streaming invariant fixture.

The fixture compares the schema-adjusted system-position composition for
`stream:false` and `stream:true` requests with tools plus `json_schema`.
The only allowed request-body difference is the `stream` boolean; the rendered
message/tool composite must stay byte-equivalent across the base, Qwen3,
Llama-3.3, and non-empty tool-history cases.

Run:

```sh
python3 assert_fixture.py
```
