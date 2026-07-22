# Partial #615 Exception Enforcement Scaffolding — Security Audit

## Verdict

**REQUEST CHANGES — required security gate is not met.**

| Severity | Count |
| --- | ---: |
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 4 |
| LOW | 2 |
| INFO | 2 |

Required gate: **0 CRITICAL / 0 HIGH / 0 MEDIUM**. Current result:
**0 / 3 / 4 — FAIL**.

Architectural security status: **BLOCK**. The stable-promotion blocker bit is
not enforced, a documented gateway opt-out skips the new deploy gate, and the
anti-resurrection ledger is not append-only or transition-enforced.

## Scope and evidence

- Worktree: `/Users/augstar/macprovider-615-exception-enforce`
- Branch: `fix/615-exception-enforcement`
- Audited tip: `f3d71718`
- Base: `origin/main`
- Primary inputs: `scratchpad/615-audit/SHARED_CONTEXT.md` and
  `scratchpad/615-audit/615.diff`
- Focus: report/CLI secret leakage, fail-open defaults, promotion bypass,
  tombstone/anti-resurrection behavior, path traversal, shell injection, and
  unregistered/expired-exception enforcement.

Fresh validation performed:

- `git diff --check origin/main...HEAD` — passed.
- `bash -n phase4-coordinator/dist/check-deploy-config.sh scripts/test-production-exceptions.sh`
  — passed.
- `bash scripts/test-production-exceptions.sh` — passed (14 unit tests).
- `bash scripts/test-acceptance-promotion.sh` — passed.
- Targeted adversarial probes reproduced the promotion-blocker bypass, missing
  tombstone transition enforcement, malformed-tombstone `sync-check` fail-open,
  and report secret leakage described below.

Passing tests do not clear the gate because the current suite does not exercise
the reproduced bypass cases.

## HIGH findings

### H-1 — `SKIP_C2_CHECK=1` skips the entire exception deploy gate on gateway deploys

**Evidence**

- `phase5-gateway/dist/deploy-pearl-vps.sh:202-223` branches around
  `check-deploy-config.sh` completely when `SKIP_C2_CHECK=1`.
- The exception gate exists only inside
  `phase4-coordinator/dist/check-deploy-config.sh:345-360`.
- The coordinator deploy handles the same opt-out safely by still invoking the
  checker in coordinator-only mode at
  `phase4-coordinator/dist/deploy-pearl-vps.sh:638-642`.
- `scripts/test-production-exceptions.sh:55-61` checks only that the shared
  checker contains the gate string; it does not exercise either deploy wrapper's
  opt-out branch.

**Impact**

`SKIP_C2_CHECK` is documented as a C2 cross-component timer opt-out, but on the
gateway path it also disables malformed-register, owner, scope, clock-expiry,
and resurrection enforcement. A gateway production deploy can therefore
proceed without running any #615 exception gate.

**Required fix**

Run the exception gate unconditionally in the gateway deploy wrapper, separate
from the C2 branch. `SKIP_C2_CHECK` may suppress only C2 evaluation. Add a
wrapper-level regression test that proves both normal and `SKIP_C2_CHECK=1`
gateway paths invoke the exception gate and abort on a failing fixture.

### H-2 — `blocks_stable_promotion: true` is inert

**Evidence**

- The field is only type-checked at
  `scripts/production_exceptions.py:276-280` and copied into the report at
  `scripts/production_exceptions.py:535`.
- `apply_gate_policy` upgrades only `status_expired`, `unbounded_active`, and
  `expiry_soon` at `scripts/production_exceptions.py:581-592`.
- The protected workflow relies on that policy at
  `.github/workflows/promote-acceptance-candidate.yml:54-60`.
- The standard test fixture sets `blocks_stable_promotion=True` at
  `scripts/tests/test_production_exceptions.py:25-44`, but no test asserts that
  this bit blocks promotion.

**Reproduction**

A structurally valid `active` row with `expires_at=2026-08-01T00:00:00Z`,
`blocks_stable_promotion=true`, and `now=2026-07-22T12:00:00Z` produced:

```text
blocking_true_promote_errors= []
```

A `planned` row with the same blocker bit is likewise not rejected. Once a
blocking row has a finite expiry more than the 72-hour alert window away,
`gate --mode=promote` can return success.

**Impact**

Stable bytes can be publicly promoted while the register explicitly declares
that a known security/rollout exception blocks stable promotion.

**Required fix**

Emit a dedicated error for every applicable non-removed row whose
`blocks_stable_promotion` value is true when `mode=promote`. Define planned-row
semantics explicitly. Add CLI-level tests for active bounded, active unbounded,
planned, expired, and removed rows with both boolean values.

### H-3 — Tombstones are not an append-only, transition-enforced authority

**Evidence**

- Validation rejects a resurrection only if the ID is already present in the
  current tombstone file (`scripts/production_exceptions.py:370-385`).
