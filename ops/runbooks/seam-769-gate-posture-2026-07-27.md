# Seam #769 — Live gate posture, spec reconciliation, and sticky-routing risk acceptance (2026-07-27)

Epic #770, issue #769 (P2, hygiene). Everything below was verified against the
**live** Pearl coordinator on 2026-07-27 — against the RUNNING process, whose
cmdline is `--config /opt/macprovider/coordinator.yaml --config-overlay
/etc/macprovider/coordinator.pearl-overlays.yaml` (per `ps`; overlay keys
override base). Note two stale path citations in older runbooks: the
production-exception-register greps `/etc/macprovider/coordinator.yaml`, which
does not exist — base config is under `/opt/macprovider/`, and the overlay is
the file that carries the gate posture (last modified 2026-07-22).

## 1. Verified live posture

| Control | Committed `dist/coordinator.yaml` | Live Pearl config | Effective |
|---|---|---|---|
| `proof_of_weights.require_autotune_hello_gate` | absent | **explicit `false` in the overlay** (was `true` at the spec's 2026-07-11 baseline) | **OFF** |
| `proof_of_weights.telemetry_drift.enabled` | absent | **explicit `true` in the overlay** | **ON (observe)** — so the #764/#765 `missing_benchmark` observe alerts fire live; `quarantine_missing_benchmark` absent → #765 quarantine stays dormant |
| `pool.canary_enabled` | absent | **explicit `false` in the overlay**; canary-buyer timer `inactive`, enable-gate absent, `DISABLED` sentinel present | **OFF** |
| `pool.warmup_gate_enabled` | `true` ("STAGE 2: gate ON") | **`false`** (same stale comment) | OFF — **drift, see §3** |
| `routing.sticky_enabled` | `true` | `true` | **ON — see §4** |
| `provider_http.timeout_s` | 300 | 300 | (the #760 twin-wall follow-up input) |

## 2. Spec reconciliation (done in this PR)

SPEC-032 v0.1 claimed `require_autotune_hello_gate: true` "in the Pearl
production overlay" in five places (§1 prose, numbering note, FR-HG1, config
table, production-posture section). All corrected in v0.2-draft: the claim was
accurate at the spec's 2026-07-11 baseline and the overlay was deliberately
flipped to `false` by its 2026-07-22 revision — the gate is OFF in prod. The intended
production posture remains ON, but flipping it requires a live-pool hardware-
evidence survey first (the same precondition documented for the #765 benchmark
quarantine in `audits/seam-hardening/findings.md`) — an unsurveyed enable
could fence the current fleet, repeating the 2026-07-10 single-provider
incident shape.

The canary-off posture is the known, accepted P0 #584 exception (continuous
canary disabled pending lab-Mac capacity); SPEC-032's incident references
should be read with that posture in mind. Not a new decision — recorded here
because #769 asked for proof of the canary state, and the proof came back
"off".

## 3. Warmup-gate drift (surfaced, deliberately NOT auto-fixed)

Committed `phase4-coordinator/dist/coordinator.yaml:44` says
`warmup_gate_enabled: true  # STAGE 2: gate ON (live test)`. The live file
says `false` with the same comment — someone flipped the live value without
updating the comment or back-porting to the committed template. Consequence:
**the next deploy that syncs the committed template would silently flip the
warmup gate ON in prod.**

This runbook surfaces the drift; it does not resolve it, because the intent is
unknowable from the config alone (was the STAGE 2 live test concluded-and-
reverted, or is the live `false` the accident?). Resolution belongs to the
operator with the STAGE 2 context. Options: (a) conclude the live test and set
the committed template to `false` with a dated comment, or (b) restore `true`
live via the normal deploy path. Until resolved, treat
`ALLOW_CONFIG_DRIFT`-style deploys of this file as unsafe. (Same drift class
as the 2026-07-02 sticky_enabled strip recorded in the committed file's own
comments — this file has a history of live/committed divergence.)

## 4. Sticky-routing same-account timing side-channel — RISK ACCEPTED

`routing.sticky_enabled: true` is live, so the residual side-channel #769
names is a present-tense property of production, and this section is the
risk-acceptance note the issue requires.

**The channel:** sticky conversation affinity (`X-MacProvider-Conversation`,
PR #302) routes a conversation's requests to the provider already holding its
KV/context. Within ONE account, a request that reuses another conversation's
tag (or a prefix-cached prompt) can observe a TTFT difference — warm vs cold —
and infer whether "that" conversation recently ran. Cross-account exposure is
not in scope of this note: conversation tags are fingerprint-keyed per account
at the gateway (#762) and sticky keys are account-scoped; cross-tenant
isolation rests on the gateway boundary as documented in the seam audit
(`audits/seam-hardening/findings.md`), with the provider's direct HTTP port
required to stay off-tenant.

**Why accepted:** (1) the observer must already be inside the account — the
same principal that could simply read its own conversation history; (2) the
signal is one bit (warm/cold) degraded by pool churn, canary-less routing
variance, and the 1800s sticky TTL; (3) disabling sticky costs real TTFT for
every multi-turn buyer, which is the metric OpenRouter ranks on. The trade is
accepted for the current single-digit-provider beta fleet.

**Revisit triggers:** enabling any sub-account/team feature where principals
within one account have distinct privacy expectations; enrolling traffic
where a marketplace (OpenRouter) multiplexes MANY end-users through one
account credential — that collapses "same account" into "same marketplace",
and this acceptance MUST be re-evaluated before enrollment; or exposing the
provider HTTP port to tenants (breaks the isolation predicate above).

## 5. Follow-ups (owned elsewhere, listed for traceability)

- Coordinator twin-wall raise + C2/C2b deploy-gate retarget (P0-adjacent
  follow-up from #760; `provider_http.timeout_s: 300` confirmed live above).
- Hello-gate enable-after-survey and #765 quarantine enable-after-survey share
  one prerequisite: a live-pool hardware-evidence/benchmark survey.
- Warmup-gate drift resolution (§3) — operator decision.
