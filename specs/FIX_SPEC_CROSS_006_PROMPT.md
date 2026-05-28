# Cross-spec fix prompt — SPEC-006 v0.3 + SPEC-002 v1.1.4 + SPEC-003 v0.6

Operator-paste prompt to apply the cross-spec coherence audit findings
in a single coordinated FIX session. Three specs bump in lockstep:

  SPEC-006 v0.2 → v0.3 (5 MAJOR + 3 MINOR)
  SPEC-002 v1.1.3 → v1.1.4 (2 MAJOR + 3 MINOR)
  SPEC-003 v0.5 → v0.6 (1 MAJOR + 1 MINOR)

Audit report: `specs/SPEC-CROSS-006-audit.md`. Both rounds verdict
READY WITH NARROW PATCHES. 0 CRITICAL — corpus is architecturally
coherent.

This prompt also addresses the three narrow SPEC-006 v0.2 regression
findings (from `specs/SPEC-006-v0-2-audit.md`) since SPEC-006 is
bumping anyway. Total SPEC-006 v0.3 scope: 5 cross-spec MAJORs + 3
cross-spec MINORs + 3 regression-audit AC fixes.

A fourth spec patch is queued but DEFERRED to a separate cycle:

  SPEC-001 v1.2.3 candidate — provider MUST include actual usage
  tokens in cancellation response (would let gateway debit exact
  partial usage instead of estimating). NOT in this fix pass; file
  as candidate. Operator decision D-CROSS-1 below locks gateway
  estimation for v0.3.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~2-3 hours
(multi-spec coordinated patch; bounded by careful version-line
synchronization, not by per-spec edit volume).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying the cross-spec coherence audit findings to three
specs in a single coordinated FIX pass. The audit report is at
specs/SPEC-CROSS-006-audit.md. Both rounds (Codex round 1 + Claude
round 2) agreed on the verdict (READY WITH NARROW PATCHES) and
identified specific patches per spec.

You will edit FIVE files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md  v0.2 → v0.3
  /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md  v1.1.3 → v1.1.4
  /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md  v0.5 → v0.6
  /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html
    (append "Resolved in v1.1.4 cross-spec" section)
  /Users/augstar/macprovider-poc/phase5-gateway/implementation-notes.html
    (append "Resolved in v0.3 cross-spec" section)

SPEC-001 v1.2.2 is NOT edited in this pass. The disconnect-usage
normative requirement is filed as SPEC-001 v1.2.3 candidate (D-CROSS-1
below), executed in a separate cycle.

## Critical constraints

**1. Three specs bump in lockstep.** SPEC-006 v0.3, SPEC-002 v1.1.4,
SPEC-003 v0.6 are released as a coordinated set. Each spec's
"Depends on:" line must reflect the new versions of the others.
Change-log entries in each must reference the cross-spec audit
report.

**2. SPEC-001 v1.2.2 unchanged.** The disconnect-usage finding M2/M2.2
is resolved via gateway-side estimation in SPEC-006 v0.3 (D-CROSS-1).
Do NOT edit SPEC-001 in this pass.

**3. Locked design choices remain locked.** SPEC-006 § 2 operator
pre-commitments (gateway architecture, $500 cap, 100K quota, GitHub
OAuth primary, B+C feedback, no premium positioning, no Tier-3
deprecation) are read-only.

**4. Buyer API stability.** OpenAI SDK drop-in compatibility MUST be
preserved. Any normative change that breaks SDK behavior = STOP.

**5. d-inference clean-room.** Do not inspect d-inference source.

**6. Backward-compat for M4 / M1.** Legacy provider binaries
(v1.1.3 / v1.1.4) MUST continue to work end-to-end through the
patched specs.

## Operator decisions for this cross-spec FIX (pre-locked)

The audit surfaced two QUESTIONS and several finding-resolution
choices. The operator has pre-decided:

### D-CROSS-1 (resolves M2/M2.2 disconnect settlement)

**Lock:** For streaming requests where the buyer disconnects
mid-stream, the gateway estimates completion tokens using:

