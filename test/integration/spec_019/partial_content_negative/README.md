AC-V2-13 partial-content negative streaming fixtures.

Streaming structured-output deltas are provisional until the terminal
validation hook succeeds. These fixtures cover SDK clients that receive partial
content followed by a terminal SPEC-018/SPEC-019 SSE error frame.

Both subfixtures assert that the accumulated partial content does not become a
successful final object.
