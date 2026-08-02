#!/usr/bin/env node
/**
 * Canary buyer probe — continuous synthetic-buyer measurement of the live
 * macprovider network from the buyer's perspective.
 *
 * P1 from the 2026-07-09 e2e-testing review: productionizes
 * test/e2e/malibu-console/smoke.mjs + network-harness scenarios 07/09 into a
 * scheduled probe that records, per model class, the buyer-observable signals:
 *
 *   - TTFT (time to first content token) distribution: p50 / p95 / p99
 *   - sustained decode TPS (completion_tokens / decode window)
 *   - sticky KV-cache reuse ratio (cached_prompt_tokens / prompt_tokens on turn 2)
 *   - serviceability: does a chat actually complete, vs /v1/status claiming ready
 *   - request outcome counts (2xx / 502 / other) for a 502-rate signal
 *
 * Emits Prometheus text-exposition metrics (node_exporter textfile collector or
 * pushgateway) plus a per-run JSON artifact. Designed to run every 30–60 min on
 * a lab Mac via launchd (see com.streamvc.canary-buyer.plist).
 *
 * Zero dependencies (Node >= 18 built-in fetch), matching smoke.mjs.
 *
 * Usage:
 *   MACPROVIDER_BUYER_TOKEN=mp_... node probe.mjs \
 *     --metrics-out /var/lib/node_exporter/textfile/canary_buyer.prom \
 *     --json-out ./artifacts \
 *     --pushgateway http://localhost:9091
 *
 * Config (env; safety inputs are required and fail closed):
 *   MACPROVIDER_BUYER_TOKEN | MALIBU_API_KEY   buyer bearer token (liveness)
 *   CANARY_BASE            gateway base URL (default https://api.streamvc.live)
 *   CANARY_MODELS         qualification model id (liveness derives live models)
 *   CANARY_POOLZ_URL      authenticated coordinator /poolz URL
 *   CANARY_OPERATOR_TOKEN operator bearer token
 *   CANARY_EXPECTED_FLEET_FILE exact provider/model inventory JSON
 *   CANARY_TTFT_SAMPLES   short-request samples per model (default 12)
 *   CANARY_TPS_SAMPLES    longer-request samples per model (default 3)
 *   CANARY_TPS_MAX_TOKENS decode window for TPS samples (default 128)
 *   CANARY_INTERVAL_MS    floor gap between samples (default 1500)
 *   CANARY_REQ_TIMEOUT_MS per-request timeout (default 45000)
 */

import net from 'node:net';
import dns from 'node:dns/promises';
import { webcrypto } from 'node:crypto';
import { existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
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
  recoverySoakReasons,
  qualificationIsolationReasons,
  validateBaselineDocument,
  validateExpectedFleetDocument,
} from './safety.mjs';

// `crypto` is a global on Node 20+ / browsers, but NOT on Node 18 (where it's
// gated behind a flag). Fall back to node:crypto's webcrypto so the probe runs
// on the systemd host's Node 18 as well as newer runtimes.
const crypto = globalThis.crypto ?? webcrypto;

const args = parseArgs(process.argv.slice(2));
const selectedMode = args.mode || env('CANARY_MODE') || 'liveness';
const isQualification = selectedMode === 'qualification';
const configuredTTFTSamples = intEnv('CANARY_TTFT_SAMPLES', 12, 1, 20);
const configuredTPSSamples = intEnv('CANARY_TPS_SAMPLES', 3, 1, 10);
const GATEWAY_STATUS_CACHE_TTL_MS = 10_000;
const PRODUCTION_HEARTBEAT_CADENCE_MS = 30_000;
const LEGACY_ROLLBACK_AUTHORITY = 'issue-825-canary-fleet-r6';
const LEGACY_ROLLBACK_MAX_VALIDITY_MS = 15 * 60 * 1000;
const LEGACY_ROLLBACK_MAX_PROVIDERS = 100;
const LIVENESS_MAX_TOKENS_PER_MODEL = 8;

const CONFIG = {
  mode: selectedMode,
  base: (env('CANARY_BASE') || 'https://api.streamvc.live').replace(/\/$/, ''),
  isolatedProviderBase: env('CANARY_ISOLATED_PROVIDER_BASE').replace(/\/$/, ''),
  isolatedProviderID: env('CANARY_ISOLATED_PROVIDER_ID'),
  token: env('MACPROVIDER_BUYER_TOKEN') || env('MALIBU_API_KEY') || '',
  operatorToken: env('CANARY_OPERATOR_TOKEN') || '',
  poolzURL: env('CANARY_POOLZ_URL'),
  baselineFile: env('CANARY_BASELINE_FILE'),
  expectedFleetFile: env('CANARY_EXPECTED_FLEET_FILE'),
  models: (env('CANARY_MODELS') || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  ttftSamples: isQualification ? configuredTTFTSamples : 1,
  tpsSamples: isQualification ? configuredTPSSamples : 0,
  tpsMaxTokens: intEnv('CANARY_TPS_MAX_TOKENS', 128, 1, 512),
  intervalMs: intEnv('CANARY_INTERVAL_MS', 1500, 1, 10000),
  reqTimeoutMs: intEnv('CANARY_REQ_TIMEOUT_MS', 45000, 1000, 120000),
  stickyPrefixLines: intEnv('CANARY_STICKY_PREFIX_LINES', 80, 1, 1000),
  maxTtftP95Ms: numberEnv('CANARY_MAX_TTFT_P95_MS', 7000),
  minDecodeTpsP50: numberEnv('CANARY_MIN_DECODE_TPS_P50', 15),
  minCachedPromptRatio: numberEnv('CANARY_MIN_CACHED_PROMPT_RATIO', 0.1),
  minReadyProviders: intEnv('CANARY_MIN_READY_PROVIDERS', 2, 1, 100),
  expectedProviderCount: intEnv('CANARY_EXPECTED_PROVIDER_COUNT', 0, 0, 100),
  maxRequestsPerProvider: intEnv('CANARY_MAX_REQUESTS_PER_PROVIDER', isQualification ? 17 : 4, 1, 100),
  maxCompletionTokensPerProvider: intEnv('CANARY_MAX_COMPLETION_TOKENS_PER_PROVIDER', isQualification ? 512 : 32, 1, 4096),
  maxRunDurationMs: intEnv('CANARY_MAX_RUN_DURATION_MS', isQualification ? 300000 : 90000, 10000, 900000),
  recoverySoakSeconds: intEnv('CANARY_RECOVERY_SOAK_SECONDS', isQualification ? 60 : 45, 2, 300),
  recoveryPollMs: intEnv('CANARY_RECOVERY_POLL_MS', 7000, 6000, 30000),
  safetyPollMs: intEnv('CANARY_SAFETY_POLL_MS', 2000, 500, 5000),
  safetyObserverTimeoutMs: intEnv('CANARY_SAFETY_OBSERVER_TIMEOUT_MS', 5000, 1000, 10000),
  maxHeartbeatAgeMs: intEnv('CANARY_MAX_HEARTBEAT_AGE_MS', 90000, 1000, 300000),
  maxMemoryGrowthMB: intEnv('CANARY_MAX_MEMORY_GROWTH_MB', 512, 1, 65536),
  maxMemoryFraction: numberEnv('CANARY_MAX_MEMORY_FRACTION', 0.9),
  metricsOut: args['metrics-out'] || env('CANARY_METRICS_OUT') || '',
  jsonOut: args['json-out'] || env('CANARY_JSON_OUT') || '',
  pushgateway: args['pushgateway'] || env('CANARY_PUSHGATEWAY') || '',
  pushJob: args['push-job'] || env('CANARY_PUSH_JOB') || 'canary_buyer',
  disableFile: env('CANARY_DISABLE_FILE'),
  allowLegacyBridgeProviderSignals: boolEnv('CANARY_ALLOW_LEGACY_BRIDGE_PROVIDER_SIGNALS', false),
  legacyRollbackAuthorizationFile: env('CANARY_LEGACY_ROLLBACK_AUTHORIZATION_FILE'),
  failOnDegraded: 'fail-on-degraded' in args,
};
CONFIG.postRequestRecoveryMs = GATEWAY_STATUS_CACHE_TTL_MS
  + CONFIG.safetyPollMs
  + CONFIG.safetyObserverTimeoutMs;

function env(k) {
  return process.env[k] && process.env[k].length ? process.env[k] : '';
}
function boolEnv(k, d) {
  const raw = env(k);
  if (!raw) return d;
  if (raw !== '0' && raw !== '1') throw new Error(`${k} must be 0 or 1`);
  return raw === '1';
}
function intEnv(k, d, minimum, maximum) {
  const raw = env(k);
  if (!raw) return d;
  if (!/^(0|[1-9][0-9]*)$/.test(raw)) {
    throw new Error(`${k} must be an integer between ${minimum} and ${maximum}`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${k} must be an integer between ${minimum} and ${maximum}`);
  }
  return value;
}
function numberEnv(k, d) {
  const raw = env(k);
  if (!raw) return d;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${k} must be a non-negative number`);
  }
  return value;
}
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      out[key] = next;
      i++;
    } else {
      out[key] = true;
    }
  }
  return out;
}

function authHeaders(extra = {}) {
  return { Authorization: `Bearer ${CONFIG.token}`, ...extra };
}

// Redact the buyer token and any Bearer credential from any text before it
// reaches a log, stdout, or an on-disk artifact. A mispointed or compromised
// gateway that echoes the Authorization header must not persist the token.
function redact(text) {
  if (text == null) return text;
  let s = String(text);
  // Only scrub the literal token when it is long enough to be a real credential
  // (harness buyer keys are mp_ + 20+ chars). A pathologically short token would
  // otherwise corrupt legitimate output by matching common substrings. The
  // Bearer-pattern scrub below still catches the credential regardless.
  for (const secret of [CONFIG.token, CONFIG.operatorToken]) {
    if (secret && secret.length >= 8) s = s.split(secret).join('***');
  }
  return s.replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer ***');
}

// Credential-bearing URLs are always HTTPS and public. Local provider
// qualification has a separate, unauthenticated URL validator below so opting
// into loopback HTTP can never weaken buyer/operator-token transport policy.
function parseSafeUrl(raw, label) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error(`${label} is not a valid URL`);
  }
  if (u.protocol !== 'https:') {
    throw new Error(`${label} must be https`);
  }
  if (isPrivateHostname(u.hostname)) {
    throw new Error(`${label} points at a private/loopback host`);
  }
  return u;
}

function parseProviderLocalUrl(raw, label) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error(`${label} is not a valid URL`);
  }
  if (u.protocol === 'http:' && env('CANARY_ALLOW_INSECURE_PROVIDER_OBSERVER') !== '1') {
    throw new Error(`${label} requires CANARY_ALLOW_INSECURE_PROVIDER_OBSERVER=1 for local HTTP`);
  }
  if (!['http:', 'https:'].includes(u.protocol)) throw new Error(`${label} must be http or https`);
  return u;
}

// Resolve the host and reject if it maps to a private address, closing the
// static-misconfiguration / private-DNS SSRF case that a literal-hostname check
// misses. Pure DNS-rebinding (a flip between this check and fetch's own resolve)
// is an inherent limitation of dependency-free fetch and is accepted as a
// residual risk for this operator-run internal tool; `redirect: 'manual'` on the
// token-bearing requests closes the redirect-based variant.
async function assertResolvesPublic(u, label) {
  const host = u.hostname.replace(/^\[|\]$/g, '');
  if (net.isIP(host)) return; // literal IP already screened by isPrivateHostname
  let addrs;
  try {
    addrs = await dns.lookup(host, { all: true });
  } catch {
    throw new Error(`${label} host ${host} does not resolve`);
  }
  for (const { address } of addrs) {
    if (isPrivateIp(address)) {
      throw new Error(`${label} host ${host} resolves to a private address`);
    }
  }
}

async function assertResolvesLocal(u, label) {
  const host = u.hostname.replace(/^\[|\]$/g, '');
  if (net.isIP(host)) {
    if (!isPrivateIp(host)) throw new Error(`${label} must resolve only to loopback/private addresses`);
    return;
  }
  let addrs;
  try {
    addrs = await dns.lookup(host, { all: true });
  } catch {
    throw new Error(`${label} host ${host} does not resolve`);
  }
  if (!addrs.length || addrs.some(({ address }) => !isPrivateIp(address))) {
    throw new Error(`${label} must resolve only to loopback/private addresses`);
  }
}

