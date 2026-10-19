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
| Codex | Isolated `CODEX_HOME`, generated model catalog | Responses | Launcher requires the parser-validated CLI version 0.163.0. |
| OpenCode | Managed `OPENCODE_CONFIG` with environment-key reference | Chat Completions | Uses the OpenAI-compatible adapter. |
| Goose | Separate `custom_providers/malibu.json` | Chat Completions | Uses its documented custom OpenAI provider. |
| Crush | Isolated XDG configuration with `crushrc` | Chat Completions | Uses its OpenAI-compatible provider. |
| Cursor | Manual Settings handoff | Verify in installed client | Malibu does not edit Cursor's internal settings or claim its API compatibility. |

Codex, Goose and Crush setup requires the gateway to publish a model context
window. The app does not infer that metadata from an alias. Client binaries are
not installed or updated by Malibu. Cursor also routes requests through Cursor
servers; verify custom endpoint/model support in the installed version.

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
