# DESIGN_SPEC_018_v0_2 — Deliverable #6: Multi-turn `tool_call_id` validation rule

## Context

SPEC-018 v0.2 builds on locked SPEC-018 v0.1.5 (`specs/SPEC-018-agentic-tool-calling.md`). v0.2 anchor framework is Cline.

v0.1.5 establishes two relevant invariants:

- §2.1 provider-emitted tool-call IDs are minted as `call_<uuid-hex-lowercase-without-hyphens>`.
- §10c forward compatibility protects the `call_` prefix for v0.2+ tool-call IDs.

This deliverable applies only after §10a #1 multi-turn acceptance lands. At that point, buyer requests may include assistant-history `tool_calls[]` and `role:"tool"` messages whose `tool_call_id` references a prior assistant tool call.

## Recommendation

SPEC-018 v0.2 SHOULD choose regime **(a) format-only, stateless validation**, plus strict request-internal cross-message consistency. The provider MUST NOT require that an incoming `tool_call_id` was minted by the current provider process, current HTTP/WebSocket session, current provider identity, or current request.

The validation goal is:

1. keep request shape OpenAI-compatible and parseable by Cline;
2. reject malformed conversation graphs before inference;
3. preserve Cline conversation resume across sessions;
4. avoid introducing provider-side session state for data that is buyer-controlled prompt history.

The validation goal is not to prove that buyer-supplied assistant-history turns are authentic. In Ring 1, the buyer owns the agent loop and can already place arbitrary text in `messages[]`. A fabricated assistant `tool_calls[]` entry plus a fabricated matching `role:"tool"` result is buyer-controlled context, not a provider-authenticated event and not a settlement decision about a past turn.

## 1. ID format validation

There are two related but distinct regexes.

### Provider-emitted IDs

The provider's own newly synthesized assistant `tool_calls[].id` values MUST continue to match the v0.1.5 shape:

```text
^call_[a-f0-9]{32}$
```

This is the existing `call_` plus lowercase hyphenless UUID-hex suffix. It preserves §2.1 and §10c exactly and carries at least UUID-v4's effective 122 bits of entropy when generated from a fresh platform UUID.

### Request-accepted IDs

For request-side assistant-history `tool_calls[].id` and `role:"tool".tool_call_id`, the provider MUST accept:

```text
^call_[A-Za-z0-9]{16,64}$
```

Rationale:

- The `call_` prefix is locked by §10c.
- OpenAI's public API schema types tool-call IDs as strings, and current examples use mixed-case alphanumeric `call_...` IDs rather than lowercase UUID-hex only.
- A 16-character base62 suffix provides about 95 bits of namespace if randomly generated; macprovider's own emitted IDs remain stronger at UUID-v4 scale. Entropy cannot be proven for buyer-supplied history, so the regex is a compatibility and typo-rejection rule, not an authenticity proof.
- The 64-character maximum prevents unbounded IDs from becoming a request-validation or prompt-rendering abuse surface while leaving room for upstream OpenAI-compatible clients that use longer opaque suffixes.

Rejected suffix characters include `_`, `-`, `.`, `/`, `:`, whitespace, non-ASCII, and empty suffixes. A future cryptographic ID format such as `call_<random>_<mac>` would not be v0.2-compatible unless it lands through a later SPEC change that updates this request-accepted regex while preserving the leading `call_` prefix.

## 2. Provider-minted vs externally-minted

v0.2 MUST NOT use session-scoped mint tracking or cryptographic binding for request-side validation.

Session-scoped validation is rejected because Cline supports conversation resume: a resumed request can include valid assistant-history tool calls minted by a prior provider process or prior connection. Requiring "this live session minted it" would turn a legitimate resumed conversation into a false negative.

Cryptographic binding is rejected for v0.2 because it also breaks resume unless the provider persists or re-derives old session keys, and because it changes the ID shape away from the locked v0.1.5 provider-emitted UUID-hex form. It adds complexity without protecting a provider-controlled money path: buyer-supplied prior messages are model input, not retroactive evidence that a provider earned credits.

The provider MAY log whether a request-side ID matches a local recently-minted cache for observability, but that cache MUST NOT affect request acceptance, billing, receipt generation, or synthesis eligibility in v0.2.

