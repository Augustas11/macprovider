import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  degradedReasons,
  directInvocationDecision,
  observerFailureClass,
  outcomeBucket,
  pollPostRequestRecovery,
  preconditionReasons,
  recoveryCadenceReasons,
  recoverySoakObservationReasons,
  safetyObservationReasons,
  shouldRunRecovery,
  streamOne,
  validateLegacyRollbackAuthorization,
} from './probe.mjs';
import { gatewaySnapshot, poolzSnapshot, providerSignalSnapshot } from './safety.mjs';

function safetyProvider(providerID, modelID, sessionID, overrides = {}) {
  return providerSignalSnapshot({ safety_telemetry: {
    schema_version: 2, provider_id: providerID, model_id: modelID, model_loaded: true,
    hardware_tier: '8GB', runtime_state: 'ready', coordinator_connected: true,
    coordinator_session_id: sessionID, cpu_utilization_pct: 10, gpu_utilization_pct: 15,
    gpu_utilization_scope: 'host', power_source: 'external', binary_version: '1.8.33',
    compatibility_set_id: 'set-a',
    model_hash: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    restart_count: 1, uptime_s: 1_000, memory_rss_mb: 2_000, memory_capacity_mb: 8_192,
    memory_pressure: 'normal', thermally_throttled: false, thermal_state: 'nominal',
    requests_in_flight: 0, requests_queued: 0, observation_id: `${providerID}-observation`,
    observed_at: new Date().toISOString(), valid_for_ms: 90_000, ...overrides,
  } }, providerID);
}

function healthyModel(overrides = {}) {
  return {
    model: 'model-a',
    serviceable: 1,
    ttft_ms: { p95: 5000, n: 12 },
    decode_tps: { p50: 30, n: 3 },
    cached_prompt_ratio: 0.7,
    outcomes: { '2xx': 17 },
    ...overrides,
  };
}

test('healthy buyer run passes the deploy gate', () => {
  assert.deepEqual(degradedReasons({ up: 1, models: [healthyModel()] }), []);
});

test('scheduled liveness requires only one bounded serviceability sample', () => {
  const model = healthyModel({
    ttft_ms: { p95: 500, n: 1 },
    decode_tps: { p50: null, n: 0 },
    cached_prompt_ratio: null,
    outcomes: { '2xx': 1 },
  });
  assert.deepEqual(degradedReasons({ mode: 'liveness', up: 1, models: [model] }), []);
});

test('explicit safety abort classification always fails the run', () => {
  const run = {
    mode: 'liveness', up: 1, models: [healthyModel({ ttft_ms: { p95: 500, n: 1 } })],
    result: { outcome: 'aborted', failure_class: 'heartbeat_regression' },
  };
  assert.deepEqual(degradedReasons(run), ['canary:heartbeat_regression']);
});

test('availability and empty-pool failures are explicit', () => {
  assert.deepEqual(degradedReasons({ up: 0, models: [] }), ['gateway_down']);
  assert.deepEqual(degradedReasons({ up: 1, models: [] }), ['no_models_probed']);
  assert.deepEqual(
    degradedReasons({ up: 1, models: [healthyModel({ serviceable: 0 })] }),
    ['model-a:unserviceable']
  );
});

test('TTFT, TPS, cache, and missing signals fail the deploy gate', () => {
  const run = {
    up: 1,
    models: [
      healthyModel({ model: 'slow', ttft_ms: { p95: 7001, n: 12 } }),
      healthyModel({ model: 'cold', decode_tps: { p50: 14.9, n: 3 } }),
      healthyModel({ model: 'uncached', cached_prompt_ratio: 0.09 }),
      healthyModel({ model: 'dark', ttft_ms: { p95: null, n: 0 }, decode_tps: { p50: null, n: 0 }, cached_prompt_ratio: null }),
    ],
  };
  assert.deepEqual(degradedReasons(run), [
    'slow:ttft_p95_7001ms_gt_7000ms',
    'cold:decode_tps_p50_14.9_lt_15',
    'uncached:cache_ratio_0.09_lt_0.1',
    'dark:ttft_signal_missing',
    'dark:decode_tps_signal_missing',
    'dark:cache_signal_missing',
  ]);
});

test('partial success cannot pass the deploy gate', () => {
  const run = {
    up: 1,
    models: [healthyModel({
      ttft_ms: { p95: 5000, n: 1 },
      decode_tps: { p50: 30, n: 1 },
      outcomes: { '2xx': 4, '5xx': 13 },
    })],
  };
  assert.deepEqual(degradedReasons(run), [
    'model-a:failed_requests_13_gt_0',
    'model-a:ttft_samples_1_lt_12',
    'model-a:decode_tps_samples_1_lt_3',
  ]);
});

test('threshold overrides are honored', () => {
  const run = { up: 1, models: [healthyModel()] };
  assert.deepEqual(degradedReasons(run, {
    maxTtftP95Ms: 4000,
    minDecodeTpsP50: 40,
    minCachedPromptRatio: 0.8,
  }), [
    'model-a:ttft_p95_5000ms_gt_4000ms',
    'model-a:decode_tps_p50_30_lt_40',
    'model-a:cache_ratio_0.7_lt_0.8',
  ]);
});

