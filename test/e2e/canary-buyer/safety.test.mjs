import test from 'node:test';
import assert from 'node:assert/strict';

import {
  RunBudget,
  expectedFleetReasons,
  findBaseline,
  gatewayInvariantReasons,
  gatewaySnapshot,
  performanceRegressionReasons,
  poolzInvariantReasons,
  poolzSnapshot,
  providerSignalReasons,
  providerSignalSnapshot,
  responseIdentityReasons,
  qualificationIsolationReasons,
  recoverySoakReasons,
  validateBaselineDocument,
  validateExpectedFleetDocument,
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
      provider_id: 'provider-a', assigned_id: 'session-a', model_id: 'model-a', state: 'ready', routing_eligible: true,
      connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
    },
    {
      provider_id: 'provider-b', assigned_id: 'session-b', model_id: 'model-b', state: 'ready', routing_eligible: true,
      connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
      ...overrides,
    },
  ] }, nowMs);
}

function provider(overrides = {}) {
  return providerSignalSnapshot({
    safety_telemetry: {
      schema_version: 2,
      provider_id: 'provider-a', model_id: 'model-a', model_loaded: true,
      hardware_tier: '8GB', runtime_state: 'ready', restart_count: 1, uptime_s: 1_000,
      memory_rss_mb: 2_000, memory_capacity_mb: 8_192, memory_pressure: 'normal',
      thermally_throttled: false, thermal_state: 'nominal',
      requests_in_flight: 0, requests_queued: 0, coordinator_connected: true,
      coordinator_session_id: 'session-a', cpu_utilization_pct: 12, gpu_utilization_pct: 18,
      gpu_utilization_scope: 'host',
      power_source: 'external', binary_version: '1.8.33', compatibility_set_id: 'set-a',
      model_hash: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      observation_id: 'observation-a', observed_at: new Date().toISOString(), valid_for_ms: 5_000,
      ...overrides,
    },
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

test('run budget capacity can only grow to a valid minimum', () => {
  const budget = new RunBudget({ maxRequests: 2, maxCompletionTokens: 16, maxDurationMs: 1_000, startedAtMs: 100 });
  budget.ensureMinimumCapacity({ maxRequests: 1, maxCompletionTokens: 8 });
  assert.equal(budget.snapshot(100).limits.max_requests_per_provider, 2);
  assert.equal(budget.snapshot(100).limits.max_completion_tokens_per_provider, 16);
  budget.ensureMinimumCapacity({ maxRequests: 5, maxCompletionTokens: 40 });
  assert.equal(budget.snapshot(100).limits.max_requests_per_provider, 5);
  assert.equal(budget.snapshot(100).limits.max_completion_tokens_per_provider, 40);
  assert.throws(() => budget.ensureMinimumCapacity({ maxRequests: 0 }), /maxRequests must be a positive safe integer/);
});

test('gateway pre/post invariants match exact active non-routable aggregation loss', () => {
  const initial = healthyGateway();
  assert.deepEqual(gatewayInvariantReasons(initial, initial, { minReadyProviders: 2 }), []);
  const active = structuredClone(initial);
  active.status = 'degraded';
  active.degraded = true;
  active.pool.total_providers = 1;
  active.pool.ready = 1;
  active.models = active.models.filter((model) => model.id !== 'model-a');
  assert.deepEqual(gatewayInvariantReasons(initial, active, {
    minReadyProviders: 2, activeModelID: 'model-a',
  }), []);
  assert.deepEqual(gatewayInvariantReasons(initial, initial, {
    minReadyProviders: 2, activeModelID: 'model-a',
  }), []);
  const inventedDegradedRow = structuredClone(initial);
  inventedDegradedRow.pool.ready = 1;
  inventedDegradedRow.pool.degraded = 1;
  inventedDegradedRow.models[0].ready_provider_count = 0;
  inventedDegradedRow.models[0].available = false;
  inventedDegradedRow.models[0].degraded = true;
  assert.ok(gatewayInvariantReasons(initial, inventedDegradedRow, {
    minReadyProviders: 2, activeModelID: 'model-a',
  }).length > 0);
  const changed = structuredClone(initial);
  changed.pool.ready = 1;
  changed.pool.draining = 1;
  changed.models[0].available = false;
  assert.deepEqual(gatewayInvariantReasons(initial, changed, { minReadyProviders: 2 }), [
    'ready_1_lt_2',
    'pool_draining_1_gt_0',
    'ready_changed_2_to_1',
    'model-a:model_not_stably_available',
  ]);
  assert.deepEqual(gatewayInvariantReasons(initial, changed, {
    minReadyProviders: 1,
    maxDrainingProviders: 1,
    enforceStableProviderCounts: false,
    enforceStableModelSet: false,
  }), []);
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
  const active = structuredClone(initial);
  active[0].state = 'busy';
  active[0].routing_eligible = false;
  assert.deepEqual(poolzInvariantReasons(initial, active, { activeProviderID: 'provider-a' }), []);
});

test('operator pool projects versioned heartbeat safety telemetry for remote liveness', () => {
  const now = Date.parse('2026-07-14T12:00:00Z');
  const rows = poolzSnapshot({ pool: [{
    provider_id: 'provider-a', assigned_id: 'session-a', model_id: 'model-a',
    binary_version: '1.8.30', catalog_admission_mode: 'legacy_bridge',
    state: 'ready', routing_eligible: true, connected_at: new Date(now - 60_000).toISOString(),
    last_heartbeat_at: new Date(now - 1_000).toISOString(),
    safety_telemetry: {
      schema_version: 2, provider_id: 'provider-a', model_id: 'model-a', model_loaded: true,
      hardware_tier: '8GB', runtime_state: 'ready', restart_count: 1, uptime_s: 1_000,
      memory_rss_mb: 2_000, memory_capacity_mb: 8_192, memory_pressure: 'normal',
      thermally_throttled: false, thermal_state: 'nominal', requests_in_flight: 0,
      requests_queued: 0, coordinator_connected: true, observation_id: 'observation-a',
      coordinator_session_id: 'session-a', cpu_utilization_pct: 12, gpu_utilization_pct: 18,
      gpu_utilization_scope: 'host',
      power_source: 'external', binary_version: '1.8.33', compatibility_set_id: 'set-a',
      model_hash: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      observed_at: new Date(now - 1_000).toISOString(), valid_for_ms: 90_000,
    },
  }] }, now);
  assert.equal(rows[0].binary_version, '1.8.30');
  assert.equal(rows[0].catalog_admission_mode, 'legacy_bridge');
  assert.equal(rows[0].safety_telemetry.provider_id, 'provider-a');
  assert.deepEqual(providerSignalReasons(rows[0].safety_telemetry, rows[0].safety_telemetry), []);
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
  assert.deepEqual(providerSignalReasons(initial, provider({
    runtime_state: 'busy', requests_in_flight: 1,
  }), { maxRequestsInFlight: 1, allowedRuntimeStates: ['ready', 'busy'] }), []);
});

test('sharp baseline regression aborts even when the request returned 2xx', () => {
  const baseline = {
    decode_tps_p50: 30,
    ttft_p95_ms: 1_000,
    max_tps_regression_fraction: 0.35,
    max_ttft_regression_fraction: 0.5,
  };
  assert.deepEqual(performanceRegressionReasons({ ttftMs: 1_600 }, baseline, 'ttft'), [
    'ttft_regression_1600ms_gt_1500ms',
  ]);
  assert.deepEqual(performanceRegressionReasons({ decodeTps: 8.9 }, baseline, 'tps'), [
    'decode_tps_regression_8.9_lt_19.5',
  ]);
  assert.deepEqual(performanceRegressionReasons({ decodeTps: null }, baseline, 'tps'), ['decode_tps_signal_missing']);
});

test('baseline files require fresh provider, hardware, thermal, and build provenance', () => {
  const now = Date.parse('2026-07-14T12:06:00Z');
  assert.throws(() => validateBaselineDocument({ schema_version: 2, entries: [{ model: 'model-a' }] }, now), /schema_version=3/);
  const entries = validateBaselineDocument({ schema_version: 3, entries: [{
    model: 'model-a', provider: 'provider-a', hardware_tier: '8GB',
    compatibility_set_id: 'set-a', binary_version: '1.8.33',
    model_hash: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    power_source: 'external',
    decode_tps_p50: 30, ttft_p95_ms: 1_000, sample_size: 20, cold_sample_size: 10, warm_sample_size: 10,
    max_tps_regression_fraction: 0.35, max_ttft_regression_fraction: 0.5,
    percentile_choice: 'decode p50 / TTFT p95', conditions: 'warm, AC power', safety_margin: '35%',
    thermal_condition: 'nominal', decode_tps_variance: 2.1, ttft_ms_variance: 12_000,
    measured_at: '2026-07-14T12:00:00Z', evidence_uri: 's3://evidence/run.json',
    approved_at: '2026-07-14T12:05:00Z', valid_until: '2026-07-21T12:05:00Z',
    evidence_sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  }] }, now);
  assert.equal(entries[0].hardware_tier, '8GB');
  const identity = {
    compatibilitySetID: 'set-a', binaryVersion: '1.8.33', modelHash: entries[0].model_hash,
    powerSource: 'external', thermalCondition: 'nominal',
  };
  assert.equal(findBaseline(entries, 'model-a', 'provider-a', '8GB', identity), entries[0]);
  assert.equal(findBaseline(entries, 'model-a', 'provider-a', '16GB', identity), null);
  const hardwareSpecific = validateBaselineDocument({ schema_version: 3, entries: [
    entries[0],
    { ...entries[0], hardware_tier: '16GB' },
  ] }, now);
  assert.equal(findBaseline(hardwareSpecific, 'model-a', 'provider-a', '16GB', identity)?.hardware_tier, '16GB');
  assert.throws(() => validateBaselineDocument({ schema_version: 3, entries: [entries[0], entries[0]] }, now), /unique/);
  assert.throws(() => validateBaselineDocument({ schema_version: 3, entries: [{ ...entries[0], valid_until: '2026-07-14T11:59:00Z' }] }, now), /expired/);
  assert.throws(() => validateBaselineDocument({ schema_version: 3, entries: [{
    ...entries[0], measured_at: '2026-06-01T12:00:00Z', approved_at: '2026-07-14T12:00:00Z',
  }] }, now), /approval window/);
  assert.throws(() => validateBaselineDocument({ schema_version: 3, entries: [{
    ...entries[0], approved_at: '2026-07-14T12:07:00Z', valid_until: '2026-07-21T12:07:00Z',
  }] }, now), /approval window/);
  assert.equal(findBaseline(entries, 'model-a', 'provider-a', '8GB', { ...identity, thermalCondition: 'fair' }), null);
});

test('expected fleet and qualification isolation require exact provider/model/routing truth', () => {
  const now = Date.now();
  const expected = validateExpectedFleetDocument({ schema_version: 1, providers: [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ] });
  const rows = poolz(now);
  assert.deepEqual(expectedFleetReasons(rows, expected, {
    maxHeartbeatAgeMs: 90_000,
  }), []);
  const activeRows = structuredClone(rows);
  activeRows[0].state = 'busy';
  activeRows[0].routing_eligible = false;
  assert.deepEqual(expectedFleetReasons(activeRows, expected, {
    maxHeartbeatAgeMs: 90_000, activeProviderID: 'provider-a',
  }), []);
  const rowsWithUnexpectedProvider = structuredClone(rows);
  rowsWithUnexpectedProvider.push({
    ...rowsWithUnexpectedProvider[0], provider_id: 'provider-c', model_id: 'model-c',
  });
  assert.ok(expectedFleetReasons(rowsWithUnexpectedProvider, expected, {
    maxHeartbeatAgeMs: 90_000,
  }).includes('provider-c:unexpected_provider'));
  rows[1].routing_eligible = false;
  rows[1].state = 'draining';
  assert.deepEqual(qualificationIsolationReasons(rows, {
    targetProviderID: 'provider-b', targetModel: 'model-b', maxHeartbeatAgeMs: 90_000,
    localProviderSignal: provider({ provider_id: 'provider-b', model_id: 'model-b', coordinator_session_id: 'session-b' }),
  }), []);
  rows[1].routing_eligible = true;
  assert.ok(qualificationIsolationReasons(rows, {
    targetProviderID: 'provider-b', targetModel: 'model-b', maxHeartbeatAgeMs: 90_000,
    localProviderSignal: provider({ provider_id: 'provider-b', model_id: 'model-b', coordinator_session_id: 'session-b' }),
  }).includes('isolation_target_still_routable'));
  assert.deepEqual(validateExpectedFleetDocument({ schema_version: 1, providers: [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-a' },
    { provider_id: 'provider-c', model_id: 'model-c' },
  ] }, { requireUniqueModels: false }), [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-a' },
    { provider_id: 'provider-c', model_id: 'model-c' },
  ]);
  assert.deepEqual(validateExpectedFleetDocument({ schema_version: 1, providers: [
    { provider_id: 'provider-a', model_id: 'model-a' },
  ] }, { requireUniqueModels: false }), [
    { provider_id: 'provider-a', model_id: 'model-a' },
  ]);
  assert.throws(() => validateExpectedFleetDocument({ schema_version: 1, providers: [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ] }, { expectedProviderCount: 3 }), /exactly 3/);
  assert.throws(() => validateExpectedFleetDocument({ schema_version: 1, providers: [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-a' },
  ] }), /unique model_id/);
});

test('response attribution requires exact provider and model in both canary modes', () => {
  const fleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ];
  assert.deepEqual(responseIdentityReasons({ provider: 'provider-a', responseModel: 'model-a' }, 'model-a', fleet), []);
  assert.deepEqual(responseIdentityReasons({ provider: '', responseModel: 'model-b' }, 'model-a', fleet), [
    'model-a:response_model_model-b_ne_model-a',
    'model-a:response_provider_missing_ne_provider-a',
  ]);
  const duplicateModelFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-a' },
  ];
  assert.deepEqual(responseIdentityReasons({ provider: 'provider-b', responseModel: 'model-a' }, 'model-a', duplicateModelFleet), []);
  assert.deepEqual(responseIdentityReasons({ provider: 'provider-c', responseModel: 'model-a' }, 'model-a', duplicateModelFleet), [
    'model-a:response_provider_provider-c_ne_provider-a|provider-b',
  ]);
  assert.deepEqual(responseIdentityReasons(
    { provider: 'provider-b', responseModel: 'model-a' },
    'model-a',
    duplicateModelFleet,
    { expectedProviderID: 'provider-a' },
  ), [
    'model-a:response_provider_provider-b_ne_provider-a',
  ]);
});

test('recovery allows stable heartbeat samples but requires eventual advance plus telemetry progress', () => {
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
  assert.ok(noAdvance.some((reason) => reason.includes('heartbeat_did_not_advance')));
  assert.ok(noAdvance.some((reason) => reason.includes('telemetry_observation_did_not_advance')));

  const advanced1 = structuredClone(operatorInitial);
  for (const row of advanced1) {
    row.last_heartbeat_at_ms += 30_000;
    row.last_activity_at_ms += 30_000;
    row.heartbeat_age_ms = 0;
    row.activity_age_ms = 0;
  }
  assert.deepEqual(recoverySoakReasons({
    gatewayInitial: gateway,
    gatewaySamples: [gateway, gateway],
    poolzInitial: operatorInitial,
    poolzSamples: [operatorInitial, advanced1],
    providerInitial,
    providerSamples: [
      [provider({ uptime_s: 1_015, observation_id: 'observation-b' })],
      [provider({ uptime_s: 1_030, observation_id: 'observation-c' })],
    ],
  }, { minReadyProviders: 2, maxHeartbeatAgeMs: 90_000 }), []);

  const regressed = structuredClone(operatorInitial);
  for (const row of regressed) row.last_heartbeat_at_ms -= 1;
  assert.ok(recoverySoakReasons({
    gatewayInitial: gateway,
    gatewaySamples: [gateway, gateway],
    poolzInitial: operatorInitial,
    poolzSamples: [regressed, advanced1],
  }, { minReadyProviders: 2, maxHeartbeatAgeMs: 90_000 })
    .some((reason) => reason.includes('heartbeat_regressed')));

  const advancedBeforeRecovery = structuredClone(advanced1);
  assert.ok(recoverySoakReasons({
    gatewayInitial: gateway,
    gatewaySamples: [gateway, gateway],
    poolzInitial: operatorInitial,
    poolzSamples: [advancedBeforeRecovery, structuredClone(advancedBeforeRecovery)],
  }, { minReadyProviders: 2, maxHeartbeatAgeMs: 90_000 })
    .some((reason) => reason.includes('heartbeat_did_not_advance')));
});
