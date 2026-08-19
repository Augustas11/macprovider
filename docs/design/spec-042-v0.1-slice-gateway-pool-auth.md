# SPEC-042 v0.1 slice — gateway pool authorization + `X-MacProvider-Pool` emit

Status: design → implementation. Slice owner: gateway (phase5) + a minimal
coordinator advertisement half (phase4). Stacked on the coordinator pool-routing
stack (`feat/spec-042-impl-stage-e`).

## 1. What this slice delivers (SPEC-042 R002 + R010, gateway half)

The coordinator already ingests an authorized `X-MacProvider-Pool` header,
routes pool traffic to members only, fails closed on stale generation, and binds
`pool_id` into the settlement record spine (#1069/#1072). But **nothing emits
that header yet**, and the coordinator honors it only for an authenticated
gateway context. This slice builds the emitting half:

1. **Credential-bound pool authorization (R002).** A buyer request may name a
   pool only from the set its credential is authorized for. The authoritative
   set is the ceiling; a request selector picks one pool from it and can only
   **narrow**, never widen.
2. **Non-disclosing rejection (R010).** A request naming a pool the credential
   is not authorized for is rejected with the generic `pool_unavailable`
   (503, non-retryable) — never a "not authorized for pool X" signal, so the
   error does not confirm the pool exists.
3. **Positive capability negotiation (R010).** The gateway refuses to emit a
   pool-required dispatch unless the coordinator *positively advertises* pool
   support. An old coordinator ignores `pool_id` and would route from the global
   snapshot (tenant spill); the gateway must not rely on it to fail closed. This
   slice builds both halves of the coordinator↔gateway handshake.
4. **The emit (R002).** For an authorized, capability-satisfied pool selection,
   set `X-MacProvider-Pool: <pool_id>` on the coordinator-bound request, next to
   the internal-bearer + `X-MacProvider-Account` pair the gateway already sends.
5. **Default-off, byte-identical global (R010).** Feature disabled, or no pool
   named → today's global behavior, unchanged. Feature disabled + pool named →
   fail closed (`pool_unavailable`), never a silent pool→global downgrade.

### Deliberately out of scope (documented, deferred)

- **Wallet-session pool selection.** R002 requires the SPEC-040 semantic
  signature to cover `pool_id` and the manifest core digest. That is a SPEC-040
  wallet-envelope amendment (flagged in SPEC-042 R010). Until it lands, a
  wallet-session request MUST NOT be able to select a pool; it stays global.
- **Per-API-key pool columns.** API keys have no scope struct today (only
  quota/concurrency class). This slice binds the authorized set at
  **account** granularity via operator config (`account_id → [pool_id]`), which
  is a safe superset-free binding (a key belongs to exactly one account).
  Per-key granularity + a DB-backed authorized set is a follow-up.
- **Provider-half capability advertisement.** R010's handshake also names the
  selected provider. The gateway cannot see the chosen provider (the coordinator
  selects it), so the gateway verifies the *coordinator's* advertisement here;
  the coordinator enforces member-only routing (#1069). A provider pool-support
  version advertised up to the coordinator, and coordinator refusal to route to
  a non-advertising member, is a follow-up.
- **Manifest/pool_status freshness, predicate errors** (`pool_policy_stale`,
  `pool_attestation_unsatisfied`, …): coordinator-side, already partly present
  or future slices. This slice adds only `pool_unavailable` and
  `pool_selection_invalid` on the gateway.

## 2. Selection resolution (pure decision table)

The pool selector is a **control-plane HTTP header only** — the inbound buyer
header `X-MacProvider-Pool-Select`, deliberately NOT a request-body field. The
gateway does not define or honor a body `pool` field, so it introduces no pool
control metadata into the data-plane body it forwards and needs no body mutation
(arbitrary unknown body keys a buyer sends still follow the pre-existing
OpenAI-compatible passthrough — this slice neither adds nor scrubs them). The
header name is **distinct** from the outbound internal
`X-MacProvider-Pool`, so the two never collide and a buyer cannot smuggle the
internal header (`copyForwardHeaders` already allowlists only
`Accept`/`X-MacProvider-Retry`/`Idempotency-Key`).

Inputs: `selector` (the single distinct non-empty value of
`X-MacProvider-Pool-Select`), `conflicting` (the header appeared with two
different values), `poolSelectionAllowed` (the auth mode may select a pool —
plain API-key only), `authorizedSet` (the account's configured pool set),
`featureEnabled`, `coordinatorAdvertises`.

Order matters — authorization precedes any coordinator interaction so latency
cannot become an existence oracle (R010):

| # | Condition | Result |
|---|---|---|
| 0 | `!poolSelectionAllowed` and a selector is present (wallet-session / demo) | `pool_unavailable` (503) — before authorization; non-disclosing |
| 1 | `conflicting` (two distinct header values) | `pool_selection_invalid` (400) |
| 2 | selector empty | **global** — emit nothing, byte-identical |
| 3 | `!featureEnabled` (selector non-empty) | `pool_unavailable` (503) — fail-closed rollback, no silent pool→global |
| 4 | selector ∉ `authorizedSet` (incl. account absent) | `pool_unavailable` (503) — non-disclosing; **no coordinator roundtrip** |
| 5 | `!coordinatorAdvertises` (selector authorized) | `pool_unavailable` (503) — fail-closed, no spill |
| 6 | otherwise | **pool `= selector`**; emit `X-MacProvider-Pool: <selector>` |

Rows 0–4 are pure/local (no network). Only an *authorized* selection (row 5/6)
consults the coordinator capability metadata, so an unauthorized caller's latency
is independent of whether the named pool exists anywhere. The narrow-only
invariant is enforced structurally by row 4's ⊆ check: a selector can only pick a
pool already in the ceiling, never add one.

Row 0 enforces the R002 deferral that only plain API-key credentials may select a
pool: a **wallet session** (SPEC-040) must not, because its semantic signature
does not yet cover `pool_id`/manifest digest and the selector header is not in
its signed profile (honoring it would authorize a pool with no signed binding);
**demo** traffic has no durable account scope. Row 0 rejects before the conflict
and authorization checks, so it is also non-disclosing.

`pool_selection_invalid` fires only on a conflicting/ambiguous selection (row 1),
never on an out-of-scope pool (that is row 4's `pool_unavailable`), so the 400
cannot confirm a pool exists.

**Row 5 uses a FRESH capability fetch** (`coordinatorRoutingMetadataFresh`), not
the 5s-cached sticky-hint metadata. A stale cached `true` would let pool dispatch
continue for up to the TTL after a coordinator rollback/disable (`trustPools ==
nil`), and the rolled-back coordinator would ignore the header and route globally
— a pool→global spill the positive handshake exists to prevent. Fresh shrinks
that window to the unavoidable in-request TOCTOU. Pool traffic is opt-in, so the
extra roundtrip is acceptable.

## 3. Placement

`handleChatCompletions` (`internal/router/chat_proxy.go`): resolve the pool
**right after `parseChatRequest`** (where `model`/`stream` are read) and
**before any quota/concurrency reservation** — R002 requires authorization before
reservation or dispatch. Store the resolved `poolID string` in the handler scope;
`buildUpReq` sets the header when non-empty, guarded by the same
`subject.AccountID != ""` condition that already guards the bearer + account pair.

Capability metadata comes from `s.coordinatorRoutingMetadataFresh(upCtx)` — the
same `/internal/routing` surface the sticky path reads, but the FRESH variant
(see row 5 rationale above) so a rollback cannot be masked by a stale cached
`true`.

## 4. Coordinator advertisement (phase4, minimal)

`handleInternalRouting` (`phase4-coordinator/internal/buyer/server.go`) adds one
block to its JSON payload:

```go
"pools": map[string]any{"enabled": s.trustPools != nil},
```

`trustPools` is the existing pool-feature handle (`WithPoolMembership`, #1069):
nil = feature off = advertise `false`. Old coordinators omit the block entirely;
the gateway decodes a missing `pools` object to the zero value (`Enabled=false`)
and fails closed. This is the positive-advertisement contract: absence ⇒ no pool
support ⇒ gateway refuses.

## 5. Config

Add under `FeaturesConfig` (`internal/config/config.go`), default-off:

```yaml
features:
  trusted_pools:
    enabled: false
    account_pools:            # account_id -> [pool_id, ...]
      "acct_example": ["<pool_id>"]
```

`TrustedPoolsConfig{ Enabled bool; AccountPools map[string][]string }`, defaulted
`{Enabled:false}` in `Default()`. At load, normalize into
`map[string]map[string]bool` for O(1) membership. `Validate()` rejects a
malformed entry only when `enabled` (an empty/absent map is valid — it just means
no account may select any pool, the safe default).

## 6. Errors (register to satisfy the AST guard)

Both are non-retryable → add to `gatewayPermanentCodes` (`server.go`):

- `pool_unavailable` → `writeError(w, 503, "service_unavailable", "pool_unavailable", "Pool unavailable")`. Single fixed (503, non-retryable) response for every cause (disabled, unauthorized, unknown, capability-absent) so neither status, code, nor the derived `retryable` flag distinguishes cause.
- `pool_selection_invalid` → `writeError(w, 400, "invalid_request_error", "pool_selection_invalid", "Conflicting pool selection")`.

## 7. Test plan (conformance-first)

Pure unit (no http):
- selector agreement/conflict (rows 1);
- account authorization map lookup incl. account-absent (row 4), narrow-only.

Handler-level (mirror `newTestHarnessConfig` + `roundTripFunc` fake coordinator,
`server_test.go`):
- **byte-identical global**: feature off, no `pool` field → request forwarded
  with **no** `X-MacProvider-Pool` header (assert absent), unchanged status;
- feature on, no selector → same (global, header absent);
- feature off + selector → `pool_unavailable`, coordinator **never called**
  for chat (reservation not taken);
- authorized selector + coordinator advertises `pools.enabled:true` → forwarded
  **with** `X-MacProvider-Pool: <pool_id>` (assert the fake coordinator saw it);
- authorized selector + coordinator advertises `false` (or omits `pools`) →
  `pool_unavailable`, chat **not** forwarded (no spill);
- unauthorized selector → `pool_unavailable`, and assert the capability endpoint
  was **not** consulted for this request (timing independence);
- conflicting body vs header selector → `pool_selection_invalid` (400);
- coordinator advertisement: `/internal/routing` includes
  `pools.enabled=true` iff `trustPools != nil` (phase4 test).

## 8. Compatibility

- Feature off (default) and poolless requests: zero behavior change, no new
  header, byte-identical forward path.
- Old coordinator (no `pools` advertisement): gateway fails closed on any pool
  selection; global traffic untouched.
- The outbound `X-MacProvider-Pool` value is `base64url` `pool_id`
  (`A-Za-z0-9-_`), which passes the coordinator's `sanitizeOpaqueHeader`
  (1–128 bytes, no control chars) unchanged — verified against #1069's honor
  path.