function isPrivateHostname(host) {
  const h = host.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (h === '' || h === 'localhost' || h.endsWith('.localhost')) return true;
  if (net.isIP(h)) return isPrivateIp(h);
  return false; // a real hostname is screened at resolve time by assertResolvesPublic
}

function isPrivateIp(ip) {
  const fam = net.isIP(ip);
  if (!fam) return false;
  const addr = ip.toLowerCase();
  if (fam === 6) {
    // IPv4-mapped/compat, in dotted (::ffff:127.0.0.1) or hex (::ffff:7f00:1)
    // form — URL parsing normalizes to the latter, so handle both.
    const v4 = ipv4FromMapped(addr);
    if (v4) return isPrivateIp4(v4);
    if (addr === '::' || addr === '::1') return true; // unspecified + loopback
    const first = addr.split(':')[0];
    if (/^fe[89ab]/.test(first)) return true; // fe80::/10 link-local
    if (/^f[cd]/.test(first)) return true; // fc00::/7 unique-local
    return false;
  }
  return isPrivateIp4(addr);
}
function ipv4FromMapped(addr) {
  const m = addr.match(/^(?:::ffff:|::)([0-9a-f.:]+)$/);
  if (!m) return null;
  const tail = m[1];
  if (tail.includes('.')) return tail; // already dotted
  const groups = tail.split(':').filter((g) => g.length);
  if (groups.length !== 2) return null; // low 32 bits are exactly two hex groups
  const [g1, g2] = groups.map((g) => parseInt(g, 16));
  if (!Number.isInteger(g1) || !Number.isInteger(g2)) return null;
  return `${(g1 >> 8) & 0xff}.${g1 & 0xff}.${(g2 >> 8) & 0xff}.${g2 & 0xff}`;
}
function isPrivateIp4(ip) {
  const p = ip.split('.').map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = p;
  if (a === 0 || a === 10 || a === 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  return false;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function sleepInterruptibly(ms, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) {
      resolve(false);
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve(true);
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      resolve(false);
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

function deadlineTimeoutMs(budget, capMs = CONFIG.reqTimeoutMs) {
  const remaining = budget.remainingDurationMs();
  if (remaining < 1) throw new Error(budget.timeReason() || 'hard_deadline_exhausted');
  return Math.max(1, Math.min(capMs, remaining));
}

async function getStatus(budget, timeoutMs = CONFIG.reqTimeoutMs) {
  const ctl = AbortSignal.timeout(deadlineTimeoutMs(budget, timeoutMs));
  const r = await fetch(`${CONFIG.base}/v1/status`, {
    headers: authHeaders({ Accept: 'application/json' }),
    redirect: 'manual',
    signal: ctl,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(redact(`/v1/status HTTP ${r.status}: ${text.slice(0, 200)}`));
  return JSON.parse(text);
}

async function getJSON(url, budget, { authorization = '', label = url, timeoutMs = CONFIG.reqTimeoutMs } = {}) {
  const headers = { Accept: 'application/json' };
  if (authorization) headers.Authorization = `Bearer ${authorization}`;
  const r = await fetch(url, {
    headers,
    redirect: 'manual',
    signal: AbortSignal.timeout(deadlineTimeoutMs(budget, timeoutMs)),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(redact(`${label} HTTP ${r.status}: ${text.slice(0, 200)}`));
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${label} returned invalid JSON`);
  }
}

async function observeSafety(budget, timeoutMs = CONFIG.reqTimeoutMs) {
  const observedAtMs = Date.now();
  const gatewayRaw = await getStatus(budget, timeoutMs);
  const gateway = gatewaySnapshot(gatewayRaw);
  const rawPool = await getJSON(CONFIG.poolzURL, budget, {
    authorization: CONFIG.operatorToken,
    label: 'CANARY_POOLZ_URL',
    timeoutMs,
  });
  const operatorPool = poolzSnapshot(rawPool, observedAtMs);
  const providers = [];
  if (CONFIG.mode === 'qualification') {
    const url = `${CONFIG.isolatedProviderBase}/v1/status`;
    const raw = await getJSON(url, budget, { label: 'isolated provider status', timeoutMs });
    providers.push(providerSignalSnapshot(raw, url, observedAtMs));
  } else {
    providers.push(...operatorPool.map((row) => row.safety_telemetry));
  }
  return { observed_at: new Date(observedAtMs).toISOString(), gateway, operator_pool: operatorPool, providers };
}

/**
 * Stream one chat completion, measuring TTFT and decode-window timing.
 * Never throws on HTTP/stream errors — returns {ok:false, status, error} so
 * the caller can record failures as metrics (recording failures is the point).
 */
export async function streamOne({
  model, messages, conversationId, maxTokens, timeoutMs = CONFIG.reqTimeoutMs, abortSignal = null,
}) {
  const headers = {
    'Content-Type': 'application/json',
    Accept: 'text/event-stream',
  };
  if (CONFIG.mode === 'liveness') Object.assign(headers, authHeaders());
  if (conversationId) headers['X-MacProvider-Conversation'] = conversationId;

  const start = now();
  let firstTokenAt = 0;
  let lastTokenAt = 0;
  let content = '';
  let usage = null;
  let requestId = '';
  let provider = '';
  let responseModel = '';
  let streamError = null;
  let sawDone = false;
  let safetyAborted = false;
  let timedOut = false;
  const requestController = new AbortController();
  const timeout = setTimeout(() => {
    timedOut = true;
    requestController.abort();
  }, timeoutMs);
  const abortForSafety = () => {
    safetyAborted = true;
    requestController.abort();
  };
  abortSignal?.addEventListener('abort', abortForSafety, { once: true });

  try {
    const requestBase = CONFIG.mode === 'qualification' ? CONFIG.isolatedProviderBase : CONFIG.base;
    const r = await fetch(`${requestBase}/v1/chat/completions`, {
      method: 'POST',
      headers,
      // include_usage requests the final usage chunk in the stream — without it
      // a spec-strict gateway omits usage and decode-TPS/cache-ratio go silently
      // null while the request still counts as serviceable.
      body: JSON.stringify({
        model,
        messages,
        stream: true,
        max_tokens: maxTokens,
        stream_options: { include_usage: true },
      }),
      redirect: 'manual',
      signal: requestController.signal,
    });
    requestId = r.headers.get('x-request-id') || '';
    provider = r.headers.get('x-provider-id') || r.headers.get('x-macprovider-provider') || '';

    if (!r.ok) {
      const text = await r.text().catch(() => '');
      return { ok: false, status: r.status, error: redact(text.slice(0, 300)), requestId, provider };
    }

    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    // SSE events are separated by a blank line, which may be LF (\n\n) or CRLF
    // (\r\n\r\n) depending on the server/proxy. Match either, else a CRLF stream
    // buffers forever and the request is falsely recorded as "empty".
    const nextSep = (s) => {
      const m = /\r?\n\r?\n/.exec(s);
      return m ? { idx: m.index, len: m[0].length } : null;
    };
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let sep;
        while ((sep = nextSep(buf))) {
          const frame = buf.slice(0, sep.idx);
          buf = buf.slice(sep.idx + sep.len);
          for (const line of frame.split(/\r?\n/)) {
            if (!line.startsWith('data:')) continue;
            const payload = line.slice(5).trim();
            if (!payload) continue;
            if (payload === '[DONE]') {
              sawDone = true;
              continue;
            }
            let obj;
            try {
              obj = JSON.parse(payload);
            } catch {
              continue;
            }
            // A terminal error frame means the completion failed even if content
            // already streamed — don't count it as a healthy sample.
            if (obj?.error) streamError = obj.error;
            if (typeof obj?.model === 'string' && obj.model) {
              if (responseModel && obj.model !== responseModel) {
                streamError = { message: `response model changed from ${responseModel} to ${obj.model}` };
              }
              responseModel = obj.model;
            }
            const delta = obj?.choices?.[0]?.delta?.content;
            if (delta) {
              if (!firstTokenAt) firstTokenAt = now();
              lastTokenAt = now();
              content += delta;
            }
            if (obj?.usage) usage = obj.usage;
          }
        }
      }
    } finally {
      try {
        reader.releaseLock();
      } catch {
        /* reader already released */
      }
    }
  } catch (e) {
    const kind = safetyAborted ? 'safety_abort' : (timedOut ? 'timeout' : 'network_error');
    return { ok: false, status: 0, kind, error: redact(`${kind}: ${e.message || e}`), requestId, provider };
  } finally {
    clearTimeout(timeout);
    abortSignal?.removeEventListener('abort', abortForSafety);
  }

  const end = now();
  if (streamError) {
    return {
      ok: false,
      status: 200,
      kind: 'stream_error',
      error: redact(`stream error frame: ${JSON.stringify(streamError).slice(0, 200)}`),
      requestId,
      provider,
      responseModel,
      usage,
    };
  }
  if (!sawDone) {
    return {
      ok: false,
      status: 200,
      kind: 'stream_error',
      error: 'stream ended without terminal [DONE]',
      requestId,
      provider,
      responseModel,
      usage,
    };
  }
  if (!firstTokenAt) {
    // 2xx but no content token ever arrived (e.g. empty completion / mid-stream abort).
    return { ok: false, status: 200, error: 'no content token', requestId, provider, responseModel, usage };
  }
  const ttftMs = firstTokenAt - start;
  const decodeMs = Math.max(0, lastTokenAt - firstTokenAt);
  const completionTokens = usage?.completion_tokens ?? null;
  let decodeTps = null;
  if (completionTokens && completionTokens > 1 && decodeMs > 0) {
    // Exclude the first token from the decode-rate window: TTFT already accounts
    // for prefill + first token; the sustained rate is the remaining tokens.
    decodeTps = ((completionTokens - 1) / decodeMs) * 1000;
  }
  return {
    ok: true,
    status: 200,
    ttftMs,
    decodeMs,
    totalMs: end - start,
    decodeTps,
    content,
    usage,
    requestId,
    provider,
    responseModel,
  };
}

async function sampleModel(model, control) {
  const res = {
    model,
    ttftMs: [],
    decodeTps: [],
    outcomes: {}, // 2xx | 502 | 5xx | timeout | network_error | stream_error | empty | other
    samples: 0,
    firstError: '',
    cachedRatio: null,
    cachedPromptTokens: null,
    promptTokens: null,
    provider: '',
    requests: [],
  };

  // Metric collection is per sample class: only the short-request loop feeds the
  // TTFT distribution, only the long-request loop feeds sustained TPS. Mixing
  // them would contaminate TTFT percentiles with long-generation requests and
  // TPS with 8-token noise. `collect` selects which array (if any) this request
  // contributes to; every request still contributes to outcome counts.
  const record = (r, collect = {}, maxTokens = null) => {
    res.samples++;
    if (r.provider && !res.provider) res.provider = r.provider;
    const bucket = outcomeBucket(r);
    res.outcomes[bucket] = (res.outcomes[bucket] || 0) + 1;
    res.requests.push({
      sequence: res.samples,
      outcome: bucket,
      status: r.status,
      provider: r.provider || null,
      response_model: r.responseModel || null,
      request_id: r.requestId || null,
      max_completion_tokens: maxTokens,
      ttft_ms: r.ttftMs ?? null,
      decode_ms: r.decodeMs ?? null,
      total_ms: r.totalMs ?? null,
      decode_tps: r.decodeTps ?? null,
      completion_tokens: numOrNull(r.usage?.completion_tokens),
    });
    if (r.ok) {
      if (collect.ttft) res.ttftMs.push(r.ttftMs);
      if (collect.tps && r.decodeTps != null) res.decodeTps.push(r.decodeTps);
    } else if (!res.firstError) {
      res.firstError = `HTTP ${r.status}: ${r.error || ''}`.slice(0, 200);
    }
  };

  const runRequest = async ({ messages, conversationId, maxTokens, collect = {}, sampleClass }) => {
    if (!(await control.beforeRequest(maxTokens))) return null;
    const requestAbort = new AbortController();
    const monitorStop = new AbortController();
    const monitor = control.monitorDuringRequest(requestAbort, monitorStop.signal, model);
    const r = await streamOne({
      model,
      messages,
      conversationId,
      maxTokens,
      timeoutMs: control.requestTimeoutMs(),
      abortSignal: requestAbort.signal,
    });
    monitorStop.abort();
    await monitor;
    record(r, collect, maxTokens);
    await control.afterRequest(model, r, maxTokens, sampleClass);
    return r;
  };

  // 1. TTFT distribution — many short requests, fresh conversation each.
  for (let i = 0; i < CONFIG.ttftSamples; i++) {
    const r = await runRequest({
      conversationId: randUUID(),
      messages: [{ role: 'user', content: 'Say: ready.' }],
      maxTokens: 8,
      collect: { ttft: true },
      sampleClass: 'ttft',
    });
    if (!r || control.failed()) break;
    if (i < CONFIG.ttftSamples - 1 && !(await control.sleep(CONFIG.intervalMs, 'ttft_interval'))) break;
  }

  // Scheduled liveness intentionally stops after one 8-token request per
  // model. Performance, decode, and cache work is qualification-only.
  if (CONFIG.mode === 'liveness' || control.failed()) {
    res.serviceable = (res.outcomes['2xx'] || 0) > 0 ? 1 : 0;
    return res;
  }

  // 2. Sustained decode TPS — fewer, longer requests.
  for (let i = 0; i < CONFIG.tpsSamples; i++) {
    if (!(await control.sleep(CONFIG.intervalMs, 'tps_interval'))) break;
    const r = await runRequest({
      conversationId: randUUID(),
      messages: [
        { role: 'user', content: 'Count from 1 to 100, one number per line.' },
      ],
      maxTokens: CONFIG.tpsMaxTokens,
      collect: { tps: true },
      sampleClass: 'tps',
    });
    if (!r || control.failed()) break;
  }

  if (control.failed()) {
    res.serviceable = (res.outcomes['2xx'] || 0) > 0 ? 1 : 0;
    return res;
  }

  // 3. Sticky KV-cache reuse — two turns, same conversation tag, sharing a
  // large prefix. The prefix MUST be large enough to exceed the provider's
  // prefix-cache granularity, otherwise turn-2 cached_prompt_tokens is always 0
  // and the metric can't distinguish "working" from "reuse collapsed". A live
  // measurement (2026-07-09, ~3.9k-token prefix) saw ~64% turn-2 reuse.
  if (!(await control.sleep(CONFIG.intervalMs, 'cache_interval'))) {
    res.serviceable = (res.outcomes['2xx'] || 0) > 0 ? 1 : 0;
    return res;
  }
  const conv = randUUID();
  const prefix = stickyPrefix(CONFIG.stickyPrefixLines);
  const t1 = await runRequest({
    conversationId: conv,
    messages: [{ role: 'user', content: `${prefix}\n\nReply with exactly: pong` }],
    maxTokens: 16,
    sampleClass: 'cache',
  });
  if (t1?.ok && !control.failed()) {
    if (!(await control.sleep(CONFIG.intervalMs, 'cache_interval'))) {
      res.serviceable = (res.outcomes['2xx'] || 0) > 0 ? 1 : 0;
      return res;
    }
    const t2 = await runRequest({
      conversationId: conv,
      messages: [
        { role: 'user', content: `${prefix}\n\nReply with exactly: pong` },
        { role: 'assistant', content: t1.content },
        { role: 'user', content: 'Reply with exactly: ping' },
      ],
      maxTokens: 16,
      sampleClass: 'cache',
    });
    if (t2?.ok && t2.usage) {
      const cached = numOrNull(t2.usage.cached_prompt_tokens);
      const prompt = numOrNull(t2.usage.prompt_tokens);
      res.cachedPromptTokens = cached;
      res.promptTokens = prompt;
      if (cached != null && prompt != null && prompt > 0) {
        res.cachedRatio = cached / prompt;
      }
    }
    control.checkCacheMeasurement(model, res.cachedRatio);
  }

  // Serviceable iff any request across all classes produced a token (a 2xx
  // outcome), not just the TTFT loop — a model that fails short probes but
  // serves long ones is still serving.
  res.serviceable = (res.outcomes['2xx'] || 0) > 0 ? 1 : 0;
  return res;
}

// Buckets: 2xx | authentication_error | 502 | 5xx | timeout | network_error | stream_error | empty | other
export function outcomeBucket(r) {
  if (r.ok) return '2xx';
  if (r.kind) return r.kind; // timeout | network_error | stream_error
  if (r.status === 0) return 'network_error';
  if (r.status === 502) return '502';
  if (r.status === 401 || r.status === 403) return 'authentication_error';
  if (r.status === 200) return 'empty';
  if (r.status >= 500) return '5xx';
  return 'other';
}

export function shouldRunRecovery(attemptedRequests) {
  return Number.isSafeInteger(attemptedRequests) && attemptedRequests > 0;
}

export function recoveryCadenceReasons(
  soakSeconds,
  pollMs,
  heartbeatCadenceMs = PRODUCTION_HEARTBEAT_CADENCE_MS,
) {
  const reasons = [];
  if (pollMs >= heartbeatCadenceMs) reasons.push('recovery_poll_not_faster_than_heartbeat');
  if ((soakSeconds * 1000) < (pollMs * 2)) reasons.push('recovery_soak_cannot_fit_two_observations');
  const recoverySampleSpanMs = (Math.floor((soakSeconds * 1000) / pollMs) - 1) * pollMs;
  if (recoverySampleSpanMs < heartbeatCadenceMs) {
    reasons.push('recovery_soak_cannot_observe_heartbeat_advance');
  }
  return reasons;
}

function numOrNull(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}
// Deterministic shared prefix (~10 tokens/line) for the sticky KV-cache test.
// Large enough to exceed the provider's prefix-cache granularity so turn-2
// cached_prompt_tokens is a real reuse signal.
function stickyPrefix(lines) {
  const out = ['Reference facts to retain for this conversation:'];
  for (let i = 0; i < lines; i++) {
    out.push(`- item ${i}: key K${i} maps to value V${i * 7} under namespace N${i % 9}; invariant s${i} > ${i}.`);
  }
  return out.join('\n');
}
function randUUID() {
  return crypto.randomUUID();
}
function now() {
  return Number(process.hrtime.bigint() / 1000000n);
}

function percentile(arr, p) {
  if (!arr.length) return null;
  const sorted = [...arr].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}
function mean(arr) {
  return arr.length ? arr.reduce((a, b) => a + b, 0) / arr.length : null;
}

// ── metrics emission ────────────────────────────────────────────────────────

function buildRun(status, modelResults, runStartUnix, details = {}) {
  return {
    schema_version: 2,
    probe: 'canary_buyer',
    mode: CONFIG.mode,
    run_at: new Date(runStartUnix * 1000).toISOString(),
    base: CONFIG.base,
    up: status && status.status !== 'down' ? 1 : 0,
    pool: status?.pool || null,
    coordinator_status: status?.coordinator?.status || status?.coordinator_status || null,
    result: details.result || { outcome: 'healthy', failure_class: null, reasons: [], phase: 'complete', aborted: false },
    budget: details.budget || null,
    safety: details.safety || null,
    models: modelResults.map((m) => ({
      model: m.model,
      serviceable: m.serviceable,
      samples: m.samples,
      outcomes: m.outcomes,
      ttft_ms: {
        p50: percentile(m.ttftMs, 50),
        p95: percentile(m.ttftMs, 95),
        p99: percentile(m.ttftMs, 99),
        n: m.ttftMs.length,
      },
      decode_tps: {
        p50: percentile(m.decodeTps, 50),
        mean: mean(m.decodeTps),
        n: m.decodeTps.length,
      },
      cached_prompt_ratio: m.cachedRatio,
      cached_prompt_tokens: m.cachedPromptTokens,
      prompt_tokens: m.promptTokens,
      provider: m.provider,
      first_error: m.firstError || null,
      requests: m.requests,
    })),
  };
}

function promEscape(v) {
  return String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ');
}

function toProm(run) {
  const L = [];
  const ts = Math.floor(Date.parse(run.run_at));
  const h = (name, help, type) => {
    L.push(`# HELP ${name} ${help}`);
    L.push(`# TYPE ${name} ${type}`);
  };
  const lbl = (o) =>
    Object.entries(o)
      .map(([k, v]) => `${k}="${promEscape(v)}"`)
      .join(',');

  h('macprovider_canary_up', 'Gateway /v1/status reachable (1) or not (0).', 'gauge');
  L.push(`macprovider_canary_up ${run.up}`);

  h('macprovider_canary_run_timestamp_seconds', 'Unix time of this probe run.', 'gauge');
  L.push(`macprovider_canary_run_timestamp_seconds ${Math.floor(ts / 1000)}`);

  h('macprovider_canary_result', 'Canary outcome by mode and failure class (1 for this run).', 'gauge');
  L.push(`macprovider_canary_result{${lbl({ mode: run.mode || 'legacy', outcome: run.result?.outcome || 'unknown', failure_class: run.result?.failure_class || 'none' })}} 1`);

  if (run.pool) {
    h('macprovider_canary_pool_providers', 'Providers by pool state from /v1/status.', 'gauge');
    for (const k of ['total_providers', 'ready', 'degraded', 'draining', 'unavailable']) {
      if (run.pool[k] != null) L.push(`macprovider_canary_pool_providers{state="${k}"} ${run.pool[k]}`);
    }
  }

  h('macprovider_canary_model_serviceable', 'A chat completion actually produced a token (1) despite status. Catches status-vs-serviceable divergence.', 'gauge');
  h('macprovider_canary_ttft_ms', 'Time-to-first-token in ms by quantile.', 'gauge');
  h('macprovider_canary_ttft_samples', 'Valid TTFT samples collected this run (0 while serviceable=1 means the signal went dark).', 'gauge');
  h('macprovider_canary_decode_tps', 'Sustained decode tokens/sec (excludes first token/prefill).', 'gauge');
  h('macprovider_canary_decode_tps_samples', 'Valid decode-TPS samples this run (0 while serviceable=1 means usage stopped being reported).', 'gauge');
  h('macprovider_canary_cached_prompt_ratio', 'Sticky turn-2 cached_prompt_tokens / prompt_tokens (KV-cache reuse).', 'gauge');
  // Per-run gauges (reset each run), NOT cumulative counters — hence no _total
  // suffix, so consumers don't apply rate()/counter semantics to them.
  h('macprovider_canary_requests', 'Probe requests this run by outcome bucket (per-run gauge).', 'gauge');
  h('macprovider_canary_samples', 'Probe requests issued for the model this run (per-run gauge).', 'gauge');

  for (const m of run.models) {
    const base = { model: m.model };
    L.push(`macprovider_canary_model_serviceable{${lbl(base)}} ${m.serviceable}`);
    L.push(`macprovider_canary_samples{${lbl(base)}} ${m.samples}`);
    for (const [outcome, n] of Object.entries(m.outcomes)) {
      L.push(`macprovider_canary_requests{${lbl({ ...base, outcome })}} ${n}`);
    }
    for (const q of ['p50', 'p95', 'p99']) {
      if (m.ttft_ms[q] != null) L.push(`macprovider_canary_ttft_ms{${lbl({ ...base, quantile: q })}} ${m.ttft_ms[q]}`);
    }
    // Explicit sample counts so alerts can catch "serviceable but signal dark"
    // — Prometheus can't easily alert on an absent series.
    L.push(`macprovider_canary_ttft_samples{${lbl(base)}} ${m.ttft_ms.n}`);
    L.push(`macprovider_canary_decode_tps_samples{${lbl(base)}} ${m.decode_tps.n}`);
    // Only the p50 quantile is emitted to Prometheus; mean stays in the JSON
    // artifact (a mean under a quantile label misleads Prometheus consumers).
    if (m.decode_tps.p50 != null) L.push(`macprovider_canary_decode_tps{${lbl({ ...base, quantile: 'p50' })}} ${round(m.decode_tps.p50)}`);
    if (m.cached_prompt_ratio != null) L.push(`macprovider_canary_cached_prompt_ratio{${lbl(base)}} ${round(m.cached_prompt_ratio, 4)}`);
  }
  return L.join('\n') + '\n';
}

function round(v, d = 2) {
  const f = Math.pow(10, d);
  return Math.round(v * f) / f;
}

/**
 * Return the buyer-visible reasons that make a run unsafe as a deploy gate.
 * Availability alone is insufficient: a release that serves one token while
 * dropping other requests or losing latency, throughput, or cache signals must
 * not ping the heartbeat.
 */
export function degradedReasons(run, thresholds = {}) {
  const livenessOnly = run?.mode === 'liveness';
  const baselineQualified = run?.mode === 'qualification';
  const limits = {
    maxTtftP95Ms: thresholds.maxTtftP95Ms ?? 7000,
    minDecodeTpsP50: thresholds.minDecodeTpsP50 ?? 15,
    minCachedPromptRatio: thresholds.minCachedPromptRatio ?? 0.1,
    minTtftSamples: thresholds.ttftSamples ?? 12,
    minTpsSamples: thresholds.tpsSamples ?? 3,
  };
  const reasons = [];
  if (run?.result?.outcome && run.result.outcome !== 'healthy') {
    reasons.push(`canary:${run.result.failure_class || 'failed'}`);
  }
  if (!run || run.up !== 1) reasons.push('gateway_down');

  for (const model of run?.models || []) {
    const id = model.model || '<unknown>';
    if (model.serviceable !== 1) {
      reasons.push(`${id}:unserviceable`);
      continue;
    }
    const outcomes = model.outcomes;
    if (!outcomes || typeof outcomes !== 'object' || Array.isArray(outcomes)) {
      reasons.push(`${id}:request_outcome_signal_missing`);
    } else {
      const counts = Object.entries(outcomes);
      const validCounts = counts.every(([, count]) => Number.isInteger(count) && count >= 0);
      const total = validCounts ? counts.reduce((sum, [, count]) => sum + count, 0) : 0;
      if (!validCounts || total < 1) {
        reasons.push(`${id}:request_outcome_signal_missing`);
      } else {
        const failed = counts.reduce((sum, [outcome, count]) => sum + (outcome === '2xx' ? 0 : count), 0);
        if (failed > 0) {
          reasons.push(`${id}:failed_requests_${failed}_gt_0`);
        }
      }
    }
    if (!model.ttft_ms || model.ttft_ms.n < 1 || model.ttft_ms.p95 == null) {
      reasons.push(`${id}:ttft_signal_missing`);
    } else if (!livenessOnly && model.ttft_ms.n < limits.minTtftSamples) {
      reasons.push(`${id}:ttft_samples_${model.ttft_ms.n}_lt_${limits.minTtftSamples}`);
    } else if (!livenessOnly && !baselineQualified && model.ttft_ms.p95 > limits.maxTtftP95Ms) {
      reasons.push(`${id}:ttft_p95_${round(model.ttft_ms.p95)}ms_gt_${limits.maxTtftP95Ms}ms`);
    }
    if (livenessOnly) continue;
    if (!model.decode_tps || model.decode_tps.n < 1 || model.decode_tps.p50 == null) {
      reasons.push(`${id}:decode_tps_signal_missing`);
    } else if (model.decode_tps.n < limits.minTpsSamples) {
      reasons.push(`${id}:decode_tps_samples_${model.decode_tps.n}_lt_${limits.minTpsSamples}`);
    } else if (!baselineQualified && model.decode_tps.p50 < limits.minDecodeTpsP50) {
      reasons.push(`${id}:decode_tps_p50_${round(model.decode_tps.p50)}_lt_${limits.minDecodeTpsP50}`);
    }
    if (model.cached_prompt_ratio == null) {
      reasons.push(`${id}:cache_signal_missing`);
    } else if (model.cached_prompt_ratio < limits.minCachedPromptRatio) {
      reasons.push(`${id}:cache_ratio_${round(model.cached_prompt_ratio, 4)}_lt_${limits.minCachedPromptRatio}`);
    }
  }
  if (run?.up === 1 && (!Array.isArray(run.models) || run.models.length === 0)) {
    reasons.push('no_models_probed');
  }
  return reasons;
}

async function pushMetrics(text) {
  const url = `${CONFIG.pushgateway.replace(/\/$/, '')}/metrics/job/${encodeURIComponent(CONFIG.pushJob)}`;
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain' },
    body: text,
    redirect: 'manual',
    signal: AbortSignal.timeout(15000),
  });
  if (!r.ok) throw new Error(`pushgateway HTTP ${r.status}`);
}

// ── main ─────────────────────────────────────────────────────────────────────

async function loadBaselines() {
  if (!CONFIG.baselineFile) return [];
  const fs = await import('node:fs/promises');
  let parsed;
  try {
    parsed = JSON.parse(await fs.readFile(CONFIG.baselineFile, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read CANARY_BASELINE_FILE: ${error.message || error}`);
  }
  return validateBaselineDocument(parsed);
}

async function loadExpectedFleet() {
  const fs = await import('node:fs/promises');
  let parsed;
  try {
    parsed = JSON.parse(await fs.readFile(CONFIG.expectedFleetFile, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read CANARY_EXPECTED_FLEET_FILE: ${error.message || error}`);
  }
  return validateExpectedFleetDocument(parsed, {
    expectedProviderCount: CONFIG.mode === 'qualification'
      ? CONFIG.expectedProviderCount || null
      : null,
    minProviderCount: CONFIG.mode === 'qualification'
      ? CONFIG.minReadyProviders
      : 1,
    requireUniqueModels: CONFIG.mode === 'qualification',
  });
}

function liveReadyFleet(observed) {
  const seen = new Set();
  const rows = [];
  for (const row of observed?.operator_pool || []) {
    if (row?.state !== 'ready' || row?.routing_eligible !== true) continue;
    if (typeof row.provider_id !== 'string' || !row.provider_id) continue;
    if (typeof row.model_id !== 'string' || !row.model_id) continue;
    if (seen.has(row.provider_id)) continue;
    seen.add(row.provider_id);
    rows.push({ provider_id: row.provider_id, model_id: row.model_id });
  }
  return rows.sort((a, b) => a.provider_id.localeCompare(b.provider_id));
}

function malformedLiveReadyFleetReasons(observed) {
  const reasons = [];
  const seen = new Set();
  for (const [index, row] of (observed?.operator_pool || []).entries()) {
    if (row?.state !== 'ready' || row?.routing_eligible !== true) continue;
    const providerID = row.provider_id;
    if (typeof providerID !== 'string' || !providerID) {
      reasons.push(`live_ready_provider_${index}:provider_id_missing`);
      continue;
    }
    if (seen.has(providerID)) {
      reasons.push(`${providerID}:live_ready_provider_duplicate`);
    }
    seen.add(providerID);
    if (typeof row.model_id !== 'string' || !row.model_id) {
      reasons.push(`${providerID}:live_ready_model_id_missing`);
    }
  }
  return reasons;
}

export function liveFleetModels(fleet) {
  return [...new Set((fleet || [])
    .map((row) => row?.model_id)
    .filter((modelID) => typeof modelID === 'string' && modelID))]
    .sort();
}

function liveFleetGatewayModelReasons(gateway, modelIDs, {
  activeModelID = '',
} = {}) {
  const models = new Map((gateway?.models || []).map((model) => [model?.id, model]));
  const reasons = [];
  for (const modelID of modelIDs) {
    const model = models.get(modelID);
    if (!model) {
      if (modelID === activeModelID) continue;
      reasons.push(`${modelID}:live_model_missing_from_gateway`);
      continue;
    }
    if (model.available !== true || model.degraded === true) {
      reasons.push(`${modelID}:live_model_not_available`);
    }
    if (!Number.isInteger(model.ready_provider_count) || model.ready_provider_count < 1) {
      reasons.push(`${modelID}:live_model_ready_provider_count_missing`);
    }
  }
  return reasons;
}

function rollbackAuthorizationFleet(legacyRollbackProviders) {
  if (!legacyRollbackProviders?.size) return [];
  return [...legacyRollbackProviders.entries()]
    .map(([providerID, row]) => ({
      provider_id: row.provider_id || providerID,
      model_id: row.model_id,
    }))
    .sort((a, b) => a.provider_id.localeCompare(b.provider_id));
}

function mergeFleetByProviderID(...fleets) {
  const byID = new Map();
  for (const fleet of fleets) {
    for (const row of fleet || []) {
      if (!row?.provider_id || byID.has(row.provider_id)) continue;
      byID.set(row.provider_id, {
        provider_id: row.provider_id,
        model_id: row.model_id,
      });
    }
  }
  return [...byID.values()].sort((a, b) => a.provider_id.localeCompare(b.provider_id));
}

function minimumReadyProviders(staticFleet, fleetSize) {
  return staticFleet
    ? Math.max(CONFIG.minReadyProviders, fleetSize)
    : Math.max(1, fleetSize);
}

export function ensureLivenessBudgetCapacity(budget, modelCount) {
  if (CONFIG.mode !== 'liveness' || modelCount < 1) return;
  budget.ensureMinimumCapacity({
    maxRequests: Math.max(CONFIG.maxRequestsPerProvider, modelCount),
    maxCompletionTokens: Math.max(
      CONFIG.maxCompletionTokensPerProvider,
      modelCount * LIVENESS_MAX_TOKENS_PER_MODEL,
    ),
  });
}

export function runtimeProtectedFleet(initial, expectedFleet, legacyRollbackProviders) {
  if (legacyRollbackProviders?.size) {
    return rollbackAuthorizationFleet(legacyRollbackProviders);
  }
  return CONFIG.mode === 'qualification' ? expectedFleet : liveReadyFleet(initial);
}

export function responseAttributionFleet(initial, observations, expectedFleet, legacyRollbackProviders) {
  const protectedFleet = runtimeProtectedFleet(initial, expectedFleet, legacyRollbackProviders);
  if (CONFIG.mode === 'qualification' || legacyRollbackProviders?.size) return protectedFleet;
  return mergeFleetByProviderID(protectedFleet, liveReadyFleet(observations?.at(-1) || initial));
}

function classifySignalReasons(reasons) {
  const joined = reasons.join(' ');
  if (/thermal/.test(joined)) return 'thermal_regression';
  if (/memory/.test(joined)) return 'memory_regression';
  if (/heartbeat|activity|connection_changed|provider_disappeared|coordinator_disconnected/.test(joined)) {
    return 'heartbeat_regression';
  }
  return 'provider_state_regression';
}

export function observerFailureClass(error, timeReason = null) {
  if (timeReason) return 'budget_exhausted';
  return /\bHTTP (?:401|403)\b/.test(String(error))
    ? 'authentication_failure'
    : 'safety_observer_failure';
}

export async function pollPostRequestRecovery({
  observe,
  strictReasons,
  transientReasons,
  maxWaitMs,
  pollMs,
  now = Date.now,
  wait = sleep,
}) {
  const deadline = now() + maxWaitMs;
  while (true) {
    const observed = await observe();
    const strict = strictReasons(observed);
    if (!strict.length) return { observed, reasons: [], timedOut: false };
    if (transientReasons(observed).length) {
      return { observed, reasons: strict, timedOut: false };
    }
    const remainingMs = deadline - now();
    if (remainingMs <= 0) {
      return {
        observed,
        reasons: ['post_request_heartbeat_recovery_timeout', ...strict],
        timedOut: true,
      };
    }
    await wait(Math.min(pollMs, remainingMs));
  }
}

function expectedPoolRows(poolRows, expectedFleet) {
  const ids = new Set(expectedFleet.map((row) => row.provider_id));
  return poolRows.filter((row) => ids.has(row.provider_id));
}

function activeExpectedProviderID(observed, expectedFleet, activeModelID, {
  qualification = false,
  activeProviderIDHint = '',
} = {}) {
  if (!activeModelID) return '';
  if (qualification) return CONFIG.isolatedProviderID;
  const candidateIDs = new Set(
    expectedFleet
      .filter((row) => row.model_id === activeModelID)
      .map((row) => row.provider_id),
  );
  if (!candidateIDs.size) return '';
  if (activeProviderIDHint && candidateIDs.has(activeProviderIDHint)) return activeProviderIDHint;
  const busy = (observed.operator_pool || []).filter((row) => candidateIDs.has(row.provider_id)
    && row.state === 'busy'
    && row.routing_eligible === false);
  if (busy.length === 1) return busy[0].provider_id;
  return candidateIDs.size === 1 ? [...candidateIDs][0] : '';
}

function isLegacyBridgeProviderSignalSubstitute(row, expected) {
  return row?.provider_id === expected.provider_id
    && row?.model_id === expected.model_id
    && row?.catalog_admission_mode === 'legacy_bridge'
    && /^[vV]?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(row?.binary_version || '');
}

function isLegacyRollbackProviderSignalSubstitute(
  row,
  expected,
  authorizedProviders,
  nowMs,
  activeProviderID,
) {
  const authorization = authorizedProviders?.get(expected.provider_id);
  const routingAllowed = row?.routing_eligible === true
    || (row?.provider_id === activeProviderID
      && row?.state === 'busy'
      && row?.routing_eligible === false);
  return authorization?.model_id === expected.model_id
    && Number.isFinite(authorization?.expires_at_ms)
    && nowMs < authorization.expires_at_ms
    && row?.provider_id === expected.provider_id
    && typeof row?.assigned_id === 'string'
    && row.assigned_id.length > 0
    && row?.model_id === expected.model_id
    && Number.isFinite(row?.connected_at_ms)
    && routingAllowed
    && row?.catalog_admission_mode == null
    && row?.binary_version === authorization.binary_version;
}

function legacyRollbackRowAuthorized(row, expected, authorizedProviders, nowMs) {
  const authorization = authorizedProviders?.get(expected?.provider_id || '');
  return authorization?.model_id === expected?.model_id
    && Number.isFinite(authorization?.expires_at_ms)
    && nowMs < authorization.expires_at_ms
    && row?.provider_id === expected.provider_id
    && typeof row?.assigned_id === 'string'
    && row.assigned_id.length > 0
    && row?.model_id === expected.model_id
    && Number.isFinite(row?.connected_at_ms)
    && row?.catalog_admission_mode == null
    && row?.binary_version === authorization.binary_version;
}

function hasDuplicateProviderIDs(rows) {
  const seen = new Set();
  for (const row of rows) {
    const providerID = row?.provider_id;
    if (typeof providerID !== 'string' || providerID.length === 0) continue;
    if (seen.has(providerID)) return true;
    seen.add(providerID);
  }
  return false;
}

function legacyIdleDuplicateDropAllowance(
  observations,
  expectedFleet,
  legacyRollbackProviders,
  heartbeatAdvanceProviderIDs,
  nowMs,
) {
  const empty = { providerIDs: new Set(), byModel: new Map(), count: 0 };
  if (!legacyRollbackProviders?.size || !heartbeatAdvanceProviderIDs) return empty;
  const observedList = Array.isArray(observations) ? observations.filter(Boolean) : [observations].filter(Boolean);
  if (!observedList.length) return empty;
  const expectedByID = new Map(expectedFleet.map((row) => [row.provider_id, row]));
  const providerIDs = new Set();
  for (const observed of observedList) {
    const rows = Array.isArray(observed?.operator_pool) ? observed.operator_pool : [];
    if (hasDuplicateProviderIDs(rows)) return empty;
    if (hasDuplicateProviderIDs(Array.isArray(observed?.providers) ? observed.providers : [])) return empty;
    const currentByID = new Map(rows.map((row) => [row.provider_id, row]));
    for (const expected of expectedFleet) {
      const id = expected.provider_id;
      if (heartbeatAdvanceProviderIDs.has(id) || !legacyRollbackProviders.has(id)) continue;
      const authorization = legacyRollbackProviders.get(id);
      const idAuthorized = authorization?.model_id === expected.model_id
        && Number.isFinite(authorization?.expires_at_ms)
        && nowMs < authorization.expires_at_ms;
      if (!idAuthorized) continue;
      const row = currentByID.get(id);
      const rowAuthorized = row && legacyRollbackRowAuthorized(row, expected, legacyRollbackProviders, nowMs);
      if (row && !rowAuthorized) continue;
      const rowReady = row
        && rowAuthorized
        && row.state === 'ready'
        && row.routing_eligible === true
        && Number.isFinite(row.heartbeat_age_ms)
        && row.heartbeat_age_ms <= CONFIG.maxHeartbeatAgeMs;
      if (rowReady) continue;
      const substituteReady = rows.some((candidate) => {
        if (!candidate?.provider_id || candidate.provider_id === id) return false;
        const candidateExpected = expectedByID.get(candidate.provider_id);
        if (!candidateExpected || candidateExpected.model_id !== expected.model_id) return false;
        return legacyRollbackRowAuthorized(candidate, candidateExpected, legacyRollbackProviders, nowMs)
          && candidate.state === 'ready'
          && candidate.routing_eligible === true
          && Number.isFinite(candidate.heartbeat_age_ms)
          && candidate.heartbeat_age_ms <= CONFIG.maxHeartbeatAgeMs;
      });
      if (substituteReady) providerIDs.add(id);
    }
	  }
	  if (providerIDs.size !== 1) return empty;
	  const byModel = new Map();
  for (const id of providerIDs) {
    const model = expectedByID.get(id)?.model_id || '';
    if (model) byModel.set(model, (byModel.get(model) || 0) + 1);
  }
  return { providerIDs, byModel, count: providerIDs.size };
}

function filterLegacyIdleDuplicateRecoveryReasons(reasons, {
  observations,
  expectedFleet,
  legacyRollbackProviders,
  heartbeatAdvanceProviderIDs,
  nowMs,
}) {
  const allowance = legacyIdleDuplicateDropAllowance(
    observations,
    expectedFleet,
    legacyRollbackProviders,
    heartbeatAdvanceProviderIDs,
    nowMs,
  );
  if (!allowance.count) return reasons;
  return reasons.filter((reason) => !legacyIdleDuplicateReasonAllowed(reason, allowance));
}

function legacyIdleDuplicateReasonAllowed(reason, allowance) {
  const unscopedReason = reason.replace(/^(?:sample_\d+|final|recovery_final|recovery_soak):/, '');
  for (const id of allowance.providerIDs) {
    if (!unscopedReason.startsWith(`${id}:`)) continue;
    const suffix = unscopedReason.slice(id.length + 1);
    if (
      suffix === 'expected_provider_not_ready'
      || suffix === 'expected_provider_missing'
      || suffix === 'heartbeat_signal_missing'
      || suffix === 'provider_signal_missing'
      || suffix === 'provider_disappeared'
      || /^state_[^:]+_not_ready$/.test(suffix)
      || /^heartbeat_stale_\d+(?:\.\d+)?ms_gt_\d+ms$/.test(suffix)
      || /^telemetry_observation_stale_\d+ms_gt_\d+ms$/.test(suffix)
      || /^provider_state_[^:]+_not_allowed$/.test(suffix)
      || suffix === 'coordinator_disconnected'
    ) {
      return true;
    }
  }
	  let match = unscopedReason.match(/^ready_(\d+)_lt_(\d+)$/);
	  if (match && Number(match[2]) - Number(match[1]) >= 1
	      && Number(match[2]) - Number(match[1]) <= allowance.count) return true;
	  match = unscopedReason.match(/^pool_unavailable_(\d+)_ne_0$/);
	  if (match && Number(match[1]) <= allowance.count) return true;
	  match = unscopedReason.match(/^ready_changed_(\d+)_to_(\d+)$/);
	  if (match && Number(match[1]) - Number(match[2]) >= 1
	      && Number(match[1]) - Number(match[2]) <= allowance.count) return true;
	  match = unscopedReason.match(/^total_providers_changed_(\d+)_to_(\d+)$/);
	  if (match && Number(match[1]) - Number(match[2]) >= 1
	      && Number(match[1]) - Number(match[2]) <= allowance.count) return true;
	  match = unscopedReason.match(/^provider_count_changed_(\d+)_to_(\d+)$/);
	  if (match && Number(match[1]) - Number(match[2]) >= 1
	      && Number(match[1]) - Number(match[2]) <= allowance.count) return true;
	  match = unscopedReason.match(/^provider_signal_count_(\d+)_ne_(\d+)$/);
	  if (match && Number(match[2]) - Number(match[1]) >= 1
	      && Number(match[2]) - Number(match[1]) <= allowance.count) return true;
	  match = unscopedReason.match(/^(.*):ready_provider_count_changed_(\d+)_to_(\d+)$/);
	  if (match) {
	    const allowedLoss = allowance.byModel.get(match[1]) || 0;
	    if (Number(match[2]) - Number(match[3]) >= 1
	        && Number(match[2]) - Number(match[3]) <= allowedLoss) return true;
	  }
  return false;
}

function hasDirectProviderSignal(signal) {
  return Object.entries(signal || {}).some(
    ([field, value]) => field !== 'source' && value != null,
  );
}

function directProviderSignalIdentityReasons(providers, expectedFleet, {
  allowUnexpectedProviders = false,
} = {}) {
  const expectedIDs = new Set(expectedFleet.map((row) => row.provider_id));
  const seen = new Set();
  const reasons = [];
  for (const [index, signal] of providers.entries()) {
    if (!hasDirectProviderSignal(signal)) continue;
    const providerID = signal?.provider_id;
    if (typeof providerID !== 'string' || providerID.length === 0) {
      reasons.push(`provider_signal_identity_missing_${index}`);
      continue;
    }
    if (!allowUnexpectedProviders && !expectedIDs.has(providerID)) {
      reasons.push(`provider_signal_unexpected_${providerID}`);
    }
    if (seen.has(providerID)) {
      reasons.push(`provider_signal_duplicate_${providerID}`);
    }
    seen.add(providerID);
  }
  return reasons;
}

function recoveryProviderSignals(
  observation,
  expectedFleet,
  authorizedProviders,
  nowMs,
  allowLegacyBridgeProviderSignals = false,
  restrictDirectSignalsToExpectedFleet = false,
) {
  const expectedByID = new Map(expectedFleet.map((row) => [row.provider_id, row]));
  const operatorPool = Array.isArray(observation?.operator_pool) ? observation.operator_pool : [];
  const providers = Array.isArray(observation?.providers) ? observation.providers : [];
  return providers.filter((signal, index) => {
    if (hasDirectProviderSignal(signal)) {
      return !restrictDirectSignalsToExpectedFleet || expectedByID.has(signal?.provider_id);
    }
    const poolRow = operatorPool[index];
    const expected = expectedByID.get(poolRow?.provider_id);
    const exactReadyLegacyBridge = expected
      && allowLegacyBridgeProviderSignals
      && poolRow?.state === 'ready'
      && poolRow?.routing_eligible === true
      && isLegacyBridgeProviderSignalSubstitute(poolRow, expected);
    const exactReadyLegacyRollback = expected
      && poolRow?.state === 'ready'
      && isLegacyRollbackProviderSignalSubstitute(
        poolRow,
        expected,
        authorizedProviders,
        nowMs,
        '',
      );
    return !(exactReadyLegacyBridge || exactReadyLegacyRollback);
  });
}

export function recoverySoakObservationReasons(
  initial,
  samples,
  expectedFleet,
  legacyRollbackProviders,
  options = {},
  nowMs = Date.now(),
) {
  const {
    allowLegacyBridgeProviderSignals = false,
    ...soakOptions
  } = options;
  const staticFleet = CONFIG.mode === 'qualification' || Boolean(legacyRollbackProviders?.size);
  const safetyFleet = runtimeProtectedFleet(initial, expectedFleet, legacyRollbackProviders);
  if (!staticFleet) {
    return recoverySoakReasons({
      gatewayInitial: initial.gateway,
      gatewaySamples: samples.map((sample) => sample.gateway),
      poolzInitial: expectedPoolRows(initial.operator_pool || [], safetyFleet),
      poolzSamples: samples.map(
        (sample) => expectedPoolRows(sample.operator_pool || [], safetyFleet),
      ),
      providerInitial: recoveryProviderSignals(
        initial,
        safetyFleet,
        null,
        nowMs,
        allowLegacyBridgeProviderSignals,
        true,
      ),
      providerSamples: samples.map(
        (sample) => recoveryProviderSignals(
          sample,
          safetyFleet,
          null,
          nowMs,
          allowLegacyBridgeProviderSignals,
          true,
        ),
      ),
    }, {
      ...soakOptions,
      enforceHealthyProviderAggregates: false,
      enforceStableProviderCounts: false,
      enforceStableModelSet: true,
      allowedStableModelIDs: new Set(safetyFleet.map((row) => row.model_id)),
    });
  }
  const reasons = recoverySoakReasons({
    gatewayInitial: initial.gateway,
    gatewaySamples: samples.map((sample) => sample.gateway),
    poolzInitial: expectedPoolRows(initial.operator_pool, safetyFleet),
    poolzSamples: samples.map(
      (sample) => expectedPoolRows(sample.operator_pool || [], safetyFleet),
    ),
    providerInitial: recoveryProviderSignals(
      initial,
      safetyFleet,
      legacyRollbackProviders,
      nowMs,
      allowLegacyBridgeProviderSignals,
    ),
    providerSamples: samples.map(
      (sample) => recoveryProviderSignals(
        sample,
        safetyFleet,
        legacyRollbackProviders,
        nowMs,
        allowLegacyBridgeProviderSignals,
      ),
    ),
  }, soakOptions);
  for (const [index, sample] of samples.entries()) {
    reasons.push(...directProviderSignalIdentityReasons(
      Array.isArray(sample?.providers) ? sample.providers : [],
      safetyFleet,
    ).map((reason) => `sample_${index + 1}:${reason}`));
  }
  return filterLegacyIdleDuplicateRecoveryReasons(reasons, {
    observations: samples,
    expectedFleet: safetyFleet,
    legacyRollbackProviders,
    heartbeatAdvanceProviderIDs: soakOptions.heartbeatAdvanceProviderIDs || null,
    nowMs,
  });
}

export function validateLegacyRollbackAuthorization(document, expectedFleetOrNowMs = Date.now(), maybeNowMs = null) {
  const nowMs = Number.isFinite(expectedFleetOrNowMs)
    ? expectedFleetOrNowMs
    : (Number.isFinite(maybeNowMs) ? maybeNowMs : Date.now());
  const exactKeys = (value, expected) => value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join('\u0000') === [...expected].sort().join('\u0000');
  if (!exactKeys(document, ['schema_version', 'kind', 'authority', 'transaction_id', 'expires_at', 'providers'])
      || document.schema_version !== 1
      || document.kind !== 'legacy_rollback'
      || document.authority !== LEGACY_ROLLBACK_AUTHORITY
      || typeof document.transaction_id !== 'string'
      || !/^[0-9a-f]{64}$/.test(document.transaction_id)
      || typeof document.expires_at !== 'string'
      || !Array.isArray(document.providers)) {
    throw new Error('legacy rollback authorization envelope is invalid');
  }
  const expiresAtMs = Date.parse(document.expires_at);
  if (!Number.isFinite(expiresAtMs) || expiresAtMs <= nowMs
      || expiresAtMs > nowMs + LEGACY_ROLLBACK_MAX_VALIDITY_MS) {
    throw new Error('legacy rollback authorization expiry is invalid');
  }
  if (document.providers.length < 1 || document.providers.length > LEGACY_ROLLBACK_MAX_PROVIDERS) {
    throw new Error('legacy rollback authorization fleet size is invalid');
  }
  const authorized = new Map();
  for (const row of document.providers) {
    if (!exactKeys(row, ['provider_id', 'model_id', 'binary_version'])
        || typeof row.provider_id !== 'string'
        || typeof row.model_id !== 'string'
        || typeof row.binary_version !== 'string'
        || !row.provider_id
        || row.provider_id.length > 256
        || !row.model_id
        || !/^[vV]?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(row.binary_version)
        || authorized.has(row.provider_id)) {
      throw new Error('legacy rollback authorization provider row is invalid');
    }
    authorized.set(row.provider_id, {
      provider_id: row.provider_id,
      model_id: row.model_id,
      binary_version: row.binary_version,
      expires_at_ms: expiresAtMs,
    });
  }
  return authorized;
}

async function loadLegacyRollbackAuthorization() {
  const path = CONFIG.legacyRollbackAuthorizationFile;
  if (!path) return null;
  const fs = await import('node:fs/promises');
  let info;
  try {
    info = await fs.lstat(path);
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
  const parentInfo = await fs.lstat(dirname(path));
  if (!info.isFile() || info.isSymbolicLink() || info.uid !== 0 || info.nlink !== 1
      || (info.mode & 0o777) !== 0o644 || info.size < 2 || info.size > 4096
      || !parentInfo.isDirectory() || parentInfo.isSymbolicLink() || parentInfo.uid !== 0
      || (parentInfo.mode & 0o777) !== 0o755) {
    throw new Error('legacy rollback authorization file is not a trusted root control');
  }
  return validateLegacyRollbackAuthorization(JSON.parse(await fs.readFile(path, 'utf8')));
}

export function safetyObservationReasons(initial, observed, expectedFleet, {
  requireHeartbeatAdvance = false,
  heartbeatAdvanceProviderIDs = null,
  activeModelID = '',
  activeProviderIDHint = '',
  cachedGatewayModelID = '',
  allowLegacyBridgeProviderSignals = false,
  legacyRollbackProviders = null,
  nowMs = Date.now(),
} = {}) {
  const qualification = CONFIG.mode === 'qualification';
  const staticFleet = qualification || Boolean(legacyRollbackProviders?.size);
  const safetyFleet = runtimeProtectedFleet(initial, expectedFleet, legacyRollbackProviders);
  const telemetryFleet = staticFleet
    ? safetyFleet
    : mergeFleetByProviderID(safetyFleet, liveReadyFleet(observed));
  const safetyModelIDs = new Set(safetyFleet.map((row) => row.model_id));
  const legacyRollbackAuthorizationUnknown = Boolean(
    legacyRollbackProviders?.size && safetyFleet.length !== legacyRollbackProviders.size,
  );
  const activeProviderID = activeExpectedProviderID(observed, safetyFleet, activeModelID, {
    qualification,
    activeProviderIDHint,
  });
  const activePoolRow = activeProviderID
    ? (observed.operator_pool || []).find((row) => row.provider_id === activeProviderID)
    : null;
  const activeAggregateLossAllowed = Boolean(activePoolRow
    && activePoolRow.state === 'busy'
    && activePoolRow.routing_eligible === false);
  const activeProviderSignal = activeProviderID
    ? (observed.providers || []).find((provider) => provider.provider_id === activeProviderID)
    : null;
  const recoveredDirectSignals = Boolean(activePoolRow
    && activePoolRow.state === 'ready'
    && activePoolRow.routing_eligible === true
    && activeProviderSignal?.status === 'ready'
    && activeProviderSignal.requests_in_flight === 0
    && activeProviderSignal.requests_queued === 0);
  const gatewayAllowanceModelID = activeAggregateLossAllowed
    ? activeModelID
    : (recoveredDirectSignals ? cachedGatewayModelID : '');
  const reasons = gatewayInvariantReasons(initial.gateway, observed.gateway, {
    minReadyProviders: minimumReadyProviders(staticFleet, safetyFleet.length),
    maxDrainingProviders: qualification ? 1 : 0,
    activeModelID: qualification ? '' : gatewayAllowanceModelID,
    enforceHealthyProviderAggregates: staticFleet,
    enforceStableProviderCounts: staticFleet,
    enforceStableModelSet: staticFleet || !qualification,
    allowedStableModelIDs: staticFleet ? null : safetyModelIDs,
  });
  if (legacyRollbackAuthorizationUnknown) {
    reasons.push('legacy_rollback_authorization_provider_unknown');
  }
  if (!staticFleet) {
    reasons.push(...liveFleetGatewayModelReasons(
      observed.gateway,
      liveFleetModels(telemetryFleet),
      { activeModelID: gatewayAllowanceModelID },
    ));
  }
  if (!staticFleet) {
    reasons.push(...malformedLiveReadyFleetReasons(observed));
  }
  if (!observed.operator_pool) return [...new Set([...reasons, 'operator_pool_signal_missing'])];

  reasons.push(...expectedFleetReasons(observed.operator_pool, safetyFleet, {
    allowedExtraProviderIDs: qualification ? [CONFIG.isolatedProviderID] : [],
    maxHeartbeatAgeMs: CONFIG.maxHeartbeatAgeMs,
    activeProviderID: qualification ? '' : activeProviderID,
    allowUnexpectedProviders: !staticFleet,
  }));
  if (staticFleet) {
    const initialExpected = expectedPoolRows(initial.operator_pool || [], safetyFleet);
    const currentExpected = expectedPoolRows(observed.operator_pool, safetyFleet);
    reasons.push(...poolzInvariantReasons(initialExpected, currentExpected, {
      maxHeartbeatAgeMs: CONFIG.maxHeartbeatAgeMs,
      requireHeartbeatAdvance,
      heartbeatAdvanceProviderIDs,
      activeProviderID: qualification ? '' : activeProviderID,
    }));
  }

  if (qualification) {
    reasons.push(...qualificationIsolationReasons(observed.operator_pool, {
      targetProviderID: CONFIG.isolatedProviderID,
      targetModel: CONFIG.models[0],
      maxHeartbeatAgeMs: CONFIG.maxHeartbeatAgeMs,
      initialPoolRows: initial.operator_pool,
      requireHeartbeatAdvance,
      localProviderSignal: observed.providers[0] || null,
      allowBusy: Boolean(activeProviderID),
    }));
    if (observed.providers.length !== 1) reasons.push(`isolated_provider_signal_count_${observed.providers.length}_ne_1`);
    const current = observed.providers[0];
    const before = initial.providers[0];
    if (current) {
      reasons.push(...providerSignalReasons(before || current, current, {
        maxMemoryGrowthMB: CONFIG.maxMemoryGrowthMB,
        maxMemoryFraction: CONFIG.maxMemoryFraction,
        maxRequestsInFlight: activeProviderID === current.provider_id ? 1 : 0,
        allowedRuntimeStates: activeProviderID === current.provider_id ? ['ready', 'busy'] : ['ready'],
        requireObservationAdvance: requireHeartbeatAdvance,
        requireNominalThermal: true,
      }));
      if (current.provider_id !== CONFIG.isolatedProviderID) {
        reasons.push(`isolated_provider_id_${current.provider_id || 'missing'}_ne_${CONFIG.isolatedProviderID}`);
      }
      if (current.model_id !== CONFIG.models[0]) {
        reasons.push(`isolated_provider_model_${current.model_id || 'missing'}_ne_${CONFIG.models[0]}`);
      }
    }
  } else {
    if (staticFleet && observed.providers.length !== safetyFleet.length) {
      reasons.push(`provider_signal_count_${observed.providers.length}_ne_${safetyFleet.length}`);
    }
    reasons.push(...directProviderSignalIdentityReasons(observed.providers, safetyFleet, {
      allowUnexpectedProviders: !staticFleet,
    }));
    const initialByID = new Map((initial.providers || []).map((provider) => [provider.provider_id, provider]));
    const currentByID = new Map(observed.providers.map((provider) => [provider.provider_id, provider]));
    const currentPoolByID = new Map(observed.operator_pool.map((provider) => [provider.provider_id, provider]));
    for (const expected of telemetryFleet) {
      const current = currentByID.get(expected.provider_id);
      const rollbackAuthorization = legacyRollbackProviders?.get(expected.provider_id);
      if (!current) {
        const poolRow = currentPoolByID.get(expected.provider_id);
        const poolIndex = observed.operator_pool.indexOf(poolRow);
        const poolSlotSignal = poolIndex >= 0 ? observed.providers[poolIndex] : null;
        const directSignalPresent = poolIndex >= 0 && hasDirectProviderSignal(poolSlotSignal);
        const directSignalMissing = poolIndex >= 0 && !directSignalPresent;
        if (allowLegacyBridgeProviderSignals && isLegacyBridgeProviderSignalSubstitute(poolRow, expected)) {
          continue;
        }
        if (directSignalMissing && isLegacyRollbackProviderSignalSubstitute(
          poolRow,
          expected,
          legacyRollbackProviders,
          nowMs,
          activeProviderID,
        )) {
          continue;
        }
        if (directSignalPresent && poolSlotSignal?.provider_id !== expected.provider_id) {
          reasons.push(`${expected.provider_id}:provider_signal_identity_mismatch_${poolSlotSignal?.provider_id || 'missing'}`);
          continue;
        }
        reasons.push(`${expected.provider_id}:provider_signal_missing`);
        continue;
      }
      const before = initialByID.get(expected.provider_id) || current;
      const requireProviderHeartbeatAdvance = requireHeartbeatAdvance
        && (!heartbeatAdvanceProviderIDs || heartbeatAdvanceProviderIDs.has(expected.provider_id));
      reasons.push(...providerSignalReasons(before, current, {
        maxMemoryGrowthMB: CONFIG.maxMemoryGrowthMB,
        maxMemoryFraction: CONFIG.maxMemoryFraction,
        maxRequestsInFlight: activeProviderID === current.provider_id ? 1 : 0,
        allowedRuntimeStates: activeProviderID === current.provider_id ? ['ready', 'busy'] : ['ready'],
        requireObservationAdvance: requireProviderHeartbeatAdvance,
      }));
      if (current.model_id !== expected.model_id) {
        reasons.push(`${expected.provider_id}:telemetry_model_${current.model_id || 'missing'}_ne_${expected.model_id}`);
      }
      if (rollbackAuthorization) {
        const poolRow = currentPoolByID.get(expected.provider_id);
        if (current.binary_version !== rollbackAuthorization.binary_version) {
          reasons.push(`${expected.provider_id}:telemetry_binary_${current.binary_version || 'missing'}_ne_${rollbackAuthorization.binary_version}`);
        }
        if (poolRow?.binary_version !== rollbackAuthorization.binary_version) {
          reasons.push(`${expected.provider_id}:pool_binary_${poolRow?.binary_version || 'missing'}_ne_${rollbackAuthorization.binary_version}`);
        }
      }
    }
  }
  return [...new Set(filterLegacyIdleDuplicateRecoveryReasons(reasons, {
    observations: observed,
    expectedFleet,
    legacyRollbackProviders,
    heartbeatAdvanceProviderIDs,
    nowMs,
  }))];
}

function createControl(initial, baselines, expectedFleet, budget, legacyRollbackProviders) {
  let failure = null;
  const observations = [initial];

  const fail = (failureClass, reasons, phase) => {
    if (failure) return;
    failure = {
      outcome: 'aborted',
      failure_class: failureClass,
      reasons: [...new Set(reasons)],
      phase,
      aborted: true,
    };
  };

  const observationReasons = (observed, options) => safetyObservationReasons(initial, observed, expectedFleet, {
    ...options,
    allowLegacyBridgeProviderSignals: CONFIG.allowLegacyBridgeProviderSignals,
    legacyRollbackProviders,
  });

  const observeAndCheck = async (phase, {
    timeoutMs = CONFIG.reqTimeoutMs,
    activeModelID = '',
    activeProviderIDHint = '',
  } = {}) => {
    if (failure) return null;
    try {
      const observed = await observeSafety(budget, timeoutMs);
      observations.push(observed);
      const reasons = observationReasons(observed, { activeModelID, activeProviderIDHint });
      if (reasons.length) fail(classifySignalReasons(reasons), reasons, phase);
      return observed;
    } catch (error) {
      const timeReason = budget.timeReason();
      const message = redact(error.message || String(error));
      fail(observerFailureClass(message, timeReason), [timeReason || message], phase);
      return null;
    }
  };

  const observeAfterRequest = async (model, activeProviderIDHint = '') => {
    const phase = `after_request_${budget.requests}`;
    try {
      const result = await pollPostRequestRecovery({
        observe: async () => {
          const observed = await observeSafety(budget, CONFIG.safetyObserverTimeoutMs);
          observations.push(observed);
          return observed;
        },
        strictReasons: (observed) => observationReasons(observed, {}),
        transientReasons: (observed) => observationReasons(observed, {
          activeModelID: model,
          activeProviderIDHint,
          cachedGatewayModelID: model,
        }),
        maxWaitMs: Math.min(CONFIG.postRequestRecoveryMs, budget.remainingDurationMs()),
        pollMs: CONFIG.safetyPollMs,
      });
      if (result.reasons.length) {
        const timeReason = budget.timeReason();
        fail(timeReason ? 'budget_exhausted' : classifySignalReasons(result.reasons),
          timeReason ? [timeReason] : result.reasons, phase);
      }
    } catch (error) {
      const timeReason = budget.timeReason();
      const message = redact(error.message || String(error));
      fail(observerFailureClass(message, timeReason), [timeReason || message], phase);
    }
  };

  return {
    async beforeRequest(maxTokens) {
      if (CONFIG.disableFile && existsSync(CONFIG.disableFile)) {
        fail('emergency_disabled', ['disable_sentinel_present'], 'before_request');
        return false;
      }
      await observeAndCheck(`before_request_${budget.requests + 1}`);
      if (failure) return false;
      const reason = budget.reserve(maxTokens);
      if (reason) {
        fail('budget_exhausted', [reason], 'before_request');
        return false;
      }
      return true;
    },
    async afterRequest(model, result, maxTokens, sampleClass) {
      budget.recordProvider(result.provider, maxTokens);
      if (!result.ok) {
        const timeReason = budget.timeReason();
        if (timeReason) {
          fail('budget_exhausted', [timeReason], `request_${budget.requests}`);
          return;
        }
        const bucket = outcomeBucket(result);
        fail(bucket === 'authentication_error' ? 'authentication_failure' : 'request_failure',
          [`${model}:${bucket}`], `request_${budget.requests}`);
        return;
      }
      const identityReasons = responseIdentityReasons(result, model, responseAttributionFleet(
        initial,
        observations,
        expectedFleet,
        legacyRollbackProviders,
      ), {
        expectedProviderID: CONFIG.mode === 'qualification' ? CONFIG.isolatedProviderID : '',
      });
      if (identityReasons.length) {
        fail(CONFIG.mode === 'qualification' ? 'isolation_unproven' : 'response_identity_unproven',
          identityReasons, `request_${budget.requests}`);
        return;
      }
      if (CONFIG.mode === 'qualification') {
        const signal = initial.providers[0] || {};
        const baseline = findBaseline(baselines, model, result.provider, signal.hardware_tier || '', {
          compatibilitySetID: signal.compatibility_set_id || '',
          binaryVersion: signal.binary_version || '',
          modelHash: signal.model_hash || '',
          powerSource: signal.power_source || '',
          thermalCondition: signal.thermal_state || '',
        });
        const reasons = performanceRegressionReasons(result, baseline, sampleClass);
        if (reasons.length) {
          fail(reasons.includes('baseline_unavailable') ? 'baseline_unavailable' : 'performance_regression',
            reasons.map((reason) => `${model}:${result.provider || '<unknown>'}:${reason}`),
            `request_${budget.requests}`);
          return;
        }
      }
      // The coordinator may retain the final busy/non-routable heartbeat for
      // one <=5s interval after the stream completes, while the gateway may
      // retain the active-loss aggregate in its 10s status cache. Permit only
      // that exact correlated shape while polling through the cache TTL plus
      // one poll/observer margin, then require a fully strict snapshot before
      // another request can start.
      await observeAfterRequest(model, result.provider || '');
    },
    async monitorDuringRequest(requestAbort, stopSignal, activeModelID) {
      let sample = 0;
      while (!stopSignal.aborted && !failure) {
        if (!(await sleepInterruptibly(CONFIG.safetyPollMs, stopSignal))) return;
        await observeAndCheck(`during_request_${budget.requests}_${++sample}`, {
          timeoutMs: CONFIG.safetyObserverTimeoutMs,
          activeModelID,
        });
        if (failure) {
          requestAbort.abort();
          return;
        }
      }
    },
    checkCacheMeasurement(model, ratio) {
      if (ratio == null) fail('performance_regression', [`${model}:cache_signal_missing`], `request_${budget.requests}`);
      else if (ratio < CONFIG.minCachedPromptRatio) {
        fail('performance_regression', [`${model}:cache_ratio_${round(ratio, 4)}_lt_${CONFIG.minCachedPromptRatio}`], `request_${budget.requests}`);
      }
    },
    async sleep(ms, phase) {
      const remaining = budget.remainingDurationMs();
      if (remaining <= ms) {
        if (remaining > 0) await sleep(remaining);
        fail('budget_exhausted', [budget.timeReason() || 'hard_deadline_exhausted'], phase);
        return false;
      }
      await sleep(ms);
      return true;
    },
    async observeRaw(phase, options = {}) {
      try {
        const observed = await observeSafety(budget);
        observations.push(observed);
        return { observed, reasons: observationReasons(observed, options), error: null, phase };
      } catch (error) {
        return { observed: null, reasons: [], error: redact(error.message || String(error)), phase };
      }
    },
    requestTimeoutMs() {
      return Math.max(1, Math.min(CONFIG.reqTimeoutMs, budget.remainingDurationMs()));
    },
    failed() {
      return failure != null;
    },
    failure() {
      return failure;
    },
    fail,
    observations,
    observeAndCheck,
  };
}

export function preconditionReasons(
  observed,
  expectedFleet,
  legacyRollbackProviders,
  allowLegacyBridgeProviderSignals = false,
) {
  return safetyObservationReasons(observed, observed, expectedFleet, {
    legacyRollbackProviders,
    allowLegacyBridgeProviderSignals,
  });
}

async function emitRun(run) {
  const prom = redact(toProm(run));
  const runJson = redact(JSON.stringify(run, null, 2));
  console.log(runJson);
  if (CONFIG.metricsOut) {
    await writeAtomic(CONFIG.metricsOut, prom);
    console.error(redact(`wrote metrics → ${CONFIG.metricsOut}`));
  }
  if (CONFIG.jsonOut) {
    const fname = `canary-${run.run_at.replace(/[:.]/g, '-')}.json`;
    const path = await joinPath(CONFIG.jsonOut, fname);
    await writeAtomic(path, runJson + '\n');
    await rotateArtifacts(CONFIG.jsonOut, 200);
    console.error(redact(`wrote artifact → ${path}`));
  }
  if (CONFIG.pushgateway) {
    try {
      await pushMetrics(prom);
      console.error(redact(`pushed metrics → ${CONFIG.pushgateway}`));
    } catch (error) {
      console.error(`WARN: pushgateway failed: ${redact(error.message)}`);
    }
  }
}

async function main() {
  const budget = new RunBudget({
    maxRequests: CONFIG.maxRequestsPerProvider,
    maxCompletionTokens: CONFIG.maxCompletionTokensPerProvider,
    maxDurationMs: CONFIG.maxRunDurationMs,
  });
  const runStartUnix = Math.floor(realUnix());
  if (!['liveness', 'qualification'].includes(CONFIG.mode)) {
    console.error('FAIL: --mode must be liveness or qualification');
    process.exitCode = 2;
    return;
  }
  const required = [];
  if (!CONFIG.poolzURL) required.push('CANARY_POOLZ_URL');
  if (!CONFIG.operatorToken) required.push('CANARY_OPERATOR_TOKEN');
  if (!CONFIG.expectedFleetFile) required.push('CANARY_EXPECTED_FLEET_FILE');
  if (CONFIG.mode === 'liveness' && !CONFIG.token) {
    required.push('MACPROVIDER_BUYER_TOKEN or MALIBU_API_KEY');
  }
  if (CONFIG.mode === 'qualification') {
    if (CONFIG.models.length !== 1) required.push('exactly one CANARY_MODELS value for qualification');
    if (!CONFIG.baselineFile) required.push('CANARY_BASELINE_FILE');
    if (!CONFIG.isolatedProviderBase) required.push('CANARY_ISOLATED_PROVIDER_BASE');
    if (!CONFIG.isolatedProviderID) required.push('CANARY_ISOLATED_PROVIDER_ID');
  }
  if (required.length) {
    console.error(`FAIL: ${CONFIG.mode} requires ${required.join(', ')}`);
    process.exitCode = 2;
    return;
  }
  const cadenceReasons = recoveryCadenceReasons(CONFIG.recoverySoakSeconds, CONFIG.recoveryPollMs);
  if (cadenceReasons.length) {
    console.error(`FAIL: invalid recovery cadence: ${cadenceReasons.join(', ')}`);
    process.exitCode = 2;
    return;
  }
  if (CONFIG.maxMemoryFraction <= 0 || CONFIG.maxMemoryFraction > 1) {
    console.error('FAIL: CANARY_MAX_MEMORY_FRACTION must be greater than 0 and at most 1');
    process.exitCode = 2;
    return;
  }
  let baselines = [];
  let expectedFleet = [];
  let legacyRollbackProviders = null;
  try {
    const baseUrl = parseSafeUrl(`${CONFIG.base}/v1/status`, 'CANARY_BASE');
    await assertResolvesPublic(baseUrl, 'CANARY_BASE');
    if (CONFIG.pushgateway) {
      const pgUrl = parseSafeUrl(CONFIG.pushgateway, 'CANARY_PUSHGATEWAY');
      await assertResolvesPublic(pgUrl, 'CANARY_PUSHGATEWAY');
    }
    const poolzUrl = parseSafeUrl(CONFIG.poolzURL, 'CANARY_POOLZ_URL');
    await assertResolvesPublic(poolzUrl, 'CANARY_POOLZ_URL');
    if (CONFIG.mode === 'qualification') {
      const providerUrl = parseProviderLocalUrl(CONFIG.isolatedProviderBase, 'CANARY_ISOLATED_PROVIDER_BASE');
      await assertResolvesLocal(providerUrl, 'CANARY_ISOLATED_PROVIDER_BASE');
    }
    expectedFleet = await loadExpectedFleet();
    if (CONFIG.mode === 'qualification') {
      const expectedModels = [...new Set(expectedFleet.map((row) => row.model_id))].sort();
      const configuredModels = [...new Set(CONFIG.models)].sort();
      if (configuredModels.length !== CONFIG.models.length) {
        throw new Error('CANARY_MODELS must not contain duplicates');
      }
      if (!expectedModels.includes(CONFIG.models[0])) {
        throw new Error(`CANARY_MODELS value ${CONFIG.models[0]} is absent from CANARY_EXPECTED_FLEET_FILE`);
      }
    }
    if (CONFIG.mode === 'qualification') baselines = await loadBaselines();
    if (CONFIG.mode === 'liveness') {
      legacyRollbackProviders = await loadLegacyRollbackAuthorization();
    }
  } catch (e) {
    console.error(`FAIL: ${redact(e.message)}`);
    process.exitCode = 2;
    return;
  }
  let initial = null;
  let initialFailure = null;
  try {
    initial = await observeSafety(budget);
  } catch (e) {
    const timeReason = budget.timeReason();
    const message = redact(e.message || String(e));
    initialFailure = {
      outcome: 'aborted', failure_class: observerFailureClass(message, timeReason),
      reasons: [timeReason || message], phase: 'precondition', aborted: true,
    };
  }
  if (!initial) {
    const run = buildRun(null, [], runStartUnix, {
      result: initialFailure,
      budget: budget.snapshot(),
      safety: { initial: null, final: null, observation_count: 0, observation_series: [] },
    });
    await emitRun(run);
    console.error(`ABORTED [${initialFailure.failure_class}]: ${initialFailure.reasons.join(', ')}`);
    process.exitCode = 1;
    return;
  }
  const control = createControl(initial, baselines, expectedFleet, budget, legacyRollbackProviders);
  const preReasons = preconditionReasons(
    initial,
    expectedFleet,
    legacyRollbackProviders,
    CONFIG.allowLegacyBridgeProviderSignals,
  );
  if (preReasons.length) {
    const isolationFailure = CONFIG.mode === 'qualification'
      && preReasons.some((reason) => /isolation_|isolated_provider_/.test(reason));
    control.fail(isolationFailure ? 'isolation_unproven' : 'precondition_failed', preReasons, 'precondition');
  }
  const models = CONFIG.mode === 'liveness'
    ? liveFleetModels(runtimeProtectedFleet(initial, expectedFleet, legacyRollbackProviders))
    : CONFIG.models;
  ensureLivenessBudgetCapacity(budget, models.length);
  const results = [];
  for (const model of models) {
    if (control.failed()) break;
    process.stderr.write(redact(`probing ${model} ...\n`));
    const r = await sampleModel(model, control);
    results.push(r);
    const t = r.ttftMs.length ? `ttft_p50=${percentile(r.ttftMs, 50)}ms p95=${percentile(r.ttftMs, 95)}ms` : 'ttft=none';
    const tps = r.decodeTps.length ? `tps_p50=${round(percentile(r.decodeTps, 50))}` : 'tps=none';
    const cache = r.cachedRatio != null ? `cache=${round(r.cachedRatio, 3)}` : 'cache=n/a';
    // redact: a hostile gateway could plant the token in a server-controlled
    // field (model id, provider id, error) that lands in this progress line.
    console.error(
      redact(
        `  ${model}: serviceable=${r.serviceable} ${t} ${tps} ${cache} outcomes=${JSON.stringify(r.outcomes)}${r.firstError ? ` firstErr="${r.firstError}"` : ''}`
      )
    );
  }
  const heartbeatAdvanceProviderIDs = legacyRollbackProviders?.size && budget.providers.size
    ? new Set([...budget.providers.keys()].filter(Boolean))
    : null;
  let post = null;
  const recoverySamples = [];
  const recoveryRecords = [];
  let recoveryFailure = null;
  if (shouldRunRecovery(budget.requests)) {
    const recoveryFleetSize = runtimeProtectedFleet(initial, expectedFleet, legacyRollbackProviders).length;
    const soakDeadline = Date.now() + (CONFIG.recoverySoakSeconds * 1000);
    while (soakDeadline - Date.now() >= CONFIG.recoveryPollMs) {
      const timeReason = budget.timeReason();
      if (timeReason) {
        recoveryRecords.push({ observed: null, reasons: [], error: timeReason, phase: 'recovery_soak' });
        break;
      }
      if (!(await control.sleep(CONFIG.recoveryPollMs, 'recovery_soak'))) {
        recoveryRecords.push({ observed: null, reasons: [], error: budget.timeReason() || 'hard_deadline_exhausted', phase: 'recovery_soak' });
        break;
      }
      const record = await control.observeRaw('recovery_soak', { heartbeatAdvanceProviderIDs });
      recoveryRecords.push(record);
      if (record.observed) {
        post = record.observed;
        recoverySamples.push(record.observed);
      }
    }
    const recoveryReasons = recoveryRecords.flatMap((record) => [
      ...(record.error ? [`${record.phase}:${record.error}`] : []),
      ...record.reasons.map((reason) => `${record.phase}:${reason}`),
    ]);
    recoveryReasons.push(...recoverySoakObservationReasons(
      initial,
      recoverySamples,
      expectedFleet,
      legacyRollbackProviders,
      {
        minReadyProviders: minimumReadyProviders(
          Boolean(legacyRollbackProviders?.size || CONFIG.mode === 'qualification'),
          recoveryFleetSize,
        ),
        maxDrainingProviders: CONFIG.mode === 'qualification' ? 1 : 0,
        maxHeartbeatAgeMs: CONFIG.maxHeartbeatAgeMs,
        maxMemoryGrowthMB: CONFIG.maxMemoryGrowthMB,
        maxMemoryFraction: CONFIG.maxMemoryFraction,
        requireNominalThermal: CONFIG.mode === 'qualification',
        allowLegacyBridgeProviderSignals: CONFIG.allowLegacyBridgeProviderSignals,
        heartbeatAdvanceProviderIDs,
        enforceStableProviderCounts: Boolean(legacyRollbackProviders?.size || CONFIG.mode === 'qualification'),
        enforceStableModelSet: Boolean(legacyRollbackProviders?.size || CONFIG.mode === 'qualification'),
      },
    ));
    const finalRecovery = recoverySamples.at(-1);
    if (finalRecovery) {
      recoveryReasons.push(...safetyObservationReasons(initial, finalRecovery, expectedFleet, {
        requireHeartbeatAdvance: true,
        heartbeatAdvanceProviderIDs,
        allowLegacyBridgeProviderSignals: CONFIG.allowLegacyBridgeProviderSignals,
        legacyRollbackProviders,
      }).map((reason) => `recovery_final:${reason}`));
    }
    if (recoveryReasons.length) {
      recoveryFailure = {
        outcome: 'failed', failure_class: 'recovery_failed',
        reasons: [...new Set(recoveryReasons)], phase: 'recovery_soak', aborted: false,
      };
      if (!control.failed()) control.fail('recovery_failed', recoveryFailure.reasons, 'recovery_soak');
    }
  }
  const result = control.failure() || {
    outcome: 'healthy', failure_class: null, reasons: [], phase: 'complete', aborted: false,
  };
  const run = buildRun(initial.gateway, results, runStartUnix, {
    result,
    budget: budget.snapshot(),
    safety: {
      initial,
      final: recoverySamples.at(-1) || post,
      observation_count: control.observations.length,
      observation_series: control.observations,
      recovery_samples: recoverySamples.length,
      recovery_records: recoveryRecords.map((record) => ({
        phase: record.phase,
        error: record.error,
        reasons: record.reasons,
        observed_at: record.observed?.observed_at || null,
      })),
      recovery_result: recoveryFailure || { outcome: 'healthy', failure_class: null, reasons: [] },
      qualification_isolation: CONFIG.mode === 'qualification' ? {
        method: 'direct_local_provider',
        provider_id: CONFIG.isolatedProviderID,
        model_id: CONFIG.models[0],
      } : null,
    },
  });
  await emitRun(run);
  const reasons = degradedReasons(run, CONFIG);
  if (result.outcome !== 'healthy') {
    console.error(`ABORTED [${result.failure_class}]: ${result.reasons.join(', ')}`);
    process.exitCode = 1;
  } else if (CONFIG.failOnDegraded && reasons.length) {
    console.error(`DEGRADED: ${reasons.join(', ')}`);
    process.exitCode = 1;
  }
}

// realUnix uses Date.now via a tiny indirection so the timestamp is honest even
// though hrtime powers the latency deltas.
function realUnix() {
  return Date.now() / 1000;
}

async function writeAtomic(path, content) {
  const fs = await import('node:fs/promises');
  // Unpredictable temp name + exclusive create (wx) so a pre-planted symlink in
  // a writable output dir can't redirect the write; restrictive mode on create.
  const tmp = `${path}.tmp-${process.pid}-${randUUID()}`;
  await fs.mkdir(dirname(path), { recursive: true }).catch(() => {});
  await fs.writeFile(tmp, content, { flag: 'wx', mode: 0o600 });
  try {
    await fs.rename(tmp, path);
  } catch (e) {
    await fs.unlink(tmp).catch(() => {}); // don't leave a .tmp behind on failure
    throw e;
  }
}
async function joinPath(dir, file) {
  const fs = await import('node:fs/promises');
  await fs.mkdir(dir, { recursive: true }).catch(() => {});
  return dir.replace(/\/$/, '') + '/' + file;
}

// Keep only the newest `keep` canary artifacts. Done in Node (readdir/stat/
// unlink) rather than shell so no filename can be misparsed into a bad delete.
async function rotateArtifacts(dir, keep) {
  const fs = await import('node:fs/promises');
  let names;
  try {
    names = await fs.readdir(dir);
  } catch {
    return;
  }
  const files = names.filter((f) => /^canary-.*\.json$/.test(f));
  if (files.length <= keep) return;
  const stated = [];
  for (const f of files) {
    try {
      const st = await fs.stat(`${dir.replace(/\/$/, '')}/${f}`);
      stated.push({ f, mtime: st.mtimeMs });
    } catch {
      /* skip unstatable entry */
    }
  }
  stated.sort((a, b) => b.mtime - a.mtime);
  for (const { f } of stated.slice(keep)) {
    await fs.unlink(`${dir.replace(/\/$/, '')}/${f}`).catch(() => {});
  }
}
function dirname(p) {
  const i = p.lastIndexOf('/');
  return i <= 0 ? '.' : p.slice(0, i);
}

export function directInvocationDecision(argvPath, modulePath = fileURLToPath(import.meta.url), resolver = realpathSync) {
  if (!argvPath) return false;
  return resolver(argvPath) === modulePath;
}

let invokedAsScript = false;
try {
  invokedAsScript = directInvocationDecision(process.argv[1]);
} catch (error) {
  console.error('FATAL:', redact(`cannot resolve executable path: ${error.message || String(error)}`));
  process.exitCode = 2;
}
if (invokedAsScript) {
  main().catch((e) => {
    console.error('FATAL:', redact(e.message || String(e)));
    process.exit(2);
  });
}
