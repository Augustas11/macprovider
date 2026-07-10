# SPEC-005 Design Exploration — Billing, Settlement, Provider Rewards

## 1. Operator's Framing

SPEC-005 is the last spec before public launch and it is the spec most
likely to be over-built. Mac Provider is a small live network of
consumer Apple Silicon Macs running 3B–7B 4-bit open-weight models. Per
SPEC-006's market check, commodity hosted inference for the same model
class sits at $0.02–$0.10 per million tokens at DeepInfra/Groq/Together.
A volunteer Mac pool cannot win on price-per-token; it cannot win on
throughput; and it has no buyer revenue today.

The north star inherited from SPEC-006 is unchanged: cheapest access,
no frills, grow supply first. SPEC-005's job is to build the smallest
accounting and settlement surface that:

1. Lets providers see that their Macs are being used and (eventually)
   compensated, so the donation-era social contract scales to strangers.
2. Tracks per-request attribution accurately enough that a future
   SPEC-007 (AntFeed USDC rail) can settle real money against it
   without rewriting the ledger.
3. Closes H-005 (billing settlement fairness) from the SPEC-006
   security audit so the public launch gate is clear.
4. Does NOT add billing logic to the Phase 5 gateway, does NOT change
   the Phase 3 binary wire format, and does NOT require on-chain
   settlement in v1.

The dominant failure mode is the same one SPEC-006 had to design
around: building a billing system that assumes revenue before there is
revenue. SPEC-005 must avoid Stripe, invoicing, tax workflows, fiat
KYC, and any UI that implies a paid product. What it must deliver is
an internal ledger expressive enough to support real settlement later,
populated by data the coordinator already has (request_log) plus a
small set of new tables.

The hard constraint set is unusually clean for a billing spec because
SPEC-006 has already pre-decided the buyer side. There is no paid tier
in v1. Quota is free and capped. All buyer-side settlement
(reservation, refund matrix, cancellation accounting) is locked in
SPEC-006 §17.7. SPEC-005's actual surface is the provider-rewards side
of the same ledger and the operator's internal accounting view of it.

## 2. What SPEC-005 Inherits

### 2.1 From SPEC-001 v1.2.4 (frozen wire format)

- The Phase 3 binary's `inference_response_end` message carries a
  `usage` object with `prompt_tokens`, `completion_tokens`, and
  `total_tokens`.
- On `cancel_request`, providers MUST include actual token usage so
  downstream accounting can settle cancellation exactly (§6.6
  normative as of v1.2.3). Pre-v1.2.4 providers may omit usage on
  cancel; SPEC-006 §17.7 already defines the byte-estimation fallback.
- On error statuses (`error_model_not_loaded`, `error_context_exceeded`,
  `error_queue_full`, `error_internal`), the `usage` field may be
  null/absent. This is the M2.1 edge case that the R2 audit will look
  for: any reward formula that assumes non-null `completion_tokens`
  will crash on these paths.

SPEC-005 cannot ask Phase 3 binaries to emit new fields. It must
compute rewards from what is already in the wire format.

### 2.2 From SPEC-002 v1.3.3 (coordinator)

- The `request_log` table (FR-B9) is the authoritative per-request
  ledger. It already records: `request_id`, `ts_utc`, `model`,
  `provider_assigned_id`, `prompt_tokens`, `completion_tokens`,
  `total_tokens`, `latency_ms`, `routing_ms`, `status`, `stream`,
  `buyer_ip`, `error`, `pref_header`, `provider_header`, `retried`.
- The coordinator runs SQLite in WAL mode. SPEC-005 can JOIN
  `request_log` but MUST NOT ALTER it; any new columns belong in
  side tables keyed by `request_id`.
- A `tokens` table already exists for provider-auth bearer tokens
  (FR-P12). The name is taken; SPEC-005's settlement tables must use
  a different prefix (e.g., `ledger_*`, `payout_*`, `provider_earnings_*`).
- `provider_assigned_id` is the per-session ID. The stable provider
  identity for accounting is `provider_id` from the static config map
  (FR-R3). SPEC-005 reward attribution must key on `provider_id`, not
  `assigned_id`, or rewards reset every reconnect.
- FR-P11a defines circuit-breaker states (`ready`, `degraded`,
  `unavailable`) and the fault categories that trip them. Q12's
  "circuit-broken provider earning" rule must align with these states.

### 2.3 From SPEC-003 v0.7 (open onboarding)

- Provider onboarding is now stranger-shaped through
  `get.streamvc.live/install.sh`. There is no out-of-band agreement
  with the provider about compensation. Whatever SPEC-005 commits to,
  strangers will read in the docs.
- §"Rewards / billing — deferred to SPEC-005" is the operator's
  unsigned IOU. The current donation-based social contract is
  acceptable only if the operator is transparent that v1 remains
  donation-with-accounting and that real payout is a future spec.

### 2.4 From SPEC-004 (smart router)

- FR-SR-18 composes routing with FR-P11a. Multi-hop requests
  (retries across providers) emit one buyer-visible response but log
  both attempts with correct provider attribution and `retried=1`.
- FR-P11a C2 cancel-during-retry breaker attribution rules already
  define which provider "owns" a cancel during a retry boundary.
- SPEC-004 §"Rewards, billing, settlement, or contributor distribution
  logic" explicitly defers to SPEC-005 but supplies the attribution
  primitive: SPEC-005 reads `retried` and per-attempt provider IDs
  from `request_log` to split rewards on multi-hop requests.

### 2.5 From SPEC-006 v0.6 (buyer API / gateway)

- §17.7 quota refund and settlement matrix (D3) is locked. Eight
  request states with explicit token debit rules. SPEC-005's provider
  reward formula must be 1:1 with these states or the buyer is debited
  for work that the provider is not credited for (or vice versa).
- §1.8 billing-state boundary: rewards, payouts, provider contribution
  economics, payment-adjacent flows are OUT of gateway scope.
  SPEC-005 lives entirely in the coordinator process.
- H-005 (billing settlement fairness) was marked "largely covered by
  D-CROSS-1 + SPEC-001 v1.2.3 cancel-usage normative; verification
  deferred." SPEC-005 must close it by demonstrating the provider
  ledger reconstructs to the same totals as the buyer ledger for
  every D3 matrix state.

