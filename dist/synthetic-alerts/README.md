# SPEC-016 §9 item 6 — synthetic payout alerts

This directory is the operator harness for **SPEC-016 payout-pipeline §9
cutover prerequisite item 6**:

> **BetterStack alert filter extended** to match EVERY §7.1 event with
> severity=PAGE or severity=WARN. … Operator MUST verify with ONE synthetic
> alert per **ENUMERATED PAGE/WARN event NAME** (NOT one per severity tier)
> before flipping `payout.enabled: true`.

Per-event (not per-tier) verification is the point: a per-tier check that only
confirms "at least one PAGE alert fires" would silently pass even if
`payout_runner_lease_lost` were typo'd in the BetterStack filter as
`payout_runner_lease_lst`. The BetterStack monitor config lives in the
BetterStack UI, **not** in this repo, so this harness cannot assert the matchers
directly. Instead it:

> **Matchers MUST key on the `event` field + the `severity` field — never on the
> zerolog `level`.** Some real events emit a PAGE `severity` at a non-error
> level (e.g. `payout_reorg_orphan_recorded` logs at `level=warn` with
> `severity=PAGE`). The synthetic lines make the `severity` field authoritative
> and identical to the catalog; the `level` field is cosmetic.

1. **Emits** one synthetic structured-log line per enumerated PAGE/WARN event
   name (`emit.sh`), in the exact zerolog-JSON shape the coordinator emits real
   events, so the operator can watch each one land in BetterStack.
2. **Guarantees** (`catalog.tsv` + the coordinator completeness test) that the
   enumerated set stays complete versus the code's actual emitted event names,
   so a newly added PAGE/WARN event can never ship without a catalog entry — and
   therefore without an operator deciding on a matcher.

## Files

| File | Role |
| --- | --- |
| `catalog.tsv` | **Single source of truth for alert events.** `event_name  severity  status  page_capable`. Shared by `emit.sh` and the completeness test. |
| `non-alert-allowlist.txt` | Reviewed list of `payout_`/`provider_payout_` string literals that are NOT alert events (DB tables/columns, INFO-only events, reason strings), each with a one-word reason. |
| `emit.sh` | POSIX-sh emitter. `--list`, `--event NAME`, default (emitted PAGE/WARN), `--include-info`, `--reserved`. |
| `README.md` | This file. |

The completeness test lives with the code it guards:
`phase4-coordinator/internal/payout/synthetic_alerts_catalog_test.go`.

**Why it is a literal-presence check, not an emission scanner.** Statically
deciding *which* zerolog emissions are PAGE/WARN alerts, from arbitrary Go, is
undecidable — an AST scanner that tries to follow the event name and severity
through helpers, structs, closures, and threaded parameters can always be fooled
by one more indirection. So the test does **not** analyse emission. It is
**style-agnostic**: it scans every non-test `.go` file under
`phase4-coordinator/internal/payout/` (recursively) and
`phase4-coordinator/cmd/coordinator/` for every identifier-shaped string literal
matching `^(payout_|provider_payout_)[a-z0-9_]+$`, and requires **each** to be
classified as exactly one of:

1. a catalogued **alert** event → `catalog.tsv`, or
2. a reviewed **non-alert** string → `non-alert-allowlist.txt`.

Any unclassified literal **fails the test** (fail-closed): a new alert event
necessarily introduces a new event-name literal (or `const`) somewhere, and it
cannot ship silently. Alert event names must be plain literals/consts — a
**dynamically constructed** alert name (`fmt.Sprintf("payout_%s", …)` or
`"payout_" + x`) also fails, which is what keeps the literal-presence guarantee
sound. (A `payout_`-prefixed *prose message* such as an `Error()` string is not
identifier-shaped and is correctly ignored.)

**Dynamic (page-capable) severity.** An event whose severity is computed at
runtime and can escalate to PAGE (e.g. `payout_stale_outbox_backlog`, WARN →
PAGE on `scan_ceiling_hit`) is marked `page_capable` in the catalog. `emit.sh`
emits BOTH a WARN and a PAGE synthetic line for it.

