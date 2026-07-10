#!/usr/bin/env node
/**
 * Cold/warm TTFT matrix probe — P2 of the 2026-07-09 e2e-testing review.
 *
 * P1 (test/e2e/canary-buyer/) measures steady-state serving quality from the
 * buyer vantage. P2 attacks the one thing P1 doesn't: COLD-START behavior and
 * the latency gates that depend on it.
 *
 * The forcing function (2026-07-09): a cold 30B model load produced a 30,827 ms
 * canary TTFT in prod. The W3 canary `max_ttft_ms` gate had been hand-guessed
 * (3500 → padded to 7000) with no measured basis; tightening it to 3500
 * (calibrated off the *streaming buyer* ~1200 ms TTFT) banned a healthy provider
 * three-in-a-row and 503'd buyers. The fix shipped was to make the latency gates
 * observe-only (PR #513). This probe produces the *real numbers* that let those
 * gates be tightened back to `enforce` safely, per model class.
 *
 * THE CRITICAL SUBTLETY (this is what bit us):
 *   The pool canary sends stream:false (NON-streaming). Its measured "TTFT" is
 *   the full non-streaming round-trip and swings wildly (observed 125 ms …
 *   7000 ms for the SAME healthy provider, depending on relay chunk timing).
 *   The buyer path STREAMS and shows the true first-token latency (~1200 ms
 *   warm). These two numbers are NOT interchangeable. The `max_ttft_ms` gate is
 *   evaluated against the CANARY's non-streaming regime — so it must be
 *   calibrated against THAT, not against the buyer streaming TTFT.
 *
 * This probe measures BOTH regimes side by side, per model class, in three
 * states (warm / cold / post_reboot), and accumulates the samples into an
 * append-only NDJSON store so cold-start percentiles (inherently one sample per
 * cold cycle) can be built up over many real cold/warm cycles. `--build-matrix`
 * then aggregates the store into the matrix (Prometheus textfile + JSON), plus
 * an advisory calibration recommendation for `max_ttft_ms` per model class.
 *
 * Regimes:
 *   buyer_stream     stream:true  — TTFT = time to first CONTENT token (real
 *                                   buyer first-token latency).
 *   canary_nonstream stream:false — "TTFT" = full non-streaming round-trip,
 *                                   faithfully mirroring the coordinator's
 *                                   canaryMetricsFromTiming (canary_probe.go):
 *                                   for a non-streaming response firstTokenAt is
 *                                   zero, so ttft = completedAt - start. This is
 *                                   the exact regime the max_ttft_ms gate sees.
 *
 * States:
 *   warm        provider already loaded; steady-state samples.
 *   cold        the FIRST request after the model was unloaded/idle-evicted.
 *               A cold cycle yields exactly ONE genuinely-cold sample (the first
 *               request warms the model), so this scenario fires a single request
 *               and appends one sample; run it once per externally-induced cold
 *               cycle. Regimes are balanced across cycles automatically.
 *   post_reboot the first request after a full provider process restart (cold
 *               load from disk). Same one-sample-per-cycle discipline.
 *
 * SAFETY (hard-won 2026-07-09 lesson): induce "cold" on a LAB provider, never the
 * prod `mac` provider — churning prod caused an hour-long outage. Do NOT stack
 * coordinator restarts (wedges the CLI's v2 proof-auth, issue #519). This probe
 * NEVER restarts anything itself; the operator induces cold out of band (idle
 * wait / restart the provider CLI / reboot) and then invokes the cold scenario.
 *
 * Zero dependencies (Node >= 18 built-in fetch), matching P1's probe.mjs. The
 * security-critical helpers (redact, SSRF guards, atomic writes) are kept
 * byte-identical to P1 so they can be diffed and share the same audit.
 *
 * Usage:
 *   # warm baseline — N samples per regime, appended to the store
 *   MACPROVIDER_BUYER_TOKEN=mp_... node coldwarm-probe.mjs --scenario warm \
 *     --model qwen3-coder-30b-a3b-instruct --samples 20 --store ./matrix.ndjson
 *
 *   # one cold sample (operator induced cold out of band just before this)
 *   node coldwarm-probe.mjs --scenario cold --state cold \
 *     --model qwen3-coder-30b-a3b-instruct --store ./matrix.ndjson
 *
 *   # after a provider process restart
 *   node coldwarm-probe.mjs --scenario cold --state post_reboot \
 *     --model qwen3-coder-30b-a3b-instruct --store ./matrix.ndjson
 *
 *   # aggregate the accumulated store into the matrix + calibration advice
 *   node coldwarm-probe.mjs --build-matrix --store ./matrix.ndjson \
 *     --metrics-out /var/lib/node_exporter/textfile/coldwarm.prom \
 *     --json-out ./artifacts
 *
 * Config (env, all optional except a token for probing scenarios):
 *   MACPROVIDER_BUYER_TOKEN | MALIBU_API_KEY   buyer bearer token (required to probe)
 *   COLDWARM_BASE          gateway base URL (default https://api.streamvc.live)
 *   COLDWARM_STORE         NDJSON sample store (default ./coldwarm-samples.ndjson)
 *   COLDWARM_SAMPLES       warm samples per regime (default 20)
 *   COLDWARM_TPS_MAX_TOKENS decode window for the warm TPS sample (default 128)
 *   COLDWARM_CANARY_MAX_TOKENS non-streaming canary max_tokens (default 16 — the
 *                          coordinator's canary_max_tokens; keep in sync so the
 *                          canary_nonstream regime matches the gate's regime)
 *   COLDWARM_INTERVAL_MS   floor gap between warm samples (default 1500)
 *   COLDWARM_REQ_TIMEOUT_MS per-request timeout (default 90000 — a cold 30B load
 *                          was observed at ~30–58 s; must not abort a cold load)
 *   COLDWARM_HEADROOM      calibration headroom multiplier over warm p99 (default 1.5)
 *   COLDWARM_MIN_SAMPLES   min samples per cell before a gate is recommended (default 30)
 */