### 2.6 From SPEC-008 (Tier 2 attestation)

- Tier 2 attestation is orthogonal to SPEC-005 in v1. Attested
  providers do not earn differently from non-attested providers in
  v1; attestation is a discovery property, not an economic one. The
  reward formula must not silently encode an "attested earns more"
  bonus that operators can't see.
- However, Pillar C attestation status COULD become a multiplier in
  v2. SPEC-005's data model should leave a nullable
  `attestation_class` field on the per-request settlement row so the
  future multiplier has a place to live without a schema migration.

### 2.7 From SPEC-007 (deferred)

SPEC-005 owns the internal ledger and reward calculation. SPEC-007
owns the AntFeed USDC rail. The boundary is a machine-readable
"payout-ready" event: SPEC-005 produces it, SPEC-007 consumes it.
SPEC-005 must NOT call AntFeed APIs, MUST NOT require on-chain state,
and MUST NOT make any assumption about settlement currency at the
ledger level (see Q6).

## 3. The Twelve Open Questions

### Q1. Billing Model

**Question.** What is the buyer-side billing model in v1? The choice
shapes what kind of revenue (if any) flows into the ledger that
SPEC-005 then redistributes.

#### Options

| Option | Shape | Buyer Friction | Operator Burden | Revenue | Provider Trust |
|---|---|---:|---:|---:|---:|
| A | Pre-paid token bundles (Stripe checkout) | High | High | Real | Strong |
| B | Post-paid credit card with metered invoice | Highest | Highest | Real | Strong |
| C | API key + running balance (top-up) | Medium | Medium | Real | Strong |
| D | Donation / free with optional tip jar | Lowest | Low | None / occasional | Weak |

#### Discussion

SPEC-006 already locked the answer for v1: free quota, no payment
method, no Stripe. The gateway has no billing path and §1.8 explicitly
excludes it. Reopening Option A/B/C here would contradict a locked
spec and force the operator to redo SPEC-006's auth/gateway
architecture in the same release.

Option D is the only one consistent with the SPEC-006 lock. The
nuance is whether to add a "tip jar" surface in v1. SPEC-006 Q2 already
said donation links are acceptable only if they take less than a day
and don't imply metered entitlement. A tip jar that credits a specific
provider is materially different — it implies the operator can route
money to a provider, which means provider identity, payout address,
and dispute handling, all of which are SPEC-007 territory.

#### Recommendation

**Option D, donation-only, no per-provider tip jar in v1.** Concretely:

- No Stripe, no checkout, no credit card collection.
- No buyer balance row. The buyer-side ledger remains the gateway's
  quota counter (SPEC-006 §17). SPEC-005 does not duplicate it.
- A single "support the network" donation link (Open Collective, Stripe
  Payment Link, or GitHub Sponsors) is permitted but lives outside the
  ledger. Donations are operator income, not earmarked provider
  revenue, and that distinction must be in the docs.
- The ledger SPEC-005 builds is a **provider-credit ledger**, not a
  revenue ledger. It records what providers earned (in internal units —
  see Q6), accrued against the free-tier work they performed. Real
  buyer revenue is a SPEC-007 problem.

This is consistent with the SPEC-006 lock, closes H-005 (because the
buyer side has no settlement to falsify), and gives providers
something real (an accrued balance) without making promises about
when or whether it converts to cash.

#### Open follow-ups

- D5 (revenue split) becomes "what fraction of *future* revenue
  accrues to providers" — a forward-looking parameter, not a v1 cash
  flow.
- The donation link UX is a SPEC-006 v0.7 docs update, not a
  SPEC-005 surface.

### Q2. Settlement Cadence

