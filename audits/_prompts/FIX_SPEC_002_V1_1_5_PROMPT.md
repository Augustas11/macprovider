# Fix prompt — SPEC-002 v1.1.4 → v1.1.5 (public-pool production invariants)

Operator-paste prompt to close audit finding **H-002** from the
2026-05-29 independent security audit: provider WS authentication is
too weak for a broad public pool. The token validation has an
operator-toggleable bypass (`auth.require_provider_tokens` defaults
false), and there are no pre-WS-upgrade connection caps or
rate-limits at the proxy layer.

Spec-text-only patch. Two related findings (production-invariant
flag default + nginx pre-WS-upgrade controls). SPEC-002 v1.1.4 →
v1.1.5.

This is the Go-stream of the three-spec coordinated audit-response
cycle. Sibling prompts handle SPEC-001 v1.2.4 (concurrency) and
SPEC-006 v0.6 (Tier 1 disclosure). Each is independently runnable;
no cross-stream dependency at execution time.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~45-60 min.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are adding production-invariant normative requirements to
SPEC-002 so the current Tier 1 cooperative pool (M4, M1,
augustass-macbook-air) can transition to public-buyer launch
without leaving the WS provider-control plane exposed to
unauthenticated upgrades, Sybil flooding, or connection-pressure
attacks.

The independent audit (H-002) caught two specific weaknesses:

1. **Auth bypass:** `auth.require_provider_tokens` defaults to
   `false` in SPEC-002 v1.1.3 (deliberately, for the Tier 1
   cooperative trust pool with pinned providers identified by
   `provider_id` only). For PUBLIC pool, this allows anyone who
   knows a provider_id + WS URL to attempt connection.

2. **No pre-WS-upgrade controls:** The coordinator performs WS
   upgrade BEFORE provider token validation. Even if validation
   tightens, the WS upgrade itself is expensive. There's no
   normative requirement for proxy-level (nginx) rate-limiting or
   per-IP connection caps before the upgrade.

You will edit one file in place:
  /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md  v1.1.4 → v1.1.5

## Critical constraints

**1. Spec-text-only patch.** No Go code changes. Verify with
`git diff phase4-coordinator/` after edits — should be empty.

**2. Backward-compat for current Tier 1 pool.** The default
`auth.require_provider_tokens=false` MUST remain valid for the
current cooperative-trust deployment. The patch adds a NORMATIVE
GATE for the transition to public pool, not a breaking change to
v1.1.3 semantics.

**3. SPEC-001, SPEC-003, SPEC-006 untouched.** Verify with
`git diff specs/SPEC-001-phase3-binary.md
specs/SPEC-003-open-onboarding.md specs/SPEC-006-buyer-api.md`
after edits — should be empty.

**4. Surgical scope.** Two findings, ~5 narrow patches:
- Production-invariant table in § 7.1 (or new § 7.X)
- nginx routing block expanded with pre-WS-upgrade controls
- Audit category I gets a new entry for "default-permissive flag
  in production deployment"
- Brief mention in § 11 audit categories
- Dependency line refresh (none needed — no upstream change)

**5. d-inference clean-room.** Do not inspect d-inference source.

**6. Operational reality check.** The current Tier 1 pool (M4 +
M1 + augustass-macbook-air) does NOT need to flip
`require_provider_tokens=true` until BUILD_PHASE5 ships SPEC-006
publicly. The patch documents a gate, it doesn't mandate
immediate migration.

## Required reading

1. `specs/SPEC-002-coordinator.md` v1.1.4 — full document. Focus
   on:
   - § 7.1 (auth.require_provider_tokens semantics; the two-mode
     normative paragraph from v1.1.3)
   - § 7 nginx routing block (added in v1.1.4 for /v1/pool/check
     ownership)
   - § 11 audit categories (especially I "always-non-nil gate")