import net from 'node:net';
import dns from 'node:dns/promises';
import { webcrypto } from 'node:crypto';

// `crypto` is a global on Node 20+ / browsers, but NOT on Node 18 (where it's
// gated behind a flag). Fall back to node:crypto's webcrypto so the probe runs
// on the systemd host's Node 18 as well as newer runtimes.
const crypto = globalThis.crypto ?? webcrypto;

const REGIMES = ['buyer_stream', 'canary_nonstream'];
const STATES = ['warm', 'cold', 'post_reboot'];

const args = parseArgs(process.argv.slice(2));

const CONFIG = {
  base: (env('COLDWARM_BASE') || 'https://api.streamvc.live').replace(/\/$/, ''),
  token: env('MACPROVIDER_BUYER_TOKEN') || env('MALIBU_API_KEY') || '',
  store: args['store'] || env('COLDWARM_STORE') || './coldwarm-samples.ndjson',
  samples: intEnv('COLDWARM_SAMPLES', 20),
  tpsMaxTokens: intEnv('COLDWARM_TPS_MAX_TOKENS', 128),
  canaryMaxTokens: intEnv('COLDWARM_CANARY_MAX_TOKENS', 16),
  intervalMs: intEnv('COLDWARM_INTERVAL_MS', 1500),
  reqTimeoutMs: intEnv('COLDWARM_REQ_TIMEOUT_MS', 90000),
  headroom: floatEnv('COLDWARM_HEADROOM', 1.5),
  minSamples: intEnv('COLDWARM_MIN_SAMPLES', 30),
  metricsOut: args['metrics-out'] || env('COLDWARM_METRICS_OUT') || '',
  jsonOut: args['json-out'] || env('COLDWARM_JSON_OUT') || '',
  // scenario / state / regime selection
  scenario: (args['scenario'] || '').toString(),
  state: (args['state'] || '').toString(),
  regime: (args['regime'] || '').toString(),
  model: (args['model'] || env('COLDWARM_MODEL') || '').toString(),
  buildMatrix: 'build-matrix' in args,
  warmFollowup: 'warm-followup' in args,
};

function env(k) {
  return process.env[k] && process.env[k].length ? process.env[k] : '';
}
function intEnv(k, d) {
  const v = parseInt(env(k), 10);
  return Number.isFinite(v) && v > 0 ? v : d;
}
function floatEnv(k, d) {
  const v = parseFloat(env(k));
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
// (Kept byte-identical to test/e2e/canary-buyer/probe.mjs.)
function redact(text) {
  if (text == null) return text;
  let s = String(text);
  if (CONFIG.token && CONFIG.token.length >= 8) s = s.split(CONFIG.token).join('***');
  return s.replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer ***');
}

// Validate a URL we are about to send the buyer token to. Require https and
// reject private/loopback/link-local hosts so a bad env/plist/CLI value can't
// exfiltrate the token or perform local-network SSRF. COLDWARM_ALLOW_INSECURE=1
// opts into http/localhost for local testing against a mock gateway.
function parseSafeUrl(raw, label) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error(`${label} is not a valid URL`);
  }
  const insecure = env('COLDWARM_ALLOW_INSECURE') === '1';
  if (u.protocol !== 'https:' && !(insecure && u.protocol === 'http:')) {
    throw new Error(`${label} must be https (set COLDWARM_ALLOW_INSECURE=1 to allow http for local testing)`);
  }
  if (!insecure && isPrivateHostname(u.hostname)) {
    throw new Error(`${label} points at a private/loopback host (set COLDWARM_ALLOW_INSECURE=1 to allow)`);
  }
  return u;
}