**Question.** When does the ledger flip an accrued balance into a
"payout-ready" event that SPEC-007 (or the operator's manual process)
can act on?

#### Options

| Option | Shape | Ledger Noise | Operator Burden | Provider Experience |
|---|---|---:|---:|---:|
| A | Real-time accrue + weekly payout batch | Low | Low | Predictable |
| B | Monthly batch | Lowest | Lowest | Slow feedback |
| C | Threshold-triggered (e.g., when accrued > $X) | Medium | Medium | Variable |
| D | Manual operator-triggered | None | Highest | Opaque |

#### Discussion

There is no real money moving in v1 (per Q1), so "payout cadence" is
the cadence at which the ledger writes a settlement-ready row that
SPEC-007 will eventually consume. The cadence choice mainly affects:
operator dashboard latency, the size of the smallest reconciliation
unit, and how providers read their dashboards.

Real-time accrual is non-negotiable — every completed request must
update the provider's balance immediately, because that's the whole
point of having a ledger. The cadence question is only about
**when accrued balance becomes "locked" for payout**.

Option B (monthly) matches how human payroll feels but introduces a
month-long correctness window: if a bug double-credits a provider on
day 3, the operator has 27 days to find it before the bad batch
posts. Weekly (Option A) keeps the same recovery property at 7x
finer granularity.

Option C (threshold) is the SPEC-007 alignment: AntFeed micropayment
rails generally batch until threshold. But baking threshold logic into
SPEC-005 leaks SPEC-007 economics (USDC gas, channel batch size) into
the ledger.

Option D defers the cadence question entirely — the operator runs a
CLI to mint payout events. Honest for v1 but means providers can't
predict when they'll see balances locked.

#### Recommendation

**Option A: real-time accrue, weekly settlement-ready batch (UTC
Monday 00:00).** Concretely:

- Every completed request writes to `ledger_request_credits` immediately.
- A nightly job (or coordinator-internal goroutine) at UTC Monday 00:00
  reads the prior 7 days of `ledger_request_credits` per provider,
  computes a single `ledger_payout_ready` row per provider per week,
  and marks the source rows as `settled=1`.
- The `ledger_payout_ready` row is the machine-readable interface to
  SPEC-007. SPEC-007 either consumes it (paying out via AntFeed) or
  ignores it (v1 case, where it just sits there as accrual record).
- Weekly cadence is hardcoded in v1 with `settlement.cadence_days: 7`
  in `coordinator.yaml` for future tuning.

Weekly is the right grain because: it bounds incident recovery to a
week, it's slow enough that providers don't refresh dashboards
constantly, and it's fast enough to give the operator a 7-day rhythm
for reconciliation. UTC Monday avoids weekend incident surprises.

#### Open follow-ups

- The "nightly job" can be a simple `cron` row or an in-process goroutine.
  Operator should prefer in-process (no new ops surface) but the
  implementation is a SPEC-005 internal choice, not an operator decision.
- If the operator picks a different cadence (D2 decision), the
  threshold-triggered alternative (Option C) still requires a minimum
  payout floor (Q4) to avoid runaway events; weekly does not.

### Q3. Provider Reward Formula

**Question.** How is a request's value computed into per-provider
credit units?

#### Options

| Option | Shape | Predictability | Game-Resistance | Operator Visibility | Build Cost |
|---|---|---:|---:|---:|---:|
| A | Flat $/M tokens (single global rate) | Highest | Medium | Trivial | Low |
| B | Per-model $/M tokens (rate card) | High | Medium | Easy | Low |
| C | Dynamic market rate (track DeepInfra/Together) | Low | Low | Hard | High |
| D | Reputation-weighted (uptime × quality × supply) | Lowest | Highest | Hard | Highest |

#### Discussion

The right formula depends on what the operator wants to optimize.
Mac Provider's north star is "grow supply first." That means the
formula should:

1. Be legible to a stranger reading the docs in 30 seconds.
2. Reward sustained operation (an always-on Mac > a flaky Mac).
3. Not reward gaming (e.g., emitting padding tokens, forging usage).
4. Not promise more than the network can pay.

Option C (dynamic market) imports the entire reasoning of "we don't
compete on price-per-token" from SPEC-006 §2 and then contradicts it
by pegging to competitors' prices. The operator's pushback in
SPEC-006 was that the network's value is not in matching commodity
prices. Pegging rewards to commodity prices forces every reward
calculation to depend on a flaky external API and lets a price war at
DeepInfra zero out provider earnings. Wrong.

Option D (reputation-weighted) is what mature networks converge to,
but it requires uptime telemetry, quality measurement, and a supply
oracle that don't exist yet. Building reputation before there is any
abuse is premature optimization.

Option A vs B is the real choice. Option A is simpler: one number,
one formula, one ledger column. Option B respects that a 7B model
generates more useful tokens per second than a 3B model (the M4 vs M1
asymmetry in production data) and that the operator may want to
incentivize larger-model supply more than smaller-model supply.

#### Recommendation

**Option B: per-model rate card, with a single global multiplier the
operator can tune.** Concretely:

- `coordinator.yaml` carries a `rewards.rate_card` map:
  ```yaml
  rewards:
    rate_card:
      "mlx-community/Qwen2.5-7B-Instruct-4bit":
        prompt_credits_per_mtok: 100
        completion_credits_per_mtok: 200
      "mlx-community/Llama-3.2-3B-Instruct-4bit":
        prompt_credits_per_mtok: 50
        completion_credits_per_mtok: 100
    default:
      prompt_credits_per_mtok: 50
      completion_credits_per_mtok: 100
    global_multiplier: 1.0
  ```
- "Credits" are internal units (see Q6) intentionally not denominated
  in dollars or USDC in v1.
- The formula per request is:
  `credits = global_multiplier × (
      prompt_tokens × prompt_credits_per_mtok / 1_000_000 +
      completion_tokens × completion_credits_per_mtok / 1_000_000
  )`
- Unknown models fall back to `default`. New providers serving new
  models earn at default rate until the operator adds them.
- The `global_multiplier` is the operator's master volume knob. It's
  the only field operators tune day-to-day.

Per-model rates are kept in config (not the database) so changes are
auditable in git and don't require an SPEC-005 migration. The rate
card is intentionally NOT exposed via a public endpoint in v1 — only
visible to operators — because exposing it commits to a price the
network can't yet pay.

#### Open follow-ups

- D3 (operator decision) needs initial rate-card values. The numbers
  above are placeholders.
- Q4 (minimum payout threshold) becomes meaningful once the rate
  card is set; a 7B model serving 100 requests/day at the suggested
  rate generates ~$0.05 of nominal credits (assuming 1 credit = 1
  micro-dollar). The threshold must be large enough to amortize SPEC-007
  payout gas but small enough to feel real.

### Q4. Minimum Payout Threshold

**Question.** What floor of accrued credits triggers a
`ledger_payout_ready` row? Anything below this floor stays as
accrued-but-not-locked.

#### Options

| Option | Shape | Ledger Noise | Provider Patience | SPEC-007 Cost |
|---|---|---:|---:|---:|
| A | No threshold — every weekly cycle creates a payout row | High | None | High (many small payouts) |
| B | Small threshold ($0.50 nominal) | Medium | Low | Medium |
| C | Mid threshold ($5 nominal) | Low | Medium | Low |
| D | High threshold ($25 nominal) | Lowest | High | Lowest |

#### Discussion

In v1 there is no real payout, so the threshold's only function is to
prevent the ledger from accumulating thousands of tiny
`ledger_payout_ready` rows that will never settle. The cost of getting
this wrong is operational noise, not lost money.

When SPEC-007 ships, the threshold becomes economically meaningful:
AntFeed micropayment channels have a non-zero gas + settlement cost
per payout. A $0.50 payout that costs $0.10 to settle is technically
possible but feels wrong. A $25 payout amortizes payout cost to
~0.4%.

But $25 is also a multi-week or multi-month wait for a small
provider. The M1 Mac in production serves maybe a few hundred
requests/day. At the placeholder rate (50/100 credits per Mtok, 1
credit = 1 micro-dollar), it accrues a few cents per day. A $25
threshold means the M1 provider sees their first payout ~year 1.
That's too slow for a network whose north star is "grow supply
first."

#### Recommendation

**Option B: $0.50 nominal threshold, configurable.** Concretely:

- `settlement.min_payout_credits: 500000` (using the 1 credit =
  1 micro-dollar convention from Q6).
- Below threshold, the weekly settlement job rolls the accrued credits
  forward to the next cycle (they remain `settled=0` in
  `ledger_request_credits`).
- At threshold, a `ledger_payout_ready` row is created for the
  cumulative amount.
- The threshold is small enough that an actively-used Mac sees its
  first payout-ready row within a few weeks at the suggested rate
  card, and small enough that the operator can manually pay out a few
  early providers from personal funds if SPEC-007 isn't shipped yet.
- A donation/grace-period clause: providers may opt-in to "donate
  accrued credits back to the network" via a CLI command, which marks
  the credits as `settled` without creating a payout row. This
  preserves the donation-era social contract for providers who don't
  want payouts but want to keep their dashboard clean.

#### Open follow-ups

- The threshold needs revisiting once SPEC-007 lands with real per-
  payout gas data. Make it operator-configurable so SPEC-007 can
  tune without re-cutting SPEC-005.

### Q5. Revenue Split

**Question.** What fraction of the gross credit value accrues to the
provider vs. the operator, and is the split per-provider or global?

#### Options

| Option | Shape | Fairness | Operational Burden | Stranger Legibility |
|---|---|---:|---:|---:|
| A | 100% provider, 0% operator (donation operator) | Highest | Low | High |
| B | 90/10 global (provider/operator) | High | Low | High |
| C | 70/30 global | Medium | Low | Medium |
| D | Per-provider negotiated split | Low | High | Low |

#### Discussion

In v1 there is no real revenue (Q1: free quota), so this question is
about the *future* split the ledger will memorialize. The number lives
in config but is recorded on every credit row so historical splits are
auditable even if the operator changes the rate later.

Per-provider splits (Option D) might feel fair for early
contributors who deserve a higher cut. But it directly contradicts the
"stranger-shaped onboarding" of SPEC-003 — a stranger installing the
provider binary cannot know what split they'll get without an
out-of-band conversation with the operator. That's the marketplace
shape SPEC-003 explicitly rejected.

Option A (100% provider) is the strongest goodwill signal but leaves
the operator with no margin to cover infrastructure, abuse mitigation,
or growth investment. It also misaligns incentives if buyer revenue
ever arrives: the operator has zero economic motivation to grow demand
side.

Option B (90/10) signals "this is mostly your money" while leaving a
real margin. Option C (70/30) follows the SaaS pattern but feels
extractive for a network that publicly disclaims premium positioning.

#### Recommendation

**Option B: 90/10 global split, stored per-credit-row for
auditability.** Concretely:

- `rewards.provider_share: 0.90` in `coordinator.yaml`.
- Every `ledger_request_credits` row stores `provider_share_bps`
  (basis points, integer 0–10000) at the time of creation. Future rate
  changes don't retroactively rewrite history.
- The 10% operator share is also recorded as `ledger_operator_credits`
  for the same request, so the ledger sums to 100% per request and
  reconciles cleanly.
- The split is NOT exposed publicly in v1 (per the same logic as the
  rate card). It IS exposed in the provider's own dashboard endpoint
  so providers can see what share they're getting.
- v1 launch copy in `get.streamvc.live/install.sh` and provider docs
  states: "Providers earn the majority of network value (currently
  90%). Exact rates are tunable in config and visible in your
  per-provider dashboard."