2. `phase4-coordinator/internal/ws/server.go` — the actual WS
   handler. Verify what the audit claims about
   "upgrade-before-auth" against the current code:
   - When does `gobwas.UpgradeHTTP` happen relative to token
     validation?
   - Is there any pre-upgrade rate-limit hook?

3. `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
   (or wherever the production nginx config lives) — see what's
   currently configured for `/ws/provider` path:
   - Is there a `limit_req_zone` declared?
   - Is there a `limit_conn_zone` declared?
   - Are they applied to `/ws/provider`?

4. The audit report excerpt (read carefully):

   > H-002: Public Provider Admission and WebSocket Authentication
   > Are Too Weak for an Open Pool
   >
   > The coordinator performs WebSocket upgrade before provider
   > token validation. Token validation may pass when no token
   > validator is configured or when no Authorization header is
   > present. Lack of pre-authentication connection caps is a
   > known provider-control-plane weakness for public WebSocket
   > admission surfaces.
   >
   > Recommendation: For any production or public beta deployment,
   > require provider tokens by default. Validate authentication
   > before expensive connection handling wherever possible,
   > enforce proxy-level rate limits before WebSocket upgrade,
   > cap connections per IP and provider ID, reject unknown
   > provider IDs aggressively, and alert on provisional admission
   > spikes. Treat `auth.require_provider_tokens=true` as a
   > production invariant.

## Findings to fix

### F-602-V5-1 — Document `auth.require_provider_tokens=true` as a public-launch production invariant.

**Location:** SPEC-002 v1.1.4 § 7.1 (auth mode normative paragraph
from v1.1.3) or a new sibling § 7.X "Production invariants."

**Problem:** The auth.require_provider_tokens flag defaults to
false for the Tier 1 cooperative-trust pool. That's correct for
Tier 1. But the spec doesn't normatively require flipping it true
before any public-buyer deployment. The production gate is
implicit, not enforced.

**Fix:** Add a normative gate section (new § 7.X or appended to
§ 7.1):

> **§ 7.X Production invariants (public-launch gate).**
>
> The following invariants MUST be true before the coordinator is
> exposed to public buyer traffic through any SPEC-006-style
> buyer-API gateway. They are documented here as normative gates,
> not as v1.1.5 mandatory defaults — operators may continue to run
> the Tier 1 cooperative-trust configuration for non-public
> deployments.
>
> **PG-1: Provider authentication MUST be required.**
> Before any public-buyer-facing service forwards requests to
> this coordinator, `auth.require_provider_tokens` MUST be set
> to `true` in `coordinator.yaml`. All pinned providers MUST
> have valid bearer tokens issued and registered in the token
> store. Provisional providers MAY continue without tokens (per
> the provisional admission tier), but pinned providers serving
> public traffic MUST be token-authenticated.
>
> **PG-2: Pre-WS-upgrade rate limits MUST be enforced at the
> proxy layer.** The nginx (or equivalent) reverse proxy in
> front of the coordinator MUST enforce:
>   - Per-IP connection rate limit (recommended: 10/min) on
>     `/ws/provider`
>   - Per-IP concurrent connection cap (recommended: 5)
>   - These limits MUST apply BEFORE the WebSocket upgrade
>     handshake reaches the coordinator process
>
> **PG-3: Provisional admission MUST be rate-limited.** The
> coordinator's existing `admission.provisional_admission_rate_per_hour`
> (per § 7.1 F-2.b) provides this; verify the production value is
> conservative (recommended: 10/hour).
>
> **PG-4: Unknown provider_id rejection MUST be aggressive.** When
> a hello includes an unknown provider_id AND
> `pinned_only=true` (production setting), the coordinator MUST
> close with WS code 4002 (unknown_provider_id) immediately, NOT
> fall through to provisional admission. The current code already
> does this; PG-4 documents it as a normative invariant.
>
> **PG-5: Provisional-admission spike alerting MUST be operator-
> facing.** The coordinator MUST emit operator-readable alerts
> (log line at WARN, optional webhook) when provisional admission
> rate exceeds 50% of `admission.provisional_admission_rate_per_hour`
> in any rolling 10-minute window. This is the canary signal for
> Sybil pressure.
>
> Each invariant has an associated AC. See § 9.

Add 5 acceptance criteria (AC-X1 through AC-X5, numbers per
SPEC-002's existing AC list, likely AC-15 onward):

- **AC-X1 (PG-1):** Deploy coordinator with
  `auth.require_provider_tokens=true`. Provider WS connection
  WITHOUT a valid token MUST receive WS close 4005 within 2s of
  upgrade. Verified by curl/wscat against /ws/provider.
- **AC-X2 (PG-2):** With proxy rate limits configured, sending
  >10 WS upgrade requests per minute from a single IP MUST result
  in HTTP 429 from proxy BEFORE the request reaches the coordinator
  process. Verified by load-testing tool.
- **AC-X3 (PG-3):** With `provisional_admission_rate_per_hour=10`,
  the 11th provisional admission within an hour MUST be rejected
  (current admission rate exceeds limit). Verified by mock-provider
  spam.
- **AC-X4 (PG-4):** With `pinned_only=true`, a hello with unknown
  provider_id MUST receive WS close 4002 within 2s. Provisional
  admission MUST NOT fire. Verified by mock-provider with unknown
  ID.
- **AC-X5 (PG-5):** When provisional admission rate exceeds 50%
  of configured limit, the coordinator MUST emit a WARN log line
  matching the audit's recommended format. Verified by log
  inspection.

### F-602-V5-2 — Expand the nginx routing block with pre-WS-upgrade controls.

**Location:** SPEC-002 v1.1.4 § 7's nginx routing block (added in
v1.1.4 for /v1/pool/check ownership).

**Problem:** The current nginx block documents path-split routing
but doesn't include rate-limit or connection-cap directives for
`/ws/provider`. PG-2 requires them.

**Fix:** Update the nginx routing block to include
`limit_req_zone` and `limit_conn_zone` declarations + their
application to `/ws/provider`:

```nginx
# Rate limit and connection cap for /ws/provider (PG-2).
limit_req_zone $binary_remote_addr zone=ws_provider_rate:10m rate=10r/m;
limit_conn_zone $binary_remote_addr zone=ws_provider_conn:10m;

