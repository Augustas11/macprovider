const READY_STATES = new Set(['ready']);
const THERMAL_PRESSURE_STATES = new Set(['serious', 'critical', 'thermal_pressure', 'thermal_throttled']);
const MEMORY_PRESSURE_STATES = new Set(['warning', 'critical', 'memory_pressure']);

export class RunBudget {
  constructor({ maxRequests, maxCompletionTokens, maxDurationMs, startedAtMs = Date.now() }) {
    for (const [name, value] of Object.entries({ maxRequests, maxCompletionTokens, maxDurationMs })) {
      if (!Number.isSafeInteger(value) || value < 1) {
        throw new Error(`${name} must be a positive safe integer`);
      }
    }
    this.limits = { maxRequests, maxCompletionTokens, maxDurationMs };
    this.startedAtMs = startedAtMs;
    this.requests = 0;
    this.completionTokensReserved = 0;
    this.providers = new Map();
  }

  reserve(maxTokens, nowMs = Date.now()) {
    if (!Number.isSafeInteger(maxTokens) || maxTokens < 1) {
      throw new Error('maxTokens must be a positive safe integer');
    }
    const elapsedMs = Math.max(0, nowMs - this.startedAtMs);
    if (elapsedMs >= this.limits.maxDurationMs) {
      return `time_budget_exhausted:${elapsedMs}ms_gte_${this.limits.maxDurationMs}ms`;
    }
    if (this.requests + 1 > this.limits.maxRequests) {
      return `request_budget_exhausted:${this.requests + 1}_gt_${this.limits.maxRequests}`;
    }
    if (this.completionTokensReserved + maxTokens > this.limits.maxCompletionTokens) {
      return `token_budget_exhausted:${this.completionTokensReserved + maxTokens}_gt_${this.limits.maxCompletionTokens}`;
    }
    this.requests++;
    this.completionTokensReserved += maxTokens;
    return null;
  }

  recordProvider(provider, maxTokens) {
    if (!provider) return;
    const current = this.providers.get(provider) || { requests: 0, completion_tokens_reserved: 0 };
    current.requests++;
    current.completion_tokens_reserved += maxTokens;
    this.providers.set(provider, current);
  }

  timeReason(nowMs = Date.now()) {
    const elapsedMs = Math.max(0, nowMs - this.startedAtMs);
    return elapsedMs >= this.limits.maxDurationMs
      ? `time_budget_exhausted:${elapsedMs}ms_gte_${this.limits.maxDurationMs}ms`
      : null;
  }

  remainingDurationMs(nowMs = Date.now()) {
    return Math.max(0, this.limits.maxDurationMs - Math.max(0, nowMs - this.startedAtMs));
  }

  snapshot(nowMs = Date.now()) {
    return {
      limits: {
        max_requests_per_provider: this.limits.maxRequests,
        max_completion_tokens_per_provider: this.limits.maxCompletionTokens,
        max_duration_ms: this.limits.maxDurationMs,
        enforcement: 'worst_case_global_route',
      },
      used: {
        requests: this.requests,
        completion_tokens_reserved: this.completionTokensReserved,
        elapsed_ms: Math.max(0, nowMs - this.startedAtMs),
        providers: Object.fromEntries([...this.providers.entries()].sort(([a], [b]) => a.localeCompare(b))),
      },
    };
  }
}

export function gatewaySnapshot(status) {
  const pool = status?.pool || {};
  const models = Array.isArray(status?.models) ? status.models : [];
  return {
    status: stringOrNull(status?.status),
    degraded: status?.degraded === true,
    coordinator_status: stringOrNull(status?.coordinator?.status),
    coordinator_checked_at: stringOrNull(status?.coordinator?.checked_at),
    pool: {
      total_providers: integerOrNull(pool.total_providers),
      ready: integerOrNull(pool.ready),
      degraded: integerOrNull(pool.degraded),
      draining: integerOrNull(pool.draining),
      unavailable: integerOrNull(pool.unavailable),
    },
    models: models.map((model) => ({
      id: stringOrNull(model?.id),
      provider_count: integerOrNull(model?.provider_count),
      ready_provider_count: integerOrNull(model?.ready_provider_count),
      slots_free: integerOrNull(model?.slots_free),
      available: model?.available === true,
      availability: stringOrNull(model?.availability),
      degraded: model?.degraded === true,
    })),
  };
}

