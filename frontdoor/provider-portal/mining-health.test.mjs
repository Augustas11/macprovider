import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

function loadPortalContext() {
  const html = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  function FakeNode(tag) {
    this.tagName = tag;
    this.classList = { contains() { return false; }, add() {}, remove() {} };
    this.style = {};
  }
  FakeNode.prototype.appendChild = function appendChild() {};
  FakeNode.prototype.setAttribute = function setAttribute() {};
  FakeNode.prototype.addEventListener = function addEventListener() {};
  const context = {
    console,
    Date,
    URL,
    Node: FakeNode,
    Promise,
    setInterval() { return 0; },
    clearInterval() {},
    setTimeout() { return 0; },
    clearTimeout() {},
    location: { pathname: "/", href: "https://portal.example/" },
    history: { replaceState() {} },
    document: {
      readyState: "loading",
      getElementById() { return null; },
      createElement(tag) {
        return new FakeNode(tag);
      },
      createElementNS(_ns, tag) { return new FakeNode(tag); },
      createTextNode(text) { return { textContent: text }; },
      addEventListener() {},
    },
    addEventListener() {},
  };
  context.window = context;
  vm.createContext(context);
  for (const script of scripts) {
    vm.runInContext(script, context);
  }
  return context;
}

function baseState(context) {
  context.state.pool = { data: { state: "ready" }, ts: Date.now(), err: null, inflight: false };
  context.state.earn = {
    data: { usdc_today: 0, idle_prewarm: { skips_by_reason_last_1h: {} } },
    ts: Date.now(),
    err: null,
    inflight: false,
  };
  context.state.malibu = {
    data: {
      wallet_bound: true,
      trust_tier: "trusted",
      withdrawable_malibu: 0,
      held_malibu: 0,
      withdrawal_hold_reasons: [],
      reward_eligibility: rewardEligibility("eligible_idle", "withdrawable", "eligible_idle_no_work"),
    },
    ts: Date.now(),
    err: null,
    inflight: false,
  };
}

function rewardEligibility(earningState, withdrawalState, primaryReason) {
  return {
    schema_version: "malibu_reward_eligibility.v1",
    earning_state: earningState,
    withdrawal_state: withdrawalState,
    primary_reason: primaryReason,
    reasons: [primaryReason],
  };
}

test("portal mining health does not render unavailable rewards as zero", () => {
  const context = loadPortalContext();
  context.state.pool = { data: { state: "ready" }, ts: Date.now(), err: null, inflight: false };
  context.state.earn = { data: null, ts: 0, err: { status: 503 }, inflight: false };
  context.state.malibu = { data: null, ts: 0, err: { status: 503 }, inflight: false };

  const health = vm.runInContext("computePortalMiningHealth()", context);

  assert.equal(health.code, "reward_projection_unavailable");
  assert.equal(health.rewardSummary, "USDC unavailable · MALIBU unavailable");
}
);

test("portal mining health prioritizes offline pool before missing rewards", () => {
  const context = loadPortalContext();
  context.state.pool = { data: { state: "unavailable" }, ts: Date.now(), err: null, inflight: false };
  context.state.earn = { data: null, ts: 0, err: { status: 503 }, inflight: false };
  context.state.malibu = { data: null, ts: 0, err: { status: 503 }, inflight: false };

  const health = vm.runInContext("computePortalMiningHealth()", context);

  assert.equal(health.code, "not_running");
  assert.equal(health.status, "Not running");
}
);

test("portal mining health distinguishes fresh zero from unavailable", () => {
  const context = loadPortalContext();
  baseState(context);

  const health = vm.runInContext("computePortalMiningHealth()", context);

  assert.equal(health.code, "idle_no_work");
  assert.equal(
    health.rewardSummary,
    "$0.00 USDC today · MALIBU 0.00 withdrawable / 0.00 held"
  );
}
);