#### Open follow-ups

- D5 (operator decision) is just the numeric split. The recommendation
  is 0.90.
- Per-provider splits are deferred. If a future Tier 2 attested
  provider deserves a different rate, that's a SPEC-008-v2 decision.

### Q6. Currency / Unit

**Question.** What unit does the ledger record? The answer ripples
through every column type and every SPEC-007 boundary contract.

#### Options

| Option | Shape | Type Stability | SPEC-007 Coupling | Future-Proofing |
|---|---|---:|---:|---:|
| A | Abstract "credits" (integer, undenominated) | Highest | Low | Highest |
| B | Internal units pegged to USD micro-dollars (1e-6 USD) | High | Medium | High |
| C | USDC micro-amounts (1e-6 USDC) accrued in real time | Medium | High | Medium |
| D | Fiat USD cents | Low | Medium | Low |

#### Discussion

The temptation is to write "USDC" in the schema because SPEC-007 will
settle in USDC. The risk is that USDC's value is not actually 1.00 USD
in pathological scenarios (depegging), and that committing to USDC at
the ledger layer makes the ledger USDC-specific in a way that
prevents the operator from ever paying in fiat, BTC, points, or any
other unit.

Option A (abstract credits) is the most flexible but pushes the
denomination question to SPEC-007 + the operator dashboard. Providers
see "1,234,567 credits" with no obvious conversion. This requires the
dashboard to always carry a "credits per USD" conversion key, which is
operator overhead.

Option B (USD micro-dollars) gives a stable mental model: 1 credit =
$0.000001. The rate card numbers in Q3 already implicitly assume this.
Storage is integer (no float drift), display is human-readable, and
SPEC-007 conversion to USDC is a single multiplier at payout time.

Option C (USDC micro-amounts) is what AntFeed natively speaks but
imports USDC's risk surface into a billing ledger that doesn't yet
need it.

Option D (fiat cents) is too coarse — a small completion is worth
less than 1 cent and would round to zero.

#### Recommendation

**Option B: internal "credits" denominated as USD micro-dollars
(1e-6 USD), stored as INTEGER.** Concretely:

- `ledger_request_credits.provider_credits` is INTEGER.
- 1 credit = 1 micro-dollar = $0.000001.
- A 1000-token completion at 200 credits/Mtok rate = 200 credits = $0.0002.
- The "1 credit = 1 micro-dollar" convention is documented in the
  spec § "Units" and is the ONLY denomination assumption SPEC-005
  makes. SPEC-007 converts credits to USDC at payout time using its
  own rate (likely 1:1 in v1).
- All credit math is integer arithmetic. Never floats.
- Migration path: if the operator ever needs to redenominate (e.g.,
  switch to credits-per-cent for some reason), it's a configuration
  rename, not a schema migration. The integer column type stays.

#### Open follow-ups

- The dashboard surface (Q11) should display credits in two forms:
  raw integer count and the equivalent USD amount with a clear
  "estimated, not guaranteed" disclaimer.