test('symlinked direct invocation still runs the probe', () => {
  const work = mkdtempSync(join(tmpdir(), 'canary-probe-symlink-'));
  try {
    const link = join(work, 'probe-link.mjs');
    symlinkSync(fileURLToPath(new URL('./probe.mjs', import.meta.url)), link);
    const env = { ...process.env };
    delete env.MACPROVIDER_BUYER_TOKEN;
    delete env.MALIBU_API_KEY;
    const result = spawnSync(process.execPath, [link], { encoding: 'utf8', env });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /liveness requires/);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test('unresolvable executable path fails closed', () => {
  assert.throws(
    () => directInvocationDecision('/removed/probe.mjs', '/opt/probe.mjs', () => {
      throw new Error('ENOENT');
    }),
    /ENOENT/
  );
});

test('malformed and oversized sample configuration fails before probing', () => {
  for (const [name, value] of [
    ['CANARY_TTFT_SAMPLES', '1oops'],
    ['CANARY_TPS_SAMPLES', '1.5'],
    ['CANARY_TTFT_SAMPLES', '21'],
    ['CANARY_TPS_SAMPLES', '9223372036854775808'],
  ]) {
    const env = {
      ...process.env,
      MACPROVIDER_BUYER_TOKEN: 'mp_test_token_not_secret',
      [name]: value,
    };
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('./probe.mjs', import.meta.url))], {
      encoding: 'utf8',
      env,
    });
    assert.equal(result.status, 1, `${name}=${value}`);
    assert.match(result.stderr, /must be an integer between/);
  }
});

test('qualification refuses to start without technical isolation and safety observers', () => {
  const env = {
    ...process.env,
    MACPROVIDER_BUYER_TOKEN: 'mp_test_token_not_secret',
  };
  const result = spawnSync(process.execPath, [
    fileURLToPath(new URL('./probe.mjs', import.meta.url)),
    '--mode', 'qualification',
  ], { encoding: 'utf8', env });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /qualification requires CANARY_POOLZ_URL/);
  assert.match(result.stderr, /CANARY_ISOLATED_PROVIDER_BASE/);
});

test('401 and 403 are classified as authentication errors, never generic failures', () => {
  assert.equal(outcomeBucket({ ok: false, status: 401 }), 'authentication_error');
  assert.equal(outcomeBucket({ ok: false, status: 403 }), 'authentication_error');
  assert.equal(outcomeBucket({ ok: false, status: 400 }), 'other');
  assert.equal(observerFailureClass('CANARY_POOLZ_URL HTTP 401: denied'), 'authentication_failure');
  assert.equal(observerFailureClass('/v1/status HTTP 403: denied'), 'authentication_failure');
  assert.equal(observerFailureClass('network reset'), 'safety_observer_failure');
  assert.equal(observerFailureClass('HTTP 401', 'time_budget_exhausted'), 'budget_exhausted');
  assert.equal(shouldRunRecovery(1), true, 'one failed attempted request still requires recovery observation');
  assert.equal(shouldRunRecovery(0), false, 'precondition failure with no attempted load does not require a soak');
});

test('recovery polling has heartbeat phase margin and room for two observations', () => {
  assert.deepEqual(recoveryCadenceReasons(45, 7_000), []);
  assert.deepEqual(recoveryCadenceReasons(45, 30_000), [
    'recovery_poll_not_faster_than_heartbeat',
    'recovery_soak_cannot_fit_two_observations',
    'recovery_soak_cannot_observe_heartbeat_advance',
  ]);
  assert.deepEqual(recoveryCadenceReasons(10, 7_000), [
    'recovery_soak_cannot_fit_two_observations',
    'recovery_soak_cannot_observe_heartbeat_advance',
  ]);
  assert.deepEqual(recoveryCadenceReasons(37, 7_000), [
    'recovery_soak_cannot_observe_heartbeat_advance',
  ]);
});

