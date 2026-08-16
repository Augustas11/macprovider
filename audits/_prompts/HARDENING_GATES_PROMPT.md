# Hardening gates — pre-public-launch fixes

Operator-paste prompt for the four remaining code-level hardening tasks
before public launch, plus operator checklist for the two operational
gates that require SSH/live-system access.

**Parallelism note:** SPEC-008 Phase 2 may be running concurrently.
It touches `ws/server.go` (first-message dispatch) and the Swift binary.
This prompt touches `buyer/server.go`, `providerhttp/client.go`,
`gateway/server.go`, and `config/config.go`. The only shared file is
`config/config.go` — SPEC-008 adds inside `Tier2Config`; this prompt
adds a new `Limits` struct and a `ProviderHTTP` struct. Run on a
**separate branch**. Merge after both sessions are done; the config.go
and gateway/server.go conflicts will be mechanical (different struct
sections, different line ranges).

Run in **Codex** (or Claude Code). Rooted at
`/Users/augstar/macprovider-poc`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session.

---

```
=== BEGIN PROMPT ===

Working directory: /Users/augstar/macprovider-poc

You are applying four pre-public hardening fixes to the coordinator and
gateway. Read the relevant source files before editing. Run tests after
every fix. Commit each fix atomically.

---

## Fix 1 — concurrency_reservation_failed context-cancel guard (gateway)

File: `phase5-gateway/internal/router/server.go`

Around line 1178 there is an AcquireConcurrency error path that returns
HTTP 500 `concurrency_reservation_failed`. The same pattern was already
applied to the `quota_reservation_failed` path (context.Canceled /
context.DeadlineExceeded → silent return, no response written to a dead
connection). Apply the same guard here.

Current pattern to find:
  } else if err != nil {
      _ = s.store.RefundReservation(context.Background(), ...)
      writeError(w, http.StatusInternalServerError, "server_error",
          "concurrency_reservation_failed", "Could not reserve concurrency")
      return
  }

Change to:
  } else if err != nil {
      _ = s.store.RefundReservation(context.Background(), ...)
      if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
          return
      }
      writeError(w, http.StatusInternalServerError, "server_error",
          "concurrency_reservation_failed", "Could not reserve concurrency")
      return
  }

Ensure `errors` is already imported (it should be). Run:
  cd phase5-gateway && go test ./... 2>&1 | tail -20

Commit:
  git add phase5-gateway/internal/router/server.go
  git commit -m "fix(gateway): context-cancel guard on concurrency_reservation_failed (same pattern as quota fix)"

---

## Fix 2 — providerhttp timeout (coordinator)

The `phase4-coordinator/internal/providerhttp/client.go` package-level
`http.Client` has no `Timeout` set, leaving HTTP-forwarding provider
connections open indefinitely if a provider hangs.

### 2a — Config

File: `phase4-coordinator/internal/config/config.go`

Add a new top-level config struct `ProviderHTTPConfig` and wire it into
the root `Config` struct:

  type ProviderHTTPConfig struct {
      TimeoutS int `yaml:"timeout_s"`
  }

In the root `Config` struct add:
  ProviderHTTP ProviderHTTPConfig `yaml:"provider_http"`

In `setDefaults()` (or equivalent), set:
  cfg.ProviderHTTP.TimeoutS = 300   // 5 min, matches coordinator request_timeout_s

In `validate()`, add:
  if cfg.ProviderHTTP.TimeoutS <= 0 {
      return fmt.Errorf("provider_http.timeout_s must be > 0")
  }

### 2b — Wire to client

File: `phase4-coordinator/internal/providerhttp/client.go`

Change the package-level var to a function so the coordinator main (or
server init) can inject the configured timeout:

  package providerhttp

  import (
      "net/http"
      "time"
  )

  var Client = &http.Client{
      CheckRedirect: func(req *http.Request, via []*http.Request) error {
          return http.ErrUseLastResponse
      },
  }

  // Init sets the HTTP client timeout. Call once at startup before
  // serving requests.
  func Init(timeoutS int) {
      Client = &http.Client{
          Timeout: time.Duration(timeoutS) * time.Second,
          CheckRedirect: func(req *http.Request, via []*http.Request) error {
              return http.ErrUseLastResponse
          },
      }
  }

### 2c — Call Init at startup

File: `phase4-coordinator/cmd/coordinator/main.go`

After config is loaded and validated, call:
  providerhttp.Init(cfg.ProviderHTTP.TimeoutS)

### 2d — YAML example

File: `phase4-coordinator/coordinator.yaml.example` (and
`phase4-coordinator/dist/coordinator.yaml`)

Add under routing section or as its own top-level block:

  provider_http:
    timeout_s: 300  # 5 min; match routing.request_timeout_s

Run:
  cd phase4-coordinator && go build ./... && go test ./... 2>&1 | tail -20

Commit:
  git add phase4-coordinator/internal/config/config.go \
          phase4-coordinator/internal/providerhttp/client.go \
          phase4-coordinator/cmd/coordinator/main.go \
          phase4-coordinator/coordinator.yaml.example \
          phase4-coordinator/dist/coordinator.yaml
  git commit -m "fix(coordinator): configurable providerhttp timeout (default 300s)"

---

## Fix 3 — maxChatRequestBodyBytes: const → config (coordinator, Task #11)

File: `phase4-coordinator/internal/buyer/server.go`

Currently line ~101:
  const maxChatRequestBodyBytes int64 = 1 << 20

This is hardcoded and breaks buyers with large `tools` arrays once paid
public traffic arrives.

### 3a — Config

File: `phase4-coordinator/internal/config/config.go`

Add a `LimitsConfig` struct:

  type LimitsConfig struct {
      MaxChatRequestBodyBytes int64 `yaml:"max_chat_request_body_bytes"`
  }

In root `Config`:
  Limits LimitsConfig `yaml:"limits"`

In `setDefaults()`:
  cfg.Limits.MaxChatRequestBodyBytes = 1 << 20  // 1 MiB

In `validate()`:
  if cfg.Limits.MaxChatRequestBodyBytes <= 0 {
      return fmt.Errorf("limits.max_chat_request_body_bytes must be > 0")
  }
  if cfg.Limits.MaxChatRequestBodyBytes > 128<<20 {
      return fmt.Errorf("limits.max_chat_request_body_bytes must be <= 128 MiB")
  }

### 3b — Remove const; read from server config

In `buyer/server.go` remove `const maxChatRequestBodyBytes`. The
`BuyerServer` struct already holds a `cfg` or is passed the config —
read `cfg.Limits.MaxChatRequestBodyBytes` at the call sites. If the
server struct does not already hold the full config, add it or pass the
limit at construction time. Do not introduce global state.

Existing test at `buyer/server_test.go` (around line 1230) creates an
oversized body using `1<<20+1`. Update that test to use a helper
constant or call the default from config so the test stays correct
regardless of the configured value.

### 3c — YAML example

Add to `coordinator.yaml.example` and `dist/coordinator.yaml`:

  limits:
    max_chat_request_body_bytes: 1048576  # 1 MiB default; raise for buyers
                                          # with large tools arrays

Run:
  cd phase4-coordinator && go build ./... && go test ./... 2>&1 | tail -20

Commit:
  git add phase4-coordinator/internal/config/config.go \
          phase4-coordinator/internal/buyer/server.go \
          phase4-coordinator/internal/buyer/server_test.go \
          phase4-coordinator/coordinator.yaml.example \
          phase4-coordinator/dist/coordinator.yaml
  git commit -m "fix(coordinator): Task #11 — maxChatRequestBodyBytes configurable via limits.max_chat_request_body_bytes"

---

## Fix 4 — SPEC-006 §17.7 spec text patch (narrow)

File: `specs/SPEC-006-buyer-api.md`

Find section §17.7 (quota refund matrix). The context-cancel / timeout
refund path was implemented in gateway code (sha 5de08803) but the spec
text does not enumerate it as a required invariant.

Add the following row to the §17.7 refund matrix table, or append a
normative paragraph immediately after the table if the section is prose:

  | Context cancelled (buyer disconnects mid-reservation) | `quota_reservation_failed` branch exits silently; `RefundReservation` called before return | No 500 written to buyer (dead connection); reservation fully refunded |
  | Context cancelled (buyer disconnects at concurrency gate) | `concurrency_reservation_failed` branch exits silently; `RefundReservation` called before return | Same as above |

If §17.7 is not a table, add a normative paragraph:

  **Context-cancel refund invariant.** When the buyer's HTTP connection
  is cancelled (`context.Canceled`) or times out (`context.DeadlineExceeded`)
  at any reservation gate (quota or concurrency), the gateway MUST call
  `RefundReservation` before returning and MUST NOT write an error
  response to the dead connection. This invariant was first enforced in
  gateway sha 5de08803 but was omitted from this matrix. Acceptance
  criterion: a client that closes the connection immediately after sending
  the request body MUST produce zero net quota consumption (verified by
  comparing `used_tokens` before and after in `/v1/usage`).

Update the §17.7 version reference comment if one exists. Increment the
SPEC-006 patch version in the header (e.g., v0.8.2 → v0.8.3).

Do NOT change any other section. Do NOT open any other spec file.

Commit:
  git add specs/SPEC-006-buyer-api.md
  git commit -m "spec(006): §17.7 enumerate context-cancel refund invariant (code-only gap from sha 5de08803)"

---

## Final verification

After all four commits:

  cd phase4-coordinator && go build ./... && go test ./... 2>&1 | tail -30
  cd phase5-gateway     && go build ./... && go test ./... 2>&1 | tail -30

If any test fails, fix before proceeding. Do not move past a red test.

Print a summary of the four commits with their SHAs:
  git log --oneline -6

=== END PROMPT ===
```

