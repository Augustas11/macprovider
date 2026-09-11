# Catalog monthly intake release runbook (SPEC-023 §16, BYOM v0.2 slice 5)

This is the §16.5 cadence runbook: once a month, evaluate the three intake
signals, decide which keys enter `listed` (and which `listed` keys are
promoted), write the §16.8 `intake-decision.json`, and cut the release with
`scripts/catalog-release.py`. Nothing here ranks or promotes automatically:
every signal is a floor test, and the operator takes every decision.

Sources of truth: SPEC-023 v0.10.4 §16 (rule), SPEC-017 v0.2.1 §5.2b
(buyer demand + fleet RAM), SPEC-047 v0.1.6 (provider supply). Companion:
`docs/runbooks/catalog-artifact-feed-release.md` for the release mechanics
this runbook feeds into.

## Preconditions (check every month, before touching signals)

- The coordinator serves SPEC-017 v0.2.1 (`/v1/stats/intake` answers a
  listed partner key) and SPEC-047 v0.1.6 (`/admin/model-admission/intake`
  answers an operator credential). Both are on the coordinator's public
  and admin ports respectively; the stats mount is behind nginx on
  `stats.malibu.tech`.
- `stats.intake.policy_salt` is set (an operator secret, `env:NAME`; intake is
  enabled exactly when it is configured), `stats.intake.reader_partner_key_ids` lists
  the partner key you will read with (it is refused otherwise), and
  `stats.intake.excluded_accounts` lists EVERY keep-warm, canary,
  synthetic-load, and acceptance-harness buyer account. A missing exclusion
  makes internal traffic look like buyer demand; add it, and note that the
  change closes the open aggregator window.
- `coordinator.require_gateway_context: true`. Only gateway-authenticated
  accounts feed the buyer-demand aggregator (SPEC-017 §5.2b.2); with the
  gateway context off the signal stays empty by construction.
- The buyer-demand signal needs ONE uninterrupted 30-day aggregator epoch
  with unchanged parameters and eligibility policy. A coordinator restart,
  a parameter change, or an excluded-account change closes the epoch
  incomplete, and an incomplete window is never evidence
  (`incomplete_window`). If the coordinator was restarted inside the last
  30 days, expect `unmatched_model_request_count` to be absent this month;
  the other two terms still admit.
- A private intake audit store exists outside the repository:
  `$MACPROVIDER_INTAKE_AUDIT_DIR` (default `~/.config/macprovider/intake-audit/`,
  mode `0700`). The responses you read below are retained there, never
  committed: both endpoints are private, and the repository is public.

## 1. Read the signals (retain, never commit)

```bash
export MACPROVIDER_INTAKE_AUDIT_DIR="${MACPROVIDER_INTAKE_AUDIT_DIR:-$HOME/.config/macprovider/intake-audit}"
RELEASE_ID=published-2026-10-01-intake-v1        # the release id you will cut
DIR="$MACPROVIDER_INTAKE_AUDIT_DIR/$RELEASE_ID"; mkdir -p "$DIR"; chmod 700 "$MACPROVIDER_INTAKE_AUDIT_DIR" "$DIR"

# Buyer demand + fleet RAM (SPEC-017 §5.2b): partner key listed in reader_partner_key_ids.
curl -sS -H "Authorization: Bearer $INTAKE_PARTNER_KEY" -H "Accept-Encoding: identity" \
  https://stats.malibu.tech/v1/stats/intake -o "$DIR/stats-intake.json"

# Provider supply (SPEC-047 v0.1.6): per-actor operator credential, admin port.
curl -sS -H "Authorization: Bearer $OPERATOR_ACTOR_KEY" -H "Accept-Encoding: identity" \
  http://127.0.0.1:8443/admin/model-admission/intake -o "$DIR/model-admission-intake.json"

sha256sum "$DIR"/*.json     # these digests go into intake-decision.json
chmod 0600 "$DIR"/*.json    # operator-private; the generator refuses a file readable by others
```

The `Accept-Encoding: identity` header is mandatory: the digest and the
retained file are the unmodified body octets, and a compressed response
would hash differently from what the generator re-parses. The store is
append-only — never edit or replace a retained file — and every file is
mode `0600` under a `0700` directory (SPEC-023 §16.8 rule 9). **Retention
lifecycle:** keep each release's files for at least 24 months after its
ledger row and for as long as a later release still lists the key it
admitted, and delete them no later than 36 months after the last release
that lists that key — the store holds private coordinator data and is not
kept indefinitely. Include the store in the operator's encrypted backup;
a lost file breaks reconstructibility for that release and MUST be
recorded in the next release's notes.

A `503 stats_stale` or `503 intake_unavailable` means the source is not
usable this month: record that signal as `null` with
`*_absent_reason: "source_unavailable"` and a `null` digest, and do NOT
retry with an older copy.

The demand-rank source is the release-bound signed `demand-rank.json`
itself; its digest is `sha256(phase3-binary/catalog/autotune/demand-rank.json)`.

## 2. Evaluate the §16.3 rule per candidate key

For each key you consider admitting to `listed`:

1. **P1–P4** (§16.1): a `verified` artifact in `autotune-artifacts-source.json`
   with an immutable `source_ref`; the current CLI loads it through an
   allowed runtime source; licence recorded; the normalized key collides
   with nothing (the generator checks shadowing and global hash uniqueness).