test('an adaptive safety abort cancels an in-flight stream', async () => {
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async (_url, options) => new Promise((_resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true });
    });
    const abort = new AbortController();
    const pending = streamOne({
      model: 'model-a', messages: [{ role: 'user', content: 'ready' }], maxTokens: 8,
      timeoutMs: 1_000, abortSignal: abort.signal,
    });
    abort.abort();
    const result = await pending;
    assert.equal(result.ok, false);
    assert.equal(result.kind, 'safety_abort');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('active-request safety correlates exact busy pool row, dropped gateway model, and provider load', () => {
  const now = Date.now();
  const stamp = (offset) => new Date(now + offset).toISOString();
  const expectedFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ];
  const gateway = gatewaySnapshot({
    status: 'up', degraded: false, coordinator: { status: 'up', checked_at: stamp(0) },
    pool: { total_providers: 2, ready: 2, degraded: 0, draining: 0, unavailable: 0 },
    models: expectedFleet.map(({ model_id }) => ({
      id: model_id, provider_count: 1, ready_provider_count: 1, slots_free: 1,
      available: true, availability: 'available', degraded: false,
    })),
  });
  const operatorPool = poolzSnapshot({ pool: expectedFleet.map(({ provider_id, model_id }, index) => ({
    provider_id, assigned_id: `session-${index}`, model_id, state: 'ready', routing_eligible: true,
    connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
  })) }, now);
  const providers = [
    safetyProvider('provider-a', 'model-a', 'session-0'),
    safetyProvider('provider-b', 'model-b', 'session-1'),
  ];
  const initial = { gateway, operator_pool: operatorPool, providers };
  const observed = structuredClone(initial);
  observed.operator_pool[0].state = 'busy';
  observed.operator_pool[0].routing_eligible = false;
  observed.providers[0].status = 'busy';
  observed.providers[0].requests_in_flight = 1;
  observed.gateway.status = 'degraded';
  observed.gateway.degraded = true;
  observed.gateway.pool.total_providers = 1;
  observed.gateway.pool.ready = 1;
  observed.gateway.models = observed.gateway.models.filter((model) => model.id !== 'model-a');

  assert.ok(safetyObservationReasons(initial, observed, expectedFleet).length > 0);
  assert.deepEqual(safetyObservationReasons(initial, observed, expectedFleet, {
    activeModelID: 'model-a',
  }), []);

  const recoveredWithCachedGateway = structuredClone(observed);
  recoveredWithCachedGateway.operator_pool[0].state = 'ready';
  recoveredWithCachedGateway.operator_pool[0].routing_eligible = true;
  recoveredWithCachedGateway.providers[0].status = 'ready';
  recoveredWithCachedGateway.providers[0].requests_in_flight = 0;
  assert.ok(safetyObservationReasons(initial, recoveredWithCachedGateway, expectedFleet, {
    activeModelID: 'model-a',
  }).length > 0);
  assert.deepEqual(safetyObservationReasons(initial, recoveredWithCachedGateway, expectedFleet, {
    activeModelID: 'model-a', cachedGatewayModelID: 'model-a',
  }), []);
});

test('active-request safety accepts unchanged gateway counts while provider is busy', () => {
  const now = Date.now();
  const stamp = (offset) => new Date(now + offset).toISOString();
  const expectedFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ];
  const gateway = gatewaySnapshot({
    status: 'up', degraded: false, coordinator: { status: 'up', checked_at: stamp(0) },
    pool: { total_providers: 2, ready: 2, degraded: 0, draining: 0, unavailable: 0 },
    models: expectedFleet.map(({ model_id }) => ({
      id: model_id, provider_count: 1, ready_provider_count: 1, slots_free: 1,
      available: true, availability: 'available', degraded: false,
    })),
  });
  const operatorPool = poolzSnapshot({ pool: expectedFleet.map(({ provider_id, model_id }, index) => ({
    provider_id, assigned_id: `session-${index}`, model_id, state: 'ready', routing_eligible: true,
    connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
  })) }, now);
  const providers = [
    safetyProvider('provider-a', 'model-a', 'session-0'),
    safetyProvider('provider-b', 'model-b', 'session-1'),
  ];
  const initial = { gateway, operator_pool: operatorPool, providers };
  const observed = structuredClone(initial);
  observed.operator_pool[0].state = 'busy';
  observed.operator_pool[0].routing_eligible = false;
  observed.providers[0].status = 'busy';
  observed.providers[0].requests_in_flight = 1;

  assert.ok(safetyObservationReasons(initial, observed, expectedFleet).length > 0);
  assert.deepEqual(safetyObservationReasons(initial, observed, expectedFleet, {
    activeModelID: 'model-a',
  }), []);
});

test('active-request safety accepts a non-first duplicate-model provider without dropping the model', () => {
  const now = Date.now();
  const stamp = (offset) => new Date(now + offset).toISOString();
  const expectedFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
    { provider_id: 'provider-c', model_id: 'model-b' },
  ];
  const gateway = gatewaySnapshot({
    status: 'up', degraded: false, coordinator: { status: 'up', checked_at: stamp(0) },
    pool: { total_providers: 3, ready: 3, degraded: 0, draining: 0, unavailable: 0 },
    models: [
      { id: 'model-a', provider_count: 1, ready_provider_count: 1, slots_free: 1, available: true, availability: 'available', degraded: false },
      { id: 'model-b', provider_count: 2, ready_provider_count: 2, slots_free: 2, available: true, availability: 'available', degraded: false },
    ],
  });
  const operatorPool = poolzSnapshot({ pool: expectedFleet.map(({ provider_id, model_id }, index) => ({
    provider_id, assigned_id: `session-${index}`, model_id, state: 'ready', routing_eligible: true,
    connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
  })) }, now);
  const providers = [
    safetyProvider('provider-a', 'model-a', 'session-0'),
    safetyProvider('provider-b', 'model-b', 'session-1'),
    safetyProvider('provider-c', 'model-b', 'session-2'),
  ];
  const initial = { gateway, operator_pool: operatorPool, providers };
  const observed = structuredClone(initial);
  observed.operator_pool[2].state = 'busy';
  observed.operator_pool[2].routing_eligible = false;
  observed.providers[2].status = 'busy';
  observed.providers[2].requests_in_flight = 1;
  observed.gateway.pool.total_providers = 2;
  observed.gateway.pool.ready = 2;
  observed.gateway.models[1].ready_provider_count = 1;
  observed.gateway.models[1].slots_free = 1;

  assert.ok(safetyObservationReasons(initial, observed, expectedFleet).length > 0);
  assert.deepEqual(safetyObservationReasons(initial, observed, expectedFleet, {
    activeModelID: 'model-b',
  }), []);

  const droppedDuplicateModel = structuredClone(observed);
  droppedDuplicateModel.gateway.models = droppedDuplicateModel.gateway.models.filter((model) => model.id !== 'model-b');
  assert.ok(safetyObservationReasons(initial, droppedDuplicateModel, expectedFleet, {
    activeModelID: 'model-b',
  }).includes('model-b:model_disappeared'));
});