export function gatewayInvariantReasons(initial, current, { minReadyProviders = 1 } = {}) {
  const before = initial?.pool ? initial : gatewaySnapshot(initial);
  const after = current?.pool ? current : gatewaySnapshot(current);
  const reasons = [];
  if (after.status !== 'up' || after.coordinator_status !== 'up') reasons.push('gateway_or_coordinator_not_up');
  if (after.degraded) reasons.push('gateway_degraded');
  if (!Number.isInteger(after.pool.total_providers) || !Number.isInteger(after.pool.ready)) {
    reasons.push('pool_signal_missing');
    return reasons;
  }
  if (after.pool.ready < minReadyProviders) reasons.push(`ready_${after.pool.ready}_lt_${minReadyProviders}`);
  for (const state of ['degraded', 'draining', 'unavailable']) {
    if (!Number.isInteger(after.pool[state])) reasons.push(`pool_${state}_signal_missing`);
    else if (after.pool[state] !== 0) reasons.push(`pool_${state}_${after.pool[state]}_ne_0`);
  }
  if (Number.isInteger(before?.pool?.total_providers) && after.pool.total_providers !== before.pool.total_providers) {
    reasons.push(`total_providers_changed_${before.pool.total_providers}_to_${after.pool.total_providers}`);
  }
  if (Number.isInteger(before?.pool?.ready) && after.pool.ready !== before.pool.ready) {
    reasons.push(`ready_changed_${before.pool.ready}_to_${after.pool.ready}`);
  }
  const beforeModels = new Map((before?.models || []).map((model) => [model.id, model]));
  const afterModels = new Map((after.models || []).map((model) => [model.id, model]));
  for (const [id, model] of beforeModels) {
    if (!id) continue;
    const observed = afterModels.get(id);
    if (!observed) {
      reasons.push(`${id}:model_disappeared`);
      continue;
    }
    if (!observed.available || observed.degraded) reasons.push(`${id}:model_not_stably_available`);
    if (Number.isInteger(model.ready_provider_count) && observed.ready_provider_count !== model.ready_provider_count) {
      reasons.push(`${id}:ready_provider_count_changed_${model.ready_provider_count}_to_${observed.ready_provider_count}`);
    }
  }
  return reasons;
}

export function poolzSnapshot(payload, nowMs = Date.now()) {
  const rows = Array.isArray(payload?.pool) ? payload.pool : [];
  return rows.map((row) => ({
    id: stringOrNull(row?.assigned_id) || stringOrNull(row?.provider_id),
    state: stringOrNull(row?.state),
    connected_at_ms: dateMsOrNull(row?.connected_at),
    last_heartbeat_at_ms: dateMsOrNull(row?.last_heartbeat_at),
    last_activity_at_ms: dateMsOrNull(row?.last_activity_at),
    heartbeat_age_ms: ageMs(row?.last_heartbeat_at, nowMs),
    activity_age_ms: ageMs(row?.last_activity_at, nowMs),
    ram_gb: finiteOrNull(row?.ram_gb),
    model_id: stringOrNull(row?.model_id),
    slots_free: integerOrNull(row?.slots_free),
    slots_total: integerOrNull(row?.slots_total),
    routing_eligible: row?.routing_eligible !== false,
  })).sort((a, b) => String(a.id).localeCompare(String(b.id)));
}

export function poolzInvariantReasons(initial, current, {
  maxHeartbeatAgeMs = 90_000,
  requireHeartbeatAdvance = false,
} = {}) {
  const before = Array.isArray(initial) ? initial : poolzSnapshot(initial);
  const after = Array.isArray(current) ? current : poolzSnapshot(current);
  const reasons = [];
  const beforeByID = new Map(before.map((row) => [row.id, row]));
  const afterByID = new Map(after.map((row) => [row.id, row]));
  if (!before.length || !after.length) reasons.push('provider_pool_signal_missing');
  if (after.length !== before.length) reasons.push(`provider_count_changed_${before.length}_to_${after.length}`);
  for (const [id, expected] of beforeByID) {
    if (!id) {
      reasons.push('provider_identity_missing');
      continue;
    }
    const observed = afterByID.get(id);
    if (!observed) {
      reasons.push(`${id}:provider_disappeared`);
      continue;
    }
    if (!READY_STATES.has(observed.state) || !observed.routing_eligible) {
      reasons.push(`${id}:state_${observed.state || 'missing'}_not_ready`);
    }
    if (expected.connected_at_ms != null && observed.connected_at_ms !== expected.connected_at_ms) {
      reasons.push(`${id}:connection_changed`);
    }
    const freshestAge = Math.min(
      observed.heartbeat_age_ms ?? Number.POSITIVE_INFINITY,
      observed.activity_age_ms ?? Number.POSITIVE_INFINITY
    );
    if (!Number.isFinite(freshestAge)) reasons.push(`${id}:heartbeat_signal_missing`);
    else if (freshestAge > maxHeartbeatAgeMs) reasons.push(`${id}:heartbeat_stale_${freshestAge}ms_gt_${maxHeartbeatAgeMs}ms`);
    if (requireHeartbeatAdvance) {
      const heartbeatAdvanced = expected.last_heartbeat_at_ms != null
        && observed.last_heartbeat_at_ms != null
        && observed.last_heartbeat_at_ms > expected.last_heartbeat_at_ms;
      const activityAdvanced = expected.last_activity_at_ms != null
        && observed.last_activity_at_ms != null
        && observed.last_activity_at_ms > expected.last_activity_at_ms;
      if (!heartbeatAdvanced && !activityAdvanced) reasons.push(`${id}:heartbeat_or_activity_did_not_advance`);
    }
  }
  return reasons;
}