// Resolve the host and reject if it maps to a private address, closing the
// static-misconfiguration / private-DNS SSRF case that a literal-hostname check
// misses. Pure DNS-rebinding is an inherent limitation of dependency-free fetch
// and is accepted as a residual risk for this operator-run internal tool;
// redirect:'manual' on the token-bearing requests closes the redirect variant.
async function assertResolvesPublic(u, label) {
  if (env('COLDWARM_ALLOW_INSECURE') === '1') return;
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

// ── regime: buyer_stream ──────────────────────────────────────────────────────
// Streaming completion, TTFT = time to the first CONTENT token (the real buyer
// first-token latency). Never throws — returns {ok:false,...} so failures are
// recorded, not swallowed.
async function measureBuyerStream({ model, messages, maxTokens }) {
  const headers = authHeaders({
    'Content-Type': 'application/json',
    Accept: 'text/event-stream',
  });
  const start = now();
  let firstTokenAt = 0;
  let lastTokenAt = 0;
  let usage = null;
  let requestId = '';
  let provider = '';
  let streamError = null;

  try {
    const r = await fetch(`${CONFIG.base}/v1/chat/completions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        model,
        messages,
        stream: true,
        max_tokens: maxTokens,
        stream_options: { include_usage: true },
      }),
      redirect: 'manual',
      signal: AbortSignal.timeout(CONFIG.reqTimeoutMs),
    });
    requestId = r.headers.get('x-request-id') || '';
    provider = r.headers.get('x-provider-id') || r.headers.get('x-macprovider-provider') || '';
    if (!r.ok) {
      const text = await r.text().catch(() => '');
      return fail(r.status, redact(text.slice(0, 300)), { requestId, provider });
    }
    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
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
            if (obj?.error) streamError = obj.error;
            const delta = obj?.choices?.[0]?.delta?.content;
            if (delta) {
              if (!firstTokenAt) firstTokenAt = now();
              lastTokenAt = now();
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
    const kind = e && e.name === 'TimeoutError' ? 'timeout' : 'network_error';
    return fail(0, redact(`${kind}: ${e.message || e}`), { kind, requestId, provider });
  }

  const end = now();
  if (streamError) {
    return fail(200, redact(`stream error frame: ${JSON.stringify(streamError).slice(0, 200)}`), {
      kind: 'stream_error',
      requestId,
      provider,
    });
  }
  if (!firstTokenAt) return fail(200, 'no content token', { kind: 'empty', requestId, provider });

  const ttftMs = firstTokenAt - start;
  const decodeMs = Math.max(0, lastTokenAt - firstTokenAt);
  const completionTokens = usage?.completion_tokens ?? null;
  let decodeTps = null;
  if (completionTokens && completionTokens > 1 && decodeMs > 0) {
    // Exclude the first token: TTFT already accounts for prefill + first token.
    decodeTps = ((completionTokens - 1) / decodeMs) * 1000;
  }
  return {
    ok: true,
    status: 200,
    ttftMs,
    decodeTps,
    totalMs: end - start,
    completionTokens,
    requestId,
    provider,
  };
}

// ── regime: canary_nonstream ──────────────────────────────────────────────────
// Non-streaming completion, "TTFT" = full round-trip, mirroring the coordinator
// canary's canaryMetricsFromTiming: for a non-streaming response firstTokenAt is
// zero, so ttft = completedAt - start and decode = the same window. This is the
// EXACT measurement regime the max_ttft_ms gate is evaluated against.
async function measureCanaryNonstream({ model, messages, maxTokens }) {
  const headers = authHeaders({
    'Content-Type': 'application/json',
    Accept: 'application/json',
  });
  const start = now();
  let requestId = '';
  let provider = '';
  try {
    const r = await fetch(`${CONFIG.base}/v1/chat/completions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ model, messages, stream: false, max_tokens: maxTokens }),
      redirect: 'manual',
      signal: AbortSignal.timeout(CONFIG.reqTimeoutMs),
    });
    requestId = r.headers.get('x-request-id') || '';
    provider = r.headers.get('x-provider-id') || r.headers.get('x-macprovider-provider') || '';
    const text = await r.text();
    if (!r.ok) return fail(r.status, redact(text.slice(0, 300)), { requestId, provider });
    const completedAt = now();
    let obj;
    try {
      obj = JSON.parse(text);
    } catch {
      return fail(200, 'unparseable non-streaming body', { kind: 'empty', requestId, provider });
    }
    if (obj?.error) {
      return fail(200, redact(`error body: ${JSON.stringify(obj.error).slice(0, 200)}`), {
        kind: 'stream_error',
        requestId,
        provider,
      });
    }
    const content = obj?.choices?.[0]?.message?.content ?? '';
    if (!content) return fail(200, 'empty completion', { kind: 'empty', requestId, provider });
    const completionTokens = numOrNull(obj?.usage?.completion_tokens);
    // Mirror canaryMetricsFromTiming exactly: TTFT = whole round-trip, and the
    // decode window is the same span, so TPS = completion_tokens / total_seconds.
    const totalMs = completedAt - start;
    let decodeTps = null;
    if (completionTokens && completionTokens > 0 && totalMs > 0) {
      decodeTps = (completionTokens / totalMs) * 1000;
    }
    return {
      ok: true,
      status: 200,
      ttftMs: totalMs, // non-streaming: "TTFT" is the full round-trip
      decodeTps,
      totalMs,
      completionTokens,
      requestId,
      provider,
    };
  } catch (e) {
    const kind = e && e.name === 'TimeoutError' ? 'timeout' : 'network_error';
    return fail(0, redact(`${kind}: ${e.message || e}`), { kind, requestId, provider });
  }
}