test('liveness substitutes missing v2 signals only for exact legacy-bridge provider rows', () => {
  const now = Date.now();
  const stamp = (offset) => new Date(now + offset).toISOString();
  const expectedFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ];
  const gateway = gatewaySnapshot({
    status: 'up', degraded: false, coordinator: { status: 'up', checked_at: stamp(0) },
    pool: { total_providers: 2, ready: 2, degraded: 0, draining: 0, unavailable: 0 },
    models: expectedFleet.map(({ model_id }) => ({
      id: model_id, provider_count: 1, ready_provider_count: 1, slots_free: 1,
      available: true, availability: 'available', degraded: false,
    })),
  });
  const operatorPool = poolzSnapshot({ pool: expectedFleet.map(({ provider_id, model_id }, index) => ({
    provider_id, assigned_id: `session-${index}`, model_id, state: 'ready', routing_eligible: true,
    binary_version: '1.8.30', catalog_admission_mode: 'legacy_bridge',
    connected_at: stamp(-60_000), last_heartbeat_at: stamp(-1_000), last_activity_at: stamp(-500),
  })) }, now);
  const providers = operatorPool.map((row) => row.safety_telemetry);
  const initial = { gateway, operator_pool: operatorPool, providers };
  const observed = structuredClone(initial);

  assert.ok(safetyObservationReasons(initial, observed, expectedFleet)
    .includes('provider-a:provider_signal_missing'));
  assert.deepEqual(safetyObservationReasons(initial, observed, expectedFleet, {
    allowLegacyBridgeProviderSignals: true,
  }), []);
  assert.deepEqual(preconditionReasons(initial, expectedFleet, null, true), []);
  assert.ok(preconditionReasons(initial, expectedFleet, null)
    .includes('provider-a:provider_signal_missing'));

  const recoveryOne = structuredClone(initial);
  const recoveryTwo = structuredClone(initial);
  for (const [index, sample] of [recoveryOne, recoveryTwo].entries()) {
    for (const row of sample.operator_pool) {
      row.last_heartbeat_at_ms += (index + 1) * 30_000;
      row.last_activity_at_ms += (index + 1) * 30_000;
      row.heartbeat_age_ms = 0;
      row.activity_age_ms = 0;
    }
  }
  assert.deepEqual(recoverySoakObservationReasons(
    initial,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    null,
    {
      minReadyProviders: 2,
      maxHeartbeatAgeMs: 90_000,
      allowLegacyBridgeProviderSignals: true,
    },
    now,
  ), []);
  assert.ok(recoverySoakObservationReasons(
    initial,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    null,
    { minReadyProviders: 2, maxHeartbeatAgeMs: 90_000 },
    now,
  ).some((reason) => reason.includes('telemetry_')));

  for (const [field, value] of [
    ['catalog_admission_mode', 'current'],
    ['catalog_admission_mode', 'previous'],
    ['catalog_admission_mode', null],
    ['binary_version', null],
    ['binary_version', 'not-semver'],
    ['model_id', 'wrong-model'],
  ]) {
    const rejected = structuredClone(observed);
    rejected.operator_pool[0][field] = value;
    assert.ok(safetyObservationReasons(initial, rejected, expectedFleet, {
      allowLegacyBridgeProviderSignals: true,
    }).includes('provider-a:provider_signal_missing'), `${field}=${value} must fail closed`);
  }
});