test("portal mining health prioritizes local blockers and reward holds", () => {
  const context = loadPortalContext();
  baseState(context);

  context.state.earn.data.idle_prewarm.skips_by_reason_last_1h = { on_battery: 2 };
  assert.equal(vm.runInContext("computePortalMiningHealth().code", context), "local_on_battery");

  context.state.earn.data.idle_prewarm.skips_by_reason_last_1h = { thermal_pressure: 1 };
  assert.equal(vm.runInContext("computePortalMiningHealth().code", context), "local_thermal_pressure");

  context.state.earn.data.idle_prewarm.skips_by_reason_last_1h = {};
  context.state.malibu.data.wallet_bound = false;
  context.state.malibu.data.reward_eligibility = rewardEligibility(
    "ineligible",
    "ineligible",
    "missing_wallet_binding"
  );
  assert.equal(vm.runInContext("computePortalMiningHealth().code", context), "wallet_missing");

  context.state.malibu.data.wallet_bound = true;
  context.state.malibu.data.trust_tier = "provisional";
  context.state.malibu.data.withdrawal_hold_reasons = [];
  context.state.malibu.data.reward_eligibility = rewardEligibility(
    "held",
    "held",
    "held_provisional_trust_tier"
  );
  context.state.malibu.data.trust_criteria_met = 1;
  context.state.malibu.data.trust_criteria_required = 3;
  const provisional = vm.runInContext("computePortalMiningHealth()", context);
  assert.equal(provisional.code, "trust_tier_provisional");
  assert.equal(provisional.action, "Complete 2 more trust criteria to unlock withdrawals.");

  context.state.malibu.data.trust_tier = "trusted";
  context.state.malibu.data.withdrawal_hold_reasons = ["per_wallet_daily_cap"];
  context.state.malibu.data.reward_eligibility = rewardEligibility("capped", "capped", "held_wallet_daily_cap");
  assert.equal(vm.runInContext("computePortalMiningHealth().code", context), "wallet_daily_cap_held");

  context.state.malibu.data.withdrawal_hold_reasons = ["manual_review"];
  context.state.malibu.data.held_malibu = 2;
  context.state.malibu.data.reward_eligibility = rewardEligibility("held", "held", "held_demotion_cooldown");
  assert.equal(vm.runInContext("computePortalMiningHealth().code", context), "rewards_held");
}
);

test("provider wallet status normalizes unknown schema unavailable", () => {
  const warnings = [];
  const context = loadPortalContext();
  context.console = { ...console, warn(...args) { warnings.push(args); } };
  context.state.wallet.data = {
    schema_version: "provider_wallet_status.v2",
    provider_id: "mp-test",
    wallet_bound: true,
  };

  const normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);

  assert.equal(normalized.unavailable, true);
  assert.equal(normalized.schema_version, "provider_wallet_status.v2");
  assert.equal(warnings[0][0], "provider_wallet_status_schema_drift");
}
);

test("provider wallet status normalizes incomplete v1 unavailable", () => {
  const warnings = [];
  const context = loadPortalContext();
  context.console = { ...console, warn(...args) { warnings.push(args); } };
  context.state.wallet.data = {
    schema_version: "provider_wallet_status.v1",
    provider_id: "mp-test",
    wallet_bound: true,
    wallet_mismatch: false,
    reward_wallet: {
      verification_source: "provider_emission_state",
      cap_replay_pending: false,
    },
    eligibility_inputs: {
      trust_tier: "trusted",
      quarantined: false,
      receipt_quality: "sufficient_verified_receipts",
      verified_receipt_count: 3,
      required_receipt_count: 3,
      compute_integrity_state: "unknown",
      attestation_tier: "app_attested",
      app_attested: true,
      criteria_met: 3,
      criteria_required: 3,
      economic_criteria: [],
      additional_criteria: [],
      wallet_balance_ok: true,
      uptime_ok: true,
    },
  };

  const normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);

  assert.equal(normalized.unavailable, true);
  assert.equal(normalized.schema_version, "provider_wallet_status.v1");
  assert.equal(warnings[0][0], "provider_wallet_status_schema_drift");
  assert.equal(warnings[0][1].field, "reward_amounts.body");
}
);

