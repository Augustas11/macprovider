# SPEC-003 — Open Onboarding: Distribution, Lifecycle & Onboarding UX

**Version:** 0.10.1 (2026-06-26, FR-C9.4 executable runbook gate — `coordinator-cli pre-flip-audit` shipped as the normative gate)
**Depends on:** SPEC-001 v1.5, SPEC-002 v1.3.5

**Change log v0.10.1:** Additive patch on v0.10 (no wire-shape changes). Closes issue #82 item 3. The FR-C9.4 flag-flip runbook (text added under v0.8.4) referenced a tracking issue for the `coordinator-cli pre-flip-audit --max-last-used-age=24h` command; the command is now shipped and normatively required. Updates the runbook prose to point at the shipped command rather than a tracking issue. No primitive added; no wire field changed.

**Change log v0.10:** Adds **FR-C10**, the coordinator-side emission policy for SPEC-001 v1.5's `pair_ot` / `claim_url` and ownership-status wire surfaces. The amendment exists because the downstream SPEC-014 v0.2 GitHub-auth design identified a protocol-owner split: SPEC-001 owns the field and frame shape, SPEC-003 owns the open-onboarding coordinator mint policy, and SPEC-014 consumes both through its portal and bind flows. The SPEC-014 round-1 A.1 audit found that putting this policy in the GitHub-auth spec would cross the spec boundary, so FR-C10 is written as the sibling of FR-C9's existing `assigned_provider_token` mint contract rather than as a downstream-only implementation note. L-1 baseline preservation is explicit: deployments with `GITHUB_OAUTH_ENABLED=false` or unset MUST NOT emit `pair_ot`, `claim_url`, `ownership_event`, or `needs_claim`; the additive SPEC-001 v1.5 wire fields exist but remain absent on the wire unless the deployment opts into the new surfaces. FR-C10 keeps FR-C9 unchanged and piggybacks only on the same admission that minted a fresh `assigned_provider_token`. Dual-path delivery follows FR-C9's v1/v2 discipline: if the gate passes, the coordinator fills the optional fields defined by SPEC-001 v1.5 §6.5.1 for v1 `hello_ack` or §6.7.2.1 for proof-stage-accepted v2 `auth_response`. Ownership change and migration hints use SPEC-001 v1.5 §6.12 (`ownership_event` / `ownership_status`) and §6.5.2 (`needs_claim`) without redefining those wire shapes.

