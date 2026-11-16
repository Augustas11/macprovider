# Chat and Connected apps

Related: #2054. These features require a CLI/app release containing the Phase 3
implementation. Merged source alone does not establish release or live acceptance.

## Chat on this Mac

Open **Chat** while the provider has a loaded model. The app discovers the
configured loopback port and checks the current model and local-accounting
capability before sending. It does not choose a cloud fallback or switch models.
Replies stream into the conversation; **Stop** cancels the request. Chats stay in
memory and are cleared when the screen closes or the provider/model changes.

Local use is separate from earnings and coordinator usage. Paying buyers have
priority: a local request can wait briefly, be declined, or stop with
`local_preempted`. A partial reply is not reused as conversation history.
Legacy provenance-only receipts are not settlement receipts and do not make
local inference billable.

**Agent mode** is available only when the loaded model reports guaranteed tool
selection. Choose a folder to allow read, list and text-search tools within that
folder. Tools cannot write files, execute commands or access the network. Each
turn is limited to six rounds, twelve calls and ninety seconds, with bounded
file and output sizes. Symlinks and paths outside the chosen folder are refused.

## Connect a coding agent

Connected apps uses the Malibu buyer gateway. **It is not private:** the gateway
and serving provider can read prompts and responses. Usage is billed to the
buyer account. This is separate from local Chat and provider earnings credentials.

1. Open **Connected apps** and save a buyer API key in Keychain.
2. Load gateway models, choose a client and model, and select its installed CLI.
3. Choose **Preview setup** to inspect the managed configuration and file locations.
4. Choose **Set up**, then **Launch**. The launcher reads the buyer key from
   Keychain and supplies it to that client process.
5. Use **Test endpoint (uses buyer credit)** for a bounded, buyer-funded inference against the
   selected endpoint/model. A successful endpoint test does not certify the
   client's streaming, tool use or conversation behavior.

| Client | Configuration | API | Compatibility boundary |
| --- | --- | --- | --- |
| Codex | Isolated `CODEX_HOME`, generated model catalog | Responses | Launcher still requires the parser-validated CLI version 0.163.0; see Codex 0.168 and later below. |
| OpenCode | Managed `OPENCODE_CONFIG` with environment-key reference | Chat Completions | Uses the OpenAI-compatible adapter. See OpenCode 2.2.6 and later below. |
| Goose | Separate `custom_providers/malibu.json` | Chat Completions | Uses its documented custom OpenAI provider. |
| Crush | Isolated XDG configuration with `crushrc` | Chat Completions | Uses its OpenAI-compatible provider. |
| Cursor | Manual Settings handoff | Verify in installed client | Malibu does not edit Cursor's internal settings or claim its API compatibility. |

Codex, OpenCode, Goose and Crush setup requires the gateway to publish a model context
window. OpenCode config uses the documented model `limit.context` and
`limit.output` fields: the served context and a client output budget capped at
1,024 tokens (or the smaller served context/published output limit). The app does not infer that metadata from an alias. Client binaries are
not installed or updated by Malibu. Cursor also routes requests through Cursor
servers; verify custom endpoint/model support in the installed version.

### Codex 0.168 and later

Codex 0.168.0 added a provider-management API and a default-provider picker.
Codex 0.169.0 lets a user add or edit a custom provider in the TUI. The
launcher above is not yet validated against these versions. Its generated
catalog and version check still target 0.163.0.

What the gateway does for Codex on `/v1/responses`:

- **Spend cap.** When a wallet-session cap is spent, the gateway answers HTTP 400
  with `error.code: "budget_reached"`. Codex 0.168 treats that code as a
  terminal error. A cap blocked only by in-flight reservations keeps HTTP 402
  `wallet_session_exhausted`, because a retry can succeed once they settle.
- **Over-context requests.** The gateway answers HTTP 400 with
  `error.code: "context_length_exceeded"`. Codex 0.169 compacts the history and
  retries on that code.

### OpenCode 2.2.6 and later

OpenCode 2.2.6 reads `store`, `tools.strict`, `streamUsage` and
`promptCacheKey` for the OpenAI-compatible adapter from the model's
`capabilities`. The older config `compatibility` block now maps only
`supportsPromptCacheKey`, `streamUsage` and `supportsEffortUpdates`.
`supportsStrictMode` and `supportsStore` are ignored. Set these options under
`capabilities`, not `compatibility`.

For a host OpenCode does not know, such as Malibu, OpenCode sends `strict: false`
on every function tool, no `store`, `include_usage: true` and no
`prompt_cache_key`.

### Model metadata for models.dev

Keep `freeform` out of any Malibu models.dev entry. OpenCode 2.3.0 sends
freeform tool input to a model that lists `capabilities.freeform`, and the
gateway does not support custom tools yet.

## Restore or change a setup

**Restore setup** removes the managed additions or restores exact original file bytes
when the installed files still match the saved setup. Backups and configurations
are protected user-owned files. Newer edits are preserved: a conflict stops the
restore instead of overwriting them. Restore before changing a managed model or
CLI selection. Existing unrelated client configurations are not rewritten.

**Forget buyer key** removes the Connected apps Keychain item. Restore retains
that key so other managed clients can continue using it. Cursor credentials and
settings must be removed in Cursor itself.

## Release acceptance

The gateway and coordinator must both contain the authoritative ownership guard
before claiming that a buyer cannot route to their own provider. Apply the
coordinator first, then the gateway through the Pearl runtime train, and verify
the resulting pair. A mixed-version pair provides only partial protection.

Before release, retain CI results, the full-diff audit, exact model tool-history
qualification and installed-client protocol checks. A live claim additionally
requires the signed released app/provider and the actual gateway path. Isolated
loopback checks do not prove billing, receipts, settlement or live routing.