- SPEC-007 may add a `payout_currency` column to `ledger_payout_ready`
  when it lands. SPEC-005 should leave that field nullable so SPEC-007
  doesn't require a migration.

### Q7. Buyer Balance Enforcement

**Question.** How does the gateway behave when a buyer exhausts their
quota?

#### Options

| Option | Shape | Buyer Experience | Operator Risk | Build Cost |
|---|---|---:|---:|---:|
| A | Hard limit: 429 immediately, reset at window boundary | Predictable | Low | None (already SPEC-006) |
| B | Soft limit: warn at 80%, allow 20% grace then 429 | Friendly | Medium | Medium |
| C | Rolling window (sliding 24h) | Smooth | Low | Medium |
| D | Hard limit + manual operator override per account | Predictable | Low | Low |

#### Discussion

This question is mostly already answered by SPEC-006 §17.7. The
gateway uses hard limits at the per-account-day boundary with reset
at UTC midnight (or configurable boundary). SPEC-005's only role
here is to ensure the provider-reward ledger doesn't credit providers
for work that should have been refused upstream.

The interesting edge: a buyer at 99% of quota submits a request whose
provider response generates 2x the reservation. SPEC-006 §17.7 already
handles this on the buyer side (the actual debit may exceed
reservation up to `max_tokens_per_request`). SPEC-005's question is
whether the provider gets full credit for the overage.

The answer must be yes — the provider did the work and the wire
format already recorded the usage. Otherwise the operator would be
silently zero-crediting providers for legitimate work, which is a
fairness violation.

#### Recommendation

**Option A: hard limit at the account-day boundary, as already defined
in SPEC-006 §17.7. SPEC-005 credits providers for actual reported
usage regardless of whether the request was at-quota or over-quota.**
Concretely:

- SPEC-005 does NOT re-validate quota. The gateway already did that.
- If the gateway forwarded the request, the coordinator served it,
  and the provider reported usage, the provider gets credit.
- Operator-side recovery: if a misconfigured quota lets a buyer
  consume 10x more than intended, the buyer is debited (per SPEC-006)
  AND the provider is credited (per SPEC-005). The operator's recourse
  is to tighten the quota config, not to clawback provider credit.
- A `ledger_request_credits.overshoot_flag` column records whether
  the request exceeded the buyer's expected reservation, for
  operator visibility. Pure observation; no automatic action.

#### Open follow-ups

- D7 (operator decision) is mostly a SPEC-006 echo. The novel SPEC-005
  call is whether overshoots get a flag (recommended) or are silent.
- A soft limit (Option B) is deferred. It's a SPEC-006 UX choice, not
  a SPEC-005 ledger concern.

### Q8. Failed / Partial Request Accounting

**Question.** How does each row of SPEC-006's §17.7 D3 matrix map to
provider reward credit?

#### Discussion

This is the H-005 closure question. SPEC-006 §17.7 defines what the
*buyer* is debited for each request state. SPEC-005 must define what
the *provider* is credited for the same state. The two ledgers must
sum consistently or the operator can't reconcile.

SPEC-006 D3 matrix is 8 rows. SPEC-005 must give an answer for each.
The mapping is constrained by one normative principle: **the provider
is credited only for work the provider actually performed**, mirroring
the buyer-side principle that quota is debited only for work the
provider performed. Asymmetry here is the H-005 failure mode.

#### Recommendation

**Direct 1:1 credit mapping to the SPEC-006 §17.7 debit table.**

| Buyer status | Buyer debit (SPEC-006) | Provider credit (SPEC-005) | Notes |
|---|---|---|---|
| 200 | prompt + completion | rate_card(prompt) + rate_card(completion) | Successful work. |
| 503 (no provider reached) | none | none | No provider to credit; no `request_log` row with a `provider_assigned_id`. |
| 502, completion_tokens=0 | prompt only | rate_card(prompt) only | Provider processed prompt before failing. Credit covers prompt processing cost. |
| 502, partial stream | prompt + actual completion | rate_card(prompt) + rate_card(actual completion) | Symmetric to buyer side. |
| 504, completion_tokens=0 | prompt only | rate_card(prompt) only | Same as 502/0 case. |
| 504, partial stream | prompt + actual completion | rate_card(prompt) + rate_card(actual completion) | Symmetric. |
| Client disconnect, v1.2.4+ provider | provider-reported actual | rate_card(provider-reported actual) | Exact, normative per SPEC-001 v1.2.3. |
| Client disconnect, pre-v1.2.4, usage absent | byte-estimated | rate_card(byte-estimated, same value as buyer) | Symmetric fallback; both sides use `ceil(bytes/4)`. |

Additional rules:

- **Null usage on error path.** If `completion_tokens IS NULL` in
  `request_log` (per SPEC-001 error statuses
  `error_model_not_loaded`, `error_context_exceeded`,
  `error_queue_full`, `error_internal`), provider credit is 0. The
  provider failed to perform work; no credit owed. This is the M2.1
  edge case the R2 audit will look for.
- **Tier 2 circuit-breaker fault.** If the request count toward
  FR-P11a (e.g., `relay-timeout-mid-inference` or
  `dead-WS-mid-inference`), the provider still gets prompt credit if
  prompt_tokens is non-null. Circuit-breaker accounting (Q12) is
  separate from per-request credit.
- **Buyer-cancel exclusion.** Per FR-P11a, buyer-initiated cancels
  are NOT faults. The provider gets full credit for whatever they
  reported, just like the 200 row.

This closes H-005 by construction: for every buyer-side debit, the
SPEC-005 ledger has a matching provider-side credit derivable from
the same `request_log` row. The end-to-end test from SPEC-006 v0.6
becomes a sum-reconciliation test in SPEC-005.

#### Open follow-ups

- D8 (operator decision) is the locked mapping above. The operator
  approves the table as-is or asks for a row-by-row change.
- A reconciliation acceptance criterion: at end of day, sum of
  `request_log` quota-equivalents must equal sum of
  `ledger_request_credits` provider-equivalents within rounding
  tolerance. This becomes an AC in the BUILD spec.

### Q9. Crash Recovery / Reconciliation