function fail(status, error, extra = {}) {
  return { ok: false, status, error, ...extra };
}

function measureRegime(regime, opts) {
  return regime === 'buyer_stream' ? measureBuyerStream(opts) : measureCanaryNonstream(opts);
}

// Per-regime request shape. Short prompt / small decode window for TTFT; the
// canary regime uses the coordinator's canary_max_tokens so it matches the gate.
function regimeRequest(regime, model, { long = false } = {}) {
  if (regime === 'canary_nonstream') {
    return {
      model,
      messages: [{ role: 'user', content: 'Reply with exactly: READY' }],
      maxTokens: long ? CONFIG.tpsMaxTokens : CONFIG.canaryMaxTokens,
    };
  }
  return {
    model,
    messages: [
      long
        ? { role: 'user', content: 'Count from 1 to 100, one number per line.' }
        : { role: 'user', content: 'Say: ready.' },
    ],
    maxTokens: long ? CONFIG.tpsMaxTokens : 8,
  };
}

// role separates the two measurement classes, exactly as P1 does: a 'ttft'
// sample is a short request that feeds ONLY the TTFT distribution; a 'tps' sample
// is a longer request that feeds ONLY the sustained decode-TPS distribution.
// Mixing them pollutes both — a short 8/16-token request has a decode window of a
// couple ms, so its "TPS" is pure noise (observed 0.68 and 500 tok/s against
// prod). decode_tps is therefore only retained on 'tps' samples.
function toSample(regime, state, model, r, runUnix, role) {
  const isTps = role === 'tps';
  return {
    ts: new Date(runUnix * 1000).toISOString(),
    model,
    regime,
    state,
    role,
    ok: r.ok ? 1 : 0,
    ttft_ms: r.ok ? round(r.ttftMs, 1) : null,
    decode_tps: isTps && r.ok && r.decodeTps != null ? round(r.decodeTps, 3) : null,
    completion_tokens: r.completionTokens ?? null,
    total_ms: r.ok ? round(r.totalMs, 1) : null,
    outcome: outcomeBucket(r),
    provider: r.provider || '',
    request_id: r.requestId || '',
    first_error: r.ok ? null : `HTTP ${r.status}: ${r.error || ''}`.slice(0, 200),
  };
}

function outcomeBucket(r) {
  if (r.ok) return '2xx';
  if (r.kind) return r.kind; // timeout | network_error | stream_error | empty
  if (r.status === 0) return 'network_error';
  if (r.status === 502) return '502';
  if (r.status === 200) return 'empty';
  if (r.status >= 500) return '5xx';
  return 'other';
}

// ── scenarios ─────────────────────────────────────────────────────────────────

