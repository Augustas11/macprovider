AC-V2-6 openai-python streaming strict json_schema fixture.

Pinned SDK: openai==2.44.0.

This mirrors the v0.1 AC-15 non-streaming fixture, but sets `stream=True`.
The client accumulates `chunk.choices[0].delta.content`, parses the final
content as JSON, and validates it against the emitted schema.

Run:

```sh
python3 assert_fixture.py
```
