# AUDIT — ISS-211 R1 — SECURITY lens

## Task

Security-lens audit of the SPEC + IMPL bundle for issue #211
(coordinator-side account-scoped reconciliation key,
follow-up to #196).

Branch: `spec/iss-211-coordinator-account-scope`.

### Focus areas

1. **Header trust boundary.** The gateway now sends
   `X-MacProvider-Account: <subject.AccountID>` on every forwarded
   request. The coordinator's `handleChatCompletions` reads this
   header from `r.Header.Get(...)` and writes it into
   `request_log.account_id`. Does the coordinator validate that
   the header came from a trusted upstream (vs. a buyer who
   bypasses the gateway and sets the header directly)? Does the
   threat model require validation, or is the coordinator-vs-buyer
   network-level segmentation sufficient? Compare with how
   `X-MacProvider-Account` is treated on the existing sticky path
   (where it already arrived and was used to derive the
   conversation key — a security-sensitive value).

2. **`sanitizeAccountID` in
   `phase4-coordinator/internal/buyer/server.go`.** New helper.
   Same shape as `sanitizeExternalRequestID` (trim, 128-byte cap,
   C0/C1 control-char reject). Are there account-id-specific
   considerations the sanitizer should additionally enforce
   (e.g. character allowlist matching the actual issued
   account-id format `acct_<...>` or `demo:<ip>`)? Does rejecting
   on length / control chars to "" silently expose a downstream
   path that assumes a valid account_id?

3. **Demo IP exposure.** Demo subjects forward
   `subject.AccountID = "demo:<X-Real-IP>"` to coordinator. The
   coordinator can already see the underlying IP via X-Forwarded-For
   / source address, so net new exposure is approximately zero;
   verify this reasoning is correct and the IP isn't being newly
   exposed to a downstream system (log file, audit table,
   admin dashboard) that previously did not see it.

4. **Cross-account row leakage in money-path query.** The
   `hotpath.go` change scopes the AttemptN COUNT by
   `(account_id, request_id)` when `account_id != ""`. Is the
   fallback to the unscoped query (when `account_id == ""`) a
   downgrade an attacker can engineer (gateway suppresses the
   header → coordinator counts cross-account rows → exploit)?

5. **SQL injection / parameter binding.** The new query uses
   parameterized binds; verify there is no string-interpolation
   path.

6. **Migration safety.** `ALTER TABLE request_log ADD COLUMN
   account_id TEXT NULL` on a live deployment. Are there any
   constraints (NOT NULL, FK, UNIQUE) that would block the
   migration mid-traffic? Is the partial-NULL composite index
   safe to build under sustained write load given the
   single-writer connection pool?

### Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal SPEC or code edit>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

### Out of scope
- The #196 gateway composite-PK design.
- Auth model for `/v1/chat/completions` itself.
- Explorer surface (intentionally deferred).