- Historical comparison runs only when `previous_doc` is supplied
  (`scripts/production_exceptions.py:387-388`), but `cmd_gate` never supplies it
  (`scripts/production_exceptions.py:653-675`).
- No validator rule requires every `status=removed` row to have a tombstone.
  The invariant is only prose at
  `ops/runbooks/production-exception-register.md:27-33`.
- No gate compares the tombstone ledger with a trusted base, so deleting a
  tombstone and reactivating its ID in one change is accepted.

**Reproduction**

Both of these transitions produced zero errors with an empty tombstone list:

```text
removed_without_tombstone_errors= []
reactivated_without_history_errors= []
```

**Impact**

A row may be removed without creating durable anti-resurrection state and later
return as active/planned/expired. A PR or whole-repository rollback can delete
the tombstone together with the current register state, defeating the claimed
anti-resurrection guarantee while both deploy and stable-promotion gates pass.

**Required fix**

Enforce the removed-row/tombstone invariant, compare current register and
tombstones with an immutable trusted base, and reject tombstone deletion or
mutation. Gate tests must cover delete-without-tombstone, tombstone deletion,
remove-and-reactivate across revisions, and whole-register rollback.

## MEDIUM findings

### M-1 — Unregistered production exceptions are invisible to both gates

**Evidence**

- `cmd_gate` reads only register and tombstone JSON
  (`scripts/production_exceptions.py:653-675`). It receives no coordinator,
  gateway, overlay, environment/drop-in, database, or runtime authority state.
- The standard deploy checker invokes it without either deploy config at
  `phase4-coordinator/dist/check-deploy-config.sh:345-357`.
- Production mutation scripts such as
  `phase4-coordinator/dist/deploy-malibu-emission-pearl.sh:135-182,214-238` and
  `phase4-coordinator/dist/deploy-opoi-v0-pearl.sh:105-143` install coordinator
  binaries/overlays/drop-ins and restart without invoking the exception gate.
- The runbook says emergency exceptions have no side channel at
  `ops/runbooks/production-exception-register.md:17-21`, but the implementation
  has no completeness assertion that can prove that statement.

**Impact**

A permissive production flag, overlay, drop-in, DB authorization, or alternate
deploy path that is absent from the self-reported register passes silently.
Stable promotion also knows only the checked-out inventory, not whether live
production authority contains an unregistered exception.

The shared context explicitly leaves physical exception-free proof out of this
partial, which limits the present implementation's claim; it does not make an
unregistered exception detectable or safe.

**Required fix**

Define machine-readable reconciliation for each authority surface and require
all production mutation paths to run it. Until live reconciliation exists,
narrow documentation and status output to state that the gates prove register
syntax/policy only, not exception completeness.

### M-2 — The “no secrets” report leaks supported and unsupported secret forms

**Evidence**

- `SECRET_RE` at `scripts/production_exceptions.py:71-75` covers only a small
  set of patterns and only a private-key header, not the PEM body.
- Only four prose fields are passed through redaction at
  `scripts/production_exceptions.py:536-539`. Fields including `id`, `status`,
  `owner`, and expiry are emitted raw at `scripts/production_exceptions.py:527-535`.
- Invalid values are embedded in findings (for example status/component/schema
  values) and copied unredacted into report JSON at
  `scripts/production_exceptions.py:639-642`; gate/validate also print them raw
  at `scripts/production_exceptions.py:617-618,676-678`.
- The output nevertheless sets `secrets_redacted: true` and claims HMAC,
  referral-code, and private-key exclusion at
  `scripts/production_exceptions.py:560-564`.
- Tests cover only a Bearer token and `password:` in two redacted prose fields
  (`scripts/tests/test_production_exceptions.py:184-199`).

**Reproduction**

A valid owner containing `password=owner-secret` and an invalid status
containing `Bearer STATUSSECRETVALUE` both remained in the generated report:

```text
owner_secret_leaked= True
status_secret_leaked= True
```

Generic API/HMAC/referral values and private-key bodies also have no complete
redaction rule.

**Impact**

Malformed or carelessly populated inventories can copy credentials into CLI
logs or saved operator reports under a false “secrets redacted” assurance.

**Required fix**

Build the report from a strict allowlist of validated safe scalar forms, redact
every emitted string including diagnostics, handle entire PEM blocks, and fail
report generation if a final secret scan still matches. Do not set
`secrets_redacted=true` merely because four fields passed through a regex.

### M-3 — Malformed tombstones make `sync-check` fail open

**Evidence**

`simulate_config_sync_restore` calls `validate_tombstones(tombstones)` without a
shared result, then creates the returned `ValidationResult` afterward at
`scripts/production_exceptions.py:483-485`. Tombstone schema/environment/shape
errors are discarded.

**Reproduction**

With a malformed tombstone document (`schema_version` and environment wrong;
`tombstones` not a list), a current document lacking the removed row, and a
stale document restoring it, the function returned:

