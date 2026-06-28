# ISS-186 R1 — code-lane audit prompt

Audit target: the diff on branch `fix/iss-186-mid-stream-sse-envelope`
against `origin/main`. The change implements SPEC-002 FR-B6's
mid-stream-disconnect error envelope by changing one writeSSEError
call site to emit `code: "provider_disconnected"` / `type:
"server_error"` instead of the legacy `stream_truncated` / `api_error`,
and extends writeSSEError's signature to take an explicit type so
the other (non-FR-B6) call sites stay on `api_error`.

## Scope of this lane

You are the **code lane**. Focus on:

- **Signature change of writeSSEError.** It now takes 4 args
  (writer, message, type, code) — were ALL existing call sites
  updated? Grep `writeSSEError(` across phase5-gateway/. Any stragglers
  will fail compilation but verify the four-arg form is consistently
  applied.
- **Distinction between gateway-truncation and provider-disconnect.**
  The buffer-full path (bufio.ErrBufferFull) keeps stream_truncated /
  api_error because it's gateway-side protection, NOT a provider
  drop. The "unexpected read error" path becomes
  provider_disconnected / server_error per FR-B6. Is the distinction
  clearly motivated in code comments?
- **Settlement vs signaling separation.** SPEC-006 § 17.7 outcome
  `stream_truncated` remains on usage_events.outcome via
  `settleTruncated()`. Only the buyer-visible SSE error.code changes.
  Are these two surfaces unambiguously separate, or could a future
  refactor recouple them?
- **Test coverage.**
  - `TestStreamingMidStreamProviderDisconnectEmitsFRB6Envelope` —
    new test asserting (code, type, message) all match FR-B6 verbatim.
    Does it also confirm settlement outcome stays stream_truncated?
  - `TestStreamingScannerErrorSettlesStreamTruncated` — existing
    test on the buffer-full path. Was the assertion updated to
    expect the now-narrower stream_truncated/api_error envelope, or
    did it not assert envelope shape before (only settlement)?
  - `TestStreamingProviderReportedUsageCannotUnderstateTruncated
    Output` — also exercises the new path (CloseWithError on
    upstream). Should this test ALSO assert the new envelope, or is
    that adequately covered by the new dedicated test?
- **Buyer write failure paths.** Look for other places where
  buyer-side stream writes could fail (e.g., line 459's `streaming
  buyer write failed`). Does that path need the same envelope, or
  does it not reach writeSSEError because the buyer is already
  gone?
- **Concurrency.** writeSSEError + flusher.Flush happen on the
  gateway's response writer goroutine; settleTruncated may dispatch
  background. No new shared state is introduced — confirm.

Out of scope for this lane (other lanes own):

- **Security lane:** error envelope leakage, log injection, denial
  of service.
- **Architect lane:** SPEC-002 FR-B6 wording, FR-B7 vs FR-B6
  alignment, SPEC-006 § 17.7 settlement matrix.

Do NOT duplicate their work.

## Files in the diff

```
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
```

Useful command:
```
git diff origin/main -- phase5-gateway/
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention: this audit gates
this PR on findings INTRODUCED by the diff against origin/main.
Pre-existing concerns visible to your audit but NOT modified by
this PR are out of scope for blocking convergence.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Issue:** one-sentence problem statement
- **Evidence:** quote relevant code
- **Recommendation:** specific change

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 800 words.