export function providerSignalSnapshot(payload, source = '') {
  const capacityRAMGB = finiteOrNull(payload?.capacity?.ram_gb);
  const thermalState = stringOrNull(
    payload?.thermal_state ?? payload?.thermal?.state ?? payload?.metrics_snapshot?.thermal_state
  );
  return {
    source,
    provider_id: stringOrNull(payload?.provider_id) || source,
    status: stringOrNull(payload?.status),
    coordinator_connected: payload?.coordinator?.connected ?? payload?.coordinator_connected ?? null,
    restart_count: integerOrNull(payload?.restart_count),
    uptime_s: integerOrNull(payload?.uptime_s),
    memory_rss_mb: finiteOrNull(payload?.memory_rss_mb),
    memory_capacity_mb: capacityRAMGB == null ? null : capacityRAMGB * 1024,
    memory_pressure: stringOrNull(payload?.memory_pressure ?? payload?.metrics_snapshot?.memory_pressure),
    thermally_throttled: payload?.thermally_throttled === true || payload?.thermal?.throttled === true,
    thermal_state: thermalState,
    requests_in_flight: integerOrNull(payload?.requests_in_flight),
    requests_queued: integerOrNull(payload?.requests_queued),
    observation_id: stringOrNull(payload?.observation?.id),
    observed_at_ms: dateMsOrNull(payload?.observation?.observed_at),
    valid_for_ms: integerOrNull(payload?.observation?.valid_for_ms),
  };
}

export function providerSignalReasons(initial, current, {
  maxMemoryGrowthMB = 512,
  maxMemoryFraction = 0.9,
  requireIdle = true,
} = {}) {
  const before = initial?.provider_id ? initial : providerSignalSnapshot(initial);
  const after = current?.provider_id ? current : providerSignalSnapshot(current);
  const id = after.provider_id || before.provider_id || '<provider>';
  const reasons = [];
  if (after.status !== 'ready') reasons.push(`${id}:provider_state_${after.status || 'missing'}_not_ready`);
  if (after.coordinator_connected === false) reasons.push(`${id}:coordinator_disconnected`);
  if (Number.isInteger(before.restart_count) && after.restart_count !== before.restart_count) {
    reasons.push(`${id}:restart_count_changed_${before.restart_count}_to_${after.restart_count}`);
  }
  if (Number.isInteger(before.uptime_s) && Number.isInteger(after.uptime_s) && after.uptime_s < before.uptime_s) {
    reasons.push(`${id}:uptime_regressed`);
  }
  if (after.thermally_throttled || THERMAL_PRESSURE_STATES.has(String(after.thermal_state).toLowerCase())) {
    reasons.push(`${id}:thermal_pressure`);
  }
  if (MEMORY_PRESSURE_STATES.has(String(after.memory_pressure).toLowerCase())) {
    reasons.push(`${id}:memory_pressure_${after.memory_pressure}`);
  }
  if (after.memory_rss_mb != null && after.memory_capacity_mb != null
      && after.memory_rss_mb > after.memory_capacity_mb * maxMemoryFraction) {
    reasons.push(`${id}:memory_fraction_${round(after.memory_rss_mb / after.memory_capacity_mb, 3)}_gt_${maxMemoryFraction}`);
  }
  if (before.memory_rss_mb != null && after.memory_rss_mb != null
      && after.memory_rss_mb - before.memory_rss_mb > maxMemoryGrowthMB) {
    reasons.push(`${id}:memory_growth_${round(after.memory_rss_mb - before.memory_rss_mb)}mb_gt_${maxMemoryGrowthMB}mb`);
  }
  if (requireIdle) {
    if (Number.isInteger(after.requests_in_flight) && after.requests_in_flight !== 0) {
      reasons.push(`${id}:requests_in_flight_${after.requests_in_flight}_ne_0`);
    }
    if (Number.isInteger(after.requests_queued) && after.requests_queued !== 0) {
      reasons.push(`${id}:requests_queued_${after.requests_queued}_ne_0`);
    }
  }
  return reasons;
}

