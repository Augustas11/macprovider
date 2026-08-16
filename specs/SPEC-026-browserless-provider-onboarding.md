# SPEC-026 — Browserless Provider Onboarding (one-click Launch Provider)

Status: DRAFT v0.26 · Owner: augstar · Target: 2026 Q3

**Change log v0.26 (2026-07-18, required early referral intake).** A fresh
private-prebeta install obtains its referral before release discovery,
autotune, model download, or mutation. Malibu requires the field locally; the
direct interactive installer prompts and creates the same protected source
file, while a noninteractive fresh install without one exits 20. Restart-safe
incumbent updates remain unaffected.

**Change log v0.25 (2026-07-16, SPEC-034 referral recovery).** Referral-gated
onboarding composes with the live CLI `bootstrap-auth`/WS admission path. Malibu
may collect bounded non-secret input, but the signed installed CLI owns the
registration attempt, identity, proof, coordinator exchange, bearer persistence,
restart recovery, and launchd process. `/v1/providers/register`, `RegisterClient`,
App admission signing, `--token-fd`, and an App-managed child MUST NOT be restored.
After registration Malibu attaches to the one launchd provider and reads a
capability-gated sanitized referral projection. Failures preserve a working
identity and return typed retry/correction states.

**Change log v0.24 (2026-07-14, issue #585 Option 2 completion).** The
launchd-managed CLI is the sole runtime authority for provider bearer custody,
registration/bootstrap, admission identity, rotation/recovery, lifecycle state, and
compatibility-set mutation. Malibu no longer contains a registration client or
provider-identity signer and cannot create a provider bearer in production. It may
read a legacy App-Keychain bearer once as migration input, passes it only to the signed
installed CLI's import/verify transaction, and deletes/verifies the legacy item after
CLI custody is proven. CLI-authenticated earnings are projected over the owner-only
read-only control socket, so no compatibility bearer remains in Malibu. Durable legacy
principal migration preserves provider ID, billing ownership, and history through the
generation-CAS admission identity plus bounded previous-key rollback and exact-bound
dual-control loss recovery. **All earlier statements below describing an App identity,
App registration client, App admission signer, retained App compatibility bearer,
Sparkle release, or independent App update path are historical and superseded by
v0.24.** The signed two-Mac restart/reboot/logout/locked-Keychain matrix, interruption
drills, temporary-exemption exit, #584 canary, and 24-hour soak remain mandatory
external rollout evidence.

**Change log v0.23 (2026-07-14, issue #585 admission-identity rotation).**
The CLI-owned admission identity is now restart-safe but rotatable: the stable legacy
Keychain service remains the current slot, with separate pending and bounded previous
slots. `macprovider-cli credentials rotate-admission-identity` stages one idempotent
candidate, takes the maintenance lease, restarts the launchd provider, and requires a
fresh buyer-serving proof before reporting success. The current key signs the complete
initial transcript containing `provider_admission_next_public_key`; the coordinator
performs an exact-bearer/current-key/generation CAS, retains the previous public key for
seven days, and returns the authoritative active key plus generation. A lost response
therefore converges on restart without permitting bearer-only replacement. Full
Keychain loss and dormant App/Postgres custody use the explicit, audited, dual-control
operator recovery transaction in §4.3; unknown or revoked bindings otherwise fail closed.
This change log supersedes v0.18/v0.19 descriptions of the admission key as non-rotating.

**Change log v0.22 (2026-07-14, issue #585 Option 2 credential-custody
slice).** The shipped CLI-track onboarding now hands the bearer to CLI-owned Keychain
storage while Malibu retains YAML. Import calls the installed
`macprovider-cli credentials import --config` and then a separate
`credentials verify --config` against one immutable snapshot; the second process's
exact-value proof permits the App marker/link transition but not YAML removal. A
restarted launchd provider removes YAML only after authenticated coordinator admission.
Failure preserves the original 0600 YAML. Existing token-bearing migrations retain a
temporary App-Keychain compatibility copy, while fresh tokenless bootstrap keeps the
bearer exclusively in CLI Keychain. A provider-ID-bound App-local custody marker is
required whenever that compatibility copy exists. The exact shipped
tokenless-YAML/App-only incident state restores its bearer to private YAML before the
ordinary handoff, and backup deletion is confirmed before the journal is retired.
Removing Malibu's residual direct earnings-token dependency belongs to issue #585's
later versioned-status transaction.
Option 2 also removes the compiled-but-unreachable App identity-signature responder,
the two local control-socket frames, and the CLI bridge timeout. Admission proof
signing is exclusively a CLI-owned Keychain operation; Malibu neither receives auth
transcripts nor signs coordinator admission proofs.
This v0.22 rule supersedes historical v0.17 best-effort backup-cleanup notes.

**Change log v0.21 (2026-07-13, R8 audit-loop convergence — code source of truth;
architect lane PASS 0/0/0).** R8 (code 0C/0H/1M, security 0C/0H/1M, architect
**0C/0H/0M**). Two narrow fixes: **§10 self-consistency** — the banner/conclusion now
acknowledge §4.3 `identity_signature` verification IS step 7 of this checklist (deployed
→ **LIVE**, gating CLI-track `mp-*` admission), while §4.1 register + §5.3 App Attest are
the CLIENT-DORMANT contracts; dropped the "onboarding that this checklist gates" wording
(the checklist gates the coordinator backend rollout, not the onboarding flow — which
nonetheless depends on the live §4.3). **Watchdog nuance** — the companion watchdog is a
no-op restart for *routine* health failures (KeepAlive handles those), but it DOES
force-restart the provider service during **auto-update rollback recovery** (`launchctl
kickstart`, `install.sh:4086,4113`); the earlier "never restarts" was too absolute.

**Change log v0.20 (2026-07-13, R7 audit-loop convergence — code source of truth).** R7
(code 0C/2H/3M, security 0C/1H/1M, architect 0C/0H/2M). The re-fired security lane
(vindicating the money-path re-audit) caught that the v0.19 §4.3-live reframe was
INCOMPLETE — §10 still contradicted it. **Fixes:** §10 opening banner scopes the
client-dormant surface to **§4.1 register + §5.3 App Attest only** (§4.3 is live, not
gated by this checklist); §10 conclusion "no §4 dependency" → "no §4.1/§5.3 dependency
(live §4.3 dependency remains)". **New HIGH:** §4.3 in-band receipt-key rotation is
available **only to durable `mp-*` bootstrap principals** — a legacy principal (no
durable row) is admission-verified by receipt-key byte-equality, so a rotating frame
carrying a NEW key is rejected before staging (`identity_signature.go:149-160`); legacy
principals must re-provision, not rotate in place. **Fidelity:** receipt key is generated
during `bootstrap-auth` (before first `serve`), not on first serve; the dormant
App-responder frame's `binary_version` MUST be a string (numeric fails closed); the
companion watchdog does **not** restart the CLI (no-op — `install.sh:3575`), the provider
service `KeepAlive` does; auth citations corrected `server.go:1210`→`:1216`.

**Change log v0.19 (2026-07-13, R6 audit-loop convergence — code source of truth;
security lane PASS 0/0/0).** R6 (code 0C/1H/3M, security **0C/0H/0M**, architect
0C/0H/3M). The HIGH was an over-statement of dormancy: **§4.3 `identity_signature` is
LIVE via the CLI track** — the `macprovider-cli` the app monitors signs it with its
stable **bootstrap identity** for `mp-*` admission (`CoordinatorClient.swift:1842`,
`identity_signature.go:127`, `server.go:1216`), only the App-side `p_*` responder is
dormant. Corrected the §4 scope banner, §10 checklist ("gates §4.1 register + §5.3 App
Attest only; §4.3 auth-policy is already live"), §3.2 table (bootstrap-identity distinct
then-described non-rotating lifecycle; superseded by v0.23), and the v0.14 changelog note. **Fidelity:** §4.3 legacy fallback
resolves the receipt pubkey from the **live provider registry** (`currentReceiptPubkey`
→ `s.pool`), not a nonexistent `LookupCurrentPubKey` helper — requires a live pool entry;
§6.2 routing is evaluated **once per app launch** (not a continuous auto-reopen watcher,
`MalibuApp.swift:21,115`); §3 banner names the **provider service + companion watchdog**
(three launchd registrations, SPEC-025 §8).

**Change log v0.18 (2026-07-13, R5 audit-loop convergence — code source of truth).** R5
(code 0C/1H/3M, security 0C/1H/1M, architect 0C/1H/2M) surfaced the last cluster: the
v0.17 "corrected everywhere" claim was premature — 4 twins still tied `mp-*` proof to
the rotatable receipt key. **Grep-verified sweep (zero unqualified receipt-key-as-identity
sites remain):** §3 banner, §3 table, §4.1, §4.3 `identity_signature` field def, and §6.1
step 7e now all state that the durable `mp-*` admission identity is the **bootstrap
identity** — described in that revision as a stable, non-rotating snapshot of the first receipt key in slot
`com.malibu.provider.bootstrap-identity-key` (`ReceiptKeyStore.swift:23,66`;
`identity_signature.go:127`) — while the rotatable `.receipt-key` signs receipts and is
only a legacy verify fallback. §3 table now lists all three Keychain services with
lifetimes. **Fidelity:** startup-route table adds the two missing fallback routes
(configured-but-no-launchd-evidence, launchd-evidence-without-config →
`.showOnboarding`); §8 historical/live boundary marked (live scope resumes at §8.4);
§11 "flag flip" → "ship the release". (SPEC-025 v0.6: §3.3 BSDiff-delta twin, Keychain
full names, `.pkg`/`hdiutil` distribution facts.)

**Change log v0.17 (2026-07-13, R4 audit-loop convergence — code source of truth).** R4
(code 0C/2H/6M, security 0C/2H/3M, architect 0C/0H/5M) caught remaining stale twins of
the v0.16 fixes. **Money-path:** §4.3 corrected everywhere — new CLI `mp-*` proofs use
the stable **bootstrap identity** (not the receipt key) via principal-branching
(`identity_signature.go:118-159`), and rotation **commits on the first accepted
`state_update`** then starts the grace window for the old key (`provider.go:839,1753`)
— NOT "commit after grace" (§4.3, AC-026-12, changelog rule aligned); wallet
binding/swap SPEC-027-gated in §9.2 + AC-026-06 too (uniform `501`). **Fidelity:**
token-backup deletion documented as best-effort/may-persist (§2/§8.4 aligned to §7);
"coexists unchanged" carries the import token-custody caveat; retry short-circuits when
healthy (not unconditional rerun); receipt-key Keychain coordinates corrected
(`com.malibu.provider.receipt-key`, account `<provider_id>` — not
`tech.malibu.receipt`/`receipt_key_v1`); §6.2 auto-reopen covers the missing-launchd
route; App Attest AAGUID non-enforcement documented as a carried coordinator gap. (See
SPEC-025 v0.5 for the app-side bundle/distribution/Sparkle reconciliations.)

**Change log v0.16 (2026-07-13, R3 audit-loop deep-tail convergence — code source of
truth).** R3 (code 0C/2H/7M, security 0C/2H/2M, architect 0C/0H/4M) caught the tail of
the v0.15 sweep, including two self-inflicted items: the App Attest JCS member was
renamed `ts_utc_unix` (a NEW hash mismatch — coordinator keeps member `ts_utc`, only the
VALUE is Unix seconds; reverted), and §4.3 rotation was over-corrected. **Money-path
(rewritten against code):** §4.3 `identity_signature` is verified against a **stable**
identity selected by principal type — bootstrap identity for `mp-*`
(`identity_signature.go:118-159`), stored receipt key for legacy — never the proposed
key, and the new receipt key rotates **in-band** (staged/committed, `provider.go:779,839`);
§4.2/§4.5/§9.3/§10-step4 wallet binding+swap uniformly **SPEC-027-gated `501`** (no
interim EIP-712 path); App Attest degrades **only** on transient/missing evidence
(shipped verifier returns `(true,nil)` on success, typed error otherwise —
`appattest.go:127,144`). **Fidelity:** §6.4/§7.2 retry re-enters `launch()` from start;
§6.1 restart routing dispatches per §8 table (not unconditional `install.sh` rerun);
§9.1 reinstall keeps the `mp-*` principal unless clean-wiped (`install.sh:2484-2506`);
§8.4 disk token is NOT "redundant" (launchd reads bearer from `config.yaml`,
`install.sh:3425`); §10 checklist gates the designed §4 surface, not the already-live
onboarding; §0 `provider_id` `p_*` dormant qualifier; AC-026-16 exercises the
unused-token case.

**Change log v0.15 (2026-07-13, R2 audit-loop straggler sweep — code source of truth).**
The v0.14 reconciliation stated the correct fail-closed rules in the v0.13 change-log
changelog but left the §4 body and several live sections carrying pre-hardening /
pre-#418 prose. The R2 codex 3-lane audit (code / security / architect) surfaced the
tail; v0.15 sweeps it. **Security money-path:** §4.1 duplicate-register now requires
current-bearer proof for **any** active token (no never-handshaked bypass, matching
`tokens.go:945-975`); §4.3 receipt-key rotation `identity_signature` is verified against
a **stable** identity selected by principal type (bootstrap identity for `mp-*`, stored
receipt key for legacy — `identity_signature.go:118-159`), never the proposed new key,
and the new key is staged/committed **in-band** (`provider.go:779,839`); §4.2 wallet binding carries a **SPEC-027-gated /
`501`** banner (not live EIP-712); App Attest **rejects** malformed/binding/invalid
evidence (`400`/`409`) and degrades **only** transient failures (`apptrack.go:346-388`);
the §5.3 hash algorithm now hashes `ts_utc` as **Unix seconds** (`apptrack.go:518`).
**Dormant App-track apparatus** marked outside banners: §0 identity key, §1.1 success
criteria, §4.1 caller (shipped uses `bootstrap-auth`/WS admission, NOT §4.1 register),
§6.1 step 3, §6.2, §7.1 module, §7.6, §9.1 reinstall, §10 deploy-gate framing.
**Shipped-fidelity:** §1.1 resumable claim, §6.4 retry-from-scratch + all-retryable,
§6.1 success-card static counters, AC-026-02 installer-string exception, §8 route-row 2,
§8.4 3-arg `saveProviderIdentity`, `Downloads/` capitalization, key-custody wording.

**Change log v0.14 (2026-07-13, CLI-wrapper client-architecture reconciliation — spec
matched to shipped code; code is source of truth):** The **CLI-wrapper refactor (PR
#418, 2026-07-06)** replaced the in-app onboarding client. The v0.1–v0.13 §6.1/§7.2
in-app **register → autotune → spawn-child** flow is gone: `LaunchProviderController`
now runs the bundled CLI-track **`install.sh`** (which registers, autotunes, downloads
the model, and installs the launchd provider service + companion watchdog) and
`MalibuAgent` **monitors** the launchd-managed `macprovider-cli` over local HTTP — it
does not spawn a child.
`RegisterClient.postRegister` and the `MALIBU_ONBOARD_V2` flag are gone from the live
path (so §8's migration matrix and AC-026-09 no longer apply). v0.14 rewrites §6.1 /
§7.2 / §7.5 / §7.6 / §8 to the shipped model and marks the removed pieces as shipped-
removed. **The coordinator API (§4) still conforms** — App-track `/v1/providers/register`,
App Attest team/bundle pins, `identity_signature`, and the wallet-change `501` are
unchanged *as coordinator contracts*; but §4.1/§4.3 now note that the **client** that
exercises them moved: registration is done by `install.sh`/the CLI (not the app), and
the app's per-auth `identity_signature` responder has **no wired transport** in the
monitor-only flow (present but unreachable — a carried gap, §4.3).

**Deeper reframe (reconciled v0.14, after the codex audit — the App-track client
apparatus is DORMANT).** The shipped Malibu app does **not** create the App-track
device `p_*` Ed25519 identity, does **not** call `/v1/providers/register`, and does
**not** perform App Attest or App-`p_*` identity signing at runtime. (Reconciled v0.18:
the `macprovider-cli` the app monitors DOES sign `identity_signature` with its stable
bootstrap identity for `mp-*` admission — a LIVE §4.3 dependency; only the App-side
`p_*` responder is dormant. See the §4 scope banner.) Instead,
`install.sh` onboards a **standard CLI-track provider**: it generates a fresh
`mp-<32-hex>` principal and runs `macprovider-cli bootstrap-auth`, which acquires a
`provider_token` via the coordinator's **tokenless WebSocket admission** handshake
(`install.sh:2484-2505,3112-3125`; `BootstrapAuthCommand.swift`;
`CoordinatorClient.swift:569-575,1989-2056`). Bootstrap persists that bearer directly
to the installed CLI's separate Keychain service; Malibu verifies custody through a
fresh installed-CLI process and then monitors it. Only an existing token-bearing YAML
migration also creates the temporary App-Keychain compatibility copy. The
App-track `p_*` identity
(`ProviderIdentity`), `RegisterClient.postRegister`, App Attest, and the
`identity_signature` responder all **compile** and the coordinator-side contracts (§4)
still **conform**, but **no shipped client path exercises them** — they are a
designed-but-client-dormant surface. v0.14 therefore reframes §3 (identity model),
§4.1 (register caller), §4.3 (identity-signature), and §5.3 (App Attest) as
**coordinator-contract / client-dormant**, and documents the real CLI-track credential
flow in §6.1. It also records shipped **gaps** the audit surfaced: the token-import
strips the bearer from `config.yaml` (breaking a launchd CLI restart, §6.1); "Quit and
Uninstall" is compiled but **unreachable** (drag-to-trash leaves the launchd CLI, §6.5);
the installer env is **not** sanitized (§6.1); the in-app CLI-updater is unwired (only
Sparkle updates the `.app`). No code change. **See the paired SPEC-025 v0.2** (same PR
#418 reconciliation, app-shell side).

Earlier honesty note (2026-07-10): flagged the same supersession pending this revision.

**Numbering:** earlier revisions of this spec referred to the MALIBU rewards
emission ledger by the number 028. That was a mislabel — the number 028 belongs
to the unrelated MLX speculative-decoding spec (`specs/SPEC-028-mlx-speculative-decoding.md`)
— so every emission-ledger reference below now points to canonical **SPEC-021**
(`specs/SPEC-021-malibu-emission-ledger.md`).

## Change log

**v0.13 (2026-07-04, Wave 2 token-custody hardening).** Wave 2
keeps App-track wallet and non-bearer proof surfaces fail-closed
until SPEC-027 exists:

- **App-track wallet changes are blocked pending SPEC-027.**
  `POST /v1/provider/wallet` MUST return
  `501 {"error":"wallet_change_requires_spec_027"}` for App-track
  providers until SPEC-027 defines the required non-bearer proof and
  cancellation semantics.
- **CLI-track receipt-key rotation proof is stable-identity signed.**
  Rotation requests MUST prove control of a stable prior credential —
  the durable **bootstrap identity** for `mp-*` bootstrap principals, or
  the currently-published receipt key for legacy principals (§4.3). A
  signature that verifies only against the proposed replacement key is
  self-declared proof and MUST be rejected.
- **WebSocket `identity_signature` challenge excludes the signature
  field.** The coordinator challenge is the pre-auth
  `auth_challenge`; the response signature covers the retained initial
  transcript plus the coordinator challenge and MUST NOT include the
  signature value itself in its own signed input.
- **App Attest pins are required when App Attest evidence is present.**
  The coordinator MUST reject App Attest verification when the Malibu
  team ID or bundle ID pin is unset; production pins are loaded from
  deployment config and must match the Malibu app identity.
- **Provider-token custody is fail-closed.** Tokenless reconnects MUST
  NOT revoke or replace an existing `provider_tokens` row. Mutation
  requires proof of the existing token or an operator recovery action.

**v0.12 (2026-07-03, Step-2 build-prompt audit closure).** The Step-2
implementation prompt audit found that v0.11 still promised
flag-off SPEC-025 browser-OAuth parity while §7.3 simultaneously
retired the `malibu://` URL scheme and `PendingLinkState` machinery
that the old browser-OAuth path used. v0.12 closes the
implementation contradiction:

- **Fresh flag-off behavior no longer invokes SPEC-025 browser OAuth.**
  Fresh installs with `MALIBU_ONBOARD_V2=0` show a local setup-paused
  state and do not invoke a browser tab, portal URL, URL scheme, or
  `PendingLinkState`. Existing configured v1 installs continue to run
  because `MalibuAgent.start()` still gates on `ProviderConfig.isConfigured`.
- **AC-026-09 retargeted to rollback safety.** It now verifies env-var
  precedence, default-off behavior, and absence of retired URL-scheme
  invocation, not byte-for-byte fresh-install browser-OAuth parity.
- **§8.2/§8.3 aligned with URL-scheme retirement.** Rollback to flag-off
  does not restore the deleted browser flow for fresh installs; it only
  preserves already configured installs and auto-presents v2-partial
  installs for completion.

**v0.11 (2026-07-03, adversarial + product-design critique
closure pass).** After R10 audit converged, Claude adversarial
verification (`critic` agent) and product-design critique
(`designer` agent) fired against v0.10 in parallel as a
last-call check. Combined result: 0/0/5 MEDIUM (critic 0/0/2 +
designer 0/0/3). v0.11 closes:

- **Entry 102 stale wording purged (critic MEDIUM-1).** v0.10
  left "v0.9" references, "three rounds of 3-lane codex audit"
  understatement, and "eight round audit files (r1..r8)" count
  in Entry 102 even after v0.10 shipped. v0.11 bumps every
  version reference to v0.10 in Entry 102 body, updates round
  count to "nine rounds," inventory to "nine round audit
  files (r1..r9)," and adds per-round stanzas for R7 (0/4/8),
  R8 (0/0/5, first 0-HIGH round), R9 (0/0/4).
- **v0.10 change-log inventory bump corrected (critic
  MEDIUM-2).** v0.10 said "bumped … to eight round audit files
  (r1-r8)" but SPEC-026-r9-audit.md already existed as the R9
  disposition file. v0.11 fixes the sentence to "nine round
  audit files (r1..r9)."
- **§6.1 step 8 success card + §6.2 unbound-wallet backlog
  visibility (designer MEDIUM-2).** v0.10 had the payout-wallet
  row as a small sub-row on the success card, and §6.2 steady
  state made no normative statement about resurfacing unbound
  backlog. A first-run user closes the window on animated
  counters and never learns their earnings are unclaimed. v0.11
  rewrites §6.1 step 8 to give the "Add wallet" affordance
  equal visual weight to the counters when unbound, and adds
  a §6.2 normative requirement: once
  `unpaid_ledger_backlog_usdc + unpaid_ledger_backlog_malibu`
  crosses a "worth mentioning" threshold ($1 USDC-equivalent),
  the menu-bar icon MUST carry an "unclaimed earnings" badge
  until a wallet is bound.
- **§6.2 non-withdrawable MALIBU persistent state (designer
  MEDIUM-3).** v0.10 only mentioned "non-withdrawable" once on
  the first success card. A user coming back on day 7 with
  175 MALIBU on a counter experiences "can't withdraw" as a
  bug. v0.11 §6.2 requires: whenever a MALIBU balance is
  displayed while the provider is Provisional, the display
  MUST carry a lock icon + microcopy "unlocks at Trusted"
  visually adjacent to the number. Both dashboard and menu-bar
  count elements.
- **Entry 102 launch-readiness note for landing-page (designer
  MEDIUM-1).** The `/Users/augstar/projects/malibu/host/index.html`
  landing page still sells the CLI flow (curl|bash, "Sign in
  with GitHub", "You're a node") — vocabulary AC-026-02
  explicitly forbids inside the App. Not SPEC-026's normative
  surface (SPEC-025 owns landing-page), but v0.11 Entry 102
  adds a launch-readiness note: the landing page MUST ship
  App-track copy in lockstep with §10 step 9's Sparkle
  release, or AC-026-02 fails at the marketing surface even
  if the App-side copy is clean.
- **§4.1 step 7 `provider_name` column added (critic Minor-1
  promoted to fix).** `provider_tokens` DDL has
  `provider_name TEXT NOT NULL` between `token_prefix` and
  `created_at`; v0.10 §4.1 step 7 enumeration omitted it. The
  App-track mint SQL will hit a NOT NULL constraint failure
  without a value. v0.11 §4.1 step 7 adds
  `provider_name = "malibu-app"` as the App-track literal to
  supply.
- **§6.1 step 7c "freshly-minted identity" ambiguity resolved
  (critic Minor-3).** v0.10 wording could be read as the App
  passing the Ed25519 identity key to SPEC-023 autotune. v0.11
  clarifies: SPEC-023's own HMAC-derived diversification
  identity is used, distinct from and unchanged by SPEC-026's
  Ed25519 identity key. The identity key never leaves the
  Keychain per §3.1.

**v0.10 (2026-07-03, R9 targeted wording pass).** R9 SEC + ARCH
each landed 0/0/2 MEDIUM against v0.9. Both lanes converged on
the same three issues (Entry 102 stale wording + §6.2/§9.3
alignment). v0.10 fixes:

- **Entry 102 email-active wording fully purged.** Deleted the
  residual "Wallet-swap coercion is defended by a REQUIRED
  out-of-band coordinator-authored email channel" sentence and
  the "Wallet swap MUST fail closed on unverified email …
  HMAC-signed via LoadCredential" paragraph. Entry 102 now
  states only SPEC-016 preservation + SPEC-027 pointer.
- **Entry 102 9-step deploy checklist enumerated correctly.**
  Was "8 steps: schema → … → Sparkle release"; v0.10 is
  "9 steps: schema → … → MALIBU emission stance → Sparkle
  release / flag flip" with step 8 explicitly called out as
  mandatory.
- **§6.2 and §9.3 now use IDENTICAL "MUST NOT add a Cancel
  affordance" wording** to prevent an implementer reading only
  one section and adding a Cancel button.
- **Entry 102 audit-file inventory bumped** from "seven round
  audit files" (r1-r7) to "nine round audit files" (r1-r9)
  (the SPEC-026-r9-audit.md file already existed and describes
  the R9 findings v0.10 closed; the v0.10 change log incorrectly
  said "eight round audit files" and was corrected in v0.11).

**v0.9 (2026-07-03, R8 cleanup pass).** R8 was the first round
with 0 HIGH: 0/0/5. v0.9 targeted fixes for the 5 MEDIUMs:

- **§6.1 step 7j removed (ARCH MEDIUM).** v0.8 still opened the
  SPEC-016 EIP-712 signing flow inline during onboarding if the
  user filled the optional payout-wallet field on the launch
  window. That contradicts §1.1 "No wallet-signing prompt"
  success criterion and §1.2 non-goal wording. v0.9 removes the
  optional wallet field from the launch window entirely; wallet
  binding lives on the post-success dashboard "Add wallet" link
  only, per the post-onboarding wallet-signing UX invariant.
- **§9.3 pre-SPEC-027 Cancel bullet removed (ARCH MEDIUM).**
  Local UI "Cancel" action needs backend semantics that only
  SPEC-027 provides; v0.9 removes the pre-SPEC-027 Cancel
  bullet. Local read-only display of a pending swap remains
  acceptable but not required.
- **Entry 102 email-active wording replaced (SEC + ARCH MEDIUM).**
  v0.8 Entry 102 had residual wording describing email/HMAC/
  fail-closed as active in SPEC-026 while also saying "SPEC-026
  does not cover them." v0.9 reformulates the moved-out
  primitives as "SPEC-027 will own/require …" and leaves
  SPEC-026's active surface as SPEC-016 preservation +
  pointers.
- **§10 step-count references corrected (ARCH LOW).** v0.8 §10
  step 1 still said "SPEC-026 v0.7 schema migrations"; Entry
  102 still said "ordered 8-step deploy checklist" though §10
  now has 9 steps. v0.9 fixes labels.
- **AC-026-16 added for bearer-proof duplicate-register (SEC
  MEDIUM).** Verifies the §4.1 same-identity duplicate flow
  correctly rejects without bearer / with wrong bearer, and
  reissues with correct bearer.

**v0.8 (2026-07-03, R7 cleanup pass).** R7 3-lane codex audit
against v0.7 landed 0/4/8 (mostly drift from the R6 scope
reduction). v0.8 targeted fixes:

- **§4.1 duplicate-register token proof mechanism corrected (CODE
  HIGH).** v0.7 required `current_token_proof = HMAC-SHA256(current_provider_token, ...)`,
  but `provider_tokens` stores only `token_hash`, not the
  cleartext bearer. Coordinator cannot recompute the HMAC. v0.8
  drops the HMAC scheme and requires the request to carry the
  raw bearer via HTTP
  `Authorization: Bearer <current_provider_token>` on the
  `/register` call itself (in addition to the request-body
  signature). v0.12 removes the App-track JSON-body bearer path
  so signed JCS bodies never contain bearer material.
  Coordinator SHA-256 hashes the provided cleartext and compares
  against `token_hash` on the active row.
- **§4.1 SQLite locking corrected (CODE MEDIUM).** v0.7 used
  `SELECT ... FOR UPDATE`, but the `provider_tokens` store is
  SQLite (which doesn't support that). v0.8 replaces with
  `BEGIN IMMEDIATE` + explicit atomic `UPDATE`/`INSERT`
  semantics keyed off the existing partial unique index.
- **§4.3 `version` type in JSON example (CODE MEDIUM).** v0.7
  showed `"version": "2"` as a string; SPEC-001 v1.6 §6.7
  requires int `2`. Fixed.
- **AC-026-06 rescoped to SPEC-016 preservation only (CODE +
  ARCH HIGH).** v0.7 still required the moved-out email
  channel + `notification_email` + retries. v0.8 shrinks
  AC-026-06 to "SPEC-016 §3 wallet-swap semantics are
  preserved unchanged; all App-track out-of-band cancellation
  is covered by SPEC-027 acceptance criteria, not
  SPEC-026." AC list gains AC-026-15 for §8.4 import dialog.
- **§7.3 `malibu-app://` registration removed (ARCH HIGH).** v0.7
  still directed the impl PR to add the deep-link scheme. v0.8
  deletes that requirement — SPEC-027 owns any deep-link
  scheme its email flow needs.
- **§6.2 pending-swap Cancel UI made SPEC-027-owned (ARCH
  MEDIUM).** v0.7 §6.2 normatively required an App-track
  Cancel action on the pending-swap row, but the corresponding
  backend contract lives in SPEC-027. v0.8 makes §6.2 say the
  App-track pending-swap display is deferred to SPEC-027; no
  guarantee is offered by SPEC-026.
- **§10 + §11 MALIBU-until-SPEC-021 gate (SEC HIGH).** v0.7
  allowed the App-side flag flip without a normative MALIBU
  gate. v0.8 adds an explicit deploy-checklist gate: the
  App-side flag flip MUST NOT enable withdrawable MALIBU
  emissions until EITHER SPEC-021 ships OR the operator has
  configured a hold mode that prevents any MALIBU withdrawal
  before Trusted unlock. §11 sybil-defense narrative gains a
  qualifier: the stack is coherent only after SPEC-021 or an
  equivalent normative hold is live.
- **§1.2 wallet-signing non-goal wording tightened (ARCH LOW).**
  Rewritten to make clear that only the wallet-signing UX
  DURING onboarding is a non-goal; post-onboarding wallet
  binding does compose with SPEC-016 §3 EIP-712.
- **§8.4 references AC-026-15 (ARCH LOW).** Added as
  acceptance criterion.
- **Entry 102 fully rewritten (all three lanes MEDIUM).** v0.7
  Entry 102 still had residual wording about email fail-closed
  + HMAC cancel URL being active in SPEC-026; v0.8 states
  SPEC-026 explicitly does NOT cover those and points at
  SPEC-027 / SPEC-021 / SPEC-016 addendum for each moved-out
  primitive.

**v0.7 (2026-07-03, R6 scope-reduction pass).** R6 architect flagged
that v0.6 bundled too much implementation surface for a single
onboarding SPEC — identity + register + auth-policy + verified-email
channel + GET/POST cancel URLs + `provider_wallet_swaps` addendum
+ Postgres projection + WAL replication + rewards-ledger extension
+ per-wallet emission aggregate — with each new subsystem introducing
attack surface for the next audit round. R6 also surfaced a subtle
attack on the fresh-install ratification EIP-712 (opaque hash
display) that reinforced the concern that the scope had outgrown
one spec.

**v0.7 rescopes.** SPEC-026 keeps App-track identity, `/register`,
proof-stage `identity_signature` + `provider_auth_policy` auth
policy, App Attest, `PendingLinkState` deletion, "node" → "provider"
rename, migration matrix, and the sybil-defense narrative. Three
subsystems are extracted to follow-up SPECs, referenced by name
but not defined here:

- **SPEC-016 §3 addendum for `provider_wallet_swaps`** — provider
  wallet-swap intent table with `pending → committed |
  cancelled_by_* | delivery_failed` state machine and atomic
  commit into `provider_payout_addresses`. Owned by the SPEC-016
  team; the addendum PR is a blocking follow-up for enabling
  App-track wallet-swap notifications.
- **SPEC-027 (App-track wallet-swap coercion defense)** —
  verified-email out-of-band cancellation channel: the
  `notification_email` column, `provider_email_change_requests`
  table, three-path channel-authority transfer, `malibu-app://`
  deep-link scheme, `POST /notification-channel` + verify /
  approve / reject actions, HMAC-signed cancel URL, GET
  confirmation + POST mutation split, EIP-712
  `EmailChangeAuthorization` domain, fresh-install
  re-ratification at first wallet bind. All the R4-R6 audit
  findings on this surface stay open against SPEC-027, not
  SPEC-026. This SPEC gains only a §9.3 pointer.
- **SPEC-021 (MALIBU rewards emission ledger)** —
  `provider_rewards_ledger` MALIBU extension
  (`amount_malibu` + `withdrawal_hold_reason`), the
  `wallet_daily_malibu_emission` aggregate under SERIALIZABLE
  isolation, `provider_emission_state` cross-track table,
  Postgres projection of SPEC-016 `provider_payout_addresses`,
  WAL replication worker + staleness monitoring, replay-through-cap
  at bind time. SPEC-026 §5.1 keeps only the sybil-defense
  narrative (non-withdrawable, per-wallet cap, replay at bind)
  and delegates enforcement primitives to SPEC-021.

**Ordering.** SPEC-026 v0.7 can merge and its `/register` +
proof-stage auth can ship without SPEC-027 or SPEC-021. What
does NOT ship without them:

- Provisional MALIBU emissions cannot be honored as
  non-withdrawable until SPEC-021 ships; before that, all
  provisional providers are effectively pre-Trusted (or
  emissions are held in an ad-hoc coordinator hold outside the
  spec). SPEC-021 SHOULD land before real MALIBU flow starts.
- Wallet-swap coercion defense (App-track) is not covered until
  SPEC-027 ships. SPEC-016 §3 EIP-712 wallet proof-of-possession
  still provides the underlying protection; App-track UI (email
  channel, in-band cancel) is deferred.

The R6 SEC HIGH (opaque-hash ratification EIP-712) is now
against SPEC-027, not SPEC-026, and MUST be closed there before
SPEC-027 merges. The R6 ARCH HIGH #1 ("currently-bound wallet"
ambiguous during in-flight rotation) is against SPEC-027 too.
The R6 ARCH HIGH #2 (spec too big) is closed by this split.

**v0.6 (2026-07-03, R5 audit-loop cleanup pass).** R5 3-lane codex
audit landed 0/1/11. All targeted fixes:

- **§9.3 fresh-install email expiry (SEC HIGH).** v0.5 allowed the
  fresh-install `confirm` step to grant durable email authority.
  Attacker with bearer+identity access on a fresh Mac could set
  their email, confirm directly, and remain authoritative even
  after the honest user later binds a wallet. v0.6 requires the
  fresh-install email to be re-ratified via a currently-bound-wallet
  EIP-712 signature at the moment of the FIRST wallet bind or the
  FIRST wallet swap ≥ $500, whichever comes first. Until
  re-ratification, the fresh-install email cannot cancel a swap
  above the fail-closed threshold.
- **§2 grounding text updated to proof-stage.** v0.4 changelog
  fixed the JSON example; §2 grounding still described adding
  `identity_signature` to the initial-stage frame. v0.6 fixes.
- **§4.5 / §7.3 `malibu-app://` URL scheme registration.** v0.5
  referenced `malibu-app://` deep links but SPEC-025 §3.4
  registers only `malibu://`, and v0.4 §7.3 deletes that. Two
  paths were available: (a) register a new scheme, (b) keep
  `malibu://` and use path-based dispatch. v0.6 picks (a):
  `Info.plist` `CFBundleURLTypes` MUST register `malibu-app` as
  a new scheme with handlers for `verify-email`,
  `approve-email-change`, and `reject-email-change` action
  paths. `malibu://` is still deleted per §7.3.
- **§10 Phase 1a schema list adds `provider_email_change_requests`.**
  Missing DDL — v0.6 lists it.
- **§4.3 `approved_by != requested_by` constraint mechanism
  corrected.** v0.5 said UNIQUE constraint, but UNIQUE compares
  rows, not columns. v0.6 uses a Postgres `CHECK` constraint:
  `CHECK (approved_by IS NULL OR approved_by <> requested_by)`.
- **§5.1 `cap_replay_pending` moved to cross-track table.** v0.5
  put it on `provider_identities` (App-track-only), but CLI-track
  providers can also bind wallets via SPEC-016 §3. v0.6 introduces
  `provider_emission_state (provider_id PRIMARY KEY,
  cap_replay_pending BOOLEAN NOT NULL DEFAULT FALSE, ...)` as a
  cross-track table.
- **§5.1 Postgres/SQLite consistency for wallet-cap enforcement.**
  v0.5 had `wallet_daily_malibu_emission` in Postgres joining
  `provider_payout_addresses` which lives in SPEC-016's SQLite DB.
  v0.6 introduces a Postgres projection of
  `provider_payout_addresses` maintained by a replication worker
  that reads the SQLite DB's WAL; the wallet-cap transaction reads
  ONLY from the Postgres projection. The projection carries a
  monotonic `last_synced_seq` and readers must not observe stale
  bindings past a 60-second staleness threshold (alert fires).
- **§4.6 SPEC-016 addendum shape specified.** v0.5 said "MUST be
  added" without shape. v0.6 §4.6 pins the required schema:
  `provider_wallet_swaps (swap_id UUID PRIMARY KEY, provider_id
  TEXT NOT NULL, current_wallet TEXT NOT NULL, new_wallet TEXT
  NOT NULL, state TEXT NOT NULL CHECK (state IN
  ('pending','committed','cancelled_by_email','cancelled_by_wallet','cancelled_by_operator','delivery_failed')),
  cooling_started_at TIMESTAMPTZ NOT NULL,
  cooling_ends_at TIMESTAMPTZ NOT NULL,
  cancelled_at TIMESTAMPTZ NULL,
  committed_at TIMESTAMPTZ NULL)`. Commits fold into the existing
  SPEC-016 `provider_payout_addresses` row within a single
  transaction.
- **AC-026-12 updated for cross-track `provider_auth_policy`.**
  v0.5 still referenced `identity_signature_exempt_until` column
  name and only tested `p_` providers; v0.6 rewrites to
  `provider_auth_policy.signature_exempt_until` semantics
  (row absent / `signature_exempt_until IS NULL` / expired) and
  covers both App-track and new CLI-track provider_ids.
- **§9.3 EIP-712 domain shape specified.** Full domain object
  spelled out with `name`, `version`, `chainId`, and the
  sentinel `verifyingContract` policy per SPEC-016 v1.0.1 §3.2
  conventions.
- **§8.4 SPEC-025 §7 cross-reference tightened.** v0.6 notes that
  SPEC-025 §7 requires an update in a follow-up PR to link to
  SPEC-026 §8.4 as the atomic import contract for App-track.
- **v0.5 changelog line contradiction fixed** ("v0.4 invented
  `.installed-by-app`; actual is `.installed-by-app`" — meant
  `.malibu-owned`).
- **§10 checklist step 7 explicitly runs Phase 1b seeding
  substep.** Made explicit to avoid the ordering confusion.
- **Entry 102 rewritten for v0.6** with R4/R5 dispositions,
  cross-track auth policy, verified-email 3-path transfer,
  Phase 1a/1b split, `provider_emission_state`, and Postgres
  projection.

**v0.5 (2026-07-03, R4 audit-loop cleanup pass).** R4 3-lane codex
audit landed 0/7/11. Most CODE HIGHs were text-hygiene drift from
v0.4's partial edits; SEC + ARCH HIGHs were real. v0.5 closes all:

- **§4.3 prose swept for `auth_proof` → `auth_request` + `stage:
  "proof"`.** v0.4 fixed the JSON example but the surrounding text
  (line 579 per R4) still referenced the wrong frame name.
- (from v0.5) **§4.3 remove `provider_ecdh_public_key` from proof-stage body.**
  SPEC-001 §6.7 proof fields are only `type`, `version`, `stage`,
  `auth_attempt_id`, `provider_id`, `attestation_token`, and
  optional SPEC-010 fields; ECDH is initial-stage-only. v0.5 says
  the ECDH pubkey is signed FROM cached initial-frame values but
  not re-transmitted in proof.
- **§4.5 email confirmation flow — deep-link back to App.** v0.4 had
  a `/notification-channel/verify?token=…` link that opened in a
  browser but the underlying `POST` required bearer + identity
  signature. Real bug. v0.5 defines the email link as a
  `malibu-app://verify-email?token=…` deep-link (using the same
  URL-scheme mechanism the CLI-track SPEC-025 flow uses); the App
  handles the link, extracts the token, and performs the signed
  POST from the trusted App target.
- **§4.6 GET → POST split (ARCH HIGH).** v0.4 had a GET endpoint
  that mutated state — email prefetchers or link-preview bots
  could fire it accidentally. v0.5 splits: GET renders a
  confirmation page with a "Confirm cancel" button; POST does the
  mutation. Also SPEC-016 does not currently define a
  cancel-swap primitive, so v0.5 §4.6 explicitly calls out that
  this endpoint MUST be added as a SPEC-016 addendum in the
  implementing PR (or here in SPEC-026's follow-up SPEC-016
  addendum). Deploy checklist gates on it.
- **§5.1 `provider_rewards_ledger.amount_usd` NOT NULL constraint.**
  v0.4 wanted MALIBU-only rows with `amount_usd = NULL`, but the
  existing DDL is `NUMERIC(18,2) NOT NULL`. v0.5 requires the
  implementing PR to drop the NOT NULL constraint as part of the
  same migration, with a rollback script that re-adds it after
  clearing null rows.
- **§8.4 marker filename corrected.** v0.4 used
  `.malibu-owned` (a v0.4 invention); actual
  `ProviderPaths.appMarkerFile` at `ProviderPaths.swift:24` is
  `.installed-by-app` and `ProviderConfig.isConfigured` checks
  that exact path. v0.5 fixed globally.
- **§8.4 "Import existing CLI provider" migrates YAML token to
  Keychain.** v0.4 Option A just added the marker file, but
  `ProviderConfig.isConfigured` requires the token in Keychain
  (not YAML). v0.5 defines import as: parse `provider_id` +
  top-level `provider_token` from YAML → save token to Keychain
  → rewrite YAML without the token → create
  `.installed-by-app`. Matches SPEC-025 §7 import contract.
- **§8.4 "Start fresh" backup naming.** v0.4 said rename the
  directory to `config.yaml.cli-backup-<timestamp>` and mentioned
  running CLI against it, but `config.yaml` is a file path, not
  a directory. v0.5 moves the file to
  `~/.config/macprovider/config.yaml.cli-backup-<timestamp>` and
  documents `macprovider-cli --config <backup-file>` for
  reclaim.
- **§10 step 7 rewritten** to use `provider_auth_policy.signature_exempt_until`,
  `migration_time + 7 days`, both App and CLI pre-cutover ids,
  and operator extensions only via §4.3. v0.4 accidentally left
  the v0.3 wording in step 7.
- **§9.3 email channel authority transfer (SEC HIGH).** v0.4's
  24h "wait it out" rule let bearer+identity malware trivially
  take over the channel. v0.5 requires channel-authority
  transfer to require ONE of:
  1. Approval reply from the OLD verified email (deep-linked
     into the App from the notification), OR
  2. EIP-712 signature from the currently-bound payout wallet,
     OR
  3. Manual dual-control operator recovery (with incident ID).
  Time passage alone does NOT transfer authority. If none of the
  three paths succeeds within a 7-day pending window, the change
  request expires and the old email remains authoritative. This
  closes the "compromised Mac, no old email" fresh-install
  attack because a fresh install has no bound wallet AND no old
  email, so §9.3 fail-closed (unverified email + swap ≥ $500 =
  reject) already prevents the swap.
- **§4.3 `provider_auth_policy` NULL semantics explicit.** ARCH
  MEDIUM. v0.4 said `signature_exempt_until IS NULL` means "must
  sign" but the pseudocode only checked `NOW() > row.signature_exempt_until`.
  v0.5 explicit: `if row IS NULL OR row.signature_exempt_until IS
  NULL OR NOW() > row.signature_exempt_until: require signature`.
- **§4.3 admin exemption grants require pending + separate approver
  table + immutable audit chain.** SEC MEDIUM. v0.4 had a single
  `granted_by` column that let one insider unilaterally issue,
  approve, and re-issue exemptions. v0.5 adds
  `provider_auth_policy_pending` and requires
  `approved_by != requested_by`; rolling renewals capped at
  30 days total from original grant except for break-glass with
  incident ID.
- **§4.5 email `unset` rate-limited too.** SEC MEDIUM. v0.4 only
  rate-limited `set`; attacker could bypass via `unset` + `set`.
  v0.5 applies the 1/7-day limit to `set`, `unset`, `confirm`,
  AND rejected changes.
- **§5.2 distinct criterion IDs.** SEC MEDIUM. v0.4 let E2
  wallet balance satisfy both the economic slot AND additional
  criterion #3. v0.5 requires the two satisfied criteria to be
  distinct IDs.
- **§5.1 unbound emission replay atomicity at bind time.** SEC
  MEDIUM. v0.5 adds `provider.cap_replay_pending` state during
  bind: withdrawal release and Trust promotion blocked until
  replay job completes; replay uses the same aggregate lock as
  live emissions.
- **§9.3 email delivery exhaustion auto-cancels swap.** SEC LOW
  promoted to explicit rule: after 5 retries exhaust, swap
  auto-cancels with reason `notification_delivery_failed`
  (was: held indefinitely).
- **§4.6 cancel URL single-use enforcement.** SEC LOW. v0.5
  requires atomic `pending → cancelled_by_email` compare-and-swap
  on the swap row; reused links return `410 already_used`.
- **§4.6 HMAC verification order fix.** CODE MEDIUM. v0.4 verified
  HMAC over fields not in the URL. v0.5: first `SELECT` the
  pending swap by `swap_id`, then compute HMAC over the loaded
  `provider_id` + `new_wallet` + URL's `kid`/`exp` and compare
  to URL's `sig`. Fields not in the URL come from the swap row.
- **§11 §5.2 E3 operator promotion documented as manual audited
  exception.** ARCH LOW. v0.5 §11 explicitly notes E3 is a
  manual out-of-band review, not part of the automated sybil
  economics bound; requires reason, evidence class, dual control.
- **§5.1 SERIALIZABLE isolation pinned to Postgres rewards-writer
  role.** ARCH MEDIUM. v0.5 notes the emission ledger runs on
  the coordinator's Postgres stats DB (not the SQLite
  billing/payout DB); a dedicated rewards-writer DSN with
  `SERIALIZABLE` isolation is required by the impl PR;
  SQLite billing/payout isolation is unchanged.
- **§10 step 1 migration timing.** ARCH MEDIUM. v0.5 splits table
  creation (deployed in the initial migration) from row seeding
  (populated at auth-verifier cutover time). "Cutover time" is
  defined as the moment the auth-verifier code is deployed and
  serving; the 7-day exemption window anchors from cutover, not
  from schema deploy.

**v0.4 (2026-07-03, R3 audit-loop revision).** 3-lane codex audit
against v0.3 landed 0 CRITICAL / 4 HIGH / 18 MEDIUM
(`SPEC-026-r3-audit.md`). v0.4 closes each as targeted edits:

- **§4.3 proof-stage frame shape corrected to SPEC-001 §6.7
  literal.** v0.3 named the frame `type: "auth_proof"` and put the
  bearer inside the body. SPEC-001 v1.6 §6.7 defines proof-stage as
  `type: "auth_request", stage: "proof"` and the bearer stays in
  the WS-upgrade `Authorization` header. v0.4 uses the actual
  SPEC-001 wire shape and only ADDS `identity_signature` +
  `identity_signature_transcript_sha256` fields to the existing
  proof-stage frame.
- **§4.3 CLI-track receipt-key rotation composes with SPEC-015.**
  During SPEC-015 `macprovider rotate-key` reconnect, the client's
  initial-stage frame carries the NEW `provider_receipt_public_key`
  that hasn't yet been committed at the coordinator. v0.4 §4.3
  validates the proof-stage signature against the initial-frame
  key when it differs from the stored key, then commits the
  rotation after auth acceptance. This preserves SPEC-015's
  reconnect-based rotation model.
  **(Reconciled §4.3 — the shipped verifier selects the
  `identity_signature` key by principal type: for `mp-*` bootstrap
  principals it verifies against the stable durable **bootstrap
  identity** (`identity_signature.go:132-138`), for legacy principals
  against the stored receipt key (`:153-159`) — never a self-signed new
  key. The new receipt key is then rotated **in-band**, staged and
  committed via `provider.go:779,839`. So a rotated key CAN authenticate,
  but only when the frame is signed by the stable identity.)**
- **§5.2 Trust unlock requires at least one economic criterion.**
  v0.3 "any two of five" allowed 72h uptime + valid App Attest
  to unlock Trusted with zero economic cost — a hole the audit
  correctly flagged. v0.4 requires at least ONE of {≥100 verified
  receipts, ≥100 USDC continuous 72h balance, manual operator
  promotion} plus a second criterion from the full list. App
  Attest alone is not an economic gate (§11 already reframed this).
- **§9.3 App-track cancellation moved out of SPEC-026.**
  The older email/HMAC/cancel-channel design is no longer a
  SPEC-026 active surface; SPEC-027 owns those requirements.
- **§4.1 rotate-on-duplicate hardened against DoS.** v0.3 revoked
  the live token on every duplicate `/register`. v0.4 requires
  the duplicate `/register` to prove current token possession
  (v0.12: via HTTP `Authorization: Bearer <current_provider_token>`,
  not a JSON body field) or the request is rejected
  `409 CONFLICT existing_active_token_no_proof`. This
  closes the "spam-register to invalidate live session" DoS.
- **§5.1 emission ledger named.** v0.3 was generic. v0.4 pins the
  target as `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql:170`
  `provider_rewards_ledger` (which currently stores `amount_usd`).
  The implementing PR MUST add MALIBU columns
  (`amount_malibu NUMERIC NULL`, `withdrawal_hold_reason TEXT NULL`)
  to that table.
- **§5.1 concurrent emission cap enforced by
  `SERIALIZABLE` isolation.** v0.3 lacked concurrency semantics
  on `wallet_daily_malibu_emission`. v0.4 pins per-transaction
  `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` with
  retry-on-40001 for the emission + aggregate insert.
- **§5.2 randomized-check distribution specified.** v0.4 uses a
  Poisson-process sampler with mean interval 60 minutes, secret
  scheduler state coordinator-side. Max gap 4h; min gap 15min.
- **§5.5 requalification window after demotion.** 72h re-hold of
  all criteria after demotion before Trusted-tier privileges
  reinstate. Prevents rapid demote/re-promote oscillation.
- **§4 API surface enumerated.** v0.3 introduced
  `POST /v1/providers/{id}/notification-channel` and the
  HMAC-signed cancel URL in §9.3 without listing them in §4.
  v0.4 adds §4.5 and §4.6 with full request/response/auth/error
  schemas.
- **§7.3 test path corrected.** Was
  `phase3-binary/app/Tests/MalibuTests/PendingLinkStateTests.swift`
  — kept.
- **§8.1 import/migration dialog defined inline.** v0.3 cited
  SPEC-025 §3.4 which is uninstall-only, not import. v0.4 §8.4
  defines the dialog inline.
- **§9.3 HMAC secret + rotation.** Secret ID `wallet_swap_cancel_hmac`,
  loaded via coordinator `LoadCredential`, 32-byte min entropy,
  `kid` in cancel URL, current + previous acceptance window
  matches cooling-window duration.
- **§10 checklist adds v0.4 primitives.** Schema migrations for
  `identity_signature_exempt_until`, `notification_email`,
  `provider_rewards_ledger` MALIBU columns,
  `wallet_daily_malibu_emission` table added as explicit gate steps.
- **§4.3 auth-policy lookup moved off `provider_identities`.** v0.3
  put `identity_signature_exempt_until` on `provider_identities`,
  but that table is App-track-only; the CLI-track hardening (§4.3
  new-CLI-provider_ids MUST sign) needs the same allowlist. v0.4
  moves it to a new `provider_auth_policy(provider_id,
  signature_exempt_until, kind)` table.
- **AC-026-06 rewritten to cover the email channel** including
  storage, dispatch, signed-URL success, expiry, and
  unset-email fail-closed semantics.
- **§8.2 rollback text aligned to §8.1** (auto-present, not
  menu-bar-only).
- **CLI-track receipt-key source cited correctly.** v0.3 named
  `phase4-coordinator/internal/receipts/keys.go` which doesn't
  exist. v0.4 uses the actual `/v1/receipt-keys/{provider_id}`
  endpoint's backing storage and defines a lookup helper as
  implementation-required.

**v0.3 (2026-07-03, R2 audit-loop revision).** 3-lane codex audit
(`SPEC-026-r2-audit.md`) against v0.2 landed 0 CRITICAL / 5 HIGH /
14 MEDIUM. v0.3 closes each with targeted edits (not a full rewrite):

- **§4.3 `identity_signature` moves from `auth_request` to the
  proof-stage frame.** SPEC-001 v1.6 §6.7 issues `auth_attempt_id`
  in the server's `auth_challenge` (after the client's initial
  `auth_request`), so signing it in `auth_request` was
  unimplementable. v0.3 puts the signature on the client's proof
  response, binds a transcript hash, and renames the ECDH field to
  match SPEC-001 (`provider_ecdh_public_key`).
- **§4.3 client-reported `binary_version` no longer gates auth
  policy.** Server-side `provider_identities.identity_signature_exempt_until`
  is populated only by explicit operator action or by a one-time
  migration for legacy `p_`-prefixed provider_ids. New provider_ids
  MUST always sign; there is no client-declared exemption path.
- **§9.3 out-of-band cancellation channel.** UNUserNotification is
  in-band from a compromised Mac. v0.3 adds an OPTIONAL
  `notification_email` field on `provider_identities`; SPEC-016's
  App-track wallet-swap flow sends a coordinator-authored email
  with a signed cancellation link that works during the SPEC-016
  cooling window regardless of Mac state.
- **§4.1 step 7 uses the actual `provider_tokens` schema.** v0.2
  referenced `ACTIVE`/`USED`/`REVOKED` states that do not exist.
  v0.3 uses the real predicates (`revoked_at IS NULL`,
  `last_used_at IS NULL`) and switches to a
  rotate-on-duplicate-identity_pubkey model instead of
  return-existing-cleartext (cleartext isn't persisted).
- **§5.1 provisional non-withdrawable + per-wallet cap gain concrete
  enforcement primitives.** `withdrawal_hold_reason` column on the
  reward-emission ledger; `wallet_daily_malibu_emission` aggregate
  table keyed on canonical bound wallet + emission day. Every
  MALIBU withdrawal runner query MUST filter
  `WHERE withdrawal_hold_reason IS NULL`.
- **§5.2 wallet-balance criterion becomes time-weighted with
  randomized checks.** Balance must remain ≥100 USDC for the full
  72h unlock window, verified at randomized 15min–4h intervals
  using SPEC-016's dual-RPC dual-read on the pinned Base USDC
  contract.
- **§7.6 launch gate reverts to `ProviderConfig.isConfigured`.** v0.2
  used `||` composition which allowed identity-only (v2-partial) to
  reach `MalibuAgent.start()` without a persisted provider_id +
  token. v0.3 keeps identity-only state on the onboarding-window
  rehydration path.
- **§8.1 migration matrix adds "CLI-owned config, no App marker" row
  + auto-present-on-foreground for v2-partial regardless of flag.**
- **§11 App Attest economics reframed.** v0.2 overstated attestation
  as a per-device sybil cost; in reality, `DCAppAttestService.generateKey`
  produces arbitrarily many keys per device. v0.3 reframes App
  Attest as bundle-integrity + anti-replay evidence, not economic
  sybil resistance.
- **CLI-track hardening (§4.3, §4.4).** New CLI-track provider_ids
  issued after the App-track cutover MUST use a matching
  receipt-key-signed proof-stage flow. Legacy CLI provider_ids
  remain bearer-only via the same server-side exemption list.
- **Cross-cutting corrections.** base32 helper claim rewritten as
  implementation requirement; test file path corrected to
  `Tests/MalibuTests/`; §10 gate step 4 requires SPEC-016 §3 in
  production; earnings endpoint aligned to existing SPEC-005 path;
  §2 receipt-key generation citation moved to `ReceiptKeyStore.swift:41`.

**v0.2 (2026-07-03, R1 audit-loop revision).** 3-lane codex audit
(`SPEC-026-r1-audit.md`) surfaced 1 CRITICAL / 9 HIGH / 16 MEDIUM
against v0.1. v0.2 closes each. Load-bearing changes:

- **Identity key is now SEPARATE from the SPEC-015 receipt key.** v0.1
  reused one key for both; that would have made every receipt-key
  rotation also rotate `provider_id`, orphaning SPEC-016 payout
  bindings and settled-receipt history. The identity key lives in
  Keychain slot `provider_identity_v1` and does NOT rotate on the
  SPEC-015 receipt-key rotation path. Environment-variable handoff of
  raw private-key bytes (`MACPROVIDER_RECEIPT_KEY_RAW`) is retired for
  the same reason and for the SEC-7 raw-key-exposure finding.
- **Payout-wallet binding delegates entirely to SPEC-016 §3.** v0.1
  invented a parallel Ed25519-signed `POST /providers/{id}/payout-address`
  endpoint that skipped the SPEC-016 EIP-712 wallet
  proof-of-possession. v0.2 uses SPEC-016 §3 unchanged; the Ed25519
  identity signature only proves the Mac authored the wallet-binding
  request. The EIP-712 wallet signature remains the money-path
  authority.
- **`identity_signature` moves to the SPEC-001 v1.6 §6.7 v2
  `auth_request` initial-stage frame.** v0.1 put it on legacy `hello`,
  which is reconnect / backwards-compat only. v0.2 pins the correct
  stage and defines a hard cutover: REQUIRED for `p_`-prefixed
  provider_ids from binary v1.9.0 forward.
- **App Attest replay closure.** v0.2 §5.3 binds `clientDataHash` to
  `(provider_id, identity_pubkey, register_nonce, coordinator_domain,
  bundle_id, team_id, ts_utc)` and requires attestation-key-id
  uniqueness per provider_id. v0.1 let one legitimate attestation
  object replay across arbitrary identities.
- **SPEC-023 autotune stays on-device.** v0.1 had the coordinator
  return `recommended_model` from `/register`. v0.2 removes it; the
  App runs `macprovider-cli autotune --recommend --json` locally after
  identity is minted, preserving SPEC-023's signed-catalog + rate-card
  privacy invariants.
- **"Coordinator escrow" renamed to "unpaid ledger backlog".** Aligns
  with SPEC-005/SPEC-016 accounting; no new ledger owner introduced.
- **Sybil economics tightened.** Provisional $MALIBU is non-withdrawable
  until Trusted unlock; wallet-balance criterion is continuously
  re-checked (not one-shot); per-wallet emission cap added.
- **Migration matrix and rollback path.** §8 now enumerates each of
  {fresh, CLI-owned config, v1-complete, v2-partial, v2-complete} ×
  {flag-on, flag-off}.

**v0.1 (2026-07-03).** Initial draft.

## 0. Terminology

- **App track** — `Malibu.app`, the signed `.dmg` menu-bar wrapper
  introduced by [SPEC-025](./SPEC-025-native-mac-app.md). Brand is
  Malibu; user-visible strings never say "MacProvider",
  `malibu.tech`, or "node".
- **CLI track** — existing `macprovider-cli` binary launched via
  `install.sh` by developer users. As of v0.22, App import stages the YAML bearer in
  CLI Keychain and keeps the private YAML until a restarted launchd process is admitted;
  older installed CLIs fail the handoff without losing the source.
- **Provider identity key** — Ed25519 keypair DEFINED for the App track,
  stored in Keychain slot `provider_identity_v1`, distinct from the
  SPEC-015 receipt key. **DORMANT in the shipped build (reconciled
  v0.15):** `ProviderIdentity.loadOrGenerate`/`isReady` have zero
  production callers (§3, §7.1); the shipped monitor-only onboarding
  never generates or uses this key — provider identity in the shipped
  flow is the CLI-track `mp-<32hex>` principal (§2). Same algorithm
  (`Curve25519.Signing.PrivateKey`, generated the same way as the
  SPEC-015 receipt key at
  `phase3-binary/Sources/macprovider-cli/ReceiptKeyStore.swift:41`)
  but a separate keypair in a separate Keychain slot. Does NOT rotate on
  the SPEC-015 receipt-key rotation path; rotation of the identity key
  itself is out of scope for v0.2 (open question §13).
- **Receipt key** — Ed25519 keypair defined by [SPEC-015 §12](./SPEC-015-receipts.md),
  generated and rotated per that spec. UNCHANGED by SPEC-026.
- **provider_id** — the App-track designed form is `p_` +
  base32(sha256(identity_pubkey_bytes)), deterministic from the identity
  key and self-verifiable by anyone with the pubkey. **DORMANT
  client-side (reconciled v0.16):** the shipped provider ID is the
  CLI-track `mp-<32hex>` principal — opaque, generated locally by
  `install.sh` (`openssl rand`, `install.sh:2500`), NOT a `p_*`
  derivation and NOT a coordinator-issued string (§3 banner, §4.1). The
  `p_*` form applies only to the designed App-track identity model.
- **Provisional tier** — trust bucket every new provider starts in.
  Capped concurrent slots, capped $MALIBU emissions (non-withdrawable),
  delayed payout. Trust unlock per §5.2.
- **Deferred wallet** — the payout wallet is not required at
  onboarding. Earnings accrue in the SPEC-016 unpaid ledger backlog
  until first bind.

## 1. Goal

A non-technical Mac user opens `Malibu.app` for the first time and
sees a single primary button: **Launch Provider**. Clicking it makes
them a live marketplace provider within the same window, without a
browser tab, without a GitHub sign-in, without copy-pasting anything,
and without entering a wallet address unless they want to.

### 1.1 Success criteria

- **Zero external surfaces during onboarding.** No browser tab opens.
  No `portal.malibu.tech` URL appears in the UI or logs. No GitHub
  OAuth screen. No wallet-signing prompt.
- **≤ 1 click of user intent.** After launch, a single button starts
  every background step. **Reconciled v0.15 to the shipped CLI-wrapper:**
  the button runs the bundled `install.sh`, which performs
  `bootstrap-auth` credential acquisition (`mp-*` principal over WS
  admission — §2/§4.1), SPEC-023 autotune, model download, and launchd
  provider-service + watchdog install; the app then adopts and monitors the
  launchd CLI (§3, §6.1). There is no in-app "identity generation" or HTTP
  coordinator-registration step — that App-track apparatus is dormant
  (§3/§4.1).
- **In-window progress and success.** Every step's progress and the
  final "Provider live · <model> · <USDC/MALIBU counters>" success card
  render inside the same `NSWindow`. No menu-bar-only completion. No
  secondary dashboard window opening automatically.
- **Resumable.** Closing the window mid-install does not cancel the
  underlying `LaunchProviderController` Task. **Reconciled v0.15:** the
  shipped app resumes by retaining the in-memory controller (the window
  rebinds to it, §6.3); it does NOT persist resumable onboarding state —
  `onboarding.json` is legacy decode-only and production writes no
  progress checkpoint (`OnboardingState.swift`, §7.5). On a full app
  restart mid-install, routing re-derives state from disk evidence +
  Keychain and dispatches per the §8 precedence table (markerless
  CLI-owned config → import dialog; app-owned-but-incomplete →
  onboarding, which re-runs `install.sh`; healthy + launchd evidence →
  monitor) — not an unconditional `install.sh` rerun.
- **Wording.** No user-facing string contains "node". Everywhere it
  currently reads "node", the App track reads "provider".

### 1.2 Non-goals (v0.2)

- Wallet-signing UX **during onboarding**. Not in the onboarding
  flow. Post-onboarding wallet binding is **SPEC-027-gated, not shipped**
  (reconciled v0.15): the designed SPEC-016 §3 EIP-712 composition lives
  behind the §4.2 / §6 SPEC-027 banner (coordinator returns `501`,
  `setPayoutWallet` throws). See §4.2 + §6.1 step 8.
- WalletConnect / Rainbow / Rabby deep-link integration.
- In-app wallet creation.
- Retiring the CLI-track `install.sh` path. This spec does not force
  any change on developer users.
- Automated model-selection driven by coordinator. SPEC-023 autotune
  stays on-device (run by `install.sh` during §6.1 step 7b).
- Rotation of the dormant App-derived `p_*` identity remains out of scope. The shipped
  CLI-owned admission identity rotates and recovers in place under §4.3 without changing
  `provider_id`, billing ownership, tokens, payout bindings, or settled history.

## 2. What already exists (grounding)

- [SPEC-001 v1.6 §6.7](./SPEC-001-phase3-binary.md) — v2 `auth_request`
  handshake with `stage: "initial"` (client → server) →
  `auth_challenge` (server → client) → `auth_request` with
  `stage: "proof"` (client → server). SPEC-026 §4.3 adds two
  OPTIONAL fields to the **proof-stage** frame
  (`identity_signature` and `identity_signature_transcript_sha256`)
  and defines a cutover to REQUIRED for both `p_`-prefixed
  provider_ids AND new CLI-track provider_ids via the cross-track
  `provider_auth_policy` table.
- [SPEC-003 §FR-C9 v0.8](./SPEC-003-open-onboarding.md) — coordinator
  self-mint of `assigned_provider_token` on **tokenless WS admission**, with
  TOFU enforcement per FR-C9.4. **Reconciled v0.14: this WS-admission path is
  exactly what the shipped app uses** — `install.sh` runs `bootstrap-auth`, which
  acquires the `provider_token` over the coordinator WebSocket handshake
  (`BootstrapAuthCommand.swift`; `CoordinatorClient.swift:569-575,1989-2056`). SPEC-026
  §4.1's separate HTTP `/v1/providers/register` token primitive is a
  coordinator-contract that the shipped client does **not** call (§4.1).
- [SPEC-015 §12](./SPEC-015-receipts.md) — provider receipt key
  Ed25519, generated + rotated by SPEC-015 unchanged. SPEC-026's
  identity key is a DIFFERENT Keychain slot and does NOT rotate on
  the SPEC-015 rotation path.
- [SPEC-016 §3](./SPEC-016-payout-pipeline.md) — provider payout-address
  registration with EIP-712 wallet proof-of-possession, hot-wallet
  reconfirm, `provider_payout_addresses` table. SPEC-026 does not
  modify this endpoint; the App-track wallet-binding UI that would plug
  into it is **SPEC-027-gated and disabled in the shipped build** (§4.2
  banner — coordinator `501`, `setPayoutWallet` throws).
- [SPEC-022](./SPEC-022-verified-model-settlement.md) — verified-model
  settlement, keyed off provider receipt-key identity. Unchanged.
- [SPEC-023](./SPEC-023-installer-autotune-recommend.md) — local
  autotune with signed catalog. **Reconciled v0.14: `install.sh` runs
  `autotune --recommend` inside the CLI track** as part of onboarding (the app only
  scrapes `ps` for a progress hint), not an in-app post-identity-mint step (§6.1).
- [SPEC-025 §3.1](./SPEC-025-native-mac-app.md) — first-run flow. **Reconciled v0.14:
  SPEC-025 §3.1 is now the CLI-wrapper `install.sh` onboarding** (not browser OAuth);
  the `malibu://` / `PendingLinkState` machinery is removed (§7.3). There is no
  onboarding flag; `MalibuAgent.start()` is gated by the three conditions in §7.6
  (provider_id + launchd evidence + `ProviderConfig.isConfigured`).
- `phase3-binary/Sources/MacProviderCore/ProviderTokenPersist.swift`
  — compatibility helper for locked, exact YAML credential migration. New coordinator
  assignments persist only to CLI Keychain. Existing YAML remains readable during the
  handoff and is removed by the restarted CLI only after authenticated admission plus
  its first state update (§6.1). `saveProviderIdentity` also exists but is not the
  shipped onboarding path.
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:64-87` —
  launch gate is now **three** conditions (provider_id + launchd install evidence +
  `ProviderConfig.isConfigured`) and drives a **monitor**, not a spawn (§7.6).
- **Reconciled v0.14/v0.18 — NO CLI child is launched.** The app does not launch a CLI
  child with `MACPROVIDER_PROVIDER_TOKEN`; the launchd **provider service**
  `live.malibu.provider` (KeepAlive) runs AND performs routine restarts of the CLI; a
  separate companion watchdog `live.malibu.provider-watchdog` only health-observes on
  routine ticks (its restart request is a no-op — `install.sh:3575`), except it force-restarts
  the provider service during auto-update rollback recovery (`install.sh:4086,4113`; SPEC-025
  §8) — both installed by `install.sh` — and the app monitors it over HTTP (SPEC-025 §5).
- Landing page marketing copy at `/Users/augstar/projects/malibu/host/index.html`
  promises "One line in your terminal. … Your Mac picks up jobs
  whenever it's idle and online." This spec makes the App track
  deliver on that promise without the terminal step.

## 3. Identity model — CLI-owned generation-CAS admission identity

The production provider's admission identity is owned and used only by the CLI. The
current, pending, and bounded previous Keychain slots are keyed by the unchanged
provider ID. Routine rotation stages one candidate, has the current key authorize the
complete next-key transcript, and commits only the coordinator-authoritative
generation. Lost-response convergence accepts only that exact staged candidate.
Complete local-key loss uses an exact candidate-bound, expiring, dual-control operator
authorization plus bearer and candidate-key proofs; it preserves billing ownership and
history and cannot fall through to a temporary signature exemption. Malibu never reads,
generates, signs with, rotates, or deletes these keys.

### 3.0 Historical App `p_*` design — removed

> **REMOVED by issue #585 Option 2.** The App-track device-`p_*`-Ed25519 identity
> model below is retained only as design provenance. `ProviderIdentity.swift`, its
> tests, the App registration client, and the local identity-signature responder no
> longer exist. Nothing in §3.1–§3.4 is an implementation requirement.
> The shipped onboarding instead creates a **CLI-track `mp-*` provider** via
> `install.sh` → `bootstrap-auth` → tokenless WS admission. The `mp-*` provider's durable
> admission identity begins as the **bootstrap identity** — a snapshot of the FIRST
> installer receipt key, stored in its own current Keychain slot
> `com.malibu.provider.bootstrap-identity-key` (`ReceiptKeyStore.swift:23,66-92`).
> Ordinary `identity_signature` for `mp-*` is verified against that bootstrap identity
> (`CoordinatorClient.swift:1842`; coordinator `identity_signature.go:127`), NOT the
> rotatable `.receipt-key`, which signs SPEC-015 receipts and may rotate. The current
> receipt key is only a legacy fallback (proven durable-row absence). The app's finalize
> gate is `ProviderConfig.isConfigured` (App ownership/config identity plus the
> conditional CLI-custody marker), **not** `ProviderIdentity.isReady`
> (`LaunchProviderController.swift:65`; §6.1). Deleting `provider_identity_v1` does **not**
> force a fresh provider ID. Treat everything in §3 as a **designed but client-dormant**
> contract (the App `p_*` Keychain slot and derivation exist in code, but the shipped
> provider ID is `mp-*`, not `p_*`). §3.2's separation-from-receipt-key is moot in the
> shipped flow: the operative CLI-track credentials are the **bootstrap identity**
> (admission) + the **receipt key** (receipts), not the dormant App `p_*`.

### 3.1 Key generation

In the DESIGNED (client-dormant, see §3 banner) flow,
`ProviderIdentity.loadOrGenerate()` (§7.1) generates a fresh Ed25519
keypair via `Curve25519.Signing.PrivateKey()` on first launch —
reconciled v0.15: **no production caller invokes this** in the shipped
app; the shipped `LaunchProviderController` does not generate an
identity key. The **32-byte raw representation**
(`privkey.rawRepresentation`) is stored in the macOS Keychain with:

- `kSecClass = kSecClassGenericPassword`
- `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- `kSecAttrService` = the app bundle identifier (`tech.malibu.app`)
- `kSecAttrAccount` = `provider_identity_v1`

The key is never passed to a child process or environment (reconciled
v0.15 — the accurate guarantee: it is not exported to a subprocess. It
IS read into the App target's own process memory to sign in-process —
`ProviderIdentity.swift:172` — so "never leaves the Keychain" means no
subprocess handoff, not that it stays out of app memory). All signatures
are produced by loading the private key inside the App target's
(dormant) `ProviderIdentity` module and signing in-process. See §7.1.

### 3.2 Relationship to the SPEC-015 receipt key

The identity key defined here is **distinct** from the SPEC-015
receipt key. Distinct Keychain slots and lifetimes (the CLI store holds
THREE services — see the bootstrap-identity note below the table):

| Concern              | Identity key (SPEC-026)            | Receipt key (SPEC-015)      |
|----------------------|-------------------------------------|-----------------------------|
| Keychain slot        | account `provider_identity_v1` (App identity, dormant §3) | receipt services `com.malibu.provider.receipt-key` / `.prev`, plus admission services `com.malibu.provider.bootstrap-identity-key` (current; legacy name retained), `com.malibu.provider.admission-identity-key.pending`, and `.prev`, all account `<provider_id>` |
| Generated by         | App target on first `Malibu.app` launch | CLI during `bootstrap-auth`, **before** first `serve` (the bootstrap identity snapshots this first key — `BootstrapAuthCommand.swift:50`) |
| Rotation             | Dormant App-derived `p_*` identity: not rotated | Receipt key: SPEC-015 `rotate-key`; CLI admission key: §4.3 generation-CAS rotation/recovery |
| Signs                | `/register` body only (dormant App contract) | receipt frames |
| provider_id anchor   | YES — `provider_id = p_ + base32(sha256(identity_pubkey))` | NO |
| Exposed to child processes | NO                          | Via SPEC-015 mechanisms unchanged |

**Admission-identity lifecycle (v0.23 — distinct from receipt-key rotation).** The
`com.malibu.provider.bootstrap-identity-key` service retains its historical name
and begins as a one-time snapshot of the FIRST receipt key taken at `bootstrap-auth`.
It is the current admission key and signs `identity_signature`, not receipt frames.
Admission rotation uses dedicated `.pending` and `.prev` services and the coordinator
generation-CAS protocol in §4.3; `rotate-key` still touches only the receipt services.
The prior admission private key and coordinator public key are retained for at most
seven days for software rollback, then removed from eligible state.

Rationale for separation: SPEC-015 rotation is a routine hygiene
event (via `macprovider rotate-key`). If the receipt key ALSO anchored
`provider_id`, every rotation would create a new provider_id,
orphaning FR-C9 tokens, SPEC-016 payout bindings, and settled-receipt
history. Separation lets receipt-key rotation remain a routine
operation while identity remains stable.

The App target does not export the receipt-key private material to
the CLI subprocess. The CLI generates and manages its own receipt key
via `KeychainReceiptKeyStore` at
`phase3-binary/Sources/macprovider-cli/*.swift` per SPEC-015,
unchanged. CLI admission-key rotation is the §4.3 old-key-signed generation advance; it
does not migrate `provider_identities`, provider tokens, payout bindings, or provider ID.
Only rotation of the dormant App-derived `p_*` identity remains a future concern (§13).

### 3.3 provider_id derivation

```
identity_pubkey_bytes = privkey.publicKey.rawRepresentation  // 32 bytes
digest                 = SHA256(identity_pubkey_bytes)        // 32 bytes
alphabet               = "abcdefghijklmnopqrstuvwxyz234567"    // RFC 4648 §6, lowercased, no padding
provider_id            = "p_" + base32(digest, alphabet, no-pad)
```

- Total length: `p_` (2) + 52 chars = **54 chars**.
- UI compact display: `p_` + first 8 payload chars = **10 chars**
  (e.g. `p_abcd1234`) with a "Copy full ID" affordance for support.
- The alphabet is deterministic; both Swift and Go implementations
  MUST use `abcdefghijklmnopqrstuvwxyz234567` and no `=` padding.
  **Go implementation MUST** use
	  `base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)`
	  from `encoding/base32`. **Swift App implementation MUST** add the
	  tested no-pad lowercase RFC 4648 §6 encoder as
	  `ProviderIdentity.base32LowercaseNoPad()` in the App target;
	  Foundation does not ship a stdlib base32 encoder. A parity vector
	  set distinct from the `/register` JCS fixture covers a matrix of
	  inputs 0/1/many-bytes to prove both encoders agree byte-for-byte.
- Buyer-facing UI MUST render `provider_id` verbatim from the
  canonical string. v0.2 does not introduce a user-controlled display
  name; a homoglyph-substitution attack is impossible against
  `[a-z2-7]`.

### 3.4 Why not Secure Enclave (SEP-P256)

SEP does not implement Ed25519 (only P-256). Using SEP would either
force a second key algorithm split (Ed25519 receipts + P-256
identity) or force us to rewrite SPEC-015 to accept P-256 signatures.
The marginal security gain over a `ThisDeviceOnly` Ed25519 Keychain
key does not justify either.

App Attest evidence (§5.3) is attached opportunistically as a
trust-score input, but is not the sybil gate and is not required for
registration to succeed.

## 4. Coordinator API changes

> **Scope banner (reconciled v0.14/v0.18).** The coordinator-side contracts in §4 are
> **implemented and conform coordinator-side** (Go tests pass). Client exercise differs
> per section — a critical distinction: the shipped **Malibu app** is a monitor wrapper,
> but the **`macprovider-cli` it monitors** is a full v2 client.
> - **§4.1 `/v1/providers/register`** — **dormant**: neither the app nor `install.sh`
>   calls it; current main deletes `RegisterClient`. Onboarding uses `bootstrap-auth` +
>   tokenless WS admission (§6.1).
> - **§4.3 `identity_signature` proof-stage** — **LIVE via the CLI track**: the
>   launchd-managed `macprovider-cli` signs `identity_signature` with its stable
>   **bootstrap identity** on the v2 auth handshake (`CoordinatorClient.swift:1842`), the
>   coordinator verifies it (`identity_signature.go:127`), and admission requires it under
>   `provider_auth_policy` (`server.go:1216`). The Malibu **app** itself does not sign;
>   its former App-`p_*` identity-signature responder is removed (§3), while the shipped
>   onboarding DOES depend on §4.3.
> - **§5.3 App Attest** — **client-dormant**: not minted by app or CLI.
>
> Where §4/§5.3 say "the App calls X," qualify it as not-shipped-**app**-side; §4.3 is
> nonetheless a live CLI-side dependency.

### 4.0 Referral-gated onboarding integration

When SPEC-034 enforcement is disabled, the existing one-click path is unchanged.
When enabled, the onboarding window first accepts a referral code as untrusted
input. The concrete v1 handoff is:

1. Compatibility-set manifest v1 remains exact-key and is not extended with a
   capability array. For a fresh bundled install, Malibu uses its compiled-in v1
   handoff only after hashing the exact regular-file bytes at
   `Contents/Resources/install.sh` that it is about to execute and comparing the
   result with the signed
   `components.launchd.install_contract.sha256` value for
   `compatibility-set-local/install.sh`. Missing, symlinked, unreadable, or
   mismatched resources fail to `unavailable` before execution. The compiled
   `MalibuBundledReferralBootstrapV1` gate applies to every referral path because
   Malibu executes the bundled installer even when a provider is already
   installed. For an existing CLI, Malibu additionally requires
   `referral_bootstrap_v1` in the CLI-authored local status contract. Either
   missing gate renders the input unavailable; support is never inferred from a
   marketing version.
2. `CLIInstallRunner.run(referralCode:)` validates at most 256 UTF-8 bytes with
   no control characters, writes the code to an unpredictable owner-only 0600,
   single-link, no-ACL regular source file, and adds only that file's path as
   `MACPROVIDER_REFERRAL_CODE_FILE` to its existing sanitized allowlist. It does
   not inherit the App environment.
3. `install.sh` captures and unsets a Malibu-supplied source-file path before
   launching any child. For direct fresh interactive use, it prompts before
   release discovery and writes the response with shell builtins to an
   unpredictable owner-only 0600 regular source file. The code never enters a
   process argument, child environment, or log. A noninteractive fresh install
   without a source file exits with typed status 20. A restart-safe incumbent
   bypasses this fresh-only intake. Both paths call the installed
   `macprovider-cli bootstrap-auth --referral-code-file <source>`.
4. `bootstrap-auth` opens the source with no-follow owner/mode/link/ACL and
   device/inode stability checks, reuses the durable provider/receipt identity,
   and sends the exact code in both signed bootstrap stages. Its owner-only
   `~/.config/macprovider/onboarding/referral-attempt-v1.json` journal contains
   only provider/receipt/code digests, attempt ID, and typed state. It persists
   the response bearer to CLI Keychain, marks that digest journal committed,
   removes the source only after its full stat identity and byte digest still
   match the original read, and exits 0.
5. The installer exit and versioned local status are Malibu's acknowledgement;
   no response contains the bearer. Existing installs advertise
   `referral_bootstrap_v1` in local status before Malibu exposes referral input;
   `referral_status_v1` independently gates the sanitized referral dashboard.

If the process or host restarts, the CLI reuses the digest journal, exact receipt
key, and a newly supplied source file containing the same code. If the
coordinator committed but the response was lost, the same binding reconciles the
persisted credential or the coordinator replaces only that exact bootstrap
identity's unused bearer. No raw code or bearer is written to Malibu storage,
config, the durable journal, lifecycle state, or logs.

A coordinator rejection maps to a typed invalid, expired, revoked, exhausted,
conflict, rate-limited, unavailable, or retryable result. The CLI reuses its
provider ID, admission key, and registration attempt on retry. Malibu offers
correction/retry without deleting an existing credential, and after success it
attaches to the launchd-managed provider rather than launching or supervising a
child. Independent Malibu and CLI marketing versions negotiate the request and
status surfaces by protocol capability; unsupported combinations render the
referral step unavailable truthfully.

The production implementation and acceptance tests MUST prove restart during
onboarding, response loss after coordinator commit, CLI Keychain persistence,
and exactly one managed provider process. Referral admission and advocacy policy
remain owned by SPEC-034; wire/status shapes remain owned by SPEC-001.

### 4.1 `POST /v1/providers/register`

**Client note (reconciled v0.15).** This coordinator endpoint and its request/response
schema are **unchanged and still conform as a coordinator contract**, but it has **NO
shipped caller — neither the app nor `install.sh` calls §4.1.** The shipped onboarding
does not use HTTP `/v1/providers/register` at all: `install.sh` runs `bootstrap-auth`
(`phase3-binary/dist/install.sh:3112`), which acquires the `provider_token` over the
coordinator **WebSocket** admission handshake (`BootstrapAuthCommand.swift:50`;
`CoordinatorClient.swift:569-575,1989-2056`) using an `mp-<32hex>` principal whose
durable proof credential begins as the **bootstrap identity** (a CLI-owned, rotatable snapshot
of the first receipt key — `ReceiptKeyStore.swift:66-92`; `install.sh:2484`) — see §2
grounding. (Earlier reconciliations said "install.sh
performs the §4.1 registration"; that was wrong — install.sh uses WS admission, not §4.1.)
The former Malibu `RegisterClient` and its tests are deleted from current main.
No compiled App registration or provider-identity signing library remains, and
referral recovery MUST NOT recreate one.
App Attest fields (`app_attest_object` / `app_attest_key_id`) are optional passthrough
params defaulting to `nil`; **no `DCAppAttestService` attestation is implemented in the
app tree** (team/bundle pins are enforced coordinator-side per §5.3, not minted by the
shipped app). The `p_*` body below is the DESIGNED wire contract for §4.1; it is **NOT**
what the shipped `install.sh` sends (which uses `bootstrap-auth` / WS admission, above).
Read it as a coordinator surface awaiting a client that drives it.

SPEC-034 referral onboarding does not activate this dormant endpoint and MUST NOT
restore `RegisterClient`. It extends the live CLI WS bootstrap described above.

```
Content-Type: application/json

{
  "provider_id":       "p_abcd…",
  "identity_pubkey":   "<base64-32-byte-ed25519>",
  "hardware_summary":  { "chip": "M3 Max", "unified_memory_gb": 64,
                         "macos_version": "14.5", "app_version": "1.0.3" },
  "app_attest_object": "<base64 CBOR>" | null,
  "app_attest_key_id": "<base64 32-byte>" | null,
  "nonce":             "<64-hex-char = 32 random bytes>",
  "ts_utc":            "2026-07-03T09:41:00Z",
  "signature":         "<base64-64-byte-ed25519>"
}
```

**Size limits (SEC-8):** request body ≤ 8 KiB.
`app_attest_object` ≤ 4 KiB. CBOR parse is bounded (max depth 8, max
elements 128) with a 2-second verification timeout. Oversized bodies
return `413 Payload Too Large`. Malformed evidence returns `400`
(reconciled v0.15 to shipped `internal/onboarding/apptrack.go:346-388`:
malformed base64/CBOR, a missing/invalid `app_attest_key_id`, or an
App-Attest **binding** failure all return `400`; cross-provider key
reuse returns `409`; unconfigured pins return `503`). Only a **transient
Apple-service error** (`ErrAppAttestTransient` / timeout) or **missing**
evidence degrades to `trust.attested = false` (reconciled v0.16 — the
shipped Apple verifier returns `(true,nil)` only on full success and a
typed binding/invalid ERROR otherwise, `appattest.go:127,144`, which the
handler rejects; a `(false,nil)` "verified-false" degrade is permitted by
the handler interface but the shipped verifier never emits it).
Structurally invalid evidence is rejected, not silently downgraded.

`signature` is Ed25519 over `JCS(body_without_signature)` per RFC
8785. The App target owns an App-local Swift canonicalizer under
`phase3-binary/app/Sources/Malibu/System/` for this PR; it MUST NOT
depend on the SwiftPM CLI target. The Go side is
`phase4-coordinator/internal/billing.CanonicalJSON`. A parity-fixture test at
`phase4-coordinator/test/jcs_fixtures/spec026_register.json` MUST
pass in both languages before this endpoint ships (§10 gate).

Coordinator MUST:

1. Verify `provider_id == "p_" + base32_lc(sha256(identity_pubkey_bytes))`.
   Mismatch → `400`.
2. Verify Ed25519 signature under `identity_pubkey` over
   `JCS(body \ signature)`. Failure → `401`.
3. Reject `|now - ts_utc| > 60s` (`400`) or a replayed
   `(provider_id, nonce)` pair (`409`). Replay cache TTL ≥ `65s`
   (60s window + 5s clock-skew slack), atomic insert-if-absent,
   backed by a shared cache (Redis or Postgres UNIQUE constraint on
   `(provider_id, nonce, ts_utc_bucket)`) for multi-instance
   coordinators. A separate `(source_ip, nonce)` cache with the
   same TTL rejects spam-registration variants that vary
   `provider_id`.
4. Enforce **per-IP** and **per-ASN** rate limits: 5/min/IP,
   30/min/ASN. Exceeding either returns `429` with `Retry-After`.
   Per-ASN limit is documented as backpressure / abuse-telemetry,
   NOT sybil defense (§5.1 note).
5. If `app_attest_object` is present:
   a. Verify against Apple App Attest root using the SPEC-026
      `clientDataHash` binding (§5.3).
   b. Verify `app_attest_key_id` matches the attestation object's
      keyId and has not been seen for a DIFFERENT `provider_id`
      (uniqueness: reject with `409` on cross-provider-id reuse).
   c. On successful verification, record `trust.attested = true`.
      Reconciled v0.15/v0.16 to shipped `apptrack.go:346-388` +
      `appattest.go:127,144`: **malformed, structurally invalid,
      binding-failed, or key-reused** evidence is REJECTED
      (`400`/`409`/`413`/`503`), NOT downgraded. Only a **transient**
      Apple-service error or a **missing** `app_attest_object` yields
      `trust.attested = false`; the shipped verifier returns `(true,nil)`
      only on full success and a typed error otherwise, so no
      "verified-false-but-accepted" path is reachable.
6. Upsert into `provider_identities` keyed by `provider_id`. TOFU: if
   a row exists with a different `identity_pubkey`, reject `409
   CONFLICT`.
7. Mint a `provider_token` using a NEW HTTP token-issuance primitive
   in `phase4-coordinator/internal/onboarding/apptrack.go` that
   writes to the existing `provider_tokens` table (columns per
   `phase4-coordinator/internal/auth/tokens.go:248-257`:
   `token_hash`, `token_prefix`, `provider_id`, `provider_name`
   (`NOT NULL`), `created_at`, `revoked_at`, `last_used_at`).
   The App-track mint supplies `provider_name = "malibu-app"` as
   the tenant literal so existing coordinator INSERTs don't hit
   a NOT NULL constraint failure. The token schema stores only
   `token_hash`, not cleartext, so a "return the existing token"
   idempotency is not buildable. Instead, on duplicate `/register`:

   - **Same `identity_pubkey`, ANY prior active row (`revoked_at IS
     NULL`, regardless of `last_used_at`) (reconciled v0.15 to the
     shipped fail-closed custody rule — the v0.13 change-log rule; the `provider_tokens`
     mint at `phase4-coordinator/internal/auth/tokens.go:945-975`
     sets `requiresProof := lookupErr == nil` and so requires proof
     whenever an active row exists — there is NO never-handshaked
     bypass; an unused active token is treated identically):** the
     request MUST prove
	     current-token possession via HTTP
	     `Authorization: Bearer <current_provider_token>` header on this
	     `/register` call (in addition to the request-body Ed25519
	     identity signature). The App MUST NOT put bearer material in the
	     JSON body, signed JCS payload, fixtures, or logs.
     Coordinator SHA-256 hashes the provided cleartext bearer
     and compares against the active row's `token_hash`. Mismatch
     or absence → `409 CONFLICT existing_active_token_no_proof`
     (`ErrAppTrackExistingTokenNoProof`, `tokens.go:956`).
     Valid → coordinator revokes the prior row and mints a fresh
     token. This closes the "spam-register to invalidate a live
     session" DoS: an attacker with identity-signing capability
     but not current-token possession cannot force revocation of
     the honest session. Additionally, a per-provider register
     cooldown of 5 minutes applies (max 1 successful re-issue per
     5 minutes — `apptrack_register_reissues` /
     `ErrAppTrackReissueCooldown`, `tokens.go:960-969`) to bound the
     reissue rate under legitimate use.
   - **Different `identity_pubkey`:** reject `409 CONFLICT
     provider_id_pubkey_mismatch` (TOFU, same rule as step 6). Do
     not touch the existing row.

   All of the above runs in a single SQLite transaction opened
   with `BEGIN IMMEDIATE` (SQLite has no `SELECT ... FOR UPDATE`;
   `BEGIN IMMEDIATE` acquires the RESERVED lock and serializes
   concurrent duplicate registers against the partial unique
   index on `(provider_id) WHERE revoked_at IS NULL`).
8. Respond:

   ```
   200 OK
   {
     "provider_id":         "p_abcd…",
     "provider_token":      "<opaque bearer>",
     "trust_tier":          "provisional",
     "trust":               { "attested": false,
                              "rate_limit_bucket": "new_ip" },
     "coordinator_ws_url":  "wss://coordinator.malibu.tech/v2/provider"
   }
   ```

   `recommended_model` is NOT returned here. In the shipped flow
   `install.sh` runs `macprovider-cli autotune --recommend` on-device
   per SPEC-023 (§6.1 step 7b); the app does not mint via §4.1 (§4.1
   client note).

### 4.2 Payout-address binding — delegate to SPEC-016 §3

> **SPEC-027-gated in the shipped build (reconciled v0.15).** Per the
> the v0.13 change-log rule, App-track wallet binding is **fail-closed**: the
> shipped coordinator returns `501 wallet_change_requires_spec_027`
> (`appTrackWalletNotImplementedHandler`, `cmd/coordinator/main.go:1284`)
> and the app's `setPayoutWallet` throws unconditionally
> (`LaunchProviderController.swift:94`) with both wallet buttons disabled
> (`OnboardingWindow.swift:137`, `DashboardWindow.swift:59`). The
> SPEC-016 §3 EIP-712 delegation described below is the **designed
> post-SPEC-027 contract**, not shipped behavior. Read-only earnings /
> "unclaimed backlog" display is fine; the binding **action** is not wired.

**SPEC-026 does not define a new payout-address endpoint.** Wallet
binding for App-track providers uses SPEC-016 §3
`POST /providers/{provider_id}/payout-address` unchanged: EIP-712
wallet proof-of-possession, `provider_payout_addresses` row,
hot-wallet reconfirm semantics, cooling-window rules.

The `Authorization: Bearer <provider_token>` header proves the
requesting party holds the App-track provider token. The EIP-712
signature proves the wallet owner consents to receive payouts. Both
are required. The Ed25519 identity signature is NOT part of this
endpoint — the identity-signature layer's role in SPEC-026 is
authenticating the Mac to the coordinator during onboarding and WS
sessions, not gating wallet binding.

Un-bound `provider_id`s accrue earnings as SPEC-016
`ledger_payout_ready` rows (see §9.1). Earnings are reported via
the existing SPEC-005 §11.4
	`GET /providers/{provider_id}/earnings` endpoint remains the App's
	steady-state source of truth and is additively extended by SPEC-026
	with the fields the App needs to render §6.2 invariants:
	`wallet_bound` (bool), `trust_tier` (`"Provisional"` or
	`"Trusted"`), `unpaid_ledger_backlog_usdc`, and
	`unpaid_ledger_backlog_malibu`. The backlog fields mirror ledger rows
	for App-track UI rendering. The auth model
(`Authorization: Bearer <provider_token>` where the token's subject
equals `{provider_id}`; 401/403/404 per SPEC-005 §11.4) is
inherited unchanged; SPEC-026 does not introduce a new endpoint or
new auth path.

On first bind, SPEC-016's next payout batch cycle sweeps the
backlog to the bound wallet without a new spec-level trigger.

**Migration for App-track users (SPEC-027-gated):** SPEC-025 §3.2's
dashboard "Set payout wallet" button is **present but disabled** in the
shipped app (`DashboardWindow.swift:59`; `setPayoutWallet` throws). When
SPEC-027 wires it, it will open the SPEC-016 EIP-712 signing flow
inline. If the user has no browser wallet, the button links to
guidance rather than a browser tab; this stays within the SPEC-026
§1.1 "no browser tab during onboarding" constraint because wallet
binding is post-onboarding.

### 4.3 v2 auth handshake — `identity_signature` on the proof-stage frame

**Issue #585 Option 2 ownership.** The coordinator-side `identity_signature` contract
below remains unchanged. The launchd-managed CLI is the sole admission-identity owner:
it loads the durable admission key from its Keychain service and signs the proof-stage
tuple directly. Malibu is a read-only status/repair client. The former App responder,
local request/response frames, and bridge timeout are removed, so auth transcripts and
admission signatures never cross the local control socket.

Per SPEC-001 v1.6 §6.7, fresh-connect authentication is a two-frame
challenge/response over the v2 pipeline:

1. Client sends `auth_request` (initial-stage) with
   `provider_id`, `binary_version`, and `provider_ecdh_public_key`.
2. Server issues `auth_challenge` (initial-stage response) with
   `auth_attempt_id` (server-generated).
3. Client sends the proof-stage frame (`type: "auth_request",
   stage: "proof"` per SPEC-001 v1.6 §6.7) with — per SPEC-026 — an
   OPTIONAL `identity_signature` field. The bearer token is NOT in
   this frame; it stays in the WebSocket upgrade's HTTP
   `Authorization: Bearer <provider_token>` header.

**SPEC-026 adds `identity_signature` to the proof-stage frame,
NOT the initial-stage frame.** The signature cannot land on the
initial-stage frame because `auth_attempt_id` doesn't exist yet at
that point — the client hasn't received the server challenge. v0.2
diagrammed it on the initial-stage frame; that was wrong.

Per SPEC-001 v1.6 §6.7 the proof-stage frame carries only:
`type`, `version`, `stage`, `auth_attempt_id`, `provider_id`,
`attestation_token`, and OPTIONAL SPEC-010 fields. ECDH is
initial-stage-only; it is NOT re-transmitted in the proof frame
(the client and server both cached it during initial stage).
v0.5 adds only two OPTIONAL fields to the existing proof-stage
frame:

```json
{
  "type": "auth_request",
  "version": 2,
  "stage": "proof",
  "provider_id": "p_…",
  "auth_attempt_id": "<server-issued from auth_challenge>",
  "attestation_token": "…",                                          // existing SPEC-001 field
  "identity_signature": "<base64-64-byte-ed25519>",                  // NEW, optional
  "identity_signature_transcript_sha256": "<base64-32-byte>"          // NEW, optional
}
```

`identity_signature` is Ed25519 signed with the key selected by principal type
(reconciled v0.17 — see §4.3 hardening below): the App identity key (§3.1) for
`p_`-prefixed provider_ids; the stable **bootstrap identity** for durable `mp-*`
principals; and the stored SPEC-015 receipt key only as the legacy fallback for `mp-*`
with no durable bootstrap row. Signed over
`JCS({auth_attempt_id, provider_id, binary_version, provider_ecdh_public_key, transcript_sha256})`
where each field is drawn from either the received `auth_challenge`
(`auth_attempt_id`) or from the client-cached values it sent in the
initial `auth_request` (`binary_version`,
`provider_ecdh_public_key`) plus a SHA-256 transcript hash of the
JCS-canonical initial-stage frame (`transcript_sha256`). The
transcript hash prevents replay of a valid proof against a
different initial-stage frame. Verification MUST run inside
SPEC-001's existing single-use `auth_attempt_id` lifecycle, which
releases retention on either success or reject.

`binary_version` in the signed tuple MUST retain the JSON string value from the
initial-stage frame. `CoordinatorClient` constructs the JCS tuple in-process and never
logs the payload, signature, bearer token, or private key material. If no CLI-owned key
matches the coordinator's authoritative identity hint, the client omits the signature
and admission fails closed under the server policy; there is no App fallback.

**CLI admission-identity generations, rotation, rollback, and recovery (v0.23).** The
initial-stage frame MAY carry:

```json
{
  "provider_admission_public_key": "<base64 current-or-recovery key>",
  "provider_admission_next_public_key": "<base64 staged next key; rotation only>",
  "provider_admission_recovery": true
}
```

The normal rotation transaction is:

1. CLI creates exactly one `.pending` Keychain key. Concurrent commands converge on the
   existing item; a restart retries the same candidate.
2. The complete canonical initial frame, including the next key, is transcript-hashed.
   The coordinator challenges its authoritative current generation and only that current
   private key may sign a rotation request.
3. After all admission checks and exact bearer confirmation, the coordinator performs a
   current-key + generation CAS, advances one generation, and retains the prior public key
   for seven days. Exact response-loss replay is idempotent.
4. The accepted response carries `admission_identity_public_key`,
   `identity_generation`, and `identity_admission_key_role`. The CLI commits only the
   staged private key named by that authenticated response, moves the old local key to
   `.prev`, and clears `.pending`.

During the seven-day grace, a rolled-back binary may authenticate with the previous key;
the response role is `previous`, the authoritative current public key is reported, and the
client enters `degraded_previous_key` without overwriting private-key custody or gaining
rotation authority. Both coordinator and CLI delete/ignore expired previous-key state.

Full local loss or migration from the dormant App/Postgres authority is explicit recovery,
not automatic enrollment. `credentials recover-admission-identity` first stages one durable
CLI candidate and reports its SHA-256 digest. The first operator creates a bounded recovery
request and a distinct second operator approves it. That one-shot authorization is bound to
the exact provider ID, candidate digest, authoritative current digest and generation,
incident ID, and expiry; generic migration or signature-exemption policy is never recovery
authority. `--activate` then restarts with `provider_admission_recovery`; the coordinator
accepts replacement only when the exact active bearer owns the provider, the staged key
signs the recovery-marked transcript, and the exact approved authorization is still live.
The key-generation CAS, one-shot authorization consumption, and redacted audit insert occur
in one SQLite transaction. Success increments the generation and does not retain the
inaccessible prior key. An inactive/revoked identity remains fail-closed. Interrupted
staging converges on the already-persisted candidate, and no manual database or Keychain edit
is part of the supported transaction.

V1 admission MUST reject every provider with a durable admission identity, regardless of
provider-ID prefix; otherwise a bearer could downgrade around the signature requirement.

**Cutover — server-side authoritative, client-declared version
untrusted:**

Coordinator maintains a NEW cross-track auth-policy table (NOT on
`provider_identities`, which is App-track-only):

```sql
CREATE TABLE provider_auth_policy (
  provider_id             TEXT PRIMARY KEY,
  kind                    TEXT NOT NULL,           -- "app" | "cli"
  signature_exempt_until  TIMESTAMPTZ NULL,        -- NULL means "must sign"
  granted_by              TEXT NOT NULL,           -- "migration" | "operator:<admin_id>"
  granted_reason          TEXT NOT NULL,
  granted_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

Auth-policy logic (unified for App-track and CLI-track):

```
row = SELECT * FROM provider_auth_policy WHERE provider_id = ?
if row IS NULL
   OR row.signature_exempt_until IS NULL
   OR NOW() > row.signature_exempt_until:
    REQUIRE valid identity_signature on proof-stage auth_request
    else: close 4003 identity_signature_required
else:
    accept bearer-only for this session; log
    provider_auth_policy_exempt_used with the granted_by tag
```

Note: `signature_exempt_until IS NULL` and `row IS NULL` are
BOTH treated as "must sign" — a `NULL` in the column is not the
same as "no expiry." A literal implementation that only checks
`NOW() > row.signature_exempt_until` would incorrectly grant
bearer-only auth when the column is `NULL`.

The `signature_exempt_until` column is populated ONLY by:

- **One-time migration** on the release that ships this spec: every
  `p_`-prefixed provider_id AND every CLI-track provider_id that
  existed at migration time gets `signature_exempt_until =
  migration_time + 7 days` (v0.4 tightened from v0.3's 30 days per
  R3 SEC finding). Rows carry `granted_by = "migration"`,
  `granted_reason = "spec-026-cutover-legacy"`. New provider_ids
  minted after migration MUST NOT get an exempt row from the
  migration path.
- **Explicit operator action** via a two-stage admin flow backed
  by a NEW pending table `provider_auth_policy_pending`:

  ```sql
  CREATE TABLE provider_auth_policy_pending (
    pending_id             UUID PRIMARY KEY,
    provider_id            TEXT NOT NULL,
    requested_by           TEXT NOT NULL,      -- "operator:<admin_id>"
    requested_until        TIMESTAMPTZ NOT NULL,
    reason                 TEXT NOT NULL,
    incident_id            TEXT NULL,          -- required if committed_ttl > 7 days
    approved_by            TEXT NULL,          -- "operator:<admin_id>", must != requested_by
    approved_at            TIMESTAMPTZ NULL,
    committed_at           TIMESTAMPTZ NULL,   -- non-null when row folded into provider_auth_policy
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (approved_by IS NULL OR approved_by <> requested_by)
  );
  ```

  Two-step flow:
  1. Requester (operator A) calls
     `POST /admin/provider-auth-policy/exempt` with:
     - `provider_id` MUST already exist at time of grant
     - `requested_until - NOW() <= 30 days` (server-side hard
       ceiling)
     - `reason` REQUIRED
     - `incident_id` REQUIRED if `requested_until - NOW() >
       7 days` (break-glass path)
     Inserts a `provider_auth_policy_pending` row. No effect on
     `provider_auth_policy` yet.
  2. Approver (operator B) calls
     `POST /admin/provider-auth-policy/exempt/{pending_id}/approve`
     with:
     - `approved_by != requested_by` (enforced by the table's
       `CHECK` constraint plus API-side `403 dual_control_required`)
     - Approval commits the row into `provider_auth_policy` and
       sets `provider_auth_policy_pending.committed_at`.
  3. Cumulative renewal cap: the sum of
     `signature_exempt_until - first_granted_at` across all
     historical grants for a given `provider_id` MUST NOT exceed
     30 days without an explicit break-glass rotation event
     (which requires a fresh incident ID). Enforced by a check
     in the pending-insert step. Prevents insider-driven
     monthly renewals holding a legacy identity in bearer-only
     mode indefinitely.

  Every grant AND approval emits an audit event
  (`admin_action: exempt_provider_id_requested`,
  `admin_action: exempt_provider_id_approved`) with the actor,
  reason, TTL, and incident ID.

The client's self-reported `binary_version` is used only for
observability, never for auth policy.

**CLI-track hardening:**

- **Legacy CLI provider_ids** (issued before this spec's release):
  covered by the migration exemption above, cap 7 days. Legacy CLI
  providers upgrading beyond 7 days require operator-issued
  extension per the admin path above.
- **New CLI provider_ids** issued after the App-track cutover use the
  same proof-stage `identity_signature` flow, but the verify key is
  selected by the principal-branched rule below (reconciled v0.16 to
  `identity_signature.go:118-159`), NOT unconditionally the receipt key.
  Coordinator recognizes the CLI variant by absence of the `p_` prefix.
  For a **durable `mp-*` bootstrap principal** (the shipped provisioning
  path via `bootstrap-auth`) the verify key is the stable **bootstrap
  identity** (`:132-138`), which is what makes receipt-key rotation
  possible without self-signing. Only a **legacy `mp-*`** with no durable
  bootstrap row falls back to the receipt pubkey resolved from the
  **live provider registry** (`currentReceiptPubkey` → `s.pool`,
  `identity_signature.go:153-163`; the same ephemeral-registry source
  backing `/v1/receipt-keys/{provider_id}`, `buyer/server.go:1121`,
  `provider.go:1791`). This fallback therefore requires a **live pool
  entry** — there is no durable `internal/receipts.LookupCurrentPubKey`
  store.
- **SPEC-015 receipt-key rotation composes as follows (reconciled
  v0.16 to shipped `phase4-coordinator/internal/ws/identity_signature.go`
  + `internal/pool/provider.go` and the v0.13 change-log old-key rule).** The
  key the coordinator uses to VERIFY `identity_signature` is selected by
  principal type (`identitySignaturePubkey`, `identity_signature.go:118-159`):
  1. **`p_*` App-track principal** → the durable App identity pubkey
     (`LookupProviderIdentityPubkey`). Client-dormant (§3).
  2. **`mp-*` credential-bootstrap principal** → the durable **bootstrap
     admission-identity pubkey (`LookupAdmissionIdentityState`), which is
     independent of receipt-key rotation and may advance by §4.3 generation CAS. A revoked/inactive durable
     binding → reject (`nil,false`, `:142-149`); only a proven ABSENCE of
     any durable bootstrap row falls through to the legacy path.
  3. **Legacy / no durable row** → the **stored** receipt pubkey
     (`currentReceiptPubkey`, `:153-159`); the frame is authorized only if
     `bytes.Equal(initial.ProviderReceiptPubkey, stored)` — a differing key
     is rejected.

  So a receipt-key-rotating provider re-authenticates under an admission
  identity that is **independent of the key being rotated** — the
  identity for durable `mp-*` principals — **never** by
  self-signing the proposed new key (satisfying the v0.13 change-log rule).
  The new receipt key rides the register/reconnect frame and is rotated
  **in-band**: staged as `PendingReceiptPubkey` at register
  (`stageReceiptPublicationLocked`, `provider.go:779`), then **committed on
  the first accepted `state_update`** (`commitPendingReceiptPubkeyLocked`
  via `ApplyStateUpdate`, `provider.go:839,1753`) — at which point the new
  key becomes current and the **old key moves to `receipt_pubkey_prev` and
  the grace window STARTS** (`ExpiresAt = now + ReceiptRotationGrace`).
  Commitment precedes the grace period; the grace window keeps the OLD key
  valid for in-flight work AFTER commit, not as a pre-commit delay. A
  differing key presented while a grace window is already active is refused
  (`RegisterRefusalReceiptRotationGraceActive`).

  **Legacy principals (no durable bootstrap row) CANNOT rotate via this
  path (reconciled v0.20).** Their `identity_signature` is verified against
  the STORED receipt key with byte-equality (case 3 above,
  `identity_signature.go:149-160`), so a rotating initial frame carrying the
  NEW key (`CoordinatorClient.swift:941`) is rejected at admission **before**
  it can reach the staging logic. In-band receipt-key rotation is therefore
  available only to durable `mp-*` bootstrap principals, whose admission
  does not depend on the rotating key; a legacy principal must re-provision
  (obtain a durable bootstrap identity) rather than rotate in-place.

This keeps both tracks fail-closed against self-declared rotation while
supporting in-band receipt-key rotation for bootstrap principals.
SPEC-001 v1.7 candidate will absorb this normative text with the exact
field names.

### 4.4 Retire portal OAuth for the App track

The `portal.malibu.tech/onboard` GitHub OAuth flow is retired **for
the App track only** on the release that ships this spec's
implementation. CLI track continues to use it during migration.
Portal deletion is out of scope; portal maintainers mark the endpoint
deprecated in its public docs.

**Retirement observability:**
`provider_register_source{track="app"|"cli"|"portal"}` counter is
incremented on every new-provider registration.
`portal.malibu.tech/onboard` completions are labeled
`track="portal"`. Retirement trigger for the portal endpoint
itself: `portal` counter < 10/day for 14 consecutive days.
**Owner: operator.** Review cadence: monthly. When the trigger
condition first fires, the operator files a follow-up spec to
close out the portal endpoint.

### 4.5 App-track wallet-swap coercion defense — deferred to SPEC-027

v0.7 rescopes the verified-email out-of-band cancellation channel
to a follow-up SPEC-027 (App-track wallet-swap coercion defense).
The following surface moves out of SPEC-026 and lives in SPEC-027
instead:

- `notification_email` column on `provider_identities`
- `provider_email_change_requests` table
- Three-path channel-authority transfer (old-email approval OR
  currently-bound-wallet EIP-712 OR dual-control operator recovery)
- `malibu-app://` deep-link URL scheme + host routes
  (`verify-email`, `approve-email-change`, `reject-email-change`)
- `POST /v1/providers/{id}/notification-channel` endpoint
- HMAC-signed cancel URL, GET-confirmation + POST-mutation split
- EIP-712 `EmailChangeAuthorization` typed-data domain
- Fresh-install re-ratification at first wallet bind
- Rate-limiting (1 change per 7 days)

Until SPEC-027 lands, **App-track wallet binding/swap is not available
at all** (reconciled v0.16): the shipped coordinator returns
`501 wallet_change_requires_spec_027` (§4.2, `main.go:1284`) and
`setPayoutWallet` throws, so there is no interim EIP-712 swap path to
protect — the SPEC-016 §3 EIP-712 composition is the *designed*
post-SPEC-027 mechanism, not an active interim one. The App-track UI does
not surface a wallet-binding or cancellation channel; §9.3 is the
operator-visible pointer to SPEC-027.


## 5. Sybil resistance — layered, no single gate

### 5.1 Provisional tier (default for every new provider)

| Constraint            | Provisional | Trusted     |
|-----------------------|-------------|-------------|
| Concurrent slots      | 1           | ≥ 4         |
| Daily $MALIBU emit cap| 25 MALIBU   | uncapped    |
| Provisional $MALIBU   | non-withdrawable until Trusted | withdrawable |
| Per-wallet emission cap | 100 MALIBU / bound wallet / day (across all provider_ids) | uncapped |
| Payout delay          | 7 days      | 24 hours    |
| Rate limit tier       | strict      | normal      |
| Verified-receipt only | REQUIRED    | REQUIRED    |

Rate-limit strict means: `/register` per-IP 5/min, per-ASN 30/min
(backpressure, not sybil defense — see next paragraph); WS sessions
per `provider_id` 1; heartbeat interval floor 30s.

Per-ASN limits are **backpressure telemetry**, not sybil defense. With
~70k routable ASNs, `30/min/ASN × 70k = 2.1M/min` theoretical global
ceiling. The load-bearing sybil defense is the combination of
provisional non-withdrawable $MALIBU + verified-receipt-only earnings
(SPEC-022) + per-wallet emission cap.

**Enforcement primitives — deferred to SPEC-021.** The prose
"non-withdrawable" and "per-wallet cap" phrases above are
enforced by a rewards-emission ledger (schema, isolation, and
cross-DB projection of the SPEC-016 payout-address binding) that
v0.6 attempted to define inline. v0.7 rescopes that subsystem
to a follow-up SPEC-021 (MALIBU rewards emission ledger).
SPEC-021 owns:

- `provider_rewards_ledger` MALIBU extension
  (`amount_malibu` + `withdrawal_hold_reason`; existing
  `amount_usd NOT NULL` dropped in the same migration).
- `wallet_daily_malibu_emission` aggregate table with
  SERIALIZABLE isolation + retry-on-40001, on a dedicated
  Postgres `rewards_writer` role.
- `provider_emission_state` cross-track table with
  `cap_replay_pending` flag.
- Postgres projection of the SPEC-016 SQLite
  `provider_payout_addresses` table, maintained by a
  replication worker off SPEC-016's data source (WAL
  replication, trigger-outbox, or periodic snapshot polling —
  choice deferred to SPEC-021).
- Staleness monitoring using a replication-health metric
  (worker heartbeat + WAL lag), NOT the age of the most
  recent wallet-binding row.
- Replay-through-cap at first wallet bind, oldest-first, in
  the same aggregate lock as live emissions.

**Ordering implication for SPEC-026 v0.7.** Provisional
$MALIBU cannot be honored as non-withdrawable until SPEC-021
ships. Two operational stances are compatible with SPEC-026
alone: (a) MALIBU emissions do not flow at all until SPEC-021
lands (safest), (b) MALIBU emissions flow ad-hoc under an
informal coordinator-side hold that will fold into SPEC-021's
`withdrawal_hold_reason` column at cutover. The operator
picks. In either case, SPEC-026 §5.1 sybil-defense narrative
(provisional tier, per-wallet cap principle) is authoritative
for spec purposes; SPEC-021 owns enforcement.

The 100 MALIBU/day per-bound-wallet cap number is a starting
guess pending cohort telemetry (§13 open question). SPEC-021
MUST make the cap config-backed.

### 5.2 Trust unlock criteria (economic + non-economic)

A provider unlocks Trusted when **at least ONE economic criterion
AND at least ONE additional criterion of any kind** hold
concurrently.

- **Economic criteria** (any one satisfies the economic requirement):
  - **E1.** ≥ 100 settled receipts (SPEC-022 verified) with
    `receipt_verify_ok = true`.
  - **E2.** Payout wallet bound (§4.2) AND that wallet holds ≥ 100
    USDC continuously for 72h per criterion #3 below.
  - **E3.** Manual operator promotion (support flow). Recorded with
    reason; treated as an economic criterion because operator
    promotions are extended only after human review of on-chain or
    receipt history.
- **Additional criteria** (any one of, on top of an economic
  criterion):
  1. ≥ 72h uptime with `heartbeat_gap < 5min` throughout.
  2. Any of E1/E2/E3 above (a second economic criterion counts here).
  3. Payout wallet bound (§4.2) AND that wallet holds ≥ 100 USDC on
   Base **continuously for the full 72h unlock-eligibility window**,
   verified by SPEC-016's existing dual-RPC read pattern with both
   `balanceOf(wallet)` reads on the pinned Base USDC contract
   `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` agreeing to the
   satoshi. Coordinator checks are randomized at intervals of
   15min–4h to prevent an attacker funding around a predictable
   check window. Any single check reading below 100 USDC (with
   both RPCs agreeing) resets the 72h clock; disagreement between
   the two RPCs fails closed (criterion not satisfied for that
   check). If the balance falls below 100 USDC after unlock and
   the provider's only remaining Trusted qualification was this
   criterion, the provider is demoted to Provisional (§5.5).
   Prevents "deposit, unlock, withdraw" recycling. Randomized
   sampling uses a Poisson process with mean interval 60 minutes
   (server-secret-scheduled), floor 15 min, ceiling 4 h. The
   scheduler state is coordinator-side and never observable to the
   provider.
  4. Valid App Attest evidence at registration (§5.3), with a
     unique `app_attest_key_id` not previously seen against another
     `provider_id`. This is bundle-integrity + anti-replay evidence,
     not an economic cost layer (§11 details), so it counts as an
     ADDITIONAL criterion but NOT an economic one.

Unlock is provisional-to-trusted when **two DISTINCT satisfied
criterion IDs co-hold**, at least one of which is an economic
criterion (E1/E2/E3). "Distinct" means the same real-world
condition cannot satisfy both slots: e.g., a provider whose ONLY
qualifications are "wallet holds ≥100 USDC continuously" cannot
count that condition as both the E2 economic slot AND the
additional criterion #3. In that case the provider does not
unlock. Downgrade is possible per §5.5 when any criterion that
provided qualification lapses.

### 5.3 App Attest — opportunistic, replay-hardened

> **NOT implemented client-side (reconciled v0.14).** The shipped Malibu app does
> **not** call `DCAppAttestService` — there is no App Attest implementation in the app
> tree, and current main deletes the former `RegisterClient` passthrough. The
> register path remains dormant (§4.1). So "valid App Attest evidence unlocks trust
> benefits" is a **coordinator-verifier contract + future client**, not shipped
> behavior. **Hash-contract note (reconciled v0.16):** the coordinator hashes the JCS
> member **named `ts_utc`** with an **integer Unix-seconds value** (it parses the RFC3339
> `ts_utc` and converts to Unix seconds before hashing — `apptrack.go:518,527`). A future
> client implementing §5.3 MUST keep the member name `ts_utc` and hash the **Unix-seconds
> integer** — NOT the RFC3339 string, and NOT a renamed `ts_utc_unix` member; either would
> produce a different JCS hash and an unverifiable attestation.
> **Carried coordinator gap (reconciled v0.16):** the shipped verifier does NOT enforce
> the environment-specific AAGUID — `SkipAAGUIDEnforce` is declared but unused and the
> parser skips all 16 AAGUID bytes (`appattest.go:44-50,195-214`), so a *development*
> attestation could verify as `attested=true`. Exposure is low because no shipped client
> mints App Attest evidence (client-dormant, above); production-AAGUID enforcement is a
> tracked coordinator hardening item, not a SPEC-026 client contract.

App-track binary calls `DCAppAttestService.attestKey(_:clientDataHash:)`
with:

```
clientDataHash = SHA256(JCS({
  provider_id,
  identity_pubkey,
  register_nonce,          // = the /register `nonce` field
  coordinator_domain,      // canonical "coordinator.malibu.tech" (bare host, lowercase, no scheme, no trailing slash)
  bundle_id,               // "tech.malibu.app"
  team_id,                 // Apple Developer Team ID that signed the app
  ts_utc                   // member NAME stays `ts_utc`; VALUE is the Unix-SECONDS integer (int64) from parsing /register `ts_utc` — matches coordinator apptrack.go:518-527; NOT the RFC3339 string (see §5.3 hash-contract banner)
}))
```

The attestation object and its `keyId` are sent as
`app_attest_object` + `app_attest_key_id` in the `/register` body.
Coordinator verifies against Apple's App Attest CA root and MUST
also:

- Re-derive `clientDataHash` from the register body and reject on
  mismatch (closes SEC-2 replay).
- Reject if `app_attest_key_id` is already in
  `provider_identities` for a different `provider_id`
  (attestation-key reuse detection).
- Persist `app_attest_key_id` on the `provider_identities` row.

Valid attestation:
- counts as one §5.2 unlock criterion
- bumps `/register` and heartbeat rate limits by 3×
- displays a green "verified Mac hardware" chip on buyer-facing UI

Missing attestation, and TRANSIENT attestation failures (Apple service
unreachable / timeout — `ErrAppAttestTransient`), are NOT a rejection at
the endpoint level. Reason: `DCAppAttestService` requires the app be
signed by a paid Apple Developer Program certificate and Apple's
attestation service be reachable; either can fail transiently in ways
that would otherwise block 100% of new providers. **Structurally
invalid / binding-failed / key-reused evidence IS rejected**
(`apptrack.go:346-388`); only transient failures degrade to
`trust.attested = false`. Per §11 second-biggest risk,
attestation-service-error-rate is monitored and criterion #4 is
loosened during Apple outages.

### 5.4 Verified-receipt-only earnings

Per SPEC-022, earnings only accrue from receipts that pass
`macprovider-verify`. This is not a new layer; it already blocks the
naive "fake work" sybil vector. Called out here so the
sybil-resistance stack reads as an audit.

### 5.5 Downgrade path and requalification cooldown

A Trusted provider is demoted back to Provisional when:

1. A criterion that provided qualification lapses (wallet balance
   drops below 100 USDC, App Attest revoked, etc.), AND
2. The §5.2 "economic + additional" pairing no longer holds.

Demotion reinstates the 7-day payout delay and daily emission cap.
Existing settled receipts and past withdrawals are not clawed back.

**72h requalification cooldown.** After a demotion, the provider
MUST re-satisfy the §5.2 unlock criteria continuously for 72h
before Trusted privileges reinstate. This prevents rapid demote /
re-promote oscillation (attacker briefly drops below the 100 USDC
floor and re-funds to pop back into Trusted at will). The 72h
counter resets on any criterion drop during the requalification
window.

### 5.6 Behavioral risk score (future)

Placeholder for a later spec: track per-provider distributions of
latency, throughput, and receipt-verify pass rate; flag outliers for
slower payout release. Not required for this spec to ship.

## 6. User flow — click-and-earn

> **Wallet-binding scope banner (reconciled v0.14).** Every "Add a payout wallet" /
> "Change" / EIP-712 inline-binding affordance described in §6 (success card §6.1
> step 8, steady state §6.2, §6.3) is a **guarded SPEC-027 stub in the shipped app**:
> `setPayoutWallet` throws unconditionally, the button is disabled
> (`LaunchProviderController.swift:94-100`, `OnboardingWindow.swift:137`), and the
> coordinator returns `501 wallet_change_requires_spec_027` (§4.2 / v0.13 change log).
> The prose below describes the intended UX; treat all active wallet-binding language
> as SPEC-027-gated, not shipped. The read-only "unclaimed earnings" / "add a wallet"
> **prompts** (display only) are fine; the binding **action** is not wired.

### 6.1 Cold install

1. User double-clicks `Malibu.app` from a downloaded `.dmg`.
2. Menu-bar icon appears. `AppDelegate.applicationDidFinishLaunching`
   fires.
3. `ProviderConfig.isConfigured == false` (reconciled v0.15 — the
   shipped cold-install path gates on config / `.installed-by-app`
   marker / provider ID, plus a matching `.cli-credential-custody-v1` marker; no App
   bearer or `ProviderIdentity.isReady()` gate exists). No configured provider present.
4. `presentOnboarding()` opens the launch window (same NSWindow as
   today, new content — see §7.2).
5. Window contents:

   - Header: brand tile + "Malibu" small caps + "Launch your provider."
   - Sub: "One click and your Mac starts earning USDC + $MALIBU."
   - Body: "Add a payout wallet anytime after setup — nothing to
     enter now." (No wallet input field on the launch window;
     wallet binding lives on the post-success card + dashboard
     per §1.1 "no wallet-signing prompt during onboarding".)
   - Primary button (coral): **Launch Provider**
   - Secondary link: "How does this work?" (opens an in-App info
     sheet, not a browser tab)

6. User clicks **Launch Provider**. The button is replaced by an
   in-window progress ring + step label; the `LaunchProviderController`
   stage machine (§7.2) owns the flow.
7. Steps happen in the background (reconciled v0.14 to the shipped
   CLI-wrapper flow — `LaunchProviderController.launch()`):

   Normal-success stage order is `.idle → .runningCLIInstall → .startingAgent →
   .live` (`.importingProviderCredential` is entered only on a **deferred
   missing-token retry** after `.startingAgent`, not on the happy path —
   `LaunchProviderController.swift:117-138,165-180`).

   a. **Short-circuit:** if a local provider is already healthy AND has a provider
      id, a port, and readable launchd evidence (`install_manifest.json` /
      `live.malibu.provider.plist`), skip the installer and attach
      (`CLIInstallRunner.swift:89-103`; `LaunchProviderController.swift:79-87`).
   b. **Run the bundled `install.sh`** (`.runningCLIInstall`) by authenticating
      the exact bundled regular-file bytes and supplying those same bytes to
      `/bin/bash -s --` over stdin with **no script-path or installer CLI args**.
      **Environment is sanitized (reconciled v0.25 to current source):**
      `CLIInstallRunner.installerEnvironment` constructs a new allowlist with
      fixed `PATH`, validated `HOME`/`TMPDIR`, `LC_ALL`,
      `MACPROVIDER_NO_PROMPT=1`, and its validated port/version inputs; it does
      not inherit the parent process environment. SPEC-034 adds only the path to
      the validated one-shot owner-only referral source file as
      `MACPROVIDER_REFERRAL_CODE_FILE`; the raw code is not an environment value.
      **`install.sh` runs the
      CLI-track onboarding:** it generates a fresh `mp-<32hex>` principal and runs
      `bootstrap-auth`, which acquires the `provider_token` via the coordinator's
      **tokenless WS admission** handshake (NOT the App-track `/v1/providers/register`,
      §4.1); it also runs the SPEC-023 `autotune --recommend`, downloads model
      weights, and installs the launchd provider service + watchdog. The app surfaces a progress hint by
      scraping `ps` for the autotune stage (`:110-149`). **The initial token import
      happens here, still in `.runningCLIInstall`.**
   c. **Verify CLI credential custody** (`ProviderConfig.importExistingCLIConfig()`,
      `:128`): for an existing YAML bearer, invoke the installed CLI with `credentials import
      --config` and a distinct fresh-process `credentials verify --config`. Fresh
      tokenless bootstrap runs verify-only. Both paths use one immutable private 0600
      snapshot and emit redacted metadata only. A legacy tokenless YAML whose only
      surviving bearer is the App compatibility item is first repaired back to private
      live YAML and then takes the token-bearing path; after the second CLI process
      proves custody, Malibu deletes and verifies deletion of that legacy item. The App
      writes its ownership and provider-ID-bound custody markers. A
      restarted CLI removes it only after Keychain-backed coordinator admission and a
      successful first state update. A missing/old CLI credential or failed proof
      preserves the original config and removes partial App ownership state.
   d. **Finalize** (`.startingAgent` → `finalizeInstall`, `:165-199`): wait for the
      launchd provider's `GET /v1/health`, retry the token import, then check
      **`appIdentityConfigured`, which is actually `ProviderConfig.isConfigured`**
      (config + `.installed-by-app` marker + provider ID + the matching
      `.cli-credential-custody-v1` marker, `:65`,
      `ProviderConfig.swift`) — **NOT** `ProviderIdentity.isReady`. The launchd
      health/status response separately proves CLI credential readiness. Attach the
      `MalibuAgent` **monitor** (no child spawn), then register the `SMAppService`
      login item and mark `.live(model, tier: .provisional)`. The login item is
      registered **only after** a successful attach.
   e. **The App `p_*` Ed25519 implementation is absent.** The shipped provider identity is the CLI-track `mp-*`
      principal, whose durable admission credential begins as the **bootstrap identity** (a
      CLI-owned rotatable snapshot of the first receipt key, `ReceiptKeyStore.swift`)
      and whose rotatable receipt key signs SPEC-015 receipts. The former App identity,
      registration client, and `identity_signature` responder are removed (§3/§4.3).
   f. **Wallet binding is NOT part of the launch flow** and is a **guarded SPEC-027
      stub**: `setPayoutWallet` throws unconditionally
      (`LaunchProviderController.swift:94-100`) and the shipped affordance is disabled
      (`OnboardingWindow.swift:137`). All active wallet-binding language in this spec
      is gated on SPEC-027.

8. Success card, in the same window:

   - Big check + "Provider live"
   - Model chip: `<autotune-recommended-model>`
   - Two live counters (USDC today, MALIBU today). **Reconciled v0.15:**
     the shipped success card renders static placeholders (`$—` /
     `Locked`) until real earnings arrive rather than animating from 0
     (`OnboardingWindow.swift:129`); the animated-counter + lock-microcopy
     design below is intended UX, not yet wired.
     **The MALIBU counter carries a small lock icon +
     inline microcopy "unlocks at Trusted" whenever the
     provider is in Provisional tier** (§5.2), so the
     non-withdrawable state is inherent to the display rather
     than a one-time whisper in a caption.
   - **When no payout wallet is bound**, a callout with visual
     weight EQUAL to the counters (matching type size and
     accent color) reads: `Add a payout wallet to receive your
     first payout →`. The link opens the SPEC-016 §3 EIP-712
     wallet-binding flow inline. A first-run user closing the
     window here MUST NOT reasonably believe their earnings
     are being credited to them without further action; the
     copy makes the unclaimed state legible.
   - **When a wallet is already bound**, the row reads
     `Payout wallet: 0x…abcd` with a subtler "Change" link
     (goes to the same SPEC-016 §3 endpoint, subject to that
     spec's cooling-window rules).
   - Trust tier row: `Provisional — earn up to 25 MALIBU/day
     (non-withdrawable until Trusted). Unlock Trusted →` (link opens
     `docs/trust-tiers` in the App, not a browser tab)
   - Primary button: "Open Dashboard"
   - Secondary: "Close" (window closes, menu bar keeps running)

### 6.2 Steady state

Menu-bar icon shows live status per SPEC-025 §3.2. **Reconciled
v0.15/v0.18 — routing is evaluated ONCE per app launch, not continuously.**
`StartupState.detect().route()` runs at `applicationDidFinishLaunching`
(`MalibuApp.swift:21,115`); mid-session there is no watcher that re-opens
onboarding — the user re-triggers it via the explicit menu action
(`MalibuApp.swift:83`) or a relaunch. On the **next app launch**, routing
sends the install to onboarding when (1) `ProviderConfig.isConfigured` is
false (config / `.installed-by-app` marker / provider ID, with the conditional custody
marker above — NOT the dormant App identity; e.g. after uninstall+reinstall or loss
of required App-local custody evidence), OR (2) a fully-configured App-owned install has
**launchd install evidence missing** (`route()`,
`LaunchProviderController.swift:352`; §7.6 / §8 precedence table). A
markerless CLI-owned config instead routes to the import dialog.

**Persistent MALIBU-locked display invariant.** Anywhere in the
App-track UI where a MALIBU balance or per-day counter is
rendered — success card, menu-bar tooltip, dashboard, notification
copy — the display MUST carry a lock icon and the microcopy
"unlocks at Trusted" as long as the provider is in Provisional
tier. This turns the non-withdrawable state into a persistent
property of the number rather than a one-time onboarding
whisper. On Trusted unlock, the lock icon disappears in the same
render pass.

**Unclaimed-earnings badge invariant.** Whenever
`unpaid_ledger_backlog_usdc + unpaid_ledger_backlog_malibu`
(measured in USDC-equivalent) crosses $1.00 while no payout
wallet is bound, the menu-bar icon MUST carry an "unclaimed
earnings" badge (small dot on the icon plus tooltip "You have
unclaimed earnings — add a wallet") until either (a) a wallet is
bound and the backlog sweeps, OR (b) the user explicitly
dismisses the badge for that session (dismissal resurfaces the
next launch until threshold #2 fires at $10 USDC-equivalent,
then again at $100). Prevents a first-run user from silently
losing awareness that earnings are piling up unclaimed.

**Before SPEC-027 ships, `Malibu.app` MAY show only a read-only
pending-swap row and MUST NOT add a Cancel affordance or
cancellation action.** The corresponding backend cancel contract
(SPEC-016 §3 addendum for `provider_wallet_swaps` + SPEC-027's
coordinator-issued cancel URL) is not part of SPEC-026, so adding
in-app Cancel would produce false user assurance backed by no
defined coordinator path. Any App-track UI surface for
pending-swap cancellation is specified by SPEC-027, not
SPEC-026.

### 6.3 Window closed mid-setup

Any close during the step-7 install sequence cancels the window but not
the underlying Task. `LaunchProviderController` continues in the
background (reconciled v0.15). Reopening via the menu bar rebinds the
SwiftUI view to the same in-memory controller and picks up mid-progress.
No resumable state is persisted (§1.1, §7.5).

### 6.4 Errors

Any step failure sets the controller to
`.failed(stage, retryable, message)`. Window shows:

- Red icon + human copy for the failure (e.g. "Couldn't reach the
  marketplace. Check your connection.")
- **Primary button: Retry** — **reconciled v0.15/v0.16:** the shipped
  `retry()` calls `launch()` from the **beginning**, not from the failed
  stage (`LaunchProviderController.swift:89`). `launch()` itself then
  **short-circuits**: if a local provider is already healthy with a
  provider id, port, and launchd evidence it skips `install.sh` and
  attaches directly (§6.1 step 7a, `LaunchProviderController.swift:79`,
  `CLIInstallRunner.swift:89`); otherwise it re-runs install → import →
  attach. So a retry re-runs only the stages the short-circuit does not
  satisfy — not unconditionally the whole sequence.
- Secondary: "Contact support" (opens `mailto:` — no browser tab)

**Reconciled v0.15:** the shipped controller marks **every** failure
`retryable` (`LaunchProviderController.swift:126,173`), so there is no
non-retryable "Quit-only" surface in the current build. The "Quit
secondary for Keychain-unusable / disk-full" case is a designed state
the shipped code does not yet distinguish.

### 6.5 Uninstall

SPEC-025 §3.4 uninstall flow additionally wipes:

- Any historical App-owned provider bearer/identity items. Production Malibu cannot
  create replacements for them.
- The SPEC-015 receipt-key Keychain item is NOT wiped by SPEC-026
  uninstall — the receipt key survives per SPEC-015 rules (it may
  need to sign closure receipts for in-flight work). SPEC-015 §12
  owns its lifetime.
- Any partial-download files under
  `Application Support/Malibu/Downloads/`
- The onboarding state JSON at
  `Application Support/Malibu/onboarding.json`

Uninstall does NOT unbind the payout wallet. Prior earnings, if any,
settle to the bound wallet regardless of the Mac's fate. See §9.

## 7. Swift implementation

### 7.1 Removed App identity and registration authority

Issue #585 deletes `ProviderIdentity.swift`, `RegisterClient.swift`, their tests, and
the App-side admission-signature bridge. `KeychainStore` can read/delete a legacy App
bearer for migration but its save API is DEBUG-only so production App code cannot
recreate custody. `ProviderEarningsClient` lives in the CLI; Malibu decodes only its
non-secret control-socket projection. Shipped onboarding and startup routing gate on
`ProviderConfig.isConfigured` and the CLI-authored versioned status contract.

### 7.2 New controller: `LaunchProviderController`

```swift
// phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift
@MainActor
final class LaunchProviderController: ObservableObject {

    // Reconciled v0.14 — shipped stage machine (LaunchProviderController.swift:14-21).
    // The in-app registering/autotuning/downloading/authenticating stages are gone;
    // install.sh owns register+autotune+download and launchd owns the daemon.
    enum Stage: Equatable {
        case idle
        case runningCLIInstall            // running the bundled install.sh
        case startingAgent                // finalize: wait /v1/health, attach monitor
        case importingProviderCredential  // stage provider_token into CLI Keychain
        case live(model: String, tier: TrustTier)
        case failed(stage: String, retryable: Bool, message: String)
    }

    @Published private(set) var stage: Stage = .idle

    func launch() async     // runs install.sh, imports token, attaches the monitor
    func retry() async      // reconciled v0.16: re-enters launch() from the START (not the failed stage) — LaunchProviderController.swift:89
    // Reconciled v0.14 — wallet binding is a guarded SPEC-027 follow-up:
    // setPayoutWallet always throws until SPEC-027 defines the non-bearer proof.
    func setPayoutWallet(_ address: String) async throws
}
```

**Reconciled v0.14:** the controller does NOT register, autotune, download, or spawn
in-process. `runCLIInstall` runs the bundled `install.sh`;
`importCLIConfigAfterInstall` moves the token to Keychain; `finalizeInstall` waits for
`/v1/health` and attaches the `MalibuAgent` monitor (§6.1). Production onboarding no
longer writes `onboarding.json` (§7.5).

### 7.3 Delete: `PendingLinkState`, `URLSchemeHandler.malibu` — SHIPPED (reconciled v0.14)

**These removals are DONE — PR #418 removed the `malibu://` onboarding.** Grep over
`phase3-binary/app/Sources` + `Tests` confirms: no `MalibuOnboardingPolicy`, no
`MALIBU_ONBOARD_V2`, no `resumeOnboarding`/`setupPaused`, no `application(_:open:)` /
`CFBundleURLSchemes` (only a tombstone comment at `MalibuApp.swift:35-38` records the
v0.11 removal). Current main also deletes `RegisterClient.swift` and its tests;
there is no compiling App registration client to reuse. The original line-level
removal list below is retained as provenance.

Removals (historical — now completed):

- `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift` —
  delete the file wholesale.
- `phase3-binary/app/Sources/Malibu/MalibuApp.swift:37-45` — the
  `application(_:open:)` `malibu://` handler.
- `phase3-binary/app/Sources/Malibu/MalibuApp.swift:107-125` — the
  `.consume(.providerLinked)` branch.
- `phase3-binary/app/Sources/Malibu/MalibuApp.swift:163` — the
  `PendingLinkState.discard()` call.
- `phase3-binary/app/Sources/Malibu/Onboarding/OnboardingWindow.swift:55`
  — the `PendingLinkState.beginLink()` call. The whole
  `OnboardingWindow` is replaced by the SwiftUI view backing
  `LaunchProviderController` (§7.2).
- `phase3-binary/app/Tests/MalibuTests/PendingLinkStateTests.swift`
  — delete the file wholesale.
- Any README or `Info.plist` `CFBundleURLSchemes` entry for
  `malibu://` — delete.

**URL scheme registration for SPEC-027 is out of scope.** v0.6/v0.7
required registering a new `malibu-app://` deep-link scheme for the
email verification / approval / rejection flows. Those flows moved
to SPEC-027 (see §4.5). Any deep-link scheme SPEC-027 needs is
SPEC-027's normative surface; v0.8 requires only that `malibu://`
be deleted per the list above. No new scheme is registered by
SPEC-026.

The follow-up implementation PR that lands §7.3 MUST leave the App
Xcode build/test gate green with no retired deep-link residue. A CI
grep scoped to App source, App tests, `phase3-binary/app/project.yml`,
generated project files, and `phase3-binary/app/README.md` MUST return
zero hits for `PendingLinkState`, `URLSchemeHandler`, `malibu://`,
`CFBundleURLSchemes: [malibu]`, or `.providerLinked`. SPEC and audit
files may mention the retired symbols as history.

### 7.4 Rename: "node" → "provider"

Grep and replace across the App-track sources. Notable strings:

- `MalibuAgent.swift:48` — "Not linked yet. Open Set up… and link your
  node." → "Not set up yet. Click Launch Provider to activate."
- `PendingLinkState.swift:60` — "This Mac is already linked to a
  node." (file deleted; no replacement needed)
- Any `MenuBarController` copy — "node status" → "provider status"
- Any `DashboardView` copy — same

### 7.5 Onboarding state persistence — legacy decode-only (reconciled v0.14)

**Reconciled v0.14 — production onboarding no longer writes this file.** The
`OnboardingState` struct still exists as a **decode-only legacy** shape (its
doc-comment says so, `OnboardingState.swift:3-5`; fields
`onboardingSchemaVersion` / `provider_id` / `created_at` / `last_stage` /
`first_serving_at` / `model_download`, pinned by
`OnboardingStateTests.testOnboardingStateUsesSnakeCaseAndFirstServingAt`), so an
older `onboarding.json` still parses — but the shipped flow does **not** write it and
does **not** use `onboardingSchemaVersion` as a live migration disambiguator.

Instead, install/onboarding state is derived from local evidence at startup
(`StartupState.detect().route()`, §7.6): the `.installed-by-app` marker,
`config.yaml`, the conditional provider-ID-bound CLI-custody marker, the redacted CLI
status contract, and the **launchd install evidence** (`install_manifest.json` /
`live.malibu.provider.plist`). There is no `v2` vs `v1` schema flag on the live
path.

The historical v2 JSON shape (retained for provenance):

```json
{ "onboardingSchemaVersion": 2, "provider_id": "p_abcd…",
  "created_at": "…", "last_stage": "…", "first_serving_at": null,
  "model_download": { "model_id": "…", "partial_bytes": 12345678 } }
```

File mode 0600. Never contains the private key or bearer token — those live in
Keychain.

### 7.6 `MalibuAgent.start()` — monitor gate with launchd evidence (reconciled v0.14)

**Reconciled v0.14 — the gate now has THREE conditions, and it drives a MONITOR, not a
spawn.** `MalibuAgent.start()` (`MalibuAgent.swift:64-87`) refuses unless, in order:

```swift
guard ProviderConfig.readProviderID() != nil else { … }              // :64-68
guard StartupState.launchdInstallEvidenceExists() else { … }          // :69-73
guard await ProviderConfig.isConfigured else { … }                    // :74-78
// → releases any legacy spawned child, then monitorInstalledProviderIfPresent()  :81-87
```

- `launchdInstallEvidenceExists()` is true iff `install_manifest.json` OR
  `live.malibu.provider.plist` is readable
  (`LaunchProviderController.swift:374-380`). When it is false the agent **refuses to
  poll** and shows "Click Launch Provider to run the installer" — a legacy app-marker
  config (config + marker but no launchd) routes to onboarding, not a reconnect loop
  (the PR #418 bugbot follow-up; `route()` at `LaunchProviderController.swift:352-372`,
  `StartupRouteTests.swift:9`).
- `ProviderConfig.isConfigured` = config present AND `.installed-by-app` marker AND
  provider ID; if an App-Keychain compatibility bearer exists, its provider-ID-bound
  `.cli-credential-custody-v1` marker is also required (`ProviderConfig.swift`). CLI
  runtime credential readiness remains the separate redacted status contract.
- `start()` then calls `monitorInstalledProviderIfPresent()` and **never instantiates
  `CLIChildProcess`** — the daemon is launchd-owned (§6.1, SPEC-025 §5).

**App-owned-but-unconfigured state** (`.installed-by-app` marker present but not yet
`isConfigured` — config identity or required custody evidence incomplete) never reaches monitoring; `StartupState.route()`
sends it to `.showOnboarding` to (re-)run `install.sh` (reconciled v0.15 — routing keys on
`ProviderConfig.isConfigured`, not the dormant App identity; `StartupRouteTests.swift`
`app-owned-missing-identity → .showOnboarding`).

The v0.1 receipt-key env-var handoff (`MACPROVIDER_RECEIPT_KEY_RAW`) remains removed.

## 8. Migration & feature flag — flag REMOVED, routing is disk-evidence-based (reconciled v0.14)

**Reconciled v0.14 — there is no onboarding feature flag in the shipped app.** PR #418
removed `MALIBU_ONBOARD_V2` (and the `onboardingFlow="v2"` user default); grep over
`Sources` + `Tests` finds neither. The CLI-wrapper onboarding is **always** the flow —
there is no v1-vs-v2 gate. Consequently the §8.1 State × flag matrix, the §8.2 rollback
behavior keyed on the flag, and **AC-026-09** (which asserted flag-gated behavior) **no
longer apply** and are retained below only as provenance.

**What replaced the flag matrix: `StartupState.detect().route()`**
(`LaunchProviderController.swift:302-372`, pinned by
`StartupRouteTests.testStartupRouteInstallStates`). **`detect()` is NOT pure
disk-state** (reconciled v0.14) — `ProviderConfig.isConfigured` conditionally checks
App compatibility/custody evidence, and detection probes the provider's HTTP health
(`:328-341`). **`route()` checks App-ownership FIRST**, so the
precedence is (evaluated top-down):

| Precedence | State | Route |
|---|---|---|
| 1 | `config.yaml` present but **no** `.installed-by-app` marker (CLI-owned) → **wins even when the launchd provider is healthy** | `.showImportDialog` (§8.4) |
| 2 | app-owned (marker present) but not yet `isConfigured` (config identity/custody evidence incomplete) | `.showOnboarding` (run `install.sh`) |
| 3 | App-owned + `isConfigured` AND launchd install evidence present (healthy or attachable) | `.startAgent` (monitor) |
| 4 | App-owned + `isConfigured` but **launchd install evidence missing** (e.g. the provider-service plist `live.malibu.provider.plist` / `install_manifest.json` removed — the app's gate checks these, NOT the watchdog) | `.showOnboarding` (re-run `install.sh`) |
| 5 | launchd install evidence present but **no config** | `.showOnboarding` |
| 6 | nothing configured | `.showOnboarding` |

Rows 4–5 (reconciled v0.17 to `LaunchProviderController.swift:352,366`,
`StartupRouteTests.swift:10,16`): a configured App-owned install whose launchd evidence
is gone, and launchd evidence without config, both fall back to onboarding to (re-)run
`install.sh`.

So a healthy launchd CLI-owned config still routes to the import dialog (App-ownership is
checked before health) — `StartupRouteTests.swift:8-17` pins `cli-owned` /
`launchd-cli-owned-* → .showImportDialog` and `app-owned-missing-identity →
.showOnboarding`. The import/migration dialog (§8.4) is reached by `.showImportDialog`.

---

**Historical (pre-#418) — the flag design, retained for provenance:** the SPEC-026 flow
shipped behind a single flag readable at App launch:

- Environment variable `MALIBU_ONBOARD_V2` (dev + CI)
- User default key `onboardingFlow` = `"v2"` (production Sparkle
  rollout)

**Precedence:** env var wins over user default when both are set.
Default off in the release that lands the code. Flip on via Sparkle
after the deploy checklist in §10 passes.

### 8.1 State × flag matrix

| Install state → | Flag OFF (current default)      | Flag ON (post-cutover)              |
|-----------------|----------------------------------|--------------------------------------|
| **Fresh** (no config, no identity, no onboarding.json) | Show a local setup-paused state: "Provider launch is not enabled in this build." Do not open browser OAuth, portal URLs, `malibu://`, or any URL-scheme handler. Persist nothing. Existing configured installs are unaffected. | Run SPEC-026 §6 flow. Persist as v2. |
| **CLI-owned config, no App marker** (`config.yaml` exists but `.installed-by-app` marker absent — `ProviderConfig.saveProviderIdentity` throws `existingConfigNotOwnedByApp` at `ProviderConfig.swift:69-72`) | Run the **import/migration dialog defined in §8.4 below**: user chooses "Import existing CLI provider" (adds marker file, becomes v1-complete) or "Start fresh" (moves aside CLI config, becomes Fresh). No SPEC-026 v2 flow attempts to write here. | Same import/migration dialog. If user picks "Start fresh," proceeds to v2 flow. If user picks "Import existing CLI provider," becomes v1-complete. |
| **v1-complete** (`ProviderConfig.isConfigured == true`, no v2 identity) | Live. No re-onboarding. | Live. Menu-bar affordance to migrate to a v2 identity is NOT surfaced in v0.3 (deferred to a follow-up spec that defines the migration invariants: old + new provider_ids coexist, no automatic ledger transfer, explicit wallet rebinding). |
| **v2-partial** (Keychain identity set, `onboardingSchemaVersion=2`, but `first_serving_at` is null/absent) | **Auto-present the onboarding window on next app foreground** with "Complete Malibu onboarding" as the primary action, regardless of flag. User can't miss it via menu-bar-only discovery. Alternative: uninstall via SPEC-025 §3.4. | Auto-present + resume v2 flow from last stage. |
| **v2-complete** (`ProviderConfig.isConfigured == true` AND `onboardingSchemaVersion=2` AND `first_serving_at` is set) | Live. Sparkle rollback to a flag-off build does NOT force re-onboarding — `MalibuAgent.start()` gate is `ProviderConfig.isConfigured` which stays true (§7.6). | Live. |

### 8.2 Rollback

If v2 ships with a bug and Sparkle flips the flag back to off:

- Fresh installs return to the local setup-paused state from §8.1; the
  retired SPEC-025 browser-OAuth/deep-link path is not restored by
  rollback.
- v2-complete installs continue running unchanged (per matrix cell
  above).
- v2-partial installs **auto-present the onboarding window on next
  app foreground** with "Complete Malibu onboarding" as the primary
  action (matching §8.1 matrix). No menu-bar-only discovery. No
  forced downgrade to browser OAuth (would require wiping Keychain
  identity, which is destructive of accrued unpaid ledger backlog).

### 8.3 Existing SPEC-025 §3.1 installs

> **Historical (pre-#418) — no flag ships (§8 head).** Read "flag is off" below as
> "the shipped unconditional CLI-wrapper flow"; live routing is the §8 precedence table.

Existing configured SPEC-025 §3.1 installs keep running when the flag
is off because `ProviderConfig.isConfigured` still drives
`MalibuAgent.start()`. Fresh flag-off installs do not run browser
OAuth; v0.12 retired that path along with `malibu://`.
`AC-026-09` verifies default-off/env precedence and absence of retired
URL-scheme invocation.

### 8.4 Import/migration dialog (CLI-owned config, no App marker)

> **LIVE (reconciled v0.17 — the historical §8.1/§8.2/§8.3 flag content above ends here).**
> This dialog is the shipped `.showImportDialog` route (§8 precedence table,
> `LaunchProviderController.swift:352`). The state labels it references (`v1-complete`,
> `Fresh`) remain valid descriptors of routing OUTCOMES; they do NOT reintroduce the
> retired v1/v2 flag matrix.

Triggered when `Malibu.app` starts and detects
`config.yaml` at the App-track path but no `.installed-by-app` marker
file (i.e. a CLI user is trying the App for the first time on a
Mac that has an existing CLI setup). Malibu never overwrites that ownership boundary
without the explicit import flow.

**Dialog layout (single sheet, presented at foreground):**

- Header: "Existing macprovider setup detected."
- Body: "We found a CLI-track macprovider config in this account.
  How do you want to proceed?"
- Option A (primary): **Import my existing provider** — crash-safe
  three-phase sequence matching SPEC-025 §7's import contract:
  1. Parse `provider_id` and any top-level `provider_token` from `config.yaml`.
  2. Write an App-support `.import_pending` marker containing the
     source path, destination Keychain slot, timestamp, provider_id,
     SHA-256 of the token, SHA-256 of the original config, and the
     import backup path.
  3. When YAML is tokenless but the exact provider ID still has a legacy App
     bearer, first restore that bearer to private live YAML as the launchd-readable
     rollback source, then continue as a bearer-bearing import. No production App path
     saves a bearer. A tokenless config proceeds only if the installed CLI verifies its
     own exact provider-bound item.
  4. Write one immutable 0600 snapshot of the original YAML. For a bearer-bearing
     snapshot, run the installed CLI's `credentials import --config <path>`, then run
     `credentials verify --config <same-snapshot>` as a second process. The
     second invocation MUST compare the exact value from the selected config against
     CLI-owned Keychain storage; for a tokenless snapshot it MUST instead prove a
     non-empty CLI-Keychain item for the exact provider ID. No bundled-binary fallback is allowed:
     the installed launchd executable is the process that must prove access.
  5. Revalidate that live `config.yaml` still has the original hash. Keep its
     `provider_token` intact; fresh-process Keychain proof is staging evidence, not
     launchd coordinator admission. A handoff failure preserves the original YAML and
     removes partial marker state. After successful CLI custody proof, delete and
     verify deletion of any legacy App bearer; deletion failure leaves the import
     retryable and does not claim completion.
  6. Write `.cli-credential-custody-v1` with the exact provider ID, then create the
     `.installed-by-app` marker file at
     `ProviderPaths.appMarkerFile` (per `ProviderPaths.swift:24`
     that path is
     `~/Library/Application Support/Malibu/.installed-by-app`).
  7. Except for the explicit legacy App-only repair in step 3, leave live CLI-owned
     YAML byte-for-byte unchanged. Verify `ProviderConfig.isConfigured == true` from
     provider ID plus the App-local ownership marker and, when an App bearer remains,
     the matching custody marker. The fixed import backup is the immutable CLI handoff
     snapshot. Confirm its deletion before deleting `.import_pending` and dismissing
     the dialog; cleanup failure retains the journal and fails the import. If verification fails,
     restore the prior App-Keychain value, delete any new app marker, preserve live
     YAML, and leave the import retriable.

  On startup, if `.import_pending` exists, the app locates the marker-bound
  hash-matching secret-bearing current config or backup. It restores that source to
  live YAML when necessary, removes the stale transaction artifacts, and returns to
  the import dialog; recovery never treats an unbound backup as authority.
  Tests MUST cover the exact tokenless-YAML/App-only incident repair, rejection without
  overwrite of a divergent App bearer, retry after an equal App bearer was saved before
  interruption, and backup-before-journal cleanup ordering.

  The install transitions to `v1-complete` state (§8.1). No
  re-onboarding required **provided launchd install evidence is also
  present** (reconciled v0.16): the import sets config plus ownership/custody markers after CLI custody proof,
  but `route()` still checks launchd evidence — an imported config whose
  launchd install is missing routes to `.showOnboarding` to (re-)run
  `install.sh` (`LaunchProviderController.swift:352`, §8 precedence
  table).
- Option B: **Start fresh with a new provider** — moves the
  existing `config.yaml` file to
  `~/.config/macprovider/config.yaml.cli-backup-<UTC-timestamp>`
  and proceeds to Fresh state (§8.1). The user is warned that
  earnings on the CLI-track provider_id continue to accrue but
  are no longer accessible via `Malibu.app`; they can be
  reclaimed via
  `macprovider-cli --config <backup-file-path>` which
  supports pointing at an arbitrary config file. The dialog
  displays the exact reclaim command for copy.
- Option C (secondary link): **Cancel** — closes the dialog and
  quits the App. No files are touched.

The dialog is modal; the App does not proceed to the launch
screen until a choice is made. AC-026-15 covers each of the
three outcomes.

## 9. Recovery, reinstall, wallet swap

### 9.1 Fresh reinstall / Mac wipe

Fresh reinstall re-runs `install.sh` and re-acquires a `provider_token`
via `bootstrap-auth` (reconciled v0.15 — the shipped provider identity is
the CLI-track `mp-*` principal, NOT the dormant App-track `p_*` Ed25519
identity; §2, §4.1). **A new `mp-<32hex>` principal is generated ONLY on a
clean wipe (reconciled v0.16):** `choose_provider_id` reuses a saved
`$PROVIDER_ID_PATH` or an existing `config.yaml` provider_id first and
generates a fresh `mp-*` only when neither survives (`install.sh:2484-2506`).
So an ordinary App reinstall that leaves the CLI config/ID in place keeps
the same principal + provisional standing; a full Mac wipe (Keychain +
config gone) yields a new principal → fresh provisional tier. Prior unpaid
earnings are lost UNLESS a
payout wallet was bound before the wipe. If bound, earnings settle to
that wallet on the SPEC-016 next payout batch cycle regardless of the
Mac's presence — the SPEC-016 pipeline is coordinator-owned and does
not require the Mac to be online.

**Accounting language:** earnings not yet swept to a bound wallet
accumulate as SPEC-016 `ledger_payout_ready` rows against the
`provider_id`. SPEC-026 does not introduce a new per-provider
custodial escrow ledger; it plugs App-track providers into the
existing SPEC-005 / SPEC-016 accounting rails. The `earnings`
response field is `unpaid_ledger_backlog_usdc` (not
`accrued_escrow_usdc`).

**Loss on wipe is a feature, not a bug.** No seed phrase means no
seed phrase to lose. The "back up your identity" step every crypto
app has is replaced by "bind a wallet as soon as you're comfortable."
That is the recovery path.

### 9.2 Multi-Mac, same wallet

Each Mac has its own `provider_id`. **Wallet binding is SPEC-027-gated
and not available in the shipped build** (reconciled v0.16 —
`501 wallet_change_requires_spec_027`, §4.2); the DESIGNED model is that
all Macs can bind to the same payout wallet via SPEC-016 §3, and
SPEC-016's payout runner sums per-wallet `ledger_payout_ready` rows at
batch time. That composition activates once SPEC-027 defines the
non-bearer proof.

Note: the §5.1 per-wallet emission cap (100 MALIBU / bound wallet /
day, across all `provider_id`s) means a large multi-Mac operator is
throttled at the wallet level, not the provider_id level. This is
intentional against wallet-sharing sybil variants.

### 9.3 Wallet swap

Wallet swap for App-track providers is **SPEC-027-gated and NOT
available in the shipped build** (reconciled v0.16 — coordinator returns
`501 wallet_change_requires_spec_027`, §4.2). The SPEC-016 §3 EIP-712
swap flow (proof-of-possession + cooling window + hot-wallet reconfirm)
is the *designed* post-SPEC-027 mechanism, not an active one.

**App-track additions deferred to SPEC-027.** v0.6 defined an
out-of-band coordinator-authored email cancellation channel with
a three-path channel-authority transfer, HMAC-signed cancel URL,
GET-confirmation + POST-mutation split, EIP-712
`EmailChangeAuthorization` domain, and fresh-install
re-ratification at first wallet bind. v0.7 moves that entire
surface to SPEC-027 (App-track wallet-swap coercion defense),
along with the related SPEC-016 §3 addendum for
`provider_wallet_swaps` state machine and the `cancelled_by_email`
transition. See §4.5 for the full moved-out list.

**Until SPEC-027 lands:**

- App-track wallet binding/swap is **blocked with `501`** (§4.2); there
  is no interim EIP-712 swap path (the SPEC-016 §3 mechanism activates
  only once SPEC-027 defines the required non-bearer proof).
- **Before SPEC-027 ships, `Malibu.app` MAY show only a
  read-only pending-swap row and MUST NOT add a Cancel
  affordance or cancellation action.** Identical rule as §6.2.
  The coordinator-side cancel endpoint lives in SPEC-027 +
  the SPEC-016 §3 addendum.
- Operators should treat wallet-swap coercion as an accepted
  App-track risk between SPEC-026 merge and SPEC-027 merge.
- Support MUST NOT override payout binding.

### 9.4 Lost payout wallet, no swap possible

Out of scope for v0.2. Support-ticket path only. A future spec may
introduce a challenge-response recovery for the case where the user
still has provider identity but has lost the wallet keys.

## 10. Backend deploy checklist (ordered gate for the coordinator §4 backend rollout)

> **Reconciled v0.15/v0.20/v0.21.** This is the coordinator-**backend** deploy checklist
> for the §4 surface. It gates when the coordinator may serve three things: §4.1
> `/v1/providers/register`, §5.3 App Attest, and §4.3 `identity_signature` verification
> (step 7). The important distinction is **client** exercise, not whether a step exists:
> **§4.1 register + §5.3 App Attest are CLIENT-DORMANT** (deployed as contracts; no shipped
> client drives them — §4 banner), while **§4.3 `identity_signature` verification is now
> LIVE** and gates CLI-track `mp-*` admission (step 7 has been deployed —
> `identity_signature.go:127`, `server.go:1216`). "App-side flag flip" throughout this
> section means **shipping the CLI-wrapper Sparkle release** (step 9) — PR #418 removed the
> `onboardingFlow` user default, so there is no runtime flag to flip (§8). These steps gate
> the coordinator BACKEND rollout; they do NOT gate the shipped onboarding FLOW itself,
> which uses `bootstrap-auth` / WS admission — a flow that nonetheless DEPENDS on the
> now-live §4.3 verification (step 7).

The list is a strict ordering; each step MUST pass before the next
runs.

1. **SPEC-026 v0.9 schema migrations deployed** on staging AND
   production coordinator, split into two phases:

   **Phase 1a — schema-only (no row seeding), deploys with the
   coordinator release that ships §4.1 `/register` and §4.3
   proof-stage auth verify:**
   - `provider_identities` table: `identity_pubkey BYTEA NOT NULL`,
     `attested BOOLEAN DEFAULT FALSE`, `app_attest_key_id BYTEA
     NULL UNIQUE`, `first_seen_ts TIMESTAMPTZ NOT NULL`.
   - `provider_auth_policy` table per §4.3 — created empty; no
     row seeding at this phase.
   - `provider_auth_policy_pending` table per §4.3 for the
     dual-approval workflow (includes the `CHECK (approved_by IS
     NULL OR approved_by <> requested_by)` constraint).
   - Rollback script tested for each migration.

   Schema for SPEC-027 (verified-email + wallet-swap coercion)
   and SPEC-021 (MALIBU rewards emission ledger) is out of scope
   for this checklist; those specs own their own deploy gates.

   **Phase 1b — row seeding, deploys ONLY at auth-verifier
   cutover time (the moment the auth-verifier code is deployed
   and serving):** one-time migration populates
   `provider_auth_policy.signature_exempt_until = CUTOVER_TIME
   + 7 days` for every existing provider_id (both App-track `p_`
   and CLI-track opaque). `CUTOVER_TIME` is captured server-side
   at migration execution time. This split ensures the 7-day
   grace clock anchors from cutover, not from the earlier
   schema migration.
2. **`POST /v1/providers/register` deployed to staging.** Verified:
   Ed25519 signature verify, JCS parity with the App-local Swift
   canonicalizer via a `spec026_register.json` fixture that both Swift
   and Go tests load,
   per-IP + per-ASN rate-limit behavior, `(provider_id, nonce)`
   replay-cache rejection over 65s.
3. **App Attest verification implemented** with the SPEC-026 §5.3
   `clientDataHash` binding and `app_attest_key_id` cross-provider
   reuse rejection. Fallback to `trust.attested = false` on
   Apple-service outage verified by fault-injection test.
4. **SPEC-016 §3 EIP-712 payout-wallet-binding path — DEFERRED to
   SPEC-027 (reconciled v0.16).** This gate is **moot for the current
   release**: the shipped App-track wallet-binding endpoint returns
   `501 wallet_change_requires_spec_027` (§4.2, `main.go:1284`), so there
   is no live App-track EIP-712 binding to verify E2E. The
   deployed-and-operating-in-production requirement (Ed25519 bearer auth
   + EIP-712 proof-of-possession composition) becomes a **SPEC-027
   release gate**, not a SPEC-026 one. The shipped CLI-wrapper onboarding
   does not bind wallets.
5. **FR-C9 self-mint TOFU regression check** via the new register
   endpoint (existing CLI-track providers still mint tokens
   correctly).
6. **Rate limits observable** via `/admin/metrics`:
   `provider_register_rate_limit_hits{scope="ip"}`,
   `..{scope="asn"}`, and
   `provider_register_source{track="app"|"cli"|"portal"}`.
7. **SPEC-001 v1.6 §6.7 v2 proof-stage `identity_signature`
   verification** deployed. The moment this code goes live IS the
   `CUTOVER_TIME` referenced in step 1 Phase 1b: the one-time
   seeding job runs immediately, populating
   `provider_auth_policy.signature_exempt_until = CUTOVER_TIME + 7
   days` for every pre-cutover provider_id (both `p_`-prefixed and
   CLI-track opaque). After the 7-day window closes, all
   provider_ids without an operator-issued exemption (§4.3 admin
   flow) MUST supply a valid signature or the coordinator MUST WS
   close with `4003 identity_signature_required`. Client-declared
   `binary_version` is not consulted for auth policy — the
   server-side `provider_auth_policy` allowlist is authoritative.
8. **MALIBU emission stance decided.** The App-side flag flip MUST
   NOT enable **withdrawable** MALIBU emissions until EITHER:
   - **SPEC-021 (MALIBU rewards emission ledger) has shipped to
     production**, providing enforceable `withdrawal_hold_reason`
     + per-wallet cap semantics, OR
   - **The operator has configured an equivalent hold mode** that
     prevents any MALIBU withdrawal until the provider unlocks
     Trusted per §5.2. The hold-mode configuration is
     coordinator-side and documented separately from SPEC-026;
     the mere existence of §5.1 sybil-defense prose is NOT
     sufficient by itself.

   Non-withdrawable MALIBU emission (accrual only, with all rows
   held) is acceptable before either condition; withdrawable flow
   is not. Providers displayed a "Provisional — earn up to 25
   MALIBU/day (non-withdrawable until Trusted)" tier chip per §6
   are still consistent under either operational stance.
9. **`Malibu.app` Sparkle release** shipping the CLI-wrapper onboarding.
   (Reconciled v0.14: there is no `onboardingFlow` user default to flip —
   PR #418 removed the flag, §8. The CLI-wrapper onboarding is
   unconditional; "flag flip" here means simply shipping the release.)

This checklist gates the coordinator-**backend** rollout of §4.1 register +
§5.3 App Attest (client-dormant contracts) AND §4.3 `identity_signature`
verification (step 7 — now **LIVE**, gating CLI-track `mp-*` admission via
`identity_signature.go:127`, `server.go:1216`; the shipped onboarding DOES
depend on it, via the CLI's bootstrap-identity signing). The checklist does
NOT gate the onboarding FLOW itself, which already ships and runs
unconditionally at startup (`MalibuApp.swift:115`, §8) using
`bootstrap-auth` / WS admission — **no §4.1-register / §5.3-App-Attest dependency**,
though it DOES depend on the live §4.3 `identity_signature` auth-policy (above).
(Reconciled v0.16/v0.20: the "App-side ships only after every step" framing applied to
the pre-#418 in-app register→spawn client that these steps gated; that client is dormant,
§4.1.)

## 11. Biggest risk and mitigation

**Sybil farming for $MALIBU emissions.** Dropping the GitHub-gated
identity removes one abuse layer. Attacker economics with v0.2
tightening:

- **v0.1 economics (broken):** N identities × 25 MALIBU/day × 7 days
  = 175 MALIBU per identity, withdrawable at day-7 unlock.
- **v0.3 economics:** Provisional 25 MALIBU/day is
  **non-withdrawable** until Trusted unlock (§5.2). Two Trust unlock
  criteria are required, and the wallet-balance criterion requires
  ≥100 USDC held continuously for 72h with randomized dual-RPC
  checks (§5.2 #3). Attacker needs to either operate honest hardware
  for 72h + ship 100 SPEC-022-verified receipts (real work
  compensated by real USDC, so the attack degrades to "operate
  honestly for a week and take the USDC"), OR fund the 100 USDC
  continuously for 72h per identity (opportunity cost + gas floor).
- Attacker break-even inequality:
  `emissions_per_identity_after_unlock * $MALIBU_price ≥ cost_per_identity`
  where `cost_per_identity ≥ (72h × 100 USDC opportunity cost)
  + (72h × honest inference infrastructure cost) + gas`. This is
  the spec's stated bound.
- Per-wallet emission cap (§5.1) further compresses the attacker's
  yield when they reuse one bound wallet across many `provider_id`s.

**Note on App Attest economics.** v0.2 §11 characterized App Attest
as a per-device economic sybil cost (via paid Apple Developer
certificate at $99/year). This is wrong: `DCAppAttestService.generateKey`
produces arbitrarily many attestation keys per device without
per-key cost, so a single legitimate Apple Developer entity on a
single physical Mac can mint many attested identities. The
`app_attest_key_id` uniqueness constraint (§5.3) prevents replay of
one attestation across many identities, but does not prevent
generating many distinct attestations. **v0.3 reframes App Attest
as bundle-integrity + anti-replay evidence, not economic sybil
resistance.** It contributes to Trust unlock (§5.2 criterion #4)
because a valid attestation proves the request came from a signed
Malibu binary running on real Apple hardware, not because it caps
the sybil identity count.

**On E3 (operator promotion).** The §5.2 economic-criterion
alternatives E1 (verified receipts) and E2 (100 USDC held for
72h) are the automated sybil-economics bound. E3 (manual operator
promotion) is a **human-audited exception path**, not part of the
automated defense stack. E3 grants require: written reason
recorded on the promotion row, evidence class (e.g. "known
enterprise operator", "in-person KYC", "on-chain payment
history"), and dual-control approval by two operators. E3 is not
a self-serve criterion and must not be relied on for the
automated economics argument. If E3 grants become common, revisit
the design.

**Prerequisite for this stack to hold.** The non-withdrawable
provisional $MALIBU + per-wallet cap layers are ENFORCEABLE only
once SPEC-021 (MALIBU rewards emission ledger) has shipped OR the
operator has stood up an equivalent hold mode per §10 step 8.
Between SPEC-026 merge and either of those milestones, the
"non-withdrawable" invariant is prose-only and MUST NOT be relied
on as a live control. **Shipping the CLI-wrapper release** (reconciled
v0.17 — there is no runtime "flag flip", §8/§10) is gated on
withdrawable MALIBU being blocked until then (§10 step 8).

Mitigation stack, in effectiveness order (each layer assumes the
prerequisite above holds):

1. **Non-withdrawable provisional $MALIBU** — attacker sees no cash
   at all until Trusted criteria unlock. Fundamental cost floor.
2. **Verified-receipt-only earnings (SPEC-022)** — fake or synthesized
   work earns nothing. The load-bearing anti-abuse layer.
3. **Continuous ≥100 USDC time-weighted balance criterion + dual-RPC
   verify (§5.2 #3)** — locks capital per identity for the full
   unlock window with randomized-jitter checks.
4. **Per-wallet emission cap + demotion path (§5.1, §5.5)** —
   wallet-sharing sybil variants throttled at the wallet level;
   "deposit, unlock, withdraw" recycling triggers demotion.
5. **App Attest bundle-integrity evidence (§5.3)** — not an economic
   cost layer, but proves the request came from a real signed
   binary and contributes to Trust unlock.
6. **Behavioral risk score (§5.6, future)** — outlier providers get
   settlement release deferred beyond the 7-day floor.

Residual risk after this stack: acceptable given the buyer
marketplace already imposes an economic ceiling on how much $MALIBU a
fake provider can extract before settlement stops matching. Revisit
when field data shows a specific attack.

**Second-biggest risk: App Attest dependency.** Apple's attestation
service is an external dependency. If it goes down globally, honest
providers can still register (attestation is opportunistic, not
required), but they lose the trust-tier bump. Mitigation: log
`app_attest_service_error_rate` and alert on sustained > 5% error
rate; during outage, temporarily loosen the alternative unlock
criteria in §5.2 by 25%.

## 12. Acceptance criteria

- **AC-026-01.** Fresh install on a Mac with no prior Malibu state
  completes onboarding to `.live` in ≤ 3 minutes on a residential
  100 Mbps connection, with the model download counted.
- **AC-026-02 (reconciled v0.15).** No user-visible string in the App's
  OWN chrome (window headers, buttons, success card) during the
  fresh-install flow contains "node", "malibu.tech", "portal", or
  "sign in". **Exception:** the transient progress line scraped from
  `install.sh` may surface "Downloading provider release from GitHub…"
  (`CLIInstallRunner.swift:124`), and the onboarding body references the
  "macprovider CLI" (`OnboardingWindow.swift:43`) — these are the
  managed-CLI installer's own output, not Malibu-authored marketing
  copy. The no-"node"/no-"portal"/no-"sign in" brand rule still holds
  for App-authored strings.
- **AC-026-03.** No browser tab, external app, or URL scheme handler
  is invoked during a successful fresh install.
- **AC-026-04 — SUPERSEDED (reconciled v0.14).** It referenced a
  `.downloadingModel` stage + in-app resumable model download that no longer exist —
  the shipped stage machine is `.idle/.runningCLIInstall/.startingAgent/
  .importingProviderIdentity/.live/.failed` and `install.sh` (CLI track) owns the model
  download (§6.1, §7.2). No in-app byte-offset-resume criterion applies.
- **AC-026-05.** A second `POST /v1/providers/register` with the same
  `provider_id` but a different `identity_pubkey` returns `409
  CONFLICT` and does not overwrite the row.
- **AC-026-06 (reconciled v0.16 — SPEC-027-gated).** App-track wallet
  binding/swap is NOT available in the shipped build: every App-track
  wallet POST returns `501 wallet_change_requires_spec_027`
  (`main.go:1284`) and `setPayoutWallet` throws
  (`LaunchProviderController.swift:94`). The designed SPEC-016 §3
  cooling-window swap semantics AND all App-track out-of-band
  cancellation semantics (verified email, signed cancel URL, delivery
  retries, `UNUserNotification` policy, deep links) are **SPEC-027
  acceptance criteria, not SPEC-026** — there is no live wallet-swap
  behavior for SPEC-026 to accept.
- **AC-026-07.** A settled receipt from an App-track provider passes
  the CLI-track's `macprovider-verify` command with no code change
  to `macprovider-verify`. Receipt-key semantics are unchanged from
  SPEC-015; the identity-key separation in §3.2 does not affect
  receipt verification.
- **AC-026-08 — SUPERSEDED (reconciled v0.14).** It asserted that deleting
  `provider_identity_v1` forces a fresh `provider_id` — **false** in the shipped app.
  `ProviderIdentity` is dormant (§3): the onboarding gate is `ProviderConfig.isConfigured`
  (config + marker + provider ID, plus the conditional custody marker above), not
  `ProviderIdentity.isReady`, so deleting
  the App identity key does not re-onboard. The shipped provider_id is the CLI-track
  `mp-*` (from `install.sh`). A fresh onboarding is forced by removing the app marker or
  config, not the dormant App identity key; launchd status separately reports missing
  CLI credential custody.
- **AC-026-09 — SUPERSEDED (reconciled v0.14).** This criterion asserted
  `MALIBU_ONBOARD_V2=0` / `onboardingFlow` flag behavior, which PR #418 **removed**
  (§8): there is no onboarding flag and no setup-paused state. The still-valid *residual*
  invariant — **no browser tab, portal URL, `malibu://` scheme, URL-scheme handler, or
  `PendingLinkState` path is ever invoked** — is retained and enforced by the §7.3 CI
  grep (zero hits for `PendingLinkState` / `URLSchemeHandler` / `malibu://` /
  `CFBundleURLSchemes` in App sources). The routing that replaced the flag is verified by
  `StartupRouteTests.testStartupRouteInstallStates` (§8).
- **AC-026-10.** Uninstall wipes the `provider_identity_v1` Keychain
  item and all onboarding artifacts under
  `Application Support/Malibu/`, but does NOT wipe the SPEC-015
  receipt-key Keychain slot.
- **AC-026-11.** Replaying one legitimate `app_attest_object`
  captured from provider A across a `/register` call with provider
  B's Ed25519 identity is rejected: (a) the `clientDataHash` binding
  fails because the register nonce differs, AND (b) the
  `app_attest_key_id` collides with provider A's row and returns
  `409`.
- **AC-026-12.** For any provider_id (App-track `p_`-prefixed OR
  new CLI-track opaque, both flavors covered) that reaches the
  SPEC-001 v1.6 §6.7 proof-stage frame:
  - If the coordinator's `provider_auth_policy` row is absent for
    that `provider_id`, OR the row's `signature_exempt_until IS
    NULL`, OR `NOW() > signature_exempt_until`, then a
    proof-stage frame WITHOUT a valid `identity_signature` is
    rejected with WS close code `4003 identity_signature_required`.
  - If the row exists with `signature_exempt_until IN THE FUTURE`,
    the coordinator accepts bearer-only for that session and
    logs `provider_auth_policy_exempt_used`.
  - A client that self-reports `binary_version < 1.9.0` in the
    initial-stage frame does NOT bypass the requirement — the
    server-side allowlist is authoritative.
  - For App-track `p_` provider_ids, the signature is verified
    against `provider_identities.identity_pubkey`. For CLI-track
    `mp-*` provider_ids the verify key is principal-branched
    (reconciled v0.16): a durable bootstrap principal → the stable
    current CLI admission-identity generation; a legacy principal with no durable row →
    the stored SPEC-015 receipt key. See §4.3's CLI-track hardening
    path (`identity_signature.go:118-159`).
- **AC-026-13.** JCS parity between the App-local Swift canonicalizer
  and Go `billing.CanonicalJSON` is verified by a shared fixture at
  `phase4-coordinator/test/jcs_fixtures/spec026_register.json`;
  identical `/register` bodies canonicalize byte-for-byte identically
  in both languages.
- **AC-026-13a.** Provider ID base32 parity is verified by a separate
  lowercase/no-padding vector set covering empty, 1-byte, 2-byte,
  multi-byte, and 32-byte digest inputs. The register JCS fixture is
  not used as a substitute for base32 coverage.
- **AC-026-14.** A Trusted provider whose only remaining unlock
  criterion is wallet-balance-≥-100-USDC and whose wallet drops
  below 100 USDC is demoted to Provisional on the next payout batch
  cycle. Any Provisional-tier restrictions (payout delay, emission
  cap, non-withdrawable) reinstate; existing settled receipts are
  not clawed back. **Note:** enforcement of "non-withdrawable"
  and "emission cap" is deferred to SPEC-021; this AC verifies the
  status-transition side, not the ledger-hold enforcement.
- **AC-026-15.** §8.4 import/migration dialog with a CLI-owned
  config present but no App marker: the dialog presents "Import
  existing CLI provider" / "Start fresh with a new provider" /
  "Cancel". Each outcome is verified end-to-end:
  - **Import:** parses `provider_id` plus any `provider_token` from the existing YAML,
    imports an existing bearer absent-or-equal into CLI Keychain, and proves custody in
    a distinct installed-CLI process. Tokenless input is normally verify-only; the
    exact legacy App-only incident state first restores its matching bearer to private
    YAML. It retains live YAML, creates `.installed-by-app` plus the provider-ID-bound
    custody marker, and verifies `ProviderConfig.isConfigured == true`. Rollback on any
    intermediate failure preserves the original config, and the secret snapshot is
    confirmed absent before its journal is retired.
  - **Start fresh:** moves `config.yaml` to
    `~/.config/macprovider/config.yaml.cli-backup-<UTC-timestamp>`,
    proceeds to Fresh state, and displays the exact
    `macprovider-cli --config <backup-file>` reclaim command.
  - **Cancel:** closes the dialog and quits the App with no file
    changes.
- **AC-026-16.** §4.1 duplicate-register bearer-proof mechanic
  covers the following scenarios against an active `provider_tokens`
  row (`revoked_at IS NULL`) for the same `identity_pubkey`. **Both an
  in-use row (`last_used_at IS NOT NULL`) AND a never-handshaked row
  (`last_used_at IS NULL`) MUST be exercised (reconciled v0.16 — proof
  is required for ANY active row; there is no never-handshaked bypass,
  `tokens.go:945-975`):**
  - No `Authorization: Bearer` header → coordinator returns
    `409 existing_active_token_no_proof` and does NOT touch the
    existing token row. The App-track request body never carries
    `current_provider_token`.
  - Wrong bearer (arbitrary 32-byte cleartext that doesn't
    match `token_hash`) → same `409` response, same no-mutation
    behavior.
  - Correct bearer (SHA-256 of the provided cleartext matches
    the row's `token_hash`) AND cooldown-clock permits →
    coordinator revokes the prior row (`revoked_at = NOW()`)
    and mints a fresh token; response carries the new bearer.

## 13. Open questions

- Dormant App-derived `p_*` identity algorithm migration (for example Ed25519 → Ed448)
  remains open because it changes the provider-ID anchor. It is distinct from the shipped
  CLI admission-key generation rotation/recovery in §4.3, which preserves provider ID,
  tokens, payouts, billing ownership, and history.
- Should the App Attest attestation object be re-attested
  periodically (e.g. weekly) or only at `/register`? Only-at-register
  is cheaper and matches Apple's documented pattern.
- Trust-tier unlock timing: is 72h uptime + 100 verified receipts
  too strict for honest solo providers? Revisit after two weeks of
  field data.
- Whether to expose the "Trusted" trust chip to buyers before we
  have a material sample of attested providers. Landing this in a
  separate spec.
- Should we ship a "recovery bundle" export (private key wrapped by
  a user-chosen passphrase) to give power users a self-hosted seed
  backup? Explicit non-goal here; open for a follow-up spec.