**Dynamic (page-capable) severity.** An event whose severity is computed at
runtime and can escalate to PAGE (e.g. `payout_stale_outbox_backlog`, WARN →
PAGE on `scan_ceiling_hit`) is marked `page_capable` in the catalog. `emit.sh`
emits BOTH a WARN and a PAGE synthetic line for it, and the test fails if such an
event is mis-catalogued as WARN-only.

## Operator procedure (run BEFORE `payout.enabled: true`)

Do this on the coordinator host (Pearl VPS), where the coordinator's stdout is
captured by systemd-journald and forwarded to BetterStack.

1. **Preview the catalog.**

   ```sh
   ./emit.sh --list
   ```

   The **verification set is the emitted set**: `./emit.sh` (default) emits one
   synthetic line per PAGE/WARN event the coordinator ACTUALLY emits (`code`
   rows). `info` rows are optional (`--include-info`).
   `spec-only-not-emitted` rows are **excluded** from the default — the code
   never emits them, so a matcher for them can never fire from real traffic.
   They are an implementation gap (see Discrepancies below), available only via
   `./emit.sh --reserved`, and are NOT part of pre-enablement verification.

2. **Fire the synthetic alerts into the same journald stream the coordinator
   uses.**

   ```sh
   ./emit.sh | systemd-cat -t macprovider-coordinator
   ```

   (Adjust the syslog identifier to whatever the coordinator unit uses, so the
   lines pass through the identical BetterStack ingest path.) Every line carries
   `"synthetic":true` and a `"note"` — they are safe and self-identifying.

3. **In the BetterStack UI, confirm EACH event name fired its matcher —
   one per name.** Do not accept "a PAGE alert fired"; check the full list off
   name-by-name against `./emit.sh --list`. Any name that does NOT trigger is a
   missing or mistyped matcher — fix it in BetterStack and re-run
   `./emit.sh --event <name>` for just that one.

4. **Only after every enumerated PAGE/WARN name is confirmed** may the operator
   proceed with the remaining §9 prerequisites and flip `payout.enabled: true`.

To re-test a single event after fixing a matcher:

```sh
./emit.sh --event payout_runner_lease_lost | systemd-cat -t macprovider-coordinator
```

## Keeping the catalog honest

The catalog is not a static hand-maintained list that can drift from the code.
`synthetic_alerts_catalog_test.go` runs in CI and:

- **FAILS closed on any unclassified `payout_`/`provider_payout_` identifier
  literal** in the scanned source — it must be an alert (`catalog.tsv`) or a
  reviewed non-alert (`non-alert-allowlist.txt`). This is the load-bearing
  guarantee: a new alert event introduces a new literal, which cannot ship
  without a classification decision.
- **FAILS on a dynamically constructed alert name** — `fmt.Sprintf("payout_%s")`,
  `"payout_" + x`, and the one-more-indirection variant where a `payout_`
  fragment (a literal ending in `_`, e.g. `"payout_"`) is stored in a variable
  and concatenated later. This forbids the patterns that could hide a new alert
  name from a literal check. (A `payout_`-prefixed prose message is not
  identifier-shaped and is ignored.)
- **ENFORCES severity-presence on every catalogued alert (sound, per-site).**
  For each catalogued `code` event — a FINITE, known list — the test resolves
  every production zerolog chain that emits it (following string literals,
  consts, struct-field literals, string-returning helpers, and event names
  threaded through emit-helper parameters) and asserts EACH emitting chain sets
  a `severity` field matching the catalog. It FAILS, with `file:line`, if any
  emission site lacks severity, emits the wrong severity, or can emit `PAGE`
  dynamically for a non-`page_capable` WARN event — and FAILS closed if a
  catalogued alert has no resolvable emission at all. This is what makes it
  impossible to ship a catalogued alert whose real event line would miss a
  `severity`-keyed BetterStack matcher (the false-verification bug class), and it
  replaces the earlier best-effort check that could miss a per-site gap. The
  requirement is gated on the catalog SEVERITY (PAGE/WARN), not on a status
  value, so no status can exempt an emitted alert from carrying severity (there
  is deliberately no `code-untagged` status). And if a payout-package emission
  sets an `event` field whose name the harness cannot resolve while carrying no
  severity, the test FAILS closed rather than skipping it — an emission it can't
  analyze can never silently pass.
- **FAILS on a catalog typo** — every catalog entry (except
  `spec-only-not-emitted`) must appear as a literal in the scanned source.