# api.malibu.tech → gateway (buyer surface)
location /v1/chat/completions { proxy_pass http://127.0.0.1:9443; }
location /v1/models { proxy_pass http://127.0.0.1:9443; }
location /v1/usage { proxy_pass http://127.0.0.1:9443; }
location /v1/feedback { proxy_pass http://127.0.0.1:9443; }
location /v1/status { proxy_pass http://127.0.0.1:9443; }

# coordinator.malibu.tech → coordinator (operator + legacy buyer surface)
location /v1/pool/check { proxy_pass http://127.0.0.1:8443; }
location /healthz { proxy_pass http://127.0.0.1:8443; }
location /poolz { proxy_pass http://127.0.0.1:8444; }
location /admin/ { proxy_pass http://127.0.0.1:8444; }

# Provider WS — production invariants per § 7.X PG-1 + PG-2
location /ws/provider {
    limit_req zone=ws_provider_rate burst=5 nodelay;
    limit_conn ws_provider_conn 5;
    proxy_pass http://127.0.0.1:8444;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_read_timeout 86400;
}
```

Document the values as recommendations, not strict requirements
(operators with different threat models may tune). The KEY
property is that rate-limit + connection-cap MUST be applied at
the proxy layer before reaching the coordinator.

### Audit category addition

Add to § 11:

> **Audit category I.Y: "Default-permissive flag in production
> deployment."**
>
> Some configuration flags are correctly default-permissive for
> developer convenience or backward-compatibility but MUST be set
> to the restrictive value for any public production deployment.
> The flag's default is the development setting; production
> deployment of services exposing public interfaces MUST flip
> these flags as part of the deployment runbook.
>
> Reference example: `auth.require_provider_tokens` defaults
> `false` for the Tier 1 cooperative pool but is a production
> invariant `true` per § 7.X PG-1.
>
> Auditors of future specs MUST identify default-permissive flags
> that need production-invariant counterparts. If a flag's
> default differs from its production-correct value, the spec
> MUST document the production invariant explicitly (per § 7.X
> pattern in v1.1.5).

### Spec text catch-up

Add to SPEC-002 v1.1.5's change log:

> **v1.1.5 (2026-05-29, audit response, public-pool production
> invariants):** Adds normative production gates (§ 7.X PG-1
> through PG-5) for the transition from Tier 1 cooperative-trust
> deployment to public-buyer launch (H-002 from 2026-05-29
> independent security audit). nginx routing block expanded with
> pre-WS-upgrade rate-limit + connection-cap directives.
> Audit category I.Y added for "default-permissive flag in
> production deployment" anti-pattern. No code change required.
> Current Tier 1 deployment configuration remains valid; the
> patch documents the gate, not the migration timing.

Update "Depends on:" line — unchanged (no upstream spec
dependency changes).

## Verification gate

After the edits:

1. `git diff phase4-coordinator/` MUST be empty (code already
   correct; the patch is documentation).
2. `git diff specs/SPEC-001-phase3-binary.md
   specs/SPEC-003-open-onboarding.md specs/SPEC-006-buyer-api.md`
   MUST be empty.
3. § 7.X (or expanded § 7.1) contains PG-1 through PG-5.
4. AC list gains AC-X1 through AC-X5 with deterministic
   verification commands.
5. nginx routing block includes `limit_req_zone` and
   `limit_conn_zone` directives for `/ws/provider`.
6. § 11 audit category I.Y exists.

If your edits exceed ~250 added lines in SPEC-002, stop and
re-check scope.

When done, print a 200-word handback summary covering:
- F-602-V5-1 closure (PG-1..PG-5 + ACs)
- F-602-V5-2 closure (nginx config)
- Audit category I.Y addition
- Whether SPEC-002 v1.1.5 is READY TO LOCK
- Recommended operational follow-up: at SPEC-006 v0.6 public
  launch, the operator MUST execute PG-1 (issue provider tokens
  to all pinned providers; flip the flag; restart coord)

Then stop. The operator commits SPEC-002 v1.1.5 in coordination
with SPEC-001 v1.2.4 + SPEC-006 v0.6.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~15 min):

1. `git diff specs/SPEC-002-coordinator.md` — version bump, change
   log, § 7.X production invariants, expanded nginx block,
   audit category I.Y, AC additions.
2. `git diff phase4-coordinator/` — should be empty.
3. `git diff specs/SPEC-001-phase3-binary.md
   specs/SPEC-003-open-onboarding.md specs/SPEC-006-buyer-api.md`
   — should be empty.
4. Verify the PG-1 through PG-5 invariants are framed as
   "production gates," not as v1.1.5 mandatory migrations.

## Operational migration when SPEC-006 launches

When BUILD_PHASE5 ships and api.malibu.tech opens to the public,
PG-1 must be executed:

1. Generate bearer tokens for M4, M1, augustass-macbook-air
   (operator side).
2. Update `/opt/macprovider/coordinator.yaml` providers entries
   to include `bearer_token: "..."`.
3. Set `auth.require_provider_tokens: true`.
4. Coordinate with each provider partner: their config.yaml or
   env var needs `MACPROVIDER_BEARER_TOKEN=<their-token>`.
5. Restart coord; verify all three providers reconnect with valid
   tokens.

Plus the nginx config update from F-602-V5-2.

Estimated time: ~1-2 hours operator + ~5 min per partner.

The patch in this FIX prompt documents the gate; the migration
itself happens at SPEC-006 public-launch time. Worth scheduling
as a Day-2 task in BUILD_PHASE5 (Phase E deployment runbook).
