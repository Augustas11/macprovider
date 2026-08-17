import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

function loadPortalContext() {
  const html = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  const context = {
    console,
    Date,
    URL,
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
        return {
          tagName: tag,
          classList: { contains() { return false; }, add() {}, remove() {} },
          style: {},
          appendChild() {},
          setAttribute() {},
          addEventListener() {},
        };
      },
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
    data: { current_window_credits: 0, idle_prewarm: { skips_by_reason_last_1h: {} } },
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
  assert.equal(health.rewardSummary, "Credits unavailable · MALIBU unavailable");
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
    "Credits current window: 0 · MALIBU: 0.00 MALIBU withdrawable / 0.00 MALIBU held"
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