**Question.** What happens if the coordinator crashes after writing
a billing/credit row but before the provider response is forwarded to
the buyer (or vice versa)?

#### Options

| Option | Shape | Consistency Model | Build Cost | Recovery Time |
|---|---|---|---:|---:|
| A | Best-effort: ignore inconsistencies | At-most-once | Low | None |
| B | Write-then-forward, replay log on restart | At-least-once | Medium | Seconds |
| C | Two-phase commit between request_log and ledger | Exactly-once | High | Slow |
| D | Eventual reconciliation: nightly job detects/repairs gaps | Eventually consistent | Medium | Hours |

#### Discussion

Coordinator crashes are rare but not impossible. The ones that matter
for billing fairness are:

1. **Crash after request_log write, before ledger credit.** Buyer
   was debited (SPEC-006 quota counter) but provider was not credited.
   Provider underpaid. H-005 violation.
2. **Crash after ledger credit, before request_log write.** Provider
   credited for a request that nobody can audit. Ghost credit. Bad.
3. **Crash mid-streaming, after partial usage was forwarded but
   before final `inference_response_end`.** Both sides have stale state.
   The streaming cancel path is supposed to handle this but a crash
   bypasses it.

Option C (2PC) is overkill for SQLite single-instance. Option A
violates H-005 by design.

The right answer is structural: **ledger writes MUST happen in the
same SQLite transaction as the `request_log` write.** SQLite's
single-writer ACID guarantees the two rows commit atomically. If the
crash happens before COMMIT, both rows are lost (and so is the
provider response forwarded to the buyer, who will get a 502 on retry).
If the crash happens after COMMIT, both rows exist.

This collapses Q9 to: "what about the in-memory state that hasn't been
written yet?"

For that, Option D (nightly reconciliation) handles the rare edge.

#### Recommendation

**Same-transaction write (Option B-flavored, ACID-grounded) plus a
nightly reconciliation pass (Option D for residual edges).** Concretely:

- The coordinator's request-completion handler writes `request_log`,
  `ledger_request_credits`, and `ledger_operator_credits` in a single
  SQLite transaction (`BEGIN IMMEDIATE; ...; COMMIT`).
- On startup, the coordinator runs a reconciliation check:
  - SELECT all `request_log` rows from the last 24h.
  - For each, verify a corresponding `ledger_request_credits` row exists
    (where status warrants credit per Q8).
  - If a `request_log` row is "creditable" but has no ledger row, write
    a recovery ledger row with `recovery_source='startup_scan'`.
  - If a `ledger_request_credits` row references a non-existent
    `request_id`, mark it `quarantined=1` for operator review.
- A nightly job (UTC 00:00) extends the same check across the last 7
  days for safety.
- The recovery algorithm is deterministic and unit-testable: given
  any (request_log, ledger) state pair, the recovery output is uniquely
  defined. This is the AC for D9.

This closes the crash-recovery question at the cheapest level
consistent with H-005. ACID does most of the work; the recovery
scanner handles the residual.

#### Open follow-ups

- D9 (operator decision) is the policy: same-transaction + startup-scan
  + nightly-reconcile. Operator can ask for a different recovery
  window than 24h startup / 7d nightly.
- For multi-region or multi-coordinator deployments (currently out of
  scope), this design would need a different model. SPEC-005 v1
  assumes the SPEC-002 single-instance SQLite deployment.

### Q10. Multi-Provider Attribution

**Question.** SPEC-004's smart router may retry a failed request to a
second provider. Both providers may have done partial work. How is
credit split?

#### Options

| Option | Shape | Fairness | Implementation Complexity |
|---|---|---:|---:|
| A | Winner-takes-all: only the provider that produced the buyer-visible response is credited | Low | Low |
| B | Per-attempt credit: each provider credited for what they actually did | High | Medium |
| C | Proportional split by usage | Medium | Medium |
| D | Operator-configurable policy | Medium | High |

#### Discussion

SPEC-004 FR-SR-18 already says retried requests log both attempts to
`request_log` with correct provider attribution and `retried=1`. The
attribution primitive exists.

Option A (winner-takes-all) is the simplest but punishes the first
provider for failures the smart router intentionally classified as
retryable. A provider that processed the prompt, hit a transient
fault, and got retried earns nothing despite real work. This breaks
the H-005 symmetry: the buyer pays for both attempts' prompt
processing under some D3 rows (the 502/0 row), but the original
provider would be credited zero. Wrong.

Option C (proportional split) assumes the buyer paid one bill and the
two providers should share it. But SPEC-006 §17.7 doesn't bill the
buyer once — it bills per-attempt according to the matrix. The
correct mirror is per-attempt provider credit, not proportional split.

Option D defers a policy decision the operator doesn't need to make.
This is a structural property of the H-005 closure, not a knob.

#### Recommendation

**Option B: per-attempt provider credit, derived directly from the
per-attempt rows in `request_log`.** Concretely:

- Every attempt logged in `request_log` (whether `retried=0` or
  `retried=1`) goes through the same Q8 credit mapping.
- The two `ledger_request_credits` rows share the same `request_id`
  but have different `attempt_n` (0, 1, ...) and different
  `provider_id`.
- The buyer's quota debit aggregates across attempts (per SPEC-006
  §17.7); the provider credit ledger records each attempt
  independently. Sum-of-credits across attempts equals sum-of-debits
  by construction.
- The dashboard shows per-attempt detail when the user drills in;
  aggregate views sum across attempts.

This composes cleanly with SPEC-004 FR-SR-18 and FR-P11a C2 cancel
attribution. It also makes the future "provider that fails a lot but
processes prompts" pattern visible — these providers earn prompt
credit but no completion credit, which is the right economic signal.

#### Open follow-ups

- D10 (operator decision) is per-attempt-credit policy. No tuning
  needed beyond accepting the recommendation.
- SPEC-004 may need a tiny patch to ensure `attempt_n` is recorded
  in `request_log`. Currently the schema has `retried` (0/1 flag); a
  monotonic `attempt_n` (0, 1, 2, ...) would be cleaner for SPEC-005's
  attribution. Cross-spec patch candidate for the R2 audit.

### Q11. Operator Dashboard

