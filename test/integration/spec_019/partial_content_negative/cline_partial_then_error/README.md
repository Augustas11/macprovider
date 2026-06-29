AC-V2-13 Cline partial-content negative fixture.

Static fixture; see `../KNOWN_GAPS.md`.

Cline sees provisional content chunks and then a terminal
`json_schema_validation_failed` SSE error frame. Client code must not parse or
surface a partial-success object.

Run:

```sh
python3 assert_fixture.py
```