> `estimated_completion_tokens = ceil(bytes_emitted_so_far / 4)`

Where `bytes_emitted_so_far` counts the SSE chunk bytes (excluding
framing) sent to the buyer up to disconnect. The 4-bytes-per-token
constant is documented as a coarse approximation for English-leaning
content; mismatch with actual provider token counts is bounded to ~5
tokens for typical short generations.

This estimation is documented as gateway behavior in SPEC-006 v0.3
§ 7.2 and § 17.5. The provider-side normative requirement (provider
MUST include actual usage in cancellation response) is filed as
SPEC-001 v1.2.3 candidate, to be addressed in a separate cycle. Once
that lands, SPEC-006 v0.4 can replace estimation with provider-reported
actuals.

Rationale: shipping estimation now unblocks SPEC-006 implementation
without waiting for an SPEC-001 + provider-binary release cycle.
Estimation error on disconnects is small enough not to affect quota
fairness materially.

### D-CROSS-2 (resolves M1, M2.6, Q1: /v1/pool/check ownership)

**Lock:** `/v1/pool/check` is a coordinator-owned operator/health-check
surface. It stays publicly exposed at coordinator.streamvc.live
(nginx routes /v1/pool/check to coordinator, NOT to gateway).
SPEC-002 v1.1.4 normatively defines /v1/pool/check as part of its
operator surface (NOT buyer surface). SPEC-003 v0.6 installer
continues to use /v1/pool/check unchanged.

