import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { degradedReasons, directInvocationDecision } from './probe.mjs';

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
    assert.match(result.stderr, /set MACPROVIDER_BUYER_TOKEN or MALIBU_API_KEY/);
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

test('qualification refuses to start without isolation and safety observers', () => {
  const env = {
    ...process.env,
    MACPROVIDER_BUYER_TOKEN: 'mp_test_token_not_secret',
  };
  const result = spawnSync(process.execPath, [
    fileURLToPath(new URL('./probe.mjs', import.meta.url)),
    '--mode', 'qualification',
  ], { encoding: 'utf8', env });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /qualification requires --capacity-isolated/);
});
