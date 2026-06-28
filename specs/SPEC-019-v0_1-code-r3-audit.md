**Verdict:** READY TO LOCK
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified

- r2 F-1: CLOSED. SPEC §4 now has one normative composite render order:
  construct schema-adjusted `ChatMessage` values, pass that adjusted array to
  `ToolPromptRenderer.renderMessages(...)`, then construct
  `UserInput(chat: rendered, tools: request.tools)` with the original tools
  unchanged (`specs/SPEC-019-structured-output.md:497-516`). AC-22a and AC-22b
  separately cover the empty-tool-history short-circuit and non-empty tool
  history paths (`specs/SPEC-019-structured-output.md:288-301`).
- r2 F-2: CLOSED. `json_schema_invalid_name` now has request-validation AC
  coverage under AC-8a, including provider and coordinator rejection, 65-byte
  names, non-ASCII names, newline/control characters, substring-only bypasses,
  disallowed punctuation, and acceptance of `person-v1`
  (`specs/SPEC-019-structured-output.md:162-189`). §3 makes the anchored
  regex mandatory at provider and coordinator
  (`specs/SPEC-019-structured-output.md:455-463`), and §5 lists the error code
  in the table (`specs/SPEC-019-structured-output.md:615`).
- r2 F-3: CLOSED. The stale `chat_proxy.go:997-1008` citation is gone from §7;
  that range is still `parseChatRequest` in current code, so removal was the
  right fix (`phase5-gateway/internal/router/chat_proxy.go:997-1008`). The
  body-preservation citations now point to the inbound body read and upstream
  request construction from the same `body`
  (`phase5-gateway/internal/router/chat_proxy.go:102-117`,
  `phase5-gateway/internal/router/chat_proxy.go:217-224`;
  `specs/SPEC-019-structured-output.md:709-715`). The provider-error helper
  and predicate are now labeled correctly: `passThroughReceiptEligibleProviderError`
  is `chat_proxy.go:593-599`, and `isNullUsageProviderError` is
  `chat_proxy.go:601-607` (`specs/SPEC-019-structured-output.md:741-746`).

## Fresh findings

None.

## Verdict justification

The §7 gateway citations are grep-verified against current code. `:102-117`
reads and parses the gateway-visible inbound body, `:217-224` builds the
coordinator request from `bytes.NewReader(body)` and forwards headers, `:593-599`
is the receipt-eligible provider-error pass-through helper, and `:601-607` is
the current null-usage provider-error allow-list predicate. The previous stale
`:997-1008` range is no longer cited.

The name-regex byte/character semantics are implementable as written. §3 says
`^[A-Za-z0-9_-]{1,64}$` and describes that as 1-64 bytes. Because every accepted
character in that class is ASCII and therefore exactly one UTF-8 byte, byte
count and character count are equivalent for all accepted names. Non-ASCII input
such as `cafe` with an accented final character is rejected by the character
class before length semantics can diverge.

The empty-content stop-filter citation is correct. §5 cites
`ModelRuntime.swift:811-828`, and that range is exactly `applyOutputFilters`,
including stop-token stripping and request-stop truncation before returning the
final filtered text.

The validator catch-all fallback-code mapping is implementable, but it requires
phase-scoped wrapping rather than one undifferentiated catch at the outermost
postprocess boundary. §5 requires JSON parse internals to map to
`malformed_json_response` and validator internals to map to
`json_schema_validation_failed` (`specs/SPEC-019-structured-output.md:557-568`).
That does not allow a single universal fallback code, but Swift can implement
the mapping by wrapping JSON parsing/duplicate-key checks and schema validation
in separate typed error boundaries before converting to the SPEC-019 envelope.

The §6 depth-counting algorithm is computable in a single traversal of the
schema JSON tree, O(schema bytes). For the probe shape
`{"type":"object","properties":{"a":{"items":{"properties":{...}}}}}`, root
depth is 1, `properties.a` is depth 2, the `items` subtree is depth 3, and any
schema under that `items.properties[*]` is depth 4. Thus an `items` child inside
a `properties[*]` schema increments depth once for the property schema edge and
once for the `items` schema edge, which matches §6's "each nested
`properties[*]` subtree, `items` subtree..." rule
(`specs/SPEC-019-structured-output.md:663-672`).