**Change log v0.9.2:** Merge-time composition of two independent SPEC-003 lines that landed concurrently. v0.9.1 (PR #67 main) shipped installer-side hardenings to FR-D2.1. v0.8.4 (PR #69 branch, see below) shipped the composed FR-C9.4 contract + fix-pass-5 audit closure. v0.9.2 is the union: the v0.9.1 FR-D2.1 changes are unchanged (no FR-C9 overlap), and the v0.8.4 FR-C9.4 contract is normative as written. The composed v0.9.2 contract adds three storage/pool primitives from fix-pass-5: `auth.Store.ValidateAndMarkTokenUsed` (atomic UPDATE-RETURNING closing the ValidateToken+MarkTokenUsed TOCTOU window), `pool.AuthMintFailed` enum (transient IssueToken DB-error → fail-closed RejectTOFU), and extended `pool.Registry.Register` eviction defense (non-Bearer-validated incoming MUST NOT replace existing routable Bearer-validated session). DECISION_CRITERIA Entry 76 captures the composition reasoning; Entries 74 (was 69, was 67), 75 (was 70, was 68) trace the renumber history through two merge cycles. Pearl operational state unchanged.

**Change log v0.9.1:** Two installer-side R2/R3 hardenings surfaced by the parallel codex audits on PR #67. **(a) FR-D2.1 step 1 (format validation)** now MUST reject path components equal to `.` or `..` (split on `/`, reject either segment) in addition to the existing charset and shape checks. Prior wording said "no traversal/whitespace" in prose but the implementation relied on the charset filter alone, which permitted `org/..` and `../name`. **(b) FR-D2.1 step 4 (weight estimation)** now MUST match a Mixture-of-Experts `[0-9]+x[0-9]+(\.[0-9]+)?B` shape BEFORE the single `[0-9]+(\.[0-9]+)?B` shape. Otherwise an id like `Mixtral-8x7B-Instruct-4bit` is read as 7B and the fit check accepts a 56B model that would OOM the host. Headroom constants, quant table, and tier thresholds are unchanged.

**Change log v0.9:** Extends FR-D2 with a fourth interactive option `c) custom HuggingFace MLX model id` so providers are no longer locked to the three RAM-tier defaults. The `c)` branch reads a free-form `org/name`, validates format (path-component charset, single slash, no traversal/whitespace/newlines), then queries `https://huggingface.co/api/models/<id>` to enforce two hard blocks and one soft check: (i) HTTP 401/403/404 → die with a single "not accessible" message (HF does not disclose existence to unauth'd callers, so these are indistinguishable from outside); (ii) repos that neither sit under `mlx-community/*` nor declare `library_name:"mlx"` / `"mlx"` in `tags` → die with "not an MLX repo"; (iii) RAM fit — weights estimated from the `[0-9]+(\.[0-9]+)?B` suffix and a `(4bit|8bit|bf16|fp16|q4|q8)` quant hint, then compared to detected RAM with a 6 GB headroom for the "comfortable" tier and a 2 GB headroom for the "tight" tier (matches the existing RAM-tier defaults where 7B targets 16 GB, not 8 GB). Tight/over-RAM cases warn-and-prompt; user may override. New env var `MACPROVIDER_SKIP_HF_CHECK=1` bypasses (i)/(ii)/(iii) for offline or self-mirrored installs. `MACPROVIDER_MODEL=` env override continues to skip the interactive prompts entirely (CI/`NO_PROMPT` path) but now also runs the format validator so a malformed env value fails fast. Coordinator/gateway are unaffected — no protocol change.

**Change log v0.6:** Resolves cross-spec findings F-603-1 and F-603-2 from `specs/SPEC-CROSS-006-audit.md`: the installer visibility self-test now references SPEC-002 v1.1.4's coordinator-owned `GET /v1/pool/check`, and dependencies align to SPEC-001 v1.2.2 + SPEC-002 v1.1.4.

**Change log v0.7:** Resolves six v1.2.4 partner-upgrade follow-ups from Decision log Entry 22, building on the Entry 20 install.sh bug class: F-603-V7-1 existing config port detection, F-603-V7-2 own-service port holder stop, F-603-V7-4 real binary path in launchd plist for Swift Bundle resolution, F-603-V7-5 cold-cache 20-minute wait, F-603-V7-6 diagnostic self-test timeout messaging, and F-603-V7-7 mixed-state install-dir warning. F-603-V7-3 and F-603-V7-8 were retracted and are not part of v0.7.

**Change log v0.8:** Closes Open Q2 from Decision log Entry 59 (provider-token issuance model for open onboarding). v0.8 picks self-serve provisional token minting and adds the normative contract under § 4 as **FR-C9**. The coordinator MINTs a fresh `provider_token` on every tokenless provisional admission and returns it in both the v1 `hello_ack` and v2 `auth_response` (initial-stage acceptance) frames under a new OPTIONAL field `assigned_provider_token`. The phase3-binary MUST persist the returned token to its on-disk config under the existing top-level `provider_token` YAML key with file mode 0600 via atomic-rename. Pinned-tier token issuance (Entry 59 / M1-1) is unchanged — operator-issued via `coordinator-cli issue-token`. Dependencies bump to SPEC-001 v1.3.1 (M1-1 Bearer-on-WS-connect plumbing) and SPEC-002 v1.3.5 (locked, no coordinator-side schema change required). See Decision log Entry 60 for the full ruling and the rationale for dual-path delivery (the binary's default first frame is v1 `hello`, not v2 `auth_request`, so the v1 `hello_ack` path is the primary delivery channel for the actual target population — provisional strangers).

**Change log v0.8.4:** Composition of two parallel v0.8.3 drafts (PR #69 fix-pass-3/4 + PR #78), reconciled at merge time. v0.8.3 attempted to solve the same deploy-gap lockout class via two different mechanisms — PR #78 chose self-heal-on-NULL (PR #78 merged first, became canonical on `main`); PR #69 chose admit-tokenless-with-quarantine-marker plus an AuthState eligibility primitive and pool-registry eviction defense. v0.8.4 composes them: the FR-C9.4 wire contract becomes the table below, the eligibility primitive (`pool.AuthState`) ships as the single authority for buyer routing + billing exclusion, and the pool-registry eviction defense ships as defense-in-depth for the race-loss case. The result: deploy-gap NULL-row → self-heal (PR #78); USED-row credential-capture vector → strict reject (PR #78); IssueToken race-loss after self-heal passed → admit-bearer-less-quarantined (PR #69). Storage-layer primitives carried in: `auth.Store.RevokeUnusedTokenForProvider` (PR #78) + `auth.Store.IssueToken` ErrActiveTokenAlreadyExists sentinel (v0.8.2) + partial unique index `idx_provider_tokens_one_active_per_provider` (v0.8.2). Pool-layer primitives carried in: `pool.AuthState` enum (`AuthBearerValidated` / `AuthSelfMinted` / `AuthBearerlessDuplicate`), `pool.Provider.RoutingEligible()` excluding bearer-less duplicates, `pool.Registry.Register(p, conn) (oldConn, registered bool)` refusing eviction by an incoming bearer-less duplicate of an existing routable session. Buyer-side: routing/capacity sites delegate to `RoutingEligible()` as the single authority. The `RoutingEligible()` scope was corrected in fix-pass-4 to remove HashStatus filtering (operator-configurable; lives in Tier-2-aware buyer code), keeping the predicate exclusively about credential trust + slot availability. DECISION_CRITERIA Entries 67 (PR #78 self-heal), 69 (PR #69 fix-pass-3 + AuthState primitive, renumbered from 67 at merge time), 70 (PR #69 fix-pass-4 + RoutingEligible scope correction, renumbered from 68), 71 (this composition note + atomic ValidateAndMarkTokenUsed + AuthMintFailed enum + extended eviction defense from fix-pass-5) document the full arc.

**Change log v0.8.3 (PR #78, merged 2026-06-12):** Post-deploy hardening from the 2026-06-12 first end-to-end M0-5/M1-6 production deploy on Pearl. FR-C9.4 amended with the unused-token self-heal clause. When the active row in `provider_tokens` for a `provider_id` has `last_used_at IS NULL` AND a tokenless connect arrives, the coordinator MUST revoke that row and mint a fresh token for the incoming connect, instead of rejecting. A token that has never authenticated cannot have been captured-and-used by an attacker — the codex MAJOR-1 credential-capture vector that v0.8.1 closed requires the attacker to have authenticated at least once, which sets `last_used_at`. The strict-reject path is preserved for `last_used_at IS NOT NULL` (a used token is a live credential and the security argument applies in full). The trigger was the 2026-06-12 deploy gap: `air5` connected to the v1.3.0 coordinator under `require_provider_tokens=false`, the coordinator restarted to v1.3.1-5 and minted a self-serve token during admission, but `air5`'s old binary did not consume the ack-frame's `assigned_provider_token`. On reconnect the binary sent tokenless and v0.8.2's strict TOFU rejected it indefinitely. With v0.8.3, the same sequence revokes-and-remints automatically and the provider re-enters the pool with a fresh row. Storage-layer primitive added: `auth.Store.RevokeUnusedTokenForProvider(ctx, providerID) (revoked bool, err error)` performs the conditional revoke as a single-statement `UPDATE` which SQLite WAL serializes against concurrent writers. v0.8.4 supersedes by composing this with the PR #69 quarantine primitive.

**Change log v0.8.2:** Post-re-audit hardening from the codex security-reviewer focused pass on commit 4b1c527 in PR #44. **(a)** FR-C9.4 TOFU enforcement moved from a SELECT-then-INSERT pattern (TOCTOU-vulnerable: two concurrent tokenless connects for the same `provider_id` could both pass the gate before either committed) to a DB-layer partial unique index `idx_provider_tokens_one_active_per_provider ON provider_tokens(provider_id) WHERE revoked_at IS NULL`. `IssueToken` now returns `ErrActiveTokenAlreadyExists` on constraint violation; `resolveProvisionalToken` maps that to the TOFU close path. The migration step revokes pre-existing duplicate active rows so the index can be installed on existing databases. **(b)** FR-C9.3 binary-side persist now AWAITs disk I/O completion before in-memory adoption, closing the v0.8.1 brick-mode where a process crash between in-memory adoption and persist flush would strand the token coordinator-side and TOFU-reject the binary on next restart. The await runs on a detached priority-utility Task so the actor suspends but the runtime doesn't, preserving the FR-C9.3 SHOULD-not-block intent. **(c)** `coordinator-cli prune-tokens` refuses cutoffs younger than 24h without `--force`, and the dry-run output now lists candidate `provider_id` + `token_prefix` + `created_at` so the operator can sanity-check before `--apply` (a self-minted token is `last_used_at IS NULL` until the binary reconnects with Bearer, which can be seconds out — naive cutoffs can brick providers mid-onboarding). **(d)** SPEC-003 prose contradictions cleaned: v0.8.1 still contained pre-TOFU "multi-mint by design" passages in FR-C9.1 + FR-C9.4 prose; v0.8.2 rewrites these to match the TOFU contract.

**Change log v0.8.1:** Post-merge audit hardening from three codex auditors (code-reviewer / security-reviewer / architect) on the v0.8 implementation in PR #44. **(a)** FR-C9.4 rewritten from "multi-mint on tokenless reconnect" to **TOFU (trust-on-first-use)**: once an unrevoked token exists for a `provider_id`, the coordinator MUST refuse tokenless admission with `CloseInvalidToken / "invalid_token"`. This closes the security-MAJOR credential-capture exploit where an attacker could declare a victim's `provider_id` on a tokenless connect and harvest a valid bearer for it. Persist-failure self-healing is now an operator-action (revoke + retry), not an automatic re-mint. **(b)** FR-C9.3 binary-side persist relaxed from "MUST NOT block the WS receive loop" by moving from a strict prohibition to a "SHOULD offload" with the implementation using a detached Task. The previous inline implementation violated the contract. **(c)** Config key contract clarified everywhere: the binary writes the **top-level** YAML key `provider_token`, not `auth.provider_token`. Prior prose in v0.8 referenced the nested path; SPEC-001 and the actual `ConfigLoader` use flat. **(d)** Normative interaction with SPEC-002 v1.3.5 FR-P12 / PG-1 spelled out: SPEC-003 v0.8 supersedes those locked clauses for tokenless provisional admission under `require_provider_tokens=true`. **(e)** Operator-side prune is now normative: `coordinator-cli prune-tokens [--apply]` removes never-used unrevoked tokens older than the supplied cutoff. **(f)** Coordinator-side adds a separate `TokenIssuer` interface alongside `TokenValidator` (interface segregation per architect MINOR-2).

**Restructure note (v0.2).** SPEC-003 v0.1 contained four parts in a
single document. v0.2 redistributes them to avoid cross-spec drift:
- **Part A** (WS-tunneled inference wire protocol) → SPEC-001 v1.2.1 § 6.6
- **Part B** (dynamic admission + routing weight) → SPEC-002 v1.1.2
  § 3/§ 5/§ 7.1/§ 7.5
- **Part C** (distribution + lifecycle) → this document (SPEC-003 v0.2 § 4)
- **Part D** (onboarding UX) → this document (SPEC-003 v0.2 § 5)

SPEC-003 v0.2 also provides the **integration narrative** (§ 3) that
explains how SPEC-001 v1.2.1, SPEC-002 v1.1.2, and this spec compose into
the "stranger downloads and joins" experience.

**Change log v0.3:** Resolves audit findings C4, M4, M3, m1, m3.
- AC-1: restored `coordinator connection succeeds` as mandatory pass condition (C4 fix). Added AC-1a for degraded-mode install.
- § 7.3: fixed SPEC-001 clean-room cross-reference from § 8.2 to § 7.2 (M4 fix).
- OQ note: updated for v0.1 OQ-2 split between SPEC-001 OQ-5 (provider-side) and SPEC-002 OQ-10 (coordinator-side) (M3 fix).
- § 8 D8 reference: broadened to SPEC-002 v1.1.2 § 10 D8 + SPEC-001 v1.2.1 FR-30 (m1 fix).
- Added line-count justification note (m3 fix).

**Change log v0.4:** Resolves round-2 audit finding MAJOR-2.2.
- § 2 and § 9: SPEC-002 companion AC range updated from "AC-11 through AC-14" to "AC-11 through AC-15" to include the nak routing-mode fallback test.
- Build-complete label updated to v0.4.

**Change log v0.5:** Resolves Day-3 distribution follow-ups from
Decision log Entry 20.
- § 5: local self-test failures in `install.sh` MUST print the first
  200 bytes of the raw `/v1/models` response, or the stderr path and
  last 200 stderr bytes when the endpoint returns nothing.
- § 4: distribution-channel decoupling is now explicit:
  `install.sh` is served from `main` via `get.streamvc.live` and is
  NOT bundled into the release tarball.
- § 10: new audit category requires integration tests, not code-review
  approval alone, for shell-script paths touching real OS resources.

**Line-count note (v0.3).** v0.2 final length (752 lines) is below
the 1200-1500 target from the redistribution prompt. Justification:
Parts C (distribution) and D (onboarding) are genuinely smaller than
the WS protocol (Part A) and admission tier (Part B) content that
moved to SPEC-001 v1.2.1 § 6.6 and SPEC-002 v1.1.2 § 3/§ 5/§ 7. The
integration narrative in § 3 adds cross-spec context without inflating
to artificial length.

---

## 0. Operator-paste invocation block

```
Implement SPEC-003 (Parts C + D). The WS-tunneled inference protocol
is in SPEC-001 v1.2.1 § 6.6 and the dynamic admission is in SPEC-002
v1.1.1. This spec covers distribution, lifecycle, and onboarding UX.

As you work, maintain a running
phase5-onboarding/implementation-notes.html that captures anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

The Mac Provider network works — two providers, two models, real
multi-model routing, ~2.5 s end-to-end inference. SPEC-001 v1.2.1 adds
WS-tunneled inference so providers need zero inbound network.
SPEC-002 v1.1.2 adds dynamic admission so the coordinator accepts
strangers automatically.

But these protocol and coordinator changes are invisible without a
**distribution layer**. A stranger reading a GitHub README still cannot
become a provider unless they:
- Build the binary from source (requires Xcode + Swift toolchain)
- Manually write a config file
- Know the coordinator URL
- Set up a launchd service for reboot survival

SPEC-003 makes Mac Provider a **downloadable product**. After SPEC-003
ships, the user experience for joining the network is:

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
```

One line. Zero operator action. Provider in the pool within 2 minutes
(excluding the multi-GB model download on first run).

Two parts make this work:

- **Part C — Distribution + lifecycle.** GitHub Releases, curl-pipe-bash
  install script at `get.streamvc.live`, `macprovider-cli update`
  subcommand, launchd plist for reboot survival, log rotation,
  coordinator-advertised version nudge.
- **Part D — Onboarding UX.** The README flow, `install.sh` prompts,
  first-run self-test, status check, uninstall.

Decision log Entry 18 (2026-05-28) is the direct rationale: "the
network works, the product doesn't yet exist."

---

## 2. Scope

### In scope (Parts C + D)

**Part C — Distribution + lifecycle:**
- GitHub Releases with tagged binaries, checksums, release notes
- `install.sh` at `get.streamvc.live`
- `macprovider-cli update` subcommand (self-update)
- `macprovider-cli status` subcommand (local + remote state)
- `macprovider-cli uninstall` subcommand (remove everything)
- launchd plist for reboot survival
- Log rotation
- Coordinator-advertised `recommended_binary_version` in `hello_ack`
  (see SPEC-001 v1.2.1 § 6.5)

**Part D — Onboarding UX:**
- README-driven setup flow
- `install.sh` interactive prompts (model selection, coordinator URL)
- First-run self-test with user-visible output
- `macprovider-cli status` for contributor self-diagnostics
- Graceful degradation on coordinator unavailability

### Companion specs (Parts A + B, shipped together with C + D)

- **SPEC-001 v1.2.1** — Part A: WS-tunneled inference wire protocol
  (§ 6.6 inference message types, FR-21 through FR-32, AC-11 through
  AC-15).
- **SPEC-002 v1.1.2** — Part B: Dynamic admission and WS-tunneled relay
  (three-tier admission, routing weight, provisional rate limits,
  operator endpoints, FR-P14 through FR-P21, AC-11 through AC-15).

All four parts MUST ship together because each fails without the
others: distribution without WS-tunneled inference still requires
Cloudflare tunnels; WS-tunneled inference without dynamic admission
still requires operator config changes; admission without distribution
still requires source builds.

### Out of scope

- **Antseed seller integration** — deferred to SPEC-007.
- **Smart router** — deferred to SPEC-004.
- **Rewards / billing** — deferred to SPEC-005.
- **Tier 2 attestation** — no privacy/attestation features.
- **Buyer-side privacy** — Tier 2 concern.
- **Changes to the buyer-facing HTTP API** — unchanged per SPEC-002
  v1.1.1 § 7.2.
- **Forcing pinned providers to migrate** — M4/M1 continue via
  existing tunnels per SPEC-001 v1.2.1 backward-compatibility statement.

---

## 3. Integration narrative

This section describes how SPEC-001 v1.2.1 (Part A), SPEC-002 v1.1.2
(Part B), and SPEC-003 v0.2 (Parts C + D) compose into the
"stranger downloads and joins" experience.

### End-to-end flow: stranger to serving provider

```
Stranger's Mac                    get.streamvc.live    GitHub Releases
      │                                  │                    │
      │  curl install.sh                 │                    │
      │──────────────────────────────>   │                    │
      │  <── install.sh ────────────────│                    │
      │                                                       │
      │  fetch latest release                                 │
      │──────────────────────────────────────────────────────>│
      │  <── macprovider-cli tarball + checksums ────────────│
      │                                                       │
      │  verify checksum                                      │
      │  extract to ~/.local/bin/                             │
      │  prompt: model selection (based on RAM)               │
      │  prompt: coordinator URL (default: streamvc.live)     │
      │  generate provider_id (UUID v4)                       │
      │  write ~/.config/macprovider/config.yaml              │
      │  optionally install launchd plist                     │
      │                                                       │
      │  macprovider-cli self-test                            │
      │  ├─ load model                                        │
      │  ├─ run inference (FR-20 self-test)                   │
      │  └─ connect to coordinator                            │
      │                                                       │
      │                           Coordinator                 │
      │  WSS hello ──────────────────────>│                   │
      │  (provider_id not in config)      │                   │
      │                                   │ SPEC-002 v1.1.2     │
      │                                   │ FR-P15: tier =    │
      │                                   │   provisional     │
      │                                   │ FR-P16: rate      │
      │                                   │   limit check     │
      │  <────── hello_ack ──────────────│                   │
      │  (tier: "provisional")            │                   │
      │                                   │                   │
      │  heartbeat (every 30s) ──────────>│                   │
      │                                   │                   │
      │              Buyer sends request  │                   │
      │                                   │ SPEC-002 v1.1.2     │
      │                                   │ § 3: mode =       │
      │                                   │   WS_TUNNELED     │
      │  <── inference_request ──────────│                   │
      │  (SPEC-001 v1.2.1 § 6.6)           │                   │
      │                                   │                   │
      │  inference_response_chunk ───────>│                   │
      │  inference_response_chunk ───────>│──> SSE to buyer   │
      │  inference_response_end ─────────>│──> [DONE]         │
      │                                   │                   │
      │  "You're serving inference!"      │                   │
```

### How the specs compose

| Step | Spec | Section |
|---|---|---|
| Download + install binary | SPEC-003 v0.2 | FR-C1 (releases), FR-C2 (install.sh) |
| Model selection | SPEC-003 v0.2 | FR-D2 |
| Config generation | SPEC-003 v0.2 | FR-C2 (install.sh) |
| launchd plist | SPEC-003 v0.2 | FR-C5 |
| Self-test inference | SPEC-001 v1.2.1 | FR-20 |
| WS hello + admission | SPEC-002 v1.1.2 | FR-P2, FR-P15, FR-P16 |
| WS-tunneled inference | SPEC-001 v1.2.1 | § 6.6, FR-21–FR-32 |
| Routing with tier weight | SPEC-002 v1.1.2 | § 5 (tier weight) |
| Self-update | SPEC-003 v0.2 | FR-C3 |
| Status check | SPEC-003 v0.2 | FR-C4 |
| Uninstall | SPEC-003 v0.2 | FR-C6 |

---

## 4. Functional requirements — Part C (Distribution + lifecycle)

**FR-C1. GitHub Releases.**
Each release of `macprovider-cli` is published as a GitHub Release on
the `macprovider-poc` repository (or a dedicated `macprovider-releases`
repo if the operator prefers to separate release artifacts from source).

Release shape:
- **Tag format:** `v{major}.{minor}.{patch}` (e.g., `v1.2.0`).
  Follows semantic versioning. The tag is created on the `main` branch.
- **Asset naming:** `macprovider-cli-{version}-{os}-{arch}.tar.gz`
  (e.g., `macprovider-cli-v1.2.0-darwin-arm64.tar.gz`). Only
  `darwin-arm64` is shipped in v1 (Apple Silicon only).
- **Checksums:** A `checksums.txt` file containing SHA-256 hashes for
  all assets, formatted as `{hash}  {filename}` (GNU coreutils style).
- **Release notes:** Markdown body with: version, date, summary of
  changes, breaking changes (if any), link to spec version this release
  implements.

**FR-C1a. Distribution channel decoupling.**
`install.sh` is served from `main` via the `get.streamvc.live` ->
`raw.githubusercontent.com/<owner>/<repo>/main/phase3-binary/dist/install.sh`
redirect. It is NOT bundled into the release tarball. This is an
intentional architecture property:

- Installer bugs (parse errors, sed quoting, environment-handling) can
  be fixed by a one-line commit to `main`; the next `curl ... | bash`
  carries the fix in seconds.
- Binary releases are tagged, signed, and immutable; an installer patch
  does not require re-running the GitHub Action or re-signing release
  artifacts.
- Strangers running `curl get.streamvc.live/install.sh | bash` always
  get the latest installer, but the installer fetches a specific signed
  binary release tag and verifies it.

The release tarball MUST NOT contain `install.sh`. Re-bundling it would
reintroduce the slow-iterate path and is explicitly out of scope.

**FR-C2. install.sh contract.**
The install script at `https://get.streamvc.live/install.sh` is the
primary distribution mechanism for new providers. It is a Bash script
that:

1. Detects the platform (`uname -s`, `uname -m`). Exits with error if
   not `Darwin` + `arm64`.
2. Checks for required tools: `curl`, `tar`, `shasum` (or `sha256sum`).
3. Fetches the latest release tag from the GitHub API
   (`GET /repos/{owner}/{repo}/releases/latest`).
4. Downloads the binary tarball and `checksums.txt`.
5. Verifies the SHA-256 checksum. Exits with error on mismatch.
6. Extracts the real binary and adjacent `.bundle` directories to `~/macprovider/`, then creates `~/.local/bin/macprovider-cli` as a symlink for PATH discoverability.
7. Adds `~/.local/bin` to `$PATH` in `~/.zshrc` (if not already
   present) with a comment marker: `# Added by macprovider-cli`.
8. Prompts the user for model selection (FR-D2).
9. Prompts for coordinator URL (default:
   `wss://coordinator.streamvc.live/ws/provider`).
10. Generates a stable `provider_id` (UUID v4, persisted to
    `~/.config/macprovider/provider_id`).
11. Writes `~/.config/macprovider/config.yaml` with the selected model,
    coordinator URL, and generated provider_id.
12. Optionally installs a launchd plist for reboot survival (FR-C5).
    User is prompted: "Install as a background service? [Y/n]"
13. Runs `macprovider-cli self-test` to verify the installation.
14. Prints a summary: binary version, model, coordinator URL,
    provider_id, and a "you're in the pool!" confirmation if the
    coordinator link succeeded.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Platform not supported |
| 2 | Missing required tool |
| 3 | Download failed |
| 4 | Checksum mismatch |
| 5 | Extraction failed |
| 6 | Self-test failed |
| 7 | User aborted |

**Side effects (files written):**

| Path | Purpose |
|---|---|
| `~/macprovider/macprovider-cli` | Real binary, adjacent to Swift/MLX `.bundle` directories |
| `~/.local/bin/macprovider-cli` | Symlink for PATH discoverability |
| `~/.config/macprovider/config.yaml` | Configuration |
| `~/.config/macprovider/provider_id` | Stable identity |
| `~/Library/LaunchAgents/live.streamvc.macprovider.plist` | launchd plist (if opted in) |
| `~/Library/Logs/macprovider/` | launchd stdout/stderr logs |

**Environment variables (override defaults):**

| Variable | Effect |
|---|---|
| `MACPROVIDER_MODEL` | Skip model selection prompt |
| `MACPROVIDER_COORDINATOR_URL` | Skip coordinator URL prompt |
| `MACPROVIDER_PORT` | Override local HTTP port; otherwise reuses existing config port when present, falling back to 8080 |
| `MACPROVIDER_INSTALL_DIR` | Override `~/macprovider` support directory |
| `MACPROVIDER_NO_LAUNCHD` | Skip launchd prompt (no plist) |
| `MACPROVIDER_NO_PROMPT` | Non-interactive mode (uses all defaults) |

**FR-C3. macprovider-cli update subcommand.**
`macprovider-cli update` performs an atomic self-update:

1. Queries the GitHub API for the latest release.
2. Compares the remote version to the running binary's version.
3. If newer: downloads the tarball and checksums, verifies checksum.
4. Extracts the new binary to a temporary path.
5. Runs `macprovider-cli self-test` with the new binary (sanity check
   before swap).
6. Atomically replaces the old binary with the new one (rename on same
   filesystem; if cross-filesystem, copy + rename + remove old).
7. If a launchd plist is installed, runs
   `launchctl bootout gui/$UID/live.streamvc.macprovider` then
   `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/live.streamvc.macprovider.plist`
   to restart the service with the new binary.
8. If no launchd plist, prints "Update complete. Restart macprovider-cli
   to use the new version."

If already at the latest version, prints "Already up to date
(v{version})" and exits 0.

`macprovider-cli update --check` performs only steps 1-2 and prints the
comparison without downloading.

**FR-C4. macprovider-cli status subcommand.**
`macprovider-cli status` displays local and remote state:

```
macprovider-cli v1.2.0

Local:
  Model:       mlx-community/Qwen2.5-7B-Instruct-4bit
  Status:      ready
  Uptime:      2h 34m
  Requests:    142 served, 0 errors
  RAM:         16 GB (M4)
  Context cap: 50,000 tokens

Coordinator:
  URL:         wss://coordinator.streamvc.live/ws/provider
  Connected:   yes (session abc-123)
  Tier:        provisional
  Pool models: Qwen2.5-7B (2 providers), Llama-3.2-3B (1 provider)

Update:
  Current:     v1.2.0
  Latest:      v1.2.1 (run 'macprovider-cli update' to upgrade)
```

Local state comes from the binary's in-process metrics (same data as
`GET /v1/health`). Coordinator state comes from the most recent
`hello_ack` and heartbeat exchange (SPEC-001 v1.2.1 § 6.5 `tier` field).
Update state comes from the GitHub API (cached for 1 hour to avoid rate
limits).

**FR-C5. launchd plist.**
The plist ensures `macprovider-cli` starts on login and restarts on
crash:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>live.streamvc.macprovider</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/macprovider/macprovider-cli</string>
    <string>--port</string>
    <string>8080</string>
    <string>--model</string>
    <string>mlx-community/Qwen2.5-7B-Instruct-4bit</string>
    <string>--provider-id</string>
    <string>example-provider</string>
    <string>--coordinator</string>
    <string>wss://coordinator.streamvc.live/ws/provider</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/macprovider/macprovider.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/macprovider/macprovider.err.log</string>
  <key>WorkingDirectory</key>
  <string>$HOME/macprovider</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
```

Notes:
- `$HOME` is expanded at install time by `install.sh`, not by launchd.
  The plist contains literal absolute paths.
- The plist invokes `$HOME/macprovider/macprovider-cli`, not the
  `~/.local/bin/macprovider-cli` symlink. The symlink remains for shell
  use, but launchd must use the real path so Swift Bundle resolution
  finds adjacent `.bundle` directories.
- `KeepAlive.SuccessfulExit = false` means launchd restarts the binary
  only on crash (non-zero exit), not on clean SIGTERM shutdown.
- `ThrottleInterval = 10` prevents restart storms.
- `ProcessType = Background` reduces scheduling priority and power impact.
- Log rotation is handled by the binary (FR-C8), not launchd.

**FR-C6. macprovider-cli uninstall subcommand.**
`macprovider-cli uninstall` removes all installed artifacts:

1. If launchd plist exists: `launchctl bootout
   gui/$UID/live.streamvc.macprovider` (stop the service).
2. Remove `~/Library/LaunchAgents/live.streamvc.macprovider.plist`.
3. Remove `~/.local/bin/macprovider-cli`.
4. Prompt: "Remove configuration and logs? [y/N]"
   - If yes: remove `~/.config/macprovider/` and
     `~/.local/share/macprovider/`.
   - If no: keep config and logs (allows re-install with same identity).
5. Remove the `PATH` addition from `~/.zshrc` (the line with the
   `# Added by macprovider-cli` marker).
6. Print "macprovider-cli has been uninstalled."

**FR-C7. Coordinator-advertised version nudge.**
The `hello_ack` message includes an optional `recommended_binary_version`
field (SPEC-001 v1.2.1 § 6.5). If the provider's `binary_version` is
older, the provider logs a warning: "A newer version is available
(vX.Y.Z). Run 'macprovider-cli update' to upgrade."

The coordinator does NOT enforce the version — providers running older
binaries continue to function. Enforcement is deferred (see SPEC-002
v1.1.1 OQ-7). The field is configured in `coordinator.yaml`
(`versions.recommended_binary_version`).

**FR-C8. Log rotation.**
The binary's log files (`stdout.log`, `stderr.log`) are rotated on
startup:
1. If a log file exceeds 50 MB, rename it to `{name}.1.log`.
2. If `{name}.1.log` already exists, delete it first (keep only one
   rotated file).
3. Open a fresh log file.

This provides simple 2-file rotation (~100 MB max disk usage for logs).

**FR-C9. Self-serve provisional provider token (closes Open Q2 / Entry 60).**
v0.8 closes the long-standing gate on flipping `auth.require_provider_tokens=true` with provisional strangers in the pool. Pinned-tier providers are operator-issued via `coordinator-cli issue-token` (M1-1, unchanged). Provisional providers self-mint on first admission.

**FR-C9.1. Coordinator MUST mint on tokenless provisional admission, subject to the FR-C9.4 composed gate.**
When `prepareProviderAdmission` (`phase4-coordinator/internal/ws/server.go`) returns a non-pinned `*pool.Provider` AND `auth.validated == false` AND the token store is configured (`s.tokens != nil`), the coordinator MUST evaluate the FR-C9.4 composed gate FIRST, then mint a fresh row in `provider_tokens` via `auth.Store.IssueToken(providerID, providerName)` in either of these outcomes:
  (a) no unrevoked row exists for this `provider_id`, OR
  (b) an unrevoked row exists with `last_used_at IS NULL` and FR-C9.4 self-healed it via `RevokeUnusedTokenForProvider`.

If the unrevoked row has `last_used_at IS NOT NULL` (strict TOFU path), the coordinator MUST NOT mint and MUST close the connection per FR-C9.4. If IssueToken races and returns `ErrActiveTokenAlreadyExists` (race-loss path), the coordinator MUST admit the connection bearer-less with `AuthBearerlessDuplicate` marking — non-routable, non-billable, eviction-defended — per FR-C9.4. The mint MUST happen AFTER admission is approved and BEFORE the corresponding ack frame is written so that ack-write failure does not leave the operator without a record that a token was promised. v0.8.1 specified the mint MUST NOT be conditional on prior rows (multi-mint by design); v0.8.2 narrowed this to "MUST be conditional on FR-C9.4 TOFU" (blanket reject); v0.8.4 composes self-heal-on-NULL (PR #78 deploy-gap recovery) with strict-reject-on-USED (credential-capture closure) and adds the race-loss admit-quarantined branch (PR #69) — see FR-C9.4 for the full security rationale.

If the INSERT succeeds, the cleartext token MUST be returned in the ack frame so the binary can persist it (FR-C9.3). If the INSERT fails on the partial unique index (`ErrActiveTokenAlreadyExists`), the coordinator MUST admit the connection without including `assigned_provider_token` in the ack — see FR-C9.4 for the settling-window rationale. If the INSERT fails on any other DB error, the coordinator MUST admit the connection tokenless and log a warning.

The minting backend MUST enforce the one-active-token-per-provider_id invariant at the database layer (a partial unique index on `provider_tokens(provider_id) WHERE revoked_at IS NULL` is the normative implementation; the v0.8.2 reference store in `phase4-coordinator/internal/auth/tokens.go` installs this index in `migrate()`). The `IssueToken` call MUST surface a constraint failure as a distinct sentinel error (`ErrActiveTokenAlreadyExists` in the reference implementation) so the caller can apply the v0.8.3 admit-tokenless contract (mark the session `AuthBearerlessDuplicate`, exclude from routing + billing, refuse to evict an existing routable session — see FR-C9.4) without leaking a generic 500 to the wire. This DB-layer enforcement closes the TOCTOU race the codex security re-audit on PR #44 (MAJOR-1) flagged in the v0.8.1 implementation, where two concurrent tokenless connects could both pass the `HasActiveTokenForProvider` check before either insert.

The `providerID` is the value declared in the `hello` or `auth_request` initial frame. The `providerName` is the value declared as `hostname` in the same frame; if `hostname` is empty (unreachable per existing `requireString` parsing, but defensive), the coordinator MAY synthesize a placeholder of the form `provisional:<provider_id>`.

When `auth.validated == true` (provider sent a Bearer that matched), or when admission is rejected, or when the token store is not configured, the coordinator MUST NOT mint and MUST NOT include the field in any ack frame.

**FR-C9.2. Ack frame contract — both v1 and v2.**
The minted token MUST be returned to the binary in BOTH ack frames under the field name `assigned_provider_token` (string, lowercase hex, 64 hex chars matching the existing `IssueToken` output format). The field is OPTIONAL (`omitempty`). Field placement:

- **v1 path:** `HelloAck` struct in `phase4-coordinator/internal/ws/messages.go` gains `AssignedProviderToken string \`json:"assigned_provider_token,omitempty"\``. The v1 path writes this on the existing `hello_ack` emission at `server.go:386`.
- **v2 path:** `AuthResponse` struct in the same file gains the same field. The v2 path writes this on the proof-stage-accepted `auth_response` emission at `server.go:624`. The v2 `auth_challenge` and any rejection-shaped `auth_response` MUST NOT carry the field.

Both ack writes happen AFTER `prepareProviderAdmission` and AFTER `releaseUnauth()`, on the path that also calls `s.tokens.MarkTokenUsed` for already-validated tokens. The mint hook is symmetric: same condition (`s.tokens != nil && !auth.validated`), same call shape, different surrounding struct.

**FR-C9.3. Binary MUST persist atomically with 0600 perms; persist SHOULD NOT block the WS receive loop.**
On receipt of an ack frame carrying `assigned_provider_token`, the phase3-binary MUST:

1. Write the token value to a temporary file in the same directory as the config file, with file mode 0600 set BEFORE writing the secret.
2. Atomically rename the temp file to the final config file path (`rename(2)` semantics — POSIX-atomic on same-filesystem renames).
3. Match a **top-level** YAML key only: `provider_token: <value>`. Indented `provider_token:` entries nested under a parent block (e.g. an `auth:` map) MUST be preserved verbatim; the persist routine owns only the top-level key. If multiple top-level `provider_token:` lines exist (from a prior botched write), ALL such lines MUST be collapsed to a single canonical entry with the new value.
4. **AWAIT the persist completion before adopting the token in memory.** The in-memory token MUST be updated ONLY after the rename(2) returns successfully. v0.8.2 hardening: v0.8.1 adopted in memory FIRST then fired a fire-and-forget persist; the codex security re-audit on PR #44 (MINOR-1) flagged the resulting brick window — a process crash between in-memory adoption and persist flush leaves the coordinator with a valid token row that the binary never persisted, and on next process restart the binary reconnects tokenless and TOFU-rejects. Awaiting closes the window: persist either succeeds (both sides have the token) or fails (neither side has it, current WS session continues with the pre-existing bearer).

The persist write SHOULD execute outside the WS receive loop synchronously (e.g. via `Task.detached(...).value` await) so disk I/O cannot stall the runtime even though the receive-handling actor suspends. The intent is "disk I/O does not block other actors / Tasks", not "disk I/O is fire-and-forget."

On persist failure (disk full, permission denied, parent directory missing) the binary MUST log a JSON-encoded structured-log line with `event=provider_token_persist_failed`, `error=<cause>`, `config_path=<resolved>`, continue serving the current WS session with the previously-configured bearer (or no bearer), and NOT crash. The JSON line MUST be encoded via a JSON encoder, not hand-built string interpolation, so embedded quotes/newlines/backslashes in the error description or path cannot break the JSON envelope.

The persist target is the top-level `provider_token` YAML key (already wired by M1-1 SPEC-001 v1.3.1 § config). If the config file already has a top-level token populated, the new one REPLACES it. Pre-v0.8.1 prose referenced `auth.provider_token` (nested); the correct contract is flat top-level.

**FR-C9.4. TOFU (trust-on-first-use), composed: self-heal-on-NULL + strict-reject-on-USED + race-loss admit-quarantined + pool-registry eviction defense.**

When a tokenless connect arrives for a `provider_id` that already has an unrevoked row in `provider_tokens`, the coordinator MUST evaluate the row's `last_used_at` and act per the table:

| Existing row's `last_used_at`         | Required coordinator action                                                                                                                |
|---------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `NULL` (never authenticated)          | **Self-heal:** atomically revoke the existing row and mint a fresh token for this connect. Admit with the fresh-token ack frame; mark the session `AuthSelfMinted`. |
| `NOT NULL` (token has been presented) | **Strict TOFU reject** with close code `CloseInvalidToken / "invalid_token"`. The coordinator MUST NOT mint a parallel token.              |
| DB error evaluating either signal     | **Fail closed:** reject as above. The gate MUST NOT mint in the dark.                                                                      |
| IssueToken race-loss after self-heal/no-row gate passed | **Admit bearer-less with `AuthBearerlessDuplicate` marking.** The connection is admitted without a token; routing + billing exclude it; the pool-registry eviction defense protects an already-routable session for the same `provider_id`. |

**Self-heal implementation.** The reference store exposes `auth.Store.RevokeUnusedTokenForProvider(ctx, providerID) (revoked bool, err error)` which issues a single-statement `UPDATE provider_tokens SET revoked_at = now WHERE provider_id = ? AND revoked_at IS NULL AND last_used_at IS NULL` and reads `RowsAffected`. SQLite WAL serializes the writer, so a concurrent reconnect either sees the row before-revoke (and revokes it itself, racing the first connect) or after-revoke (and finds no row to revoke). When `revoked == true`, the partial unique index `idx_provider_tokens_one_active_per_provider` (v0.8.2) guarantees the provider now has zero active rows, so the subsequent `IssueToken` cannot race a duplicate; on rare two-concurrent-mints races the index still traps the second mint at INSERT time and the coordinator follows the race-loss admit-quarantined path. When `revoked == false`, a single `HasActiveTokenForProvider` call disambiguates "no row at all" (mint OK) from "active row with `last_used_at IS NOT NULL`" (strict reject).

**Security argument (composed).** Pre-v0.8.1 this clause specified "multi-mint on tokenless reconnect is intentional" so failed persists could self-heal automatically. The codex security audit on PR #44 (MAJOR-1) demonstrated that this design lets an attacker who declares a victim's `provider_id` on a tokenless connect harvest a valid bearer for it — but the exploit requires the attacker to USE the harvested bearer (otherwise it has no value), and using it sets `last_used_at`. v0.8.1's blanket TOFU closed the vector at the cost of bricking every persist-failure / deploy-gap case. v0.8.4 narrows the strict-reject to the actually-exploitable case (`last_used_at IS NOT NULL`) and restores in-band self-heal for the unused case, where the security argument does not apply. The 2026-06-12 deploy-gap incident on `air5` made the operational cost of the blanket policy concrete: a legitimate provider was locked out indefinitely after a routine coordinator restart even under `require_provider_tokens=false`. The race-loss admit-quarantined path closes the residual pool-slot-capture vector flagged on the v0.8.3 PR #69 codex security review (MAJOR-1): a concurrent attacker who wins the IssueToken race after self-heal is admitted bearer-less but cannot route or bill, and cannot evict the legitimate session if one is already registered. DECISION_CRITERIA Entries 67/68/69/70 capture the full reasoning arc.

Operator-facing log lines distinguish the paths for post-incident analysis:

- self-heal fired: `event=fr_c9_4_self_heal provider_id=<id>`
- strict reject fired: `event=fr_c9_4_tofu_reject provider_id=<id>` (matches the v0.8.1 log fingerprint for backwards-compatible alerting)
- race-loss admit fired: `event=fr_c9_4_race_loss_admit_quarantined provider_id=<id>`

The strict-reject path is preserved for the case where a legitimate provider lost its persisted token AFTER having authenticated with it (manual config edit, disk corruption, mismatched binary roll-back, etc.). That case still requires operator judgment because the same connect-shape is the credential-capture attack's signature. The operator runbook stays:

**(a) Storage invariant.** The token store MUST enforce a partial unique index equivalent to:

```sql
CREATE UNIQUE INDEX idx_provider_tokens_one_active_per_provider
  ON provider_tokens(provider_id) WHERE revoked_at IS NULL AND provider_id <> '';
```

This index is the authoritative "at most one valid bearer per `provider_id`" enforcement. The reference store in `phase4-coordinator/internal/auth/tokens.go` installs it in `migrate()`; existing databases get a one-time migration that revokes pre-existing duplicate active rows so the index can be installed without aborting. `IssueToken` MUST surface a unique-constraint failure as a distinct sentinel error (`ErrActiveTokenAlreadyExists` in the reference implementation) so the caller can take the v0.8.4 race-loss admit-quarantined path (mark `AuthBearerlessDuplicate`, non-routable, eviction-defended) without leaking a generic 500 to the wire.

**(b) Settling-window wire contract** (when `RequireProviderTokens=false`). When a tokenless connect arrives for a `provider_id` that already has an unrevoked row, the coordinator MUST follow the v0.8.4 composed gate documented in the table at the top of this clause (FR-C9.4). Concretely:

1. Call `RevokeUnusedTokenForProvider`. If it returned `(true, nil)` (self-heal fired), proceed to step 4.
2. Otherwise call `HasActiveTokenForProvider`. If it returned `(true, nil)` (a USED row exists), close the connection with `CloseInvalidToken / "invalid_token"` (strict TOFU reject).
3. If either step returned a DB error, fail closed with `CloseInvalidToken / "invalid_token"`.
4. Attempt the mint via `IssueToken`. On success, mark the admission with `AuthSelfMinted` and return the cleartext token in the ack frame.
5. If `IssueToken` returned `ErrActiveTokenAlreadyExists` (the partial unique index trapped a concurrent INSERT), mark the admission with `AuthBearerlessDuplicate`, admit WITHOUT a token in the ack frame, and log an info-level event with `provider_id` so operators surface race-loss admits in their pre-flag-flip audit. This is the only path that reaches the `AuthBearerlessDuplicate` quarantine.
6. If `IssueToken` returned any other DB error, mark the admission with `AuthMintFailed` and close with `CloseInvalidToken / "invalid_token"`. Fail-closed on transient infra so an empty `AuthState` is never routable (security audit, PR #69 fix-pass-5).

The settling-window posture replaces v0.8.1's blanket strict reject (which bricked old-binary cohorts on the 2026-06-12 Pearl deploy attempt) with the table-driven composed gate. Hard-reject is preserved only for the credential-capture path (used row + tokenless reconnect) and the fail-closed paths (DB error, mint error). The legitimate deploy-gap shape (NULL row + tokenless reconnect) self-heals automatically.

**Routing + billing + registry consequences (normative; v0.8.4 composed contract).** An admission marked `AuthBearerlessDuplicate`:

- MUST be excluded from buyer routing eligibility (the reference implementation's `pool.Provider.RoutingEligible()` returns false when `AuthState == AuthBearerlessDuplicate`).
- MUST be excluded from billing identity propagation (a consequence of the routing exclusion — a non-routable session receives no buyer traffic, so no billing rows accrue under the claimed `provider_id`).
- MUST be refused by the registry if a session for the same `provider_id` is already registered (eviction defense: the registry's `Register` returns `(_, registered=false)` when the new admission is `AuthBearerlessDuplicate` AND a prior session exists, and the WS handler closes the new connection with `CloseInvalidToken / "invalid_token"`). The legitimate provider's session is preserved.
- MUST be surfaced in the `/poolz` JSON via the `auth_state` field on each `pool.Provider` entry so operators see which providers are admitted but non-routable.

This closes the pool-slot capture vector flagged by the PR #69 codex security review: pre-fix, a bearer-less duplicate connect would last-writer-win on `provider_id` in the registry, evicting the legitimate provider and receiving buyer traffic + accruing billing identity under the claimed `provider_id`.

**(c) Post-flip wire contract** (when `RequireProviderTokens=true`). Tokenless connects are rejected at the WS upgrade layer by `validateProviderToken` BEFORE reaching admission unless `auth.allow_tokenless_provisional_bootstrap=true` is also explicitly enabled. With that bootstrap flag enabled, a tokenless provisional connect reaches the same FR-C9 mint / TOFU path documented above: first-claim provisional installs can receive and persist a fresh `assigned_provider_token`, while pinned providers and provider IDs whose active token has already been used still close with `CloseInvalidToken / "invalid_token"`. The bootstrap exception MUST fail closed if the coordinator has no `TokenIssuer` wired. The DB constraint at this layer is defense in depth — if a future code path admitted a tokenless connect under flag=true, the INSERT would fail with `ErrActiveTokenAlreadyExists` and the connection would proceed bearer-less (non-routable) rather than minting a credential-capture window.

**Operator flag-flip runbook (normative).** Before flipping `RequireProviderTokens=true`, the operator MUST verify EVERY active token row carries operational provenance evidence — specifically, the `last_used_at` column populated by the `MarkTokenUsed` call on a successful Bearer connect MUST be within an acceptable freshness window (recommended: 24 hours). A row whose `last_used_at IS NULL` proves no binary has ever successfully authenticated with that token; the row was either minted but never persisted by the legitimate provider OR minted by an attacker who never had a binary capable of using it. In either case the operator MUST treat such rows as "unproven" and either:

1. Revoke + ask the legitimate provider to reconnect (they will then race for a fresh mint; if the same `last_used_at IS NULL` outcome repeats, the legitimate provider's binary likely cannot persist tokens and a binary upgrade is required), OR
2. Coordinate out-of-band with the legitimate provider to issue them a pinned-tier token via `coordinator-cli issue-token` and have them paste it into their `provider_token` config field manually.

Pure "row existence" is NOT operational evidence under the v0.8.4 contract. The runbook MUST gate the flag flip on `last_used_at` freshness — not on `list-tokens` enumeration alone — to prevent flipping with an attacker-owned bearer in the active set. The operator MUST also verify zero `AuthBearerlessDuplicate` entries and zero unproven `AuthSelfMinted` sessions (those with `last_used_at IS NULL`) in `/poolz` before flipping.

The `last_used_at` freshness check is automated by `coordinator-cli pre-flip-audit --max-last-used-age=24h` (#82 item 3, shipped in v0.10.1). The command lists every active `provider_tokens` row, flags any with `last_used_at IS NULL` or older than the cutoff, and exits non-zero on any offender. Operators MUST integrate this command into the deploy pipeline as a precondition before flipping `RequireProviderTokens=true` — a non-zero exit MUST block the flip until each offender is either reconnected (so `MarkTokenUsed` stamps a fresh `last_used_at`) or revoked. The default cutoff matches the runbook recommendation; tighter values (e.g. `--max-last-used-age=1h`) are appropriate for short-deploy-window operators. `--json` emits a machine-readable report with the same exit-code contract for pipeline integration.

**What stays unchanged from v0.8.2.** The partial unique index, `ErrActiveTokenAlreadyExists` sentinel, and migration step are all preserved as-is. The credential-capture attack the codex security audit on PR #44 (MAJOR-1) closed remains closed — an attacker still cannot mint a parallel bearer for someone else's `provider_id`, because the INSERT fails on the unique constraint. The v0.8.4 composition adds two further closures: (a) atomic `ValidateAndMarkTokenUsed` removes the brief window where a Bearer-validated provider's row was still `last_used_at IS NULL` and could be self-healed by a concurrent attacker, and (b) extended `pool.Registry.Register` eviction defense refuses non-Bearer-validated sessions from replacing an existing routable Bearer-validated session.

Operator-side bounded-cleanup is unchanged: `coordinator-cli prune-tokens [--older-than 168h] [--apply]` removes rows where `last_used_at IS NULL AND revoked_at IS NULL AND created_at < cutoff`.

**FR-C9.5. Compatibility cutoff at flag flip.**
When the operator flips `auth.require_provider_tokens=true` (Decision log Entry 59 forecast; Entry 60 confirmed), tokenless connects are rejected at `validateProviderToken` BEFORE reaching admission unless `auth.allow_tokenless_provisional_bootstrap=true` is explicitly enabled. After the flip with bootstrap disabled, FR-C9.1's mint path is unreachable for new connects — only providers holding a valid token (operator-issued OR previously self-minted) connect. After the flip with bootstrap enabled, FR-C9.1 remains reachable only for first-claim provisional bootstrap; pinned providers and provider IDs whose active token has already been used continue to reject tokenless reconnects.

Production deployments intending public `curl|bash` provider onboarding MUST run:

```yaml
auth:
  require_provider_tokens: true
  allow_tokenless_provisional_bootstrap: true
```

Invite-only deployments MAY keep `allow_tokenless_provisional_bootstrap=false`, but then each new provider needs an operator-preprovisioned `provider_token` before first connect.

**Supersedes SPEC-002 v1.3.5 FR-P12 / PG-1 for tokenless provisional admission.** Those locked clauses say provisional providers may continue without tokens under `require_provider_tokens=true`; SPEC-003 v0.8.1 explicitly narrows that to "providers with at least one unrevoked token row." The locked SPEC-002 text is intentionally preserved as-is; this supersede is normative for the open-onboarding tier (per codex architect MAJOR-1, PR #44). A future SPEC-002 revision SHOULD amend FR-P12 / PG-1 to reflect this.

The flag flip is safe AFTER:

1. The new coordinator binary carrying FR-C9.1/FR-C9.2/FR-C9.4 is deployed on Pearl.
2. A new release tag of `macprovider-cli` carrying FR-C9.3 is published and `install.sh`'s `latest_release_tag()` resolves to it.
3. A settling window (≥24h, operator's discretion) has elapsed during which existing provisional providers reconnect at least once and self-mint.

Old binaries that cannot parse `assigned_provider_token` will silently drop the field (Swift's JSON decoder ignores unknown keys) and never persist a token; at flag-flip time they are rejected at the WS handshake — same blast radius as the original M1-1 plan, no worse. Entry 60 records this as the explicit compatibility cutoff. The operator action `coordinator-cli list-tokens` may be used during the settling window to verify that all expected provider IDs have at least one unrevoked token row before flipping the flag.

**FR-C9.6. install.sh is NOT modified.**
The bootstrap pipe `curl https://get.streamvc.live/install.sh | bash` continues to write a tokenless `config.yaml`. Token acquisition happens automatically on the first WS connect after install. This preserves the single-shell-pipe UX that the open-onboarding tier exists to provide; gating provisional token issuance on operator action would re-create the very approval bottleneck Q2 was about removing.

**FR-C10. `pair_ot` minting policy on provisional admission.**

On every WS connect that the coordinator admits through the FR-C9 self-mint path (the same connect that mints a fresh `assigned_provider_token`), the coordinator MUST additionally evaluate the FR-C10 emission gate. The gate has three conjunctive conditions:

1. **The deployment opts into the GitHub-ownership surfaces.** The coordinator process environment variable `GITHUB_OAUTH_ENABLED` is exactly `"true"`. When the variable is `"false"` or unset, FR-C10 MUST NOT emit `pair_ot`, `claim_url`, `ownership_event`, or `needs_claim`, regardless of any other condition. This preserves the L-1 baseline for operators who do not deploy the downstream portal consumer.
2. **The connecting `provider_id` has no GitHub-bound ownership record.** The coordinator's ownership store has zero `provider_ownership` rows for the connecting `provider_id`. v0.10 treats any row as owned; a future operator-unlink amendment may define revocation semantics, but FR-C10 does not invent them. The ownership anti-check, FR-C9 provider-token insert, and `pair_ots` insert MUST be one commit-or-rollback transactional decision so the coordinator cannot mint pairing material against stale ownership state.
3. **This is the same connect that minted a fresh `assigned_provider_token` per FR-C9.1/FR-C9.2.** FR-C10 piggybacks on the FR-C9 mint event. The coordinator MUST NOT emit `pair_ot` on a reconnect that did not mint a fresh provider token, including reconnects by already-tokened providers. The post-first-connect refresh path is HTTP `POST /v1/install/pair/refresh`; FR-C10 does not add or imply a binary-to-coordinator WS refresh request.

When all three conditions hold, the coordinator MUST:

- Generate a fresh `pair_ot` value: 32 bytes from a cryptographically secure random source, encoded as lowercase hex. Store it in the `pair_ots` table with `expires_at = now + 600 seconds` and `used_at = NULL`. The `pair_ot` is not a provider, buyer, browser, or operator credential; it authorizes only one downstream ownership-bind attempt through authenticated routes.
- Compute `claim_url` as the literal `<PORTAL_BASE_URL>/claim?ot=<pair_ot>`, using the coordinator startup config value `PORTAL_BASE_URL`. If `PORTAL_BASE_URL` is unset or invalid while `GITHUB_OAUTH_ENABLED=true`, the coordinator MUST fail closed at startup; the FR-C10 ack emission path may rely on the parsed value being valid.
- Emit the pairing material on the ack frame by populating the fields whose wire placement is defined by SPEC-001 v1.5 §6.5.1 for v1 `hello_ack` or SPEC-001 v1.5 §6.7.2.1 for proof-stage-accepted v2 `auth_response`, following the same dual-path discipline as FR-C9.2's `assigned_provider_token`.

When any of the three conditions fails, the coordinator MUST NOT emit `pair_ot` or `claim_url` on the ack. The ack frame is otherwise unchanged from FR-C9's emission: `assigned_provider_token` may still be emitted when FR-C9 minted it, and all pre-v0.10 fields retain their existing semantics.

**FR-C10.1. `ownership_event {event: "bound"}` emission.**

After a successful `POST /v1/auth/me/providers/bind` transaction commits, the coordinator MUST emit an `ownership_event` server-pushed frame to the connected provider's WS session for the bound `provider_id` within 5 seconds of commit. The frame's wire shape is defined by SPEC-001 v1.5 §6.12, and the event value for this flow is `event: "bound"`.

If the provider's WS session is offline at bind time, the coordinator SHOULD enqueue the event in a provider-ID-keyed outbox for best-effort delivery on the next reconnect. The queued notification is not security-critical and MAY be discarded by an implementation-defined retention policy; the persisted local claim URL path owned by the downstream consumer remains the eventually consistent fallback for a Mac that was offline at bind time.

`event: "unbound"` is RESERVED for a later operator-unlink flow. FR-C10.1 does NOT require emitting `event: "unbound"` in the v0.10 timeframe.

**FR-C10.2. `needs_claim: true` migration signal.**

On each WS admission where all of the following hold, the coordinator MUST emit `needs_claim: true` on the next periodic ownership status frame for that WS session, using the status carrier defined by SPEC-001 v1.5 §6.5.2 and §6.12:

1. `GITHUB_OAUTH_ENABLED` is exactly `"true"`.
2. The connecting `provider_id` has a non-revoked provider-token row under the existing FR-C9 / SPEC-002 token store.
3. The ownership store has zero `provider_ownership` rows for that `provider_id`.

The coordinator MAY emit `needs_claim: true` exactly once per WS session and MAY omit the field on subsequent status frames. The coordinator MUST NOT emit `needs_claim: true` after it has sent `ownership_event {event: "bound"}` for the same `provider_id` in the same coordinator process lifetime. If `GITHUB_OAUTH_ENABLED` is `"false"` or unset, the coordinator MUST NOT emit `needs_claim` under any condition.

**FR-C10.3. Storage primitives.**

Coordinator implementations MUST add the following primitives to `auth.Store` or an equivalent coordinator-owned storage layer. These primitives extend the same coordinator-side storage boundary that already owns provider-token validation and minting; they do not expose a buyer or browser API surface.

```go
MintAdmissionTokenAndPairOT(ctx context.Context, providerID, providerName string) (providerToken string, pairOT string, pairOTExpiresAt time.Time, err error)
MintPairOT(ctx context.Context, providerID string) (token string, expiresAt time.Time, err error)
BurnPairOT(ctx context.Context, token string) (providerID string, err error)
HasOwnership(ctx context.Context, providerID string) (bool, error)
```

- `MintAdmissionTokenAndPairOT` is the WS-admission primitive used by FR-C10. It MUST perform the FR-C9 provider-token insert, the ownership anti-check, and the `pair_ots` insert in one database transaction. If the ownership anti-check finds a `provider_ownership` row, the operation MUST roll back and return an `ErrOwnershipExists`-class result without minting `providerToken` or `pairOT`; the caller treats this as an FR-C10 gate miss and continues the plain FR-C9 provider-token mint/admission path without pairing fields. If the `pair_ots` insert fails, the operation MUST roll back the compound transaction so the caller can fall back to a plain FR-C9 provider-token mint/admission without leaving a half-created pair-OT decision. Implementations MAY satisfy this with an explicit transaction wrapper rather than this exact function name, but the single-transaction semantics are mandatory.
- `MintPairOT` atomically inserts one row into `pair_ots` for the given `providerID`, with a fresh CSPRNG token and `expires_at = now + 600 seconds`. The token MUST be single-use; `used_at` starts as `NULL`.
- `BurnPairOT` performs the burn-first conditional update for a single token and returns the bound `providerID` on success. If no unexpired, unused row matches, it returns a distinct `ErrPairOTInvalid`-class error. The HTTP route and session behavior that consume this primitive are downstream concerns and are not republished here.
- `HasOwnership` returns true when a `provider_ownership` row exists for the supplied `providerID`.

These primitives are coordinator-side internal API. They MUST NOT be exposed on any HTTP route directly and MUST NOT be reachable from buyer or browser code except through the downstream consumer's authenticated routes.

**FR-C10.4. Failure modes and back-pressure.**

If the FR-C10 pair-OT half of the compound mint fails (DB error, disk full, entropy failure, config invariant violation, or any equivalent storage failure), the coordinator MUST fall back to the plain FR-C9 provider-token mint/admission path, admit the WS connect without `pair_ot` or `claim_url` on the ack, and log the failure at WARN level with `provider_id` and a redacted cause. This deliberately degrades to "the user can claim later through the HTTP refresh path" rather than rejecting an otherwise valid open-onboarding connect.

Rate limiting of WS-path `pair_ot` mints is out of scope for FR-C10 because the FR-C9 connect admission path already bounds first-tokenless admissions. HTTP refresh-path rate limits are owned by the downstream consumer and are not duplicated here.

**FR-C10.5. Test obligations.**

Coordinator implementations MUST cover at minimum:

- First tokenless admission emits `pair_ot` and `claim_url` when `GITHUB_OAUTH_ENABLED=true`, FR-C9 minted `assigned_provider_token`, and no ownership row exists.
- A bind/ownership creation racing first-tokenless admission yields either a committed ownership row with no `pair_ot` mint or a committed admission compound mint before ownership exists; it MUST NOT commit a provider-token insert and then mint `pair_ot` after ownership becomes true.
- The same admission with `GITHUB_OAUTH_ENABLED=false` or unset emits neither `pair_ot` nor `claim_url` and emits no ownership frames.
- Reconnect of an already-tokened provider with no `provider_ownership` row emits `needs_claim: true` once per WS session and does not emit `pair_ot` or `claim_url` on the ack.
- Reconnect of a bound provider emits neither `pair_ot` nor `needs_claim`.
- FR-C10 pair-OT mint failure falls back to plain FR-C9 admission, admits the WS connect without the pairing ack fields, and logs a warning.
- `ownership_event {event: "bound"}` is delivered within 5 seconds of bind commit to a connected provider; when the provider is offline and the implementation supports the provider-ID-keyed outbox, queued delivery on next reconnect is best-effort and may fall back to the persisted local claim URL path.

---

## 5. Functional requirements — Part D (Onboarding UX)

**FR-D1. README-driven setup flow.**
The project README includes a "Join the Network" section:

```markdown
## Join the Network

Run this on any Apple Silicon Mac (M1 or newer, macOS 14+):

\`\`\`bash
curl -fsSL https://get.streamvc.live/install.sh | bash
\`\`\`

The installer will:
1. Download the latest macprovider-cli binary
2. Ask you to choose a model (based on your Mac's RAM)
3. Connect you to the network
4. Optionally set up auto-start on login

**Requirements:**
- Apple Silicon Mac (M1, M2, M3, M4)
- macOS 14 (Sonoma) or later
- ~4-8 GB free disk space (for the model)
- Internet connection

**Check your status:**
\`\`\`bash
macprovider-cli status
\`\`\`

**Update:**
\`\`\`bash
macprovider-cli update
\`\`\`

**Uninstall:**
\`\`\`bash
macprovider-cli uninstall
\`\`\`
```

**FR-D2. install.sh model selection.**
The installer detects available RAM and presents appropriate model
options:

| RAM | Recommended models | Default |
|---|---|---|
| 8 GB | `mlx-community/Llama-3.2-3B-Instruct-4bit` (~2 GB) | Llama 3.2 3B |
| 16 GB | Llama 3.2 3B (~2 GB), `mlx-community/Qwen2.5-7B-Instruct-4bit` (~4 GB) | Qwen 2.5 7B |
| 24 GB+ | Llama 3.2 3B, Qwen 2.5 7B, `mlx-community/Qwen2.5-14B-Instruct-4bit` (~8 GB) | Qwen 2.5 14B |

The installer prints the model name, approximate download size, and
estimated context window. The user selects by number, or chooses
`c)` to enter a custom HuggingFace model id (see FR-D2.1). If the
model is not already downloaded, the installer runs
`huggingface-cli download {model}` (or prints instructions if
`huggingface-cli` is not installed). Model download is the longest
step and is NOT included in the "2 minutes to pool" target.

**FR-D2.1. install.sh custom-id branch (v0.9).**
The interactive menu MUST offer a fourth option `c) custom
HuggingFace MLX model id`. When selected, the installer reads a
single line of input (the HF repo id) and applies the following gates
in order:

1. **Format**: id MUST match `org/name` with each component drawn
   from `[A-Za-z0-9._-]+`, exactly one `/`, and no leading or
   trailing `/`, whitespace, or newline. Additionally (v0.9.1, after
   the charset and shape checks) neither segment may equal `.` or
   `..` — the charset filter permits these by themselves, so the
   installer MUST split on `/` and reject the literal `.` / `..`
   values explicitly. Violations die with exit code 7 before any
   network call.
2. **HuggingFace existence**: installer issues
   `GET https://huggingface.co/api/models/<id>` with a 10 s timeout.
   - `200` → proceed to step 3.
   - `401`, `403`, `404` → die with a single "not accessible
     (private, gated, or doesn't exist)" message; the installer MUST
     NOT distinguish these because HuggingFace does not disclose
     existence to unauthenticated callers. The error MUST direct the
     user to `macprovider-cli models switch` post-install with
     `HF_TOKEN` set for the gated-repo path.
   - Network error or unexpected status → log warning, skip
     remaining checks, proceed.
3. **MLX detection**: the repo qualifies if any of the following
   holds — the id starts with `mlx-community/`, OR the API body
   contains `"library_name":"mlx"`, OR the API body's `tags` array
   contains the literal element `"mlx"`. Failure dies with "not an
   MLX repo" and references `mlx_lm.convert` / `mlx-community/*`.
4. **RAM fit**: weights are estimated as `params_b ×
   bytes_per_param`. `params_b` is parsed from the repo name with
   two patterns tried in order (v0.9.1):
   - First, the Mixture-of-Experts shape
     `[0-9]+x[0-9]+(\.[0-9]+)?B` (e.g. `Mixtral-8x7B`); when
     matched, `params_b = experts × per_expert` (8 × 7 = 56 in the
     example).
   - Otherwise, the single-N shape `[0-9]+(\.[0-9]+)?B` from the
     first match.
   `bytes_per_param` is `0.5` (`4bit`/`q4`), `1.0` (`8bit`/`q8`),
   or `2.0` (`bf16`/`fp16`/`-f16` or unknown).
   - Comfortable: `ram_gb >= est_gb + 6` → log "fits", proceed.
   - Tight: `ram_gb >= est_gb + 2` → log warning, prompt
     `Proceed anyway? [y/N]`, default N.
   - Won't fit: otherwise → log warning, prompt as above.
   - If the name does not match the `B`-suffix pattern, log
     "could not estimate weight size; skipping fit check" and
     proceed.

The headroom constants match the existing RAM-tier defaults: 7B
(~4 GB weights) targets 16 GB Macs (`4 + 6 = 10 ≤ 16`), not 8 GB
Macs (`4 + 6 = 10 > 8`, falls to tight tier).

The env var `MACPROVIDER_SKIP_HF_CHECK=1` bypasses steps 2–4
entirely for offline or self-mirrored installs. The format check
(step 1) is always enforced. `MACPROVIDER_MODEL=<id>` continues to
skip the interactive prompt and proceed straight to install, but
SHOULD now also run the format check so malformed env values fail
fast; the HF/MLX/fit checks are skipped on the env-override path so
CI and `MACPROVIDER_NO_PROMPT=1` flows do not deadlock on an
interactive yes/no prompt.

All FR-D2.1 prompts and warnings MUST be written to stderr so the
installer's stdout-captured model id remains clean.

Coordinator and gateway behavior is unchanged: the coordinator
already accepts arbitrary `supported_models` advertised in the
provider's initial WS frame, so no protocol or schema change is
required for this branch.

**FR-D3. First-run self-test.**
On first run (or when invoked via `macprovider-cli self-test`), the
binary:
1. Loads the model (this is the slowest step).
2. Runs the SPEC-001 v1.2.3 FR-20 self-test (short inference, verify
   output).
3. Connects to the coordinator, sends `hello`, waits for `hello_ack`.
4. Calls `https://coordinator.streamvc.live/v1/pool/check?provider_id=<sanitized>` after WebSocket connect. This is the canonical post-SPEC-006-deployment verification path defined in SPEC-002 v1.1.4 § 7.4: `/v1/pool/check` stays on coordinator's public operator/health surface, not behind the gateway. The installer MUST NOT attempt to reach this endpoint via `api.streamvc.live`; the gateway does not proxy `/v1/pool/check`.
5. Prints results:
   ```
   Self-test results:
     Model loaded:     OK (mlx-community/Qwen2.5-7B-Instruct-4bit)
     Inference:        OK (18.3 tok/s)
     Coordinator:      OK (connected as provisional, session abc-123)
     Ready to serve!
   ```
6. If any step fails, prints the failure with a suggested fix:
   ```
   Self-test results:
     Model loaded:     OK
     Inference:        OK (18.3 tok/s)
     Coordinator:      FAILED - connection refused
       -> Check your internet connection
       -> Verify coordinator URL: wss://coordinator.streamvc.live/ws/provider
   ```

**FR-D3a. Installer self-test failure diagnostics.**
When `install.sh`'s local self-test (`wait_for_local_model`) times out, the script MUST print a diagnostic block that distinguishes "deadline reached" from "binary failed" and includes commands to check process liveness, Hugging Face cache growth, and stderr logs. This exists because first-time Qwen 7B downloads can exceed 5 minutes and the prior "Local self-test failed" message caused partners to conclude the install was broken while the binary was still loading.

The timeout path MUST also print the first 200 bytes of the actual `/v1/models` response when bytes are available, labelled clearly as "raw response". This requirement exists because wire-format mismatches between the installer's grep patterns and the binary's JSON encoder are the dominant failure mode for self-test false negatives (see Decision log Entry 20 Bug D). The 200-byte cap avoids dumping multi-kilobyte responses while reliably exposing the JSON structure that the grep is checking.

If the `/v1/models` endpoint returned no response (port unbound), the
script MUST instead print the binary's stderr log path and the last 200
bytes of stderr if non-empty. This ensures every failure mode produces
a self-diagnosing message.

**§ 5.X v1.2.4 partner-upgrade lessons.**
Install.sh upgrade-in-place was exercised at scale for the first time during the v1.2.4 partner upgrade, triggered by the SPEC-006 v0.5 launch path and tracked as Decision log Entry 22 follow-ups. Six findings surfaced from operator self-canary plus M4 partner reproduction, all closed in v0.7 (F-603-V7-1 through F-603-V7-7, excluding retracted F-603-V7-3 and F-603-V7-8). The findings clustered around three classes:

1. **Existing-state detection** — install.sh assumed fresh install
   paths; upgrade-in-place required reading prior config (port) and
   stopping the prior service (launchctl bootout).
2. **Swift Bundle resolution edge case** — launchd plist invoked the
   symlink path, which Swift's Bundle.main resolved incorrectly on some
   macOS environments. Fixed by invoking the real binary path from the
   plist.
3. **User-facing failure clarity** — "Local self-test failed" alarmed
   users when the binary was still loading. Diagnostic-rich timeout
   messaging plus cold-cache deadline extension shipped.

**FR-D4. Status check.**
See FR-C4 for the full `macprovider-cli status` output format. The
status subcommand is the primary diagnostic tool for contributors. It
answers: "Is my Mac serving? Am I in the pool? What tier am I?"

**FR-D5. Graceful degradation on coordinator unavailability.**
If the coordinator is unreachable (DNS failure, connection refused,
timeout), the binary:
1. Continues running the local HTTP server (for direct access if
   configured).
2. Logs a warning every 60 seconds: "Coordinator unreachable. Local
   server running. Retrying in {backoff}s."
3. Follows the existing reconnect-with-backoff logic (SPEC-001 v1.2.1
   FR-13).
4. Does NOT exit or stop serving. A contributor whose Mac is behind a
   temporary network outage should not need to manually restart.

---

## 6. Interface contracts

### 6.1. install.sh contract

Defined in FR-C2. Summary:

- **URL:** `https://get.streamvc.live/install.sh`
- **Hosting:** Cloudflare Pages (static site, free tier, global CDN).
  The `get.streamvc.live` subdomain is a CNAME pointing to Cloudflare
  Pages.
- **Arguments:** None (all configuration via interactive prompts or
  env vars).
- **Exit codes:** 0-7 (see FR-C2).
- **Side effects:** See FR-C2 file table.

### 6.2. macprovider-cli new subcommands

| Subcommand | Description | Requires running service |
|---|---|---|
| `serve` | Start the inference server (existing) | N/A (this IS the service) |
| `self-test` | Run model load + inference + coordinator check | No |
| `status` | Show local + remote state (FR-C4) | Yes (reads from running process) |
| `update` | Self-update to latest release (FR-C3) | No (stops service if needed) |
| `update --check` | Check for updates without downloading | No |
| `uninstall` | Remove all artifacts (FR-C6) | No (stops service if running) |

### 6.3. launchd plist schema

Defined in FR-C5. Key properties:

| Property | Value | Rationale |
|---|---|---|
| Label | `live.streamvc.macprovider` | Reverse-domain per Apple convention |
| RunAtLoad | true | Start on login |
| KeepAlive.SuccessfulExit | false | Restart on crash, not on clean stop |
| ThrottleInterval | 10 | Prevent crash-loop restart storms |
| ProcessType | Background | Reduce scheduling priority |

### 6.4. GitHub Releases shape

Defined in FR-C1. Summary:

| Property | Format | Example |
|---|---|---|
| Tag | `v{semver}` | `v1.2.0` |
| Asset | `macprovider-cli-{version}-{os}-{arch}.tar.gz` | `macprovider-cli-v1.2.0-darwin-arm64.tar.gz` |
| Checksums | `checksums.txt` (SHA-256, GNU format) | `a1b2c3...  macprovider-cli-v1.2.0-darwin-arm64.tar.gz` |
| Release notes | Markdown body | Version, date, changes, breaking changes, spec version |

---

## 7. Dependencies

### 7.1. Distribution dependencies

| Dependency | Purpose | License | Notes |
|---|---|---|---|
| GitHub API | Release discovery, download | N/A (public API) | No API key needed for public repos. Rate limit: 60 req/hr unauthenticated. `install.sh` makes 2 API calls; `update` makes 1-2. |
| Cloudflare Pages | Hosting `get.streamvc.live` | Free tier | Static site. Only serves `install.sh` and a landing page. |
| `huggingface-cli` | Model download | Apache-2.0 | NOT a hard dependency. `install.sh` prints manual download instructions if not installed. |
| `shasum` / `sha256sum` | Checksum verification | OS-provided | macOS ships `shasum` (BSD). Fallback to `openssl dgst -sha256` if neither found. |

### 7.2. Binary dependencies (no new additions)

No new Swift dependencies for Part C or Part D. The `update`
subcommand uses `URLSession` for HTTP (already available). The launchd
plist is a static file written by `install.sh`, not by the binary.

### 7.3. Clean-room hygiene

SPEC-003 v0.2 inherits the strict clean-room policy from SPEC-001
v1.2.1 § 7.2 and SPEC-002 v1.1.2 § 8.2. No d-inference source files were
read during spec writing. `cloudflared` is NOT a hard dependency for
SPEC-003 — WS-tunneled providers (SPEC-001 v1.2.1 § 6.6) need only
outbound WSS.

---

## 8. Phase 4 findings encoded in SPEC-003 v0.2

Findings D7-D10 are documented in SPEC-002 v1.1.2 § 10 (where they
belong, since they concern coordinator behavior). This section
cross-references them for completeness:

- **D7** (static config-map relaxed) → SPEC-002 v1.1.2 FR-P15, FR-P16,
  § 7.1 F-2 amendment, § 7.5
- **D8** (drain conflation) → SPEC-002 v1.1.2 § 10 D8 + SPEC-001 v1.2.1 FR-30
- **D9** (model_id case-sensitivity) → SPEC-002 v1.1.2 § 5
- **D10** (coordinator overhead) → SPEC-002 v1.1.2 FR-P14 validation
  method

---

## 9. Acceptance criteria

**AC-1 through AC-5 must ALL pass for SPEC-003 v0.7 to be considered
build-complete. Companion ACs in SPEC-001 v1.2.3 (AC-11 through AC-15)
and SPEC-002 v1.1.4 (AC-11 through AC-15) must also pass.**

---

**AC-1. install.sh from clean Mac.**

**Setup:** A Mac with no previous macprovider-cli installation. Model
already downloaded (to isolate install time from download time).

**Action:** `curl -fsSL https://get.streamvc.live/install.sh | bash`
(or local `bash install.sh` during testing).

**Expected:**
1. Binary installed to `~/.local/bin/macprovider-cli`.
2. Config written to `~/.config/macprovider/config.yaml`.
3. `provider_id` generated and persisted.
4. Self-test passes (model loads, inference works, coordinator
   connection succeeds).
5. Total time from script start to "Ready to serve!" message: <2
   minutes (excluding model download).

**How to verify:** Manual test on a clean user account.

---

**AC-1a. Degraded-mode install (diagnostic only — does NOT satisfy
build-complete).**

**Setup:** A Mac without internet access (or with coordinator
unreachable).

**Action:** `bash install.sh` with `MACPROVIDER_NO_PROMPT=1`.

**Expected:**
1. Binary installed, config written, provider_id generated.
2. Self-test: model loads and inference works.
3. Self-test: coordinator connection FAILS with a clear warning.
4. install.sh exits with code 6 (self-test failed) but prints:
   "Installed locally. Coordinator connection failed — provider will
   join the pool when internet is available."

**Note:** AC-1a is offered for diagnostic purposes. AC-1 (with
coordinator connection success) remains the build-complete gate.

**How to verify:** Manual test on isolated network.

---

**AC-2. macprovider-cli update.**

**Setup:** Install v1.2.0. Publish v1.2.1 to GitHub Releases.

**Action:** `macprovider-cli update`

**Expected:**
1. New version detected and downloaded.
2. Checksum verified.
3. Binary atomically swapped.
4. If launchd plist installed: service restarted with new binary.
5. `macprovider-cli --version` shows `1.2.1`.

**How to verify:** `phase5-onboarding/scripts/test-update.sh`

---

**AC-3. launchd plist reboot survival.**

**Setup:** Install macprovider-cli with launchd plist. Verify service
is running (`launchctl list | grep macprovider`).

**Action:** `sudo reboot` (or `launchctl bootout` + `launchctl
bootstrap` to simulate).

**Expected:**
1. After reboot, `macprovider-cli serve` is running automatically.
2. Provider reconnects to coordinator (visible in `/poolz`).
3. `macprovider-cli status` shows healthy state.

**How to verify:** Manual test.

---

**AC-4. Installer self-test diagnostic output.**

**Setup:** A Mac with `macprovider-cli` installed by `install.sh`, but
with the local self-test forced to fail after the binary binds its local
HTTP port. During testing, this can be done by temporarily changing the
model string expected by `wait_for_local_model` to a non-existent model
and reverting the edit after the check.

**Action:** Run
`curl -fsSL https://get.streamvc.live/install.sh | MACPROVIDER_PORT=18080 MACPROVIDER_NO_PROMPT=1 bash`.

**Expected:**
1. `install.sh` exits with code 6.
2. The failure log includes `Self-test timeout reached. THIS DOES NOT
   NECESSARILY MEAN THE BINARY FAILED.`
3. If `/v1/models` returned bytes, the log includes
   `Raw /v1/models response (first 200 bytes):` followed by the capped
   raw response.
4. If `/v1/models` returned nothing, the log includes the stderr log
   path and the last 200 bytes of stderr if the file is non-empty.
5. The normal green install path does not print the raw-response
   diagnostic.

**How to verify:** Manual curl-pipe-bash failure injection plus a normal
green install retest.

---

**AC-5. Upgrade-in-place installer hardening.**

**Setup/action:** Re-run `install.sh` on an existing v1.2.3+ install, then run a mixed-state directory simulation via `MACPROVIDER_INSTALL_DIR`.

**Expected:** Existing config port is reused; own `macprovider-cli` port holders are stopped while foreign holders still exit 6; launchd invokes the real binary path; warm-cache waits remain 5 minutes; cold-cache waits are 20 minutes with progress; mixed-state directories warn and continue.

**How to verify:** Manual upgrade on existing partner-shaped install plus local mixed-directory simulation.

---

## 10. Audit categories for SPEC-003+ revisions

**Audit category A: Shell-script paths that touch real OS resources
require integration tests, not code review.**

Any shell-script path in the installer or related tooling that touches a
real OS resource MUST have an integration test that actually exercises
the resource. "Real OS resource" includes but is not limited to:

- Controlling tty (`/dev/tty`, `read -p`, prompt redirection)
- File descriptor manipulation (`exec 4</dev/tty`, fd inheritance across
  subshells, `<&-`)
- Port binding (`lsof -iTCP`, `nc -l`, launchd `Sockets`)
- Filesystem layout assumptions (binary-adjacent resource loading,
  bundle co-location, symlink behavior under `cp -L` / `tar -h`)
- JSON parsing over loopback (RFC 8259 escape choices that vary by
  producer)
- Pipe-environment semantics (`A=1 cmd1 | cmd2` environment scoping)
- macOS-specific behavior (`com.apple.quarantine`, launchd plist
  bootstrap, codesign verification)

Audit findings that say "this line looks correct" without an
accompanying integration-test step MUST be downgraded to "needs
integration test" rather than "approved." Reference: Decision log Entry
20 Bugs A/B/C/D, all four of which were independently code-review-clean
and all four of which broke on first stranger-shaped execution.

This category inherits and reinforces the v0.5 rule that shell-script
paths touching real OS resources need integration tests, not code
review. v0.7 specifically adds: **upgrade-in-place paths exercise
different OS-resource interactions than fresh installs and require
their own integration testing.**

---

## 11. Open questions

**OQ-1. Code signing strategy.** _RESOLVED 2026-06-25 (PR #62, #148, #149) — Apple Developer ID enrollment landed and the release pipeline now ships Developer-ID-signed + notarized + stapled `.pkg` assets alongside the compatibility tarball. v1.6.1 (2026-06-25) is the first release with the stapled `.pkg`. macOS 26.3.1 launchd AMFI rejection of adhoc-signed binaries is unblocked. The "Phase 6+" deferral below is superseded._
Apple Developer ID signing ($99/yr) vs `xattr -d com.apple.quarantine`
workaround. SPEC-001 NFR-6 says "signed with Developer ID, not
notarized." For `install.sh` strangers, the xattr workaround is
acceptable in v1 (the script runs `xattr -d` after extraction).
Long-term, notarization is needed for a true "double-click to install"
experience.

**Current position:** v1.2 ships unsigned. `install.sh` runs
`xattr -d com.apple.quarantine` on the extracted binary. Document this
in the README with a note: "macOS may warn about an unidentified
developer. This is expected for the current release." Apple Developer
ID signing is a Phase 6+ concern.

**Note:** The remaining 6 OQs from SPEC-003 v0.1 have been
redistributed to the specs that own the questions:
- OQ-1 (WS frame size) → SPEC-001 v1.2.1 OQ-4
- OQ-2 (WS write buffer) → split: provider-side → SPEC-001 v1.2.1
  OQ-5; coordinator-side → SPEC-002 v1.1.2 OQ-10. The split reflects
  different tuning constraints for the two buffers.
- OQ-3 (tier visibility to buyers) → SPEC-002 v1.1.2 OQ-6
- OQ-4 (version enforcement) → SPEC-002 v1.1.2 OQ-7
- OQ-6 (promotion persistence) → SPEC-002 v1.1.2 OQ-8
- OQ-7 (provisional identity) → SPEC-002 v1.1.2 OQ-9

---

## 12. Build steps

SPEC-003 v0.2 implementation is split across three build prompts,
corresponding to the three spec updates that ship together:

| Build prompt | Spec | Scope |
|---|---|---|
| `BUILD_SPEC_001_V1_2_PROMPT.md` | SPEC-001 v1.2.1 | phase3-binary v1.2: WS inference handlers, hello endpoint_url, new subcommands (update, status, uninstall, self-test), log rotation |
| `BUILD_SPEC_002_V1_1_PROMPT.md` | SPEC-002 v1.1.2 | coordinator v0.2: WS-tunneled relay, admission tiers, provisional rate limits, new admin endpoints, tier-weighted routing, case-insensitive model match |
| `BUILD_SPEC_003_V0_2_PROMPT.md` | SPEC-003 v0.2 | install.sh, get.streamvc.live hosting, GitHub Releases automation |

These build prompts are authored separately by the operator after the
audit cycle completes.

---

## Appendix A — References

| Source | What was taken |
|---|---|
| `specs/SPEC-001-phase3-binary.md` v1.2.1 | Wire protocol (§ 6.5-6.6), FR-20 self-test, FR-13 reconnect backoff |
| `specs/SPEC-002-coordinator.md` v1.1.1 | Admission tiers (§ 7.5), hello_ack tier field, routing weight |
| `specs/SPEC-003-open-onboarding.md` v0.1 | Source for all Part C and Part D content (redistributed) |
| `beta/DECISION_CRITERIA.md` | Decision log Entry 18 (rationale for SPEC-003) |
| `HANDOFF.md` | Project context, roadmap, VPS details |
| OpenAI API reference | SSE streaming format referenced in integration narrative |

**Clean-room note:** No d-inference source files were read during spec
writing. Distribution and lifecycle design follows standard macOS CLI
patterns (Homebrew, Tailscale CLI, Fly.io CLI).