test('legacy rollback authorization is exact, expiring, and limited to unclassified prior rows', () => {
  const now = Date.parse('2026-07-15T07:00:00Z');
  const expectedFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ];
  const document = {
    schema_version: 1,
    kind: 'legacy_rollback',
    authority: 'issue-825-canary-fleet-r5',
    transaction_id: 'a'.repeat(64),
    expires_at: new Date(now + 300_000).toISOString(),
    providers: expectedFleet.map((row) => ({ ...row, binary_version: '1.8.30' })),
  };
  const authorized = validateLegacyRollbackAuthorization(document, expectedFleet, now);
  assert.equal(authorized.get('provider-a').binary_version, '1.8.30');

  const gateway = gatewaySnapshot({
    status: 'up', degraded: false, coordinator: { status: 'up', checked_at: new Date(now).toISOString() },
    pool: { total_providers: 2, ready: 2, degraded: 0, draining: 0, unavailable: 0 },
    models: expectedFleet.map(({ model_id }) => ({
      id: model_id, provider_count: 1, ready_provider_count: 1, slots_free: 1,
      available: true, availability: 'available', degraded: false,
    })),
  });
  const operatorPool = poolzSnapshot({ pool: expectedFleet.map(({ provider_id, model_id }, index) => ({
    provider_id, assigned_id: `session-${index}`, model_id, state: 'ready', routing_eligible: true,
    binary_version: '1.8.30', connected_at: new Date(now - 60_000).toISOString(),
    last_heartbeat_at: new Date(now - 1_000).toISOString(),
  })) }, now);
  const observation = {
    gateway,
    operator_pool: operatorPool,
    providers: operatorPool.map((row) => row.safety_telemetry),
  };
  assert.deepEqual(safetyObservationReasons(observation, observation, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
  }), []);

  assert.deepEqual(safetyObservationReasons(observation, observation, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now + 299_999,
  }), []);
  assert.ok(safetyObservationReasons(observation, observation, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now + 300_000,
  }).includes('provider-a:provider_signal_missing'));

  const activeRequest = structuredClone(observation);
  activeRequest.operator_pool[0].state = 'busy';
  activeRequest.operator_pool[0].routing_eligible = false;
  activeRequest.gateway.status = 'degraded';
  activeRequest.gateway.degraded = true;
  activeRequest.gateway.pool.total_providers = 1;
  activeRequest.gateway.pool.ready = 1;
  activeRequest.gateway.models = activeRequest.gateway.models.filter(
    (model) => model.id !== 'model-a',
  );
  assert.deepEqual(safetyObservationReasons(observation, activeRequest, expectedFleet, {
    activeModelID: 'model-a',
    legacyRollbackProviders: authorized,
    nowMs: now,
  }), []);
  assert.ok(safetyObservationReasons(observation, activeRequest, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
  }).includes('provider-a:provider_signal_missing'));

  const recoveryOne = structuredClone(observation);
  const recoveryTwo = structuredClone(observation);
  for (const [index, sample] of [recoveryOne, recoveryTwo].entries()) {
    for (const row of sample.operator_pool) {
      row.last_heartbeat_at_ms += (index + 1) * 30_000;
      row.last_activity_at_ms += (index + 1) * 30_000;
      row.heartbeat_age_ms = 0;
      row.activity_age_ms = 0;
    }
  }
  const soakOptions = { minReadyProviders: 2, maxHeartbeatAgeMs: 90_000 };
  assert.deepEqual(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    authorized,
    soakOptions,
    now,
  ), []);
  assert.ok(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    null,
    soakOptions,
    now,
  ).some((reason) => reason.includes('telemetry_')));
  assert.ok(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    authorized,
    soakOptions,
    now + 300_000,
  ).some((reason) => reason.includes('telemetry_')));

  const malformedDirectSignal = structuredClone(observation);
  malformedDirectSignal.providers[0].schema_version = 1;
  assert.ok(safetyObservationReasons(
    observation,
    malformedDirectSignal,
    expectedFleet,
    { legacyRollbackProviders: authorized, nowMs: now },
  ).some((reason) => reason.startsWith('provider-a:')));

  const replacementSession = structuredClone(observation);
  replacementSession.operator_pool[0].assigned_id = 'replacement-session';
  assert.ok(safetyObservationReasons(
    observation,
    replacementSession,
    expectedFleet,
    { legacyRollbackProviders: authorized, nowMs: now },
  ).includes('provider-a:session_changed'));

  for (const [field, value] of [
    ['assigned_id', null],
    ['assigned_id', ''],
    ['connected_at_ms', null],
    ['routing_eligible', null],
    ['routing_eligible', false],
    ['catalog_admission_mode', 'legacy_bridge'],
    ['catalog_admission_mode', 'current'],
    ['binary_version', '1.8.31'],
    ['model_id', 'wrong-model'],
  ]) {
    const rejected = structuredClone(observation);
    rejected.operator_pool[0][field] = value;
    assert.ok(safetyObservationReasons(observation, rejected, expectedFleet, {
      legacyRollbackProviders: authorized,
      nowMs: now,
    }).includes('provider-a:provider_signal_missing'));
  }

  for (const invalid of [
    { ...document, expires_at: new Date(now).toISOString() },
    { ...document, expires_at: new Date(now + (16 * 60_000)).toISOString() },
    { ...document, authority: 'issue-585-integration-r3' },
    { ...document, providers: document.providers.slice(1) },
  ]) {
    assert.throws(() => validateLegacyRollbackAuthorization(invalid, expectedFleet, now));
  }
});