// Warm baseline: N samples per regime, all tagged state=warm, plus one longer
// sample per regime for a decode-TPS reading. Appended to the store.
async function runWarm(model, runUnix) {
  const out = [];
  for (const regime of REGIMES) {
    process.stderr.write(redact(`warm ${regime} × ${CONFIG.samples} → ${model}\n`));
    for (let i = 0; i < CONFIG.samples; i++) {
      const r = await measureRegime(regime, regimeRequest(regime, model));
      const s = toSample(regime, 'warm', model, r, runUnix, 'ttft');
      out.push(s);
      logSample(s);
      if (i < CONFIG.samples - 1) await sleep(CONFIG.intervalMs);
    }
    // one longer sample for sustained decode TPS (kept separate from the TTFT
    // distribution — a short request's decode window is too small to time TPS).
    await sleep(CONFIG.intervalMs);
    const rl = await measureRegime(regime, regimeRequest(regime, model, { long: true }));
    const sl = toSample(regime, 'warm', model, rl, runUnix, 'tps');
    out.push(sl);
    logSample(sl);
  }
  return out;
}

// Cold / post_reboot: a cold cycle yields exactly ONE genuinely-cold sample (the
// first request warms the model). Fire a single request in the chosen regime
// (explicit --regime, else balance across accumulated cold samples), append it.
// With --warm-followup, also take a few warm samples afterwards (the model is
// now loaded) so a cold cycle cheaply contributes to the warm baseline too.
async function runCold(model, state, runUnix, store) {
  const out = [];
  const regime = CONFIG.regime || pickBalancedRegime(store, model, state);
  process.stderr.write(redact(`${state} ${regime} (first-after-cold) → ${model}\n`));
  const r = await measureRegime(regime, regimeRequest(regime, model));
  // The cold first-request latency IS the point — a TTFT-class sample.
  const s = toSample(regime, state, model, r, runUnix, 'ttft');
  out.push(s);
  logSample(s);

  if (CONFIG.warmFollowup && r.ok) {
    // Model is warm now — grab a small warm batch in BOTH regimes for free.
    for (const wregime of REGIMES) {
      for (let i = 0; i < 3; i++) {
        await sleep(CONFIG.intervalMs);
        const wr = await measureRegime(wregime, regimeRequest(wregime, model));
        const ws = toSample(wregime, 'warm', model, wr, runUnix, 'ttft');
        out.push(ws);
        logSample(ws);
      }
    }
  }
  return out;
}

// Balance cold sampling across regimes: pick whichever regime has FEWER
// accumulated ok cold samples for this (model,state), so both regimes fill up.
function pickBalancedRegime(store, model, state) {
  const counts = { buyer_stream: 0, canary_nonstream: 0 };
  for (const s of store) {
    if (s.model === model && s.state === state && s.ok && s.regime in counts) counts[s.regime]++;
  }
  return counts.buyer_stream <= counts.canary_nonstream ? 'buyer_stream' : 'canary_nonstream';
}

function logSample(s) {
  const v = s.ok ? `ttft=${s.ttft_ms}ms${s.decode_tps != null ? ` tps=${s.decode_tps}` : ''}` : `FAIL ${s.outcome}`;
  console.error(redact(`  [${s.state}/${s.regime}] ${v}${s.first_error ? ` err="${s.first_error}"` : ''}`));
}

// ── matrix aggregation ────────────────────────────────────────────────────────

