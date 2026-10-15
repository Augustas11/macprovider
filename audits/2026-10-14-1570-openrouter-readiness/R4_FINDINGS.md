# R4 findings: SPEC-019 §1a non-strict capability gate

Scope: commit 41125dfc8 (coordinator routes non-strict json_schema only to
provider CLI 1.8.242+) and the fix commit 8eb439d73. Two codex lanes, code and
security. Prompts: `AUDIT_R4_CODE_PROMPT.md`, `AUDIT_R4_SECURITY_PROMPT.md`.

| Lane | Pass | C/H/M/L |
|---|---|---|
| Code | 41125dfc8 | 0/1/1/0 |
| Code | fix verification, 8eb439d73 | 0/0/0/0 |
| Security | 0f57d6a28..8eb439d73 | 0/0/2/0, both marked pre-existing by the auditor |

## Code lane (fixed in 8eb439d73)

- HIGH: a slot-queue waiter re-polls by provider ID, so a same-ID reconnect on
  an older CLI could be dispatched a non-strict request. Fixed: the poll
  re-checks the gate (`forwardState.nonStrictJSONSchema`); an incapable
  reconnect is terminal. Test: `TestNonStrictJSONSchemaRecheckedAtSlotQueuePoll`.
- MEDIUM: a pin to a provider of another model returned the non-strict 400
  ahead of the existing pinned-model error. Fixed: the pinned gate applies
  only to a provider that serves the requested model. Test:
  `TestNonStrictJSONSchemaPinnedProvider`.

## Security lane (pre-existing, carried)

- MEDIUM, pre-existing: `binary_version` is self-reported in the provider
  hello, so a provider could claim 1.8.242 on an older CLI. This is the trust
  boundary every coordinator version gate already uses (#768 per-model floors,
  #1998 conversation-key gate, pool binary floors). A genuine older CLI cannot
  report a newer version. A provider that lies gains nothing: it receives
  requests it then rejects, with zero credit. A malicious provider can already
  fail any request it is sent, whatever its version. The gate is meant to
  stop honest older CLIs from receiving these requests, not to defend against
  a lying provider. Authenticated capability (signed release identity) is the
  general fix and is outside this PR.
- MEDIUM, pre-existing: relay-blind requests are end-to-end encrypted, so the
  coordinator cannot see `response_format` and cannot apply the gate. An older
  CLI rejects a relay-blind non-strict body after decryption, both before and
  after this PR. This is not a deploy-order dependency: the coordinator never
  validated relay-blind bodies, and relay-blind non-strict starts working as
  providers update. A fix needs a buyer-declared capability requirement in the
  relay-blind envelope metadata (follow-up).