## 3. Cross-message consistency

The provider MUST validate the `messages[]` array as an ordered conversation graph before inference.

Rules:

1. Every assistant-history `tool_calls[].id` MUST match `^call_[A-Za-z0-9]{16,64}$`.
2. Every `role:"tool"` message MUST contain a non-empty `tool_call_id` matching `^call_[A-Za-z0-9]{16,64}$`.
3. A `role:"tool"` message MUST appear after the assistant message whose `tool_calls[]` contains the same ID.
4. Within a single request, each `tool_call_id` MUST appear in exactly one assistant `tool_calls[]` entry.
5. Within a single request, each assistant `tool_calls[].id` MAY have zero or one matching `role:"tool"` result.
6. A `role:"tool"` message MUST NOT reuse a `tool_call_id` already used by an earlier `role:"tool"` message in the same request.
7. A `role:"tool"` message whose `tool_call_id` does not match an earlier assistant `tool_calls[].id` in the same request MUST be rejected.

Rule 5 intentionally allows a latest assistant turn with pending tool calls at the end of history. That shape can appear in saved conversations or debugging fixtures. It also avoids requiring all historical assistant tool calls to have results if the buyer truncated part of the conversation. However, any actual `role:"tool"` result that is present must be linked, ordered, and unique.

Valid:

```json
[
  {"role": "user", "content": "Read package.json"},
  {
    "role": "assistant",
    "content": null,
    "tool_calls": [
      {"id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"package.json\"}"}}
    ]
  },
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "{\"ok\":true}"},
  {"role": "user", "content": "Now summarize it"}
]
```

Invalid because the tool result appears before the assistant tool call:

```json
[
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "{}"},
  {
    "role": "assistant",
    "tool_calls": [
      {"id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
    ]
  }
]
```

Invalid because one tool call has two results:

```json
[
  {
    "role": "assistant",
    "tool_calls": [
      {"id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
    ]
  },
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "first"},
  {"role": "tool", "tool_call_id": "call_0123456789abcdef0123456789abcdef", "content": "second"}
]
```

## 4. Cross-session reuse

Cross-session reuse MUST be accepted when the request is internally consistent and every ID matches the request-accepted regex.

Acceptance criterion: a Cline conversation saved after a successful macprovider tool-call turn can be resumed through a fresh provider process or fresh HTTP/WebSocket connection. The resumed request includes prior assistant `tool_calls[].id` and matching `role:"tool".tool_call_id` values. The provider validates format and request-internal consistency, does not check a live minted-ID registry, and proceeds to inference.

This acceptance criterion is release-gating for §10a #1 multi-turn support. A provider that rejects solely because "this process/session did not mint the ID" is non-compliant with v0.2.

## 5. Buyer-fabricated IDs

Buyer-fabricated but internally consistent IDs MUST be accepted if they match the request-accepted regex.

Example:

```json
[
  {"role": "user", "content": "Earlier you read a file."},
  {
    "role": "assistant",
    "content": null,
    "tool_calls": [
      {"id": "call_definitelyreal123456", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"fake\"}"}}
    ]
  },
  {"role": "tool", "tool_call_id": "call_definitelyreal123456", "content": "fabricated result"},
  {"role": "user", "content": "Continue"}
]
```

This is buyer-controlled prompt history. The model may believe the fabricated context, but the buyer already controls the request body and pays for the inference. The provider MUST NOT infer from this history that a real provider-side event occurred, MUST NOT retroactively create settlement state for it, and MUST NOT use the fabricated ID as evidence for prior provider work.

## 6. Failure response and malformed-signal interaction

Request-side `tool_call_id` validation failures MUST fail fast with HTTP 400. They MUST NOT run inference and MUST NOT be represented as the response-side §10a #5 `malformed_tool_call` signal.

Rationale: malformed request history is a client/request construction error, not a provider output parse failure. Cline should see a clear request error if it sends an impossible message graph. The §10a #5 structured signal remains reserved for provider-side model-output parsing failures after inference.

The response shape SHOULD follow the existing OpenAI-style error envelope used by macprovider:

```json
{
  "error": {
    "message": "Invalid tool_call_id: role:\"tool\" message at messages[2] references no earlier assistant tool_calls[].id",
    "type": "invalid_request_error",
    "code": "tool_call_id_not_found",
    "param": "messages[2].tool_call_id"
  }
}
```