**Question.** What does the operator need to see in v1?

#### Options

| Option | Shape | Build Cost | Operator Value |
|---|---|---:|---:|
| A | Nothing (raw SQLite queries via `sqlite3` CLI) | None | Low |
| B | One JSON endpoint (`/admin/ledger`) | Low | High |
| C | Web dashboard with charts | High | Medium |
| D | Slack/email digest | Medium | Medium |

#### Discussion

SPEC-006 made the same call for buyer-side usage: build a `/usage`
JSON endpoint, no dashboard. SPEC-005 should follow the same pattern.
The one-person operator constraint hasn't changed.

The metrics that matter in the first 90 days post-launch are:

- Daily / weekly accrued credits per provider.
- Total credits accrued by all providers in current settlement window.
- Number of providers currently above the payout threshold.
- Number of `ledger_payout_ready` rows pending SPEC-007 settlement.
- Operator share total (the 10% accrual).
- Any `quarantined` or `recovery_source=startup_scan` rows that need
  human attention.
- H-005 reconciliation summary: per-day sum-of-buyer-debits vs
  sum-of-provider-credits, with delta and tolerance.

#### Recommendation

**Option B: admin-only JSON endpoint plus a per-provider read-only
endpoint.** Concretely:

- `GET /admin/ledger/summary` — totals, this week, last 4 weeks,
  pending payouts, quarantined rows. Operator-only (same auth as
  existing `/admin/*` endpoints).
- `GET /admin/ledger/providers` — per-provider breakdown: total
  earned, pending payout, last activity, attestation class
  (nullable, future-proofing for SPEC-008).
- `GET /admin/ledger/reconcile?from=YYYY-MM-DD&to=YYYY-MM-DD` — the
  H-005 reconciliation report.
- `GET /providers/{provider_id}/earnings` — provider-facing
  read-only view of their own credits. Authenticated by the
  provider's bearer token (FR-P12). Returns: total credits accrued,
  current settlement-window credits, last payout-ready row, share
  percentage, rate-card excerpt for models served.
- All three endpoints return JSON; no HTML/charts in v1.

This is enough for the operator to debug, for providers to see their
own earnings, and for the H-005 closure to be empirically
demonstrable on every deployment.

#### Open follow-ups

- D11 (operator decision) is endpoint scope. The recommendation is
  the four endpoints above; operator can trim if needed.
- A future web dashboard reading these JSON endpoints is straightforward
  but out of v1 scope.

### Q12. Fraud Floor for Degraded Providers

**Question.** Do providers earn rewards for requests routed to them
during the window before FR-P11a's circuit-breaker trips?

#### Options

| Option | Shape | Fairness | Game Resistance |
|---|---|---:|---:|
| A | Full credit until circuit trips | High to provider | Low |
| B | Reduced credit (e.g., 50%) for requests preceding a trip | Medium | Medium |
| C | Zero credit for the N requests that contributed to the trip | Low to provider | High |
| D | Zero credit until provider passes a re-warmup probe | Lowest | Highest |

#### Discussion