- **FAILS if a `spec-only-not-emitted` event starts appearing as a literal**
  without being reclassified, so the discrepancy list can't silently rot.

When you add a new payout PAGE/WARN event: add its `event`+`severity` field in
the coordinator, add a `code` row here, add the BetterStack matcher, and verify
with `./emit.sh --event <name>` as part of the change's go-live gate (SPEC-016
§9 item 6 requires this for every new event). When you add a non-alert
`payout_`-shaped string (a new table/column/reason/INFO event), add it to
`non-alert-allowlist.txt` with a one-word reason.

## Discrepancies found while building this catalog (2026-08-01)

Reconciling SPEC-016 §9 item 6's enumeration against the coordinator's actual
emitted event names surfaced money-path spec-vs-code divergences. They are
recorded here rather than silently resolved:

### A. Formerly `spec-only-not-emitted` — NOW WIRED (2026-08-02)

Both events below were previously enumerated by §9 item 6 but emitted by no
`phase4-coordinator` source. That gap is now **closed**: they are wired as
`code` events in `catalog.tsv` and participate in the default verification set.

- **`payout_nonce_gap` (WARN)** — emitted by `RunOnce`'s §7.1 pre-check
  (`checkNonceGap`, `internal/payout/runner.go`) when the on-chain pending nonce
  falls behind the DB cursor via a real abandon hole. Catalogued `code`.
- **`payout_runner_lease_conflict` (PAGE)** — emitted by the lease path
  (`internal/payout/lease*.go`) on a competing-holder conflict. Catalogued
  `code`.

Related recovery-only diagnostics introduced alongside the R2-HIGH fix are
**non-alert info events** (no `severity` field) and are listed in
`non-alert-allowlist.txt`, not `catalog.tsv`:
`payout_nonce_gap_precheck_skipped`, `payout_nonce_gap_reorg_suspect`, and
`payout_nonce_gap_recovery_only` (the per-cycle recovery-only diagnostic — a
rebroadcastable crash-recovery attempt sits at the pending nonce; fresh
allocation is suppressed for that cycle while the persisted bytes re-broadcast).

### B. Missing `severity` field on PAGE/WARN events — FIXED (2026-08-01)

Four §9 item-6 alerts were emitted WITHOUT a `severity` field, so a BetterStack
matcher keyed on `severity` would have missed the real event (the synthetic line
had severity, the production line did not — false verification). The production
emission sites now set the field, and the catalog rows are `code`:

- `payout_failed` → `.Str("severity","PAGE")` (both emission sites in `runner.go`)
- `payout_signer_unavailable` → `.Str("severity","PAGE")` (`runner.go`)
- `provider_payout_address_change_rejected` → `.Str("severity","WARN")` (`addresses.go` `emitFailure`)
- `provider_payout_address_rejected_unknown_provider` → `.Str("severity","WARN")` (`addresses.go` `emitReject`)

The severity-consistency check (below) now enforces that these keep matching the
catalog.

### C. Emitted by code as PAGE/WARN but NOT enumerated in §9 item 6

§9 item 6's list is explicitly a "CURRENT minimum filter set … always re-verify
against §7.1" and is stale relative to the code. The following carry a real
PAGE/WARN `severity` field in the coordinator but are absent from the item 6
enumeration; they ARE included in this catalog (status `code`) so the operator
provisions matchers for them:

`payout_admin_invoked_while_halted` (WARN),
`payout_chain_balance_rpc_disagreement` (PAGE),
`payout_chain_balance_rpc_error` (WARN),
`payout_daily_cap_tripped` (WARN),
`payout_reorg_orphan_recorded` (PAGE),
`payout_reorg_poll_rpc_error` (WARN),
`payout_runner_halted` (PAGE),
`payout_runner_halted_skipping_cycle` (PAGE),
`payout_runtime_flag_sync_emit_failed` (PAGE).

This is exactly the "later minor revisions silently missed events" failure mode
§9 item 6 warns about; the completeness test now prevents it from recurring.

> Note: `payout_stale_outbox_backlog` emits a **dynamic** severity — `WARN`
> normally, escalating to `PAGE` when `scan_ceiling_hit=true`. It is catalogued
> as WARN (its floor); its matcher must treat it as PAGE-capable.
