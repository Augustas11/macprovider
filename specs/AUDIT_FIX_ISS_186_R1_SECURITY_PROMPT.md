# ISS-186 R1 — security-lane audit prompt

Audit target: the diff on branch `fix/iss-186-mid-stream-sse-envelope`
against `origin/main`. The change emits a mid-stream SSE error
envelope with code `provider_disconnected` / type `server_error` /
message `Provider disconnected during streaming` when the upstream
coordinator stream dies unexpectedly.

## Scope of this lane

You are the **security lane**. Focus on:

- **Information leak via error envelope.** Does the new envelope
  carry any internal-state values (provider_id, internal request_id,
  stack trace, IP)? Look at writeSSEError's payload construction.
  The buyer-visible error message is now a fixed string
  ("Provider disconnected during streaming") with no interpolation
  — confirm.
- **DoS amplification via SSE.** Is there a path where an attacker
  buyer can force repeated mid-stream disconnects (e.g., by
  exploiting provider-side fragility) and exhaust gateway buffer
  space? Look at flusher.Flush + writeSSEError sequence — does the
  envelope itself cost more than the legacy stream_truncated one?
  Bounded by a small constant, but verify.
- **Settlement integrity.** Buyer-visible signaling changes from
  stream_truncated to provider_disconnected — does the settlement
  / billing path still settle correctly? Specifically:
  - Does the gateway-estimated-tokens path still fire
    settleTruncated() before returning?
  - Does any code path (e.g., audit_events) use the SSE error.code
    as a billing key? If so, the new code value could break that.
- **Error type "server_error" — clients may retry.** OpenAI SDKs
  treat type=server_error as retriable. If a buyer's idempotency
  is not honored or the gateway issues fresh charges on retry, this
  could be exploitable. Check idempotency handling in the
  chat-completions handler.
- **Buffer-full path stays stream_truncated.** A buyer COULD attempt
  to attack by sending pathologically long lines to the gateway,
  forcing the bufio.ErrBufferFull branch. That still emits
  stream_truncated/api_error. Confirm that's not the right path
  for the FR-B6 envelope — the spec wording is specifically about
  PROVIDER disconnects, not gateway truncation.

Out of scope for this lane:

- **Code lane:** Go idiom, signature change consistency.
- **Architect lane:** SPEC consistency.

Do NOT duplicate their work.

## Files in the diff

```
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Threat model / attack surface:** one-sentence statement
- **Evidence:** quote relevant code
- **Recommendation:** specific change

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 700 words.
