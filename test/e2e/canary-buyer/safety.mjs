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

  ensureMinimumCapacity({ maxRequests = this.limits.maxRequests, maxCompletionTokens = this.limits.maxCompletionTokens } = {}) {
    for (const [name, value] of Object.entries({ maxRequests, maxCompletionTokens })) {
      if (!Number.isSafeInteger(value) || value < 1) {
        throw new Error(`${name} must be a positive safe integer`);
      }
    }
    this.limits.maxRequests = Math.max(this.limits.maxRequests, maxRequests);
    this.limits.maxCompletionTokens = Math.max(this.limits.maxCompletionTokens, maxCompletionTokens);
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

export function gatewayInvariantReasons(initial, current, {
  minReadyProviders = 1,
  maxDrainingProviders = 0,
  activeModelID = '',
  enforceHealthyProviderAggregates = true,
  enforceStableProviderCounts = true,
  enforceStableModelSet = true,
  allowedStableModelIDs = null,
} = {}) {
  const before = initial?.pool ? initial : gatewaySnapshot(initial);
  const after = current?.pool ? current : gatewaySnapshot(current);
  const reasons = [];
  const beforeModels = new Map((before?.models || []).map((model) => [model.id, model]));
  const afterModels = new Map((after.models || []).map((model) => [model.id, model]));
  // The gateway may exclude a coordinator row as soon as it becomes
  // non-routable, but some runtimes keep the active row buyer-visible while the
  // request is in flight. Accept either stable counts or one active-provider
  // loss. The model may disappear only when that was its sole ready provider;
  // duplicate-provider models must remain available.
  const activeModelBefore = activeModelID ? beforeModels.get(activeModelID) : null;
  const activeModelDropped = Boolean(activeModelBefore && !afterModels.has(activeModelID));
  const activeProviderLossAllowed = Boolean(activeModelBefore);
  const activeModelLossAllowed = activeModelDropped && activeModelBefore.provider_count === 1;
  if (!['up', ...(activeModelLossAllowed ? ['degraded'] : [])].includes(after.status)
      || after.coordinator_status !== 'up') reasons.push('gateway_or_coordinator_not_up');
  if (after.degraded !== (after.status === 'degraded') || (after.degraded && !activeModelLossAllowed)) {
    reasons.push('gateway_degraded');
  }
  if (!Number.isInteger(after.pool.total_providers) || !Number.isInteger(after.pool.ready)) {
    reasons.push('pool_signal_missing');
    return reasons;
  }
  const minimumReady = Math.max(0, minReadyProviders - (activeProviderLossAllowed ? 1 : 0));
  if (after.pool.ready < minimumReady) reasons.push(`ready_${after.pool.ready}_lt_${minimumReady}`);
  if (enforceHealthyProviderAggregates) {
    for (const state of ['degraded', 'unavailable']) {
      if (!Number.isInteger(after.pool[state])) reasons.push(`pool_${state}_signal_missing`);
      else if (after.pool[state] !== 0) reasons.push(`pool_${state}_${after.pool[state]}_ne_0`);
    }
    if (!Number.isInteger(after.pool.draining)) reasons.push('pool_draining_signal_missing');
    else if (after.pool.draining > maxDrainingProviders) {
      reasons.push(`pool_draining_${after.pool.draining}_gt_${maxDrainingProviders}`);
    }
  }
  if (enforceStableProviderCounts && Number.isInteger(before?.pool?.total_providers)) {
    const minTotal = before.pool.total_providers - (activeProviderLossAllowed ? 1 : 0);
    if (after.pool.total_providers < minTotal || after.pool.total_providers > before.pool.total_providers) {
      reasons.push(`total_providers_changed_${before.pool.total_providers}_to_${after.pool.total_providers}`);
    }
  }
  if (enforceStableProviderCounts && Number.isInteger(before?.pool?.ready)) {
    const minReady = before.pool.ready - (activeProviderLossAllowed ? 1 : 0);
    if (after.pool.ready < minReady || after.pool.ready > before.pool.ready) {
      reasons.push(`ready_changed_${before.pool.ready}_to_${after.pool.ready}`);
    }
  }
  if (!enforceStableModelSet) return reasons;
  for (const [id, model] of beforeModels) {
    if (!id) continue;
    if (allowedStableModelIDs && !allowedStableModelIDs.has(id)) continue;
    const observed = afterModels.get(id);
    if (!observed) {
      if (!(activeModelLossAllowed && id === activeModelID)) reasons.push(`${id}:model_disappeared`);
      continue;
    }
    if (observed.degraded || !observed.available) {
      reasons.push(`${id}:model_not_stably_available`);
    }
    if (Number.isInteger(model.ready_provider_count)) {
      const minReady = model.ready_provider_count - (activeProviderLossAllowed && id === activeModelID ? 1 : 0);
      if (
        observed.ready_provider_count < minReady
        || (enforceStableProviderCounts && observed.ready_provider_count > model.ready_provider_count)
      ) {
        reasons.push(`${id}:ready_provider_count_changed_${model.ready_provider_count}_to_${observed.ready_provider_count}`);
      }
    }
  }
  return reasons;
}

export function poolzSnapshot(payload, nowMs = Date.now()) {
  const rows = Array.isArray(payload?.pool) ? payload.pool : [];
  return rows.map((row) => {
    const id = stringOrNull(row?.provider_id) || stringOrNull(row?.assigned_id);
    return {
      id,
      provider_id: stringOrNull(row?.provider_id),
      assigned_id: stringOrNull(row?.assigned_id),
      state: stringOrNull(row?.state),
      connected_at_ms: dateMsOrNull(row?.connected_at),
      last_heartbeat_at_ms: dateMsOrNull(row?.last_heartbeat_at),
      last_activity_at_ms: dateMsOrNull(row?.last_activity_at),
      heartbeat_age_ms: ageMs(row?.last_heartbeat_at, nowMs),
      activity_age_ms: ageMs(row?.last_activity_at, nowMs),
      ram_gb: finiteOrNull(row?.ram_gb),
      model_id: stringOrNull(row?.model_id),
      binary_version: stringOrNull(row?.binary_version),
      catalog_admission_mode: stringOrNull(row?.catalog_admission_mode),
      slots_free: integerOrNull(row?.slots_free),
      slots_total: integerOrNull(row?.slots_total),
      routing_eligible: typeof row?.routing_eligible === 'boolean' ? row.routing_eligible : null,
      safety_telemetry: providerSignalSnapshot({ safety_telemetry: row?.safety_telemetry }, `poolz:${id || '<missing>'}`, nowMs),
    };
  }).sort((a, b) => String(a.id).localeCompare(String(b.id)));
}

export function poolzInvariantReasons(initial, current, {
  maxHeartbeatAgeMs = 90_000,
  requireHeartbeatAdvance = false,
  activeProviderID = '',
  heartbeatAdvanceProviderIDs = null,
  enforceStableProviderSet = true,
} = {}) {
  const before = Array.isArray(initial) ? initial : poolzSnapshot(initial);
  const after = Array.isArray(current) ? current : poolzSnapshot(current);
  const reasons = [];
  const beforeByID = new Map(before.map((row) => [row.id, row]));
  const afterByID = new Map(after.map((row) => [row.id, row]));
  if (!before.length || !after.length) reasons.push('provider_pool_signal_missing');
  if (enforceStableProviderSet && after.length !== before.length) {
    reasons.push(`provider_count_changed_${before.length}_to_${after.length}`);
  }
  for (const [id, expected] of beforeByID) {
    if (!id) {
      reasons.push('provider_identity_missing');
      continue;
    }
    const observed = afterByID.get(id);
    if (!observed) {
      if (enforceStableProviderSet) reasons.push(`${id}:provider_disappeared`);
      continue;
    }
    const stateAllowed = READY_STATES.has(observed.state)
      || (id === activeProviderID && observed.state === 'busy');
    const routingAllowed = observed.routing_eligible || (id === activeProviderID && observed.state === 'busy');
    if (!stateAllowed || !routingAllowed) {
      reasons.push(`${id}:state_${observed.state || 'missing'}_not_ready`);
    }
    if (expected.assigned_id && observed.assigned_id !== expected.assigned_id) {
      reasons.push(`${id}:session_changed`);
    }
    if (expected.connected_at_ms != null && observed.connected_at_ms !== expected.connected_at_ms) {
      reasons.push(`${id}:connection_changed`);
    }
    const heartbeatAge = observed.heartbeat_age_ms;
    if (!Number.isFinite(heartbeatAge)) reasons.push(`${id}:heartbeat_signal_missing`);
    else if (heartbeatAge > maxHeartbeatAgeMs) reasons.push(`${id}:heartbeat_stale_${heartbeatAge}ms_gt_${maxHeartbeatAgeMs}ms`);
    if (expected.last_heartbeat_at_ms != null && observed.last_heartbeat_at_ms != null
        && observed.last_heartbeat_at_ms < expected.last_heartbeat_at_ms) {
      reasons.push(`${id}:heartbeat_regressed`);
    }
    const requireProviderHeartbeatAdvance = requireHeartbeatAdvance
      && (!heartbeatAdvanceProviderIDs || heartbeatAdvanceProviderIDs.has(id));
    if (requireProviderHeartbeatAdvance) {
      const heartbeatAdvanced = expected.last_heartbeat_at_ms != null
        && observed.last_heartbeat_at_ms != null
        && observed.last_heartbeat_at_ms > expected.last_heartbeat_at_ms;
      if (!heartbeatAdvanced) reasons.push(`${id}:heartbeat_did_not_advance`);
    }
  }
  return reasons;
}

export function providerSignalSnapshot(payload, source = '', nowMs = Date.now()) {
  const telemetry = payload?.safety_telemetry || {};
  const observedAtMs = dateMsOrNull(telemetry.observed_at);
  return {
    source,
    schema_version: integerOrNull(telemetry.schema_version),
    provider_id: stringOrNull(telemetry.provider_id),
    model_id: stringOrNull(telemetry.model_id),
    model_loaded: typeof telemetry.model_loaded === 'boolean' ? telemetry.model_loaded : null,
    hardware_tier: stringOrNull(telemetry.hardware_tier),
    status: stringOrNull(telemetry.runtime_state),
    coordinator_connected: typeof telemetry.coordinator_connected === 'boolean' ? telemetry.coordinator_connected : null,
    coordinator_session_id: stringOrNull(telemetry.coordinator_session_id),
    cpu_utilization_pct: finiteOrNull(telemetry.cpu_utilization_pct),
    gpu_utilization_pct: finiteOrNull(telemetry.gpu_utilization_pct),
    gpu_utilization_scope: stringOrNull(telemetry.gpu_utilization_scope),
    power_source: stringOrNull(telemetry.power_source),
    binary_version: stringOrNull(telemetry.binary_version),
    compatibility_set_id: stringOrNull(telemetry.compatibility_set_id),
    model_hash: stringOrNull(telemetry.model_hash),
    restart_count: integerOrNull(telemetry.restart_count),
    uptime_s: integerOrNull(telemetry.uptime_s),
    memory_rss_mb: finiteOrNull(telemetry.memory_rss_mb),
    memory_capacity_mb: finiteOrNull(telemetry.memory_capacity_mb),
    memory_pressure: stringOrNull(telemetry.memory_pressure),
    thermally_throttled: typeof telemetry.thermally_throttled === 'boolean' ? telemetry.thermally_throttled : null,
    thermal_state: stringOrNull(telemetry.thermal_state),
    requests_in_flight: integerOrNull(telemetry.requests_in_flight),
    requests_queued: integerOrNull(telemetry.requests_queued),
    observation_id: stringOrNull(telemetry.observation_id),
    observed_at_ms: observedAtMs,
    observation_age_ms: observedAtMs == null ? null : Math.max(0, nowMs - observedAtMs),
    valid_for_ms: integerOrNull(telemetry.valid_for_ms),
  };
}

export function providerSignalReasons(initial, current, {
  maxMemoryGrowthMB = 512,
  maxMemoryFraction = 0.9,
  maxRequestsInFlight = 0,
  allowedRuntimeStates = ['ready'],
  requireObservationAdvance = false,
  requireNominalThermal = false,
} = {}) {
  const before = initial?.provider_id ? initial : providerSignalSnapshot(initial);
  const after = current?.provider_id ? current : providerSignalSnapshot(current);
  const id = after.provider_id || before.provider_id || '<provider>';
  const reasons = [];
  for (const [field, valid] of [
    ['schema_version', after.schema_version === 2],
    ['provider_id', Boolean(after.provider_id)],
    ['model_id', Boolean(after.model_id)],
    ['model_loaded', after.model_loaded === true],
    ['hardware_tier', Boolean(after.hardware_tier)],
    ['runtime_state', Boolean(after.status)],
    ['coordinator_connected', typeof after.coordinator_connected === 'boolean'],
    ['coordinator_session_id', Boolean(after.coordinator_session_id)],
    ['cpu_utilization_pct', after.cpu_utilization_pct != null && after.cpu_utilization_pct <= 100],
    ['gpu_utilization_pct', after.gpu_utilization_pct != null && after.gpu_utilization_pct <= 100],
    ['gpu_utilization_scope', after.gpu_utilization_scope === 'host'],
    ['power_source', ['external', 'battery'].includes(after.power_source)],
    ['binary_version', Boolean(after.binary_version)],
    ['compatibility_set_id', Boolean(after.compatibility_set_id)],
    ['model_hash', /^[a-f0-9]{64}$/.test(after.model_hash || '')],
    ['restart_count', Number.isInteger(after.restart_count)],
    ['uptime_s', Number.isInteger(after.uptime_s)],
    ['memory_rss_mb', after.memory_rss_mb != null],
    ['memory_capacity_mb', after.memory_capacity_mb != null],
    ['memory_pressure', Boolean(after.memory_pressure)],
    ['thermally_throttled', typeof after.thermally_throttled === 'boolean'],
    ['thermal_state', Boolean(after.thermal_state)],
    ['requests_in_flight', Number.isInteger(after.requests_in_flight)],
    ['requests_queued', Number.isInteger(after.requests_queued)],
    ['observation_id', Boolean(after.observation_id)],
    ['observed_at', Number.isInteger(after.observed_at_ms)],
    ['valid_for_ms', Number.isInteger(after.valid_for_ms) && after.valid_for_ms > 0],
  ]) {
    if (!valid) reasons.push(`${id}:telemetry_${field}_missing_or_invalid`);
  }
  if (Number.isInteger(after.observation_age_ms) && Number.isInteger(after.valid_for_ms)
      && after.observation_age_ms > after.valid_for_ms) {
    reasons.push(`${id}:telemetry_observation_stale_${after.observation_age_ms}ms_gt_${after.valid_for_ms}ms`);
  }
  if (requireObservationAdvance && before.observation_id && after.observation_id === before.observation_id) {
    reasons.push(`${id}:telemetry_observation_did_not_advance`);
  }
  if (before.provider_id && after.provider_id && after.provider_id !== before.provider_id) {
    reasons.push(`${id}:provider_identity_changed`);
  }
  if (before.coordinator_session_id && after.coordinator_session_id
      && after.coordinator_session_id !== before.coordinator_session_id) {
    reasons.push(`${id}:coordinator_session_changed`);
  }
  for (const field of ['binary_version', 'compatibility_set_id', 'model_hash', 'power_source']) {
    if (before[field] && after[field] && before[field] !== after[field]) {
      reasons.push(`${id}:${field}_changed`);
    }
  }
  if (before.model_id && after.model_id && after.model_id !== before.model_id) reasons.push(`${id}:model_changed`);
  if (before.hardware_tier && after.hardware_tier && after.hardware_tier !== before.hardware_tier) {
    reasons.push(`${id}:hardware_tier_changed`);
  }
  if (!allowedRuntimeStates.includes(after.status)) {
    reasons.push(`${id}:provider_state_${after.status || 'missing'}_not_allowed`);
  }
  if (after.coordinator_connected !== true) reasons.push(`${id}:coordinator_disconnected`);
  if (Number.isInteger(before.restart_count) && after.restart_count !== before.restart_count) {
    reasons.push(`${id}:restart_count_changed_${before.restart_count}_to_${after.restart_count}`);
  }
  if (Number.isInteger(before.uptime_s) && Number.isInteger(after.uptime_s) && after.uptime_s < before.uptime_s) {
    reasons.push(`${id}:uptime_regressed`);
  }
  if (after.thermally_throttled !== false || THERMAL_PRESSURE_STATES.has(String(after.thermal_state).toLowerCase())) {
    reasons.push(`${id}:thermal_pressure`);
  }
  if (requireNominalThermal && String(after.thermal_state).toLowerCase() !== 'nominal') {
    reasons.push(`${id}:thermal_state_${after.thermal_state || 'missing'}_not_nominal`);
  }
  if (!['nominal', 'fair', 'serious', 'critical'].includes(String(after.thermal_state).toLowerCase())) {
    reasons.push(`${id}:thermal_state_unknown_${after.thermal_state || 'missing'}`);
  }
  if (!['normal', 'warning', 'critical'].includes(String(after.memory_pressure).toLowerCase())) {
    reasons.push(`${id}:memory_pressure_unknown_${after.memory_pressure || 'missing'}`);
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
  if (Number.isInteger(after.requests_in_flight) && after.requests_in_flight > maxRequestsInFlight) {
    reasons.push(`${id}:requests_in_flight_${after.requests_in_flight}_gt_${maxRequestsInFlight}`);
  }
  if (Number.isInteger(after.requests_queued) && after.requests_queued !== 0) {
    reasons.push(`${id}:requests_queued_${after.requests_queued}_ne_0`);
  }
  return reasons;
}

export function validateBaselineDocument(document, nowMs = Date.now()) {
  if (document?.schema_version !== 3 || !Array.isArray(document?.entries) || document.entries.length < 1) {
    throw new Error('baseline file must contain schema_version=3 and a non-empty entries array');
  }
  const seen = new Set();
  return document.entries.map((entry, index) => {
    const key = [entry?.model, entry?.provider, entry?.hardware_tier, entry?.compatibility_set_id,
      entry?.binary_version, entry?.model_hash, entry?.power_source].join('\u0000');
    if (!entry?.model || !entry?.provider || entry.provider === '*' || !entry?.hardware_tier || seen.has(key)) {
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
    if (!Number.isSafeInteger(entry.sample_size) || entry.sample_size < 10
        || !Number.isSafeInteger(entry.cold_sample_size) || entry.cold_sample_size < 5
        || !Number.isSafeInteger(entry.warm_sample_size) || entry.warm_sample_size < 5
        || entry.cold_sample_size + entry.warm_sample_size !== entry.sample_size
        || typeof entry.percentile_choice !== 'string' || !entry.percentile_choice
        || typeof entry.conditions !== 'string' || !entry.conditions
        || typeof entry.safety_margin !== 'string' || !entry.safety_margin
        || !['external', 'battery'].includes(entry.power_source)
        || entry.thermal_condition !== 'nominal'
        || typeof entry.compatibility_set_id !== 'string' || !entry.compatibility_set_id
        || typeof entry.binary_version !== 'string' || !entry.binary_version
        || typeof entry.model_hash !== 'string' || !/^[a-f0-9]{64}$/.test(entry.model_hash)
        || !Number.isFinite(entry.decode_tps_variance) || entry.decode_tps_variance < 0
        || !Number.isFinite(entry.ttft_ms_variance) || entry.ttft_ms_variance < 0
        || !isRFC3339(entry.measured_at)
        || !isRFC3339(entry.approved_at)
        || !isRFC3339(entry.valid_until)
        || typeof entry.evidence_uri !== 'string' || !/^(?:https|s3):\/\//.test(entry.evidence_uri)
        || typeof entry.evidence_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(entry.evidence_sha256)) {
      throw new Error(`baseline entry ${index} lacks threshold provenance`);
    }
    const measuredAt = dateMsOrNull(entry.measured_at);
    const approvedAt = dateMsOrNull(entry.approved_at);
    const validUntil = dateMsOrNull(entry.valid_until);
    const maxApprovalLifetimeMs = 30 * 24 * 60 * 60 * 1000;
    const maxApprovalDelayMs = 24 * 60 * 60 * 1000;
    if (measuredAt > approvedAt || approvedAt > nowMs || approvedAt >= validUntil || validUntil <= nowMs
        || approvedAt - measuredAt > maxApprovalDelayMs
        || validUntil - measuredAt > maxApprovalLifetimeMs) {
      throw new Error(`baseline entry ${index} has invalid or expired approval window`);
    }
    return { ...entry };
  });
}

export function findBaseline(entries, model, provider, hardwareTier, {
  compatibilitySetID = '', binaryVersion = '', modelHash = '', powerSource = '', thermalCondition = '',
} = {}) {
  return entries.find((entry) => entry.model === model
    && entry.provider === provider
    && entry.hardware_tier === hardwareTier
    && entry.compatibility_set_id === compatibilitySetID
    && entry.binary_version === binaryVersion
    && entry.model_hash === modelHash
    && entry.power_source === powerSource
    && entry.thermal_condition === thermalCondition) || null;
}

export function responseIdentityReasons(result, requestedModel, expectedFleet, {
  expectedProviderID = '',
} = {}) {
  const reasons = [];
  if (result?.responseModel !== requestedModel) {
    reasons.push(`${requestedModel}:response_model_${result?.responseModel || 'missing'}_ne_${requestedModel}`);
  }
  const matching = expectedFleet.filter((row) => row.model_id === requestedModel);
  const expectedProviders = expectedProviderID ? [expectedProviderID] : matching.map((row) => row.provider_id);
  if (!expectedProviders.length) reasons.push(`${requestedModel}:expected_provider_mapping_missing`);
  if (!expectedProviders.includes(result?.provider || '')) {
    const expectedProvider = expectedProviderID || (expectedProviders.length ? expectedProviders.join('|') : 'unresolved');
    reasons.push(`${requestedModel}:response_provider_${result?.provider || 'missing'}_ne_${expectedProvider || 'unresolved'}`);
  }
  return reasons;
}

export function performanceRegressionReasons(result, baseline, sampleClass) {
  if (!baseline) return ['baseline_unavailable'];
  const reasons = [];
  if (sampleClass === 'ttft') {
    if (result?.ttftMs == null) return ['ttft_signal_missing'];
    const limit = baseline.ttft_p95_ms * (1 + baseline.max_ttft_regression_fraction);
    if (result.ttftMs > limit) reasons.push(`ttft_regression_${round(result.ttftMs)}ms_gt_${round(limit)}ms`);
  }
  if (sampleClass === 'tps') {
    if (result?.decodeTps == null) return ['decode_tps_signal_missing'];
    const floor = baseline.decode_tps_p50 * (1 - baseline.max_tps_regression_fraction);
    if (result.decodeTps < floor) reasons.push(`decode_tps_regression_${round(result.decodeTps)}_lt_${round(floor)}`);
  }
  return reasons;
}

export function validateExpectedFleetDocument(document, {
  expectedProviderCount = null,
  minProviderCount = 1,
  maxProviderCount = 100,
  requireUniqueModels = true,
} = {}) {
  if (expectedProviderCount != null
      && (!Number.isSafeInteger(expectedProviderCount) || expectedProviderCount < 1)) {
    throw new Error('expectedProviderCount must be a positive integer when set');
  }
  if (!Number.isSafeInteger(minProviderCount) || minProviderCount < 1
      || !Number.isSafeInteger(maxProviderCount) || maxProviderCount < minProviderCount) {
    throw new Error('expected fleet provider bounds are invalid');
  }
  if (document?.schema_version !== 1 || !Array.isArray(document?.providers)) {
    throw new Error('expected fleet file must contain schema_version=1 and a providers list');
  }
  const actualCount = document.providers.length;
  if (expectedProviderCount != null && actualCount !== expectedProviderCount) {
    throw new Error(`expected fleet file must contain exactly ${expectedProviderCount} providers`);
  }
  if (actualCount < minProviderCount || actualCount > maxProviderCount) {
    throw new Error(`expected fleet file must contain between ${minProviderCount} and ${maxProviderCount} providers`);
  }
  const seen = new Set();
  const models = new Set();
  const result = document.providers.map((row, index) => {
    if (typeof row?.provider_id !== 'string' || !row.provider_id
        || typeof row?.model_id !== 'string' || !row.model_id
        || seen.has(row.provider_id)) {
      throw new Error(`expected fleet provider ${index} needs a unique provider_id and model_id`);
    }
    seen.add(row.provider_id);
    if (requireUniqueModels && models.has(row.model_id)) {
      throw new Error(`expected fleet provider ${index} needs a unique model_id`);
    }
    models.add(row.model_id);
    return { provider_id: row.provider_id, model_id: row.model_id };
  });
  return result;
}

export function expectedFleetReasons(poolRows, expectedFleet, {
  allowedExtraProviderIDs = [],
  maxHeartbeatAgeMs = 90_000,
  activeProviderID = '',
  allowUnexpectedProviders = false,
} = {}) {
  const reasons = [];
  const allowed = new Set(allowedExtraProviderIDs);
  const current = new Map(poolRows.map((row) => [row.provider_id, row]));
  const expected = new Map(expectedFleet.map((row) => [row.provider_id, row]));
  for (const [id, row] of expected) {
    const observed = current.get(id);
    if (!observed) {
      reasons.push(`${id}:expected_provider_missing`);
      continue;
    }
    if (observed.model_id !== row.model_id) reasons.push(`${id}:model_${observed.model_id || 'missing'}_ne_${row.model_id}`);
    const stateAllowed = observed.state === 'ready' || (id === activeProviderID && observed.state === 'busy');
    const routingAllowed = observed.routing_eligible || (id === activeProviderID && observed.state === 'busy');
    if (!stateAllowed || !routingAllowed) reasons.push(`${id}:expected_provider_not_ready`);
    if (!Number.isFinite(observed.heartbeat_age_ms)) reasons.push(`${id}:heartbeat_signal_missing`);
    else if (observed.heartbeat_age_ms > maxHeartbeatAgeMs) {
      reasons.push(`${id}:heartbeat_stale_${observed.heartbeat_age_ms}ms_gt_${maxHeartbeatAgeMs}ms`);
    }
  }
  for (const id of current.keys()) {
    if (!allowUnexpectedProviders && !expected.has(id) && !allowed.has(id)) {
      reasons.push(`${id || '<missing>'}:unexpected_provider`);
    }
  }
  return reasons;
}

export function qualificationIsolationReasons(poolRows, {
  targetProviderID,
  targetModel,
  maxHeartbeatAgeMs = 90_000,
  initialPoolRows = null,
  requireHeartbeatAdvance = false,
  localProviderSignal = null,
  allowBusy = false,
} = {}) {
  const matches = poolRows.filter((row) => row.provider_id === targetProviderID);
  if (matches.length !== 1) return [`isolation_target_count_${matches.length}_ne_1`];
  const target = matches[0];
  const reasons = [];
  if (target.model_id !== targetModel) reasons.push(`isolation_target_model_${target.model_id || 'missing'}_ne_${targetModel}`);
  if (target.routing_eligible) reasons.push('isolation_target_still_routable');
  if (!['ready', 'draining', ...(allowBusy ? ['busy'] : [])].includes(target.state)) {
    reasons.push(`isolation_target_state_${target.state || 'missing'}_not_allowed`);
  }
  if (!Number.isFinite(target.heartbeat_age_ms)) reasons.push('isolation_target_heartbeat_missing');
  else if (target.heartbeat_age_ms > maxHeartbeatAgeMs) reasons.push('isolation_target_heartbeat_stale');
  if (!target.assigned_id) reasons.push('isolation_target_session_missing');
  if (!localProviderSignal?.coordinator_session_id) reasons.push('isolated_provider_session_missing');
  else if (target.assigned_id && localProviderSignal.coordinator_session_id !== target.assigned_id) {
    reasons.push('isolated_provider_session_ne_pool_session');
  }
  if (initialPoolRows) {
    const initial = initialPoolRows.find((row) => row.provider_id === targetProviderID);
    if (!initial) reasons.push('isolation_target_initially_missing');
    else {
      if (initial.assigned_id && target.assigned_id !== initial.assigned_id) reasons.push('isolation_target_session_changed');
      if (initial.connected_at_ms != null && target.connected_at_ms !== initial.connected_at_ms) reasons.push('isolation_target_connection_changed');
      if (requireHeartbeatAdvance && !(initial.last_heartbeat_at_ms != null
          && target.last_heartbeat_at_ms != null
          && target.last_heartbeat_at_ms > initial.last_heartbeat_at_ms)) {
        reasons.push('isolation_target_heartbeat_did_not_advance');
      }
    }
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
      const previous = index === 0 ? poolzInitial : poolzSamples[index - 1];
      reasons.push(...poolzInvariantReasons(previous, sample, {
        maxHeartbeatAgeMs: options.maxHeartbeatAgeMs,
        enforceStableProviderSet: options.enforceStableProviderCounts !== false,
      }).map((reason) => `sample_${index}:${reason}`));
    });
    if (poolzSamples.length) {
      reasons.push(...poolzInvariantReasons(poolzSamples[0], poolzSamples[poolzSamples.length - 1], {
        maxHeartbeatAgeMs: options.maxHeartbeatAgeMs,
        requireHeartbeatAdvance: true,
        heartbeatAdvanceProviderIDs: options.heartbeatAdvanceProviderIDs || null,
        enforceStableProviderSet: options.enforceStableProviderCounts !== false,
      }).map((reason) => `final:${reason}`));
    }
  }
  if (providerInitial.length) {
    if (providerSamples.length < 2) reasons.push('recovery_provider_samples_lt_2');
    providerSamples.forEach((sampleSet, index) => {
      const byID = new Map(sampleSet.map((sample) => [sample.provider_id, sample]));
      for (const initial of providerInitial) {
        const current = byID.get(initial.provider_id);
        if (!current) reasons.push(`sample_${index}:${initial.provider_id}:provider_signal_missing`);
        else {
          const previousSet = index === 0 ? providerInitial : providerSamples[index - 1];
          const previous = previousSet.find((sample) => sample.provider_id === initial.provider_id) || initial;
          reasons.push(...providerSignalReasons(previous, current, {
          ...options,
          requireObservationAdvance: !options.heartbeatAdvanceProviderIDs
            || options.heartbeatAdvanceProviderIDs.has(initial.provider_id),
        }).map((reason) => `sample_${index}:${reason}`));
        }
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

function isRFC3339(value) {
  return typeof value === 'string'
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
    && dateMsOrNull(value) != null;
}

function ageMs(value, nowMs) {
  const parsed = dateMsOrNull(value);
  return parsed == null ? null : Math.max(0, nowMs - parsed);
}

function round(value, digits = 2) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}