---

## Operator checklist — gates that require SSH / live system

These cannot be run by Codex. Do them AFTER the four code fixes above
are merged to main and deployed.

### Gate A — Phase A burn-in verdict

Due: 00:03 UTC 2026-06-02 (tomorrow).

```bash
ssh pearl 'tail -5 /var/lib/macprovider/burnin.csv'
```

PASS if RSS growth < 50 MB over 48h and FD count is stable (no
monotonic growth). FAIL if either trends upward — investigate before
flipping any provider-auth gates.

### Gate B — require_provider_tokens flip

Pre-condition: Phase A PASS, and new coordinator binary (with Fix 2+3
above) is deployed to Pearl.

**Step 1 — Re-issue tokens for M1 and M4.**

SPEC-002 §7.1 requires every pinned provider token to be issued with
`--provider-id` before `require_provider_tokens: true` is set. Check
whether the coordinator exposes a token-issuance admin endpoint:

```bash
curl -s -H "Authorization: Bearer $OPERATOR_KEY" \
  https://coordinator.malibu.tech/admin/token-issue
```

If that endpoint exists, issue tokens for each provider_id (M1, M4)
and send to each partner with their updated config. If no endpoint
exists yet, check SPEC-002 §7.1 for the issuance procedure and
implement it before flipping the flag.

