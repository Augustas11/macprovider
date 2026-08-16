# Issue drafts — phase-A engineering follow-ups (2026-06-27)

Each issue below is ready to file via `gh issue create` against
`Augustas11/macprovider` (public repo). Before filing, confirm:
- Wording is non-exploit-style (no "here's how to drain provider $$$").
- Internal repro details that name specific buyer accounts /
  operator-only paths stay in the internal findings doc.

## Issue 1 — Plumb shared correlation_id end-to-end (gateway↔coordinator↔usage_events)

**Title:** `feat(gateway, coordinator): shared correlation_id across request_log and usage_events`

**Body:**

> Today gateway and coordinator each generate their own UUID per request
> (verified live 2026-06-27 — gateway X-Request-Id and coord request_log
> id never overlap). Out-of-process auditors (the internal e2e harness,
> any future SRE audit script) cannot exactly reconcile billing between
> the two SQLite stores; they must fall back to fuzzy matching by
> `(ts ± window, model, completion_tokens)`. That obscures the
> difference between "gateway over-billed" and "concurrent live traffic".
>
> **Proposal**
>
> 1. Gateway accepts inbound `X-Correlation-Id` header; if absent,
>    generates one (UUIDv4).
> 2. Gateway echoes it on every response (success and error) as
>    `X-Correlation-Id`.
> 3. Gateway forwards it to coordinator over the WS tunnel (new field
>    in the inference_request message).
> 4. Coordinator stores in `request_log.correlation_id` (new column,
>    nullable, indexed).
> 5. Gateway stores in `usage_events.correlation_id` (new column,
>    nullable, indexed).
>
> Backwards-compatible: NULLs allowed for pre-feature traffic.
>
> **Scope split**
>
> Can land in three PRs:
> - Schema migration on both sides (no behavior change).
> - Gateway changes (header round-trip + forward).
> - Coordinator changes (read incoming field, store in request_log).
>
> Surfaces in SPEC-002 v1.4.2 R-6 (see internal addendum).

---

## Issue 2 — Investigate Swift WS silent-disconnect on provider Macs

**Title:** `bug(phase3-binary): provider WS reconnect loop wedges silently after extended uptime`

**Body:**