test('legacy rollback recovery requires heartbeat advance only from exercised providers', () => {
  const now = Date.parse('2026-08-01T10:21:58Z');
  const expectedFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
    { provider_id: 'provider-c', model_id: 'model-b' },
  ];
  const document = {
    schema_version: 1,
    kind: 'legacy_rollback',
    authority: 'issue-825-canary-fleet-r5',
    transaction_id: 'b'.repeat(64),
    expires_at: new Date(now + 300_000).toISOString(),
    providers: expectedFleet.map((row) => ({ ...row, binary_version: '1.8.30' })),
  };
  const authorized = validateLegacyRollbackAuthorization(document, expectedFleet, now);
  const gateway = gatewaySnapshot({
    status: 'up',
    degraded: false,
    coordinator: { status: 'up', checked_at: new Date(now).toISOString() },
    pool: { total_providers: 3, ready: 3, degraded: 0, draining: 0, unavailable: 0 },
    models: [
      { id: 'model-a', provider_count: 1, ready_provider_count: 1, slots_free: 1, available: true, availability: 'available', degraded: false },
      { id: 'model-b', provider_count: 2, ready_provider_count: 2, slots_free: 2, available: true, availability: 'available', degraded: false },
    ],
  });
  const operatorPool = poolzSnapshot({ pool: expectedFleet.map(({ provider_id, model_id }, index) => ({
    provider_id,
    assigned_id: `session-${index}`,
    model_id,
    state: 'ready',
    routing_eligible: true,
    binary_version: '1.8.30',
    connected_at: new Date(now - 60_000).toISOString(),
    last_heartbeat_at: new Date(now - 1_000).toISOString(),
    last_activity_at: new Date(now - 1_000).toISOString(),
  })) }, now);
  const providers = expectedFleet.map(({ provider_id, model_id }, index) => safetyProvider(
    provider_id,
    model_id,
    `session-${index}`,
    {
      binary_version: '1.8.30',
      observation_id: `${provider_id}-initial`,
      observed_at: new Date().toISOString(),
    },
  ));
  const observation = { gateway, operator_pool: operatorPool, providers };
  const recoveryOne = structuredClone(observation);
  const recoveryTwo = structuredClone(observation);
  const exercisedProviderIDs = new Set(['provider-a', 'provider-b']);

  for (const [index, sample] of [recoveryOne, recoveryTwo].entries()) {
    for (const row of sample.operator_pool) {
      if (exercisedProviderIDs.has(row.provider_id)) {
        row.last_heartbeat_at_ms += (index + 1) * 30_000;
        row.last_activity_at_ms += (index + 1) * 30_000;
      }
      row.heartbeat_age_ms = 0;
      row.activity_age_ms = 0;
    }
    for (const provider of sample.providers) {
      if (exercisedProviderIDs.has(provider.provider_id)) {
        provider.observation_id = `${provider.provider_id}-sample-${index + 1}`;
        provider.observed_at_ms += (index + 1) * 30_000;
      }
      provider.observation_age_ms = 0;
    }
  }

  const scopedAdvance = {
    minReadyProviders: 3,
    maxHeartbeatAgeMs: 90_000,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  };
  assert.deepEqual(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    authorized,
    scopedAdvance,
    now,
  ), []);
  assert.deepEqual(safetyObservationReasons(observation, recoveryTwo, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }), []);
  assert.ok(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    authorized,
    { minReadyProviders: 3, maxHeartbeatAgeMs: 90_000 },
    now,
  ).some((reason) => reason.includes('provider-c')));
  assert.ok(safetyObservationReasons(observation, recoveryTwo, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
  }).some((reason) => reason.includes('provider-c')));
});

