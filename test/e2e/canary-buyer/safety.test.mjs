import test from 'node:test';
import assert from 'node:assert/strict';

import {
  RunBudget,
  gatewayInvariantReasons,
  gatewaySnapshot,
  performanceRegressionReasons,
  poolzInvariantReasons,
  poolzSnapshot,
  providerSignalReasons,
  providerSignalSnapshot,
  recoverySoakReasons,
  validateBaselineDocument,
} from './safety.mjs';

function healthyGateway() {
  return gatewaySnapshot({
    status: 'up',
    degraded: false,
    coordinator: { status: 'up', checked_at: '2026-07-14T12:00:00Z' },
    pool: { total_providers: 2, ready: 2, degraded: 0, draining: 0, unavailable: 0 },
    models: [
      { id: 'model-a', provider_count: 1, ready_provider_count: 1, slots_free: 1, available: true, degraded: false },
      { id: 'model-b', provider_count: 1, ready_provider_count: 1, slots_free: 1, available: true, degraded: false },
    ],
  });
}

function poolz(nowMs, overrides = {}) {
  const stamp = (offset) => new Date(nowMs + offset).toISOString();
  return poolzSnapshot({ pool: [
    {
      assigned_id: 'provider-a', state: 'ready', routing_eligible: true,
      connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
    },
    {
      assigned_id: 'provider-b', state: 'ready', routing_eligible: true,
      connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
      ...overrides,
    },
  ] }, nowMs);
}

function provider(overrides = {}) {
  return providerSignalSnapshot({
    provider_id: 'provider-a', status: 'ready', restart_count: 1, uptime_s: 1_000,
    memory_rss_mb: 2_000, capacity: { ram_gb: 8 }, requests_in_flight: 0, requests_queued: 0,
    coordinator: { connected: true },
    ...overrides,
  }, 'provider-a');
}

test('hard request, token, and time budgets never admit an over-budget request', () => {
  const budget = new RunBudget({ maxRequests: 2, maxCompletionTokens: 16, maxDurationMs: 1_000, startedAtMs: 100 });
  assert.equal(budget.reserve(8, 100), null);
  budget.recordProvider('provider-a', 8);
  assert.equal(budget.reserve(9, 200), 'token_budget_exhausted:17_gt_16');
  assert.equal(budget.reserve(8, 200), null);
  budget.recordProvider('provider-a', 8);
  assert.equal(budget.reserve(1, 200), 'request_budget_exhausted:3_gt_2');
  assert.match(budget.timeReason(1_100), /^time_budget_exhausted/);
  assert.deepEqual(budget.snapshot(300).used.providers['provider-a'], {
    requests: 2,
    completion_tokens_reserved: 16,
  });
});

test('gateway pre/post invariants catch capacity loss, drain, and model loss', () => {
  const initial = healthyGateway();
  assert.deepEqual(gatewayInvariantReasons(initial, initial, { minReadyProviders: 2 }), []);
  const changed = structuredClone(initial);
  changed.pool.ready = 1;
  changed.pool.draining = 1;
  changed.models[0].available = false;
  assert.deepEqual(gatewayInvariantReasons(initial, changed, { minReadyProviders: 2 }), [
    'ready_1_lt_2',
    'pool_draining_1_ne_0',
    'ready_changed_2_to_1',
    'model-a:model_not_stably_available',
  ]);
});

test('operator pool invariants abort on state, connection, and heartbeat regressions', () => {
  const now = Date.parse('2026-07-14T12:00:00Z');
  const initial = poolz(now);
  const stale = structuredClone(initial);
  stale[1].state = 'draining';
  stale[1].heartbeat_age_ms = 100_000;
  stale[1].activity_age_ms = 100_000;
  const reasons = poolzInvariantReasons(initial, stale, { maxHeartbeatAgeMs: 90_000 });
  assert.ok(reasons.includes('provider-b:state_draining_not_ready'));
  assert.ok(reasons.some((reason) => reason.startsWith('provider-b:heartbeat_stale_')));
});

test('provider observers abort on restart, memory growth, thermal pressure, and queue growth', () => {
  const initial = provider();
  const changed = provider({
    restart_count: 2,
    memory_rss_mb: 7_500,
    thermal_state: 'critical',
    requests_queued: 1,
  });
  const reasons = providerSignalReasons(initial, changed, { maxMemoryGrowthMB: 512, maxMemoryFraction: 0.9 });
  assert.ok(reasons.includes('provider-a:restart_count_changed_1_to_2'));
  assert.ok(reasons.includes('provider-a:thermal_pressure'));
  assert.ok(reasons.some((reason) => reason.includes('memory_growth')));
  assert.ok(reasons.includes('provider-a:requests_queued_1_ne_0'));
});

test('sharp baseline regression aborts even when the request returned 2xx', () => {
  const baseline = {
    decode_tps_p50: 30,
    ttft_p95_ms: 1_000,
    max_tps_regression_fraction: 0.35,
    max_ttft_regression_fraction: 0.5,
  };
  assert.deepEqual(performanceRegressionReasons({ decodeTps: 8.9, ttftMs: 1_600 }, baseline), [
    'ttft_regression_1600ms_gt_1500ms',
    'decode_tps_regression_8.9_lt_19.5',
  ]);
});

test('baseline files require provider and hardware-tier provenance', () => {
  assert.throws(() => validateBaselineDocument({ schema_version: 1, entries: [{ model: 'model-a' }] }), /hardware_tier/);
  const entries = validateBaselineDocument({ schema_version: 1, entries: [{
    model: 'model-a', provider: 'provider-a', hardware_tier: 'm1-8gb',
    decode_tps_p50: 30, ttft_p95_ms: 1_000, sample_size: 20,
    max_tps_regression_fraction: 0.35, max_ttft_regression_fraction: 0.5,
    percentile_choice: 'decode p50 / TTFT p95', conditions: 'warm, AC power', safety_margin: '35%',
  }] });
  assert.equal(entries[0].hardware_tier, 'm1-8gb');
});

test('recovery requires multiple stable samples and advancing heartbeat or activity', () => {
  const now = Date.parse('2026-07-14T12:00:00Z');
  const gateway = healthyGateway();
  const operatorInitial = poolz(now);
  const providerInitial = [provider()];
  const noAdvance = recoverySoakReasons({
    gatewayInitial: gateway,
    gatewaySamples: [gateway, gateway],
    poolzInitial: operatorInitial,
    poolzSamples: [operatorInitial, operatorInitial],
    providerInitial,
    providerSamples: [providerInitial, providerInitial],
  }, { minReadyProviders: 2, maxHeartbeatAgeMs: 90_000 });
  assert.ok(noAdvance.some((reason) => reason.includes('heartbeat_or_activity_did_not_advance')));

  const advanced = structuredClone(operatorInitial);
  for (const row of advanced) {
    row.last_heartbeat_at_ms += 30_000;
    row.last_activity_at_ms += 30_000;
    row.heartbeat_age_ms = 0;
    row.activity_age_ms = 0;
  }
  assert.deepEqual(recoverySoakReasons({
    gatewayInitial: gateway,
    gatewaySamples: [gateway, gateway],
    poolzInitial: operatorInitial,
    poolzSamples: [operatorInitial, advanced],
    providerInitial,
    providerSamples: [providerInitial, [provider({ uptime_s: 1_030 })]],
  }, { minReadyProviders: 2, maxHeartbeatAgeMs: 90_000 }), []);
});
