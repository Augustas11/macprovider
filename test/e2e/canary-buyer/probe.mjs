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
 * Config (env, all optional except a token):
 *   MACPROVIDER_BUYER_TOKEN | MALIBU_API_KEY   buyer bearer token (required)
 *   CANARY_BASE            gateway base URL (default https://api.streamvc.live)
 *   CANARY_MODELS         comma list of model ids (default: all from /v1/status)
 *   CANARY_TTFT_SAMPLES   short-request samples per model (default 12)
 *   CANARY_TPS_SAMPLES    longer-request samples per model (default 3)
 *   CANARY_TPS_MAX_TOKENS decode window for TPS samples (default 128)
 *   CANARY_INTERVAL_MS    floor gap between samples (default 1500)
 *   CANARY_REQ_TIMEOUT_MS per-request timeout (default 45000)
 */

import net from 'node:net';
import dns from 'node:dns/promises';
import { webcrypto } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  RunBudget,
  findBaseline,
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

// `crypto` is a global on Node 20+ / browsers, but NOT on Node 18 (where it's
// gated behind a flag). Fall back to node:crypto's webcrypto so the probe runs
// on the systemd host's Node 18 as well as newer runtimes.
const crypto = globalThis.crypto ?? webcrypto;

const args = parseArgs(process.argv.slice(2));
const selectedMode = args.mode || env('CANARY_MODE') || 'liveness';
const isQualification = selectedMode === 'qualification';
const configuredTTFTSamples = intEnv('CANARY_TTFT_SAMPLES', 12, 1, 20);
const configuredTPSSamples = intEnv('CANARY_TPS_SAMPLES', 3, 1, 10);

const CONFIG = {
  mode: selectedMode,
  qualificationConfirmed: 'capacity-isolated' in args || env('CANARY_CAPACITY_ISOLATED') === '1',
  base: (env('CANARY_BASE') || 'https://api.streamvc.live').replace(/\/$/, ''),
  token: env('MACPROVIDER_BUYER_TOKEN') || env('MALIBU_API_KEY') || '',
  operatorToken: env('CANARY_OPERATOR_TOKEN') || '',
  poolzURL: env('CANARY_POOLZ_URL'),
  providerStatusURLs: (env('CANARY_PROVIDER_STATUS_URLS') || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  baselineFile: env('CANARY_BASELINE_FILE'),
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
  minReadyProviders: intEnv('CANARY_MIN_READY_PROVIDERS', isQualification ? 2 : 1, 1, 100),
  maxRequestsPerProvider: intEnv('CANARY_MAX_REQUESTS_PER_PROVIDER', isQualification ? 17 : 4, 1, 100),
  maxCompletionTokensPerProvider: intEnv('CANARY_MAX_COMPLETION_TOKENS_PER_PROVIDER', isQualification ? 512 : 32, 1, 4096),
  maxRunDurationMs: intEnv('CANARY_MAX_RUN_DURATION_MS', isQualification ? 300000 : 90000, 10000, 900000),
  recoverySoakSeconds: intEnv('CANARY_RECOVERY_SOAK_SECONDS', isQualification ? 60 : 15, 2, 300),
  recoveryPollMs: intEnv('CANARY_RECOVERY_POLL_MS', 5000, 250, 30000),
  maxHeartbeatAgeMs: intEnv('CANARY_MAX_HEARTBEAT_AGE_MS', 90000, 1000, 300000),
  maxMemoryGrowthMB: intEnv('CANARY_MAX_MEMORY_GROWTH_MB', 512, 1, 65536),
  maxMemoryFraction: numberEnv('CANARY_MAX_MEMORY_FRACTION', 0.9),
  metricsOut: args['metrics-out'] || env('CANARY_METRICS_OUT') || '',
  jsonOut: args['json-out'] || env('CANARY_JSON_OUT') || '',
  pushgateway: args['pushgateway'] || env('CANARY_PUSHGATEWAY') || '',
  pushJob: args['push-job'] || env('CANARY_PUSH_JOB') || 'canary_buyer',
  failOnDegraded: 'fail-on-degraded' in args,
};

function env(k) {
  return process.env[k] && process.env[k].length ? process.env[k] : '';
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

// Validate a URL we are about to send the buyer token to. Require https and
// reject private/loopback/link-local hosts so a bad env/plist/CLI value can't
// exfiltrate the token or perform local-network SSRF. CANARY_ALLOW_INSECURE=1
// opts into http/localhost for local testing against a mock gateway.
function parseSafeUrl(raw, label) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error(`${label} is not a valid URL`);
  }
  const insecure = env('CANARY_ALLOW_INSECURE') === '1';
  if (u.protocol !== 'https:' && !(insecure && u.protocol === 'http:')) {
    throw new Error(`${label} must be https (set CANARY_ALLOW_INSECURE=1 to allow http for local testing)`);
  }
  if (!insecure && isPrivateHostname(u.hostname)) {
    throw new Error(`${label} points at a private/loopback host (set CANARY_ALLOW_INSECURE=1 to allow)`);
  }
  return u;
}

// Resolve the host and reject if it maps to a private address, closing the
// static-misconfiguration / private-DNS SSRF case that a literal-hostname check
// misses. Pure DNS-rebinding (a flip between this check and fetch's own resolve)
// is an inherent limitation of dependency-free fetch and is accepted as a
// residual risk for this operator-run internal tool; `redirect: 'manual'` on the
// token-bearing requests closes the redirect-based variant.
async function assertResolvesPublic(u, label) {
  if (env('CANARY_ALLOW_INSECURE') === '1') return;
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

async function getStatus() {
  const ctl = AbortSignal.timeout(CONFIG.reqTimeoutMs);
  const r = await fetch(`${CONFIG.base}/v1/status`, {
    headers: authHeaders({ Accept: 'application/json' }),
    redirect: 'manual',
    signal: ctl,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(redact(`/v1/status HTTP ${r.status}: ${text.slice(0, 200)}`));
  return JSON.parse(text);
}

async function getJSON(url, { authorization = '', label = url, timeoutMs = CONFIG.reqTimeoutMs } = {}) {
  const headers = { Accept: 'application/json' };
  if (authorization) headers.Authorization = `Bearer ${authorization}`;
  const r = await fetch(url, {
    headers,
    redirect: 'manual',
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(redact(`${label} HTTP ${r.status}: ${text.slice(0, 200)}`));
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${label} returned invalid JSON`);
  }
}

async function observeSafety() {
  const observedAtMs = Date.now();
  const gatewayRaw = await getStatus();
  const gateway = gatewaySnapshot(gatewayRaw);
  let operatorPool = null;
  if (CONFIG.poolzURL) {
    const raw = await getJSON(CONFIG.poolzURL, {
      authorization: CONFIG.operatorToken,
      label: 'CANARY_POOLZ_URL',
    });
    operatorPool = poolzSnapshot(raw, observedAtMs);
  }
  const providers = [];
  for (const url of CONFIG.providerStatusURLs) {
    const raw = await getJSON(url, { label: `provider status ${url}` });
    providers.push(providerSignalSnapshot(raw, url));
  }
  return { observed_at: new Date(observedAtMs).toISOString(), gateway, operator_pool: operatorPool, providers };
}

/**
 * Stream one chat completion, measuring TTFT and decode-window timing.
 * Never throws on HTTP/stream errors — returns {ok:false, status, error} so
 * the caller can record failures as metrics (recording failures is the point).
 */
async function streamOne({ model, messages, conversationId, maxTokens, timeoutMs = CONFIG.reqTimeoutMs }) {
  const headers = authHeaders({
    'Content-Type': 'application/json',
    Accept: 'text/event-stream',
  });
  if (conversationId) headers['X-MacProvider-Conversation'] = conversationId;

  const start = now();
  let firstTokenAt = 0;
  let lastTokenAt = 0;
  let content = '';
  let usage = null;
  let requestId = '';
  let provider = '';
  let streamError = null;

  try {
    const r = await fetch(`${CONFIG.base}/v1/chat/completions`, {
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
      signal: AbortSignal.timeout(timeoutMs),
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
            if (!payload || payload === '[DONE]') continue;
            let obj;
            try {
              obj = JSON.parse(payload);
            } catch {
              continue;
            }
            // A terminal error frame means the completion failed even if content
            // already streamed — don't count it as a healthy sample.
            if (obj?.error) streamError = obj.error;
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
    // Distinguish a request timeout (AbortError from AbortSignal.timeout) from
    // other connect/DNS/TLS/reset failures so the outcome buckets stay honest.
    const kind = e && e.name === 'TimeoutError' ? 'timeout' : 'network_error';
    return { ok: false, status: 0, kind, error: redact(`${kind}: ${e.message || e}`), requestId, provider };
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
      usage,
    };
  }
  if (!firstTokenAt) {
    // 2xx but no content token ever arrived (e.g. empty completion / mid-stream abort).
    return { ok: false, status: 200, error: 'no content token', requestId, provider, usage };
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

  const runRequest = async ({ messages, conversationId, maxTokens, collect = {} }) => {
    if (!(await control.beforeRequest(maxTokens))) return null;
    const r = await streamOne({
      model,
      messages,
      conversationId,
      maxTokens,
      timeoutMs: control.requestTimeoutMs(),
    });
    record(r, collect, maxTokens);
    await control.afterRequest(model, r, maxTokens);
    return r;
  };

  // 1. TTFT distribution — many short requests, fresh conversation each.
  for (let i = 0; i < CONFIG.ttftSamples; i++) {
    const r = await runRequest({
      conversationId: randUUID(),
      messages: [{ role: 'user', content: 'Say: ready.' }],
      maxTokens: 8,
      collect: { ttft: true },
    });
    if (!r || control.failed()) break;
    if (i < CONFIG.ttftSamples - 1) await sleep(CONFIG.intervalMs);
  }

  // Scheduled liveness intentionally stops after one 8-token request per
  // model. Performance, decode, and cache work is qualification-only.
  if (CONFIG.mode === 'liveness' || control.failed()) {
    res.serviceable = (res.outcomes['2xx'] || 0) > 0 ? 1 : 0;
    return res;
  }

  // 2. Sustained decode TPS — fewer, longer requests.
  for (let i = 0; i < CONFIG.tpsSamples; i++) {
    await sleep(CONFIG.intervalMs);
    const r = await runRequest({
      conversationId: randUUID(),
      messages: [
        { role: 'user', content: 'Count from 1 to 100, one number per line.' },
      ],
      maxTokens: CONFIG.tpsMaxTokens,
      collect: { tps: true },
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
  await sleep(CONFIG.intervalMs);
  const conv = randUUID();
  const prefix = stickyPrefix(CONFIG.stickyPrefixLines);
  const t1 = await runRequest({
    conversationId: conv,
    messages: [{ role: 'user', content: `${prefix}\n\nReply with exactly: pong` }],
    maxTokens: 16,
  });
  if (t1?.ok && !control.failed()) {
    await sleep(CONFIG.intervalMs);
    const t2 = await runRequest({
      conversationId: conv,
      messages: [
        { role: 'user', content: `${prefix}\n\nReply with exactly: pong` },
        { role: 'assistant', content: t1.content },
        { role: 'user', content: 'Reply with exactly: ping' },
      ],
      maxTokens: 16,
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
  }

  // Serviceable iff any request across all classes produced a token (a 2xx
  // outcome), not just the TTFT loop — a model that fails short probes but
  // serves long ones is still serving.
  res.serviceable = (res.outcomes['2xx'] || 0) > 0 ? 1 : 0;
  return res;
}

// Buckets: 2xx | 502 | 5xx | timeout | network_error | stream_error | empty | other
function outcomeBucket(r) {
  if (r.ok) return '2xx';
  if (r.kind) return r.kind; // timeout | network_error | stream_error
  if (r.status === 0) return 'network_error';
  if (r.status === 502) return '502';
  if (r.status === 200) return 'empty';
  if (r.status >= 500) return '5xx';
  return 'other';
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

function classifySignalReasons(reasons) {
  const joined = reasons.join(' ');
  if (/thermal/.test(joined)) return 'thermal_regression';
  if (/memory/.test(joined)) return 'memory_regression';
  if (/heartbeat|activity|connection_changed|provider_disappeared|coordinator_disconnected/.test(joined)) {
    return 'heartbeat_regression';
  }
  return 'provider_state_regression';
}

function createControl(initial, baselines, budget) {
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

  const observationReasons = (observed) => {
    const reasons = gatewayInvariantReasons(initial.gateway, observed.gateway, {
      minReadyProviders: CONFIG.minReadyProviders,
    });
    if (initial.operator_pool) {
      if (!observed.operator_pool) reasons.push('operator_pool_signal_missing');
      else reasons.push(...poolzInvariantReasons(initial.operator_pool, observed.operator_pool, {
        maxHeartbeatAgeMs: CONFIG.maxHeartbeatAgeMs,
      }));
    }
    if (initial.providers.length) {
      const byID = new Map(observed.providers.map((provider) => [provider.provider_id, provider]));
      for (const expected of initial.providers) {
        const current = byID.get(expected.provider_id);
        if (!current) reasons.push(`${expected.provider_id}:provider_signal_missing`);
        else reasons.push(...providerSignalReasons(expected, current, {
          maxMemoryGrowthMB: CONFIG.maxMemoryGrowthMB,
          maxMemoryFraction: CONFIG.maxMemoryFraction,
        }));
      }
    }
    return [...new Set(reasons)];
  };

  const observeAndCheck = async (phase) => {
    if (failure) return null;
    try {
      const observed = await observeSafety();
      observations.push(observed);
      const reasons = observationReasons(observed);
      if (reasons.length) fail(classifySignalReasons(reasons), reasons, phase);
      return observed;
    } catch (error) {
      fail('safety_observer_failure', [redact(error.message || String(error))], phase);
      return null;
    }
  };

  return {
    async beforeRequest(maxTokens) {
      const reason = budget.reserve(maxTokens);
      if (reason) {
        fail('budget_exhausted', [reason], 'before_request');
        return false;
      }
      await observeAndCheck(`before_request_${budget.requests}`);
      return !failure;
    },
    async afterRequest(model, result, maxTokens) {
      budget.recordProvider(result.provider, maxTokens);
      if (!result.ok) {
        fail('request_failure', [`${model}:${outcomeBucket(result)}`], `request_${budget.requests}`);
        return;
      }
      if (CONFIG.mode === 'qualification') {
        const baseline = findBaseline(baselines, model, result.provider || '');
        const reasons = performanceRegressionReasons(result, baseline);
        if (reasons.length) {
          fail(reasons.includes('baseline_unavailable') ? 'baseline_unavailable' : 'performance_regression',
            reasons.map((reason) => `${model}:${result.provider || '<unknown>'}:${reason}`),
            `request_${budget.requests}`);
          return;
        }
      }
      await observeAndCheck(`after_request_${budget.requests}`);
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

function preconditionReasons(observed) {
  const reasons = gatewayInvariantReasons(observed.gateway, observed.gateway, {
    minReadyProviders: CONFIG.minReadyProviders,
  });
  if (CONFIG.mode === 'qualification') {
    reasons.push(...poolzInvariantReasons(observed.operator_pool || [], observed.operator_pool || [], {
      maxHeartbeatAgeMs: CONFIG.maxHeartbeatAgeMs,
    }));
    for (const provider of observed.providers) {
      reasons.push(...providerSignalReasons(provider, provider, {
        maxMemoryGrowthMB: CONFIG.maxMemoryGrowthMB,
        maxMemoryFraction: CONFIG.maxMemoryFraction,
      }));
    }
  }
  return [...new Set(reasons)];
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
  if (!CONFIG.token) {
    console.error('FAIL: set MACPROVIDER_BUYER_TOKEN or MALIBU_API_KEY');
    process.exitCode = 2;
    return;
  }
  if (!['liveness', 'qualification'].includes(CONFIG.mode)) {
    console.error('FAIL: --mode must be liveness or qualification');
    process.exitCode = 2;
    return;
  }
  if (CONFIG.maxMemoryFraction <= 0 || CONFIG.maxMemoryFraction > 1) {
    console.error('FAIL: CANARY_MAX_MEMORY_FRACTION must be greater than 0 and at most 1');
    process.exitCode = 2;
    return;
  }
  if (CONFIG.mode === 'qualification') {
    const missing = [];
    if (!CONFIG.qualificationConfirmed) missing.push('--capacity-isolated');
    if (!CONFIG.baselineFile) missing.push('CANARY_BASELINE_FILE');
    if (!CONFIG.poolzURL) missing.push('CANARY_POOLZ_URL');
    if (!CONFIG.operatorToken) missing.push('CANARY_OPERATOR_TOKEN');
    if (!CONFIG.providerStatusURLs.length) missing.push('CANARY_PROVIDER_STATUS_URLS');
    if (missing.length) {
      console.error(`FAIL: qualification requires ${missing.join(', ')}`);
      process.exitCode = 2;
      return;
    }
  }
  let baselines = [];
  try {
    const baseUrl = parseSafeUrl(`${CONFIG.base}/v1/status`, 'CANARY_BASE');
    await assertResolvesPublic(baseUrl, 'CANARY_BASE');
    if (CONFIG.pushgateway) {
      const pgUrl = parseSafeUrl(CONFIG.pushgateway, 'CANARY_PUSHGATEWAY');
      await assertResolvesPublic(pgUrl, 'CANARY_PUSHGATEWAY');
    }
    if (CONFIG.poolzURL) {
      const poolzUrl = parseSafeUrl(CONFIG.poolzURL, 'CANARY_POOLZ_URL');
      await assertResolvesPublic(poolzUrl, 'CANARY_POOLZ_URL');
    }
    for (const raw of CONFIG.providerStatusURLs) {
      const providerUrl = parseSafeUrl(raw, 'CANARY_PROVIDER_STATUS_URLS');
      await assertResolvesPublic(providerUrl, 'CANARY_PROVIDER_STATUS_URLS');
    }
    baselines = await loadBaselines();
  } catch (e) {
    console.error(`FAIL: ${redact(e.message)}`);
    process.exitCode = 2;
    return;
  }
  const runStartUnix = Math.floor(realUnix());
  const budget = new RunBudget({
    maxRequests: CONFIG.maxRequestsPerProvider,
    maxCompletionTokens: CONFIG.maxCompletionTokensPerProvider,
    maxDurationMs: CONFIG.maxRunDurationMs,
  });
  let initial = null;
  let initialFailure = null;
  try {
    initial = await observeSafety();
  } catch (e) {
    initialFailure = {
      outcome: 'aborted', failure_class: 'safety_observer_failure',
      reasons: [redact(e.message || String(e))], phase: 'precondition', aborted: true,
    };
  }
  if (!initial) {
    const run = buildRun(null, [], runStartUnix, {
      result: initialFailure,
      budget: budget.snapshot(),
      safety: { initial: null, final: null, observation_count: 0 },
    });
    await emitRun(run);
    console.error(`ABORTED [${initialFailure.failure_class}]: ${initialFailure.reasons.join(', ')}`);
    process.exitCode = 1;
    return;
  }
  const control = createControl(initial, baselines, budget);
  const preReasons = preconditionReasons(initial);
  if (preReasons.length) control.fail('precondition_failed', preReasons, 'precondition');
  let models = CONFIG.models;
  if (!models.length) {
    models = (initial.gateway.models || []).map((m) => m.id).filter(Boolean);
  }
  if (!models.length) {
    control.fail('precondition_failed', ['no_models_to_probe'], 'precondition');
  }
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
  let post = control.observations.at(-1);
  const recoverySamples = [];
  if (!control.failed()) {
    post = await control.observeAndCheck('postcondition');
  }
  if (!control.failed()) {
    const soakDeadline = Date.now() + (CONFIG.recoverySoakSeconds * 1000);
    while (Date.now() < soakDeadline && !control.failed()) {
      const timeReason = budget.timeReason();
      if (timeReason) {
        control.fail('budget_exhausted', [timeReason], 'recovery_soak');
        break;
      }
      await sleep(Math.min(CONFIG.recoveryPollMs, Math.max(1, soakDeadline - Date.now())));
      const observed = await control.observeAndCheck('recovery_soak');
      if (observed) recoverySamples.push(observed);
    }
  }
  if (!control.failed()) {
    const recoveryReasons = recoverySoakReasons({
      gatewayInitial: initial.gateway,
      gatewaySamples: recoverySamples.map((sample) => sample.gateway),
      poolzInitial: initial.operator_pool,
      poolzSamples: recoverySamples.map((sample) => sample.operator_pool),
      providerInitial: initial.providers,
      providerSamples: recoverySamples.map((sample) => sample.providers),
    }, {
      minReadyProviders: CONFIG.minReadyProviders,
      maxHeartbeatAgeMs: CONFIG.maxHeartbeatAgeMs,
      maxMemoryGrowthMB: CONFIG.maxMemoryGrowthMB,
      maxMemoryFraction: CONFIG.maxMemoryFraction,
    });
    if (recoveryReasons.length) control.fail('recovery_failed', recoveryReasons, 'recovery_soak');
  }
  const result = control.failure() || {
    outcome: 'healthy', failure_class: null, reasons: [], phase: 'complete', aborted: false,
  };
  const run = buildRun(initial.gateway, results, runStartUnix, {
    result,
    budget: budget.snapshot(),
    safety: {
      initial,
      final: post,
      observation_count: control.observations.length,
      recovery_samples: recoverySamples.length,
      qualification_capacity_isolated: CONFIG.mode === 'qualification' ? CONFIG.qualificationConfirmed : null,
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
