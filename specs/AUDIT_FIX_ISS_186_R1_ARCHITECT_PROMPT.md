# ISS-186 R1 — architect-lane audit prompt

Audit target: the diff on branch `fix/iss-186-mid-stream-sse-envelope`
against `origin/main`. Restores SPEC-002 § FR-B6's exact
mid-stream-disconnect SSE envelope (`provider_disconnected` /
`server_error` / "Provider disconnected during streaming") on the
gateway-side relay path. Internal settlement outcome stays
`stream_truncated` per SPEC-006 § 17.7.

## Background

SPEC-002 v1.4.1 FR-B6 (lines 1248-1254) mandates the exact envelope.
The phase-A network harness scenario `05_mid_stream_drop.yaml`
caught the gateway emitting `code: "stream_truncated"` instead. The
SPEC-002 v1.4.2 R-3 re-affirms FR-B6.

## Scope of this lane

You are the **architect lane**. Focus on:

- **Spec wording vs implementation.** Does the new envelope EXACTLY
  match FR-B6's specified strings?
  - `message: "Provider disconnected during streaming"`
  - `type: "server_error"`
  - `code: "provider_disconnected"`
  Any drift breaks SDK compatibility.
- **FR-B7 alignment.** FR-B7 (lines 1257-1268) describes the broader
  "clean error on provider failure" contract: streaming requests
  emit the FR-B6 envelope then `data: [DONE]`. Does the diff
  satisfy this composition?
- **Settlement matrix (SPEC-006 § 17.7).** The buyer-visible
  envelope (FR-B6) and settlement outcome (§ 17.7) are now
  explicitly two different fields:
  - Buyer-visible: SSE error.code = `provider_disconnected`
  - Settlement: usage_events.outcome = `stream_truncated`
  Is that mapping spec-consistent? § 17.7 lists `stream_truncated`
  as the gateway's "provider died mid-stream" row — keep
  in mind the spec wording.
- **Gateway-truncation vs provider-disconnect distinction.** The
  bufio.ErrBufferFull path (gateway truncating an overlong line)
  keeps `stream_truncated`. Is the SPEC clear about this case, or
  does FR-B6 implicitly cover ALL mid-stream failures? Read FR-B6
  carefully — "if the provider disconnects mid-stream" is
  specifically about provider disconnect, not gateway-internal
  protection. The distinction seems correct, but worth confirming.
- **Cross-spec.** SPEC-002 v1.4.2 R-3 re-affirms FR-B6. Does this
  PR fully satisfy R-3, or is there a coordinator-side companion
  change (the spec text says "the coordinator emits" — gateway
  in the architecture acts as relay)?
- **Naming / future-proofing.** Should writeSSEError continue to
  be a free function in chat_proxy.go, or should the FR-B6 envelope
  be its own typed builder so future codes can't drift? (Minor
  recommendation territory.)
- **Versioning.** Does this code fix need a SPEC-002 minor bump?
  Probably not — it restores existing FR-B6 behavior. The v1.4.2
  R-3 addendum is already the re-affirmation.

## Files in the diff

```
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
```

Useful command:
```
git diff origin/main -- phase5-gateway/
specs/SPEC-002-coordinator.md  # FR-B6 lines 1241-1255, FR-B7 lines 1257-1268
specs/SPEC-006-buyer-api.md    # § 17.7 settlement matrix
specs/SPEC-002-v1.4.2-routing-contract-addendum.md  # R-3
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **Aspect:** spec | naming | versioning | cross-service | contract
- **Issue:** one-sentence statement
- **Evidence:** quote relevant code or spec
- **Recommendation:** specific change

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 700 words.
