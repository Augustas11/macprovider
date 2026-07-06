# SPEC-002 — Phase 4 Coordinator: Mac Provider Request Router

**Version:** 1.5.3 (2026-07-06, bounded coordinator slot queue — issue #374)
**Depends on:** SPEC-001 v1.4 (Phase 3 binary wire protocol, locked; v1.4 adds installer custom-model selection + `models browse` + fit guard on top of the v1.3 absorbed in §7.8/§7.9); SPEC-003 FR-C9.4 composed contract — base AuthState enum (`bearer_validated`, `self_minted`, `bearerless_duplicate`) introduced in v0.8.3; `mint_failed` reserved value added in v0.8.4.

**Change log v1.5.3 (2026-07-06, issue #374 — bounded coordinator slot queue):**
- **Bounded zero-slot queue.** Non-pinned requests MAY enter a
  coordinator-side pre-dispatch queue when at least one otherwise
  eligible `ready` provider for the requested model reports
  `slots_free == 0`. Queue admission is still quota-filtered before
  waiting. The queue is FIFO per `provider_id`, caps pending waiters at
  4 per provider, and uses a total deadline no longer than 750 ms.
  Pinned provider/session requests do not enter this queue and retain
  immediate 503 behavior when the pinned target has no free slot.
- **Queue wait observability.** `request_log` gains
  `queue_wait_ms REAL NOT NULL DEFAULT 0`, populated per active
  provider attempt. The value measures coordinator slot-queue dwell
  before preflight/provider dispatch; it does not include provider
  execution time or preflight latency.
- **Provider-queue boundary.** The coordinator remains responsible only
  for bounded pre-dispatch slot smoothing. Provider-side tokenization,
  execution queueing, and model-specific inference work remain provider
  responsibilities.

**Change log v1.5.2 (2026-06-29, issue #168 — monotonic `attempt_n` column on `request_log`):**
- **New column.** `request_log` gains `attempt_n INTEGER NULL` (zero-based
  monotonic attempt ordinal). NULL on legacy rows written before
  v1.5.2; non-NULL on all v1.5.2+ writes. Existing reconciliation
  contracts (SPEC-005 v0.3+, SPEC-007 v0.3+) continue to work in the
  rollout window because the read-side prefers the persisted
  `attempt_n` when non-NULL and falls back to the v0.3.1 id-ASC
  derivation when NULL.
- **Write-time population semantics.** At `request_log` INSERT,
  `attempt_n` MUST be assigned monotonically as `COUNT(*) FROM
  request_log WHERE account_id IS ? AND request_id = ?` over the
  rows already in the same `(account_id, request_id)` group under
  SQLite `IS` semantics, computed in the same writer transaction.
  Because the request-log store caps the pool at one writer
  connection (`SetMaxOpenConns(1)` per the v1.4.2 R-2 + #21 / ARCH-3
  discipline), this read-then-insert is race-free. The first row in
  any group receives `attempt_n=0`; the n-th row receives
  `attempt_n=n-1`. This is the same arithmetic the prior v0.3.1
  read-time derivation produced; v1.5.2 just persists it at write
  time so the value is stable across audit, reconciliation, and
  replay.
- **Read-side discipline.** SPEC-005 v0.3.3+ MUST consume
  `request_log.attempt_n` directly when non-NULL. When NULL (legacy
  pre-v1.5.2 row OR rollback window), the read-side falls back to
  the v0.3.1 id-ASC derivation within the same
  `(account_id, request_id)` group. The fallback is exactly the
  arithmetic the writer would have produced, so a backfilled row and
  a derivation-time row are byte-identical.
- **Backfill subcommand.** A new operator subcommand
  `coordinator backfill-attempt-n` walks legacy rows in id-ASC order
  within each `(account_id, request_id)` group and assigns
  `attempt_n` monotonically (the same arithmetic the v0.3.1 fallback
  produces, executed once as a one-shot DDL-class operation rather
  than per-read). Idempotent: rows that already have non-NULL
  `attempt_n` are skipped. Read-only `--check --format=text|json`
  reports a count of NULL vs populated rows so operators can verify
  completion before they consider the migration done.
- **Migration state machine.** Three observable states, parallel to
  the v1.5.1 per-key state machine but PER-COLUMN (no index, since
  `attempt_n` is a per-row ordinal, not a join key):
  - `legacy` — column absent. Read-side MUST fall back to id-ASC
    derivation; SPEC-005 v0.3.3 fallback rules apply (row 3+ credited
    normally via the byte-identical id-ASC arithmetic; only
    `attempt_n=1` with `retried=0` quarantined as the legitimate-
    retry-without-marker class).
  - `populating` — column present, some rows have NULL `attempt_n`
    (either pre-v1.5.2 rows awaiting backfill OR a rollback window
    where the v1.5.2 binary briefly ran then reverted). Read-side
    prefers persisted `attempt_n` on non-NULL rows, falls back to
    id-ASC derivation on NULL rows. Both paths produce byte-
    identical ordinals because the writer derivation matches the
    fallback derivation.
  - `populated` — column present, zero NULL rows. Steady-state.
  Tooling MAY check state via `backfill-attempt-n --check --format
  json` which returns `{"migration_state": "legacy|populating|
  populated", "null_count": N, "total_count": M}`.
- **No race with the v1.5.0 AttemptN derivation.** The v1.5.0
  AttemptN scoping in `hotpath.go` / `recovery.go` /
  `endpoints.go` (defense-in-depth COUNT-based derivation
  scoped by `(account_id, request_id) IS`) remains correct on
  legacy rows. v1.5.2 writes populate `attempt_n` BEFORE the
  derivation point so the derivation simply prefers the
  persisted column when non-NULL — same arithmetic either
  way.
- **Quarantine rule change (cross-spec, see SPEC-005 v0.3.3).**
  With persisted monotonic `attempt_n`, the v0.3.1 "row 3+ MUST
  be quarantined until SPEC-002 gains monotonic attempt_n" rule
  is satisfied in BOTH paths — the persisted monotonic `attempt_n`
  path AND the byte-identical id-ASC fallback path. Row 3+ in either
  path receives a stable `attempt_n=2, 3, ...` ordinal and is credited
  normally (subject to the existing `retried` flag and identity-
  snapshot rules). Quarantining is reserved for one genuine ambiguity
  class: `attempt_n=1` with `retried=0` (legitimate retry without an
  explicit `retried` marker — see SPEC-005 §OQ-5, issue #169).
- **Deploy ordering.** Coordinator v1.5.2 MUST be deployed before
  any out-of-process tooling that reads `attempt_n` directly. The
  ALTER TABLE runs at daemon startup; the operator runs
  `coordinator backfill-attempt-n` once per deployment. During the
  `populating` window (column present, some NULL rows), the read-side
  discipline above keeps every consumer correct.
- **Backfill live-safety.** `coordinator backfill-attempt-n` SHOULD
  run during a maintenance window (the same window as
  `migrate-indexes` is the natural choice). It MAY run live against
  a running daemon — the request-log writer-connection cap from
  issue #21 / ARCH-3 serializes the backfill UPDATE against new
  hot-path INSERTs, preserving correctness — but operators MUST
  accept that the backfill UPDATE will hold the writer lock for the
  duration of its scan, potentially exceeding the 6s INSERT timeout
  on the hot path and triggering buyer-visible 503s. The
  recommended sequence is: take the deploy briefly offline, run
  `backfill-attempt-n`, then restore traffic.
  **Preflight wall-clock measurement.** `coordinator
  backfill-attempt-n --dry-run` executes the same UPDATE inside a
  transaction and ROLLBACKs without persisting; it reports the
  rows-that-would-be-updated count plus the wall-clock elapsed
  time on the operator's actual production corpus. Operators MUST
  use this dry-run to measure against the 6s hot-path INSERT budget
  BEFORE deciding whether to run a live backfill — the dry-run
  itself holds the writer lock for the same duration as a live run
  would, but is observability-only (no row mutation). The CLI emits
  a WARNING if dry-run elapsed exceeds 4 seconds (75% of the 6s
  budget). A dry-run that warns means the operator SHOULD use a
  maintenance window; a clean dry-run authorizes a live backfill.

**Change log v1.5.1 (2026-06-29, issue #197 — R-2 normative clarifications + sanitizer hardening):**
- **`external_request_id` UUID-tolerance clause.** Formalizes the
  pre-existing implementation contract for the inbound `X-Request-ID`
  header: `request_log.external_request_id` is **opaque sanitized
  text**, not a UUIDv4-shape-required field. Gateway-routed traffic
  carries a UUIDv4 per SPEC-006 R-G3 (the gateway middleware mints a
  UUIDv4 if the inbound `X-Request-ID` is absent or non-UUIDv4-like).
  Direct coordinator buyer-port traffic (no gateway in front) MAY
  carry an arbitrary printable, sanitized string up to 128 bytes.
  Coordinator implementations MUST NOT reject non-UUID-shaped
  inbound IDs but MUST apply the sanitization documented in this
  section: trim whitespace; cap at 128 bytes; reject invalid UTF-8;
  reject control bytes **at byte granularity** (`< 0x20`, `0x7f`,
  and the C1 range `0x80-0x9f`). Rune-based iteration is NOT
  sufficient — raw bytes in `0x80-0x9f` decode to `utf8.RuneError`
  (U+FFFD) and would otherwise pass a rune-only check, bypassing
  the load-bearing C1/CSI rejection that the
  `c1-control-chars-terminal-sanitizer-bypass` hardening was added
  for. On failure the value is treated as if the header was absent
  and the malformed payload MUST NOT be echoed to structured logs
  (re-introduces the log-injection class the sanitizer exists to
  defeat). Cross-service reconciliation MUST NOT assume UUIDv4
  shape when joining gateway `usage_events` to coordinator
  `request_log` by `external_request_id`; parity is byte-exact on
  the sanitized string. The same sanitization applies to
  `X-MacProvider-Account` → `request_log.account_id` (SPEC-002
  v1.5.0); both headers share `sanitizeOpaqueHeader`.
- **Registry invariant.** The composite-key registry
  (`migrationKeyDefs` in code, table in this SPEC) MUST be non-empty.
  Entries are append-only: future SPEC versions add reconciliation keys
  by appending entries and MUST NOT rename existing `key` strings. The
  JSON `keys` array order is **normative** — consumers MAY rely on the
  i-th entry being stable across coordinator versions; new entries
  append at the end. If a `key` ever must be replaced
  (irreconcilable shape change — including cosmetic rename or
  same-columns-different-name), the path is **deprecate-and-add**:
  the OLD `key` entry continues to enumerate with its real
  `legacy | unindexed | indexed` state — the state-enum vocabulary
  is NOT extended, no new `deprecated` state value is introduced —
  while the SPEC change-log explicitly marks the old `key` as
  deprecated and names the new `key` as its replacement. If the
  rename is cosmetic (same columns + same index), both entries
  report the same state derived from the same underlying schema;
  if the shape changed, the old `key` reports `unindexed` (its
  index dropped) or `legacy` (its column dropped) while the new
  `key` reports the new shape's state. The deprecated `key` is
  dropped in a later SPEC version after at least one minor-version
  deprecation window. Tooling MUST match by `key` and MUST
  tolerate additional entries beyond what it knows about
  (forward-compat).
- **Per-key migration-state machine.** Each composite reconciliation
  key on `request_log` has its OWN three-state migration:
  - state `legacy` — required column(s) absent in
    `PRAGMA table_info(request_log)`. Exact composite-key
    reconciliation is unavailable; downstream tooling MAY fall
    back to the prior-version key (e.g.
    `account_external_request_id` legacy → `external_request_id`
    alone, documented ambiguity).
  - state `unindexed` — column(s) present but the partial-NULL
    composite index is absent in `sqlite_master`. Exact
    reconciliation is **available** but unindexed, with the
    operator-visible performance penalty of a full `request_log`
    scan per join. This is NOT legacy.
  - state `indexed` — column(s) AND partial-NULL composite index
    present. Steady-state.
  The aggregate `migration_state` across all keys is `legacy` if
  ANY key is legacy; `indexed` only if EVERY key is indexed;
  `unindexed` otherwise. Reconciliation tooling MUST decide join
  strategy per-key, not whole-schema, because v1.4.2 R-2 and
  v1.5.0 added separate composite keys at different times
  (`idx_request_log_external_request_id` and
  `idx_request_log_account_external_request_id` respectively) and
  may be at different states on the same deployment.
- **Canonical state vocabulary.** The strings `"legacy"`,
  `"unindexed"`, `"indexed"` are normative. Reconciliation
  harnesses, dashboards, and operator tooling MUST emit these
  literal strings (no synonyms, no casing variation) so that
  cross-team tooling is interoperable.
- **Machine-readable surface.** The coordinator MUST expose this
  state via `coordinator migrate-indexes --check --format json`
  (a read-only sibling of the existing build path). JSON shape:
  ```json
  {
    "migration_state": "legacy|unindexed|indexed",
    "keys": [
      {
        "key": "<key-name>",
        "column_names": ["<col>", ...],
        "columns_present": true|false,
        "index_name": "<idx>",
        "index_present": true|false,
        "state": "legacy|unindexed|indexed"
      }
    ]
  }
  ```
  Implementation: `requestlog.Store.MigrationState(ctx)`. The
  `--check` form does NOT mutate the schema; it is the canonical
  state probe for external tooling.
- **State `(unindexed)` operational binding.** Scope is by
  **data-surface contract, not process placement**. In scope:
  any reconciliation surface that performs **closing-the-books
  joins** between coordinator `request_log` and gateway
  `usage_events` / `audit_events` by composite reconciliation
  key — out-of-process harnesses AND any future coordinator-
  hosted endpoint that exposes the same join. Out of scope:
  coordinator's own in-process AttemptN paths (`hotpath.go`,
  `recovery.go`, `endpoints.go` `/admin/ledger/reconcile`)
  which derive ordinals via single-table SQLite `IS`
  clustering on `(account_id, request_id)` and are correct
  (just unindexed-slow) under state `unindexed`. In-scope
  tooling MUST fail closed when it observes state `unindexed`
  for a composite key it depends on. Operator response: run
  `coordinator migrate-indexes` once, then resume. Tooling MAY
  support an explicit override (`--allow-unindexed-scan`,
  bounded by row-count or wall-clock budget) for fixture, dev,
  or one-shot recovery use; the override MUST NOT be the
  default. Falling back silently to fuzzy match under state
  `unindexed` is a SPEC violation — it conflates with state
  `legacy` and hides an operator-action gap.
- **Expected operator workflow.** Normal sequence is (A) daemon
  startup applies ALTER TABLE migrations (legacy → unindexed),
  then (B) operator runs `coordinator migrate-indexes`
  (unindexed → indexed). The `migrate-indexes` subcommand also
  calls `requestlog.OpenStore` and so applies any pending ALTER
  TABLE migrations itself before building indexes; running it
  against a legacy DB takes the schema directly to indexed in
  one invocation.
- **Sanitizer hardening (code change).** v1.5.1 ships byte-level
  C1 rejection + invalid-UTF-8 rejection in
  `sanitizeExternalRequestID` and `sanitizeAccountID` via a
  shared `sanitizeOpaqueHeader` helper. Pre-v1.5.1 the rune-based
  loop accepted raw C1 bytes via `utf8.RuneError` decoding;
  v1.5.1 closes that bypass and pins it with regression tests
  for `0x80`, `0x9b`, `0x9f`, and invalid UTF-8 leads.
- **Cross-SPEC alignment.** SPEC-005 reconciliation tooling that
  enforces schema-check (failing closed on missing indexes) MUST
  read the per-key state vocabulary defined here. SPEC-007 v0.3
  explorer surface gates by resolved row fields (not schema
  state) and is independent of this state machine. SPEC-006
  R-G3 (gateway UUIDv4 minting) is unchanged — gateway-routed
  traffic remains UUIDv4-shaped; the v1.5.1 opaque-text tolerance
  is scoped to the direct coordinator buyer-port input.

**Change log v1.5.0 (2026-06-29, issue #211 — coordinator-side counterpart to #196 composite-PK):**
- `request_log` gains an `account_id TEXT NULL` column. The
  reconciliation key joining gateway `usage_events` to coordinator
  `request_log` is now the composite `(account_id, external_request_id)`,
  not `external_request_id` alone. After #196 a buyer-supplied
  `X-Request-ID` MAY legitimately appear in `usage_events` rows
  belonging to distinct accounts; under the v1.4.2-shipped key
  (`external_request_id` only) the coordinator could not attribute a
  `request_log` row to the correct gateway account.
- **Gateway forward contract.** Gateway MUST send
  `X-MacProvider-Account: <subject.AccountID>` on every forwarded
  buyer request (including the non-sticky routing path; the prior
  conditional emit on the sticky path only is insufficient for
  reconciliation). The coordinator MUST persist this header value
  into `request_log.account_id` for every row written for that
  request. Absent header MUST be tolerated (legacy gateway, demo
  traffic, direct legacy buyer calls); the column carries NULL in
  that case and reconciliation degrades to the prior
  `external_request_id`-only key with the documented ambiguity.
  Because `selectProviderExcluding` already treats
  `X-MacProvider-Account` as an internal-routing header (see
  `hasInternalRoutingHeader` / `internalBearerAuthorized`),
  v1.5.0 also requires the gateway to send the upstream
  `Authorization: Bearer <UpstreamCoordinatorBearer>` together
  with the account header on every forward; pre-v1.5.0 the
  bearer was only set on the sticky path. The coordinator's
  acceptance logic is unchanged — only the gateway's emission
  envelope. See SPEC-006 v0.9.1 for the gateway-side rule.
- **Money-path scope (hot path + recovery + admin reconcile).**
  Coordinator queries that attribute multiple `request_log` rows
  to a single logical request — `internal/billing/hotpath.go`
  AttemptN derivation, `internal/billing/recovery.go` startup /
  nightly reconciliation, and `internal/billing/endpoints.go`
  `/admin/ledger/reconcile` `buyerEquivalentCredits` — MUST scope
  by `(account_id, request_id)` using SQLite `IS` semantics
  (`account_id IS ?` / `prior.account_id IS rl.account_id`).
  Note: `request_log.request_id` is coordinator-internal
  (server-minted UUID v4 per buyer call), so two accounts do not
  naturally collide on it; the buyer-supplied collision class
  motivating #211 lives on `external_request_id` and is fully
  addressed by the composite `(account_id, external_request_id)`
  reconciliation key. The internal-`request_id` account scoping
  here is therefore defense-in-depth so that any UUID v4
  collision, retry-loop bug, or future schema change that ever
  causes the same internal `request_id` to appear in rows from
  different accounts cannot inflate the count and silently
  trigger the `ambiguous_attempt_n` zero-credit path under the
  SPEC-005 v0.3.1 multi-attempt attribution contract. Legacy
  NULL-`account_id` rows cluster with NULL-`account_id` rows
  only (NULL = NULL true under `IS`), preserving the pre-v1.5.0
  intra-NULL grouping without bleeding non-NULL rows into the
  legacy bucket. All three sites MUST use identical NULL
  semantics so the same row gets the same `attempt_n`
  derivation regardless of which path scans it.
- **Index.** A new partial-NULL composite index
  `idx_request_log_account_external_request_id ON request_log(account_id, external_request_id) WHERE account_id IS NOT NULL AND external_request_id IS NOT NULL`
  supports reconciliation scans. Built by the operator-runbook
  subcommand `coordinator migrate-indexes` (same pattern as the
  v1.4.2 `idx_request_log_external_request_id` index), NOT from
  daemon startup.
- **Deploy ordering.** Coordinator MUST be deployed before gateway
  begins sending the unconditional header so that even pre-gateway
  rollout coordinator writes accept and persist the new column.
  Coordinator without the column behaves as if `account_id` were
  always NULL. Downstream auditors MAY use
  `PRAGMA table_info(request_log)` only to detect "column absent —
  pre-v1.5.0 schema; fall back wholesale to the v1.4.2 R-2
  reconciliation key". Once the column exists, all audit /
  reconciliation gating MUST be per-row `account_id IS NOT NULL`
  (see §11 "Deploy ordering" canonical sequence). Column presence
  alone is NOT sufficient because a v1.5.0 coordinator can be
  serving pre-v0.9.1 gateway traffic OR rolled back to a v1.4.x
  binary that doesn't populate the column — both cases produce
  rows with NULL `account_id` despite the column being present.
- **Cross-spec.** SPEC-006 §6 gains a forward-header requirement
  for `X-MacProvider-Account`. SPEC-007 §6.4 records the
  gateway-side composite-PK addendum once issue #212 / PR #221
  merges; the coordinator-side parallel is documented in this
  v1.5.0 entry. The two PRs are merge-order independent — the
  cross-pointers describe relative state, not a strict ordering.
- **Explorer deferral.** Coordinator-side explorer queries
  (`phase4-coordinator/internal/explorer/store.go`
  `SessionDetail` / `RecentSessions`) still join `request_log`
  by `request_id` alone and do not return `account_id` in
  session output. This is intentionally deferred from v1.5.0 —
  the reconciliation contract (the focus of issue #211) is
  the key change-log item; explorer surface enrichment lands
  in a separate SPEC-007 follow-up. Operators querying
  `request_log` for cross-account audit MUST use direct SQL
  with the composite key for the v1.5.0 window.
- **Triage:** the in-flight "SPEC-002 v1.4.2 R-2" references in
  `phase4-coordinator/internal/requestlog/store.go` and tests reflect
  external_request_id work that never received a formal change-log
  entry; that gap is the subject of issue #197 and is intentionally
  NOT closed here. v1.5.0 builds on top of the v1.4.2 R-2 work as
  shipped (column + index already present) and does not relitigate
  it.

**Change log v1.4.1 (2026-06-26, additive — issue #82 item 1):**
- FR-O2 `/poolz` provider row gains the optional `auth_state` string
  field (`omitempty`). Enum: `bearer_validated`, `self_minted`,
  `bearerless_duplicate` (SPEC-003 v0.8.3 FR-C9.4), plus the
  `mint_failed` value reserved by SPEC-003 v0.8.4. Absent / empty
  preserves pre-v0.8.3 behavior (routable). The field is
  documentational on the coordinator side (`pool.Provider.AuthState`
  has been emitted via the embedded `pool.Provider` struct since
  SPEC-003 v0.8.3) and is now normatively part of the SPEC-002
  `/poolz` contract surface. **Observability scope:** today only
  `bearer_validated`, `self_minted`, `bearerless_duplicate`, and the
  empty pre-v0.8.3 value actually appear on registered `/poolz` rows.
  `mint_failed` is a reserved enum value — the coordinator returns it
  internally from `resolveProvisionalToken` on transient DB-write
  failure but immediately closes the WebSocket with `CloseInvalidToken`
  before the session is registered (`phase4-coordinator/internal/ws/server.go`
  `handleHello` / `handleAuthRequest` close paths), so it does NOT
  currently surface as a `/poolz` row. Issue #82 item 2 may publish
  an observable non-routable `mint_failed` row in the future — when
  it does, the aggregation rule below MUST be re-evaluated.
- Adds normative aggregation rule for downstream `/poolz` consumers
  (SPEC-006 gateway `/v1/status`): provider rows with
  `auth_state == "bearerless_duplicate"` MUST be excluded from ALL
  buyer-facing capacity counters derived from the detailed pool
  array, including top-level `Pool.TotalProviders`, top-level
  `Pool.Ready`, per-model `ProviderCount`, per-model
  `ReadyProviderCount`, slot totals, model availability, and
  per-model `supported_models` unions. This mirrors
  `pool.Provider.RoutingEligible()` on the coordinator side — a
  bearerless duplicate is admitted to `/poolz` for operator
  visibility but is non-routable; counting it would over-promise
  capacity the coordinator will refuse to route. Other `auth_state`
  values (empty, `bearer_validated`, `self_minted`, and currently
  `mint_failed` — which never appears on registered rows today) are
  aggregated normally; the eventual `mint_failed`-becomes-observable
  decision is intentionally deferred to issue #82 item 2 and is NOT
  in scope for v1.4.1.
- **Buyer-vs-operator counter separation (Q1 resolution).** On
  buyer-facing surfaces derived from `/poolz` (the SPEC-006 gateway
  `/v1/status`), `total_providers` is a routable-eligible count, not
  a raw session count — it excludes `bearerless_duplicate` rows by
  the aggregation rule above. The operator-facing `/poolz` body
  itself still surfaces ALL admitted sessions in its `pool` array
  (including bearerless duplicates) and in its top-level `summary`;
  operator visibility is preserved precisely because operators must
  be able to see WHY a session is non-routable. Consumers that need
  raw operator-visible session counts MUST read the `/poolz`
  `summary` block (which is coordinator-emitted and includes
  bearerless rows in `total_providers`); consumers that surface
  buyer-facing counts MUST apply the aggregation rule.
- **Summary-fallback prohibition (covers the all-bearerless edge
  case).** Auth-state-aware consumers that derive buyer-facing
  counts from `/poolz` MUST NOT use the coordinator-supplied
  `summary` block as a fallback to repopulate counts that have been
  excluded by the aggregation rule when the detailed `pool` array
  was present. The coordinator's `summary.total_providers` is
  `len(providers)` on the coordinator side (includes bearerless);
  using it as a fallback after filtering would reintroduce excluded
  capacity. The gateway IMPL gates its summary fallback on
  `len(poolz.Pool) == 0` (no detailed rows at all), not on
  `out.Pool.TotalProviders == 0` after filtering.
- Wire-additive change. Pre-v1.4.1 consumers that ignore unknown
  fields continue to work unchanged; the only behaviour change is
  the gateway aggregation exclusion. No SPEC-001 wire change.
- **Cross-spec follow-up (deferred).** SPEC-006 (buyer-facing gateway)
  currently describes `/v1/status` without the `auth_state`
  exclusion. A SPEC-006 amendment carrying a pointer to this rule is
  the right place to surface the invariant for implementers reading
  the gateway spec alone; that amendment is out of scope for
  v1.4.1 and lands as part of issue #82 closure.

**Change log v1.4.0 (2026-06-26):**
- **v1.4.0 (2026-06-26, issue #92):** FR-P11a streaming-failover paragraph
  now defines "committed" with the post-#92 predicate inline. Adds the
  buyer-visible TTFT note and the gateway `coordinator_header_timeout_seconds`
  constraint (header timeout MUST be >= request budget, deploy-checked at
  `phase4-coordinator/dist/check-deploy-config.sh` C2b). No wire-protocol
  change; SPEC-001 unaffected.

**Change log v1.4:**
- **v1.4 (2026-06-22, SPEC-015 v0.1.3 absorption):** Adds two
  parser/consumer-optional fields to each `/poolz` provider row:
  `receipt_pubkey` and `receipt_pubkey_prev`. `receipt_pubkey` is a
  nullable standard padded base64 ed25519 public key string; null means
  the provider did not publish a SPEC-001 v1.6 receipt pubkey.
  `receipt_pubkey_prev` is null outside key-rotation grace windows or
  an object carrying `pubkey`, `rotated_at`, and `expires_at` during
  the SPEC-015 v0.1.3 reconnect-based rotation grace window. This is a
  `/poolz` JSON shape absorption only; durable receipt-key storage is
  deferred to future specs.

**Triage note 2026-06-26 (no version bump, no normative change):**
- §12 OQ-6 (`X-MacProvider-Tier` to buyers) marked RESOLVED inline. Pointer: `docs/OPEN_QUESTIONS.md` 2026-06-26 triage row for SPEC-002.

**Change log v1.3.5:**
- **v1.3.5 (2026-06-06, SPEC-010 v1.5 + SPEC-011 v0.5 + SPEC-001 v1.3 absorption):** Adds coordinator-side surface for three now-LOCKED companion specs. SPEC-010 v1.5 adds the `Provider` data-model extension (`SupportedModels[]`, `PublishesSupportedModels`); opt-in `/v1/status.supported_models` echo per R-3.3.3 / AC-21. SPEC-011 v0.5 adds heartbeat parsing for optional `model_hash` + `loading: bool` per R-3.3.0 / R-3.3.1; REPLACES the locked `ApplyHeartbeat` hash-clearing semantics with a two-path (legacy clear / SPEC-011 re-verify) contract at `phase4-coordinator/internal/pool/provider.go:411-432`; adds NEW §7.10 audit-log infrastructure + normative `operator_model_swap` event schema. ALSO adds a new normative §7.8 v2 `auth_request` provider handshake section — the v2 contract has been in code since SPEC-002 v1.2.x but was never normatively documented in SPEC-002; v1.3.5 closes that gap on the coordinator side (matching SPEC-001 v1.3 §6.7 binary-side closure). ALSO adds a new normative §7.9 auth-attempt lifecycle section (10-minute timeout per `s.now().Add(10 * time.Minute)` at server.go:355; per-attempt state release on success/reject/expiry/disconnect); takes over as the source of truth from SPEC-010 v1.5 R-3.1.10 clauses 1 and 5 per SPEC-010 §6.2 transition note. L-1 baseline preserved literally: a v1.3 binary in the unset/unset cell continues to be accepted and processed exactly as a pre-SPEC-010/SPEC-011 binary per SPEC-001 v1.3 §6.7.3 cell 1 and SPEC-010 §4.1 back-compat analysis. NO new buyer HTTP surface; NO routing-behavior change; NO Tier-2 (SPEC-008) expansion; NO change to existing FR-P* numbering or AC numbering.

**Change log v1.3.4:**
- Adds the SPEC-005 v0.3 X-2 request_log bundle to FR-B9: `error_code TEXT NULL` for SPEC-001 null-usage errors, `ts_utc` and `(request_id, id)` indexes for reconciliation and attempt fallback, and explicit multi-row-per-request_id semantics for provider retry attempts. Adds deterministic ACs for multi-row request logging and exact error_code population. No SPEC-001 wire change.

**Change log v1.3.3:**
- Adds **audit category J — operational-threshold realism** (§ 11): J.1 requires every timeout/threshold/window to be validated against the slowest realistic provider/workload (the v1.1.6 35s heartbeat-miss kill is the reference: it passed the audit "as coded" but was below one normal MLX completion); J.2 requires cross-component timer relations to be checked for ORDERING (the coordinator vs gateway 300s=300s C2 race). Pairs with a new deploy-time assertion `phase4-coordinator/dist/check-deploy-config.sh` (placeholder-key, threshold-sanity, and C2 timer-ordering checks; wired as step 0 of `deploy-pearl-vps.sh`). No code or wire change.

**Change log v1.3.2:**
- Closes a HIGH finding from the independent Claude audit of the Phase 7 P1 set. The v1.3.1 hold rule only forbade a held provider from self-reporting `ready`, but a breaker/recovery-held provider could still escape by self-reporting `draining` (which cleared the hold via state cleanup) and then `ready`. FR-P11a now forbids a held provider's self-reported state from taking ANY value other than re-affirming `degraded`; only a fresh session (reconnect) or the coordinator recovery path clears a hold. Added a pool-layer regression test (`TestProviderCannotEscapeBreakerHoldViaDrainingLaundering`) that fails against the pre-fix code. The provider-path and coordinator-path state guards are now intentionally distinct (the coordinator may still drain a held provider).
- Hardens **FR-P12 / PG-1** with a production launch gate: because v1.3.1 binds tokens to a `provider_id` subject and rejects empty-subject tokens, every token issued before v1.3.1 is invalid and MUST be re-issued (with `--provider-id`) before `require_provider_tokens` is flipped to `true` — otherwise pinned providers are silently rejected with `4005` (the 2026-05-28 audit-category-I outage class). No code change for this item; SPEC-001 v1.2.4 unaffected.

**Change log v1.3.1:**
- Tightens **FR-P8a** after audit: WS-tunneled providers are probed with the SPEC-001 `inference_request` path, while HTTP-forwarding providers are probed through their configured `/v1/chat/completions` HTTP endpoint and MUST NOT receive WS `inference_request` probes. A warm-up pass now requires both observed non-empty output and `usage.completion_tokens > 0`.
- Tightens **FR-P11a** after audit: provider-reported heartbeat/state `ready` cannot clear coordinator-owned breaker/recovery holds, buyer-initiated streaming cancellations are excluded from breaker accounting, and only a successful breaker recovery records the re-trip anchor. Generic `ready` transitions such as warm-up admission do not make the next breaker trip immediately fatal.
- Closes follow-up security/architecture audit gaps: provider-supplied `hello.endpoint_url` no longer enables HTTP-forwarding for pinned providers, provider HTTP calls MUST NOT follow redirects, HTTP 3xx redirects and literal HTTP 530 are terminal provider failures that close the active provider WebSocket and require reconnect, generic `ready` transitions MUST NOT clear sub-threshold breaker fault counters, provider bearer tokens are bound to `provider_id`, and provider-originated control frames are accepted only from the active `assigned_id` session.

**Change log v1.3.0:**
- Adds **FR-P8a**: an admission-time warm-up capability gate. When enabled (`pool.warmup_gate_enabled`, default true), a newly connected provider is registered as `degraded` and is not buyer-routable until the coordinator runs a tiny inference probe and observes a successful token-producing completion within `pool.warmup_gate_timeout_s` (default 90s, `pool.warmup_gate_max_tokens` default 2). WS-tunneled providers are probed over WebSocket; HTTP-forwarding providers are probed through their configured HTTP endpoint. The gate is an actual inference, not self-reported throughput. Failure/timeout retries on degraded backoff up to `pool.degraded_max_retries`; after exhaustion the provider becomes `unavailable` with reason `warmup_failed`. Existing wake-from-sleep `warm_up` fallback is now config-driven by `pool.warmup_fallback_s` (default 60s). No SPEC-001 / phase3-binary wire change: WS-tunneled probing reuses `inference_request`, `inference_response_chunk`, and `inference_response_end`.

**Change log v1.2.0:**
- Adds **FR-P11a**: a provider **circuit-breaker** for in-flight inference faults. Until now only HTTP 502/504 (HTTP-forwarding path) degraded a provider; in WS-tunneled mode a dead-WS-mid-inference, a relay timeout, or a zero-token completion only failed the individual request (fast-fail/failover per F-4) while the faulting provider stayed `ready` and kept receiving buyer traffic (observed live: an undersized provider that fast-failed every non-trivial request). v1.2.0 makes a provider that accumulates `pool.breaker_failure_threshold` (default 2) qualifying in-flight faults within a rolling `pool.breaker_window_s` (default 120) window transition to `degraded` and run the existing FR-P11 recovery-preflight cycle before returning to `ready`. Buyer-initiated cancellation / client hangup (buyer context cancelled) is EXPLICITLY EXCLUDED and never counts against a provider. Also wires the previously-inert `pool.degraded_backoff_s` and `pool.degraded_max_retries` keys (defined since v1.1, never read) into that recovery cycle, and adds `pool.breaker_*` plus the v1.1.7 `pool.heartbeat_miss_threshold_s` to the config schema block (both were previously only described in prose). Per independent review: FR-P11a **supersedes** FR-P20's former "3 consecutive timeouts → degraded" clause (single source of truth); zero-token only counts when `finish_reason` is abnormal (a clean empty `stop` is valid); buyer-cancels are excluded in both streaming and non-streaming paths; and a provider that re-trips the breaker within the window after breaker recovery is marked `unavailable` to bound flapping. No wire-protocol change; SPEC-001 v1.2.4 unaffected; provider binaries need no update. (The proactive half of provider fitness is FR-P8a's admission warm-up capability gate.)

**Change log v1.1.7:**
- Hotfix to F-4 liveness detection. The v1.1.6 missed-heartbeat monitor closed a provider WebSocket after `heartbeat_interval_s + routing.failover_timeout_s` (35s with production defaults) measured from the last *heartbeat*. A provider doing single-threaded MLX inference cannot emit heartbeats while its one slot is busy, so any generation longer than ~35s was killed mid-request (observed live on Pearl: a Llama-3.2-3B provider at ~0.6 tps fast-failed every non-trivial completion). Fix: (1) the liveness monitor now measures staleness from the last inbound frame of ANY type — in-flight `inference_response_chunk` frames count as activity and keep a busy provider alive; (2) the threshold is a new dedicated key `pool.heartbeat_miss_threshold_s` (default 90s), decoupled from `routing.failover_timeout_s`. In-flight observed close/write failures are unchanged (still bounded by `routing.failover_timeout_s`). No wire-protocol change; provider binaries need no update.

**Change log v1.1.6:**
- Adds F-4: in-flight buyer requests routed over provider WebSocket MUST finish, fail over once to another ready same-model provider, or return `provider_disconnected` when the provider WebSocket dies mid-inference. Observed close/write failures are bounded by `routing.failover_timeout_s` plus small scheduler overhead; silent missed-heartbeat failures are bounded by `heartbeat_interval_s + routing.failover_timeout_s`. Streaming requests may fail over only before response bytes are committed; after commit they terminate the SSE stream with `provider_disconnected`. Explicit provider/session pins do not fail over. Adds `routing.failover_enabled` and `routing.failover_timeout_s` config keys. Adds explicit failure-mode rows for graceful WS close, abnormal WS death, and dead-WS-mid-inference.

**Change log v1.1.5:**
- Adds normative production gates (§ 7.7 PG-1 through PG-5) for the transition from Tier 1 cooperative-trust deployment to public-buyer launch (H-002 from the 2026-05-29 independent security audit). nginx routing block expanded with pre-WS-upgrade rate-limit and connection-cap directives. Audit category I.2 added for the "default-permissive flag in production deployment" anti-pattern. No code change required. Current Tier 1 deployment configuration remains valid; the patch documents the gate, not the migration timing.

**Change log v1.1.4:**
- Closes F-602-1 through F-602-6 from `specs/SPEC-CROSS-006-audit.md`: X-Request-ID correlation, public coordinator-owned `GET /v1/pool/check`, nginx route split, per-model `degraded`, `/poolz` gateway summary fields, SPEC-001 v1.2.4 dependency, and SPEC-006 gateway buyer-port rebind notes.

**Change log v1.1.3:**
- § 7.1 / FR-P12: added `auth.require_provider_tokens` provider-authentication mode. Default `false` preserves the v1.1.2 cooperative pinned-provider trust pool; `true` requires pinned providers to present a valid bearer token and rejects missing or invalid tokens with WS close 4005 `invalid_token`.
- § 6 / § 7.1 close-code semantics: coordinator-initiated provider WebSocket closes MUST be logged at WARN level with close code and reason so production rejections are observable in coordinator logs.
- § 11 audit category I: added the "always-non-nil gate" anti-pattern from Decision log Entry 19 so future audits check both configured and unconfigured branches for production gates.

**Change log v1.1.2:**
- § 7.1 FR-P2: validation wording changed from "validates all fields" to "validates all REQUIRED fields"; absent `endpoint_url` normalized to null before § 3 mode resolution (CRITICAL-2.1 fix).
- § 5 routing pseudocode: replaced undefined `all_filtered_by_quota` with explicit `quota_blocked_candidates` list for 429 vs 503 disambiguation (MAJOR-2.1 fix).
- `**Depends on:**` line corrected to SPEC-001 v1.2.1 (MINOR-2.1 fix).

**Change log v1.1 (absorbs SPEC-003 v0.1 Part B — dynamic admission + WS-tunneled relay):**
- § 3 Request forwarding model: added two-path mode resolution. HTTP-forwarding (legacy, for providers with `endpoint_url` via hello or config) and WS-tunneled (new default, for providers without `endpoint_url`). Mode determined at registration time.
- § 4 FR-P14 through FR-P21: new FRs for WS-tunneled inference relay, admission tiers, provisional rate limits.
- § 5 Routing algorithm: added admission-tier weight multiplier (pinned 1.0, provisional 0.3 configurable). Applied to `effective_throughput`.
- § 5 model_id matching: amended from exact string equality to case-insensitive comparison (D9 fix).
- § 7.1 Close codes: added 4007 `provisional_pool_full`, 4008 `provisional_rate_limited`, 4009 `banned`. Close code 4002 `unknown_provider_id` retired for v1.1+ coordinators.
- § 7.1 F-2 amendment: relaxed from "every provider_id must be in config.providers[]" to three-tier admission (pinned / provisional / rejected).
- § 7.5 (new): Admission state and operator endpoints — `GET /admin/provisional`, `POST /admin/promote/{provider_id}`, `POST /admin/reject/{provider_id}`.
- § 10 D7-D10: four new findings from Phase 4 deploy.
- § 11 AC-11 through AC-14: admission tier acceptance criteria.
- § 12 OQ-6 through OQ-10: redistributed open questions.
- No change to buyer-facing HTTP API (§ 7.2). POST /v1/chat/completions, GET /v1/models, GET /healthz are unchanged in observable behavior.

**Change log v1.1.1:**
- § 3 mode resolution: provisional providers with self-reported endpoint_url are forced to WS-tunneled mode (Q1 operator decision — anti-abuse).
- § 5 routing pseudocode: case-insensitive model_id comparison via `model_id_equal()` helper (M2 fix); provisional request quota integrated into routing paths (M1 fix).
- § 7.1 wire schemas: hello and hello_ack JSON examples updated to match SPEC-001 v1.2.1 § 6.5 (C1 fix); provider_id example corrected to stable operator-issued ID.
- § 7.1: special-case nak handling for § 6.6 routing-mode fallback (M5 fix).
- FR-P14: restored status-to-buyer-HTTP mapping table from SPEC-003 v0.1 FR-A8 (C2 fix).
- § 6.6 request_id lifecycle: unknown/duplicate/cleanup rules added (C3 fix, cross-ref to SPEC-001 v1.2.1 § 6.6).
- OQ-6, OQ-8, OQ-9: restored full rationale paragraphs (M6 fix).
- OQ-10: scoped to coordinator-side buffer only, distinct from SPEC-001 OQ-5 (M3 fix).
- AC-15: coordinator marks provider http_forwarding_only after § 6.6 nak (M5 fix).

**Change log since v1.0.3:**
- § 5 Tie-breaking: added "Operator-visible behavior" note on order-sticky routing under equal metrics (Finding F-1).
- § 7.4 Operator endpoints: explicit port placement — `/admin/*` and `/poolz` live on `provider_port` (default 8444), not `buyer_port` (Finding F-3).
- § 10 added D6 (Phase 4 local acceptance findings F-1, F-2, F-3).
- No FR changes; no normative-behavior changes. v1.0.4 is documentation-only — the implementation already exhibits these behaviors and the corresponding SPEC-002 prose now matches operator-visible reality.

---

## 0. Operator-paste invocation block

```
Implement SPEC-002. As you work, maintain a running
phase4-coordinator/implementation-notes.html that captures anything
I should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

The Phase 4 coordinator is a Go service that runs on a VPS and turns a
pool of Phase 3 Mac Provider binaries into a single OpenAI-compatible
inference endpoint for buyers. It accepts inbound WebSocket connections
from provider binaries (speaking the SPEC-001 section 6.5 protocol), maintains a
live registry of available providers with their advertised capacity and
health state, exposes an HTTPS API that accepts standard OpenAI chat
completion requests from buyers, and routes each request to the
best-matching provider in the pool based on model, capacity, and buyer
preference. It is the single point of contact for Antseed seller
integration (SPEC-003, out of scope) and the future public buyer API
(SPEC-006, out of scope). The coordinator does not perform inference
itself — it is a stateful reverse proxy with provider-aware routing
intelligence.

---

## 2. Scope

### In Tier 1 launch scope (build now)

- Go binary targeting Linux amd64 (VPS deployment)
- WebSocket server on `/ws/provider` accepting inbound connections from
  Phase 3 binaries
- Full implementation of the coordinator side of SPEC-001 section 6.5 wire
  protocol (hello/hello_ack, heartbeat, state_update, drain_status,
  preflight/preflight_ack, drain, warm_up, nak)
- Provider pool registry with live capacity tracking
- Provider state machine (ready, busy, degraded, draining, unavailable)
- Provider auth: offline token issuance via CLI, bearer token validation
  on WebSocket hello, token revocation, hashed storage in SQLite
- Buyer HTTP API: `/v1/models`, `/v1/chat/completions` (streaming and
  non-streaming), wire-compatible with SPEC-001 section 6.2
- Routing algorithm: model match, capacity check, buyer preference
  headers (`X-MacProvider-Pref`, `X-MacProvider-Provider`)
- Preflight check against chosen provider before forwarding
  context-heavy requests
- SSE streaming pass-through from provider to buyer
- Clean error responses (503 no provider, 502 provider failure, 504
  provider timeout)
- Request logging to SQLite: timestamp, model, tokens, provider,
  latency, status
- Operator endpoints: `/healthz`, `/poolz` (auth-gated), `/admin/blacklist`
- Graceful SIGTERM drain of in-flight buyer requests
- SQLite persistence for provider auth, request log, pool state
- Structured JSON logging to stdout
- Coordinator CLI: `coordinator-cli issue-token --provider-id ...`,
  `coordinator-cli revoke-token`, `coordinator-cli list-tokens`
- Operator-opt-in coordinator-side capability advertisement per
  SPEC-010 v1.5 §3.3 / §3.6: extend `Provider` data model with
  `SupportedModels[]` and `PublishesSupportedModels`; extend
  `/v1/status` to opt-in echo `supported_models` when the provider
  set `publishes_supported_models: true` on the v2 `auth_request`
  initial-stage frame.
- Operator-opt-in coordinator-side warm-swap handling per SPEC-011
  v0.5 §3.3 / §3.5 / §3.6: extend heartbeat parser to accept
  optional `model_hash` (raw lowercase hex) + `loading: bool`;
  REPLACE the `ApplyHeartbeat` hash-clearing semantics with the
  two-path (legacy clear / SPEC-011 re-verify) contract; emit
  `operator_model_swap` audit-log event when a swap completes.

### In Tier 2 roadmap scope (designed-in but not implemented)

- `AttestationVerifier`: validate hardware attestation blob from
  provider hello (Tier 2 providers send `attestation` field)
- `BuyerEncryptionRelay`: forward buyer-encrypted payloads to Tier 2
  providers without coordinator decryption
- `TrustChainAuditor`: log attestation chain
  (buyer -> coordinator -> provider) for compliance
- Buyer-side API authentication and per-buyer rate limiting
- Multi-coordinator HA with leader election

Each of these is a named interface in the Go codebase with a Tier 1
no-op implementation. The request and routing pipelines have explicit
insertion points for each. See Section 3 for hook-point locations.

### Out of scope

- Smart router with sticky single-tenant caching (SPEC-004)
- Public direct buyer API with auth/billing (SPEC-006)
- Contributor reward distribution (SPEC-005)
- Antseed seller integration code (SPEC-003; the coordinator's buyer
  HTTP API is wire-compatible with what SPEC-003 will need)
- Buyer-side privacy stack (Tier 2)
- TLS termination (deployment concern; Caddy or nginx in front)
- Multi-model-per-provider support (SPEC-001 is single model per binary)
- Automatic scaling or auto-restart of provider binaries

---

## 3. Architecture overview

```
                          BUYERS (HTTPS)
                              |
                     TLS termination (Caddy)
                              |
    +----------------------------------------------------------+
    |                  COORDINATOR (Go)                         |
    |                                                          |
    |   BUYER SIDE                    PROVIDER SIDE            |
    |   ----------                    -------------            |
    |   Buyer HTTP Server (:8443)     Provider WS Server(:8444)|
    |         |                              |                 |
    |   Request Validator             Auth Validator (bearer)  |
    |   (SPEC-001 s6.2)                     |                  |
    |         |                       Hello Handler            |
    |         |                              |                  |
    |         |                       [AttestationVerifier]     |
    |         |                        TIER 2 HOOK              |
    |         |                              |                  |
    |         +------> Pool Registry <-------+                 |
    |         |        (provider_id -> state, model, capacity) |
    |         |              ^                                  |
    |   [BuyerEncryption     |  Heartbeat Processor            |
    |    Relay] TIER 2       |  State Machine                  |
    |         |              |  Wake Detector (gap >120s)      |
    |         v              |                                  |
    |   Router (model match, capacity, buyer pref)             |
    |         |                                                |
    |   Preflight Checker (WS preflight/preflight_ack)         |
    |         |                                                |
    |   Request Forwarder (HTTP to provider endpoint)          |
    |         |                                                |
    |   [TrustChainAuditor] TIER 2 HOOK                        |
    |         |                                                |
    |   Response Relay        Request Logger (SQLite)           |
    |   (SSE passthrough)                                      |
    |                                                          |
    |   Operator: /healthz  /poolz  /admin/blacklist           |
    |   Storage:  SQLite (WAL) — tokens, request_log, snapshots|
    +----------------------------------------------------------+
              ^                    ^
              |                    |
         WebSocket            WebSocket
         (outbound)           (outbound)
              |                    |
           Mac #1              Mac #2
         (M1 8GB)            (M4 16GB)
```

### Request forwarding model (v1.1 — two paths)

The coordinator supports two inference forwarding paths, selected
per-provider at registration time:

**Path A — HTTP-forwarding (legacy).** The coordinator sends the buyer's
request as a standard HTTP POST to the provider's reachable endpoint
(Cloudflare tunnel URL or direct IP). The WebSocket carries control
plane only (registration, heartbeats, state, preflight, commands).
This is the v1.0.x behavior, preserved for pinned providers with
operator-managed tunnels.

**Path B — WS-tunneled (v1.1 default for new providers).** The
coordinator sends the buyer's request as an `inference_request` message
over the provider's existing WebSocket (SPEC-001 v1.2 § 6.6). The
provider returns response chunks over the same WebSocket. No inbound
network required — provider needs only outbound WSS to the
coordinator. Works behind any NAT, firewall, or hotspot.

#### Mode resolution (normative)

The coordinator determines the forwarding mode at provider registration
time (on `hello`) using the following resolution:

```
if provider_id in config.providers[]:
    tier = pinned
    if config.providers[provider_id].endpoint_url is present:
        inference_path = HTTP_FORWARDING(config.providers[provider_id].endpoint_url)
    else:
        # Provider-supplied endpoint_url is ignored for pinned providers.
        # Only operator-configured endpoints may enable HTTP-forwarding.
        inference_path = WS_TUNNELED
else:
    tier = provisional  (subject to admission rate limits, FR-P16)
    if hello.endpoint_url is present and non-empty:
        # Q1 OPERATOR DECISION (v1.1.1): Provisional providers operate
        # EXCLUSIVELY in WS-tunneled mode. Self-reported endpoint_url
        # from unknown provider_ids is IGNORED to prevent abuse (a Sybil
        # attacker could register N provisional providers each pointing
        # endpoint_url at a target server to amplify traffic via the
        # coordinator). The coordinator logs at warn level:
        # "provisional provider <id> sent endpoint_url <url>; ignored,
        # forcing WS-tunneled mode."
        inference_path = WS_TUNNELED
    else:
        inference_path = WS_TUNNELED
```

**`endpoint_url` in hello (SPEC-001 v1.2 § 6.5).** The `hello`
message gains an OPTIONAL `endpoint_url` field. Existing v1.1.x
binaries do not send it; the coordinator treats absence as null and
falls back to the static `config.providers[]` map. For pinned providers,
`endpoint_url` from `hello` is never trusted as an HTTP-forwarding
destination; only operator-configured `config.providers[].endpoint_url`
can select HTTP-forwarding. Net: zero binary changes required for
existing providers.

**Endpoint discovery (v1.1 resolution, supersedes v1.0.x).** The
static `config.providers[]` map remains the mechanism for pinned-tier
admission and endpoint_url fallback. It is no longer the sole admission
mechanism — see § 7.5 for provisional admission.

### Provider data model (v1.3.5 SPEC-010 extension)

SPEC-002 v1.3.4 does not normatively enumerate the `Provider` Go
struct. The struct exists in code at
`phase4-coordinator/internal/pool/provider.go:50-88`, while existing
fields such as provider identity, `model_id`, capacity, state, and
heartbeat-derived metrics are specified operationally through FR-P1
through FR-P21. v1.3.5 adds normative documentation only for the
coordinator-side fields and retention state extended by SPEC-010 v1.5,
SPEC-011 v0.5, and SPEC-008 v0.3.

R-3.X.1 `SupportedModels []string` MUST be populated from the v2
`auth_request` initial-stage `supported_models[]` field per
SPEC-010 v1.5 §3.3 R-3.3.1. When `supported_models[]` is absent on
the wire, the coordinator MUST synthesize `[model_id]` per SPEC-010
v1.5 R-3.1.5. For the L-1 unset/unset baseline defined by SPEC-001
v1.3 §6.7.3 cell 1, a v1.3 binary's single-entry
`supported_models: [model_id]` frame and a pre-SPEC-010 binary's absent
catalog field both result in `SupportedModels = [model_id]` and no
buyer-visible change per SPEC-010 v1.5 §4.1.

R-3.X.2 `PublishesSupportedModels bool` MUST be populated from the v2
`auth_request` initial-stage `publishes_supported_models` field per
SPEC-010 v1.5 §3.3 R-3.3.2. The default is `false` when the wire field
is absent or explicitly `false`. This bool is the sole coordinator data
model gate for `/v1/status.supported_models` per §7.4 and SPEC-010
v1.5 R-3.3.3 / AC-21; the L-1 baseline omits that response field.

R-3.X.3 `HashStatus` MUST use the five-state SPEC-008 v0.3 §5.5
enumeration: `hash_verified`, `hash_mismatch`, `hash_invalid`,
`uncatalogued`, and `catalog_unavailable`. The enum already exists in
the coordinator; v1.3.5 documents it here because §7.1's
ApplyHeartbeat REPLACEMENT now makes `HashStatus` assignment a
heartbeat-state contract. No sixth state is introduced by SPEC-011
v0.5 §3.5 R-3.5.2.

R-3.X.4 `LastLoadingState bool` MUST be retained per active provider
session to implement the SPEC-011 v0.5 §3.3 R-3.3.5 and §3.6
exactly-once `operator_model_swap` emission gate. The value is updated
from the current heartbeat's `loading` field when present; absence of
`loading` is equivalent to `false` per SPEC-011 v0.5 R-3.3.4. The
sticky gate resets after the first post-loading swap-completion
heartbeat so later steady-state heartbeats do not re-emit the audit
event.

R-3.X.5 `AuthAttemptRetention map[string]AuthAttemptState` MUST be
keyed by the coordinator-generated `auth_attempt_id` from
`phase4-coordinator/internal/ws/server.go:354` and MUST retain only the
per-attempt state required by SPEC-010 v1.5 R-3.1.10 and §7.9. A
retention entry includes the initial-stage SPEC-010 values when present,
challenge details, `provider_id`, start/expiry timestamps, and the
generated auth-attempt ID. The L-1 baseline rule from SPEC-010 v1.5
R-3.1.10 clause 1 remains binding: if neither SPEC-010 field is present
on an initial-stage frame, no SPEC-010 retention entry is created.

R-3.X.6 The coordinator MAY populate the internal `seenModels` index
from the union of `Provider.ModelID` and every entry in
`Provider.SupportedModels` per SPEC-010 v1.5 R-3.3.4 and R-3.4.1, but
v1.3.5 MUST NOT change dispatch outcomes. A request still requires an
otherwise eligible currently loaded provider; buyer HTTP behavior and
§5 routing results remain unchanged under all defaults.

### Tier 2 hook points summary

| Hook point | Location | Tier 1 behavior | Tier 2 behavior |
|---|---|---|---|
| `AttestationVerifier` | After hello parse, before pool registration | Skip (accept any Tier 1 provider) | Validate hardware attestation blob |
| `BuyerEncryptionRelay` | After router selects provider, before forwarding | Passthrough (plaintext request) | Forward encrypted payload without decryption |
| `TrustChainAuditor` | After response received from provider | No-op | Log full attestation chain for buyer verification |

Each hook point is a Go interface with a Tier 1 no-op struct
implementation. Tier 2 adds alternative implementations without
modifying the request pipeline.

---

## 4. Functional requirements

### Provider-side (matching SPEC-001 section 6.5)

**FR-P1. Accept WebSocket from provider.**
The coordinator listens on a configurable port (default: 8444) at path
`/ws/provider` for inbound WebSocket connections from Phase 3 binaries.

**Provider auth in v1: optional.** SPEC-001 v1.1.1 does not require
binaries to send credentials on WebSocket upgrade, and v1's trust model
comes from the operator's static `provider_id → endpoint_url` map (only
known providers can map to a forwarding URL anyway). The coordinator
therefore accepts the WebSocket upgrade with or without an
`Authorization` header in v1. After upgrade, it awaits the `hello`
message; trust is enforced by `provider_id` lookup in FR-P12.

When `auth.require_provider_tokens=true`, pinned providers must present
a valid `Authorization: Bearer <token>` header; missing, malformed,
invalid, or revoked tokens close the WebSocket with 4005
`invalid_token` (FR-P12). When the flag is false, bearer tokens are not
required for pinned providers.

Authenticated buyer-API and operator endpoints (sections 7.2, 7.4) still
require their own auth headers; this exemption is provider-side WebSocket
only.

**FR-P2. Validate hello message; respond hello_ack.**
On receiving a `hello` message (SPEC-001 section 6.5), the coordinator:
1. Validates that all REQUIRED fields are present and correctly typed:
   `type`, `version`, `tier`, `provider_id`, `hostname`, `model_id`,
   `model_params_b`, `ram_gb`, `max_context_tokens`, `max_concurrency`,
   `throughput_tps_estimate`, `binary_version`.
   OPTIONAL fields (`attestation`, `endpoint_url`) are validated when
   present. Absent `endpoint_url` MUST be normalized to null before
   passing to § 3 mode resolution; this preserves backward compatibility
   with v1.1.x binaries that do not include the field.
2. Checks `version` is 1 (the only supported protocol version).
3. Checks `tier` is 1 (FR-P13 rejects Tier 2 in v1).
4. Checks `provider_id` is not already registered in the active pool
   (duplicate ID = stale connection; close the older one).
5. Registers the provider in the pool with state `ready`.
6. Responds with `hello_ack`:
   ```json
   {
     "type": "hello_ack",
     "coordinator_version": 1,
     "assigned_id": "<pool-scoped-id>",
     "heartbeat_interval_s": 30
   }
   ```
   The `assigned_id` is a coordinator-assigned identifier (UUID) for
   this provider's pool session. It may differ from `provider_id` (which
   is the binary's self-assigned ID). The `heartbeat_interval_s` is
   configurable (default: 30 seconds).

After `hello_ack`, every provider-originated control/data frame is
authorized against the WebSocket session's `assigned_id`. If a stale
replaced socket later sends `heartbeat`, `state_update`,
`preflight_ack`, `inference_response_chunk`, or
`inference_response_end`, the coordinator MUST ignore it unless the
session `assigned_id` still matches the active pool entry for that
`provider_id`.

If any validation fails, the coordinator closes the WebSocket using a
standard application close code with a human-readable reason. SPEC-001
§ 6.5 defines `nak` as provider-to-coordinator only; the coordinator
does not send a wire-level `nak` to the provider. See "Provider
rejection via WebSocket close codes" later in this section for the full
close-code table.

For an invalid hello, the coordinator closes with code `4001` and
reason `"invalid_hello: <field>"` (e.g. `"invalid_hello: missing
model_id"`).

**FR-P3. Maintain provider pool entry with last-heard timestamp.**
Each provider pool entry tracks: `provider_id`, `assigned_id`,
`ws_conn`, `state`, `model_id`, `model_params_b`, `ram_gb`,
`max_context_tokens`, `max_concurrency`, `slots_free`, `slots_total`,
`throughput_tps_estimate`, `endpoint_url` (looked up from coordinator
static config keyed by `provider_id`; not from hello),
`last_heartbeat_at`, `connected_at`, `binary_version`. Updated on every
heartbeat and state_update from the active `assigned_id` session.
Removed on WebSocket disconnect (after grace period) or operator
blacklisting.

**FR-P4. Process heartbeat messages, update capacity state.**
On receiving a `heartbeat`, update `last_heartbeat_at`, dynamic fields
(`slots_free`, `slots_total`, throughput metrics), and static fields
(`model_id`, `model_params_b`, `ram_gb`, `max_context_tokens`,
`max_concurrency` — repeated per SPEC-001 so coordinator can
re-establish state after restart without new handshake). If `status`
differs from pool state, treat as implicit state_update.

**FR-P5. Process state_update: react to state transitions.**
On receiving a `state_update`, the coordinator validates `state` is one
of `ready`, `busy`, `degraded`, `draining`, `unavailable`, updates the
pool entry, and adjusts routing eligibility:

| State | Routing eligible | Behavior |
|---|---|---|
| `ready` | Yes | Normal operation |
| `busy` | No | All slots occupied; in-flight continues |
| `degraded` | No | Warm-up or partial failure; in-flight continues |
| `draining` | No | Provider shutting down; will close WS |
| `unavailable` | No | Fatal error; MAY close WS after 60s timeout |

Logs state transition with `reason` and `since` fields at info level.

**FR-P6. Process drain_status: stop routing to draining providers.**
On receiving a `drain_status` message (SPEC-001 section 6.5), the coordinator:
1. Logs the drain progress (`phase`, `inflight_requests`,
   `estimated_drain_seconds`).
2. If `phase` is `"complete"`, expects the provider to close the
   WebSocket imminently. The coordinator removes the provider from
   the pool after the WebSocket closes.
3. Does NOT forcefully close the WebSocket during drain — the
   provider controls when to close.

**FR-P7. Send preflight queries before routing context-heavy requests.**
Before forwarding, the coordinator sends a `preflight` message with the
estimated token count (bytes/4 heuristic). Preflight is REQUIRED for
`estimated_tokens > 4096`; skipped for smaller requests (latency).
Coordinator waits up to 5s for `preflight_ack`. Timeout: skip provider
for this request, try next candidate. Timeout does NOT mark provider
unhealthy. Rejection: log reason, remove from candidates, re-route. No
candidates remaining: return 503 to buyer.

**FR-P8. Send warm_up after detected wake event.**
The coordinator detects wake events by monitoring heartbeat gaps. If
`last_heartbeat_at` gap > 120s and a new heartbeat arrives, the
coordinator sends `{"type": "warm_up"}`, marks the provider `degraded`
(overriding the heartbeat's `ready` — Phase 2 D2 found -12% throughput
on first post-wake request), and waits for a `state_update` to `ready`
before routing. If no `state_update` arrives within
`pool.warmup_fallback_s` (default 60s), log a warning and allow routing
anyway.

**FR-P8a. Admission warm-up capability gate.**
If `pool.warmup_gate_enabled` is true (default), a newly connected
provider MUST NOT be buyer-routable immediately after `hello`. The
coordinator registers it as `degraded`, sends `hello_ack`, then starts a
capability probe. Probe transport follows the provider's forwarding
mode:

- WS-tunneled providers: send a minimal SPEC-001 `inference_request`
  over the provider WebSocket.
- HTTP-forwarding providers: send the same minimal OpenAI-compatible
  request as `POST {endpoint_url}/v1/chat/completions`. The coordinator
  MUST NOT send `inference_request` over the WebSocket to an
  HTTP-forwarding provider.

Probe payload:

- model: the `hello.model_id`.
- prompt: a small deterministic self-test prompt.
- `max_tokens`: `pool.warmup_gate_max_tokens` (default 2).
- non-streaming mode.

The provider passes only if the probe observes non-empty assistant
output and positive token usage (`usage.completion_tokens > 0`) within
`pool.warmup_gate_timeout_s` (default 90s). For WS-tunneled providers,
the terminal frame must be `inference_response_end` with
`status: "complete"`; for HTTP-forwarding providers, the HTTP response
must be 200 with an OpenAI-compatible response body. A self-reported
`throughput_tps_estimate`, a `ready` heartbeat/state update, or usage
metadata without observed output is never sufficient. A provider that
reports `ready` through heartbeat or `state_update` while the gate is
pending MUST remain non-routable until the token-producing probe passes.

On pass, coordinator marks the provider `ready` and buyer routing may
select it. On failure, timeout, provider disconnect, or zero-token
completion, coordinator logs `reason = "warmup_failed"`, leaves the
provider non-routable, and retries after `pool.degraded_backoff_s`,
doubling backoff between attempts up to `pool.degraded_max_retries`.
After all attempts fail, coordinator marks the provider `unavailable`.

If `pool.warmup_gate_enabled` is false, the coordinator preserves the
pre-v1.3.0 behavior: valid `hello` registers the provider as `ready`.
Operators MAY disable the gate only for trusted/pinned providers or
debug sessions where admission latency is more harmful than a false
ready signal.

**FR-P9. Send drain command on shutdown / blacklisting.**
The coordinator sends `{"type": "drain"}` when: (1) coordinator SIGTERM
(to all providers), or (2) operator blacklist (to specific provider).
After sending, marks provider `draining` and stops routing. Does NOT
close the WebSocket — waits for provider to send `drain_status` and
close when ready.

**FR-P10. Detect provider disconnect; remove from active pool.**
On WebSocket close, the coordinator marks the provider `unavailable` and
starts a grace period (configurable, default: 30s). If the provider
reconnects (same `provider_id`) within the grace period, the new
connection replaces the old entry seamlessly. If the grace period
expires, the provider is removed from the pool. In-flight buyer
requests to the disconnected provider fail with HTTP 502 (FR-B7). Clean
close after `drain_status: complete` is logged at info; all other
closes at warn.

**FR-P11. Distinguish provider failure modes.**
Informed by Phase 2 D1 (502 vs 530):

| Failure | Detection | Action | Recovery |
|---|---|---|---|
| WS disconnect (530-equivalent) | WS close, no prior drain | `unavailable`, grace period | Reconnects with new hello |
| dead-WS-graceful | Provider-initiated close frame while no drain is active | Active relays receive `provider_disconnected`; provider marked `unavailable` | Reconnects with new hello |
| dead-WS-abnormal | Read/write failure, or no inbound frame of any type for `pool.heartbeat_miss_threshold_s` (default 90s; in-flight response chunks count as activity) | Coordinator closes the session; active relays receive `provider_disconnected` | Reconnects with new hello |
| dead-WS-mid-inference | WS dies after `inference_request` was routed and before `inference_response_end` | Cancel the in-flight relay and either fail over once or return HTTP 502 `provider_disconnected` per F-4 | Buyer receives one response or one clean OpenAI-envelope error; no gateway-timeout hang. Counts toward the FR-P11a circuit-breaker. |
| relay-timeout-mid-inference | `routing.request_timeout_s` elapses with no `inference_response_end` (and no buyer cancel) | Cancel the relay; fail the request | Counts toward the FR-P11a circuit-breaker |
| zero-token-completion (qualified) | `inference_response_end` with `usage.completion_tokens == 0` AND `finish_reason` not in {`stop`,`length`} (abnormal). A clean empty `stop` does NOT count. | Return the result/error for this request | Counts toward the FR-P11a circuit-breaker |
| HTTP 502 (MLX down) | Provider returns 502 on routed buyer request | `degraded`, 30s backoff | Recovery preflight after 30s |
| HTTP 504 (timeout) | No response in time | `degraded`, 30s backoff | Same as 502 |
| **HTTP 530 (Cloudflare tunnel daemon disconnected)** | Provider endpoint returns literal HTTP 530 on routed buyer request | `unavailable` immediately; log `state_update.reason = "http_530_observed"`; close the active provider WebSocket | Removed from pool until WebSocket reconnects with fresh hello; provider-originated `ready` heartbeat/state updates MUST NOT restore this session |
| **HTTP 3xx redirect from provider endpoint** | Provider endpoint returns any 3xx response on a routed buyer request | Do not follow the redirect; mark `unavailable`; close the active provider WebSocket | Removed from pool until WebSocket reconnects with fresh hello after operator endpoint correction |

On degraded — whether from 502/504 or from the FR-P11a circuit-breaker —
after `pool.degraded_backoff_s` (default 30s) backoff, send a **recovery
preflight**. If accepted, mark `ready`. If rejected/timeout, extend the
backoff and retry up to `pool.degraded_max_retries` (default 3); after
that, mark `unavailable`. (`pool.degraded_backoff_s` and
`pool.degraded_max_retries` were defined since v1.1 but only wired into
this recovery cycle in v1.2.0; before that the backoff/retry counts were
hardcoded.)

**Literal HTTP 530 is normative in v1.** Phase 2 observed the M4
provider's Cloudflare tunnel emit HTTP 530 to a routed buyer request
while the WebSocket control plane briefly remained connected (mac
sleeping, cloudflared partially alive). The coordinator must treat this
as a stronger signal than 502: 502 is "mlx down, tunnel up, retry soon";
530 is "tunnel daemon itself disconnected, this provider is not
reachable until tunnel reconnects." The coordinator closes the active
provider WebSocket after marking the provider unavailable so stale
heartbeats or state updates cannot restore the old session; only a fresh
hello can re-admit the provider.

**Recovery preflight shape (SPEC-001-legal health probe):**
```json
{
  "type": "preflight",
  "request_id": "recovery-probe-<uuid>",
  "estimated_tokens": 128
}
```

This is a strict subset of SPEC-001 § 6.5's `preflight` schema — no extra
fields, no protocol extension. The `request_id` prefix `recovery-probe-`
is a coordinator-side convention that lets the coordinator (and any
operator inspecting logs) distinguish health probes from real buyer
requests by string match. The binary cannot and need not distinguish
them — recovery probes are processed identically to buyer preflights.

**Important:** the recovery preflight is NOT followed by an HTTP request.
The provider responds with `preflight_ack` indicating whether it would
accept a 128-token request; the coordinator interprets `accepted: true`
as "provider is healthy" and immediately marks `ready`. No buyer was
involved; the probe is purely diagnostic.

The provider's binary MUST NOT special-case recovery probes — it should
respond exactly as it would for any preflight (capacity check, no side
effects). The `recovery-probe-` prefix is observable only in the
provider's own logs; the binary still treats it as a normal preflight
under SPEC-001 § 6.5.

**FR-P11a. Provider circuit-breaker for in-flight inference faults.**
FR-P11's degrade/recover cycle originally fired only on HTTP 502/504 from
the HTTP-forwarding path. In WS-tunneled mode a provider can repeatedly
**fail in-flight requests** without ever returning a 502/504, so it stays
`ready` and keeps receiving buyer traffic. The coordinator MUST trip a
circuit-breaker so a persistently-faulting provider is removed from buyer
routing. **FR-P11a is the single source of truth for fault-driven
degradation in WS-tunneled mode** and supersedes FR-P20's former
"3 consecutive timeouts → degraded" clause.

- **Qualifying faults (count toward the breaker):**
  - *dead-WS-mid-inference* (F-4): provider WS dies after `inference_request`
    was routed and before `inference_response_end`.
  - *relay-timeout-mid-inference*: `routing.request_timeout_s` elapses with
    no `inference_response_end`, attributed to the provider per the
    attribution rule below.
  - *zero-token-completion (qualified)*: relay reaches `inference_response_end`
    with `usage.completion_tokens == 0` **AND** a `finish_reason` that is NOT
    a clean terminal value (`stop` or `length`). A clean empty completion
    (`finish_reason: "stop"`, zero tokens) is a VALID response and MUST NOT
    count.
- **Fault attribution (who is charged):** each qualifying fault is charged to
  exactly the provider whose relay produced it. F-4 may fail a request over
  once (A → B); that creates a *new* relay to B, so B's outcome is charged to
  B independently. A single dead-WS on A charges A exactly once — never
  twice, never B.
- **Excluded (MUST NOT count):** preflight rejection/timeout (FR-P7),
  graceful drain, and genuine buyer cancellation / client hangup.
  **Cancel-vs-timeout race rule (C2):** because the gateway's
  `coordinator_request_seconds` and the coordinator's `request_timeout_s` may
  be equal (both default 300s), a buyer-side context cancellation can race
  the relay timeout. The coordinator MUST use the observed relay error to
  disambiguate: a provider-side `relay-timeout-mid-inference` counts, while a
  buyer-context cancellation is excluded in both streaming and non-streaming
  paths, even if no chunks have been received yet. Operators SHOULD set the
  coordinator `request_timeout_s` strictly below the gateway
  `coordinator_request_seconds` so the coordinator's relay-timeout fires
  first and is unambiguously provider-attributable; with equal timers a
  gateway-initiated cancel can pre-empt the coordinator's timeout and an
  unfit provider may escape detection until a non-cancelled request times out.
- **Trip condition:** when a provider accumulates
  `pool.breaker_failure_threshold` (default 2) qualifying faults within a
  rolling `pool.breaker_window_s` (default 120s), the coordinator marks it
  `degraded` (routing-ineligible per FR-P5), logs
  `state_update.reason = "breaker_tripped"` with fault type and count, and
  runs the FR-P11 recovery cycle. The counter is per provider (a provider
  serves a single model). Simultaneous faults across a multi-slot provider
  from one wedge event each count, intentionally tripping immediately. The
  breaker applies to all tiers (pinned and provisional). Transition to
  `draining`/`unavailable` (any cause) clears the counter; a successful
  recovery to `ready` resets it to zero.
- **No flapping on a single blip:** the threshold + window are REQUIRED so a
  single transient fault does not degrade an otherwise-healthy provider — it
  fails only its own request (F-4) and leaves the provider `ready`.
- **Recovery preflight is liveness/capacity only.** The FR-P11 recovery
  preflight proves WS liveness + capacity, NOT token production — a provider
  degraded for zero-token/timeout faults may pass it and return to `ready`
  while still broken. To bound the resulting flap: the coordinator MUST
  record the timestamp of each successful breaker recovery to `ready`; a
  breaker trip whose triggering fault occurs within `pool.breaker_window_s` of
  that breaker-recovery timestamp is a **re-trip** and MUST mark the provider
  `unavailable` (removed until it reconnects with a fresh hello) instead of
  degrade-and-retry again. Generic `ready` transitions, including warm-up
  admission success and HTTP 502/504 recovery, MUST NOT create a breaker
  re-trip anchor. Provider-originated state changes (heartbeat status or
  `state_update`) MUST NOT clear or escape a coordinator-owned hold by ANY
  value: while a hold for the active session is live, a provider's
  self-reported state may only re-affirm `degraded`. In particular a held
  provider MUST NOT be able to launder back to routable by self-reporting
  `draining` (which would otherwise clear the hold) and then `ready`. Only a
  fresh session (reconnect, which starts a new admission warm-up) or the
  coordinator recovery path may clear a hold and return a held provider to
  `ready`.
- **No new wire messages:** routing exclusion, recovery preflight, and the
  observable fields it relies on (`usage.completion_tokens`, `finish_reason`,
  `inference_response_chunk` count) all already exist in SPEC-001 v1.2.4. The
  provider binary needs no change.

This is the runtime (reactive) half of provider fitness. The proactive half is
FR-P8a's admission-time warm-up capability gate, which withholds `ready` until
a provider proves it can produce a token.

**FR-P12. Identify provider; configurable bearer-token check.**

The coordinator supports two provider authentication modes, selected by
config field `auth.require_provider_tokens` (default: `false`).

When `auth.require_provider_tokens` is `false`:
- Pinned providers (those whose `provider_id` matches an entry in
  `config.providers[]`, see § 7.1 F-2) are admitted on `provider_id`
  match alone. The bearer token field in the WebSocket handshake is
  ignored.
- Provisional providers follow the provisional admission path in
  FR-P16 and § 7.5.

When `auth.require_provider_tokens` is `true`:
- Pinned providers MUST present a bearer token in the WebSocket
  handshake matching an operator-issued token registered for the same
  `provider_id` in the coordinator token store. A valid token issued for
  any other `provider_id`, or any missing/malformed/revoked token, MUST
  result in WS close 4005 `invalid_token`.
- Provisional providers continue to be admitted without a token. If a
  provisional provider presents a malformed or invalid bearer header,
  the coordinator MAY reject it before hello parsing because the tier is
  not known until after hello.

Tokens (when used) are 32-byte random (64 hex chars), stored as SHA-256
hashes (no plaintext). See Section 7.3.

The default `false` reflects the v1.1.2 tier-1 cooperative trust pool
(per § 2): pinned providers are trusted by `provider_id` alone, and the
token store exists for opt-in hardening. Operators who add a token store
SHOULD flip `require_provider_tokens` to `true` and re-issue tokens to
all pinned providers as one deployment step.

**Token re-issuance after `provider_id` binding (v1.3.1) — production
gate.** As of v1.3.1 tokens carry a `provider_id` subject and validation
MUST reject any token whose stored `provider_id` is empty. The schema
migration backfills every pre-binding token with an empty `provider_id`,
so **every token issued before v1.3.1 is now invalid and MUST be re-issued
(with `--provider-id`) before `require_provider_tokens` is set to `true`.**
Skipping this re-issuance reproduces the 2026-05-28 silent-`4005`
`invalid_token` outage (audit category I): pinned providers are rejected
at the WS handshake with no buyer-visible cause. Treat token re-issuance
as a hard pre-flip launch gate (§ 7.7).

**Implementation invariant:** every code path that depends on the token
validator being configured MUST also handle the case where it is not.
Failure to do so caused the 2026-05-28 production outage cited in audit
category I (see § 11).

**v1 security note.** With optional auth, anyone who learns a valid
`provider_id` and the coordinator's WebSocket URL could attempt to
connect. The coordinator's static config map is the gating mechanism —
only IDs listed in config can be admitted. For production trust beyond
v1, SPEC-001 will be amended to require token-based auth (path B
mandatory). Deploy v1 coordinator behind Cloudflare or similar so the
provider endpoint is not publicly enumerable.

**FR-P13. Reject Tier 2 providers via WebSocket close.**
If a provider's `hello` message contains `tier: 2` (or any value other
than 1), the coordinator closes the WebSocket with application close
code `4003` and reason `"tier_unsupported: coordinator v1 supports tier 1 only"`.

This is a clean rejection — the provider should not retry until
upgraded. The coordinator logs the rejection at info level.

**FR-P14. WS-tunneled inference relay.**
When routing a buyer request to a WS-tunneled provider (mode
resolution: § 3), the coordinator sends an `inference_request` message
(SPEC-001 v1.2 § 6.6) over the provider's WebSocket. For streaming:
each `inference_response_chunk` is translated into one SSE `data:`
line and flushed to the buyer immediately. For non-streaming: chunks
are accumulated until `inference_response_end`, then assembled into a
single HTTP response. The coordinator MUST NOT buffer streaming
chunks — each is relayed as it arrives to preserve time-to-first-token
fidelity.

**FR-P14.1. Status-to-buyer-HTTP mapping for WS-tunneled responses.**
When a WS-tunneled provider sends `inference_response_end`, the
coordinator maps the `status` field to buyer-facing behavior:

| `inference_response_end.status` | Coordinator buyer-facing behavior |
|---|---|
| `"complete"` | Relay final response to buyer with HTTP 200 |
| `"cancelled"` | Close buyer connection cleanly (buyer already disconnected) |
| `"error_model_not_loaded"` | Return HTTP 503 to buyer; do NOT try next provider |
| `"error_context_exceeded"` | Return HTTP 413 to buyer |
| `"error_queue_full"` | Return HTTP 503 to buyer; try next provider in candidates list |
| `"error_internal"` | Return HTTP 502 to buyer; do NOT try next provider |
| (no message received within `request_timeout_s`) | Return HTTP 504 to buyer |

**Provider-internal error messages MUST NOT appear in the buyer-facing
response body.** The coordinator uses generic error descriptions from
the standard OpenAI error envelope (§ 7.2). The `error` field in
`inference_response_end` is logged at the coordinator but not forwarded.

**`error_queue_full` is the only status that triggers re-routing.**
On receiving `error_queue_full`, the coordinator treats this provider
as temporarily full and continues iterating through the § 5 candidate
list. All other error statuses result in an immediate error response
to the buyer per FR-B7 (no silent retry in v1).

**FR-P15. Admission tier assignment.**
The coordinator recognizes three admission tiers:

| Tier | Source | Admission | Routing weight |
|---|---|---|---|
| Pinned | `config.providers[]` | Operator pre-approved | 1.0 |
| Provisional | Unknown `provider_id` | Auto on hello, rate-limited | 0.3 (configurable) |
| Rejected | `rejected_providers` table | Never. WS close 4009. | N/A |

**FR-P16. Provisional admission rate limits.**
- Per-hour admission rate: max 10 new provisional providers per hour
  (sliding window). 11th → WS close 4008. Rationale: 10/hr allows
  ~240/day; at 40 KB per-connection state, 240 = ~9.6 MB on the
  3.8 GB Pearl VPS. Config: `admission.provisional_rate_per_hour`.
- Total provisional pool size: max 100 simultaneous. 101st → WS close
  4007. Rationale: 100 × 40 KB = 4 MB. Config:
  `admission.max_provisional_providers`.
- Per-provisional-provider request quota: max 100 buyer requests per
  hour. Over quota → skip provider in routing (invisible to buyer).
  Rationale: 100 req/hr at ~2.5 s each = ~4 min active inference,
  ~7% utilization. Config:
  `admission.provisional_request_quota_per_hour`.

**FR-P17. Provisional admission persistence.**
Provisional admissions are persisted to SQLite:

```sql
CREATE TABLE provisional_providers (
    provider_id TEXT PRIMARY KEY,
    first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_seen_at TEXT NOT NULL,
    hostname TEXT,
    model_id TEXT,
    binary_version TEXT,
    total_requests_served INTEGER NOT NULL DEFAULT 0,
    total_tokens_served INTEGER NOT NULL DEFAULT 0,
    promoted_at TEXT DEFAULT NULL,
    notes TEXT DEFAULT NULL
);

CREATE TABLE rejected_providers (
    provider_id TEXT PRIMARY KEY,
    rejected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    reason TEXT,
    rejected_by TEXT NOT NULL DEFAULT 'operator'
);
```

On restart, providers with `last_seen_at` older than 30 days are not
pre-loaded (configurable: `admission.provisional_retention_days`).
`rejected_providers` is always loaded — bans are permanent until
operator removes the row.

**FR-P18. WS-tunneled cancellation propagation.**
When a buyer disconnects mid-stream for a WS-tunneled request, the
coordinator detects the broken connection within 1 second, sends
`cancel_request` (SPEC-001 v1.2 § 6.6) to the provider, and frees the
request slot on `inference_response_end` or after 10 seconds (whichever
first). The coordinator MUST NOT close the WebSocket or mark the
provider unhealthy due to a slow cancellation.

**FR-P18.1. Request ID lifecycle (coordinator-side).**
The coordinator maintains an active request_id map per provider WS
connection. The following rules are normative:

1. **Unknown request_id.** If the coordinator receives an
   `inference_response_chunk` or `inference_response_end` with a
   `request_id` it did not issue (or that has already been cleaned up),
   the coordinator MUST log at warn level and discard the frame. MUST
   NOT propagate to any buyer. MUST NOT close the WebSocket.

2. **Duplicate active request_id.** The coordinator MUST NEVER reuse
   a `request_id` while the prior request with that ID is still
   in-flight. The UUID format of `request_id` makes accidental
   collision negligible.

3. **Cleanup.** The coordinator removes a `request_id` from its active
   map after receiving `inference_response_end` OR after
   `routing.request_timeout_s` expires (default 300 s).

See also SPEC-001 v1.2.4 § 6.6 "Request ID lifecycle and error
handling" for the provider-side rules.

**FR-P19. WS-tunneled backpressure — coordinator write buffer.**
Bounded write buffer of 64 messages per provider WebSocket. If full,
return HTTP 503 to buyer. Do NOT block the buyer goroutine. Do NOT
mark provider degraded. Config: `ws.write_buffer_size`.

Rationale: 64 messages at ~100 KB avg = ~6.4 MB, within coordinator
memory budget. Buffer absorbs brief TCP congestion.

**FR-P20. WS-tunneled response timeout.**
Per outstanding `inference_request`, coordinator starts a timer of
`routing.request_timeout_s` (default 300 s). On timeout: send
`cancel_request`, return HTTP 504 to buyer, free slot. The timeout counts
as a `relay-timeout-mid-inference` fault toward the **FR-P11a** circuit-breaker,
which (as of v1.2.0) is the single source of truth for timeout-driven
degradation and **supersedes** the former "3 consecutive timeouts → degraded"
rule.

**FR-P21. Tier visibility in /poolz.**
The `/poolz` response (FR-O2) gains `tier` (`"pinned"` or
`"provisional"`) and `inference_path` (`"http_forwarding"` or
`"ws_tunneled"`) fields per provider entry.

### Provider rejection via WebSocket close codes

Because SPEC-001 § 6.5 does not define a coordinator-to-provider `nak`
direction, all coordinator-initiated rejections use standard WebSocket
application close codes (RFC 6455, range 4000–4999). The provider's
binary already handles WebSocket close per SPEC-001 FR-13.

| Close code | Name | Sent when | Reason text format |
|---|---|---|---|
| `4001` | `invalid_hello` | Required field missing or malformed | `"invalid_hello: <field>"` |
| `4002` | `unknown_provider_id` | `provider_id` not in coordinator config map | `"unknown_provider_id: <id>"` |
| `4003` | `tier_unsupported` | `tier != 1` | `"tier_unsupported: tier <n> not supported"` |
| `4004` | `version_unsupported` | `version != 1` | `"version_unsupported: protocol version <n>"` |
| `4005` | `invalid_token` | Token validation is required and bearer token is absent, malformed, invalid, revoked, or valid for a different `provider_id` | `"invalid_token"` |
| `4429` | `pool_full` | Coordinator at configured max provider count | `"pool_full"` |
| `4007` | `provisional_pool_full` | Provisional provider connects when provisional pool at capacity | `"provisional_pool_full: max <N> provisional providers reached"` |
| `4008` | `provisional_rate_limited` | Provisional admission rate exceeded | `"provisional_rate_limited: max <N> admissions per hour"` |
| `4009` | `banned` | Provider's `provider_id` in `rejected_providers` table | `"banned: provider <id> has been rejected by operator"` |

**v1.1 amendment — close code 4002 retired.** In v1.0.x, close code
4002 `unknown_provider_id` rejected any `provider_id` not in
`config.providers[]`. In v1.1, unknown `provider_id` values are
admitted as provisional (subject to rate limits) or rejected with 4009
if banned. Close code 4002 is no longer sent by v1.1+ coordinators.

**F-2 amendment (v1.1, from SPEC-003 v0.1 § 6.4).** The original F-2
("every provider_id must be in config.providers[]") is relaxed:
`config.providers[]` remains the mechanism for pinned tier admission.
Unknown `provider_id` values are accepted as provisional (subject to
rate limits in FR-P16) or rejected with 4009 if in the
`rejected_providers` table.

**F-4 — Dead provider WebSocket during in-flight inference MUST
fast-fail or fail over.** If a provider WebSocket transitions to dead
while a buyer request is in flight, the coordinator MUST detect the
condition within `routing.failover_timeout_s` for observed close/write
failures, or within `pool.heartbeat_miss_threshold_s` for silent
(half-open) sockets that stop producing inbound frames. The liveness
monitor MUST measure staleness from the last inbound frame of ANY type
(heartbeat OR in-flight inference response), not heartbeats alone: a
provider actively streaming a long single-slot generation is alive even
though it cannot emit heartbeats while its slot is busy, and MUST NOT be
closed for "missed" heartbeats. `pool.heartbeat_miss_threshold_s`
(default 90s) MUST be generous relative to `pool.heartbeat_interval_s`
and is independent of `routing.failover_timeout_s` (which governs
replacement selection, not liveness). It MUST then either reroute the request
once to a different ready provider running the same model when
`routing.failover_enabled` is true and such a provider has free slots,
or return HTTP 502 with error code `provider_disconnected` and the
request id in logs. For streaming responses, failover is allowed only
before HTTP status/body bytes are committed; after a chunk has been
emitted, dead-WS failure MUST mark the provider unavailable and
terminate the SSE stream with an error event whose code is
`provider_disconnected`. **(v1.4.0, issue #92):** "committed" is
defined as "the coordinator has observed a complete, well-formed
first OpenAI-compatible SSE event from the provider — a `data:` line
with a JSON object carrying either `choices[].delta` with at least
one of `content`, `role`, `refusal`, `reasoning`, `tool_calls`,
`function_call` (value-typed: strings non-empty, arrays/objects
non-empty), `choices[].message` (same allowlist), `choices[].finish_reason`
(non-empty string), OR a top-level `usage` object with non-negative
integer `completion_tokens` AND one of `prompt_tokens` / `total_tokens`,
all within `maxRequestLogUsageTokens`". Anything weaker — a 200 status
line without body, a single byte, an SSE comment-only event, a
`data: [DONE]` terminator-only event, metadata-only JSON, or an
arbitrary-key delta/message — is NOT committed; the coordinator MUST
return `wsForwardProviderDisconnected` and failover (subject to the
same `failover_enabled` + pin rules). The buyer-visible consequence
is that HTTP response headers wait for the first commit-worthy event;
buyer clients MUST tolerate up to `coordinator_request_seconds` of
TTFT and gateway `coordinator_header_timeout_seconds` MUST be set
accordingly (>= `coordinator_request_seconds`). Explicit `X-MacProvider-Provider` and
`X-MacProvider-Session` pins MUST NOT fail over because the buyer
requested that provider/session. The buyer MUST receive one coherent
response or one clean OpenAI-compatible error envelope; the buyer MUST
NOT observe a hung connection waiting on the gateway timeout.

Codes are mnemonic (4000-range maps to "rejected") and the reason text
provides operator-visible detail. Provider binaries log the close code
and reason per SPEC-001 standard logging; no special parsing required.

**WS-close logging requirement (v1.1.3).** The coordinator MUST emit a
WARN-level log entry for every provider WebSocket close it initiates,
including the numeric close code (for example `4005`) and a short
human-readable reason string (for example `"invalid_token"`,
`"drain_complete"`, or `"heartbeat_timeout"`). This requirement exists
because silent close paths conceal production-breaking misconfiguration.
A coordinator-initiated close is, by definition, a decision the
coordinator made; it MUST be observable in the coordinator's own logs
without correlating against external proxy logs.

When known at close time, close logs SHOULD also include the provider's
`provider_id` and remote address. The v1.1.3 hotfix implementation logs
`close_code` and `reason`; passing provider and remote context into the
shared close helper is a follow-up hardening item, not required for
v1.1.3 spec conformance.

### Buyer-side

**FR-B1. /v1/models endpoint returns aggregated model list.**
`GET /v1/models` returns a JSON response listing all unique models
available across the provider pool. Each model appears once, regardless
of how many providers serve it. The response shape matches the OpenAI
models endpoint:

```json
{
  "object": "list",
  "data": [
    {
      "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "object": "model",
      "created": 1716768000,
      "owned_by": "macprovider",
      "provider_count": 2,
      "max_context_tokens": 50000,
      "total_slots": 4,
      "degraded": false
    },
    {
      "id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "object": "model",
      "created": 1716768000,
      "owned_by": "macprovider",
      "provider_count": 1,
      "max_context_tokens": 20000,
      "total_slots": 1,
      "degraded": true
    }
  ]
}
```

The `provider_count`, `max_context_tokens` (maximum across providers
for that model), `total_slots` (sum across providers), and `degraded`
fields are non-standard extensions. Standard OpenAI clients will ignore
them.

A model is `degraded: true` if any of:

- all providers for this model are state `unavailable` or `draining`.
- fewer than 50% of registered providers for this model are `ready`.
- all providers' `slots_free` for this model equal 0.

Otherwise the model is `degraded: false`. SPEC-006 v0.3 gateway status
aggregation MUST use these same rules.

`created` is the coordinator's start time as a Unix timestamp.

If the pool is empty (no providers connected), the response is:
```json
{
  "object": "list",
  "data": []
}
```

This returns HTTP 200 with an empty list — not 503. The buyer should
check the list before sending requests.

**FR-B2. /v1/chat/completions (non-streaming).**
`POST /v1/chat/completions` with `stream: false` (or `stream` omitted)
accepts a standard OpenAI chat completion request per SPEC-001
section 6.2. The coordinator:
1. Validates the request schema (same validation as SPEC-001 section 6.2,
   steps 1-6).
2. Runs the routing algorithm (Section 5) to select a provider.
3. Optionally sends a preflight check to the selected provider (FR-P7).
4. Forwards the request as an HTTP POST to the provider's endpoint.
5. Receives the provider's JSON response.
6. Returns it to the buyer unmodified (the provider's response is
   already SPEC-001 section 6.2 compliant).

The coordinator adds two response headers:
- `X-MacProvider-Provider`: the stable `provider_id` of the provider
  that served the request (operator-meaningful identity).
- `X-MacProvider-Route`: the session `assigned_id` of the WebSocket
  session that served the request (for log correlation).

Full header list in § 7.2.

**FR-B3. /v1/chat/completions (streaming).**
`POST /v1/chat/completions` with `stream: true` returns an SSE stream.
The coordinator:
1. Validates and routes as in FR-B2.
2. Forwards the request to the provider with `stream: true`.
3. Receives the provider's SSE stream.
4. Relays each SSE event to the buyer in real-time (chunk-by-chunk
   passthrough).
5. Adds both `X-MacProvider-Provider` (stable provider_id) and
   `X-MacProvider-Route` (session assigned_id) response headers, same
   as FR-B2. See § 7.2 for full header list.

The coordinator does NOT buffer the entire stream — it relays each
`data: {...}` line as it arrives from the provider. This preserves
time-to-first-token fidelity.

**FR-B4. Route request to best provider.**
The coordinator selects a provider using the routing algorithm defined
in Section 5. If no eligible provider exists, the coordinator returns
HTTP 503:
```json
{
  "error": {
    "message": "No provider available for model mlx-community/Qwen2.5-7B-Instruct-4bit",
    "type": "service_unavailable",
    "code": "no_provider_available"
  }
}
```

**FR-B5. Preflight check before forwarding context-heavy requests.**
See FR-P7. Invisible to the buyer (adds latency only). If preflight
fails and no fallback exists, buyer receives 503 with rejection reason.

**FR-B6. Forward SSE stream from provider to buyer transparently.**
The coordinator relays SSE events without modification:
- Sets `Content-Type: text/event-stream; charset=utf-8`.
- Sets `X-Accel-Buffering: no` and `Cache-Control: no-cache`.
- Flushes each SSE event immediately.
- Passes through `data: [DONE]` and closes.

If the provider disconnects mid-stream, the coordinator emits:
```
data: {"error":{"message":"Provider disconnected during streaming","type":"server_error","code":"provider_disconnected"}}

data: [DONE]

```
Then closes the buyer's response and logs the failure.

**FR-B7. Clean error on provider failure mid-request — no retry in v1.**
If the selected provider fails at any point (connection error, 502, 504,
mid-stream disconnect), the coordinator does NOT retry with a different
provider. The buyer receives:

- **Streaming requests** (response headers already sent): error SSE event
  emitted (see FR-B6), then `data: [DONE]` and stream close.
- **Non-streaming requests** (no response bytes sent yet): HTTP 502 with
  body
  ```json
  {"error":{"message":"Selected provider failed; buyer should retry","type":"upstream_error","code":"provider_failed"}}
  ```

The buyer (or coordinator-aware client) decides whether to retry. This
preserves idempotency, attribution, and clean debugging in v1.

Visible retry policies (e.g. coordinator-managed retry with explicit
`X-MacProvider-Retry` header) are deferred to SPEC-004 (smart router)
or SPEC-006 (public API), where buyer expectations differ.

**FR-B8. Return HTTP 503 with descriptive body if no provider available.**
See FR-B4 for the response shape. Additional 503 scenarios:
- All providers for the requested model are `busy`, `degraded`,
  `draining`, or `unavailable`.
- All providers rejected the preflight check.
- The requested model is not served by any provider.

**FR-B9. Log every buyer request.**
Every buyer request is logged to the `request_log` table in SQLite:

| Column | Type | Description |
|---|---|---|
| `id` | INTEGER PK | Auto-increment |
| `ts_utc` | TEXT | ISO 8601 timestamp |
| `request_id` | TEXT | Coordinator-internal request/billing id (NOT the inbound `X-Request-ID`). On the non-pinned retry path multiple `request_log` rows for one logical buyer request share this value; pinned-client retries get distinct values. |
| `external_request_id` | TEXT NULL | Inbound `X-Request-ID` header value. Shared across all `request_log` rows for one logical request and across the gateway's `usage_events.request_id` for the same logical request, enabling end-to-end billing reconciliation. NULL when the inbound request carried no `X-Request-ID`. (v1.4.2 R-2; formally documented here.) |
| `account_id` | TEXT NULL | (v1.5.0) Gateway account id propagated via `X-MacProvider-Account` on the gateway → coordinator forward. NULL on legacy rows and on direct legacy buyer calls without the header. The composite `(account_id, external_request_id)` is the reconciliation key joining to gateway `usage_events`; `external_request_id` alone is a logical join key only. |
| `model` | TEXT | Requested model. **Sanitized at the buyer-handler boundary (v1.5.1):** valid-UTF-8 only; C0 / DEL / C1 codepoints stripped via `sanitizeRequestLogText`. The same sanitizer applies to `error`, `pref_header`, `provider_header` below. |
| `provider_assigned_id` | TEXT | Pool ID of serving provider (null if 503) |
| `prompt_tokens` | INTEGER | From provider response usage (null if failed) |
| `completion_tokens` | INTEGER | From provider response usage (null if failed) |
| `total_tokens` | INTEGER | prompt + completion |
| `latency_ms` | REAL | Total wall time including routing |
| `routing_ms` | REAL | Time spent in routing + preflight |
| `queue_wait_ms` | REAL | Coordinator-side bounded slot queue wait for this attempt; 0 when no slot queue wait occurred |
| `status` | INTEGER | HTTP status returned to buyer |
| `stream` | INTEGER | 1 if streaming, 0 if not |
| `buyer_ip` | TEXT | Buyer's IP (for rate limiting in future) |
| `error` | TEXT | Error message if failed (null if success) |
| `error_code` | TEXT | SPEC-001 v1.2.4 status enum on failed responses (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`); NULL on success or non-SPEC-001 error paths |
| `pref_header` | TEXT | Value of X-MacProvider-Pref if present |
| `provider_header` | TEXT | Value of X-MacProvider-Provider if present |
| `retried` | INTEGER | Always 0 in v1 (no coordinator-managed retry). Column reserved for SPEC-004 / SPEC-006 retry policies. |
| `attempt_n` | INTEGER NULL | (v1.5.2) Zero-based monotonic attempt ordinal within the same `(account_id, request_id)` group under SQLite `IS` semantics. Populated at INSERT time by the writer via `COUNT(*) FROM request_log WHERE account_id IS ? AND request_id = ?` in the same transaction. NULL only on legacy rows written before v1.5.2 (or written during a v1.5.2 → v1.5.1 rollback window); SPEC-005 v0.3.3 read-side falls back to id-ASC derivation for NULL rows during the migration window. Backfilled by the operator subcommand `coordinator backfill-attempt-n`. |

Token counts are extracted from the provider's response `usage` field.
For streaming responses, they come from the usage chunk (SPEC-001 FR-7).

Each provider attempt for a given `request_id` MUST produce its own `request_log` row. The only uniqueness constraint is on (`id`). `request_id` MAY recur across rows when SPEC-004 retry logic produces multiple attempts within a single account. Note that `request_log.request_id` is coordinator-internal (server-minted UUID v4 per buyer request — see `requestIDForBuyerRequest()`); it is NOT the inbound `X-Request-ID` (which is persisted as `external_request_id`). The cross-account collision class motivating #211 lives on `external_request_id`, not on internal `request_id`. The `retried` column counts additional explicit-retry attempts beyond the first per SPEC-004 v0.3.1.

**Attempt ordinal (v1.5.2).** The canonical attempt ordinal within a single `(account_id, request_id)` group is `request_log.attempt_n` — a zero-based monotonic integer populated at INSERT time by the writer (`COUNT(*) FROM request_log WHERE account_id IS ? AND request_id = ?` in the same transaction; the single-writer pool cap from #21 / ARCH-3 makes this race-free). For legacy NULL-`attempt_n` rows (written pre-v1.5.2 or during a rollback window), the read-side falls back to id-ASC derivation within the same `(account_id, request_id)` group under SQLite `IS` clustering — the same arithmetic the writer would have produced, so backfilled and derivation-time ordinals are byte-identical. Account scoping is defense-in-depth so that if a UUID v4 collision or future schema change ever causes the same internal `request_id` to appear in rows from different accounts, each account's attempt sequence is computed within its own scope. This contract is load-bearing for SPEC-005 v0.3.3 multi-attempt attribution.

`request_id` MUST be indexed. Any service in the request path that fails to propagate `X-Request-ID` degrades cross-layer debuggability; new buyer/request log surfaces MUST include X-Request-ID propagation.

```sql
CREATE INDEX idx_request_log_ts_utc ON request_log(ts_utc);
CREATE INDEX idx_request_log_request_id_id ON request_log(request_id, id);
-- v1.4.2 R-2 (external_request_id) + v1.5.0 (account-scoped reconciliation):
CREATE INDEX idx_request_log_external_request_id ON request_log(external_request_id)
    WHERE external_request_id IS NOT NULL;
CREATE INDEX idx_request_log_account_external_request_id ON request_log(account_id, external_request_id)
    WHERE account_id IS NOT NULL AND external_request_id IS NOT NULL;
```

The `idx_request_log_ts_utc` index supports SPEC-005 v0.3 reconciliation scans (24h startup, 7d nightly, ad-hoc admin ranges) at 10K-provider scale. The composite `(request_id, id)` index supports the SPEC-005 § 8.2 attempt-ordinal fallback and SPEC-004 multi-attempt log queries. The partial-NULL `external_request_id` and `(account_id, external_request_id)` indexes support closing-the-books reconciliation joins to gateway `usage_events` and `audit_events` (whether run as out-of-process harnesses or via a future coordinator-hosted reconciliation endpoint).

Migration: existing deployments MUST apply `ALTER TABLE request_log ADD COLUMN error_code TEXT NULL`, `ALTER TABLE request_log ADD COLUMN external_request_id TEXT NULL` (v1.4.2 R-2), `ALTER TABLE request_log ADD COLUMN account_id TEXT NULL` (v1.5.0), `ALTER TABLE request_log ADD COLUMN attempt_n INTEGER NULL` (v1.5.2), and `ALTER TABLE request_log ADD COLUMN queue_wait_ms REAL NOT NULL DEFAULT 0` (v1.5.3), and create the four indexes above. The two partial-NULL reconciliation indexes are built via `coordinator migrate-indexes`, NOT from daemon startup. The `attempt_n` column requires no index (it is a per-row ordinal, not a join key); the operator backfill subcommand `coordinator backfill-attempt-n` populates legacy NULL rows once per deployment.

**Per-key migration-state machine (v1.5.1).** Because ALTER TABLE migrations run at daemon startup but the partial-NULL composite indexes are built only by the operator subcommand `coordinator migrate-indexes`, each composite reconciliation key on `request_log` has its OWN three-state migration:

| State | Column(s) | Index | Meaning |
|---|---|---|---|
| `legacy` | absent | n/a | pre-migration; exact composite-key reconciliation unavailable |
| `unindexed` | present | absent | rollout incomplete; exact reconciliation **available** but unindexed |
| `indexed` | present | present | steady-state |

The state machine is PER-KEY because v1.4.2 R-2 (`external_request_id`) and v1.5.0 (`account_external_request_id`) added their composite indexes at different points in time; the same deployment may be at different states on each. The aggregate `migration_state` across all keys is `legacy` if ANY key is legacy; `indexed` only if EVERY key is indexed; `unindexed` otherwise. **`unindexed` is NOT legacy** — exact composite-key reconciliation is available but unindexed (full-scan), and reconciliation tooling MUST distinguish it. Reconciliation tooling MUST introspect BOTH `PRAGMA table_info(request_log)` (column presence) AND `sqlite_master` (index presence) per key. The canonical state vocabulary is `"legacy" | "unindexed" | "indexed"` — tooling MUST emit these literal strings.

**Machine-readable state surface (v1.5.1).** The coordinator exposes per-key migration state via `coordinator migrate-indexes --check --format json` (a read-only sibling of the existing build path), backed by `requestlog.Store.MigrationState`. JSON shape:

```json
{
  "migration_state": "unindexed",
  "keys": [
    { "key": "external_request_id", "column_names": ["external_request_id"], "columns_present": true, "index_name": "idx_request_log_external_request_id", "index_present": false, "state": "unindexed" },
    { "key": "account_external_request_id", "column_names": ["account_id", "external_request_id"], "columns_present": true, "index_name": "idx_request_log_account_external_request_id", "index_present": false, "state": "unindexed" }
  ]
}
```

**State `unindexed` operational binding (v1.5.1).** **Scope is defined by data-surface contract, not process placement:**

- **In scope (MUST fail closed on state `unindexed`/`legacy`):** any reconciliation surface that performs **closing-the-books joins** between coordinator `request_log` and gateway `usage_events` / `audit_events` by the composite reconciliation key — the SPEC-005 v0.3+ closing-the-books contract. This includes both out-of-process harnesses (e.g. nightly reconciler, issue #226 harness) AND any future coordinator-hosted endpoint that exposes the same join (e.g. a hypothetical `/admin/explorer/reconcile` returning cross-table joined rows for external auditors).
- **Out of scope (MUST NOT fail closed during the `unindexed` rollout window):** coordinator's own in-process AttemptN derivation paths — `internal/billing/hotpath.go`, `internal/billing/recovery.go`, `internal/billing/endpoints.go` `/admin/ledger/reconcile`. These derive attempt ordinals via SQLite `IS` clustering on `(account_id, request_id)` over a single table (`request_log`); they do NOT join gateway tables. They are correct (just unindexed-slow) under state `unindexed`, and the daemon-startup `legacy → unindexed` rollout window is by design a transient state the daemon serves traffic in.

In-scope tooling MUST fail closed when it observes state `unindexed` (or `legacy`) for a composite key it depends on, until the operator runs `coordinator migrate-indexes`. Tooling MAY support an explicit `--allow-unindexed-scan` override (bounded by row-count or wall-clock budget) for fixture, dev, or one-shot recovery use; the override MUST NOT be the default. Silently falling back to fuzzy match under state `unindexed` is a SPEC violation — it conflates with state `legacy` and hides an operator-action gap.

**Expected operator workflow.** Daemon startup applies ALTER TABLE migrations (`legacy → unindexed`), then operator runs `coordinator migrate-indexes` (`unindexed → indexed`). The `migrate-indexes` subcommand also calls `requestlog.OpenStore` and so applies any pending ALTER TABLE migrations itself before building indexes; running it against a `legacy` DB takes the schema directly to `indexed` in one invocation.

**Deploy ordering (v1.5.0).** Coordinator MUST be deployed first; it accepts and persists `X-MacProvider-Account` whether or not the gateway sends it. Gateway then deploys with the unconditional header. Auditor tooling MUST detect the boundary at row granularity (not schema granularity): rows with NULL `account_id` are either (a) pre-v1.5.0-coordinator rows, (b) v1.5.0-coordinator rows from a pre-v0.9.1 gateway, or (c) v1.5.0-coordinator rows written during a v1.4.x rollback window where the column existed but the writer didn't populate it. In all three cases the join MUST fall back to the prior `external_request_id`-only key and accept the documented ambiguity. Tooling MUST NOT use `PRAGMA table_info(request_log)` column-presence as a switch — that would misclassify rollback-window rows as scoped-ready. Use `account_id IS NOT NULL` as the per-row gate instead.

**Money-path: AttemptN read-side discipline (v1.5.2; supersedes v1.5.0 derivation rule).** `internal/billing/hotpath.go`, `internal/billing/recovery.go`, and `internal/billing/endpoints.go` admin-reconcile MUST read `request_log.attempt_n` (SPEC-002 v1.5.2 monotonic ordinal, populated at INSERT time) when non-NULL. For legacy NULL-`attempt_n` rows (pre-v1.5.2 OR rollback window), the read-side falls back to the v1.5.0 COUNT-based derivation over `request_log` rows sharing the same `(account_id, request_id)` group — same arithmetic the writer would have persisted, so backfilled and derivation-time ordinals are byte-identical. **Note on identity:** `request_log.request_id` is the coordinator-internal billing id (server-minted UUID v4 per buyer request — see `requestIDForBuyerRequest()`), NOT the inbound `X-Request-ID` (which is persisted as `external_request_id`). The buyer-supplied collision class motivating #211 lives on `external_request_id` and is fully addressed by the composite `(account_id, external_request_id)` reconciliation key; it does NOT naturally manifest as collisions on internal `request_id`. Account-scoping the AttemptN derivation (whether persisted at INSERT time under v1.5.2 OR computed at read time under the v1.5.0 fallback) by `(account_id, request_id)` using SQLite `IS` semantics is defense-in-depth — it ensures that if a UUID v4 collision, a misconfigured retry path, or any future schema-level change ever causes the same internal `request_id` to appear in `request_log` rows belonging to different accounts, each account's first attempt is correctly counted within its own scope. All three sites MUST use identical `IS` semantics so the same row gets the same `AttemptN` regardless of which path scans it. The pre-v1.5.0 same-account multi-attempt grouping (legacy NULL-`account_id` rows cluster among themselves) is preserved exactly. **Quarantine class (v0.3.3): only `attempt_n=1` with `retried=0` is quarantined — see SPEC-005 v0.3.3 §15.2; the v0.3.1 "row 3+ MUST quarantine" rule is satisfied in both the persisted and fallback paths.**

### Routing logic

**FR-R1. Default selection: model match, utilization-favoring.**
The default routing algorithm selects a provider whose `model_id`
matches the request's `model` field exactly. If multiple providers
serve the same model, the coordinator prefers the one with the lowest
positive `slots_free` (utilization-favoring). This concentrates load on
fewer providers, leaving others fully idle for sleep/power savings.

Full algorithm in Section 5.

**FR-R2. Capacity preference via buyer header.**
The buyer can hint routing preference via the `X-MacProvider-Pref`
request header:

| Value | Meaning | Selection effect |
|---|---|---|
| `fast` | Maximize throughput | Prefer highest `throughput_tps_estimate` |
| `accurate` | Maximize model quality | Prefer highest `model_params_b` |
| (absent) | Default | Utilization-favoring (FR-R1) |

Unknown values are silently ignored (treated as absent).

**FR-R3. Provider pinning via buyer header.**
The buyer can pin to a specific provider via
`X-MacProvider-Provider: <provider_id>`. **The header value is the
stable `provider_id`** (the identifier the provider sends in `hello`,
matched by the coordinator's static config map). This is the
operator-meaningful identity that survives reconnects.

If a buyer needs to pin a specific WebSocket session for short-lived
debugging (e.g. "this exact instance, this run"), they may send
`X-MacProvider-Session: <assigned_id>` instead. The coordinator
resolves session ID to the current pool entry; if the session has ended,
returns 503 with `code: "session_ended"`.

If `X-MacProvider-Provider` is sent and the named provider is in the
pool in `ready` state with `slots_free > 0`, the coordinator routes to
it directly (bypassing the selection algorithm). If the pinned provider
is unavailable, the coordinator returns 503 (does NOT fall back — the
buyer explicitly requested this one).

If both headers are sent, `X-MacProvider-Session` takes precedence (more
specific). `/poolz` shows both `provider_id` and `assigned_id` for each
entry.

**FR-R4. Pool filtering: only ready providers with free slots.**
Before running the selection algorithm, the coordinator filters the pool
to only include providers where:
- `state` is `ready`
- `slots_free > 0`
- `model_id` matches the request's `model` field

**FR-R5. Context length check.**
The coordinator estimates the request's token count (bytes / 4
heuristic) and excludes providers whose `max_context_tokens` is less
than the estimated count. For requests where `estimated_tokens > 4096`,
the authoritative check is the preflight (FR-P7) — but the coordinator
pre-filters to avoid sending preflights to providers that will
obviously reject.

**FR-R6. Tier scope check.**
In v1, all providers are Tier 1 and all buyers are Tier 1. This check
is a no-op but exists as a hook point: in Tier 2, the coordinator would
match buyer trust requirements to provider attestation levels.

### Operations

**FR-O1. /healthz endpoint.**
`GET /healthz` returns coordinator self-health:

```json
{
  "status": "ok",
  "uptime_s": 3600,
  "pool_size": 3,
  "pool_ready": 2,
  "pool_degraded": 1,
  "pool_draining": 0,
  "pool_unavailable": 0,
  "requests_total": 1420,
  "requests_active": 2,
  "version": "0.1.0"
}
```

Returns HTTP 200 if the coordinator is running. Returns HTTP 503 if
the coordinator is draining (SIGTERM received).

No authentication required — intended for VPS-side monitoring
(systemd, uptime checks).

**FR-O2. /poolz endpoint (operator-only, auth-gated).**
`GET /poolz` returns the full pool state, including per-provider
details. Requires an operator API key in the `Authorization` header
(`Bearer <operator-key>`). The operator key is configured in the
coordinator's config file (not the same as provider tokens).

Response:
```json
{
  "pool": [
    {
      "assigned_id": "abc-123",
      "provider_id": "uuid-of-mac",
      "hostname": "Johns-MacBook-Pro.local",
      "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "model_params_b": 7.0,
      "ram_gb": 16,
      "state": "ready",
      "slots_free": 1,
      "slots_total": 2,
      "max_context_tokens": 50000,
      "throughput_tps_estimate": 19.8,
      "last_heartbeat_at": "2026-05-27T14:30:00Z",
      "connected_at": "2026-05-27T12:00:00Z",
      "binary_version": "0.1.0",
      "endpoint_url": "https://m4.streamvc.live",
      "auth_state": "bearer_validated",
      "receipt_pubkey": "<base64-32-byte-ed25519>" | null,
      "receipt_pubkey_prev": null | {
        "pubkey": "<base64-32-byte-ed25519>",
        "rotated_at": "2026-06-22T12:00:00Z",
        "expires_at": "2026-06-29T12:00:00Z"
      }
    }
  ],
  "summary": {
    "total_providers": 2,
    "ready": 2,
    "draining": 0,
    "unavailable": 0,
    "total_slots": 4,
    "free_slots": 3,
    "models": ["mlx-community/Qwen2.5-7B-Instruct-4bit"],
    "by_model": {
      "mlx-community/Qwen2.5-7B-Instruct-4bit": {
        "providers": 2,
        "ready": 2,
        "slots_free_total": 3,
        "slots_total": 4
      }
    }
  }
}
```

The `summary` block is the raw coordinator/operator summary; per the SPEC-002 v1.4.1 aggregation rule below, the SPEC-006 gateway derives buyer-facing `/v1/status` counters from the detailed `pool` array (applying the `auth_state == "bearerless_duplicate"` exclusion) when those rows are present, and MAY fall back to `summary` only when the coordinator omitted the detailed `pool` array entirely. The detailed `pool` array is operator-only and MUST NOT be exposed to buyers by the gateway.

SPEC-002 v1.4.1 documents the optional `auth_state` field shown above
(SPEC-003 FR-C9.4 absorption — base enum from v0.8.3, `mint_failed`
reserved by v0.8.4, emitted by the coordinator via embedded
`pool.Provider.AuthState`). Enum values are `bearer_validated`
(connect carried a matching Bearer header), `self_minted` (FR-C9.1
fresh provisional mint, cleartext returned in the ack frame),
`bearerless_duplicate` (tokenless connect for a provider_id that
already has an unrevoked token row — admitted for operator visibility
but non-routable per FR-C9.4), and the reserved `mint_failed` value
(FR-C9.1 mint attempted but the DB write failed with a non-constraint
error; today the connect is closed with `CloseInvalidToken` before
session registration so this value does NOT currently surface on
registered `/poolz` rows — issue #82 item 2 may change that). The
field is `omitempty`; absent / empty preserves pre-v0.8.3 behavior
(routable, billable).

**Aggregation rule for buyer-facing consumers (normative).**
Downstream `/poolz` consumers that derive buyer-facing capacity
(SPEC-006 gateway `/v1/status`) MUST exclude rows with `auth_state ==
"bearerless_duplicate"` from EVERY counter they expose:
- top-level `Pool.TotalProviders` and top-level `Pool.Ready`,
- per-model `ProviderCount`, per-model `ReadyProviderCount`,
- per-model slot totals (`TotalSlots`, `SlotsFree`),
- per-model availability flags,
- per-model `supported_models` unions.
Counting bearerless rows on the buyer surface would over-promise
capacity the coordinator will refuse to route.

Operator-facing `/poolz` output is not subject to this rule: the raw
`pool` array still surfaces ALL admitted sessions (including
bearerless duplicates), and the coordinator-emitted `summary` block
still counts them in `total_providers` — operator visibility into
WHY a session is non-routable depends on it. Buyer-facing aggregators
applying the rule above MUST NOT fall back to the coordinator
`summary` block to repopulate counters that have been excluded; the
summary includes bearerless rows in `total_providers` (it is
`len(providers)` on the coordinator side), so using it as a fallback
after filtering would silently reintroduce the excluded capacity.
The gateway implementation lives at
`phase5-gateway/internal/router/server.go` `aggregateStatus`; its
summary fallback gates on `len(poolz.Pool) == 0`, not on
`out.Pool.TotalProviders == 0` after filtering.

SPEC-006 (buyer-facing gateway) currently describes `/v1/status`
without this exclusion — a SPEC-006 amendment carrying the pointer
to this rule is deferred to issue #82 closure.

SPEC-015 v0.1.3 adds the two receipt fields shown above as the SPEC-002
v1.4 absorption. `receipt_pubkey` is `null` when the provider did not
publish SPEC-001 v1.6 `auth_request.provider_receipt_public_key`;
otherwise it is the provider's current standard padded base64 32-byte
ed25519 receipt public key. `receipt_pubkey_prev` is `null` outside the
SPEC-015 rotation grace window; during that window it carries the prior
pubkey plus coordinator UTC timestamps `rotated_at` and `expires_at`.
Both fields are additive to the provider row and consumers MUST tolerate
their absence when reading pre-v1.4 coordinator responses.

Returns HTTP 401 if the operator key is missing or invalid.

**FR-O3. SIGTERM gracefully drains in-flight buyer requests.**
On SIGTERM: stop accepting new connections, send `drain` to all
providers (FR-P9), wait for in-flight requests (up to 30s configurable
timeout), force-close remaining with 503, close all WebSockets, flush
SQLite WAL, exit 0. On SIGINT, same with 5s timeout.

**FR-O4. Provider auth token CLI.**
The coordinator ships with a `coordinator-cli` tool:

- `issue-token --provider-id <provider_id> --provider-name "Name"` —
  generates 32-byte random token (64 hex chars), stores SHA-256 hash
  and authorized `provider_id` in SQLite, prints plaintext once (not
  recoverable).
- `revoke-token --token-prefix <prefix>` — sets `revoked_at` on
  matching token. Provider disconnected on next reconnection attempt.
- `list-tokens` — shows ID, prefix, provider ID, name, created,
  revoked status.

Token storage schema: see Section 7.3.

**FR-O5. Persist durable state to SQLite.**
SQLite (WAL mode) persists, across coordinator restarts:
- `provider_tokens` (auth tokens; restored on restart)
- `request_log` (billing/attribution; append-only ledger)
- `pool_snapshots` (periodic debug history, every 5 min — **debugging
  only, not restored on restart**)

**Live pool routing state is in-memory only.** On coordinator restart,
the pool table is empty. Providers reconnect automatically (SPEC-001
FR-13 exponential backoff) and re-establish state via fresh hello +
heartbeats. This means a coordinator restart causes ~30s of buyer-facing
503s while providers reconnect, which is acceptable for v1 single-
instance deployment. The `pool_snapshots` table exists only to help an
operator debug "what did the pool look like 5 min before crash."

SQLite file: `coordinator.db` (configurable via `--db-path`). Daily
backup via cron + rsync to operator.

(Scope item in § 2 "SQLite persistence for provider auth, request log,
pool state" should be read as: auth + log persisted across restarts;
pool snapshots stored for debugging only.)

---

## 5. Routing algorithm

The routing algorithm runs for every buyer request to
`/v1/chat/completions`. It selects the best provider from the pool.

### Pseudocode

```
function route(request, pool, headers) -> provider | error:
    model = request.model
    estimated_tokens = estimate_tokens(request.messages)

    # v1.1.1 helper: case-insensitive model match (D9 fix)
    function model_id_equal(a: string, b: string) -> bool:
        return casefold(a) == casefold(b)
    # Canonical casing preserved in /poolz and /v1/models for display.

    # Step 1: Provider pinning (X-MacProvider-Session takes precedence)
    if headers["X-MacProvider-Session"] is set:
        provider = pool.get_by_assigned_id(headers["X-MacProvider-Session"])
        if provider is nil:
            return error(503, "code=session_ended")
    elif headers["X-MacProvider-Provider"] is set:
        provider = pool.get_by_provider_id(headers["X-MacProvider-Provider"])
        if provider is nil:
            return error(503, "Pinned provider not in pool")
    if provider is set:
        if provider.state != "ready" or provider.slots_free <= 0:
            return error(503, "Pinned provider not available")
        if not model_id_equal(provider.model_id, model):
            return error(404, "Pinned provider serves different model")
        # v1.1.1: check provisional quota even for pinned-by-header requests
        if not check_provisional_quota(provider):
            return error(429, "Pinned provisional provider is over request quota")
        return provider

    # Step 2: Filter candidates
    candidates = []
    queue_candidates = []
    for p in pool:
        if not model_id_equal(p.model_id, model):
            continue
        if p.state != "ready":
            continue
        if p.slots_free <= 0:
            if p.slots_total > 0 and p.max_context_tokens >= estimated_tokens:
                queue_candidates.append(p)
            continue
        if p.max_context_tokens < estimated_tokens:
            continue
        candidates.append(p)

    # Step 2.3: Provisional request quota check (v1.1.1)
    function check_provisional_quota(provider) -> bool:
        if provider.tier == "pinned":
            return true  # pinned providers have no request quota
        quota = COUNT(requests where provider_id == provider.id
                      AND ts > now() - 1 hour)
        return quota < admission.provisional_request_quota_per_hour  # default 100

    pre_quota_candidates = candidates
    quota_blocked_candidates = [c for c in pre_quota_candidates
                                if not check_provisional_quota(c)]
    candidates = [c for c in pre_quota_candidates
                  if check_provisional_quota(c)]
    queue_candidates = [c for c in queue_candidates
                        if check_provisional_quota(c)]

    if len(candidates) == 0 and len(queue_candidates) > 0:
        provider = wait_in_bounded_slot_queue(queue_candidates,
                                             max_pending_per_provider=4,
                                             deadline_ms=750)
        if provider is not nil:
            return provider

    if len(candidates) == 0:
        if len(quota_blocked_candidates) > 0 and len(pre_quota_candidates) == len(quota_blocked_candidates):
            # All otherwise-eligible candidates are quota-blocked
            return error(429, code="provisional_quota_exceeded",
                         headers={"Retry-After": "3600"})
        else:
            # No eligible candidates for other reasons
            return error(503, "No provider available for model " + model)

    # Step 2.5: Apply admission-tier weight (v1.1)
    for candidate in candidates:
        candidate.effective_throughput = candidate.throughput_tps_estimate * tier_weight(candidate.tier)
    # where tier_weight(pinned) = 1.0, tier_weight(provisional) = 0.3 (configurable)

    # Step 3: Apply buyer preference
    pref = headers.get("X-MacProvider-Pref", "")

    if pref == "fast":
        # Sort by throughput descending, break ties by slots_free ascending
        sort(candidates, key=(-effective_throughput, slots_free))
    elif pref == "accurate":
        # Sort by model_params_b descending, break ties by slots_free ascending
        sort(candidates, key=(-model_params_b, slots_free))
    else:
        # Default: utilization-favoring
        # Prefer lowest positive slots_free (concentrate load)
        # Break ties by throughput descending
        sort(candidates, key=(slots_free, -effective_throughput))

    # Step 4: Select and preflight
    for provider in candidates:
        if estimated_tokens > 4096:
            ack = send_preflight(provider, request_id, estimated_tokens)
            if ack is nil:
                # Timeout — skip this provider for this request
                continue
            if not ack.accepted:
                # Provider rejected — skip
                continue
        return provider

    # All candidates failed preflight
    return error(503, "All providers rejected the request")
```

### Selection order detail

1. **Provider pinning** takes absolute precedence. If the buyer
   requests a specific provider, no other provider is considered. This
   enables A/B testing and debugging.

2. Model match is **case-insensitive** string comparison on `model_id` (v1.1 amendment, per D9). The canonical form (as sent by the provider in hello) is preserved in storage and returned in `GET /v1/models`. No fuzzy
   matching, no aliases in v1. The model ID is the HuggingFace
   identifier (e.g., `mlx-community/Qwen2.5-7B-Instruct-4bit`).

3. **State + capacity filter** removes any provider that cannot serve
   the request right now. Only `ready` providers with `slots_free > 0`
   and sufficient `max_context_tokens` are immediate candidates. For
   non-pinned requests, a `ready` provider with `slots_free == 0`,
   `slots_total > 0`, and sufficient `max_context_tokens` MAY enter the
   bounded coordinator-side slot queue described below.

4. **Buyer preference** changes the sort order but not the filter.
   All three sort strategies produce a total order — no random
   selection, fully deterministic for a given pool snapshot.

5. **Preflight** is the final gate. It only runs for estimated-large
   requests. The provider's own token counting is authoritative. If
   the first candidate rejects the preflight, the algorithm tries the
   next candidate in sorted order.

### Tie-breaking

- **Default mode (utilization-favoring):** If two providers have the
  same `slots_free`, the one with higher `throughput_tps_estimate`
  wins. If still tied, the one that connected earlier (`connected_at`)
  wins (stable sort).

- **Fast mode:** If two providers have the same
  `throughput_tps_estimate`, the one with fewer `slots_free` wins
  (pack load). If still tied, `connected_at`.

- **Accurate mode:** If two providers have the same `model_params_b`,
  the one with fewer `slots_free` wins. If still tied, `connected_at`.

**Operator-visible behavior under equal metrics (v1.0.4 clarification,
Finding F-1).** Because all tiebreaks ultimately fall back to
`connected_at` and the sort is stable, when two providers advertise
identical primary metrics in steady state, **all traffic deterministically
routes to whichever provider connected first**. This is by design — slot
counts are decremented only on heartbeat tick, not on dispatch, so
sub-heartbeat-interval bursts do not cause metric drift between
equivalent providers. Operators running pools of N≥2 identical providers
should expect skewed utilization until at least one provider's metrics
diverge (different `model_id`, different `throughput_tps_estimate` from
real traffic, or one being marked `degraded`/`draining`). Operators who
want active load distribution across equivalent providers should set
different `model_id` aliases or use `/admin/blacklist` to drain providers
in rotation. A future SPEC-004 (smart router) may introduce a randomized
tiebreak with tolerance ε on metric equality; v1.0.4 explicitly does NOT
randomize, to preserve reproducibility of routing decisions in audit
logs.

### Token estimation heuristic

The coordinator does NOT have access to the model's tokenizer (it does
not load models). It uses a byte-based heuristic:

```
estimated_tokens = total_bytes(serialize(request.messages)) / 4
```

This is intentionally conservative (overestimates for English text,
roughly accurate for code). The provider's preflight check uses the
real tokenizer and is authoritative. The coordinator's estimate is
only used for:
1. Pre-filtering providers by `max_context_tokens` (avoid obvious
   mismatches).
2. Deciding whether to send a preflight (skip for < 4096 estimated).

---

## 6. Non-functional requirements

**NFR-1. Coordinator overhead.**
The coordinator adds less than 50ms of latency to routed requests,
measured as the time between receiving the buyer's HTTP request and
sending the first byte to the provider's HTTP endpoint (excluding
preflight). This covers request validation, routing, and connection
setup. Preflight adds its own latency (up to 5s timeout, typically
<100ms on a healthy provider).

**NFR-2. Availability.**
Single-instance deployment in v1. No HA, no failover. If the
coordinator process crashes, providers reconnect automatically when it
restarts (SPEC-001 FR-13 exponential backoff). Buyer requests fail with
connection errors during downtime. HA is deferred to SPEC-002.next.

**NFR-3. Storage.**
SQLite in WAL mode. Single database file. Daily backup via file copy
(cp + rsync to operator's machine). No replication in v1. Expected
database size: <100MB after 6 months of moderate traffic (~10K
requests/day).

**NFR-4. Logging.**
JSON Lines to stdout, captured by systemd journal. Each log line
includes: ISO 8601 timestamp, level, message, and structured fields
(request_id, provider_id, model, latency_ms, etc.). Log level
configurable via `--log-level` (default: `info`).

The coordinator never logs buyer prompt content or response content
at `info` level. `debug` level may log request metadata (model,
token counts, headers) but not message bodies.

**NFR-5. Security.**
- TLS termination handled by Caddy or nginx in front of the
  coordinator (out of scope for the coordinator binary).
- Provider WebSocket auth via bearer token (FR-P12).
- Operator endpoints (/poolz, /admin/*) auth via operator API key.
- No buyer auth in v1 (single-tenant, Antseed-only).
- SQLite provider tokens stored as SHA-256 hashes.
- No secrets in environment variables at runtime (tokens loaded from
  SQLite; operator key from config file).

**NFR-6. Concurrency.**
The coordinator handles at least 100 concurrent buyer requests across
at least 4 connected providers without degradation. Go's goroutine
model handles this naturally — each buyer request is a goroutine, each
provider WebSocket is a goroutine.

**NFR-7. Memory.**
Less than 200MB RSS at idle (no providers, no active requests). Less
than 1GB RSS at peak (100 concurrent requests, 10 providers connected).
The coordinator does not buffer full inference responses in memory —
streaming responses are relayed chunk-by-chunk.

**NFR-8. Startup time.**
From `coordinator start` to listening on both HTTP and WebSocket ports:
under 2 seconds. No model loading, no heavy initialization. SQLite
open + table creation + listener bind.

---

## 7. Interface contracts

### 7.1. Provider WebSocket (server side of SPEC-001 section 6.5)

The coordinator is the WebSocket server. Providers (Phase 3 binaries)
connect as clients. The protocol is defined by SPEC-001 section 6.5 and is
LOCKED. This section replicates the message schemas and defines the
coordinator's behavior for each.

#### Connection lifecycle

```
Provider                         Coordinator
   |                                  |
   |--- WebSocket upgrade + Bearer -->|
   |                                  | FR-P12: validate token
   |<-------- 101 Switching ---------|
   |                                  |
   |--- hello ----------------------->|
   |                                  | FR-P2: validate, register in pool
   |<-------- hello_ack -------------|
   |                                  |
   |--- heartbeat (every 30s) ------>|
   |                                  | FR-P4: update pool state
   |                                  |
   |--- state_update (on change) --->|
   |                                  | FR-P5: update state, adjust routing
   |                                  |
   |                                  | FR-P7: preflight (before routing)
   |<-------- preflight -------------|
   |--- preflight_ack -------------->|
   |                                  |
   |                                  | FR-P8: after wake detection
   |<-------- warm_up ---------------|
   |--- state_update (degraded) ---->|
   |  ... warm-up inference ...      |
   |--- state_update (ready) ------->|
   |                                  |
   |                                  | FR-P9: shutdown or blacklist
   |<-------- drain -----------------|
   |--- drain_status (starting) ---->|
   |--- drain_status (in_progress) ->|
   |--- drain_status (complete) ---->|
   |--- WebSocket close ------------>|
   |                                  | FR-P10: remove from pool
```

#### Provider authentication mode (v1.1.3)

The coordinator supports two provider authentication modes, selected by
the config field `auth.require_provider_tokens` (default: `false`).

When `auth.require_provider_tokens` is `false`:
- Pinned providers (those whose `provider_id` matches an entry in
  `config.providers[]`, see § 7.1 F-2) are admitted on `provider_id`
  match alone. The bearer token field in the WebSocket handshake is
  ignored.
- Provisional providers follow the provisional admission path as normal.

When `auth.require_provider_tokens` is `true`:
- Pinned providers MUST present a bearer token in the WebSocket
  handshake matching the operator-issued token registered for that
  `provider_id` in the coordinator's token store. Mismatch or absence
  MUST result in WS close 4005 `invalid_token`.
- Provisional providers continue to be admitted without a token; the
  token requirement applies only to the pinned tier. A malformed or
  invalid bearer header MAY still be rejected before hello parsing
  because the coordinator cannot know the provider tier until after
  hello.

The default `false` reflects v1.1.2's tier-1 cooperative trust pool
(per § 2): pinned providers are trusted by `provider_id` alone, and the
token store exists for future expansion. Operators who add a token store
SHOULD flip `require_provider_tokens` to `true` and re-issue tokens to
all pinned providers as a single deployment step.

**Implementation invariant:** every code path that depends on the token
validator being configured MUST also handle the case where it is not.
Failure to do so caused the 2026-05-28 production outage cited in audit
category I (see § 11).

#### Message schemas (replicated from SPEC-001 section 6.5)

All messages are JSON objects with a `type` field.

**hello (P->C)** — sent by provider on WebSocket open:
```json
{
  "type": "hello",
  "version": 1,
  "tier": 1,
  "provider_id": "m4-anon",
  "hostname": "Johns-MacBook-Pro.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 2,
  "throughput_tps_estimate": 19.8,
  "binary_version": "1.2.0",
  "attestation": null,
  "endpoint_url": null
}
```

These schemas mirror SPEC-001 v1.2.4 § 6.5; SPEC-001 is the authoritative source.

Coordinator behavior:
- Validates all REQUIRED fields present and correctly typed; validates OPTIONAL fields (`attestation`, `endpoint_url`) when present. Absent `endpoint_url` normalized to null (FR-P2).
- Rejects `tier != 1` by closing the WebSocket with application close code 4003 `tier_unsupported` (FR-P13).
- Rejects duplicate `provider_id` by closing the older connection.
- Registers provider in pool with state `ready`.
- Responds with `hello_ack`.

**hello_ack (C->P)** — coordinator response to valid hello:
```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30,
  "tier": "pinned",
  "recommended_binary_version": "1.2.0"
}
```

Coordinator behavior:
- `assigned_id` is a UUID generated by the coordinator for this pool
  session. Used in routing logs and the `X-MacProvider-Route` header.
- `heartbeat_interval_s` is configurable (default: 30). The provider
  must send heartbeats at this interval. The coordinator uses
  `1.5 * heartbeat_interval_s` as the staleness threshold — if no
  heartbeat arrives within 45s, the provider is considered potentially
  stale (logged at warn but not removed; removal requires WebSocket
  close or explicit timeout).

**heartbeat (P->C)** — sent by provider every heartbeat_interval_s:
```json
{
  "type": "heartbeat",
  "status": "ready",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 2,
  "slots_free": 1,
  "slots_total": 2,
  "throughput_tps_estimate": 19.8,
  "requests_served_since_last": 12,
  "avg_latency_ms_since_last": 450.0,
  "throughput_tps_since_last": 18.5
}
```

Coordinator behavior:
- Updates pool entry with all fields (FR-P4).
- Updates `last_heartbeat_at`.
- If `status` differs from pool state, treats as implicit state_update.
- If `last_heartbeat_at` gap > 120s (wake detection), triggers FR-P8.
- Logs heartbeat at debug level.

**state_update (P->C)** — sent on provider state change:
```json
{
  "type": "state_update",
  "state": "degraded",
  "reason": "post-wake warm-up in progress",
  "since": "2026-05-27T14:30:00Z",
  "metrics_snapshot": {
    "slots_free": 2,
    "slots_total": 2,
    "requests_served_since_last": 0,
    "avg_latency_ms_since_last": null,
    "throughput_tps_since_last": null
  }
}
```

Coordinator behavior:
- Validates `state` is one of the 5 allowed values (FR-P5).
- Updates pool entry state and metrics.
- Adjusts routing eligibility immediately.
- Logs state transition at info level with `reason`.

**drain_status (P->C)** — sent during provider drain:
```json
{
  "type": "drain_status",
  "phase": "in_progress",
  "inflight_requests": 2,
  "estimated_drain_seconds": 15
}
```

Coordinator behavior:
- Logs drain progress (FR-P6).
- `phase: "starting"` — coordinator confirms provider is draining.
- `phase: "in_progress"` — informational; coordinator already stopped
  routing to this provider.
- `phase: "complete"` — coordinator expects WebSocket close imminently.

**preflight (C->P)** — coordinator asks provider before routing:
```json
{
  "type": "preflight",
  "request_id": "buyer-req-uuid",
  "estimated_tokens": 8500
}
```

When coordinator sends this:
- Before forwarding a buyer request to the provider, if
  `estimated_tokens > 4096` (FR-P7).
- The `request_id` is the coordinator's UUID for the buyer request,
  used to correlate the response.
- Coordinator waits up to 5 seconds for `preflight_ack`.

**preflight_ack (P->C)** — provider's response to preflight:
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": true,
  "estimated_wait_ms": 0
}
```

Rejection example:
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": false,
  "reason": "context_exceeds_capacity",
  "max_context_tokens": 50000
}
```

Coordinator behavior:
- If `accepted: true`: proceed to forward the buyer request.
- If `accepted: false`: log rejection reason, try next candidate
  provider (Section 5).
- If timeout (no response in 5s): skip this provider for this request,
  try next candidate. Do NOT mark provider as unhealthy.

Valid rejection reasons (from SPEC-001):
- `context_exceeds_capacity`
- `queue_full`
- `draining`
- `model_not_loaded`
- `unhealthy`
- `tier_mismatch`

**drain (C->P)** — coordinator tells provider to stop:
```json
{
  "type": "drain"
}
```

When coordinator sends this:
- On coordinator SIGTERM (to all providers) (FR-P9).
- On operator blacklist command (to specific provider).
- Coordinator marks provider as `draining` in pool immediately.
- Coordinator does NOT close the WebSocket — waits for provider.

**warm_up (C->P)** — coordinator triggers warm-up:
```json
{
  "type": "warm_up"
}
```

When coordinator sends this:
- After detecting a wake event (heartbeat gap > 120s then resumption)
  (FR-P8).
- Coordinator marks provider as `degraded` in pool.
- Coordinator waits for `state_update` with `state: "ready"` before
  routing to this provider, or falls back after `pool.warmup_fallback_s`.

**nak (P->C only)** — per SPEC-001 § 6.5, `nak` is provider-to-coordinator
only. Protocol error from provider:
```json
{
  "type": "nak",
  "in_reply_to": "preflight",
  "error": {
    "code": "unknown_message_type",
    "message": "Unrecognized message type: 'foo'"
  }
}
```

Coordinator behavior when receiving nak from provider:
- Log the nak at warn level.
- Do NOT disconnect the provider. A nak is informational — the
  provider does not understand a specific message but is otherwise
  healthy.

**Special case: nak `unknown_message_type` in response to § 6.6
message dispatch (v1.1.1, M5 fix).** When the coordinator dispatches
an `inference_request` (or other SPEC-001 v1.2 § 6.6 message) and the
provider replies with `nak code=unknown_message_type`, this indicates
a routing-mode resolution bug: the coordinator believed the provider
supported WS-tunneled mode when it does not. The coordinator MUST:
1. Mark the provider's effective routing mode as
   `http_forwarding_only` for the remainder of this WS session (until
   the provider reconnects with a fresh hello).
2. MUST NOT retry the failed request via § 6.6.
3. SHOULD return HTTP 503 to the buyer for this request.
4. Log at warn level: "routing-mode resolution bug: provider <id>
   does not support § 6.6; marking http_forwarding_only."

See SPEC-001 v1.2.4 backward-compat statement for the design rationale.

**Coordinator does NOT send `nak` to providers.** Coordinator-initiated
rejection (invalid hello, unknown provider_id, tier mismatch, version
mismatch, invalid token, pool full) uses WebSocket application close
codes 4001–4005, 4429 with descriptive reason strings. See FR-P13's
"Provider rejection via WebSocket close codes" table.

This preserves SPEC-001 § 6.5's locked one-directional `nak` semantics
exactly. Provider binaries do not need any new parser logic; standard
WebSocket close handling per SPEC-001 FR-13 is sufficient.

#### Heartbeat field extension (v1.3.5, SPEC-011)

The existing heartbeat schema above remains the L-1 baseline shape.
When the binary has not enabled SPEC-011 warm swap, heartbeats omit
`model_hash` and `loading`, and the coordinator processes the frame
through the legacy behavior below. When the binary has enabled
`--enable-warm-swap`, the heartbeat MAY carry the following optional
fields per SPEC-011 v0.5 §3.3 R-3.3.0 / R-3.3.1 and SPEC-001 v1.3
§6.10:

| Field | JSON name | Type | Requiredness | Coordinator handling |
|---|---|---|---|---|
| Model hash | `model_hash` | string, raw 64-char lowercase hex | optional; present only on SPEC-011 warm-swap path | Validated and used as the new `Provider.ModelHash` when present; triggers SPEC-008 v0.3 §5.3-§5.6 re-verification on model change |
| Loading flag | `loading` | bool | optional; absence is equivalent to `false` | Marks the provider routing-ineligible while `true` via the existing non-ready exclusion path and feeds `LastLoadingState` for exactly-once audit emission |

R-7.1.1 The coordinator MUST accept heartbeat frames that omit
`model_hash` and `loading` and MUST process them exactly as SPEC-002
v1.3.4 did. This preserves the L-1 byte-identical default for
pre-SPEC-011 binaries and for v1.3 binaries in SPEC-001 v1.3 §6.7.3
cell 1, per SPEC-011 v0.5 R-3.3.0 / AC-18.

R-7.1.2 When `loading: true` is present, the coordinator MUST treat the
provider as routing-ineligible until the next heartbeat with
`loading: false` or an absent `loading` field, reusing the existing
non-ready filtering path and adding no new coordinator-side provider
state, per SPEC-011 v0.5 R-3.3.3 / R-3.3.4.

#### ApplyHeartbeat hash-clearing REPLACEMENT (v1.3.5, per SPEC-011 v0.5 §6.2)

**THIS SUB-SECTION NORMATIVELY REPLACES THE HASH-CLEARING PART OF THE
LOCKED v1.3.4 `ApplyHeartbeat` BEHAVIOR AT
`phase4-coordinator/internal/pool/provider.go:411-432`.** The
replacement is a two-path dispatch keyed ONLY by whether the current
heartbeat carries the `model_hash` field. It applies per-heartbeat; the
coordinator MUST NOT infer a sticky SPEC-011 path from a prior heartbeat.

**LEGACY PATH — heartbeat lacks `model_hash` field.**

R-7.1.3 If the current heartbeat lacks `model_hash` and
`heartbeat.model_id != Provider.ModelID`, the coordinator MUST keep the
locked v1.3.4 behavior at
`phase4-coordinator/internal/pool/provider.go:420-432`: update
`Provider.ModelID`, CLEAR `Provider.ModelHash`, and SET
`Provider.HashStatus = HashStatusUncatalogued`. No
`operator_model_swap` event is emitted. This is the L-1 path for
pre-SPEC-011 binaries and for any SPEC-011 binary heartbeat that omits
`model_hash`, per SPEC-011 v0.5 R-3.3.2 / R-3.3.5 and SPEC-001 v1.3
AC-18.0.

**SPEC-011 PATH — heartbeat carries `model_hash` field.**

R-7.1.4 If the current heartbeat carries `model_hash` and
`heartbeat.model_id != Provider.ModelID`, the coordinator MUST update
`Provider.ModelID` and MUST UPDATE `Provider.ModelHash` to the new
heartbeat value, not clear it, per SPEC-011 v0.5 R-3.3.5 and
SPEC-011 v0.5 AC-10.

R-7.1.5 After updating `Provider.ModelHash` on the SPEC-011 PATH, the
coordinator MUST run SPEC-008 v0.3 §5.3-§5.6 Pillar A re-verification
against the new hash and MUST populate `Provider.HashStatus` from the
SPEC-008 v0.3 §5.5 five-state enumeration, per SPEC-011 v0.5 §3.5
R-3.5.2 / R-3.5.3.

R-7.1.6 The coordinator MUST emit an `operator_model_swap` audit event
IF AND ONLY IF the prior heartbeat on the current provider session had
`loading: true` and the current SPEC-011 PATH heartbeat is the
post-swap heartbeat. The `LastLoadingState` sticky gate MUST reset
after the emission so the event is emitted exactly once per completed
swap, per SPEC-011 v0.5 R-3.3.5 / R-3.6.3 / AC-20. The "current
session" qualifier is normative: per §7.10 R-7.10.10 (the conditional
emission rule of SPEC-011 v0.5 R-3.6.6), if the WS dropped during the
loading window and the provider reconnected AFTER swap completion, no
`loading: true` heartbeat exists on the new session and therefore NO
`operator_model_swap` event fires. Reconnect DURING load (post-
reconnect heartbeat has `loading: true` with the OLD `model_id`) DOES
re-establish the sticky on the new session and a subsequent swap
completion DOES emit normally. The full emission contract — payload
schema, F-1.5 invariants, conditional emission, and emission
exactly-once — lives in §7.10.

R-7.1.7 The SPEC-011 PATH MUST NOT change buyer HTTP endpoints,
SPEC-002 §5 routing order, or Tier-2 behavior beyond invoking the
existing SPEC-008 v0.3 §5.3-§5.6 Pillar A pipeline. The SPEC-010
catalog opt-in and the SPEC-011 heartbeat opt-in remain orthogonal for
all four SPEC-001 v1.3 §6.7.3 matrix cells per SPEC-001 v1.3 R-6.7.7.

### 7.2. Buyer HTTP API

Wire-compatible with SPEC-001 section 6.2. The harness (`beta/harness.py`)
is the first buyer and generates SPEC-001-shaped requests.

Coordinator MUST honor any inbound `X-Request-ID` header on buyer-facing `/v1/*` requests and persist it as `request_log.external_request_id` (v1.4.2 R-2). If absent, coordinator's internal `request_log.request_id` is generated locally as a UUID v4 and `external_request_id` is NULL. The `request_log` schema includes a partial-NULL `external_request_id` index for cross-service reconciliation.

**Buyer-controlled text sanitization (v1.5.1).** Every column in `request_log` whose value originates from buyer-controlled input — `external_request_id` (from `X-Request-ID`), `account_id` (from `X-MacProvider-Account`), `model` (from JSON body), `error` (provider/upstream error message), `pref_header` (from `X-MacProvider-Pref`), `provider_header` (from `X-MacProvider-Provider`) — MUST pass through a sanitizer at the buyer-handler boundary:
- **Opaque headers** (`external_request_id`, `account_id`): `sanitizeOpaqueHeader` — reject the whole value on UTF-8 invalid OR control bytes (C0 `<0x20`, DEL `0x7f`, C1 `0x80-0x9f`) at byte granularity, cap at 128 bytes.
- **Text fields** (`model`, `error`, `pref_header`, `provider_header`): `sanitizeRequestLogText` — reject UTF-8 invalid; strip C0/DEL/C1 codepoints; cap at 256 runes.
- **WS provider hello required strings** (`provider_id`, `hostname`, `model_id`, `binary_version` — provider-controlled, not buyer-controlled, but they reach the same structured-log surface): `requireString` rejects control characters at parse time so a malicious provider cannot inject CSI sequences via the hello.

Reason: terminal-control-character (CSI / OSC) sequences in structured logs and SQLite text columns are a load-bearing log-injection class — the `c1-control-chars-terminal-sanitizer-bypass` audit established this for opaque headers and v1.5.1 extends the contract to every buyer-controlled persisted text column.

**UUID-tolerance (v1.5.1).** `external_request_id` is **opaque sanitized text**, not UUIDv4-shape-required. Gateway-routed traffic carries a UUIDv4 per SPEC-006 R-G3 (the gateway middleware mints a UUIDv4 if the inbound `X-Request-ID` is absent or non-UUIDv4-like). Direct coordinator buyer-port traffic MAY carry any non-control 1-128-byte ASCII/UTF-8 string. Coordinator implementations MUST NOT reject non-UUID-shaped inbound IDs but MUST apply `sanitizeExternalRequestID` (trim whitespace; cap at 128 bytes; reject invalid UTF-8; reject control bytes `< 0x20`, `0x7f`, and the C1 range `0x80-0x9f` **at byte granularity** — rune iteration is insufficient because raw C1 bytes decode to `utf8.RuneError` and would otherwise slip through, defeating the load-bearing C1/CSI rejection; on failure treat as absent and DO NOT echo the malformed payload to logs). Cross-service reconciliation MUST NOT assume UUIDv4 shape; the value is opaque text and parity is byte-exact on the sanitized string.

When forwarding work to a provider over the SPEC-001 § 6.6 `inference_request` message, coordinator MUST preserve the request ID it recorded for the buyer request. Providers MAY echo `X-Request-ID` back in usage reporting; this is OPTIONAL under SPEC-001 v1.2.4 and is filed as a SPEC-001 v1.2.3 candidate.

**Gateway → coordinator forward contract (v1.5.0).** Gateway-originated traffic from SPEC-006 v0.3+ MUST send two correlation headers on every forwarded buyer request:

- `X-Request-ID: <uuid>` — the buyer-visible request id (honored from the inbound buyer `X-Request-ID` when present, else minted by gateway middleware). Persisted into `request_log.external_request_id`.
- `X-MacProvider-Account: <account_id>` — the gateway's authenticated subject account id, sourced from the gateway's bearer- or demo-auth subject. Persisted into `request_log.account_id`. MUST be sent unconditionally — earlier gateway code only emitted this header inside the sticky-routing conditional, leaving the non-sticky hot path account-blind. Empty / absent header is tolerated for backwards compatibility but degrades the reconciliation key to `external_request_id` alone for that row.

The composite `(account_id, external_request_id)` is the reconciliation key joining coordinator `request_log` to gateway `usage_events` (and to gateway `audit_events`). `external_request_id` alone is a logical join key only — after #196 the same buyer-supplied `X-Request-ID` MAY appear in `usage_events` rows belonging to distinct accounts, so any reconciliation query that ignores `account_id` is ambiguous on cross-account collisions. Direct legacy buyer traffic without these headers remains supported and writes rows with NULL `account_id` and NULL `external_request_id`; such rows fall back to the prior `request_id`-only key.

#### GET /v1/models

**Request:** No body. No required headers.

**Response (200):** See FR-B1 for full schema.

#### POST /v1/chat/completions

**Request schema:** Wire-identical to SPEC-001 § 6.2. Detailed below
inline so this spec is self-contained for build session use; if SPEC-001
§ 6.2 ever updates, this section MUST be updated to match.

**Required fields:**

| Field | Type | Constraints |
|---|---|---|
| `model` | string | Must match a `model_id` known to the pool. 404 `model_not_found` if absent from pool history; 503 `no_provider_available` if known but no provider eligible. |
| `messages` | array | Non-empty. Per-message validation below. |

**Optional fields:**

| Field | Type | Default | Constraints |
|---|---|---|---|
| `max_tokens` | int | Remaining provider context capacity | Must be > 0. Coordinator may pass through; the provider's pre-flight enforces context cap. |
| `temperature` | float | 1.0 | 0.0 to 2.0 |
| `top_p` | float | 1.0 | 0.0 to 1.0 |
| `n` | int | 1 | MUST be 1. Values > 1 rejected 400 (single-tenant routing). |
| `stream` | bool | false | If true, response is SSE; see FR-B6. |
| `stream_options` | object | null | `{include_usage: bool}`. Per FR-B1/SPEC-001 FR-7, `include_usage=false` is silently ignored; coordinator always relays the provider's usage chunk. |
| `stop` | string or array | null | Max 4 stop sequences. |
| `presence_penalty` | float | 0.0 | -2.0 to 2.0 |
| `frequency_penalty` | float | 0.0 | -2.0 to 2.0 |
| `seed` | int | null | Passed through to provider. |
| `user` | string | null | Logged at DEBUG only. |
| `response_format` | object | `{type:"text"}` | `type` ∈ {`"text"`, `"json_object"`}. Other values rejected 400. `content_filter` is Tier 2-reserved; v1 rejects 400. |
| `tools` | array | null | Parsed syntactically; if any tool entry lacks `function.name` or has invalid `function.parameters` JSON Schema → 400 `invalid_tools`. |
| `tool_choice` | string or object | null | Parsed, forwarded to provider. v1 coordinator does not execute tools — it relays. |

**Per-message validation:**

| `role` | Required content shape |
|---|---|
| `system` | `content` must be a non-empty string |
| `user` | `content` must be a non-empty string (no multimodal content arrays in v1) |
| `assistant` | `content` may be a string OR `content: null` with `tool_calls` array. If both `content` and `tool_calls` are null/absent → 400. |
| `tool` | `tool_call_id` (string, required) and `content` (string, required) |

Roles other than the four above → 400 `invalid_request`.

**Tool-call shape (when present in assistant history):**
```json
{
  "id": "call_<id>",
  "type": "function",
  "function": {
    "name": "<string>",
    "arguments": "<string-encoded-JSON>"
  }
}
```
`arguments` must parse as valid JSON (string-encoded). Malformed → 400
`invalid_tools`.

**Unknown top-level fields:** ignored silently (forward-compat), logged
at DEBUG.

Validation order:
| Step | Check | Failure response |
|---|---|---|
| 1 | JSON parse | 400 `invalid_json` |
| 2 | Required fields present | 400 `invalid_request` |
| 3 | Field types and ranges | 400 `invalid_request` |
| 4 | Per-message role and content validation | 400 `invalid_request` |
| 5 | Tool/tool_call shape validation | 400 `invalid_tools` |
| 6 | Model exists in pool | 404 `model_not_found` |
| 7 | Provider available (routing) | 503 `no_provider_available` |
| 8 | Preflight (if applicable) | 503 `preflight_rejected` |

Note: steps 7-8 replace SPEC-001's steps 7-9 (Stage 1/2 pre-flight
and provider queue admission). The coordinator does not tokenize. It
MAY perform the bounded pre-dispatch slot queue described in this spec;
provider-side tokenization and execution queueing remain provider
responsibilities.

**Non-streaming response (200):** Forwarded from provider. Same shape
as SPEC-001 section 6.2 non-streaming response. The coordinator adds:
- `X-MacProvider-Route: <assigned_id>` response header.
- `X-MacProvider-Provider: <provider_id>` response header (stable
  identifier; complements the session-scoped `assigned_id` route header).

(No retry header in v1 per FR-B7 — coordinator does not retry across
providers.)

**Streaming response (200):** SSE stream forwarded from provider. Same
shape as SPEC-001 section 6.3. The coordinator adds the same response
headers.

**Custom request headers (buyer → coordinator):**

| Header | Type | Description |
|---|---|---|
| `X-MacProvider-Pref` | string | Same-model preference; `fast` or `accurate` (FR-R2) |
| `X-MacProvider-Provider` | string | **Stable `provider_id`** for pinning across reconnects (FR-R3) |
| `X-MacProvider-Session` | string | Session-scoped `assigned_id` for pinning a specific WebSocket session (FR-R3). Takes precedence over `X-MacProvider-Provider` when both are sent (more specific). |

**Custom response headers (coordinator → buyer):**

| Header | Type | Description |
|---|---|---|
| `X-MacProvider-Provider` | string | Stable `provider_id` of the provider that served the request (operator-meaningful identity) |
| `X-MacProvider-Route` | string | Session `assigned_id` of the WebSocket session that served the request (correlation with coordinator logs) |

(`X-MacProvider-Provider` appears as both a request and response header.
On request it selects; on response it reports. The two semantics share
the same value space — the stable `provider_id`.)

**Reserved response headers (namespace reserved, not enforced in v1):**

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | Future: requests per window |
| `X-RateLimit-Remaining` | Future: remaining in window |
| `X-RateLimit-Reset` | Future: window reset time |

**Error responses:**

| Status | Condition | Error code |
|---|---|---|
| 400 | Missing/invalid fields, malformed tools, n>1 | `invalid_request` or `invalid_tools` |
| 401 | Invalid buyer auth (future, not enforced in v1) | `invalid_auth` |
| 404 | No connected provider has ever advertised this `model_id` (model unknown to the pool) | `model_not_found` |
| 429 | Rate limit exceeded (future, not enforced in v1) | `rate_limit_exceeded` |
| 502 | Selected provider returned an error or disconnected mid-request | `provider_error` |
| 503 | Model is known to the pool but no eligible provider is currently available (all matching providers busy/degraded/draining/unavailable, or all failed preflight) | `no_provider_available` |
| 504 | Provider did not respond within timeout | `provider_timeout` |

**404 vs 503 split (clarified):**
- **404 `model_not_found`** — the requested `model_id` is not in the
  union of `model_id` fields across all currently-connected providers
  AND has not been seen in any provider's hello/heartbeat history during
  this coordinator process lifetime.
- **503 `no_provider_available`** — the `model_id` is recognized
  (some provider serves or has recently served it), but no currently-
  eligible provider can take the request right now. Retry-friendly.

This split matters because buyers should treat 404 as a misconfiguration
("pick a different model") and 503 as transient backoff ("retry soon").

All error responses use the OpenAI error envelope:
```json
{"error":{"message":"...","type":"...","param":null,"code":"..."}}
```

### 7.3. Auth

#### Token issuance flow (offline, CLI)

Operator runs `coordinator-cli issue-token --provider-id <provider_id>
--provider-name <display name>`. CLI generates 32 random bytes
(hex-encoded, 64 chars), stores SHA-256 hash plus the authorized
`provider_id` in `provider_tokens`, prints plaintext once (not
recoverable). Operator delivers token to provider via secure channel.

#### Token validation (bearer in WebSocket auth header)

When `auth.require_provider_tokens=true`, a pinned provider connects
with `Authorization: Bearer <token>`. Coordinator computes SHA-256,
looks up in `provider_tokens`, checks `revoked_at IS NULL`, checks the
token row's `provider_id` equals `hello.provider_id`, and updates
`last_used_at`. Valid: hello processing proceeds. Missing, malformed,
invalid, revoked, or valid-for-a-different-provider: WS close 4005
`invalid_token`.

#### Token rotation / revocation

Revocation via `coordinator-cli revoke-token --token-prefix <prefix>`.

**Revocation semantics in v1: future-connection only.** Marking a token
as revoked sets `revoked_at` and prevents any FUTURE WebSocket upgrade
that presents this token from succeeding. **Existing live WebSocket
sessions are NOT automatically disconnected** — they continue serving
buyer traffic until they disconnect for any other reason.

This is intentional in v1: revocation handles the "token leaked" case
on a delay, but the operator's immediate disconnect tool is
`POST /admin/blacklist` (see § 7.4), which closes the live WebSocket
synchronously. The two operations are deliberately separate:
- Revoke → "don't let this token reconnect."
- Blacklist → "kick this provider off now."

Combined: to fully terminate a leaked-token provider, the operator runs
revoke + blacklist. The CLI command `coordinator-cli revoke-and-kick
--token-prefix <prefix>` performs both in one call by kicking the
`provider_id` stored on the revoked token row; any explicit
`--provider-id` override MUST match the token row.

Rotation: issue new, deliver to provider, revoke old. No atomic rotation
in v1.

#### Token storage

```sql
CREATE TABLE provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
CREATE INDEX idx_token_hash ON provider_tokens(token_hash);
```

No plaintext tokens stored. The `token_prefix` (first 6 hex chars) is
stored for display and revocation convenience only.

### 7.4. Operator endpoints

**Port placement (v1.1.4 clarification, cross-spec F-602-2).** Operator
endpoints `/poolz` and `/admin/*` are mounted on `listen.provider_port`
(default **8444**), the same listener that serves provider WebSocket
upgrades at `/ws/provider`. `/healthz` MAY be exposed on the coordinator
health surface. `GET /v1/pool/check` is a public operator/health
surface for installer verification and is intentionally mounted behind
`coordinator.streamvc.live`, not behind SPEC-006 gateway. Runbook
entries that previously implied "use the buyer URL" should distinguish
the public coordinator health surface from authenticated provider-port
admin actions.

#### GET /healthz

No authentication. Returns coordinator health (FR-O1).

**200 OK:**
```json
{
  "status": "ok",
  "uptime_s": 3600,
  "pool_size": 3,
  "pool_ready": 2,
  "pool_degraded": 1,
  "pool_draining": 0,
  "pool_unavailable": 0,
  "requests_total": 1420,
  "requests_active": 2,
  "version": "0.1.0"
}
```

**503 Service Unavailable** (coordinator draining):
```json
{
  "status": "draining",
  "uptime_s": 3600,
  "pool_size": 0,
  "pool_ready": 0,
  "pool_degraded": 0,
  "pool_draining": 3,
  "pool_unavailable": 0,
  "requests_total": 1420,
  "requests_active": 2,
  "version": "0.1.0"
}
```

#### GET /poolz

Requires `Authorization: Bearer <operator-key>`. Returns full pool
state (FR-O2). See FR-O2 for response schema, including the optional
SPEC-015 v0.1.3 `receipt_pubkey` and `receipt_pubkey_prev` provider
row fields.

**401 Unauthorized** if operator key missing or invalid.

#### GET /v1/pool/check

**Path:** `/v1/pool/check?provider_id=<provider_id>`

**Auth:** none. This is a publicly accessible operator/health surface,
not a buyer API surface.

**Response (200 OK):**

```json
{
  "provider_id": "<id>",
  "tier": "pinned",
  "state": "ready"
}
```

`tier` MUST be `"pinned"` or `"provisional"`. `state` MUST be one of
`"ready"`, `"draining"`, `"unavailable"`, or `"unknown"`.

Unknown providers return the same 200 shape with `"state": "unknown"`.

**Response (400 Bad Request):**

```json
{"error":{"code":"invalid_request","message":"provider_id is required"}}
```

**Response (429 Too Many Requests):**

```json
{"error":{"code":"rate_limited","message":"Pool check rate limit exceeded"}}
```

**Rate-limit source-IP derivation (issue #125).** The per-source rate-
limit bucket key is derived as follows: if `r.RemoteAddr` falls inside
one of the operator-configured `proxy.trusted_proxies` CIDR ranges
(default `["127.0.0.0/8", "::1/128"]` covers the production nginx-on-
localhost topology), the coordinator parses the `X-Forwarded-For`
header rightmost-untrusted-hop first, falling back to `X-Real-IP`,
then to `r.RemoteAddr`. For peers outside the trusted-proxy CIDR set
the `X-Forwarded-For` / `X-Real-IP` headers are IGNORED — direct
internet callers cannot spoof their bucket key. Operators MUST keep
`proxy.trusted_proxies` narrow; expanding it to non-actual-proxy CIDRs
admits spoofing.

Purpose: SPEC-003 v0.6 `install.sh` self-test calls this endpoint after
first WebSocket connect to confirm that a freshly installed provider has
registered with the coordinator. It is also a generic provider-registered
health check.

This endpoint stays publicly accessible at `coordinator.streamvc.live`.
nginx routes `/v1/pool/check` to the coordinator directly, not to the
SPEC-006 gateway. SPEC-006 v0.3 gateway MUST NOT intercept this path.

#### POST /admin/blacklist

Requires `Authorization: Bearer <operator-key>`.

**Request:**
```json
{
  "provider_id": "m4-anon",
  "reason": "Provider operator requested removal"
}
```

The request key is the stable `provider_id`. For session-scoped
debugging, `assigned_id` may be sent INSTEAD — the coordinator accepts
either field name and resolves to the same pool entry. If both are sent,
`provider_id` takes precedence. If neither resolves to a current pool
entry, returns 404.

**Response (200):**
```json
{
  "status": "draining",
  "provider_id": "m4-anon",
  "assigned_id": "abc-123",
  "drain_sent": true
}
```

Both IDs are returned so the caller can correlate against either `/poolz`
column. `status: "draining"` reflects the immediate pool state after the
drain command is sent (matches AC-10 Phase 1); the entry transitions to
removed after the WebSocket closes (AC-10 Phase 2).

**404 Not Found** body:
```json
{"error": {"code": "provider_not_found", "message": "provider <id> not in pool"}}
```

The coordinator:
1. Sends `drain` to the provider.
2. Marks the provider as `draining` in the pool — stops routing
   immediately.
3. Closes the WebSocket within 60 seconds OR after `drain_status:
   complete`, whichever comes first.
4. Removes the provider from the pool on WebSocket close (per FR-P6
   normal disconnect path; not a special-case "immediate removal").
5. Logs the blacklist action at warn level.

`/poolz` continues to show the provider in `draining` state for the up-
to-60s window between drain command and WebSocket close. After close,
the entry is gone. AC-10 asserts this two-phase observable behavior
(not "removed immediately" — that would conflict with FR-P6's normal
disconnect-then-remove flow).

#### /v1/status SPEC-010 echo (v1.3.5)

R-7.4.1 For each provider entry returned by `/v1/status`, the
coordinator MUST INCLUDE the `supported_models` field IF the provider's
`PublishesSupportedModels` is `true` per §3 Provider data model and
SPEC-010 v1.5 R-3.3.3. When `PublishesSupportedModels` is `false` or
absent, the `supported_models` field MUST be OMITTED entirely, not
emitted as `null` or `[]`. This preserves byte-identical `/v1/status`
output for pre-SPEC-010 binaries and for SPEC-010 binaries that opt out
per SPEC-010 v1.5 AC-21 and SPEC-001 v1.3 AC-18.0.

### 7.5. Admission state and operator endpoints (v1.1)

All endpoints in this section are mounted on `listen.provider_port`
(default 8444) per Finding F-3. All require
`Authorization: Bearer <operator-key>`.

#### GET /admin/provisional

Returns all current and historical provisional providers.

**Response (200):**
```json
{
  "provisional": [
    {
      "provider_id": "stranger-mac-001",
      "hostname": "Strangers-MacBook.local",
      "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "binary_version": "1.2.0",
      "first_seen_at": "2026-06-01T10:00:00Z",
      "last_seen_at": "2026-06-01T12:30:00Z",
      "total_requests_served": 42,
      "total_tokens_served": 8400,
      "currently_connected": true,
      "promoted_at": null
    }
  ],
  "summary": {
    "total_provisional": 3,
    "currently_connected": 2,
    "promoted": 1
  }
}
```

#### POST /admin/promote/{provider_id}

Promotes a provisional provider to pinned tier (runtime only — operator
must also add to `coordinator.yaml` for persistence across restarts).

**Response (200):**
```json
{
  "provider_id": "stranger-mac-001",
  "previous_tier": "provisional",
  "new_tier": "pinned",
  "note": "Runtime promotion only. Add to coordinator.yaml for persistence across restarts."
}
```

**Response (404):** `{"error": {"code": "provider_not_found", "message": "..."}}`
**Response (409):** `{"error": {"code": "already_pinned", "message": "..."}}`

#### POST /admin/reject/{provider_id}

Rejects a provider (any tier). Adds to `rejected_providers` and
disconnects.

**Request body (optional):**
```json
{"reason": "Suspected bad actor"}
```

**Response (200):**
```json
{
  "provider_id": "stranger-mac-001",
  "status": "rejected",
  "drain_sent": true,
  "note": "Future connections rejected with close code 4009."
}
```

**Tier state transitions:**
- Provisional → Pinned: `POST /admin/promote/{id}`. Updates routing
  weight to 1.0 immediately.
- Provisional → Rejected: `POST /admin/reject/{id}`. Sends drain,
  adds to `rejected_providers`, closes WS with 4009.
- Rejected → Provisional: Operator removes row from
  `rejected_providers` (SQL). Provider can reconnect.

### 7.6. SPEC-006 gateway deployment routing

When deployed alongside SPEC-006 v0.3 gateway, coordinator's buyer port
(8443) MUST be rebound from `0.0.0.0` to `127.0.0.1`. Public TLS
termination happens at nginx and the gateway. The provider port (8444)
MAY remain externally reachable if `coordinator.streamvc.live` serves
`/admin/*`, `/poolz`, `/healthz`, and `/ws/provider` directly with the
required auth controls.

The public route split is:

```nginx
# Rate limit and connection cap for /ws/provider (PG-2).
# Values are recommended defaults; operators MAY tune them, but the
# controls MUST run at the proxy before the coordinator performs the
# WebSocket upgrade.
limit_req_zone $binary_remote_addr zone=ws_provider_rate:10m rate=10r/m;
limit_conn_zone $binary_remote_addr zone=ws_provider_conn:10m;

# api.streamvc.live -> gateway (buyer surface)
location /v1/chat/completions { proxy_pass http://127.0.0.1:9443; }
location /v1/models { proxy_pass http://127.0.0.1:9443; }
location /v1/usage { proxy_pass http://127.0.0.1:9443; }
location /v1/feedback { proxy_pass http://127.0.0.1:9443; }
location /v1/status { proxy_pass http://127.0.0.1:9443; }

# coordinator.streamvc.live -> coordinator (operator + legacy buyer surface)
location /v1/pool/check { proxy_pass http://127.0.0.1:8443; }
location /healthz { proxy_pass http://127.0.0.1:8443; }
location /poolz { proxy_pass http://127.0.0.1:8444; }
location /admin/ { proxy_pass http://127.0.0.1:8444; }

# Provider WS - production invariants per § 7.7 PG-1 and PG-2.
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

### 7.7. Production invariants (public-launch gate)

The following invariants MUST be true before the coordinator is exposed
to public buyer traffic through any SPEC-006-style buyer-API gateway.
They are documented here as normative gates, not as v1.1.5 mandatory
defaults. Operators may continue to run the Tier 1 cooperative-trust
configuration for non-public deployments.

**PG-1: Provider authentication MUST be required.** Before any
public-buyer-facing service forwards requests to this coordinator,
`auth.require_provider_tokens` MUST be set to `true` in
`coordinator.yaml`. All pinned providers MUST have valid bearer tokens
issued and registered in the token store. Provisional providers MAY
continue without tokens per the provisional admission tier, but pinned
providers serving public traffic MUST be token-authenticated.
Those bearer tokens MUST be issued (or re-issued) **after** the v1.3.1
`provider_id`-binding migration — any token created before v1.3.1 has an
empty `provider_id` subject and will fail validation, so flipping the flag
without re-issuance silently rejects every pinned provider with `4005`
`invalid_token` (FR-P12; the 2026-05-28 audit-category-I outage class).
Verify each pinned token authenticates a live WS handshake before exposing
public buyer traffic.

**PG-2: Pre-WS-upgrade rate limits MUST be enforced at the proxy
layer.** The nginx or equivalent reverse proxy in front of the
coordinator MUST enforce:
- Per-IP connection rate limit on `/ws/provider` before upgrade
  (recommended: 10/min).
- Per-IP concurrent connection cap on `/ws/provider` before upgrade
  (recommended: 5).
- Both controls MUST apply before the WebSocket upgrade handshake
  reaches the coordinator process.

**PG-3: Provisional admission MUST be rate-limited.** The coordinator's
existing `admission.provisional_admission_rate_per_hour` control (per
§ 7.1 F-2) provides this gate. The production value MUST be
conservative (recommended: 10/hour).

**PG-4: Unknown provider_id rejection MUST be aggressive in pinned-only
production mode.** When a hello includes an unknown `provider_id` and
`pinned_only=true`, the coordinator MUST close immediately and MUST NOT
fall through to provisional admission. For v1.1+ coordinators this uses
WS close 4009 `banned`; close 4002 `unknown_provider_id` remains retired
per § 7.1.

**PG-5: Provisional-admission spike alerting MUST be operator-facing.**
The coordinator MUST emit an operator-readable WARN log line, and MAY
also emit a webhook alert, when provisional admissions exceed 50% of
`admission.provisional_admission_rate_per_hour` in any rolling
10-minute window. The WARN event name MUST be
`provisional_admission_pressure`, with fields for the rolling-window
count, configured hourly limit, and threshold. This is the canary signal
for Sybil pressure.

Each invariant has an associated acceptance criterion in § 11.

### 7.8. v2 `auth_request` provider handshake (NEW in v1.3.5)

Locked SPEC-002 v1.3.4 §7.1 documents the legacy `hello` handshake.
The v2 `auth_request` two-stage handshake has been in coordinator code
since SPEC-002 v1.2.x: the frame validator at
`phase4-coordinator/internal/ws/messages.go:302-329` gates on
`type == "auth_request"`, `version == 2`, and
`stage ∈ {"initial", "proof"}`. This section closes the coordinator-side
normative documentation gap, matching the SPEC-001 v1.3 §6.7
binary-side closure. The legacy `hello` parser remains the reconnect
path for SPEC-011 WS-drop cases per SPEC-001 v1.3 R-6.7.9 / R-6.11.4.

#### 7.8.1. Initial-stage frame (P->C)

R-7.8.1 The coordinator MUST accept a v2 initial-stage frame with the
SPEC-010 v1.5 §3.1.A field set and MUST process it through
`parseAuthInitial` at
`phase4-coordinator/internal/ws/messages.go:333-388`, per SPEC-010
v1.5 R-3.1.1 through R-3.1.10 and SPEC-001 v1.3 R-6.7.1.

| Field | JSON name | Type | Parser requiredness | Binding source |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | SPEC-010 v1.5 §3.1.A / R-3.1.1 |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | SPEC-010 v1.5 §3.1.A |
| Stage | `stage` | string, exactly `"initial"` | REQUIRED by frame validator | SPEC-010 v1.5 §3.1.A |
| Provider ID | `provider_id` | string ULID | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Hostname | `hostname` | string | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Loaded model | `model_id` | string | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Model hash | `model_hash` | string sha256-hex | optional | SPEC-008 v0.3 §5.3-§5.6 |
| Model params (B) | `model_params_b` | float | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| RAM (GB) | `ram_gb` | int | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Max context tokens | `max_context_tokens` | int | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Max concurrency | `max_concurrency` | int | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Throughput TPS estimate | `throughput_tps_estimate` | float | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Model load time | `model_load_time_ms` | int64 | optional | SPEC-010 v1.5 §3.1.A |
| Binary version | `binary_version` | string | REQUIRED by `parseAuthInitial` | SPEC-010 v1.5 §3.1.A |
| Endpoint URL | `endpoint_url` | string pointer (nullable) | optional | SPEC-010 v1.5 §3.1.A |
| Provider ECDH public key | `provider_ecdh_public_key` | string base64 | REQUIRED by `parseAuthInitial` | SPEC-008 v0.3 |
| Tier-2 capabilities | `tier2_capabilities` | object `{encrypted_leg: bool, attestation: bool, aead_suites: []string}` | REQUIRED by `parseAuthInitial` | SPEC-008 v0.3 |
| Supported models | `supported_models` | array of strings | optional SPEC-010 field; v1.3 binary emits single-entry default | SPEC-010 v1.5 R-3.1.1 through R-3.1.9 / R-3.6.2 |
| Publishes supported models | `publishes_supported_models` | bool | optional SPEC-010 field | SPEC-010 v1.5 R-3.1.6 / R-3.6.4 |

R-7.8.2 The 11 parser-required data fields in SPEC-010 v1.5 §3.1.A
MUST be treated as required even if a Go struct tag is `omitempty`:
`provider_id`, `hostname`, `model_id`, `model_params_b`, `ram_gb`,
`max_context_tokens`, `max_concurrency`, `throughput_tps_estimate`,
`binary_version`, `provider_ecdh_public_key`, and
`tier2_capabilities`. This is the current coordinator parser contract
per SPEC-010 v1.5 R-3.1.1 through R-3.1.10 / AC-16 and SPEC-001 v1.3
R-6.7.1 / AC-18.10.

R-7.8.3 The optional SPEC-010 fields on the initial-stage frame MUST
populate `Provider.SupportedModels` and `Provider.PublishesSupportedModels`
per §3 Provider data model and SPEC-010 v1.5 R-3.3.1 / R-3.3.2. The
L-1 baseline accepts a v1.3 binary's `supported_models: [model_id]`
single-entry frame and treats it as functionally indistinguishable from
a pre-SPEC-010 binary per SPEC-010 v1.5 §4.1 and SPEC-001 v1.3
AC-18.0.

R-7.8.4 The coordinator MUST apply SPEC-010 field validation in the
order mandated by SPEC-010 v1.5 R-3.1.9: JSON type, per-entry byte
length, array length, normalized duplicate check, then `model_id`
containment. Rejection reason strings MUST trace to SPEC-010 v1.5
AC-17 / AC-22 / AC-23.

#### 7.8.2. Proof-stage frame (P->C)

R-7.8.5 The coordinator MUST accept a v2 proof-stage frame with the
SPEC-010 v1.5 §3.1.C field set and MUST process it through
`parseAuthProof` at `phase4-coordinator/internal/ws/messages.go:391-401`,
per SPEC-010 v1.5 R-3.1.10 and SPEC-001 v1.3 R-6.7.4.

| Field | JSON name | Type | Parser requiredness | Binding source |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | SPEC-010 v1.5 §3.1.C |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | SPEC-010 v1.5 §3.1.C |
| Stage | `stage` | string, exactly `"proof"` | REQUIRED by frame validator | SPEC-010 v1.5 §3.1.C |
| Auth attempt ID | `auth_attempt_id` | string | REQUIRED by `parseAuthProof` | SPEC-010 v1.5 R-3.1.10 |
| Provider ID | `provider_id` | string | REQUIRED by `parseAuthProof`; must match initial-stage value | SPEC-010 v1.5 R-3.1.10 |
| Attestation token | `attestation_token` | JSON raw | conditional per Tier-2 negotiation | SPEC-008 v0.3 |
| Supported models | `supported_models` | array of strings | optional SPEC-010 proof-stage field | SPEC-010 v1.5 R-3.1.10 |
| Publishes supported models | `publishes_supported_models` | bool | optional SPEC-010 proof-stage field | SPEC-010 v1.5 R-3.1.10 |

R-7.8.6 The proof-stage `auth_attempt_id` MUST match the
coordinator-generated value emitted in the prior `auth_challenge`, and
`provider_id` MUST match the initial-stage provider ID, per SPEC-010
v1.5 R-3.1.10 and SPEC-001 v1.3 R-6.7.5. Current code enforces the
provider-ID match at `phase4-coordinator/internal/ws/server.go:398`.

R-7.8.7 Proof-stage SPEC-010 fields MUST follow SPEC-010 v1.5
R-3.1.10: absent `supported_models[]` or absent
`publishes_supported_models` is accepted and performs no comparison;
present values MUST match the retained initial-stage values after NFC
normalization and ASCII case-fold per SPEC-010 v1.5 R-3.1.7. Mismatch
MUST be rejected with `auth_response.error.code = "bad_request"` and
reason text containing `"supported_models mismatch between auth_request
stages"` (the exact substring mandated by SPEC-010 v1.5 R-3.1.10
clause 4 and SPEC-010 AC-18(c); this is the locked test oracle).

R-7.8.8 `attestation_token` handling remains bound to SPEC-008 v0.3
§5.3-§5.7 and SPEC-001 v1.3 R-6.7.4. v1.3.5 documents the field
location in the v2 proof-stage frame but adds no encrypted-leg,
attestation, TEE, or Tier-2 expansion beyond current SPEC-008 behavior.

#### 7.8.3. Auth-attempt ID source-of-truth

R-7.8.9 The coordinator MUST generate `auth_attempt_id` only after
successful initial-stage parse, at
`phase4-coordinator/internal/ws/server.go:354`
(`authAttemptID := "auth-" + s.newUUID()`), per SPEC-010 v1.5
R-3.1.10 and SPEC-001 v1.3 R-6.7.5. The coordinator MUST attach this
ID to the outgoing `auth_challenge` frame and MUST expect the proof
stage to echo it verbatim. Implementations MUST NOT trust a
client-supplied `auth_attempt_id` on the initial stage; `parseAuthInitial`
does not read it per SPEC-010 v1.5 §3.1.A.

### 7.9. Auth-attempt lifecycle (NEW in v1.3.5)

SPEC-010 v1.5 §6.2 states that until SPEC-002 v1.3.5 lands,
SPEC-010 R-3.1.10 clauses 1 and 5 are the source of truth for the
auth-attempt retention lifecycle as it interacts with SPEC-010. This
new §7.9 now takes over as the coordinator-side state-management source
of truth. SPEC-010 v1.5 R-3.1.10 clauses 1 and 5 remain the wire-side
binding contract for the SPEC-010 fields.

#### 7.9.1. Lifecycle events

R-7.9.1 On initial-stage parse success, the coordinator MUST generate
`authAttemptID` at `phase4-coordinator/internal/ws/server.go:354` and
compute `challengeExpiresAt := s.now().Add(10 * time.Minute)` at
`phase4-coordinator/internal/ws/server.go:355`, per SPEC-010 v1.5
R-3.1.10 and SPEC-001 v1.3 R-6.7.5.

R-7.9.2 The outgoing `auth_challenge` MUST carry the generated
`auth_attempt_id` and an explicit expiry timestamp derived from
`challengeExpiresAt`, per SPEC-010 v1.5 R-3.1.10.

R-7.9.3 The coordinator MUST retain per-attempt state keyed by the
generated `auth_attempt_id` in `AuthAttemptRetention` per §3 data model
and SPEC-010 v1.5 R-3.1.10. State includes any retained SPEC-010 values,
challenge details, generated ID, `provider_id`, start timestamp, and
expiry timestamp.

R-7.9.4 Per-attempt state MUST be released on any terminal path:
successful proof-stage completion and provider registration,
proof-stage rejection for any reason, expiry timeout, WebSocket
disconnect-before-proof, proof read/parse error, or challenge write
failure. This is the coordinator-side lifecycle takeover from
SPEC-010 v1.5 R-3.1.10 clause 5.

#### 7.9.2. Timeout bound

R-7.9.5 The auth-attempt timeout is 10 minutes, matching
`challengeExpiresAt := s.now().Add(10 * time.Minute)` at
`phase4-coordinator/internal/ws/server.go:355`, per SPEC-010 v1.5
R-3.1.10 and SPEC-001 v1.3 R-6.7.5.

R-7.9.6 Implementations MUST bound aggregate retention map size as a
defensive safeguard per SPEC-010 v1.5 R-3.1.10. Recommended bound:
1024 in-flight auth attempts per coordinator instance; when exceeded,
reject new initial-stage attempts with `auth_response.error.code =
"too_many_auth_attempts"` and a 503-class WebSocket close code drawn
from the existing close-code registry. The current unauthenticated
connection cap (`ws.max_unauthenticated_conn`, default 64 at
`phase4-coordinator/internal/config/config.go:269`) remains an
additional operational bound.

#### 7.9.3. Release implementation

R-7.9.7 Retention release MUST be implemented with an
auth-attempt-scoped `defer releaseRetention(authAttemptID)` installed
immediately after retention entry creation and before `auth_challenge`
emission, per SPEC-010 v1.5 R-3.1.10 clause 5. The release call MUST
live at the auth-attempt scope between initial-stage parse acceptance
and final session registration, not only in session-level
`handleDisconnect`, so pre-proof failures release state synchronously.

R-7.9.8 The L-1 baseline presence gate from SPEC-010 v1.5 R-3.1.10
clause 1 remains binding: if an initial-stage frame has neither
`supported_models` nor `publishes_supported_models` present, the
coordinator MUST NOT create SPEC-010 retention state, MUST NOT install
the SPEC-010 retention defer, and MUST NOT increment retention metrics.

### 7.10. Audit-log infrastructure (NEW in v1.3.5)

SPEC-002 v1.3.4 does not currently define a normative audit-log
infrastructure section. SPEC-005 v0.3 documents the `request_log` table
for per-request accounting and billing; this section adds a separate
operator-action audit log for coordinator-observed operator-side
actions. v1.3.5 defines one event type: `operator_model_swap`.

#### 7.10.1. Audit-log table requirement

R-7.10.1 The coordinator MUST persist audit-log entries to a durable
store for SPEC-011 operator-side events per SPEC-011 v0.5 §3.6
R-3.6.1 / R-3.6.2. Implementations SHOULD use SQLite, matching
`request_log` storage, with this schema:

```sql
CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX idx_audit_log_ts_utc ON audit_log(ts_utc);
CREATE INDEX idx_audit_log_provider_id ON audit_log(provider_id);
CREATE INDEX idx_audit_log_event_type ON audit_log(event_type);
```

R-7.10.2 `ts_utc` MUST be RFC3339 in UTC. `payload_json` MUST be a
well-formed JSON object whose schema depends on `event_type`. The table
retention policy follows §7.7 / §13 `storage.audit_log_retention_days`
with default 90 days, mirroring `request_log_retention_days`, per
SPEC-011 v0.5 §3.6 R-3.6.1 / R-3.6.2 and SPEC-002 v1.3.5 AC-K.14.

#### 7.10.2. `operator_model_swap` event type (NORMATIVE)

R-7.10.3 Per SPEC-011 v0.5 §3.6 R-3.6.1 through R-3.6.6, the
coordinator MUST emit `operator_model_swap` when a SPEC-011 warm swap
completes under the §7.1 ApplyHeartbeat REPLACEMENT emission gate
(R-7.1.6), subject to the conditional-emission rule in R-7.10.10 below.
The payload schema is byte-for-byte SPEC-011 v0.5 §3.6 (LOCKED) — field
names, types, and units are NORMATIVE and MUST NOT be renamed or
restructured:

```json
{
  "event": "operator_model_swap",
  "ts": "2026-06-06T14:23:09.123Z",
  "provider_assigned_id": "p_01HK4Z3VYE...",
  "from_model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "to_model_id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
  "from_model_hash": "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f",
  "to_model_hash": "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1a0f9e8d",
  "loading_window_ms": 18243,
  "hash_verification_result": "hash_verified",
  "drain_inflight_count_estimate": 2
}
```

R-7.10.4 Payload field requiredness, per SPEC-011 v0.5 R-3.6.1 /
R-3.6.2:
- **REQUIRED (8 fields):** `event`, `ts`, `provider_assigned_id`,
  `from_model_id`, `to_model_id`, `to_model_hash`,
  `loading_window_ms`, `hash_verification_result`.
- **OPTIONAL (2 fields):** `from_model_hash` (MAY be empty string
  or null if the prior `model_hash` was not recorded);
  `drain_inflight_count_estimate` (MAY be omitted;
  observability-only).

Coordinator MUST populate the REQUIRED fields and MAY omit the
OPTIONAL fields. No other top-level keys are part of the v1.3.5
contract; future event types or future payload extensions are out of
scope per §7.10.3.

R-7.10.5 The `provider_assigned_id` field MUST be the per-session
coordinator-issued `AssignedID` (see `Provider.AssignedID` in the
data model), NOT the operator-issued `provider_id`. This matches the
SPEC-011 v0.5 §3.6 example payload semantics and SPEC-002's existing
distinction between operator-issued `provider_id` and per-session
`assigned_id`.

R-7.10.6 `loading_window_ms` MUST be computed as the wall-clock
duration (integer milliseconds) from the FIRST observed heartbeat
with `loading: true` to the FIRST observed heartbeat with
`loading: false` carrying the new `model_id`, using the coordinator
clock (NOT provider-reported timestamps), per SPEC-011 v0.5 R-3.6.3.
Implementations MUST record the loading-start timestamp on the
`Provider` struct when the LEGACY-or-SPEC-011-PATH heartbeat first
flips `LastLoadingState` from `false` to `true`, and compute the
duration at swap-completion emission time.

R-7.10.7 `hash_verification_result` MUST be exactly one of SPEC-008
v0.3 §5.5's five states — `"hash_verified"`, `"hash_mismatch"`,
`"hash_invalid"`, `"uncatalogued"`, `"catalog_unavailable"` — per
SPEC-011 v0.5 R-3.6.4. No sixth state is permitted. The value MUST
be derived from the SPEC-008 Pillar A re-verification run in §7.1
R-7.1.5.

R-7.10.8 The `operator_model_swap` event MUST be emitted EXACTLY ONCE
per completed swap, enforced by the §7.1 R-7.1.6 `LastLoadingState`
sticky reset, per SPEC-011 v0.5 R-3.3.5 / R-3.6.3 / AC-20. Emission
MUST be best-effort: audit-log write failure MUST NOT block heartbeat
processing or trigger a provider drop. Failures MUST be logged at
WARN level with the full payload available in process logs for
forensic recovery.

R-7.10.9 **F-1.5 payload invariants (per SPEC-011 v0.5 R-3.6.5).**
The `operator_model_swap` payload MUST NOT include `conv:` prefixed
strings, raw `account_id` values, sticky session identifiers, buyer
prompt text, or any input that could feed sticky derivation. This is
the L-6 F-1.5 survivability invariant inherited from SPEC-006 v0.8.1
and MUST be enforced by static review (grep for the prohibited
substrings against payload-building code) plus a runtime regression
test that asserts the payload of a real swap event contains none of
the prohibited tokens.

R-7.10.10 **Conditional emission (per SPEC-011 v0.5 R-3.6.6 + §3.8
C.2.2 outline decision).** The `operator_model_swap` event fires
ONLY when the coordinator observed the `loading: true → loading: false`
transition on a CONNECTED WS session. If the WS dropped during the
loading window (per SPEC-011 v0.5 §3.8) and the provider reconnected
AFTER the swap completed, the first heartbeat on the new session
arrives with the new `model_id` and `loading: false` but WITHOUT a
preceding `loading: true` on the current session — in that case NO
`operator_model_swap` event fires. This is the documented
observation-only audit invariant; operators who require complete
swap audit history MUST keep WS sessions alive during swaps
(typical load: 20-30 seconds; WS sessions are persistent and rarely
drop on that scale per SPEC-011 v0.5 §3.6 prose). Reconnect during
load (first post-reconnect heartbeat has `loading: true` with the
OLD `model_id`) DOES re-establish the `LastLoadingState` sticky on
the new session, so a subsequent `loading: false` heartbeat with the
new `model_id` WILL emit the event normally per SPEC-011 v0.5
§3.6 R-3.6.6 rationale block.

#### 7.10.3. Future event types

R-7.10.11 The audit-log infrastructure MAY support additional event
types in future revisions, but v1.3.5 ships exactly one normative event
type, `operator_model_swap`, per SPEC-011 v0.5 §3.6 R-3.6.1 through
R-3.6.6. No SPEC-005 billing or request-log semantics are changed by
this section.

---

## 8. Dependencies and references

### 8.1. Direct dependencies

| Dependency | License (SPDX) | Version pin | Purpose |
|---|---|---|---|
| Go | BSD-3-Clause | 1.22+ | Language runtime |
| [github.com/gobwas/ws](https://github.com/gobwas/ws) | MIT | v1.4.0 | WebSocket server (zero-alloc upgrade) |
| [github.com/go-chi/chi/v5](https://github.com/go-chi/chi) | MIT | v5.1.0 | HTTP routing (lightweight, stdlib-compatible) |
| [modernc.org/sqlite](https://gitlab.com/cznic/sqlite) | BSD-3-Clause | v1.33.0 | Pure-Go SQLite (no cgo, no C compiler needed) |
| [github.com/rs/zerolog](https://github.com/rs/zerolog) | MIT | v1.33.0 | Structured JSON logging |
| [github.com/google/uuid](https://github.com/google/uuid) | BSD-3-Clause | v1.6.0 | UUID generation for request IDs and assigned IDs |
| [gopkg.in/yaml.v3](https://github.com/go-yaml/yaml) | MIT | v3.0.1 | YAML config file parsing |

**Runtime requirements:** Go 1.22+, Linux amd64 (deployment target).
Cross-compilation from macOS: `GOOS=linux GOARCH=amd64 go build`.

**Deployment:** VPS at 165.22.182.207 (existing AntFeed VPS). The
coordinator runs on a different port than the existing AntFeed services.
Managed by systemd. TLS termination by Caddy reverse proxy.

**These are the required v1.0.1 pins.** The build session may bump only
with an explicit entry in `phase4-coordinator/implementation-notes.html`
documenting the new version, commit SHA, and a brief rationale (e.g.,
"security patch", "API I depend on shipped"). A bump without an entry is
a deviation that should be flagged on review.

### 8.2. Reference hygiene — strict clean-room for d-inference

This section is adapted from SPEC-001 § 7.2 with coordinator-specific
additions (Go-specific permitted dependencies and SQLite-related
references). The substantive policy is identical to SPEC-001 § 7.2.
Same policy applies
to the coordinator.

PROHIBITED references for this spec and the Phase 4 coordinator build:
- The d-inference GitHub repository
  (https://github.com/Layr-Labs/d-inference)
- Any d-inference source files, including the README and config files
- Any third-party analyses that quote or reproduce d-inference source
- Reverse-engineered analyses of any compiled Darkbloom binary

Reason: the DARKBLOOM LICENSE AGREEMENT (Eigen Labs, Inc., copyright
2026; SPDX NOASSERTION; canonical URL
https://github.com/Layr-Labs/d-inference/blob/master/LICENSE as
inspected 2026-05-27) explicitly prohibits in Section 3 the use of the
Software to "provide, operate, or enable any hosted service, platform,
marketplace, or product that offers AI inference coordination, private
inference services, or decentralized compute marketplace capabilities
that compete with Darkbloom." Mac Provider fits this description.

PERMITTED references:
- Darkbloom / Eigen Labs published academic papers (cite by URL/DOI)
- Darkbloom blog posts, conference talks, marketing pages (public)
- Third-party reviews that do NOT reproduce d-inference source
- SPEC-001 (this repo) — the Phase 3 binary spec
- Phase 1 results, Phase 2 decision criteria, harness.py
- OpenAI API reference
- WebSocket protocol RFC 6455
- Go standard library documentation
- Library documentation for dependencies listed in 8.1

Patent analysis: same as SPEC-001. Darkbloom holds patents around their
privacy/attestation model. Tier 1 of the coordinator does not implement
that model; Tier 2 hooks are designed-in but unimplemented. Patent risk
analysis for Tier 2 is deferred to its eventual SPEC.

If during implementation you are uncertain how Darkbloom solved a
problem, STOP and add an open question to
`implementation-notes.html`. Do not resolve it by reading their source.

### 8.3. Public spec sources

- SPEC-001 v1.1.1 (this repo) — Phase 3 binary protocol contract
- [OpenAI API reference](https://platform.openai.com/docs/api-reference/chat)
  — chat completions request/response schema
- [WebSocket protocol RFC 6455](https://tools.ietf.org/html/rfc6455)
  — wire protocol
- [HuggingFace model card schema](https://huggingface.co/docs/hub/model-cards)
  — model ID conventions

### 8.4. Internal sources

- `specs/SPEC-001-phase3-binary.md` — wire protocol contract
- `beta/DECISION_CRITERIA.md` — Phase 2 decision log
- `beta/harness.py` — first buyer implementation
- `beta/PHASE2_UPGRADED_PLAN.md` — routing mode evolution
- `doc/PHASE1_REPORT.md` — Phase 1 evidence

---

## 9. SPEC-001 protocol compatibility

Coverage matrix listing every message in SPEC-001 section 6.5 and the
corresponding SPEC-002 coverage.

| SPEC-001 section 6.5 message | Direction | SPEC-002 coverage | Notes |
|---|---|---|---|
| `hello` | P->C | FR-P1, FR-P2, FR-P12, FR-P13 | Validate fields, check auth, check tier, register in pool |
| `hello_ack` | C->P | FR-P2 | Coordinator generates assigned_id, sets heartbeat interval |
| `heartbeat` | P->C | FR-P4, FR-P8 | Update pool state; detect wake events from heartbeat gaps |
| `state_update` | P->C | FR-P5 | Update state, adjust routing eligibility |
| `drain_status` | P->C | FR-P6 | Log progress, expect WebSocket close on "complete" |
| `preflight` | C->P | FR-P7, FR-B5, FR-R5 | Sent before routing large requests; 5s timeout |
| `preflight_ack` | P->C | FR-P7, FR-R5 | Accept or reject; rejection reasons per SPEC-001 |
| `drain` | C->P | FR-P9, FR-O3 | Sent on coordinator shutdown or operator blacklist |
| `warm_up` | C->P | FR-P8 | Sent after wake detection (heartbeat gap > 120s) |
| `nak` | P->C | § 7.1 (receive from provider) | Informational; coordinator logs at warn, does not disconnect provider |
| (WS close, not nak) | C→provider close | FR-P2, FR-P13 | Coordinator rejects invalid provider connections via WebSocket close codes 4001–4005 / 4429 (see FR-P13 table). SPEC-001 § 6.5 does not define a C→P `nak` direction; coordinator never sends one. |

**Verification:** Every message type in SPEC-001 section 6.5 maps to at least
one FR in SPEC-002. No gaps.

---

## 10. Phase 1 + Phase 2 findings that SPEC-002 must encode

### D1 — 502 vs 530 routing distinction

**Observation:** M4 sleep transition produced HTTP 502 (Cloudflare
tunnel up, mlx_lm.server down, persisted ~14 min) then HTTP 530 (full
tunnel disconnect). Tunnel API `conns_active_at` lagged actual
buyer-visible failure.

**SPEC-002 encoding:**
- **FR-P11** (failure mode distinction): Coordinator distinguishes
  WebSocket disconnect (530-equivalent) from HTTP 502 on routed
  requests. Different recovery strategies for each.
- **FR-P10** (disconnect detection): Grace period allows transient
  reconnection without pool removal.
- **Explicit rejection of `cfd_tunnel` polling.** The Phase 2 decision
  log suggested the coordinator could poll Cloudflare's tunnel API
  (`conns_active_at` field) to predict imminent provider drops. SPEC-002
  v1 deliberately does NOT do this. Rationale: (a) Cloudflare's API is
  rate-limited and would require credential management; (b) our own
  WebSocket health + per-request HTTP signals are sufficient for v1
  routing decisions; (c) `conns_active_at` lags actual buyer-visible
  failure by minutes anyway. Accepted failure mode: the coordinator may
  route to a provider in the brief window between `cloudflared` losing
  edge connection and the WebSocket close being detected (≤ heartbeat
  interval, ~15s). That window manifests as HTTP 502/530 on the routed
  request and is handled by FR-P11.
- **Literal HTTP 530** (Cloudflare-edge "tunnel daemon disconnected" code,
  observed directly on a routed buyer request) is treated as a distinct
  normative signal per FR-P11: mark `unavailable` immediately, log
  `state_update.reason = "http_530_observed"`, and close the active
  provider WebSocket. Removed from pool until the WebSocket reconnects
  with fresh hello. This was previously open question OQ-1; resolved as
  normative in v1.0.2.

### D2 — Post-wake throughput dip

**Observation:** M4 post-wake first request was -12% throughput vs
baseline.

**SPEC-002 encoding:**
- **FR-P8** (warm_up dispatch): Coordinator detects wake events via
  heartbeat gap > 120s and sends `warm_up` command. Provider runs
  synthetic inference before accepting real traffic.
- Coordinator marks provider as `degraded` during warm-up even if the
  provider reports `ready` — Phase 2 data shows the first real request
  is still slower.

### D4 — Capacity-vs-quality routing tradeoff

**Observation:** Llama 3B on M1 8GB (22-25 tok/s) outperformed Qwen 7B
on M4 16GB (17-20 tok/s). Even TTFT favored M1.

**SPEC-002 encoding (scoped to "same model" tradeoff in v1):**
- **FR-R2** (buyer preference header): Among providers serving the
  SAME `model_id`, `X-MacProvider-Pref: fast` selects highest
  `throughput_tps_estimate`; `X-MacProvider-Pref: accurate` selects
  highest `model_params_b` (mostly relevant when one provider runs a
  quantization variant of the same family).
- **FR-R1** (default routing): Uses `throughput_tps_estimate` as a
  tie-breaker among same-model candidates, not `model_params_b`. The
  coordinator does NOT assume bigger hardware = faster.

**Explicitly deferred to SPEC-004 (smart router):** the broader D4
tradeoff — auto-routing between *different model families* (Llama 3B vs
Qwen 7B vs Qwen 14B) by latency/quality preference — requires a
model-class abstraction (aliases like `mlx-fast`, `mlx-balanced`,
`mlx-accurate`) that is properly a SPEC-004 concern. In v1, buyers
choose by exact `model_id` via `/v1/models` discovery, then optionally
refine within that model_id via `X-MacProvider-Pref`.

This means AC-9 in § 11 tests `X-MacProvider-Pref` behavior with two
providers serving the same `model_id` (a deliberately constrained test)
and explicitly does NOT validate cross-model routing.

### D5 — Timeline compression

**Classification:** Process-only. No coordinator behavior. Timeline
compressed from 14 days to 3 days. Phase 3 build started 11 days
sooner. No FR mapping.

### D6 — Phase 4 local acceptance findings (2026-05-28, v1.0.4)

**Source:** AC-2/AC-3/AC-6 closed locally via the Go mock-provider
toolkit at `phase4-coordinator/tools/mockprovider/`. All three findings
are operator-visible properties of the as-built coordinator, not bugs
and not FR changes — they are documented here so SPEC-002 prose matches
deployment reality.

**F-1 — Order-sticky routing under equal metrics.** The default sort
(`SlotsFree ASC, Throughput DESC, connected_at ASC`) is stable and slot
counts are decremented only on heartbeat tick. With two identical
providers in steady state, every primary key is equal and the
`connected_at` tertiary tiebreak fires every time, so all traffic routes
to whichever provider connected first until metrics diverge. See § 5
"Operator-visible behavior under equal metrics" for the normative
clarification. A future SPEC-004 may introduce a randomized tiebreak
with tolerance ε; v1 deliberately does not, to keep audit logs
reproducible.

**F-2 — Dynamic provider registration is not supported.** A `hello`
whose `provider_id` is not in `config.providers[]` is rejected with WS
close code **4002 `unknown_provider_id`** (already normative in § 7.1 +
FR-P13). The v1.0.4 clarification: this means every provider that may
ever connect to a given coordinator instance MUST be enumerated in the
operator's static config map before its first connection attempt;
adding a new provider requires editing the config and restarting (or
SIGHUP, when implemented). v1 does NOT support on-the-fly registration,
auto-discovery, or provider self-enrollment. This is by design —
operator approval of each `provider_id` is the v1 trust-pool admission
mechanism (per § 2 Tier 1 launch scope). SPEC-005/006 may relax this.

**F-3 — Operator endpoints live on the provider WS port.** All
operator-facing endpoints (`/healthz`, `/poolz`, `/admin/*`) are mounted
on `listen.provider_port` (default 8444), not `listen.buyer_port`
(default 8443). See § 7.4 "Port placement" for the normative
clarification.

**Why these surfaced in Phase 4 but not in spec audits.** All three
were latent in the audited spec text — F-1 was implicit in "stable sort
by connected_at" but not called out as an operator-visible behavior;
F-2 was implicit in close code 4002 but the operational implication for
deployment runbooks was not stated; F-3 was implicit in the architecture
diagram (§ 3) listing operator endpoints inside the same coordinator
box as the WebSocket server, but no section spelled out "same port as
provider WS." The Phase 4 local-acceptance harness made the operator
implications visible by forcing explicit decisions during test-script
authoring. Lesson for future specs: when an audit produces "this is
implicit in section X" answers to operator-runbook questions, prefer
to make the operator-visible behavior explicit in the user-facing
section (§ 5, § 7.4) even when it is a derived consequence of normative
text elsewhere.

### D7 — Static config-map relaxed to provisional tier (v1.1, from SPEC-003 v0.1)

**Source:** SPEC-002 v1.0.4 Finding F-2 + Decision log Entry 18.

**Finding:** F-2's "every provider_id must be in config.providers[]"
blocks supply-side growth beyond operator-vetted partners.

**SPEC-002 v1.1 encoding:**
- FR-P15 (three admission tiers): pinned / provisional / rejected.
- FR-P16 (rate limits): Prevents abuse of relaxed admission.
- § 7.1 (F-2 amendment): Formal relaxation.
- § 7.5 (operator endpoints): promote, reject.

### D8 — Coordinator drain MUST NOT terminate WS-tunneled inference

**Source:** Decision log Entry 15. phase3-binary v1.1.2 called exit()
on coordinator drain. Fixed in v1.1.3.

**SPEC-002 v1.1 encoding:**
- FR-P14 (WS relay): WS-tunneled providers complete in-flight
  inference before closing. Coordinator drain → provider finishes
  responses → WS close → reconnect.
- This is now load-bearing: WS-tunneled providers have no fallback
  path during coordinator drain (unlike pinned providers who serve
  via tunnel).

### D9 — model_id case-insensitive comparison

**Source:** Decision log Entry 18. M1 cron 404 storm from
case-sensitive model_id comparison.

**SPEC-002 v1.1 encoding:**
- § 5 routing algorithm: model match amended from exact string
  equality to case-insensitive comparison. Canonical form preserved
  in storage and GET /v1/models.

### D10 — Coordinator overhead for WS-tunneled path

**Source:** Decision log Entry 14. HTTP-forwarding adds <100 ms. WS-
tunneled adds estimated 10-50 ms on top (JSON serialization,
demultiplexing, SSE reassembly).

**SPEC-002 v1.1 encoding:**
- FR-P14 (WS relay): Validation method in AC-11 measures TTFT for
  WS-tunneled vs HTTP-forwarding. Delta SHOULD be <100 ms.

### D11 — Cross-service request correlation

**Source:** `specs/SPEC-CROSS-006-audit.md`, D-CROSS-3.

**SPEC-002 v1.1.4 encoding (superseded by v1.4.2 R-2 + v1.5.0 below):**
Coordinator honors inbound `X-Request-ID` on buyer `/v1/*` requests,
records it in `request_log`, forwards it as the provider
`inference_request.request_id`, MAY generate a UUID v4 for legacy direct
traffic, and treats propagation gaps as audit findings.

**SPEC-002 v1.4.2 R-2 + v1.5.0 encoding (current):**
Coordinator persists the inbound `X-Request-ID` into
`request_log.external_request_id` (v1.4.2 R-2) and the gateway-
forwarded `X-MacProvider-Account` into `request_log.account_id`
(v1.5.0). Coordinator-internal `request_log.request_id` is
generated locally as a UUID v4 and is the value forwarded to the
provider as `inference_request.request_id`. The composite
`(account_id, external_request_id)` is the cross-service
reconciliation key joining coordinator `request_log` to gateway
`usage_events`; `external_request_id` alone is a logical join
key only and is ambiguous on cross-account collisions after #196.
Direct legacy traffic without either header writes rows with
NULL on both columns and falls back to coordinator-internal
correlation; propagation gaps on either header remain audit
findings.

---

## 11. Acceptance criteria

### Audit category I — production-config gates

**I.1 "Always-non-nil gate" anti-pattern.** Check for code paths gated
by a non-nil pointer or a boolean that is set to the gate-open value
unconditionally in every test setup. A test where the gate is in its
closed state must exist; if the closed-state behavior cannot be
exercised in unit tests, an integration test with the gate configured
closed MUST exist. The 2026-05-28 coordinator hotfix (Decision log Entry
19) is the reference example: `WithTokenValidator(tokenStore)` was
called unconditionally, `s.tokenValidator != nil` was therefore always
true, and no test exercised the "no token validator configured" path.
The production deployment with `auth.require_provider_tokens=false`
then caused unconditional pinned-provider rejection that no audit had
caught. Generalize: every conditional in production code needs at least
one test case for each branch, including the "this branch only fires
when the operator chooses the rare config" branch.

**I.2 "Default-permissive flag in production deployment" anti-pattern.**
Some configuration flags are correctly default-permissive for developer
convenience or backward-compatibility but MUST be set to the restrictive
value for any public production deployment. The flag's default is the
development or cooperative-trust setting; production deployment of
services exposing public interfaces MUST flip these flags as part of
the deployment runbook.

Reference example: `auth.require_provider_tokens` defaults `false` for
the Tier 1 cooperative pool but is a production invariant `true` per
§ 7.7 PG-1.

Auditors of future specs MUST identify default-permissive flags that
need production-invariant counterparts. If a flag's default differs
from its production-correct value, the spec MUST document the
production invariant explicitly using the § 7.7 pattern introduced in
v1.1.5.

### Audit category J — operational-threshold realism

**J.1 Thresholds and timeouts MUST be validated against the slowest
realistic provider/workload, not merely "works as coded."** Confirming a
timeout/threshold fires correctly is necessary but not sufficient; the audit
MUST also ask whether the value is operationally viable for the real fleet.
Reference example: the v1.1.6 missed-heartbeat monitor closed a provider
WebSocket after `heartbeat_interval_s + failover_timeout_s` (35s). The audit
verified the close fired as coded, but 35s was below a single normal
completion on a single-slot MLX provider (a ~0.6 tps box hit it on ~20
tokens), so every non-trivial inference was killed mid-request in production —
a HIGH-severity functional regression the audit passed. (Fixed in v1.1.7 by
activity-based liveness under `pool.heartbeat_miss_threshold_s`.) Generalize:
for every timeout, threshold, retry count, and window, the auditor MUST state
the slowest realistic provider/workload it is measured against and confirm
adequate margin.

**J.2 Cross-component timer relations MUST be checked for ORDERING, not just
presence.** When two components each enforce a timeout on the same operation,
verify the intended ordering, not merely that both are "set." Reference
example: coordinator `routing.request_timeout_s` and gateway
`timeouts.coordinator_request_seconds` were both 300s; equal timers let a
gateway-initiated cancel race the coordinator relay-timeout, so a slow
non-streaming provider could escape FR-P11a breaker attribution (the C2
finding). The coordinator value SHOULD be strictly below the gateway value.
A deploy-time assertion (`dist/check-deploy-config.sh`) now flags this.

**AC-1 through AC-10 must ALL pass for the coordinator to be considered
build-complete. No partial passes. No operator waivers without an
explicit waiver entry in `implementation-notes.html`.**

**AC-1. Provider lifecycle (mock).**
A mock Phase 3 binary connects via WebSocket, exchanges hello/hello_ack,
sends 5 heartbeats at the configured interval, receives a drain command
on coordinator shutdown, sends drain_status, and closes cleanly.

Run by: `phase4-coordinator/scripts/test-provider-lifecycle.sh`

**AC-2. Cooperative batch through coordinator.**
The buyer harness (`beta/harness.py`) with `tunnel_url` pointing at the
coordinator's HTTP endpoint runs a full cooperative batch against a pool
of 2 mock providers. Both mock providers respond with valid
SPEC-001-shaped responses. Result: 100% HTTP 200 from the coordinator.

Run by:
```
cd beta && python harness.py --config config-coord-test.yaml \
  --batch cooperative --verbose
```

The build session creates `config-coord-test.yaml` pointing
`tunnel_url` at the coordinator.

**AC-3. Adversarial workloads (mock pool).**
Adversarial workloads (`concurrent_burst_8way`, `retry_storm`,
`malformed_tool_call`) against a pool of 2 mock providers do not crash
the coordinator. `concurrent_burst_8way` traffic is distributed across
both providers. The coordinator remains healthy (passes `/healthz` with
200) within 10 seconds of workload completion. Zero HTTP 500 responses
from the coordinator.

Run by:
```
cd beta && python harness.py --config config-coord-test.yaml \
  --batch adversarial --verbose
```

**AC-4. Provider disconnect mid-buyer-request.**
During an in-flight streaming buyer request, the serving provider's
WebSocket disconnects. The coordinator returns a clean error SSE event
to the buyer and closes the stream (not a hang, not a silent retry).
The coordinator remains healthy.

Run by: `phase4-coordinator/scripts/test-provider-disconnect.sh`

**AC-5. Auth flow.**
1. Issue a token via `coordinator-cli issue-token --provider-id <provider_id>`.
2. Connect a mock provider with the issued token — succeeds.
3. Revoke the token via `coordinator-cli revoke-token`.
4. Disconnect and reconnect the mock provider with the revoked token —
   rejected with WS close 4005 `invalid_token`.
5. Issue a token for a different `provider_id`; connect with that token
   while sending the original provider's `hello.provider_id` — rejected
   with WS close 4005 `invalid_token`.

Run by: `phase4-coordinator/scripts/test-auth-flow.sh`

**AC-6. Graceful SIGTERM drain.**
With 3 in-flight buyer requests (streaming), sending SIGTERM to the
coordinator causes it to:
1. Stop accepting new requests.
2. Send drain to all providers.
3. Complete all 3 in-flight requests (or timeout after 30s).
4. Exit with code 0.

No response truncation. No hang.

Run by: `phase4-coordinator/scripts/test-sigterm-drain.sh` — script the
build session must produce as part of AC delivery. Fires 3 streaming
requests, captures PID, sends SIGTERM, asserts all 3 complete and
process exits 0 within 35s.

**AC-7. 502 degraded recovery.**
1. Mock provider is serving traffic normally.
2. Configure mock provider to return HTTP 502 on the next request.
3. Coordinator marks provider as `degraded`.
4. After 30s backoff, coordinator sends preflight — mock provider
   accepts.
5. Coordinator marks provider as `ready`, resumes routing.

Run by: `phase4-coordinator/scripts/test-degraded-recovery.sh`

**AC-8. 530 reconnection.**
1. Mock provider is serving traffic normally.
2. Mock provider closes WebSocket unexpectedly (no drain).
3. Coordinator marks provider as `unavailable`.
4. Within grace period, mock provider reconnects with new hello.
5. Coordinator registers provider as `ready`, resumes routing.
6. After grace period (second test): coordinator removes provider
   from pool.

Run by: `phase4-coordinator/scripts/test-reconnection.sh`

**AC-8b. Warm-up dispatch on wake.**
1. Mock provider connects, runs normally for 2 minutes (heartbeats every 30s).
2. Mock provider stops sending heartbeats for 130 seconds (>120s gap,
   simulates Mac sleep).
3. Mock provider resumes heartbeats.
4. Assert: coordinator sends `{"type": "warm_up"}` to the provider
   within 5s of the resumption heartbeat.
5. Assert: coordinator marks provider as `degraded` until either (a) the
   mock provider sends `state_update: ready`, or (b) 60s elapse with
   continuous heartbeats — whichever first.
6. Assert: while provider is `degraded`, buyer requests for that
   provider's model are NOT routed to it (FR-R4 filters to `state=ready`
   only). If no other ready provider serves the same model, buyer
   receives 503 `no_provider_available` until this provider exits
   degraded state.

Run by: `phase4-coordinator/scripts/test-warmup-dispatch.sh`

**AC-9. Capacity preference routing.**
Pool has 2 mock providers:
- Provider A: Llama 3B, throughput 25 tok/s, model_params_b 3.0
- Provider B: Qwen 7B, throughput 18 tok/s, model_params_b 7.0

Both serve the same model ID for testing purposes.

1. Request with `X-MacProvider-Pref: fast` routes to Provider A.
2. Request with `X-MacProvider-Pref: accurate` routes to Provider B.
3. Request with no preference routes per utilization (FR-R1).

Run by: `phase4-coordinator/scripts/test-routing-preference.sh`

**AC-10. Operator endpoints.**
1. `GET /healthz` returns 200 with pool size.
2. `GET /poolz` without auth returns 401.
3. `GET /poolz` with valid operator key returns 200 with provider list
   showing both `provider_id` (stable) and `assigned_id` (session) per
   entry.
4. `POST /admin/blacklist` with a valid `provider_id` returns 200 with
   `{status: "draining", provider_id, assigned_id, drain_sent: true}`.
5. **Two-phase observable behavior** (per § 7.4):
   - **Phase 1 (immediate):** within 1s of the blacklist POST, the
     provider's `state` in `/poolz` transitions to `draining`. The
     provider is no longer routed to (FR-R4 filters out non-`ready`).
   - **Phase 2 (deferred):** within 60s — or sooner if the mock provider
     sends `drain_status: complete` — the provider's WebSocket closes
     and the entry disappears from `/poolz` entirely.
6. POSTing `/admin/blacklist` with an unknown `provider_id` returns 404.

Run by: `phase4-coordinator/scripts/test-operator-endpoints.sh`

**AC-FR-B9-MULTI. request_log permits one row per provider attempt.**
A deterministic fixture sends one logical request through two SPEC-004 retry attempts (single account). The assertion is two `request_log` rows sharing the same `(account_id, request_id)` group, with distinct auto-increment `id` values, provider attribution per attempt, and row order within that group defined by `id ASC` under SQLite `IS` clustering (so legacy NULL-`account_id` fixtures cluster identically). No uniqueness constraint may reject the repeated `request_id` within an account.

Run by: `go test ./phase4-coordinator/... -run TestRequestLogMultiAttemptRows`

**AC-FR-B9-ERROR-CODE. request_log preserves SPEC-001 null-usage error codes.**
A deterministic null-usage error fixture returns SPEC-001 `inference_response_end.status="error_model_not_loaded"` with no usage object. The assertion is one `request_log` row whose `error_code` is exactly `error_model_not_loaded`, while success and non-SPEC-001 error paths keep `error_code` NULL.

Run by: `go test ./phase4-coordinator/... -run TestRequestLogErrorCodePopulation`

**AC-11. Provisional admission.**
Connect a mock provider with `provider_id` NOT in `config.providers[]`
and NOT in `rejected_providers`. Coordinator responds with `hello_ack`
containing `tier: "provisional"`. `GET /poolz` shows the provider with
`tier: "provisional"`. Buyer requests are routed to it (with reduced
weight).

Run by: `phase4-coordinator/scripts/test-provisional.sh`

**AC-12. Provisional rate limit.**
Configure `admission.provisional_rate_per_hour: 10`. Connect 11
provisional providers within 60 seconds. First 10 get `hello_ack`.
11th gets WS close code 4008.

Run by: `phase4-coordinator/scripts/test-rate-limit.sh`

**AC-13. admin/promote.**
Connect a provisional provider. `POST /admin/promote/{provider_id}`.
Provider's tier changes to pinned in `/poolz`. Routing weight upgrades
to 1.0 immediately.

Run by: `phase4-coordinator/scripts/test-promote.sh`

**AC-14. admin/reject.**
Connect a provisional provider. `POST /admin/reject/{provider_id}`.
Provider receives drain. WS closes. `provider_id` in
`rejected_providers`. Subsequent hello → WS close 4009.

Run by: `phase4-coordinator/scripts/test-reject.sh`

**AC-15. Routing-mode fallback on nak.**
Coordinator dispatches `inference_request` to a mock provider that
responds `nak code=unknown_message_type`. Coordinator marks provider
routing mode `http_forwarding_only`, returns HTTP 503 to buyer.
Subsequent requests to that provider's model are NOT dispatched via
§ 6.6 for the remainder of the WS session.

Run by: `phase4-coordinator/scripts/test-nak-fallback.sh`

**AC-X1 (PG-1). Public-launch provider token gate.**
Deploy the coordinator with `auth.require_provider_tokens=true`.
A pinned provider WebSocket connection without a valid bearer token MUST
receive WS close 4005 `invalid_token` within 2s of upgrade.

Run by:
```
wscat -c wss://coordinator.streamvc.live/ws/provider \
  --execute 'hello-with-pinned-provider-id.json'
```

Expected result: close code 4005 before `hello_ack`. Repeat with
`-H 'Authorization: Bearer <valid-token>'` and the same pinned
`provider_id`; expected result is `hello_ack`.

**AC-X2 (PG-2). Pre-WS-upgrade proxy controls.**
With the § 7.6 proxy limits configured, more than 10 WebSocket upgrade
attempts per minute from one source IP MUST receive HTTP 429 from the
proxy before the request reaches the coordinator process.

Run by:
```
for i in $(seq 1 16); do
  curl -sk -o /dev/null -w '%{http_code}\n' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    https://coordinator.streamvc.live/ws/provider
done
```

Expected result: at least one `429` after the configured burst is
exhausted, and coordinator logs contain no matching provider-upgrade
attempt for the rate-limited requests.

**AC-X3 (PG-3). Provisional admission rate limit.**
With `admission.provisional_admission_rate_per_hour=10`, the 11th new
provisional provider admission in one hour MUST be rejected with WS
close 4008 `provisional_rate_limited`.

Run by: `phase4-coordinator/scripts/test-rate-limit.sh`

Expected result: first 10 unknown provider IDs get `hello_ack`; the
11th gets close code 4008.

**AC-X4 (PG-4). Pinned-only unknown-provider rejection.**
With `admission.pinned_only=true`, a hello with an unknown `provider_id`
MUST receive WS close 4009 `banned` within 2s. Provisional admission
MUST NOT fire, and no provisional record may be created.

Run by:
```
phase4-coordinator/scripts/test-provisional.sh \
  --pinned-only --expect-close-code 4009 --expect-no-record
```

Expected result: close code 4009 and no new row in the provisional
provider listing.

**AC-X5 (PG-5). Provisional-admission pressure alert.**
When provisional admissions exceed 50% of
`admission.provisional_admission_rate_per_hour` in any rolling
10-minute window, the coordinator MUST emit a WARN log line with event
name `provisional_admission_pressure`.

Run by:
```
phase4-coordinator/scripts/test-rate-limit.sh --count 6 --limit 10
journalctl -u macprovider-coordinator --since -10m \
  | grep 'provisional_admission_pressure'
```

Expected result: a WARN-level log line containing
`provisional_admission_pressure`, `rolling_10m_count`, `limit_per_hour`,
and `threshold_count`.

### Audit category K — SPEC-010 / SPEC-011 coordinator absorption

**AC-K.0 L-1 baseline coordinator handling.**
A v1.3 binary invoked with neither `--supported-models` nor
`--enable-warm-swap` registers with the v1.3.5 coordinator and is
processed byte-identical to a pre-SPEC-010/SPEC-011 binary: v2
`auth_request` initial-stage frame with single-entry
`supported_models: [model_id]` is accepted; `Provider` struct has
`SupportedModels = [model_id]` and `PublishesSupportedModels = false`;
`/v1/status` for this provider OMITS the `supported_models` field;
heartbeat without `model_hash` / `loading` triggers the LEGACY PATH of
ApplyHeartbeat (clear hash on `ModelID` change). Traces to SPEC-010
v1.5 AC-2 + AC-21, SPEC-011 v0.5 AC-18, and SPEC-001 v1.3 AC-18.0.

**AC-K.1 SPEC-010 catalog opt-in echo.**
A v1.3 binary registered with `supported_models: [A, B, C]` and
`publishes_supported_models: true` MUST cause `/v1/status` for this
provider to include `"supported_models": ["A", "B", "C"]`. Traces to
SPEC-010 v1.5 AC-1 + AC-21 and SPEC-001 v1.3 AC-18.1.

**AC-K.2 SPEC-010 catalog opt-in suppressed echo.**
A v1.3 binary registered with `supported_models: [A, B, C]` but
without `publishes_supported_models: true` MUST cause `/v1/status` for
this provider to OMIT the `supported_models` field. Traces to SPEC-010
v1.5 R-3.3.3 / AC-21.

**AC-K.3 v2 `auth_request` proof-stage retention.**
A v1.3 binary's proof-stage frame that omits `supported_models[]` MUST
be accepted (no comparison performed). A proof-stage frame that
includes `supported_models[]` MUST be compared byte-identical to the
initial-stage value after NFC normalization + ASCII case-fold per
SPEC-010 v1.5 R-3.1.7. Mismatch MUST be rejected with
`auth_response.error.code = "bad_request"` and reason text containing
the exact substring `"supported_models mismatch between auth_request
stages"` (the locked SPEC-010 v1.5 R-3.1.10 clause 4 + AC-18(c) test
oracle). Traces to SPEC-010 v1.5 R-3.1.10 / AC-18(c).

**AC-K.4 Auth-attempt expiry.**
A binary that completes the initial-stage handshake but disconnects
before sending the proof-stage frame MUST cause the coordinator to
release the auth-attempt retention state within 10 minutes, matching
`phase4-coordinator/internal/ws/server.go:355` `challengeExpiresAt`.
Traces to SPEC-010 v1.5 R-3.1.10 clauses 1 and 5 / AC-18 and
SPEC-002 v1.3.5 §7.9.

**AC-K.5 Auth-attempt release on disconnect-before-proof.**
A binary that completes initial-stage and then drops the WebSocket
before sending proof-stage MUST cause IMMEDIATE release of the
auth-attempt retention, not wait for the 10-minute timeout. Traces to
SPEC-010 v1.5 R-3.1.10 clause 5 / AC-18(f) and SPEC-002 v1.3.5 §7.9.

**AC-K.6 ApplyHeartbeat LEGACY PATH.**
A v1.3 binary without `--enable-warm-swap` (emits heartbeat without
`model_hash` field) that changes `ModelID` between heartbeats MUST
cause the coordinator to clear `Provider.ModelHash` and set
`Provider.HashStatus = HashStatusUncatalogued` per the locked v1.3.4
behavior at `phase4-coordinator/internal/pool/provider.go:420-432`.
Traces to SPEC-011 v0.5 §6.2 D2.1 fix (LEGACY PATH) and SPEC-011 v0.5
AC-19.

**AC-K.7 ApplyHeartbeat SPEC-011 PATH.**
A v1.3 binary with `--enable-warm-swap` (emits heartbeat with
`model_hash` field) that changes `ModelID` between heartbeats MUST
cause the coordinator to: (a) UPDATE `Provider.ModelHash` to the new
value (not clear); (b) run SPEC-008 v0.3 §5.3-§5.6 Pillar A
re-verification; (c) populate `Provider.HashStatus` from the
verification result; (d) emit `operator_model_swap` audit-log event per
§7.10 IF the prior heartbeat had `loading: true`. Traces to SPEC-011
v0.5 §6.2 D2.1 fix (SPEC-011 PATH) and SPEC-011 v0.5 AC-10 + AC-13 +
AC-20.

**AC-K.8 ApplyHeartbeat path selection by field presence.**
A SPEC-011 binary that omits `model_hash` from a single heartbeat
(e.g. transient bug) MUST be handled by the LEGACY PATH for that
heartbeat. There is no sticky path; path selection is per-heartbeat
based on field presence. Traces to SPEC-002 v1.3.5 R-7.1.3 /
R-7.1.4 and SPEC-011 v0.5 AC-18 + AC-19.

**AC-K.9 `operator_model_swap` exactly-once emission.**
A completed warm swap MUST cause EXACTLY ONE `operator_model_swap`
audit-log row, not one per heartbeat after swap completion. Traces to
SPEC-002 v1.3.5 R-7.1.6 / R-7.10.8 (`LastLoadingState` sticky) and
SPEC-011 v0.5 AC-20.

**AC-K.10 `operator_model_swap` payload schema (REQUIRED/OPTIONAL keys).**
Every emitted `operator_model_swap` row MUST have a `payload_json`
field that parses as a JSON object containing:
- The 8 REQUIRED keys per §7.10 R-7.10.4 / SPEC-011 v0.5 R-3.6.1:
  `event` (value `"operator_model_swap"`), `ts` (RFC3339 UTC),
  `provider_assigned_id` (per-session assigned ID, not operator-
  issued provider_id per R-7.10.5), `from_model_id`, `to_model_id`,
  `to_model_hash` (raw 64-char lowercase hex), `loading_window_ms`
  (int, coordinator-clock per R-7.10.6), and `hash_verification_result`
  (exactly one of the 5 SPEC-008 §5.5 enum values per R-7.10.7).
- The 2 OPTIONAL keys per §7.10 R-7.10.4 / SPEC-011 v0.5 R-3.6.2:
  `from_model_hash` (MAY be empty/null), `drain_inflight_count_estimate`
  (MAY be omitted).
- NO other top-level keys (key drift = AC fail). v1.3.5 ships
  exactly one event type per §7.10.3.
Traces to SPEC-011 v0.5 §3.6 R-3.6.1 / R-3.6.2 and AC-20.

**AC-K.11 `operator_model_swap` payload F-1.5 invariants.**
The emitted `payload_json` MUST NOT contain any `conv:` prefixed
string, raw `account_id` value, sticky session identifier, buyer
prompt text, or any input that could feed sticky derivation. Test
oracle: a static grep against payload-building code AND a runtime
regression test that captures a real swap event payload and asserts
the absence of each prohibited substring. Traces to SPEC-002 v1.3.5
R-7.10.9 and SPEC-011 v0.5 R-3.6.5.

**AC-K.12 `operator_model_swap` conditional emission (WS-drop).**
A v1.3 binary that begins a swap (heartbeat with `loading: true`),
loses its WebSocket mid-load, completes the swap locally, and
reconnects with `loading: false` carrying the new `model_id` MUST
NOT cause an `operator_model_swap` event to be emitted (no
`loading: true` is observed on the new session). A binary that
reconnects DURING the load (first post-reconnect heartbeat has
`loading: true` with the OLD `model_id`) and then completes the
swap on the new session MUST cause exactly one
`operator_model_swap` event on swap completion (the new session
re-establishes the `LastLoadingState` sticky). Traces to SPEC-002
v1.3.5 R-7.10.10 / R-7.1.6 and SPEC-011 v0.5 R-3.6.6.

**AC-K.13 Audit-log write failure tolerance.**
A simulated SQLite write failure during `operator_model_swap` emission
MUST NOT block heartbeat processing OR cause a provider drop; the
failure MUST be logged at WARN level with the full payload. Traces to
SPEC-002 v1.3.5 R-7.10.8 and SPEC-011 v0.5 AC-20.

**AC-K.14 Audit-log retention.**
Rows older than `storage.audit_log_retention_days` (default 90) MUST be
pruned by the existing coordinator pruner, extended from the §7.7
pruner pattern. Traces to SPEC-002 v1.3.5 §7.10.1 and SPEC-011 v0.5
AC-20.

**AC-K.15 SPEC-010 validation-order pass-through.**
The coordinator's v2 `auth_request` initial-stage parser MUST apply
SPEC-010 field validation in the order mandated by SPEC-010 v1.5
R-3.1.9 (JSON type → per-entry byte length → array length → normalized
duplicate check → `model_id` containment). Each ordered validation
failure MUST surface the corresponding locked SPEC-010 reason-text
substring on first-failure (each substring quoted verbatim on its own
line so test-oracle grep can match without spanning line wraps):
- AC-17 per-entry byte length: `"supported_models entry exceeds 256 bytes"`
- AC-22 array length: `"supported_models exceeds 64 entries"`
- AC-23 normalized duplicate: `"supported_models contains duplicate entries"`
- R-3.6.3 / R-3.1.9 `model_id` containment: pre-flight oracle per §6.2 of SPEC-010 v1.5
Traces to SPEC-002 v1.3.5 R-7.8.4 and SPEC-010 v1.5 R-3.1.9 / AC-17 /
AC-22 / AC-23.

**AC-K.16 Auth-attempt retention-bound rejection.**
When the in-flight auth-attempt count reaches the §7.9.2 R-7.9.6
defensive bound (recommended 1024), a new initial-stage frame MUST be
rejected with `auth_response.error.code = "too_many_auth_attempts"`
and a 503-class WebSocket close drawn from the existing close-code
registry. The rejection MUST occur BEFORE creating a new retention
entry (no off-by-one growth past the bound). Traces to SPEC-002 v1.3.5
R-7.9.6 and SPEC-010 v1.5 R-3.1.10 (defensive-bound rationale).

**AC-K.17 Audit-log table schema + `ts_utc` format.**
Coordinator startup migrations MUST create the `audit_log` table with
exactly the §7.10.1 R-7.10.1 column list (`id`, `ts_utc`, `event_type`,
`provider_id`, `payload_json`) and exactly the three indexes
(`idx_audit_log_ts_utc`, `idx_audit_log_provider_id`,
`idx_audit_log_event_type`). Every persisted `ts_utc` value MUST be a
valid RFC3339 string in UTC (with `Z` suffix or `+00:00`); non-UTC or
non-RFC3339 values MUST NOT be written. Traces to SPEC-002 v1.3.5
R-7.10.1 / R-7.10.2.

---

## 12. Open questions for operator

**Defaults already chosen (no longer open):**

- **Provider endpoint discovery:** static `provider_id → endpoint_url`
  config map in coordinator. No SPEC-001 amendment. (See § 3, FR-P3,
  FR-P12.)
- **Provider auth on WebSocket upgrade:** optional in v1; trust comes
  from static config admission. (See FR-P1, FR-P12.)
- **TLS in front of coordinator:** Caddy with Let's Encrypt automatic
  HTTPS. (See NFR-Security in § 6.)
- **Provider token format (when used in path B):** opaque 32-byte
  random, hex-encoded. (See § 7.3.)
- **SQLite backup:** daily file copy via cron + rsync to operator. (See
  § 7.3 storage + NFR-Reliability.)
- **Buyer auth in v1:** none; trust delegated to Antseed seller
  integration (SPEC-003). Buyer API keys are SPEC-006 scope.

No open questions remain from v1.0.x. v1.0.2 resolved all prior open items into
normative requirements (see FR-P11 for the HTTP 530 handling that was
previously OQ-1).

**OQ-6. How to surface tier=provisional to buyers.** _RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed — the "do NOT surface" current position has held for a year with no buyer signal demanding tier visibility. Router weight already handles QoS. Revisit only if a buyer use case for routing control surfaces in writing._
Current design: the tier is invisible to buyers. A buyer cannot
distinguish a response from a pinned provider vs a provisional
provider. Should the coordinator add an `X-MacProvider-Tier` response
header?

**Current position:** Do NOT surface tier to buyers in v1. Buyers
should not need to care — the coordinator's routing weight handles
quality-of-service differentiation. If a buyer wants to avoid
provisional providers, they can pin to a specific provider via
`X-MacProvider-Provider`. Adding a tier header creates an implicit
SLA promise that is premature for v1.

**OQ-7. Version enforcement for provisional providers.**
Should the coordinator refuse to route to providers running versions
older than `recommended_binary_version`? Current position: no
enforcement in v1 — the nudge is informational. Enforcement risks
rejecting all provisional providers simultaneously on version bump.

**OQ-8. Automatic persistence of promotions.**
`POST /admin/promote` (§ 7.5) is runtime-only — the operator must
also edit `coordinator.yaml`. Should the coordinator automatically
append to `coordinator.yaml`?

**Current position:** No auto-edit of config files in v1. Config
files are operator-owned and may be version-controlled. The
coordinator should not mutate them. The operator adds promoted
providers to `coordinator.yaml` manually (same workflow as today's
pinned provider onboarding, but only for the subset the operator
chooses to promote). A future version may add a `coordinator-cli
promote --persist` flag that appends to the config file.

**OQ-9. Provisional provider identity verification.**
A provisional provider self-reports its `provider_id`. Nothing prevents
a malicious actor from impersonating another provider's ID. In the
pinned tier, the operator controls ID assignment. In the provisional
tier, the provider generates its own ID (UUID from `install.sh`).

**Current position:** For v1, self-reported UUIDs are sufficient
because: (a) UUIDs are 128-bit random — collision probability is
negligible, (b) the coordinator tracks `provider_id` → WS connection,
so a duplicate ID would close the older connection (same as FR-P2
step 4), (c) provisional providers have reduced routing weight and
request quotas, limiting the impact of impersonation. Stronger
identity verification (e.g., device attestation) is a Tier 2 concern.

**OQ-10. Coordinator-side WS write buffer sizing.**
FR-P19 specifies 64 messages as the coordinator-side write buffer per
provider. This is a starting estimate. In practice, the buffer should
rarely fill because the coordinator only sends `inference_request` (at
most N concurrent, where N = `max_concurrency`, typically 1) and
`cancel_request` (at most one per outstanding request). The 64-message
buffer is ~60× the expected steady-state depth.

**Scope:** This OQ concerns the **coordinator-side** buffer only
(per-provider outbound message queue in the Go coordinator). The
provider-side write buffer sizing is SPEC-001 v1.2.4 OQ-5.

**Current position:** 64 is a conservative default. Tune based on
production telemetry. Add a `/poolz` field showing per-provider
write buffer depth for operator visibility.

---

## 13. Implementation hand-off

### Step sequence for the build session

**Step 1. Init Go module.**
Initialize `phase4-coordinator/` as a Go module. Add dependencies per
Section 8.1 version pins. Verify the module compiles an empty main.
Deliverable: `go build ./...` succeeds.

**Step 2. WebSocket /ws/provider endpoint + hello/hello_ack.**
Implement the WebSocket server that accepts provider connections.
Parse `hello`, validate fields, generate `assigned_id`, respond with
`hello_ack`. Reject invalid hello by closing the WebSocket with FR-P13 close codes (4001 for invalid_hello, 4002 for unknown_provider_id, 4003 for tier_unsupported, 4004 for version_unsupported). Deliverable: mock provider
connects, exchanges hello/hello_ack.

**Step 3. Pool registry + heartbeat handling.**
Implement the pool data structure (concurrent-safe map). Process
`heartbeat` messages, update pool entries. Implement staleness
detection (warn on 1.5x heartbeat interval). Deliverable: pool shows
connected providers with live capacity data.

**Step 4. State machine for provider states.**
Implement state transitions from `state_update` messages. Implement
routing eligibility rules (only `ready` + `slots_free > 0`).
Implement wake detection (heartbeat gap > 120s -> warm_up). Implement
disconnect detection + grace period. Deliverable: provider state
transitions logged and reflected in pool.

**Step 5. /v1/models aggregation.**
Implement the buyer HTTP server. `GET /v1/models` returns aggregated
model list from pool. Deliverable: `curl /v1/models` returns JSON
with models from connected mock providers.

**Step 6. /v1/chat/completions non-streaming routing.**
Implement request validation (SPEC-001 section 6.2 subset), routing
algorithm (Section 5), request forwarding to provider HTTP endpoint,
response relay. Deliverable: non-streaming request routed to provider,
response returned to buyer.

**Step 7. SSE streaming pass-through.**
Add `stream: true` support. Implement SSE relay with immediate
flushing. Handle provider disconnect mid-stream (error event +
[DONE]). Deliverable: streaming response relayed chunk-by-chunk.

**Step 8. Preflight + capacity routing.**
Implement preflight send/receive over WebSocket. Integrate with routing
algorithm (skip for < 4096 estimated tokens, required above). Implement
buyer preference headers. Deliverable: preflight rejects correctly,
preference headers route as expected.

**Step 9. Auth (token issuance CLI + validation).**
Implement `coordinator-cli` subcommands: `issue-token`, `revoke-token`,
`list-tokens`. `issue-token` requires `--provider-id` and records the
authorized provider subject. Implement bearer token validation on
WebSocket upgrade and require the token subject to match
`hello.provider_id`. Deliverable: token issued, used to connect,
revoked, connection rejected, and mismatched provider-token pairing
rejected.

**Step 10. Operator endpoints (/healthz, /poolz, /admin/blacklist).**
Implement all three operator endpoints. Implement operator key auth for
/poolz and /admin/*. Deliverable: endpoints return correct JSON.

**Step 11. Acceptance testing.**
Run AC-1 through AC-10. Fix issues. Write test scripts in
`phase4-coordinator/scripts/`. Create `config-coord-test.yaml` for
the harness. Deliver a coordinator that passes all acceptance criteria.

### File structure (expected)

```
phase4-coordinator/
+-- go.mod
+-- go.sum
+-- cmd/
|   +-- coordinator/
|   |   +-- main.go                  # Entry point, flag parsing, startup
|   +-- coordinator-cli/
|       +-- main.go                  # Token management CLI
+-- internal/
|   +-- config/
|   |   +-- config.go                # YAML config + flag overrides
|   +-- pool/
|   |   +-- pool.go                  # Pool registry (concurrent-safe map)
|   |   +-- provider.go              # Provider entry struct
|   |   +-- state.go                 # State machine (ready/busy/degraded/...)
|   +-- ws/
|   |   +-- server.go                # WebSocket server, upgrade handler
|   |   +-- handler.go               # Message dispatch (hello, heartbeat, etc.)
|   |   +-- messages.go              # Message type definitions (JSON structs)
|   |   +-- wake.go                  # Wake detection + warm_up dispatch
|   +-- router/
|   |   +-- router.go                # Routing algorithm (Section 5)
|   |   +-- preflight.go             # Preflight send/receive
|   |   +-- estimator.go             # Token estimation heuristic
|   +-- buyer/
|   |   +-- server.go                # Buyer HTTP server
|   |   +-- models.go                # GET /v1/models handler
|   |   +-- completions.go           # POST /v1/chat/completions handler
|   |   +-- validator.go             # Request validation (SPEC-001 s6.2)
|   |   +-- relay.go                 # Response relay (JSON + SSE)
|   +-- auth/
|   |   +-- tokens.go                # Token issuance, validation, revocation
|   +-- operator/
|   |   +-- healthz.go               # GET /healthz
|   |   +-- poolz.go                 # GET /poolz
|   |   +-- blacklist.go             # POST /admin/blacklist
|   +-- store/
|   |   +-- sqlite.go                # SQLite setup, migrations, request_log
|   +-- logging/
|       +-- logger.go                # zerolog setup
+-- scripts/
|   +-- test-provider-lifecycle.sh   # AC-1
|   +-- test-provider-disconnect.sh  # AC-4
|   +-- test-auth-flow.sh            # AC-5
|   +-- test-degraded-recovery.sh    # AC-7
|   +-- test-reconnection.sh         # AC-8
|   +-- test-routing-preference.sh   # AC-9
|   +-- test-operator-endpoints.sh   # AC-10
+-- implementation-notes.html        # Populated by build session
+-- coordinator.yaml.example         # Example config file
```

v1.3.5 implementation hand-off extension:

New files:
- `phase4-coordinator/internal/pool/provider_swap.go` — implements the
  §7.1 ApplyHeartbeat SPEC-011 PATH branch (new file to keep the
  REPLACEMENT semantics isolated for review and testing); existing
  `phase4-coordinator/internal/pool/provider.go:411-432`
  `ApplyHeartbeat` gains branch-on-field-presence dispatch.
- `phase4-coordinator/internal/ws/auth_attempt_retention.go` —
  implements the §7.9 auth-attempt lifecycle: retention map, release
  machinery, expiry handling, and test-only accessors for bounded-state
  assertions.
- `phase4-coordinator/internal/audit/log.go` — implements the §7.10
  audit-log infrastructure: SQLite table creation, write API, retention
  pruner, and WARN-on-write-failure behavior.
- `phase4-coordinator/internal/audit/events.go` — defines normative
  audit event types and payload schemas; v1.3.5 ships with exactly one
  event, `operator_model_swap`.

Existing files modified:
- `phase4-coordinator/internal/ws/server.go` — auth flow extended to
  install `defer releaseRetention(authAttemptID)` at the auth-attempt
  scope per §7.9.3; v2 `auth_request` flow remains unchanged in
  structure.
- `phase4-coordinator/internal/ws/messages.go` — `parseAuthInitial`
  extended to parse the two SPEC-010 optional fields into the
  `AuthRequest` struct; `parseAuthProof` extended to parse the same two
  fields conditionally per SPEC-010 v1.5 R-3.1.10.
- `phase4-coordinator/internal/pool/provider.go` — `Provider` struct
  gains `SupportedModels []string`, `PublishesSupportedModels bool`,
  and `LastLoadingState bool`; `ApplyHeartbeat` gains the
  branch-on-field-presence dispatch with the SPEC-011 PATH delegated to
  `provider_swap.go`.
- `phase4-coordinator/internal/api/status.go` (or wherever
  `/v1/status` is served) — extended to conditionally include
  `supported_models` per §7.4.
- `phase4-coordinator/internal/config/config.go` — add
  `storage.audit_log_retention_days` config key with default 90,
  mirroring `request_log_retention_days`.
- `phase4-coordinator/dist/coordinator.yaml` (or
  `phase4-coordinator/dist/coordinator.yaml.template`) — add a
  commented line for `storage.audit_log_retention_days: 90` matching
  the new config key.

### Configuration file schema (coordinator.yaml)

```yaml
listen:
  buyer_port: 8443           # HTTP port for buyer API
  provider_port: 8444        # WebSocket port for provider connections
  bind_address: "127.0.0.1"  # Listen address; TLS terminated by Caddy in front

pool:
  heartbeat_interval_s: 30
  disconnect_grace_period_s: 30
  heartbeat_miss_threshold_s: 90   # (v1.1.7) Close WS after no inbound frame of ANY type for this long;
                                    # in-flight response chunks count as activity (F-4 liveness)
  wake_gap_threshold_s: 120
  warmup_fallback_s: 60          # Wake warm_up fallback before allowing routing if provider sends no ready state_update
  warmup_gate_enabled: true      # (v1.3.0 FR-P8a) Gate new connections on a token-producing self-test
  warmup_gate_timeout_s: 90      # Max seconds for each warm-up gate inference attempt
  warmup_gate_max_tokens: 2      # Max tokens requested by the warm-up gate self-test
  degraded_backoff_s: 30      # Initial recovery backoff after 502/504 OR a breaker trip (FR-P11a)
  degraded_max_retries: 3     # After N consecutive failed recovery preflights, mark unavailable
  degraded_probe_after_502: true   # Send recovery preflight after 502/504 backoff (default true)
                                    # Set to false to skip auto-recovery probing for debug
  breaker_failure_threshold: 2     # (v1.2.0 FR-P11a) Qualifying in-flight faults within the window that trip the breaker
  breaker_window_s: 120            # (v1.2.0 FR-P11a) Rolling window for the fault count; also the re-trip→unavailable guard

routing:
  preflight_threshold_tokens: 4096   # Skip preflight for prompts under this size
  preflight_timeout_s: 5
  request_timeout_s: 300
  failover_enabled: true
  failover_timeout_s: 5

auth:
  operator_key: "<required>"   # Bearer token for /poolz and /admin/blacklist
  require_provider_tokens: false # Set true before exposing provider WS publicly

storage:
  db_path: "coordinator.db"
  snapshot_interval_s: 300
  audit_log_retention_days: 90  # v1.3.5 operator audit-log retention

logging:
  level: "info"
  format: "json"

# Provider endpoint map (required; coordinator refuses to start if empty)
providers:
  - provider_id: "m4-anon"
    endpoint_url: "https://m4.streamvc.live"
    display_name: "M4 partner (Qwen 7B)"    # optional; used in /poolz
  - provider_id: "m1-anon"
    endpoint_url: "https://m1.streamvc.live"
    display_name: "M1 partner (Llama 3B)"
```

**Startup validation rules** (coordinator exits with error on any failure):
- `providers` must be non-empty (no providers = no routing possible).
- Each `provider_id` must be unique across the list (duplicates rejected).
- Each `endpoint_url` must be a syntactically valid `https://` URL (the
  v1 coordinator only forwards over TLS).
- Each `provider_id` must match the regex `[a-zA-Z0-9_.-]{1,64}`
  (filesystem-and-URL-safe identifier).
- `auth.operator_key` must be set and non-empty (operator endpoints
  require auth).

An example `coordinator.yaml.example` is included in the repo. The
example MUST be kept in sync with this schema as part of the build
session deliverable.

(Note: `routing.retry_on_502` from earlier drafts was renamed to
`pool.degraded_probe_after_502` to reflect what it actually controls —
the degraded recovery probe behavior, not buyer-visible retry. The
buyer never sees coordinator-managed retry in v1 per FR-B7.)

---

## Appendix A — References used during spec writing

| Source | What was taken |
|---|---|
| `specs/SPEC-001-phase3-binary.md` v1.1.1 | Full wire protocol (section 6.5), request schema (section 6.2), health states (FR-15), capacity fields (FR-17), handshake fields, preflight reasons, drain lifecycle |
| `HANDOFF.md` | Project context: pooled Mac network architecture, VPS at 165.22.182.207, Antseed seller integration, Darkbloom differentiation, coordinator design intent |
| `beta/PHASE2_UPGRADED_PLAN.md` | Routing mode evolution table (mirror -> specialization -> stress), pre-committed decision criteria concept |
| `beta/DECISION_CRITERIA.md` | Decision log D1 (502/530 routing), D2 (post-wake dip), D4 (capacity-vs-quality routing), D5 (timeline compression), pre-launch baselines |
| `beta/harness.py` | First buyer behavior: SSE parsing, workload runner, SQLite logging, the HTTP contract the coordinator must serve |
| `doc/PHASE1_REPORT.md` | Phase 1 evidence: VPS SSH tunnel validation (Step 6.7), tunnel latency data (Step 7), Metal OOM at ~26K tokens, SSE quirks, concurrent serving |
| `phase3-binary/implementation-notes.html` | Scaffold format for implementation-notes.html |
| OpenAI API reference | Chat completions request/response schema, SSE streaming format, error envelope, models endpoint |
| WebSocket protocol RFC 6455 | Upgrade handshake, close codes, frame format |

**Clean-room note:** No d-inference source files were read during spec
writing. The coordinator design is informed by the project's own Phase 1
and Phase 2 findings, SPEC-001's wire protocol, and standard
WebSocket/HTTP patterns. This is documented here for transparency per
the strict clean-room policy inherited from SPEC-001 section 7.2.