Normative failure codes:

- `invalid_tool_call_id`: ID missing or format invalid.
- `tool_call_id_not_found`: `role:"tool"` references no earlier assistant `tool_calls[].id`.
- `duplicate_tool_call_id`: the same ID appears in more than one assistant `tool_calls[]` entry, or more than one `role:"tool"` result.
- `tool_call_result_out_of_order`: a `role:"tool"` result appears before its assistant tool call.

All four codes are HTTP 400 `invalid_request_error`. They are request-validation failures and MUST NOT be fault-breaker-qualifying provider failures, MUST NOT commit provider credits, and MUST NOT produce a receipt for inference output because no inference occurred.

Forward compatibility: because the request-accepted regex already permits mixed-case alphanumeric IDs up to 64 suffix characters, a future Cline/OpenAI-compatible client using a different opaque alphanumeric `call_` suffix should continue to resume. If a future client uses characters outside this regex, that is a SPEC-018 compatibility decision requiring a v0.2.x or later regex update; providers MUST NOT silently accept arbitrary unbounded ID strings in v0.2.

## 7. Acceptance criteria and test plan

AC-25. **Format pass cases.** Request validation accepts all of:

- `call_0123456789abcdef` (16 lowercase hex suffix);
- `call_0123456789abcdef0123456789abcdef` (v0.1.5 macprovider suffix);
- `call_RzfkBpJgzeR0S242qfvjadNe` (OpenAI-style mixed-case alphanumeric suffix);
- `call_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789AB` (64-character alphanumeric suffix).

AC-26. **Format fail cases.** Request validation rejects all of:

- `0123456789abcdef` (missing `call_`);
- `call_` (empty suffix);
- `call_short` (suffix below 16 characters);
- `call_0123456789abcde_` (extra underscore);
- `call_0123456789abcde-` (hyphen);
- `call_0123456789abcde.` (punctuation);
- `call_0123456789abcdeé` (non-ASCII);
- `call_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABC` (65-character suffix).

AC-27. **Cross-message pass cases.** Request validation accepts:

- one assistant tool call followed by one matching `role:"tool"` result;
- one assistant message containing N distinct tool calls followed by N matching tool results in any order after that assistant message;
- multi-turn history with M assistant tool-call turns and M matching result batches;
- an assistant tool call with no matching result when no `role:"tool"` message references it.

AC-28. **Cross-message fail cases.** Request validation rejects:

- `role:"tool"` with no `tool_call_id`;
- `role:"tool"` with malformed `tool_call_id`;
- `role:"tool"` referencing an ID that never appears in an earlier assistant `tool_calls[]`;
- `role:"tool"` appearing before the matching assistant tool call;
- duplicate assistant `tool_calls[].id` values anywhere in the request;
- duplicate `role:"tool"` results for the same ID.

AC-29. **Cross-session Cline resume.** A recorded Cline conversation containing macprovider-emitted `call_[a-f0-9]{32}` IDs from one provider process is replayed through a fresh provider process. The provider accepts the request and reaches inference without a minted-ID registry hit.

AC-30. **Fabricated-ID acceptance.** A request with a buyer-fabricated assistant `tool_calls[].id` and matching `role:"tool".tool_call_id`, both matching `^call_[A-Za-z0-9]{16,64}$`, is accepted. The test asserts only request acceptance; it MUST NOT assert or create any provider-minted provenance for that ID.

AC-31. **Multi-turn end-to-end.** A Cline-shaped session with at least M=5 user turns and at least N=2 tool calls in one turn completes through provider + coordinator + gateway. Each tool result references the exact assistant `tool_calls[].id`; IDs are preserved byte-for-byte through transport; no request-side validation error occurs.

AC-32. **Failure response shape.** Each validation failure in AC-26 and AC-28 returns HTTP 400 with `type: "invalid_request_error"`, a stable `code` from the four-code enum above, and a `param` pointing to the offending JSON path.

AC-33. **No malformed-signal confusion.** Request-side validation failures do not include `usage.macprovider_malformed_tool_call` and do not invoke inference. Provider-side malformed model output after inference continues to use the §10a #5 response-side signal.