test("provider wallet status requires reward eligibility and audit events", () => {
  const warnings = [];
  const context = loadPortalContext();
  context.console = { ...console, warn(...args) { warnings.push(args); } };
  const complete = {
    schema_version: "provider_wallet_status.v1",
    provider_id: "mp-test",
    wallet_bound: true,
    wallet_mismatch: false,
    reward_wallet: {
      verification_source: "provider_emission_state",
      cap_replay_pending: false,
    },
    reward_amounts: {
      accrued_malibu: "0",
      withdrawable_malibu: "0",
      held_malibu: "0",
      provider_daily_cap_malibu: 25,
      provider_day_malibu: "0",
      provider_daily_capped: false,
      wallet_daily_cap_malibu: 100,
      wallet_day_malibu: "0",
      wallet_daily_capped: false,
    },
    eligibility_inputs: {
      trust_tier: "trusted",
      quarantined: false,
      receipt_quality: "sufficient_verified_receipts",
      verified_receipt_count: 3,
      required_receipt_count: 3,
      compute_integrity_state: "unknown",
      attestation_tier: "app_attested",
      app_attested: true,
      criteria_met: 3,
      criteria_required: 3,
      economic_criteria: [],
      additional_criteria: [],
      wallet_balance_ok: true,
      uptime_ok: true,
    },
    reward_eligibility: rewardEligibility("eligible_idle", "withdrawable", "eligible_idle_no_work"),
    audit: { events: [{ id: "evt-1", occurred_at: "2026-08-18T00:00:00Z", event_type: "wallet_bind_projected", summary: "Wallet projected." }] },
  };

  context.state.wallet.data = { ...complete };
  delete context.state.wallet.data.reward_eligibility;
  let normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "reward_eligibility.body");

  context.state.wallet.data = {
    ...complete,
    payout_wallet: {
      chain: "base-mainnet",
      address: "0xPayout",
      payout_allowed: "yes",
      verification_source: "provider_payout_addresses",
    },
  };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "payout_wallet.payout_allowed");

  context.state.wallet.data = {
    ...complete,
    payout_wallet: {
      chain: "base-mainnet",
      address: "0xPayout",
      payout_allowed: true,
      verification_source: "provider_payout_addresses",
      last_update_utc: "",
    },
  };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "payout_wallet.last_update_utc");

  context.state.wallet.data = {
    ...complete,
    reward_wallet: { ...complete.reward_wallet, address: true },
  };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "reward_wallet.address");

  context.state.wallet.data = { ...complete, audit: {} };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "audit.events");

  context.state.wallet.data = { ...complete, audit: { events: [{ event_type: "wallet_bind_projected" }] } };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "audit.events[0].id");

  context.state.wallet.data = { ...complete, audit: { next_before_id: 42, events: complete.audit.events } };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "audit.next_before_id");

  context.state.wallet.data = {
    ...complete,
    reward_amounts: { ...complete.reward_amounts, accrued_malibu: true },
  };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "reward_amounts.accrued_malibu");

  context.state.wallet.data = {
    ...complete,
    audit: { events: [{ ...complete.audit.events[0], amount_malibu: "not-a-number" }] },
  };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "audit.events[0].amount_malibu");

  context.state.wallet.data = {
    ...complete,
    audit: { events: [{ ...complete.audit.events[0], amount_malibu: true }] },
  };
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, true);
  assert.equal(warnings.at(-1)[1].field, "audit.events[0].amount_malibu");

  context.state.wallet.data = complete;
  normalized = vm.runInContext("normalizedProviderWalletStatus(state.wallet.data)", context);
  assert.equal(normalized.unavailable, undefined);
  assert.equal(normalized.reward_eligibility.primary_reason, "eligible_idle_no_work");
});

test("dashboard wallet helpers keep payout address and daily-limit copy provider-facing", () => {
  const context = loadPortalContext();
  baseState(context);
  const wallet = {
    schema_version: "provider_wallet_status.v1",
    provider_id: "mp-test",
    wallet_bound: true,
    wallet_mismatch: true,
    hold_or_mismatch_reason: "wallet_projection_mismatch",
    payout_wallet: {
      chain: "base-mainnet",
      address: "0xPayout",
      payout_allowed: true,
      verification_source: "provider_payout_addresses",
    },
    reward_wallet: {
      address: "0xReward",
      verification_source: "provider_emission_state",
      cap_replay_pending: true,
    },
    reward_amounts: {
      accrued_malibu: "10",
      withdrawable_malibu: "7.5",
      held_malibu: "2.5",
      provider_daily_cap_malibu: 25,
      provider_day_malibu: "25",
      provider_daily_capped: true,
      wallet_day_malibu: "100",
      wallet_daily_cap_malibu: 100,
      wallet_daily_capped: true,
    },
    eligibility_inputs: {
      trust_tier: "trusted",
      quarantined: false,
      receipt_quality: "sufficient_verified_receipts",
      verified_receipt_count: 3,
      required_receipt_count: 3,
      compute_integrity_state: "unknown",
      attestation_tier: "app_attested",
      app_attested: true,
      criteria_met: 3,
      criteria_required: 3,
      economic_criteria: [],
      additional_criteria: [],
      wallet_balance_ok: true,
      uptime_ok: true,
    },
    reward_eligibility: rewardEligibility("capped", "capped", "held_provider_daily_cap"),
    audit: { events: [{ id: "evt-1", occurred_at: "2026-08-18T00:00:00Z", event_type: "wallet_bind_projected", summary: "Wallet projected." }] },
  };
  context.state.wallet.data = wallet;
  context.state.malibu.data.reward_eligibility = wallet.reward_eligibility;

  assert.equal(vm.runInContext("dashPayoutAddress()", context), "0xPayout");
  assert.equal(
    vm.runInContext("dashboardEligibilityCopy(normalizedMalibuRewardEligibility(state.malibu.data))", context),
    "MALIBU above the daily limit is held."
  );
  assert.equal(vm.runInContext("normalizedProviderWalletStatus(state.wallet.data).hold_or_mismatch_reason", context), "wallet_projection_mismatch");
}
);

test("portal accepts provider daily cap reward reason", () => {
  const context = loadPortalContext();
  baseState(context);
  context.state.malibu.data.reward_eligibility = rewardEligibility(
    "capped",
    "capped",
    "held_provider_daily_cap"
  );

  const eligibility = vm.runInContext("normalizedMalibuRewardEligibility(state.malibu.data)", context);

  assert.equal(eligibility.primary_reason, "held_provider_daily_cap");
  assert.equal(vm.runInContext("malibuRewardReasonCopy('held_provider_daily_cap')", context), "daily limit reached");
  assert.equal(vm.runInContext("computePortalMiningHealth().code", context), "provider_daily_cap_held");
}
);