function buildMatrix(store, runUnix) {
  // group by model|regime|state
  const groups = new Map();
  for (const s of store) {
    if (!REGIMES.includes(s.regime) || !STATES.includes(s.state)) continue;
    const key = `${s.model} ${s.regime} ${s.state}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(s);
  }
  const cells = [];
  for (const [key, samples] of groups) {
    const [model, regime, state] = key.split(' ');
    // TTFT distribution comes ONLY from 'ttft'-role (short) samples; sustained
    // decode-TPS ONLY from 'tps'-role (long) samples. Samples predating the role
    // field (none in practice) default to 'ttft' so a short request never leaks
    // into the TPS series (a short decode window reads garbage TPS — 0.68 and
    // 500 tok/s observed against prod).
    const ttftOk = samples.filter((s) => s.ok && s.ttft_ms != null && (s.role || 'ttft') === 'ttft');
    const tpsOk = samples.filter((s) => s.ok && s.decode_tps != null && s.role === 'tps');
    const ttft = ttftOk.map((s) => s.ttft_ms);
    const tps = tpsOk.map((s) => s.decode_tps);
    cells.push({
      model,
      regime,
      state,
      sample_n: ttftOk.length,
      tps_sample_n: tpsOk.length,
      attempts: samples.length,
      ttft_ms: {
        p50: percentile(ttft, 50),
        p95: percentile(ttft, 95),
        p99: percentile(ttft, 99),
        max: ttft.length ? Math.max(...ttft) : null,
      },
      decode_tps: { p50: percentile(tps, 50), min: tps.length ? Math.min(...tps) : null, n: tps.length },
      first_seen: samples.reduce((a, s) => (a && a < s.ts ? a : s.ts), null),
      last_seen: samples.reduce((a, s) => (a && a > s.ts ? a : s.ts), null),
    });
  }
  cells.sort((a, b) =>
    a.model.localeCompare(b.model) || a.regime.localeCompare(b.regime) || a.state.localeCompare(b.state)
  );
  return {
    schema_version: 1,
    probe: 'coldwarm_ttft',
    run_at: new Date(runUnix * 1000).toISOString(),
    base: CONFIG.base,
    headroom: CONFIG.headroom,
    min_samples: CONFIG.minSamples,
    cells,
    recommendations: recommendGates(cells),
    slo: buildSLO(cells),
  };
}

// Calibrated max_ttft_ms per model class, derived from the CANARY_NONSTREAM WARM
// cell (the exact regime the gate is evaluated against), with headroom over p99.
// Advisory only — the actual config change is a separate, audit-gated PR. We also
// surface the cold p99 so the operator can size canary_cold_start_grace_s.
function recommendGates(cells) {
  const recs = [];
  const byModel = new Map();
  for (const c of cells) {
    if (!byModel.has(c.model)) byModel.set(c.model, {});
    byModel.get(c.model)[`${c.regime}/${c.state}`] = c;
  }
  for (const [model, m] of byModel) {
    const warmCanary = m['canary_nonstream/warm'];
    const coldCanary = m['canary_nonstream/cold'];
    const rebootCanary = m['canary_nonstream/post_reboot'];
    const warmBuyer = m['buyer_stream/warm'];
    const coldBuyer = m['buyer_stream/cold'];
    const rec = { model, regime: 'canary_nonstream' };
    if (warmCanary && warmCanary.sample_n >= CONFIG.minSamples && warmCanary.ttft_ms.p99 != null) {
      rec.warm_p95_ms = warmCanary.ttft_ms.p95;
      rec.warm_p99_ms = warmCanary.ttft_ms.p99;
      rec.recommended_max_ttft_ms = Math.ceil((warmCanary.ttft_ms.p99 * CONFIG.headroom) / 500) * 500;
      rec.enforce_ready = true;
      rec.basis = `warm canary_nonstream p99 ${warmCanary.ttft_ms.p99}ms × ${CONFIG.headroom} headroom, rounded up to 500ms`;
    } else {
      rec.enforce_ready = false;
      rec.basis = `insufficient warm canary_nonstream samples (${warmCanary ? warmCanary.sample_n : 0} < ${CONFIG.minSamples}); keep max_ttft_ms >= 7000 and canary_latency_enforcement: observe`;
    }
    // Cold-start grace sizing: the grace window must cover the worst cold load.
    const coldP99 = coldCanary?.ttft_ms?.p99 ?? null;
    const rebootP99 = rebootCanary?.ttft_ms?.p99 ?? null;
    rec.cold_canary_p99_ms = coldP99;
    rec.post_reboot_canary_p99_ms = rebootP99;
    const worstCold = Math.max(coldP99 || 0, rebootP99 || 0);
    if (worstCold > 0) {
      rec.recommended_cold_start_grace_s = Math.ceil((worstCold / 1000) * 1.25 / 10) * 10;
    }
    // Prewarm case: cold→warm delta on the buyer path (what a real first request costs).
    if (warmBuyer?.ttft_ms?.p50 != null && coldBuyer?.ttft_ms?.p50 != null) {
      rec.buyer_cold_minus_warm_p50_ms = round(coldBuyer.ttft_ms.p50 - warmBuyer.ttft_ms.p50, 0);
    }
    recs.push(rec);
  }
  return recs;
}

// Buyer-UX cold-start SLO: worst-case first-request latency (buyer_stream cold
// p99), per model, the number the product can state/monitor.
function buildSLO(cells) {
  const slo = [];
  for (const c of cells) {
    if (c.regime === 'buyer_stream' && c.state === 'cold' && c.ttft_ms.p99 != null) {
      slo.push({
        model: c.model,
        cold_start_ttft_p99_ms: c.ttft_ms.p99,
        cold_start_ttft_max_ms: c.ttft_ms.max,
        sample_n: c.sample_n,
        sufficient_samples: c.sample_n >= CONFIG.minSamples,
      });
    }
  }
  return slo;
}

function numOrNull(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}
function now() {
  return Number(process.hrtime.bigint() / 1000000n);
}
function realUnix() {
  return Date.now() / 1000;
}
function percentile(arr, p) {
  if (!arr.length) return null;
  const sorted = [...arr].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}
function round(v, d = 2) {
  if (v == null || !Number.isFinite(v)) return v;
  const f = Math.pow(10, d);
  return Math.round(v * f) / f;
}

// ── Prometheus emission ───────────────────────────────────────────────────────

function promEscape(v) {
  return String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ');
}
function toProm(matrix) {
  const L = [];
  const lbl = (o) =>
    Object.entries(o)
      .map(([k, v]) => `${k}="${promEscape(v)}"`)
      .join(',');
  const h = (name, help, type) => {
    L.push(`# HELP ${name} ${help}`);
    L.push(`# TYPE ${name} ${type}`);
  };
  h('macprovider_coldwarm_run_timestamp_seconds', 'Unix time of this matrix build.', 'gauge');
  L.push(`macprovider_coldwarm_run_timestamp_seconds ${Math.floor(Date.parse(matrix.run_at) / 1000)}`);

  h('macprovider_coldwarm_ttft_ms', 'TTFT by model/regime/state/quantile. regime=buyer_stream|canary_nonstream, state=warm|cold|post_reboot.', 'gauge');
  h('macprovider_coldwarm_ttft_samples', 'Valid TTFT samples accumulated for the cell.', 'gauge');
  h('macprovider_coldwarm_decode_tps', 'Decode tokens/sec by model/regime/state (p50).', 'gauge');
  for (const c of matrix.cells) {
    const base = { model: c.model, regime: c.regime, state: c.state };
    for (const q of ['p50', 'p95', 'p99']) {
      if (c.ttft_ms[q] != null) L.push(`macprovider_coldwarm_ttft_ms{${lbl({ ...base, quantile: q })}} ${c.ttft_ms[q]}`);
    }
    L.push(`macprovider_coldwarm_ttft_samples{${lbl(base)}} ${c.sample_n}`);
    if (c.decode_tps.p50 != null) L.push(`macprovider_coldwarm_decode_tps{${lbl({ ...base, quantile: 'p50' })}} ${round(c.decode_tps.p50)}`);
  }

  h('macprovider_coldwarm_recommended_max_ttft_ms', 'Advisory calibrated max_ttft_ms for the canary_nonstream gate (warm p99 × headroom). Only emitted when enforce_ready.', 'gauge');
  h('macprovider_coldwarm_recommended_cold_start_grace_s', 'Advisory canary_cold_start_grace_s sized to cover the worst cold canary load.', 'gauge');
  for (const r of matrix.recommendations) {
    if (r.enforce_ready && r.recommended_max_ttft_ms != null) {
      L.push(`macprovider_coldwarm_recommended_max_ttft_ms{${lbl({ model: r.model })}} ${r.recommended_max_ttft_ms}`);
    }
    if (r.recommended_cold_start_grace_s != null) {
      L.push(`macprovider_coldwarm_recommended_cold_start_grace_s{${lbl({ model: r.model })}} ${r.recommended_cold_start_grace_s}`);
    }
  }

  h('macprovider_coldwarm_cold_start_ttft_p99_ms', 'Buyer-UX cold-start SLO: worst-case first-request TTFT (buyer_stream cold p99).', 'gauge');
  for (const s of matrix.slo) {
    L.push(`macprovider_coldwarm_cold_start_ttft_p99_ms{${lbl({ model: s.model })}} ${s.cold_start_ttft_p99_ms}`);
  }
  return L.join('\n') + '\n';
}

