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

const args = parseArgs(process.argv.slice(2));

const CONFIG = {
  base: (env('CANARY_BASE') || 'https://api.streamvc.live').replace(/\/$/, ''),
  token: env('MACPROVIDER_BUYER_TOKEN') || env('MALIBU_API_KEY') || '',
  models: (env('CANARY_MODELS') || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  ttftSamples: intEnv('CANARY_TTFT_SAMPLES', 12),
  tpsSamples: intEnv('CANARY_TPS_SAMPLES', 3),
  tpsMaxTokens: intEnv('CANARY_TPS_MAX_TOKENS', 128),
  intervalMs: intEnv('CANARY_INTERVAL_MS', 1500),
  reqTimeoutMs: intEnv('CANARY_REQ_TIMEOUT_MS', 45000),
  metricsOut: args['metrics-out'] || env('CANARY_METRICS_OUT') || '',
  jsonOut: args['json-out'] || env('CANARY_JSON_OUT') || '',
  pushgateway: args['pushgateway'] || env('CANARY_PUSHGATEWAY') || '',
  pushJob: args['push-job'] || env('CANARY_PUSH_JOB') || 'canary_buyer',
  failOnDegraded: 'fail-on-degraded' in args,
};

function env(k) {
  return process.env[k] && process.env[k].length ? process.env[k] : '';
}
function intEnv(k, d) {
  const v = parseInt(env(k), 10);
  return Number.isFinite(v) && v > 0 ? v : d;
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
  if (CONFIG.token) s = s.split(CONFIG.token).join('***');
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
  if (!insecure && isPrivateHost(u.hostname)) {
    throw new Error(`${label} points at a private/loopback host (set CANARY_ALLOW_INSECURE=1 to allow)`);
  }
  return u;
}
function isPrivateHost(host) {
  const h = host.toLowerCase().replace(/^\[|\]$/g, '');
  if (h === 'localhost' || h.endsWith('.localhost') || h === '') return true;
  if (h === '::1' || h.startsWith('fc') || h.startsWith('fd') || h.startsWith('fe80')) return true;
  const m = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (m) {
    const a = Number(m[1]);
    const b = Number(m[2]);
    if (a === 127 || a === 10 || a === 0) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
  }
  return false;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getStatus() {
  const ctl = AbortSignal.timeout(CONFIG.reqTimeoutMs);
  const r = await fetch(`${CONFIG.base}/v1/status`, {
    headers: authHeaders({ Accept: 'application/json' }),
    signal: ctl,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(redact(`/v1/status HTTP ${r.status}: ${text.slice(0, 200)}`));
  return JSON.parse(text);
}

/**
 * Stream one chat completion, measuring TTFT and decode-window timing.
 * Never throws on HTTP/stream errors — returns {ok:false, status, error} so
 * the caller can record failures as metrics (recording failures is the point).
 */
async function streamOne({ model, messages, conversationId, maxTokens }) {
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

  try {
    const r = await fetch(`${CONFIG.base}/v1/chat/completions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ model, messages, stream: true, max_tokens: maxTokens }),
      signal: AbortSignal.timeout(CONFIG.reqTimeoutMs),
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
    return { ok: false, status: 0, error: redact(`stream error: ${e.message || e}`), requestId, provider };
  }

  const end = now();
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

async function sampleModel(model) {
  const res = {
    model,
    ttftMs: [],
    decodeTps: [],
    outcomes: {}, // "2xx" | "502" | "5xx" | "timeout" | "empty" | "other"
    samples: 0,
    firstError: '',
    cachedRatio: null,
    cachedPromptTokens: null,
    promptTokens: null,
    provider: '',
  };

  const record = (r) => {
    res.samples++;
    if (r.provider && !res.provider) res.provider = r.provider;
    const bucket = outcomeBucket(r);
    res.outcomes[bucket] = (res.outcomes[bucket] || 0) + 1;
    if (r.ok) {
      res.ttftMs.push(r.ttftMs);
      if (r.decodeTps != null) res.decodeTps.push(r.decodeTps);
    } else if (!res.firstError) {
      res.firstError = `HTTP ${r.status}: ${r.error || ''}`.slice(0, 200);
    }
  };

  // 1. TTFT distribution — many short requests, fresh conversation each.
  for (let i = 0; i < CONFIG.ttftSamples; i++) {
    const r = await streamOne({
      model,
      conversationId: randUUID(),
      messages: [{ role: 'user', content: 'Say: ready.' }],
      maxTokens: 8,
    });
    record(r);
    if (i < CONFIG.ttftSamples - 1) await sleep(CONFIG.intervalMs);
  }

  // 2. Sustained decode TPS — fewer, longer requests.
  for (let i = 0; i < CONFIG.tpsSamples; i++) {
    await sleep(CONFIG.intervalMs);
    const r = await streamOne({
      model,
      conversationId: randUUID(),
      messages: [
        { role: 'user', content: 'Count from 1 to 100, one number per line.' },
      ],
      maxTokens: CONFIG.tpsMaxTokens,
    });
    record(r);
  }

  // 3. Sticky KV-cache reuse — two turns, same conversation tag.
  await sleep(CONFIG.intervalMs);
  const conv = randUUID();
  const t1 = await streamOne({
    model,
    conversationId: conv,
    messages: [{ role: 'user', content: 'Reply with exactly: pong' }],
    maxTokens: 16,
  });
  record(t1);
  if (t1.ok) {
    await sleep(CONFIG.intervalMs);
    const t2 = await streamOne({
      model,
      conversationId: conv,
      messages: [
        { role: 'user', content: 'Reply with exactly: pong' },
        { role: 'assistant', content: t1.content },
        { role: 'user', content: 'Reply with exactly: ping' },
      ],
      maxTokens: 16,
    });
    record(t2);
    if (t2.ok && t2.usage) {
      const cached = numOrNull(t2.usage.cached_prompt_tokens);
      const prompt = numOrNull(t2.usage.prompt_tokens);
      res.cachedPromptTokens = cached;
      res.promptTokens = prompt;
      if (cached != null && prompt != null && prompt > 0) {
        res.cachedRatio = cached / prompt;
      }
    }
  }

  res.serviceable = res.ttftMs.length > 0 ? 1 : 0;
  return res;
}

function outcomeBucket(r) {
  if (r.ok) return '2xx';
  if (r.status === 0) return 'timeout';
  if (r.status === 502) return '502';
  if (r.status === 200) return 'empty';
  if (r.status >= 500) return '5xx';
  return 'other';
}

function numOrNull(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
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

function buildRun(status, modelResults, runStartUnix) {
  return {
    schema_version: 1,
    probe: 'canary_buyer',
    run_at: new Date(runStartUnix * 1000).toISOString(),
    base: CONFIG.base,
    up: status ? 1 : 0,
    pool: status?.pool || null,
    coordinator_status: status?.coordinator?.status || null,
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

  if (run.pool) {
    h('macprovider_canary_pool_providers', 'Providers by pool state from /v1/status.', 'gauge');
    for (const k of ['total_providers', 'ready', 'degraded', 'draining', 'unavailable']) {
      if (run.pool[k] != null) L.push(`macprovider_canary_pool_providers{state="${k}"} ${run.pool[k]}`);
    }
  }

  h('macprovider_canary_model_serviceable', 'A chat completion actually produced a token (1) despite status. Catches status-vs-serviceable divergence.', 'gauge');
  h('macprovider_canary_ttft_ms', 'Time-to-first-token in ms by quantile.', 'gauge');
  h('macprovider_canary_decode_tps', 'Sustained decode tokens/sec (excludes first token/prefill).', 'gauge');
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
    if (m.decode_tps.p50 != null) L.push(`macprovider_canary_decode_tps{${lbl({ ...base, quantile: 'p50' })}} ${round(m.decode_tps.p50)}`);
    if (m.decode_tps.mean != null) L.push(`macprovider_canary_decode_tps{${lbl({ ...base, quantile: 'mean' })}} ${round(m.decode_tps.mean)}`);
    if (m.cached_prompt_ratio != null) L.push(`macprovider_canary_cached_prompt_ratio{${lbl(base)}} ${round(m.cached_prompt_ratio, 4)}`);
  }
  return L.join('\n') + '\n';
}

function round(v, d = 2) {
  const f = Math.pow(10, d);
  return Math.round(v * f) / f;
}

async function pushMetrics(text) {
  const url = `${CONFIG.pushgateway.replace(/\/$/, '')}/metrics/job/${encodeURIComponent(CONFIG.pushJob)}`;
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain' },
    body: text,
    signal: AbortSignal.timeout(15000),
  });
  if (!r.ok) throw new Error(`pushgateway HTTP ${r.status}`);
}

// ── main ─────────────────────────────────────────────────────────────────────

async function main() {
  if (!CONFIG.token) {
    console.error('FAIL: set MACPROVIDER_BUYER_TOKEN or MALIBU_API_KEY');
    process.exit(2);
  }
  try {
    parseSafeUrl(`${CONFIG.base}/v1/status`, 'CANARY_BASE');
    if (CONFIG.pushgateway) parseSafeUrl(CONFIG.pushgateway, 'CANARY_PUSHGATEWAY');
  } catch (e) {
    console.error(`FAIL: ${e.message}`);
    process.exit(2);
  }
  const runStartUnix = Math.floor(realUnix());

  let status = null;
  try {
    status = await getStatus();
  } catch (e) {
    console.error(`WARN: /v1/status failed: ${redact(e.message)}`);
  }

  let models = CONFIG.models;
  if (!models.length) {
    models = (status?.models || []).map((m) => m.id).filter(Boolean);
  }
  if (!models.length) {
    console.error('WARN: no models to probe (status unreachable and CANARY_MODELS unset)');
  }

  const results = [];
  for (const model of models) {
    process.stderr.write(`probing ${model} ...\n`);
    const r = await sampleModel(model);
    results.push(r);
    const t = r.ttftMs.length ? `ttft_p50=${percentile(r.ttftMs, 50)}ms p95=${percentile(r.ttftMs, 95)}ms` : 'ttft=none';
    const tps = r.decodeTps.length ? `tps_p50=${round(percentile(r.decodeTps, 50))}` : 'tps=none';
    const cache = r.cachedRatio != null ? `cache=${round(r.cachedRatio, 3)}` : 'cache=n/a';
    console.error(
      `  ${model}: serviceable=${r.serviceable} ${t} ${tps} ${cache} outcomes=${JSON.stringify(r.outcomes)}${r.firstError ? ` firstErr="${r.firstError}"` : ''}`
    );
  }

  const run = buildRun(status, results, runStartUnix);
  const prom = toProm(run);

  // stdout: the JSON run summary (machine-readable). Diagnostics go to stderr.
  console.log(JSON.stringify(run, null, 2));

  if (CONFIG.metricsOut) {
    await writeAtomic(CONFIG.metricsOut, prom);
    console.error(`wrote metrics → ${CONFIG.metricsOut}`);
  }
  if (CONFIG.jsonOut) {
    const fname = `canary-${run.run_at.replace(/[:.]/g, '-')}.json`;
    const path = await joinPath(CONFIG.jsonOut, fname);
    await writeAtomic(path, JSON.stringify(run, null, 2) + '\n');
    console.error(`wrote artifact → ${path}`);
  }
  if (CONFIG.pushgateway) {
    try {
      await pushMetrics(prom);
      console.error(`pushed metrics → ${CONFIG.pushgateway}`);
    } catch (e) {
      console.error(`WARN: pushgateway failed: ${e.message}`);
    }
  }

  // Exit code policy: 0 by default even on failures (recording is the job, and
  // launchd should not treat a bad-network run as a probe crash). Opt into a
  // non-zero exit for CI/alerting with --fail-on-degraded.
  if (CONFIG.failOnDegraded) {
    const anyUnserviceable = run.up === 0 || run.models.some((m) => !m.serviceable);
    if (anyUnserviceable) {
      console.error('DEGRADED: gateway down or a model unserviceable');
      process.exit(1);
    }
  }
}

// realUnix uses Date.now via a tiny indirection so the timestamp is honest even
// though hrtime powers the latency deltas.
function realUnix() {
  return Date.now() / 1000;
}

async function writeAtomic(path, content) {
  const fs = await import('node:fs/promises');
  const tmp = `${path}.tmp-${process.pid}`;
  await fs.mkdir(dirname(path), { recursive: true }).catch(() => {});
  await fs.writeFile(tmp, content);
  await fs.rename(tmp, path);
}
async function joinPath(dir, file) {
  const fs = await import('node:fs/promises');
  await fs.mkdir(dir, { recursive: true }).catch(() => {});
  return dir.replace(/\/$/, '') + '/' + file;
}
function dirname(p) {
  const i = p.lastIndexOf('/');
  return i <= 0 ? '.' : p.slice(0, i);
}

main().catch((e) => {
  console.error('FATAL:', redact(e.message || String(e)));
  process.exit(2);
});