> **Symptom**
>
> On the operator's local provider (binary 1.6.1, augustass-macbook-air):
>
> - Process uptime: ~42 hours.
> - `lsof -a -p <pid> -nP -iTCP -sTCP:ESTABLISHED` returned zero outbound
>   sockets — WebSocket to coordinator was dead at the TCP level.
> - `~/Library/Logs/macprovider/macprovider.out.log` had NO entries
>   between `2026-06-25 13:17` and the next forced restart, despite
>   the heartbeat task being scheduled every ≤5s per
>   `CoordinatorClient.swift:1210` (`keepaliveTickCeilingSeconds`).
> - Coordinator side observed the 90s
>   `provider_inactive_threshold` fire and dropped the provider; the
>   provider's `runReconnectLoop` (`CoordinatorClient.swift:315`) did
>   NOT re-establish for the full 42-hour window.
>
> The same pattern was observed on `air5` (a separate operator's Mac)
> during this investigation — coord journal `2026-06-27T06:15:47Z`
> "provider websocket disconnected" → reconnect minutes later, likely
> launchd KeepAlive.
>
> **Hypothesis**
>
> Most likely: macOS App Nap / cooperative-task starvation suspends
> the Swift Task scheduler while the process stays alive at the OS
> level. `connectAndRunOnce()` (`:349`) either hangs or its result
> never propagates back to `runReconnectLoop`.
>
> Secondary: URLSession's WebSocket `send()` queues frames at the API
> level even when the TCP socket is half-open; the heartbeat send
> succeeds without an error, so the existing fail-on-send-error path
> at `:1232` (`closeWebSocketAfterKeepaliveFailure`) never fires.
>
> **What we'd want to see / repro**
>
> No clean repro today (manifests over days/weeks). Suggested probes:
>
> 1. Run with `MACPROVIDER_KEEPALIVE_DEBUG=1` (existing flag,
>    `:157`) on a long-running provider and capture
>    `keepalive_send_error` / `warm_swap_heartbeat_send_error` lines
>    when the wedge appears.
> 2. Add a watchdog inside the heartbeat task: track timestamp of last
>    successful tick; if any tick is >3× expected interval late,
>    `Darwin.exit(1)` and let launchd respawn.
> 3. Bound `sendHeartbeat()` with `withTimeout(5s)` so a wedged send
>    surfaces as a throw → existing close-and-reconnect path fires.
>
> **Operator-visibility mitigation already shipped**
>
> External LaunchAgent watchdog: `ops/macprovider-watchdog/` (internal
> repo). Polls `netstat` every 60s for an ESTABLISHED TCP to coord
> IP; on detection of half-open state, runs
> `launchctl kickstart -k gui/$(id -u)/live.malibu.provider`.
> Installed and verified on augustass-macbook-air. Not a substitute
> for the Swift-side fix; documented for fleet-wide install via
> `get.malibu.tech/install.sh` follow-up.

---

## Issue 3 — Gateway returns 404 for unknown model; SPEC-002 says 503

**Title:** `bug(gateway): unknown-model requests return HTTP 404, but SPEC-002 FR-B1 documents HTTP 503 no_provider_available`

**Body:**

> **What we saw**
>
> Live probe 2026-06-27. Request body:
> ```json
> { "model": "nonexistent-model-9000-test-only", ... }
> ```
> Response: `HTTP 404 not_found`.
>
> SPEC-002 v1.4.1 FR-B1 lists the 8 expected zero-provider error codes,
> and `no_provider_available` (503) is the one that fits this case.
>
> **Decision needed**
>
> One of:
> 1. Update SPEC-002 to document 404 (matches OpenAI semantics for
>    model-not-found).
> 2. Change the gateway to return 503 + `no_provider_available` to
>    match the existing spec.
>
> The internal addendum (SPEC-002 v1.4.2 R-3) flags this as
> `[PRODUCT DECISION]` and proposes both options.

---

## Issue 4 — Mid-stream provider drop: buyer sees 200 + zero-token bill, no audit row

**Title:** `bug(gateway): mid-stream provider WS drop produces no usage_events row at all`

**Body:**

> **Repro**
>
> 1. Buyer sends a streaming `/v1/chat/completions` request to a model
>    served by exactly one provider.
> 2. While streaming, kill the provider process (`launchctl
>    kickstart -k`, `pkill`, network blip, etc.).
> 3. Observe the buyer's HTTP response.
>
> **Expected per current gateway code**: gateway emits `data: [DONE]`
> and closes the SSE stream cleanly. HTTP status remains 200 (already
> sent at headers).
>
> **Observed**: above is correct. But:
>
> - No row written to `usage_events` for this request_id. Buyer is
>   not billed (✓ from buyer's POV) but provider is also not
>   compensated for the work done before death.
> - Buyer client has no signal that the response was truncated — no
>   error chunk, no warning header, content just stops mid-sentence.
>
> **Decision needed**
>
> See SPEC-002 v1.4.2 R-4 (internal addendum). Three options:
> R-4a status quo (write down explicitly), R-4b settle partial, R-4c
> reroute on excluded list.

---

## Issue 5 — Harness streaming token counter undercounts

**Title:** `test(network-harness): streaming chunkPayload.usage parsing yields zero tokens on truncated and well-formed streams`

**Body (internal, would NOT be filed on public repo — affects internal
harness only)**:
>
> Internal e2e harness `test/network-harness/internal/buyer/loadgen.go`
> parses `Usage.CompletionTokens` from each SSE chunk. Many providers
> only emit `usage` in the final chunk (or omit it entirely on
> streaming responses, expecting clients to compute from delta
> content).
>
> Scenario 05 (mid_stream_drop) recorded `bytes_received=13097` but
> `completion_tokens_received=0`, even though the stream completed
> cleanly with `[DONE]`. I3 (overcharge detection) is therefore
> structurally blind on streaming workloads today.
>
> **Fix options**
> 1. Embed a tokenizer compatible with the served model and count
>    `choices[].delta.content` per chunk.
> 2. Sum chunk content lengths as a token approximation (×0.25
>    chars-per-token heuristic; lossy but bounded).
> 3. Read the FINAL chunk before `[DONE]` and extract `usage` from it
>    if present.
>
> Recommended: option 3 first (simplest, matches what most OpenAI-compat
> providers emit on the closing chunk); fall back to option 2 when
> the final chunk is missing usage; option 1 only if precision
> matters in phase C.

---

## Issue 6 (deferred follow-up) — Generalize macprovider-watchdog for fleet

**Title:** `feat(installer): include WS-health watchdog LaunchAgent`

**Body**:
>
> The internal `ops/macprovider-watchdog/` LaunchAgent prevents
> silent-disconnection at the operator level (every-60s
> netstat-based health check + launchctl kickstart on half-open
> WS). It's currently hardcoded to provider id
> `augustass-macbook-air`.
>
> To ship fleet-wide:
> 1. Read provider id from `~/.config/macprovider/config.yaml`.
> 2. Ship as part of `get.malibu.tech/install.sh`.
> 3. Make the launchd label / process matcher configurable.
> 4. Decide whether the watchdog also cross-checks coordinator's
>    `/v1/models` (catches the case where WS is established at TCP
>    level but provider has been silently dropped from the ready pool).
>
> Blocks proper resolution of issue #2 — the Swift fix is the
> permanent solution; this watchdog is operator-visibility insurance.

## Filing order suggestion

| Order | Issue | Public? | Why first |
|---|---|---|---|
| 1 | #1 shared correlation_id | YES | Unblocks proper reconcile; clear scope. |
| 2 | #2 Swift silent-disconnect | YES | Fleet-wide bug; needs assignee for repro. |
| 3 | #3 404 vs 503 | YES | Quick decision + small PR. |
| 4 | #4 mid-stream drop | YES | Money-path question; needs product call. |
| 5 | #6 fleet watchdog | YES | Op-side mitigation; safe to file. |
| - | #5 harness streaming counter | NO (internal worktree) | Harness lives internally per current decision. |