// ── store I/O ─────────────────────────────────────────────────────────────────

async function appendSamples(path, samples) {
  if (!samples.length) return;
  const fs = await import('node:fs/promises');
  await fs.mkdir(dirname(path), { recursive: true }).catch(() => {});
  const lines = samples.map((s) => JSON.stringify(s)).join('\n') + '\n';
  // Append-only NDJSON: a single appendFile of whole lines keeps concurrent runs
  // from interleaving partial records at our cadence. redact() guards against a
  // hostile gateway planting the token in a server-controlled field.
  await fs.appendFile(path, redact(lines), { mode: 0o600 });
}

async function readStore(path) {
  const fs = await import('node:fs/promises');
  let text;
  try {
    text = await fs.readFile(path, 'utf8');
  } catch {
    return [];
  }
  const out = [];
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      /* skip a corrupt/partial line rather than abort the whole aggregation */
    }
  }
  return out;
}

async function writeAtomic(path, content) {
  const fs = await import('node:fs/promises');
  const tmp = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`;
  await fs.mkdir(dirname(path), { recursive: true }).catch(() => {});
  await fs.writeFile(tmp, content, { flag: 'wx', mode: 0o600 });
  try {
    await fs.rename(tmp, path);
  } catch (e) {
    await fs.unlink(tmp).catch(() => {});
    throw e;
  }
}
async function joinPath(dir, file) {
  const fs = await import('node:fs/promises');
  await fs.mkdir(dir, { recursive: true }).catch(() => {});
  return dir.replace(/\/$/, '') + '/' + file;
}
async function rotateArtifacts(dir, keep) {
  const fs = await import('node:fs/promises');
  let names;
  try {
    names = await fs.readdir(dir);
  } catch {
    return;
  }
  const files = names.filter((f) => /^coldwarm-.*\.json$/.test(f));
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

// ── main ──────────────────────────────────────────────────────────────────────

async function main() {
  const runUnix = Math.floor(realUnix());

  if (CONFIG.buildMatrix) {
    const store = await readStore(CONFIG.store);
    const matrix = buildMatrix(store, runUnix);
    const prom = redact(toProm(matrix));
    const json = redact(JSON.stringify(matrix, null, 2));
    console.log(json);
    if (CONFIG.metricsOut) {
      await writeAtomic(CONFIG.metricsOut, prom);
      console.error(redact(`wrote metrics → ${CONFIG.metricsOut}`));
    }
    if (CONFIG.jsonOut) {
      const path = await joinPath(CONFIG.jsonOut, `coldwarm-${matrix.run_at.replace(/[:.]/g, '-')}.json`);
      await writeAtomic(path, json + '\n');
      await rotateArtifacts(CONFIG.jsonOut, 200);
      console.error(redact(`wrote artifact → ${path}`));
    }
    return;
  }

  // Probing scenarios require a token and a validated, public https base.
  if (!CONFIG.token) {
    console.error('FAIL: set MACPROVIDER_BUYER_TOKEN or MALIBU_API_KEY');
    process.exit(2);
  }
  if (!CONFIG.scenario) {
    console.error('FAIL: --scenario warm|cold or --build-matrix required');
    process.exit(2);
  }
  try {
    const baseUrl = parseSafeUrl(`${CONFIG.base}/v1/status`, 'COLDWARM_BASE');
    await assertResolvesPublic(baseUrl, 'COLDWARM_BASE');
  } catch (e) {
    console.error(`FAIL: ${redact(e.message)}`);
    process.exit(2);
  }

  // Resolve the model: explicit --model, else the first served model from status.
  let model = CONFIG.model;
  if (!model) {
    try {
      const status = await getStatus();
      model = (status?.models || []).map((m) => m.id).filter(Boolean)[0] || '';
    } catch (e) {
      console.error(`WARN: /v1/status failed: ${redact(e.message)}`);
    }
  }
  if (!model) {
    console.error('FAIL: no model to probe (pass --model or ensure /v1/status lists one)');
    process.exit(2);
  }

  let samples = [];
  if (CONFIG.scenario === 'warm') {
    samples = await runWarm(model, runUnix);
  } else if (CONFIG.scenario === 'cold') {
    const state = CONFIG.state || 'cold';
    if (state !== 'cold' && state !== 'post_reboot') {
      console.error(`FAIL: --state must be cold or post_reboot (got "${state}")`);
      process.exit(2);
    }
    const store = await readStore(CONFIG.store);
    samples = await runCold(model, state, runUnix, store);
  } else {
    console.error(`FAIL: unknown --scenario "${CONFIG.scenario}" (warm|cold)`);
    process.exit(2);
  }

  await appendSamples(CONFIG.store, samples);
  const okN = samples.filter((s) => s.ok).length;
  console.error(redact(`appended ${samples.length} samples (${okN} ok) → ${CONFIG.store}`));
  // stdout: the samples just recorded (machine-readable).
  console.log(redact(JSON.stringify({ appended: samples.length, ok: okN, store: CONFIG.store, samples }, null, 2)));
}

main().catch((e) => {
  console.error('FATAL:', redact(e.message || String(e)));
  process.exit(2);
});
