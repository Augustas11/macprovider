AC-V2-13 Vercel AI SDK partial-content negative fixture.

Static fixture; see `../KNOWN_GAPS.md`.

The Vercel AI SDK sees provisional content chunks and then a terminal
`malformed_json_response` SSE error frame. Client code must not parse or
surface a partial-success object.

Run:

```sh
python3 assert_fixture.py
```
