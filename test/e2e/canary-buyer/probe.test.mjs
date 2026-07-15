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
    authority: 'issue-585-integration-r4',
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
  ).includes('provider-a:provider_signal_missing'));

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