2. **Demand or supply** — at least one, evaluated on the retained bytes:
   - `demand_rank`: `demand-rank.json` `rows.<key>.rank` non-null and
     `<= INTAKE_DEMAND_RANK_MAX` (100).
   - `provider_offer`: the `model-admission-intake.json` row for the key
     has `suppressed: false` and `distinct_provider_offer_count >= INTAKE_OFFER_FLOOR` (3).
     A `suppressed: true` row satisfies nothing, and in the public manifest
     it is recorded exactly like no row: `null`, `suppressed: false`,
     `no_observations` (the manifest never says "one or two providers").
   - `buyer_request`: in `stats-intake.json`, take the window with the
     LATEST `window_start` whose `window_end` is within 31 days of your
     `as_of` (every served window is a complete 30-day epoch; at most
     three are served). The key's bucket
     `lower_bound >= INTAKE_BUYER_REQUEST_FLOOR` (250). No qualifying window
     → `incomplete_window`; no bucket for the key → `no_observations`.
     `spec017_amendment_not_landed` is no longer a valid reason: the
     amendment is recorded in `CONFORMANCE.json` (SPEC-017 ≥ 0.2.1) and the
     generator refuses it — an unreadable endpoint is `source_unavailable`.
   - `coldstart_slot`: at most `INTAKE_COLDSTART_SLOTS` (1) per release,
     only when `tier_target` is under-covered, and only with a fit term.
3. **Fit** — at least one:
   - `fleet_fit`: from `fleet_ram.classes`, sum `provider_count` over
     unsuppressed classes with `ram_gb_floor - 4 >= artifact.min_ram_gb`,
     divide by `provider_total`, take the max over the key's verified
     artifacts, record as `fleet_fit_fraction_ppm = floor(fraction × 1e6)`
     floored to the 50 000 ppm grid (5% steps: 583 333 → 550 000, so the
     public manifest never reproduces the exact fleet ratio); needs
     `>= INTAKE_FLEET_FIT_MIN_PCT` (25%) → `>= 250000` ppm. The histogram is
     frozen for a 30-day period (SPEC-017 §5.2b.6), so two reads inside one
     period return identical `fleet_ram` bytes.
   - `tier_target`: the key's best-fitting verified artifact satisfies
     `min_ram_gb + 4 <= <tier GB>`.

For a promotion (`listed` → `recommendable`): `listed_since` at least
`INTAKE_MIN_LISTED_DAYS` (30) before `as_of`; the key's `rate_class` exactly
as declared on its artifact-feed model entry, resolving to a published
rate row; `recommendable: true` in `demand-rank.json`;
bench provenance other than `omlx_seeded`; and your explicit admission
reference (release-notes anchor or ticket id, no identity).

## 3. Write `intake-decision.json`

`phase3-binary/catalog/autotune/intake-decision.json`, schema
`macprovider.intake-decision.v1`, closed at every level (SPEC-023 §16.8).
One `decisions` entry per key admitted or promoted, none for any other key;
`thresholds` carries every §16.4 knob at the value in force
(`INTAKE_K_ANONYMITY_MIN` is fixed at 3); per-signal windows and digests
exactly as read from the retained bytes; `observation_window_start/end` =
the envelope of the non-null signal windows (null when only `demand_rank`
and `tier_target` decided). The generator re-derives every recorded value
from the audit store and fails closed on any disagreement, so copy values,
never type them from memory.

## 4. Cut the release

```bash
python3 scripts/catalog-release.py generate \
  --previous-release-dir <previous artifact-bound release dir> \
  --intake-audit-dir "$MACPROVIDER_INTAKE_AUDIT_DIR"
```

The ledger row records `intake_decision_sha256`; the manifest is committed
with the release; the audit store stays private. Then follow
`docs/runbooks/catalog-artifact-feed-release.md` (sign every feed with the
same static-feed key, verify, tag, deploy). A release that admits or
promotes nothing needs no manifest and records `null`.

## 5. Out-of-band releases

Only `blocked` transitions may ship off-cadence (§16.5): withdrawing a row
needs no signal, no manifest entry, and no threshold. Never add, promote,
re-class, or re-price out of band.

## Failure modes the generator refuses

- A manifest whose digest does not equal the retained file's SHA-256, a
  retained file the manifest does not cite, or a missing audit store when
  any coordinator signal was read.
- `INTAKE_K_ANONYMITY_MIN` other than 3, or a source whose `k_anonymity_min`
  differs from it; `thresholds` that differ from the selected window's
  `parameters`.
- A suppressed signal named as `admission_clause`; a `buyer_request` clause
  from an open, incomplete, or non-latest window; a signal window ending
  more than 31 days before `as_of`; an absent signal without its reason, or
  a reason on a present signal.
- More `coldstart_slot_used` entries than `INTAKE_COLDSTART_SLOTS`; a
  promotion under `INTAKE_MIN_LISTED_DAYS`, without a resolving rate row,
  or from an `omlx_seeded` row.
- Any provider id, pseudonym, hardware fingerprint, buyer account, API key,
  IP, raw principal identifier, or principal token in any field.