**Step 2 — After both partners confirm their new tokens are loaded:**

In `/etc/macprovider/coordinator.yaml` on Pearl, add under `auth:`:

```yaml
auth:
  operator_key: "..."
  require_provider_tokens: true
```

Reload the coordinator:
```bash
sudo systemctl restart macprovider-coordinator
sudo journalctl -u macprovider-coordinator -n 30 --no-pager
```

Verify both M1 and M4 re-connect cleanly (no 4005 close codes in log).

### Gate C — Phase F re-run (clean coordinator failover)

Re-run without the midnight timing confound from Entry 37.

Pre-condition: fresh-quota dedicated test account, non-midnight window.

```bash
# On Pearl: start 50 RPS load (90s window, invalid model path)
wrk -t4 -c50 -d90s \
  -H "Authorization: Bearer $TEST_ACCOUNT_KEY" \
  -s post.lua \
  https://api.malibu.tech/v1/chat/completions &

# At T+20s: restart coordinator
sleep 20 && sudo systemctl restart macprovider-coordinator

# Capture result
wait
sudo journalctl -u macprovider-coordinator -n 50 --no-pager
```

PASS criteria:
- Coordinator restart completes in ≤5s
- Gateway does not crash
- Error rate spike is clearly correlated with coordinator down window,
  not quota exhaustion (confirm by checking test account quota before/after)
- Both providers re-join pool after coordinator restart