The split: gateway intercepts /v1/chat/completions, /v1/models,
/v1/usage, /v1/feedback, /v1/status. Coordinator continues to serve
/v1/pool/check, /healthz, /poolz, /admin/*, /ws/provider.

nginx routing block in SPEC-002 v1.1.4 § 7 explicitly documents this
split.

### D-CROSS-3 (resolves M3/M2.3 correlation contract)

**Lock:** Cross-service correlation uses an `X-Request-ID` header
containing a UUID v4 (8-4-4-4-12 hex format). Generation rules:

- Gateway generates the UUID per buyer-incoming request and uses it
  as the row key in usage_events and audit_events.
- Gateway includes `X-Request-ID: <uuid>` as a request header when
  forwarding to coordinator.
- Coordinator MUST honor the gateway-provided X-Request-ID and
  include it in its request_log row. If absent (legacy direct-tunnel
  buyer path), coordinator MAY generate its own.
- Provider MAY echo X-Request-ID back in usage reporting (OPTIONAL
  for v0.3; will become MUST in SPEC-001 v1.2.3 candidate).
- All log surfaces (gateway usage_events, gateway audit_events,
  coordinator request_log) MUST include the X-Request-ID for any
  request that flowed through gateway.

This makes the chain greppable: one buyer request → one X-Request-ID
visible at every layer.

### D-CROSS-4 (resolves M2.4 degraded definition)

**Lock:** Per-model `degraded` boolean is defined normatively in
SPEC-002 v1.1.4 § 7.5 (the /v1/models extension fields):

> A model is `degraded: true` if ANY of:
> - All providers for this model are state `unavailable` or `draining`
> - Fewer than 50% of registered providers for this model are
>   `ready`
> - All providers' `slots_free` for this model equal 0
> Otherwise `degraded: false`.

SPEC-006 v0.3 § 5.6 / § 12.2 references the SPEC-002 v1.1.4
definition; gateway computes degraded from /poolz data using the
same rules.

### D-CROSS-5 (resolves M4 / Q2.2: capacity tier independence)

**Lock:** SPEC-006 v0.3 § 10 adds a normative paragraph:

> SPEC-006 gateway capacity-burst tiers (Tier 0/1/2/3) are
> INDEPENDENT from SPEC-002 coordinator admission tiers (pinned,
> provisional). The two tier systems control different surfaces:
> SPEC-006 capacity tiers control buyer-side admission (signups,
> quotas, kill switches) at the gateway; SPEC-002 admission tiers
> control provider-side admission at the coordinator. There is no
> cascade between the two. A SPEC-006 Tier 3 hard-pause does NOT
> affect SPEC-002 admission. A SPEC-002 provider exhaustion does
> NOT trigger SPEC-006 Tier escalation directly; SPEC-006 observes
> provider-availability signals (via /poolz) and may escalate based
> on its own thresholds.

### D-CROSS-6 (resolves M5: logprobs cross-spec coverage)

**Lock:** SPEC-006 v0.3 § 5.4 logprobs field gets a clarifying note:

> The `logprobs` field is forwarded to the provider as part of the
> request body. SPEC-001 v1.2.2 § 6.4 specifies unknown-field
> tolerance — the provider MAY ignore unknown OpenAI-compatible
> fields including logprobs. Behavior is therefore provider-binary-
> implementation-dependent. The gateway does NOT enforce any
> logprobs-specific semantics. Document this in SPEC-006 v0.3 docs
> as "model-dependent."

SPEC-001 and SPEC-002 are NOT edited to add logprobs to their field
tables; the unknown-field tolerance is the existing normative
backstop.

## Required reading

1. `specs/SPEC-CROSS-006-audit.md` — both rounds. Every finding's
   suggested fix is your starting text.

2. `specs/SPEC-006-buyer-api.md` v0.2 (current state).

3. `specs/SPEC-002-coordinator.md` v1.1.3 (current state).

4. `specs/SPEC-003-open-onboarding.md` v0.5 (current state).

5. `specs/SPEC-006-v0-2-audit.md` — the regression audit's three
   narrow AC text findings. Since SPEC-006 is bumping anyway, fold
   these in:
   - AC-26 method mismatch (POST → GET /auth/github/callback)
   - AC-27 revocation latency test (65s retry on 60s bound — the
     test must prove the bound, not just retry)
   - AC-26..AC-37 missing consistent status codes and response
     body shapes — strengthen each AC

6. `phase4-coordinator/internal/buyer/server.go` — verify the
   actual response headers coordinator sets, so SPEC-006 v0.3 §
   5.4 / § 8.3 explicit response-strip list is correct (M2.1).

7. `phase4-coordinator/internal/poolz/` (or equivalent) — confirm
   /poolz shape vs M2.4 + m2.4 (per-state counts).

## Findings to fix — by spec

### SPEC-006 v0.2 → v0.3 (5 MAJOR + 3 MINOR + 3 regression AC fixes)

**Patches needed:**

**F-606-1** (M2.1) — Response header explicit strip list.

Location: § 5.4 / § 8.3 (header strip lists).

Fix: Add the following coordinator response headers to the gateway's
explicit strip list:

- `X-MacProvider-Provider` (per-response, set by coordinator)
- `X-MacProvider-Route` (per-response, set by coordinator)
- Any `X-MacProvider-*` header NOT on a documented response-pass-
  through allowlist

The gateway MUST strip these BEFORE returning the response to the
buyer. Update § 5.4 (chat completions response handling) and § 8.3
(provider transparency invariants) to list both headers explicitly.
This complements the existing F-M21 inbound-strip rule. AC-34 (header
strip) MUST exercise BOTH inbound and outbound directions.

**F-606-2** (M2.2 / M2 / D-CROSS-1) — Streaming disconnect settlement.

Location: § 7.2 (quota), § 17.5 (failure modes), refund matrix.

Fix: Replace the "actual completion tokens at disconnect" clause
with:

> On client disconnect mid-stream, the gateway estimates completion
> tokens using `ceil(bytes_emitted_so_far / 4)` and settles the
> reservation accordingly. This is gateway-side estimation; a
> normative SPEC-001 v1.2.3 candidate would have the provider include
> actual usage in cancellation response, replacing estimation with
> the reported value.

Update the refund matrix (F-M15 from v0.2) to mark the Client
disconnect row as "estimated" rather than "actual." Add a note that
this is a known small inaccuracy bounded by the estimation method.

**F-606-3** (M2.4 / D-CROSS-4) — degraded boolean cross-reference.

Location: § 5.6 (status endpoint), § 12.2 (front-door contract).

Fix: Add cross-reference: "Per-model `degraded` boolean is defined
normatively in SPEC-002 v1.1.4 § 7.5. The gateway computes degraded
from /poolz aggregation using the SPEC-002 v1.1.4 rules: any model
where all providers are unavailable/draining, where fewer than 50%
are ready, or where all slots_free = 0."

**F-606-4** (M2.5) — gateway.yaml /poolz access config.

Location: § 15 (configuration).

Fix: Add to the gateway.yaml schema documentation:

```yaml
coordinator:
  # Buyer-facing URL — typically 127.0.0.1:8443 in single-host deploys
  buyer_url: "http://127.0.0.1:8443"
  # Provider/operator port — for /poolz, /healthz, /admin/* consumption
  operator_url: "http://127.0.0.1:8444"
  # Operator key for /poolz authentication
  operator_key: "${COORDINATOR_OPERATOR_KEY}"  # from env, not stored in yaml
  # /poolz polling cadence (default 10s)
  poolz_poll_interval_s: 10
```

The gateway MUST authenticate /poolz requests with the operator key.
Add a startup-validation rule: if `coordinator.operator_url` or
`coordinator.operator_key` is missing, gateway startup fails with
explicit error.

**F-606-5** (M2.7) — 502 error terminology normalization.

Location: § 17 (failure modes).

Fix: The current spec uses inconsistent terminology for HTTP 502
("upstream failure" vs "provider error"). Normalize to: 502 means
"upstream coordinator returned an error from selected provider; the
gateway forwards an OpenAI-shaped error envelope with
`type: api_error, code: upstream_provider_error`." Cross-reference
to SPEC-002 v1.1.4's matching close-code semantics for consistency.

**F-606-6** (m2 / MINOR) — SPEC-003 audit category inheritance.

Location: § 19 (audit categories).

Fix: Add to SPEC-006 v0.3's audit category list, alongside the
"always-non-nil gate" inherited from SPEC-002:

> Inherits SPEC-003 v0.6's audit category: shell-script paths that
> touch real OS resources (tty, fd, port, FS layout, JSON over
> loopback) need integration tests that actually exercise them, not
> code review alone. Applies to gateway operational scripts
> (deployment, backup, kill-switch toggling via shell).

**F-606-7** (m3 / MINOR) — Upstream-modification governance.

Location: § 1.5 (relationship to other specs).

Fix: Clarify the "do not modify upstream specs" rule:

> SPEC-006 normatively cannot mutate SPEC-001 or SPEC-002 during
> per-spec FIX cycles. However, cross-spec audit cycles (per
> AUDIT_SPEC_CROSS_006_PROMPT.md pattern) MAY propose coordinated
> patches across multiple specs. When such cross-spec patches land,
> all affected specs bump versions in lockstep. The cross-spec FIX
> prompt is the governance vehicle, not unilateral SPEC-006 edits.

**F-606-8** (m2.5 / MINOR) — Status endpoint cache staleness.

Location: § 5.6.

Fix: Add: "Status endpoint caches /poolz data with TTL of 10s.
During coordinator restart, the cache MAY serve stale data for up
to 10s after coordinator returns. The cache MUST flush on
coordinator-not-reachable detection (HTTP error from /poolz)."

**Regression AC fixes (from SPEC-006 v0.2 regression audit):**

**F-606-9** — AC-26 method mismatch.

Location: § 18, AC-26.

Fix: Change "POST /auth/github/callback" to "GET /auth/github/callback"
to match the spec's actual endpoint definition.

**F-606-10** — AC-27 revocation latency test.

Location: § 18, AC-27.

Fix: Change "retries at 65 seconds" to: "Verifies the 60-second
bound by polling validation every 5 seconds starting at T+0; the
first 401 response MUST arrive by T+60s. A 401 at T+65s does NOT
prove the bound."

**F-606-11** — AC-26..AC-37 status codes and response body shapes.

Location: § 18, all new ACs.

Fix: For each of AC-26 through AC-37, ensure the AC includes:
- Explicit HTTP status code expected (200/201/400/401/403/404/429/etc.)
- Response body shape (OpenAI envelope or specific JSON schema)
- Verification command (curl -i with assertion against status + body)

This is one pass through the AC list, tightening each item.

### SPEC-002 v1.1.3 → v1.1.4 (2 MAJOR + 3 MINOR)

**F-602-1** (M3 / M2.3 / D-CROSS-3) — Request ID correlation.

Location: § 7.2 (request handling), § 7.5 (admin endpoints), § 10
(audit log).

Fix: Add normative paragraph in § 7.2:

> Coordinator MUST honor any inbound `X-Request-ID` header on
> buyer-facing requests (`/v1/*`) and include it in the request_log
> row. If absent, coordinator MAY generate its own UUID v4. The
> request_log schema gains a `request_id` column (or equivalent
> indexed field). The X-Request-ID is forwarded to the provider as
> part of the inference_request WS message in SPEC-001 § 6.6; the
> provider MAY echo it back in usage reporting (SPEC-001 v1.2.3
> candidate; OPTIONAL in current SPEC-001 v1.2.2).

Add audit category mention: "Cross-service correlation requires
that any service in the request path that does not propagate
X-Request-ID degrades cross-layer debuggability. New surfaces MUST
include X-Request-ID propagation."

**F-602-2** (M2.6 / D-CROSS-2) — /v1/pool/check normative ownership.

Location: § 7.5 (operator endpoints) — add normative subsection
for /v1/pool/check.

Fix: Add:

> ### § 7.5.X /v1/pool/check (provider registration verification)
>
> **Method:** GET
>
> **Path:** /v1/pool/check?provider_id=<provider_id>
>
> **Auth:** none (publicly accessible operator/health surface)
>
> **Response (200 OK):**
> ```json
> {
>   "provider_id": "<id>",
>   "tier": "pinned" | "provisional",
>   "state": "ready" | "draining" | "unavailable" | "unknown"
> }
> ```
>
> **Purpose:** Used by SPEC-003 install.sh self-test to confirm a
> freshly-installed provider has registered with the coordinator
> after first WS connect. Also useful as a generic
> provider-registered health check.
>
> This endpoint is OPERATOR/HEALTH surface, NOT buyer surface. It
> stays publicly accessible at coordinator.streamvc.live (nginx
> routes /v1/pool/check to coordinator directly, NOT to gateway).
> SPEC-006 v0.3 gateway does NOT intercept this path.

Add nginx routing example block:

```nginx
# api.streamvc.live → gateway (buyer surface)
location /v1/chat/completions { proxy_pass http://127.0.0.1:9443; }
location /v1/models { proxy_pass http://127.0.0.1:9443; }
location /v1/usage { proxy_pass http://127.0.0.1:9443; }
location /v1/feedback { proxy_pass http://127.0.0.1:9443; }
location /v1/status { proxy_pass http://127.0.0.1:9443; }

# coordinator.streamvc.live → coordinator (operator + legacy buyer surface)
location /v1/pool/check { proxy_pass http://127.0.0.1:8443; }
location /healthz { proxy_pass http://127.0.0.1:8443; }
location /poolz { proxy_pass http://127.0.0.1:8444; }
location /admin/ { proxy_pass http://127.0.0.1:8444; }
location /ws/provider { proxy_pass http://127.0.0.1:8444; }
```

**F-602-3** (D-CROSS-4 / M2.4) — degraded boolean normative definition.

Location: § 7.5 /v1/models extension fields.

Fix: Add normative definition (as per D-CROSS-4 lock above).

**F-602-4** (m1 / m2.1 / MINOR) — Dependency line update.

Location: line 4 header.

Fix: Change "Depends on: SPEC-001 v1.2.1" to "Depends on: SPEC-001
v1.2.2".

**F-602-5** (m2.4 / MINOR) — /poolz summary per-state counts.

Location: § 7.5 /poolz response schema.

Fix: Add to the documented /poolz response shape:

```json
{
  "summary": {
    "total_providers": int,
    "ready": int,
    "draining": int,
    "unavailable": int,
    "by_model": {
      "<model_id>": {
        "providers": int,
        "ready": int,
        "slots_free_total": int,
        "slots_total": int
      }
    }
  },
  "providers": [...]  // detailed array, operator-only
}
```

The `summary` block is what SPEC-006 v0.3 gateway consumes for
/v1/status. The detailed `providers` array stays operator-only.

**F-602-6** (m2.6 / MINOR) — Buyer port rebind documentation.

Location: § 7 deployment notes.

Fix: Add: "When deployed alongside SPEC-006 gateway, coordinator's
buyer port (8443) MUST be rebound from 0.0.0.0 to 127.0.0.1.
Public TLS termination happens at nginx/gateway. The provider port
(8444) MAY remain 0.0.0.0 if coordinator.streamvc.live serves
/admin/*, /poolz, /healthz directly."

### SPEC-003 v0.5 → v0.6 (1 MAJOR + 1 MINOR)

**F-603-1** (M1 / D-CROSS-2) — Installer visibility contract.

Location: § 5 (onboarding UX, self-test step).

Fix: Update the install.sh self-test documentation to reference
SPEC-002 v1.1.4 § 7.5.X normative /v1/pool/check definition.
Concretely:

> The installer's self-test calls
> `https://coordinator.streamvc.live/v1/pool/check?provider_id=<sanitized>`
> after WS connect. This is the canonical post-SPEC-006-deployment
> verification path: /v1/pool/check stays on coordinator's operator
> surface, NOT behind the gateway. The installer MUST NOT attempt to
> reach this endpoint via api.streamvc.live (the gateway does not
> proxy /v1/pool/check).

No change to install.sh code; this is a spec text clarification.

**F-603-2** (m1 / m2.2 / MINOR) — Dependency line update.

Location: line 4 header.

Fix: Change "Depends on: SPEC-001 v1.2.1, SPEC-002 v1.1.2" to
"Depends on: SPEC-001 v1.2.2, SPEC-002 v1.1.4".

## Output requirements

1. SPEC-006 updated in place. Version 0.2 → 0.3. Change log entry
   covers F-606-* fixes + the three regression AC fixes. Header
   "Depends on" line updated to SPEC-002 v1.1.4, SPEC-003 v0.6.

2. SPEC-002 updated in place. Version 1.1.3 → 1.1.4. Change log
   entry covers F-602-* fixes. Header "Depends on" line updated to
   SPEC-001 v1.2.2.

3. SPEC-003 updated in place. Version 0.5 → 0.6. Change log entry
   covers F-603-* fixes. Header "Depends on" line updated to
   SPEC-001 v1.2.2, SPEC-002 v1.1.4.

4. `phase4-coordinator/implementation-notes.html` gains "Resolved in
   v1.1.4 cross-spec" section.

5. `phase5-gateway/implementation-notes.html` gains "Resolved in
   v0.3 cross-spec" section.

6. SPEC-006 § 18 AC list strengthened per F-606-11 (every AC has
   explicit status code + response body shape + verification command).

## Self-verification checklist

- [ ] All three specs bumped in lockstep at top of file.
- [ ] All three specs' "Depends on" lines reflect each other's new
      versions.
- [ ] Every F-606-*, F-602-*, F-603-* finding has visible resolution
      text in the corresponding spec.
- [ ] D-CROSS-1 through D-CROSS-6 are encoded in the corresponding
      spec sections, not just in the prompt's lock paragraphs.
- [ ] AC-26 through AC-37 all have status code + response body shape
      + executable verification command.
- [ ] AC-26 says GET, not POST.
- [ ] AC-27 proves the 60s bound (poll every 5s; first 401 by T+60s),
      not "retry at 65s".
- [ ] SPEC-001 v1.2.2 untouched.
- [ ] No new content beyond what closes audit findings, encodes
      D-CROSS-* decisions, or fixes the three regression AC items.
- [ ] No SPEC-006 § 2 changes (locked decisions read-only).
- [ ] No premium positioning, no Tier-3 deprecation introduced.
- [ ] nginx routing block in SPEC-002 v1.1.4 § 7 documents the
      gateway/coordinator path split.

If your edits exceed ~400 added lines across the three specs
combined (rough budget: 9 MAJORs × ~25 lines + 7 MINORs × ~10 +
regression AC tightening × ~15), STOP — that's scope creep. The
patches are surgical, not architectural.

When done, print a 250-word handback summary:
- Findings closed per spec (SPEC-006: N, SPEC-002: N, SPEC-003: N)
- D-CROSS-* decisions encoded
- Any finding deferred (with rationale)
- Whether all three specs are now READY TO LOCK at the new versions
- Filed candidate: SPEC-001 v1.2.3 — provider partial-usage normative
  requirement (for future fix cycle)

Then stop. Do NOT begin implementation. Operator decides whether to
run one more narrow audit on the cross-spec set or proceed directly
to BUILD_PHASE5.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~45 min):

1. Read change-log entries on all three specs. Verify they reference
   the cross-spec audit at `specs/SPEC-CROSS-006-audit.md`.
2. `git diff specs/SPEC-001-phase3-binary.md` should return empty
   (SPEC-001 untouched).
3. Verify D-CROSS-1 through D-CROSS-6 each have spec text encoding
   the decision (not just commit-message reference).
4. SPEC-002 § 7.5 has /v1/pool/check normative subsection with the
   D-CROSS-2 ownership rule + nginx routing block.
5. SPEC-006 § 5.4 / § 8.3 has explicit X-MacProvider-Provider,
   X-MacProvider-Route in both inbound (F-M21 from v0.2) and outbound
   (F-606-1 new) strip lists.
6. SPEC-006 § 15 gateway.yaml schema includes coordinator.operator_url,
   coordinator.operator_key.
7. AC list quality: pick 3 random ACs from AC-26..AC-37, verify each
   has status code + body shape + curl command.

Then commit. Suggested message:

```
SPEC-006 v0.3 + SPEC-002 v1.1.4 + SPEC-003 v0.6: cross-spec audit closing fixes

Closes 9 MAJOR + 7 MINOR cross-spec findings from
specs/SPEC-CROSS-006-audit.md (both rounds). Also folds in the three
narrow regression AC fixes from specs/SPEC-006-v0-2-audit.md since
SPEC-006 was bumping anyway.

Six operator decisions locked: D-CROSS-1 (gateway estimation for
streaming disconnect; SPEC-001 v1.2.3 candidate for normative
provider partial-usage), D-CROSS-2 (/v1/pool/check ownership on
coordinator), D-CROSS-3 (X-Request-ID UUID v4 propagation),
D-CROSS-4 (degraded boolean rules in SPEC-002), D-CROSS-5
(SPEC-006/SPEC-002 tier independence), D-CROSS-6 (logprobs forwarded
via unknown-field tolerance).

Three specs bump in lockstep. SPEC-001 v1.2.2 unchanged.

Verdict from both rounds: READY WITH NARROW PATCHES → now CORPUS
COHERENT after this fix pass.
```

After commit, decide:

- **Lock the corpus** at SPEC-001 v1.2.2 + SPEC-002 v1.1.4 + SPEC-003
  v0.6 + SPEC-006 v0.3. Proceed to `BUILD_PHASE5_PROMPT.md` for
  gateway implementation.
- **One regression audit** narrowly scoped to verify the cross-spec
  fix didn't introduce new drift. Codex single-round, ~30-45 min.
  Recommended given this is the corpus's largest coordinated patch.

After regression check clears: BUILD_PHASE5 unlocks the next 7-10
days of implementation work.

Filed for SPEC-001 v1.2.3 (future cycle):

> Provider MUST include actual completion-token usage in the
> response to cancel_request (per SPEC-001 § 6.6). Today's behavior
> is unspecified; SPEC-006 v0.3 estimates via byte-count division.
> Once landed, SPEC-006 v0.4 can replace estimation with actual.
