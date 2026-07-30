# Next-session prompt — Deep stress test (gateway + smart router)

This prompt is **self-contained and paste-able**. It assumes a fresh Claude
or Codex session at `/Users/augstar/macprovider-poc` with no memory of the
short 5-min stress test in DECISION_CRITERIA Entry 34.

Goal: convert the system from "passes a 5-min stress test" to "demonstrably
production-shaped" before exposing to paid public buyers. NOT a blocker for
developer-beta network sharing (that's already done), but a hard
prerequisite for taking money.

---

```
=== BEGIN PROMPT ===

You are running a deep-stress test on the macprovider gateway + smart router
deployed on Pearl VPS (159.223.165.194). Prior work landed in
DECISION_CRITERIA Entry 34 — read that entry first for context on the 5-min
stress test results that came before (gateway throughput ceilings,
routing-metadata cache effectiveness, account-concurrency limit discovery,
quota-burn-on-404 fix). This session goes deeper.

## Hard constraints (do NOT skip)

1. **DO NOT touch `augustass-macbook-air`** — the operator's local Mac was
   removed from the launchd rotation by deliberate decision. It is not in
   the pool today. If you see it in `/poolz`, STOP and surface to operator.
2. **DO NOT overload `air5` or `air8gb`** — these are hobby Macs with
   single inference slots. Sustained real-inference concurrency >1 will
   degrade them and ruin the user experience. Use synthetic load only.
3. **Use the established Augustas11 git-identity rule** before any push:
   `gh auth status` → switch to Augustas11 if active is antfleet-ops.
   Project CLAUDE.md is authoritative.
4. **All defaults SHOULD currently be**: D enabled (tiebreak_randomize:true,
   epsilon:0.05), C enabled (max_retries:1, max_providers_faulted:2), A
   enabled (sticky_enabled:true on both coord and gateway), B disabled
   (model_classes: {} — there's a pending alias-rewrite fix tracked as
   Task #8 from prior session; see DECISION_CRITERIA Entry 34 successor
   if it landed). Verify via `curl -H "Authorization: Bearer $OP_KEY"
   http://127.0.0.1:8444/internal/routing` on Pearl.

## Tooling available

- Pearl already has `wrk` and `apache2-utils` (ab) installed. Use `wrk` for
  HTTP load (loopback to gateway at 127.0.0.1:9443 gives highest throughput
  by bypassing nginx + TLS).
- Operator API key at `~/.config/macprovider/buyer-api-key` on the operator's
  local Mac (you may need to SCP it to Pearl as a file for wrk to read in
  Lua scripts, OR read via ssh + inject inline).
- Operator coord bearer is at `/opt/macprovider/coordinator.yaml`
  (operator_key field) — needed only for `/internal/routing` + `/poolz`.
- The Phase 7 P2 monitor (systemd timer, every 3 min) is already watching
  for breaker/warmup/idle events. Check `/var/lib/macprovider/monitor-state.json`
  after each test phase to catch anomalies that fired during it.

## Phases (do in order; capture results per phase, do NOT skip phase between phases)

### Phase A — 48-hour burn-in for memory + FD leak detection

**Why**: prior stress was only ~5 min. Unknown if gateway/coord leak memory
or file descriptors over hours/days under sustained trickle load.

**Setup**: launch a low-rate background load (1 req/sec) against
`/v1/usage` (authenticated read, exercises auth+DB without spending quota
on real inference). Use systemd-run with `--unit=stress-burnin
--scope=system` on Pearl so it survives ssh disconnect. Capture
`ps -o rss,etime,nfds -p <pid>` for both gateway+coord every 5 min into a
CSV.

**Pass/fail**:
- RSS growth: < 100 MB per process per 24h (catches obvious leaks)
- FD count: stable ±5 (catches FD leaks)
- No journal `fatal`/`panic`/`level":"error"` events
- The Phase 7 P2 monitor never alerts on anything other than normal
  idle-Mac sleep cycles

**Estimate**: 48h elapsed, ~5 min of actual operator-time per check-in.

### Phase B — Adversarial input fuzz

**Why**: untested today. A real network audience will probe.

**Battery**:
1. **Oversized body**: post 100MB body to `/v1/chat/completions`. Expected:
   nginx `client_max_body_size 8M` returns 413. Verify NOT a gateway
   process crash, NOT memory spike.
2. **Malformed JSON**: post `{model:llama` (truncated). Expected: gateway
   400 with clean `invalid_request_error` body, no panic.
3. **Header injection**: post with `X-MacProvider-Internal-Conv:
   conv:attacker` (no other auth). Expected: gateway strips it BEFORE auth
   (audit event in gateway journal), returns 401 for missing bearer.
   Already pinned by `TestInternalHeaderStripAndAuditEventOnUnauthenticatedRequest`
   but verify the live behavior matches.
4. **Slow-loris**: open 100 connections to `/v1/chat/completions`, send
   1 byte every 30s. Expected: nginx connection-cap (`limit_conn`) rejects
   beyond 5 concurrent per IP; gateway process stays healthy.
5. **Path traversal**: GET `/v1/../../etc/passwd`, GET `/v1/models?account_id=../`.
   Expected: 404 from gateway, no information leak.
6. **Bearer probe rate**: 100 RPS of invalid bearers. Expected: all 401,
   audit events possibly recorded, no DB write storm (key-hash check is
   cheap, but verify no quadratic behavior).

**Pass/fail**: every probe returns a clean error; no process restart; no
memory spike >50MB during attack; nginx + gateway logs cleanly attribute
each.

### Phase C — High-concurrency same-account quota race (extended)

**Why**: prior test was 50 concurrent for 10s. Real abuse pattern is
sustained.

**Run**: 100 concurrent connections, 5 minutes sustained, hammering
`/v1/chat/completions` with a model that hits the **just-fixed 404 path**
(any unknown model name — verifies the fix holds under sustained load,
not just spot-checks). Track:
- Total requests, success/4xx/5xx/429 breakdown
- Quota delta (should be exactly 0 — coord 404 → gateway 404 → zero charge)
- Gateway `account_concurrency_exceeded` 429 rate (the per-account cap)
- SQLite write contention (any `database is locked` errors in gateway
  journal)

**Pass/fail**: quota delta exactly 0 over 5 min; no SQLite errors; gateway
RSS growth < 50MB; account-concurrency cap fires consistently rather than
allowing all 100 through.

### Phase D — Multi-account load (NEW: untested in prior stress)

**Why**: prior stress used 1 account. SQLite contention scales with account
count and per-account writes (settlement, key-issue, audit).

**Run**: pre-create 50 accounts via the existing `auth.NewKeyManager.Issue()`
path (call from a small Go program or shell-loop the OAuth API). Then run
50 concurrent users each making 2 RPS of `/v1/usage` calls for 5 min.
Capture:
- SQLite WAL size growth
- Gateway p99 latency vs single-account
- Auth-cache hit rate (if observable)

**Pass/fail**: p99 stays under 100ms; no SQLite contention errors; auth
path scales sub-linearly.

### Phase E — Sticky-affinity behavioral verification (NEW: blocked in prior session)

**Why**: Pillar A was deployed but verification was inconclusive — only 1
provider per model, so single-candidate routing didn't exercise sticky pin.

**Prereq**: requires ≥2 providers serving the SAME model. Options:
- Operator runs a second provider on a beefy Mac (most realistic)
- Operator runs `phase4-coordinator/tools/mockprovider/` to bring up a
  synthetic Qwen-7B-serving provider on Pearl loopback (zero-cost)

If operator can supply two same-model providers (real or synthetic):
- Send 10 requests with `X-MacProvider-Conversation: conv-A`
- Send 10 with `X-MacProvider-Conversation: conv-B`
- Verify in coord journal that all conv-A requests pinned to one provider
  and all conv-B pinned to one (possibly the other)
- Verify `sticky_hit` reason appears in `routing_decision` logs

**Pass/fail**: sticky pinning is observable; no `sticky_miss` after the
first request of a given conversation; cross-conversation routing
distributes correctly.

### Phase F — Coordinator failover under load

**Why**: untested today. If coord goes down mid-flight, gateway should
return clean 503 to in-flight buyers AND recover when coord comes back.

**Run**: start a 50-RPS load on `/v1/chat/completions` (rejected-model
path → no real inference burned). Mid-run, `systemctl restart
macprovider-coordinator` on Pearl. Capture:
- Error rate during restart (target: bounded to the ~3s coord boot window)
- Gateway connection pool behavior (any pinned dead connections?)
- Recovery time to baseline error rate

**Pass/fail**: no gateway crash; error rate spikes only during coord
restart, returns to baseline within 5s of coord coming back up; the P2
monitor catches and logs the transient.

## What to commit when done

Write `DECISION_CRITERIA` Entry 35 (find the latest entry number; the prior
one is 34) with per-phase results in the same style as Entry 34. Push via
the Augustas11 account.

If any phase fails, STOP and surface to operator before continuing. A
phase-D SQLite contention or phase-F gateway crash is deploy-blocking for
paid public launch.

## What NOT to do

- Don't propose new SPEC text or build prompts in this session — this is a
  measurement session, not a design session.
- Don't change config flags without operator say-so. The current flag state
  (D on, C on, A on, B off) is deliberate.
- Don't run synthetic load against real providers (air5, air8gb) at >1
  concurrent. Hobby providers WILL collapse under more.
- Don't touch the deferred pre-public PG-* gates (token re-issuance for
  require_provider_tokens flip, provisional-tier token gating,
  providerhttp timeout) — those are separate work items.

=== END PROMPT ===
```

---

## How to use

Paste everything between the `=== BEGIN PROMPT ===` markers into a fresh
Claude or Codex session rooted at `/Users/augstar/macprovider-poc`.
Estimated runtime: 48-72 hours elapsed (mostly Phase A burn-in), with
~30-60 min of operator-attended work across Phases B-F.

When this completes successfully, the system has been **production-shaped**
and is ready for the next deploy-gate work (PG-1 token re-issuance,
provisional-token gating, etc.) before paid public buyer launch.