test('legacy rollback recovery tolerates only unexercised duplicate provider readiness loss', () => {
  const now = Date.parse('2026-08-01T10:53:42Z');
  const expectedFleet = [
    { provider_id: 'provider-a', model_id: 'model-a' },
    { provider_id: 'provider-b', model_id: 'model-b' },
    { provider_id: 'provider-c', model_id: 'model-b' },
  ];
  const document = {
    schema_version: 1,
    kind: 'legacy_rollback',
    authority: 'issue-825-canary-fleet-r5',
    transaction_id: 'c'.repeat(64),
    expires_at: new Date(now + 300_000).toISOString(),
    providers: expectedFleet.map((row) => ({ ...row, binary_version: '1.8.30' })),
  };
  const authorized = validateLegacyRollbackAuthorization(document, expectedFleet, now);
  const gateway = gatewaySnapshot({
    status: 'up',
    degraded: false,
    coordinator: { status: 'up', checked_at: new Date(now).toISOString() },
    pool: { total_providers: 3, ready: 3, degraded: 0, draining: 0, unavailable: 0 },
    models: [
      { id: 'model-a', provider_count: 1, ready_provider_count: 1, slots_free: 1, available: true, availability: 'available', degraded: false },
      { id: 'model-b', provider_count: 2, ready_provider_count: 2, slots_free: 2, available: true, availability: 'available', degraded: false },
    ],
  });
  const operatorPool = poolzSnapshot({ pool: expectedFleet.map(({ provider_id, model_id }, index) => ({
    provider_id,
    assigned_id: `session-${index}`,
    model_id,
    state: 'ready',
    routing_eligible: true,
    binary_version: '1.8.30',
    connected_at: new Date(now - 60_000).toISOString(),
    last_heartbeat_at: new Date(now - 1_000).toISOString(),
    last_activity_at: new Date(now - 1_000).toISOString(),
  })) }, now);
  const providers = expectedFleet.map(({ provider_id, model_id }, index) => safetyProvider(
    provider_id,
    model_id,
    `session-${index}`,
    {
      binary_version: '1.8.30',
      observation_id: `${provider_id}-initial`,
      observed_at: new Date(now - 1_000).toISOString(),
    },
  ));
  const observation = { gateway, operator_pool: operatorPool, providers };
  const exercisedProviderIDs = new Set(['provider-a', 'provider-b']);
  const recoveryOne = structuredClone(observation);
  const recoveryTwo = structuredClone(observation);
  for (const [index, sample] of [recoveryOne, recoveryTwo].entries()) {
    for (const row of sample.operator_pool) {
      if (exercisedProviderIDs.has(row.provider_id)) {
        row.last_heartbeat_at_ms += (index + 1) * 30_000;
        row.last_activity_at_ms += (index + 1) * 30_000;
      }
      row.heartbeat_age_ms = 0;
      row.activity_age_ms = 0;
    }
    for (const provider of sample.providers) {
      if (exercisedProviderIDs.has(provider.provider_id)) {
        provider.observation_id = `${provider.provider_id}-sample-${index + 1}`;
        provider.observed_at_ms += (index + 1) * 30_000;
      }
      provider.observation_age_ms = 0;
    }
  }
  recoveryTwo.gateway.pool.ready = 2;
  recoveryTwo.gateway.pool.unavailable = 1;
  recoveryTwo.gateway.models[1].ready_provider_count = 1;
  const droppedDuplicate = recoveryTwo.operator_pool.find((row) => row.provider_id === 'provider-c');
  droppedDuplicate.state = 'unavailable';
  droppedDuplicate.routing_eligible = false;
  droppedDuplicate.heartbeat_age_ms = 120_000;

  const scopedAdvance = {
    minReadyProviders: 3,
    maxHeartbeatAgeMs: 90_000,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  };
  assert.deepEqual(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    authorized,
    scopedAdvance,
    now,
  ), []);
  assert.deepEqual(safetyObservationReasons(observation, recoveryTwo, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }), []);
  assert.ok(safetyObservationReasons(observation, recoveryTwo, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
  }).map((reason) => `recovery_soak:${reason}`).some((reason) => reason.includes('provider-c')));
  assert.deepEqual(safetyObservationReasons(observation, recoveryTwo, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }).map((reason) => `recovery_soak:${reason}`), []);

  assert.ok(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    authorized,
    { ...scopedAdvance, heartbeatAdvanceProviderIDs: new Set(['provider-a', 'provider-b', 'provider-c']) },
    now,
  ).some((reason) => reason.includes('provider-c')));
  assert.ok(recoverySoakObservationReasons(
    observation,
    [recoveryOne, recoveryTwo],
    expectedFleet,
    null,
    scopedAdvance,
    now,
  ).some((reason) => reason.includes('provider-c')));

  const missingDuplicate = structuredClone(recoveryTwo);
  missingDuplicate.gateway.pool.total_providers = 2;
  missingDuplicate.gateway.pool.unavailable = 0;
  missingDuplicate.operator_pool = missingDuplicate.operator_pool.filter((row) => row.provider_id !== 'provider-c');
  missingDuplicate.providers = missingDuplicate.providers.filter((provider) => provider.provider_id !== 'provider-c');
  assert.deepEqual(recoverySoakObservationReasons(
    observation,
    [recoveryOne, missingDuplicate],
    expectedFleet,
    authorized,
    scopedAdvance,
    now,
  ), []);
  assert.deepEqual(safetyObservationReasons(observation, missingDuplicate, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }), []);
  assert.ok(recoverySoakObservationReasons(
    observation,
    [recoveryOne, missingDuplicate],
    expectedFleet,
    null,
    scopedAdvance,
    now,
  ).some((reason) => reason.includes('provider-c')));

  const uniqueLoss = structuredClone(recoveryTwo);
  const providerA = uniqueLoss.operator_pool.find((row) => row.provider_id === 'provider-a');
  providerA.state = 'unavailable';
  providerA.routing_eligible = false;
  uniqueLoss.gateway.models[0].available = false;
  uniqueLoss.gateway.models[0].degraded = true;
  uniqueLoss.gateway.models[0].ready_provider_count = 0;
  assert.ok(safetyObservationReasons(observation, uniqueLoss, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }).some((reason) => reason.includes('provider-a')));

  const currentCatalogMode = structuredClone(recoveryTwo);
  currentCatalogMode.operator_pool.find((row) => row.provider_id === 'provider-c').catalog_admission_mode = 'current';
  assert.ok(safetyObservationReasons(observation, currentCatalogMode, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }).some((reason) => reason.includes('provider-c')));

  const wrongProviderSignal = structuredClone(recoveryTwo);
  const duplicateSignalIndex = wrongProviderSignal.providers.findIndex((provider) => provider.provider_id === 'provider-c');
  wrongProviderSignal.providers[duplicateSignalIndex].provider_id = 'wrong-provider';
  assert.ok(safetyObservationReasons(observation, wrongProviderSignal, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }).some((reason) => reason.includes('provider-c:provider_signal_identity_mismatch_wrong-provider')));
  const missingProviderIDSignal = structuredClone(recoveryTwo);
  const missingProviderIDSignalIndex = missingProviderIDSignal.providers.findIndex((provider) => provider.provider_id === 'provider-c');
  delete missingProviderIDSignal.providers[missingProviderIDSignalIndex].provider_id;
  assert.ok(safetyObservationReasons(observation, missingProviderIDSignal, expectedFleet, {
    legacyRollbackProviders: authorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: exercisedProviderIDs,
  }).some((reason) => reason.includes('provider-c:provider_signal_identity_mismatch_missing')));

  const substringExpectedFleet = [
    { provider_id: 'a', model_id: 'model-b' },
    { provider_id: 'provider-a', model_id: 'model-b' },
    { provider_id: 'provider-b', model_id: 'model-b' },
  ];
  const substringDocument = {
    ...document,
    providers: substringExpectedFleet.map((row) => ({ ...row, binary_version: '1.8.30' })),
  };
  const substringAuthorized = validateLegacyRollbackAuthorization(substringDocument, substringExpectedFleet, now);
  const substringInitial = {
    gateway: gatewaySnapshot({
      status: 'up',
      degraded: false,
      coordinator: { status: 'up', checked_at: new Date(now).toISOString() },
      pool: { total_providers: 3, ready: 3, degraded: 0, draining: 0, unavailable: 0 },
      models: [
        { id: 'model-b', provider_count: 3, ready_provider_count: 3, slots_free: 3, available: true, availability: 'available', degraded: false },
      ],
    }),
    operator_pool: poolzSnapshot({ pool: substringExpectedFleet.map(({ provider_id, model_id }, index) => ({
      provider_id,
      assigned_id: `substring-session-${index}`,
      model_id,
      state: 'ready',
      routing_eligible: true,
      binary_version: '1.8.30',
      connected_at: new Date(now - 60_000).toISOString(),
      last_heartbeat_at: new Date(now - 1_000).toISOString(),
      last_activity_at: new Date(now - 1_000).toISOString(),
    })) }, now),
    providers: substringExpectedFleet.map(({ provider_id, model_id }, index) => safetyProvider(
      provider_id,
      model_id,
      `substring-session-${index}`,
      {
        binary_version: '1.8.30',
        observation_id: `${provider_id}-initial`,
        observed_at: new Date(now - 1_000).toISOString(),
      },
    )),
  };
  const substringObserved = structuredClone(substringInitial);
  substringObserved.operator_pool.find((row) => row.provider_id === 'a').state = 'unavailable';
  substringObserved.operator_pool.find((row) => row.provider_id === 'a').routing_eligible = false;
  substringObserved.operator_pool.find((row) => row.provider_id === 'provider-a').state = 'unavailable';
  substringObserved.operator_pool.find((row) => row.provider_id === 'provider-a').routing_eligible = false;
  substringObserved.gateway.pool.ready = 1;
  substringObserved.gateway.pool.unavailable = 2;
  substringObserved.gateway.models[0].ready_provider_count = 1;
  assert.ok(safetyObservationReasons(substringInitial, substringObserved, substringExpectedFleet, {
    legacyRollbackProviders: substringAuthorized,
    nowMs: now,
    requireHeartbeatAdvance: true,
    heartbeatAdvanceProviderIDs: new Set(['provider-a', 'provider-b']),
  }).some((reason) => reason.includes('provider-a:expected_provider_not_ready')));
});