The risk SPEC-005 must defend against: a provider that intentionally
fast-fails most requests (zero-token completions, immediate `error_*`
statuses) to harvest prompt credit without doing completion work. The
Phase 7 stress test entries in DECISION_CRITERIA noted exactly this
pattern (the "undersized provider" case in FR-P11a's history).

Option A is the most naive — it credits the bad provider for every
prompt-processing event up to the breaker trip. At default breaker
threshold of 2 faults in 120s, the bad provider can extract prompt
credit on ~10s of failing requests before being held. That's small in
absolute terms but bad in pattern: it's an attack vector that scales
with N providers.

Option C (zero credit for fault-contributing requests) is the right
mirror of the SPEC-006 §17.7 rule: provider credit is only for work
actually performed, and FR-P11a already classifies these requests as
qualifying faults (not real work). Charging zero credit for
fault-contributing requests is the consistent answer.

Option D (re-warmup) is correct after the breaker trips — and is
already what FR-P11a does (recovery preflight). SPEC-005's job is to
keep credit ledger consistent during that recovery window.

#### Recommendation

**Option C: zero credit for the specific requests that contributed to
a circuit-breaker trip; provider returns to full credit eligibility
after passing FR-P11a recovery preflight; provider in `degraded` /
`unavailable` state earns zero credit (no requests are routed to them
anyway).** Concretely:

- `ledger_request_credits` writes a row for every request, regardless
  of fault status. The credit AMOUNT is what changes.
- For requests classified by FR-P11a as qualifying faults (relay
  timeout, dead-WS-mid-inference, qualified zero-token completion),
  `provider_credits = 0` AND `fault_flag = 'breaker_qualifying'`.
- The provider's dashboard explicitly shows the count of
  `fault_flag = 'breaker_qualifying'` requests so the provider can
  diagnose. This is also a real incentive signal: providers see their
  own bad behavior reflected as zero-credit rows.
- Once FR-P11a moves a provider to `degraded`, no requests route
  there (FR-R4), so no ledger rows are written at all. No special
  handling needed.
- On FR-P11a recovery → `ready`, the provider rejoins normal
  credit accrual immediately. No carry-over penalty.
- The 10% operator share on a zero-credit fault row is also zero. The
  fault row is recorded for audit but has no economic effect.

This is the right fraud floor: bad providers can't extract prompt
credit by fast-failing because the same fault signal that trips the
breaker also zeros their credit. Good providers are unaffected. The
ledger remains complete and auditable.

#### Open follow-ups

- D12 (operator decision) is the zero-credit policy. Operator can
  also pick Option B (reduced credit, e.g., 50%) as a softer fraud
  floor — but B is harder to defend in audits because the multiplier
  is arbitrary.
- A future "reputation score" (Q3 Option D) would consume the
  `fault_flag` history as input. SPEC-005's data shape leaves room
  for this without committing to it.

## 4. Cross-Question Coherence Check

The twelve recommendations form a coherent v1 system. Key invariants:

- **No real money in v1.** Q1 (donation-only) means the ledger
  records nominal credits, not actual cash flow. SPEC-007 is the cash
  rail.
- **H-005 closes by construction.** Q8's 1:1 credit-to-debit mapping
  makes reconciliation a property of the schema, not a runtime check.
  Q9's same-transaction write makes it crash-safe.
- **Provider trust grows via transparency.** Q11's per-provider
  earnings endpoint gives providers an honest accounting view, even
  while no money is being paid. Q5's 90/10 split signals intent. Q12's
  zero-credit-on-fault gives providers a real debugging signal.
- **The SPEC-007 boundary is a single artifact.** Q2's weekly
  settlement creates `ledger_payout_ready` rows. SPEC-007 reads them;
  SPEC-005 writes them. Nothing else crosses the boundary.
- **No new wire format dependencies.** Q3, Q8, Q12 all derive from
  data already in SPEC-001 v1.2.4. Phase 3 binaries do not need to
  change.
- **Future-proofed for Tier 2 and dynamic rates.** Q3's rate card
  is config-driven and per-model; Q6's abstract credit unit allows
  redenomination; Q11's `attestation_class` column leaves room for
  SPEC-008-v2 multipliers without migration.

## 5. Estimated Build Scope

Day 1: Schema migrations.
- `ledger_request_credits`, `ledger_operator_credits`,
  `ledger_payout_ready` tables.
- Indexes on `(provider_id, ts_utc)` for the per-provider weekly
  rollup and the dashboard endpoint.
- Migration is additive; `request_log` is untouched.

Day 2: Credit-write path.
- Hook into the request-completion handler in coordinator.
- Same-transaction write of `request_log` + ledger rows.
- Q8 mapping logic with explicit handling for each D3 matrix state.

Day 3: Rate card + config.
- `coordinator.yaml` extensions: `rewards.rate_card`,
  `rewards.provider_share`, `rewards.global_multiplier`,
  `settlement.cadence_days`, `settlement.min_payout_credits`.
- Hot-reload behavior: rate-card changes apply to NEW requests; old
  credits are immutable.

Day 4: Settlement job.
- Weekly rollup goroutine.
- Produces `ledger_payout_ready` rows above threshold; rolls forward
  below.
- Idempotent (safe to re-run a missed window).

Day 5: Endpoints.
- `/admin/ledger/summary`, `/admin/ledger/providers`,
  `/admin/ledger/reconcile`, `/providers/{provider_id}/earnings`.
- Provider bearer-token auth on the provider endpoint (existing
  FR-P12 path).

Day 6: Recovery + AC tests.
- Startup scan and nightly reconciliation.
- AC tests covering: every D3 matrix row, multi-attempt requests,
  null-usage error paths, circuit-breaker fault rows, threshold
  boundary, crash-mid-transaction.

Day 7: H-005 closure test.
- End-to-end test: synthesize N requests covering all D3 states,
  verify sum-of-debits == sum-of-credits within rounding.
- Audit prompt prep.

This fits the 6-session execution plan in
`specs/SPEC-005-EXECUTION-PLAN.md`. No surprises expected.

## 6. What This Design Defers

SPEC-005 explicitly does NOT include:

- AntFeed USDC payment rail (SPEC-007).
- On-chain settlement (any v).
- Stripe / fiat collection (no buyer revenue in v1).
- Per-provider negotiated revenue splits.
- Reputation-weighted reward formula.
- Dynamic market-rate pegging.
- KYC / 1099 / tax reporting.
- Refund/clawback workflows.
- Multi-currency ledger entries.
- Web dashboard with charts.
- Provider-tier (Tier 2 attested) reward multipliers.
- Multi-coordinator / multi-region replication.
- Webhook notifications to providers when balance crosses thresholds.

All of these are valid SPEC-007+ topics. Including any of them in
v1 violates the north star (cheapest access, no frills, grow supply
first) by adding burden before there is evidence the system works
end-to-end.

## 7. What Would Falsify This Design

The design is wrong if 90 days post-launch show:

1. **Providers ignore the earnings dashboard entirely.** Means the
   transparency signal isn't valued. Pivot: deprioritize per-provider
   endpoint, keep operator endpoint, save build cost.
2. **The 90/10 split feels extractive to early providers.** Means the
   social contract is mis-calibrated. Pivot: raise provider share to
   95/5 or 100/0 in `coordinator.yaml`.
3. **Reconciliation finds systematic delta between buyer debits and
   provider credits.** Means the Q8 mapping has a hole. Pivot: locate
   the D3 row that's wrong, patch the credit formula.
4. **Operators see runaway `quarantined` rows.** Means the recovery
   scanner is mis-classifying live data. Pivot: tune the scanner,
   possibly add an admin "force-credit" path.
5. **Bad providers extract real value via fault-credit edges.**
   Means Q12 has a loophole. Pivot: tighten the fault classifier or
   add per-day fault rate caps.
6. **Operator can't articulate the schema to a new contributor in 5
   minutes.** Means the design over-engineered. Pivot: collapse
   `ledger_request_credits` and `ledger_operator_credits` into one
   table with a `kind` column, simplify the join.
7. **SPEC-007 lands and finds the boundary contract unworkable.**
   Means `ledger_payout_ready` is the wrong artifact shape. Pivot:
   add fields SPEC-007 needs in a follow-on minor version.
8. **No provider ever crosses the payout threshold.** Means the rate
   card is too low or the threshold is too high. Pivot: tune
   `rewards.rate_card` upward or `settlement.min_payout_credits`
   downward.

The design is right if 90 days post-launch show:

- Every request that the gateway billed has a matching ledger row.
- Every provider has an earnings dashboard they actually check.
- Operator-side reconciliation runs nightly with zero variance.
- At least one provider crosses the payout threshold organically.
- H-005 audit verification produces a clean "covered" verdict.

## 8. Open Questions For Operator (Lock Before BUILD)

These are the twelve D1–D12 decisions to lock before
`specs/BUILD_SPEC_005_PROMPT.md` is written. See
`specs/SPEC-005-operator-decisions.md` for the pre-commitment table.

The recommendations above are the design's defaults. The operator
should override any default that conflicts with operator-side context
(business strategy, provider relationships, AntFeed integration
constraints) the design exploration couldn't see.

Once locked, the BUILD session has zero design space — only
implementation decisions remain.
