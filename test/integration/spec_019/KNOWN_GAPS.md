# SPEC-019 v0.2 IMPL - Known fixture gaps (deferred to v0.2.x)

The v0.2 IMPL fixtures assert byte-shape and pinned-version presence,
but the captured request bodies are static (committed JSON) rather
than regenerated from live SDK invocations. The static fixtures
satisfy the AC-V2-5 / AC-V2-12 / AC-V2-13 letter requirements but
the spec-level liveness guarantee is provenance via documentation,
not execution.

**v0.2.x will add:**
- `cline_streaming_structured_output/regenerate.sh` - invokes the
  pinned Cline commit's active streaming primitive against a stub
  endpoint, captures the outbound POST body, overwrites the
  committed JSON.
- `vercel_zod_int_streaming/regenerate.ts` - invokes pinned `ai` +
  `@ai-sdk/openai-compatible` + `zod` against a stub endpoint,
  captures, overwrites.
- `partial_content_negative/{cline,vercel}_partial_then_error/exercise.{sh,ts}`
  - runs the partial-content scenario against a stub upstream that
  emits the SSE sequence, asserts the SDK-side parse failure.

**Tracking:** https://github.com/Augustas11/macprovider/issues/235

**Until v0.2.x:**
- README pins document the intended SDK identity.
- Static `captured_request_body.json` and `sample_stream.sse` are
  hand-crafted to match the shape the pinned SDKs are expected to
  emit.
- `package-lock.json` files in fixture dirs contain the version pins
  as plain text; `assert_fixture.py` checks substring presence.
- Drift detection relies on the human reviewing PRs that change
  these fixtures, not CI.