export function validateBaselineDocument(document) {
  if (document?.schema_version !== 1 || !Array.isArray(document?.entries) || document.entries.length < 1) {
    throw new Error('baseline file must contain schema_version=1 and a non-empty entries array');
  }
  const seen = new Set();
  return document.entries.map((entry, index) => {
    const key = `${entry?.model || ''}\u0000${entry?.provider || ''}`;
    if (!entry?.model || !entry?.provider || !entry?.hardware_tier || seen.has(key)) {
      throw new Error(`baseline entry ${index} needs unique model, provider, and hardware_tier`);
    }
    seen.add(key);
    for (const field of ['decode_tps_p50', 'ttft_p95_ms', 'sample_size', 'max_tps_regression_fraction', 'max_ttft_regression_fraction']) {
      if (!Number.isFinite(entry[field]) || entry[field] <= 0) {
        throw new Error(`baseline entry ${index} has invalid ${field}`);
      }
    }
    if (entry.max_tps_regression_fraction >= 1 || entry.max_ttft_regression_fraction >= 3) {
      throw new Error(`baseline entry ${index} has an unsafe regression fraction`);
    }
    if (entry.sample_size < 5 || !entry.percentile_choice || !entry.conditions || !entry.safety_margin) {
      throw new Error(`baseline entry ${index} lacks threshold provenance`);
    }
    return { ...entry };
  });
}

export function findBaseline(entries, model, provider) {
  return entries.find((entry) => entry.model === model && entry.provider === provider)
    || entries.find((entry) => entry.model === model && entry.provider === '*')
    || null;
}

export function performanceRegressionReasons(result, baseline) {
  if (!baseline) return ['baseline_unavailable'];
  const reasons = [];
  if (result?.ttftMs != null) {
    const limit = baseline.ttft_p95_ms * (1 + baseline.max_ttft_regression_fraction);
    if (result.ttftMs > limit) reasons.push(`ttft_regression_${round(result.ttftMs)}ms_gt_${round(limit)}ms`);
  }
  if (result?.decodeTps != null) {
    const floor = baseline.decode_tps_p50 * (1 - baseline.max_tps_regression_fraction);
    if (result.decodeTps < floor) reasons.push(`decode_tps_regression_${round(result.decodeTps)}_lt_${round(floor)}`);
  }
  return reasons;
}

export function recoverySoakReasons({
  gatewayInitial,
  gatewaySamples = [],
  poolzInitial = null,
  poolzSamples = [],
  providerInitial = [],
  providerSamples = [],
}, options = {}) {
  const reasons = [];
  if (gatewaySamples.length < 2) reasons.push('recovery_gateway_samples_lt_2');
  gatewaySamples.forEach((sample, index) => {
    reasons.push(...gatewayInvariantReasons(gatewayInitial, sample, options).map((reason) => `sample_${index}:${reason}`));
  });
  if (poolzInitial) {
    if (poolzSamples.length < 2) reasons.push('recovery_poolz_samples_lt_2');
    poolzSamples.forEach((sample, index) => {
      reasons.push(...poolzInvariantReasons(poolzInitial, sample, {
        maxHeartbeatAgeMs: options.maxHeartbeatAgeMs,
        requireHeartbeatAdvance: index === poolzSamples.length - 1,
      }).map((reason) => `sample_${index}:${reason}`));
    });
  }
  if (providerInitial.length) {
    if (providerSamples.length < 2) reasons.push('recovery_provider_samples_lt_2');
    providerSamples.forEach((sampleSet, index) => {
      const byID = new Map(sampleSet.map((sample) => [sample.provider_id, sample]));
      for (const initial of providerInitial) {
        const current = byID.get(initial.provider_id);
        if (!current) reasons.push(`sample_${index}:${initial.provider_id}:provider_signal_missing`);
        else reasons.push(...providerSignalReasons(initial, current, options).map((reason) => `sample_${index}:${reason}`));
      }
    });
  }
  return [...new Set(reasons)];
}

function integerOrNull(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function finiteOrNull(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;
}

function stringOrNull(value) {
  return typeof value === 'string' && value.length ? value : null;
}

function dateMsOrNull(value) {
  if (typeof value !== 'string' || !value) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function ageMs(value, nowMs) {
  const parsed = dateMsOrNull(value);
  return parsed == null ? null : Math.max(0, nowMs - parsed);
}

function round(value, digits = 2) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}