```text
malformed_tombstones_sync_errors= []
```

The CLI can therefore print `sync-check: OK (no resurrection)` when its
anti-resurrection authority is unusable.

**Required fix**

Create the result first, pass it into `validate_tombstones`, and stop the sync
comparison on any tombstone validation error. Also validate current and stale
register shapes before simulation and add malformed-input CLI tests.

### M-4 — Stable promotion checks one early dispatch snapshot and is stale at publication

**Evidence**

- The workflow checks out `${{ github.sha }}` and runs the exception gate once
  near the start (`.github/workflows/promote-acceptance-candidate.yml:47-60`).
- It later fetches current `origin/main` but checks only candidate/control
  ancestry (`.github/workflows/promote-acceptance-candidate.yml:297-316`).
- The irreversible publication step revalidates release posture, tag, checksums,
  and draft identity, but not production exceptions
  (`.github/workflows/promote-acceptance-candidate.yml:405-445`).

**Impact**

A promotion dispatched from main can remain pending while main advances and a
new blocking exception is registered/deployed. Approving or continuing the old
run evaluates the old inventory and can publish after the new blocker exists.
The main-only production environment policy prevents arbitrary-branch dispatch;
it does not prove that the dispatch SHA is still the current main authority.

**Required fix**

Immediately before draft creation and final publication, fetch the authoritative
main head, require the expected control relationship, and rerun the promote gate
against that verified inventory. Serialize production-exception mutations with
promotion or add a durable generation/version binding so a newly introduced
blocker invalidates in-flight promotion.

## LOW findings

### L-1 — Deploy intentionally remains fail-open for expired-status and unbounded rows

`status=expired`, active `expires_at=null`, and approaching-expiry findings are
warnings at `scripts/production_exceptions.py:299-334` and become errors only
under enforcement or promote mode (`scripts/production_exceptions.py:581-601`).
The deploy wrapper invokes the default at
`phase4-coordinator/dist/check-deploy-config.sh:356-357`, and tests explicitly
require the default deploy to pass (`scripts/test-production-exceptions.sh:42-46`).

This is an accepted transitional behavior in `SHARED_CONTEXT.md`, so it is not
rated as a merge-blocking defect here. It is still a fail-open production
posture: current expired/unbounded rows permit deploy with warnings. The pass is
not silent because warnings and `enforce=0` are printed. Clock-expired rows that
remain `status=active` still hard-fail.

Retire the opt-in once the partial is ready for enforcement, or make production
deploy fail closed while preserving an explicitly reviewed break-glass path.

### L-2 — Invalid enforcement environment values silently disable enforcement

`enforcement_enabled` recognizes only the exact string `"1"` and maps every
other value to false (`scripts/production_exceptions.py:596-601`). Typos and
common values such as `true`, `yes`, or `01` silently select warning-only deploy
behavior. Output shows `enforce=0`, which limits severity.

Accept a documented strict boolean set or fail closed on any nonempty,
unrecognized value. Add tests for invalid values.

## INFO / verified positive controls

### I-1 — No new shell command injection or privilege-boundary path traversal found

The deploy checker path is derived from the script location and quoted
(`phase4-coordinator/dist/check-deploy-config.sh:349-357`); workflow gate
arguments are hardcoded; register rollback commands remain inert report data and
are not executed. The CLI's `--root`, `--register`, `--tombstones`, and report
output paths are explicit caller-selected local paths and are not fed from an
untrusted automated input or elevated wrapper in this change. No command
injection or meaningful privilege-boundary traversal was reproduced.

### I-2 — Promotion mode resists the obvious enforcement-flag bypasses

`--no-enforce` cannot weaken `--mode=promote`, because mode alone upgrades the
policy warnings (`scripts/production_exceptions.py:591-592`). Expired-status and
unbounded-active rows fail the current stable-promotion command, and an ID still
present in a valid tombstone file fails if it reappears non-removed
(`scripts/production_exceptions.py:370-385`). The production-release environment
posture also verifies a main-only deployment branch policy
(`scripts/verify-github-release-posture.sh:82-97`), so arbitrary workflow refs
are not the identified promotion bypass.

## Minimum re-audit bar

Before this lane can report 0/0/0:

1. Make the exception deploy gate unconditional across gateway and alternate
   production mutation paths.
2. Enforce `blocks_stable_promotion` in promote mode and add behavioral workflow
   tests, not string-presence checks.
3. Make tombstones transition-required and append-only against trusted history;
   propagate malformed tombstone errors through `sync-check`.
4. Add a defensible completeness/reconciliation boundary for unregistered live
   exceptions, or explicitly narrow the claimed proof until that boundary lands.
5. Make report and CLI diagnostics safe for malformed/secret-bearing input.
6. Recheck authoritative exception state at the irreversible promotion boundary.