test('post-request recovery outlives the gateway active-loss cache window', async () => {
  let nowMs = 0;
  const observe = async () => ({ gatewayCacheActive: nowMs < 10_000 });
  const options = {
    observe,
    strictReasons: (observed) => observed.gatewayCacheActive ? ['model-a:model_disappeared'] : [],
    transientReasons: () => [],
    pollMs: 2_000,
    now: () => nowMs,
    wait: async (durationMs) => { nowMs += durationMs; },
  };
  const result = await pollPostRequestRecovery({ ...options, maxWaitMs: 17_000 });
  assert.deepEqual(result.reasons, []);
  assert.equal(nowMs, 10_000);

  nowMs = 0;
  const tooShort = await pollPostRequestRecovery({ ...options, maxWaitMs: 7_000 });
  assert.equal(tooShort.timedOut, true);
  assert.ok(tooShort.reasons.includes('post_request_heartbeat_recovery_timeout'));
});

test('a content-bearing stream without terminal DONE is a partial-stream failure', async () => {
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async () => new Response(
      'data: {"model":"model-a","choices":[{"delta":{"content":"ready"}}]}\n\n',
      { status: 200, headers: { 'content-type': 'text/event-stream', 'x-provider-id': 'provider-a' } }
    );
    const partial = await streamOne({
      model: 'model-a', messages: [{ role: 'user', content: 'ready' }], maxTokens: 8, timeoutMs: 1_000,
    });
    assert.equal(partial.ok, false);
    assert.equal(partial.kind, 'stream_error');
    assert.match(partial.error, /without terminal/);

    globalThis.fetch = async () => new Response(
      'data: {"model":"model-a","choices":[{"delta":{"content":"ready"}}]}\n\ndata: [DONE]\n\n',
      { status: 200, headers: { 'content-type': 'text/event-stream', 'x-provider-id': 'provider-a' } }
    );
    const complete = await streamOne({
      model: 'model-a', messages: [{ role: 'user', content: 'ready' }], maxTokens: 8, timeoutMs: 1_000,
    });
    assert.equal(complete.ok, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
