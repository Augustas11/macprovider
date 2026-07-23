#!/usr/bin/env node
/**
 * SPEC-037 KVS-01a probe — one streaming chat turn against a LOCAL provider over
 * the direct-HTTP operator path, carrying a synthetic `conv:kvs-synth:` key so the
 * FR-KVP11 gate persists/promotes it. It is the request half of the KVS-01a
 * kill-and-relaunch cycle driven by `kvs-01a.sh`; it emits one §6 record on stdout
 * (JSON) — regime label, hit/miss reason, cached/full prompt tokens, TTFT, and
 * total latency — and never echoes the buyer token or the raw key.
 *
 * Matches the coldwarm-ttft harness style (fetch + manual SSE parse + redaction).
 * The disk-side §6 fields the buyer stream cannot see (hit/miss reason, restore
 * bytes/ms, staging peak, commit-latency delta) are scraped from the provider
 * stderr by `kvs-01a.sh` and merged into the same record.
 *
 * Usage:
 *   kvs-01a-probe.mjs --base http://127.0.0.1:8080 --conversation conv:kvs-synth:<id> \
 *       --model <served-model-id> --regime kvs01a_restored --arm restored \
 *       --prompt-tokens 2500 [--suffix-token 424242]
 * The buyer token is read from $MACPROVIDER_BUYER_TOKEN (never argv).
 */

const args = new Map();
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith('--')) args.set(a.slice(2), process.argv[i + 1]?.startsWith('--') || i + 1 >= process.argv.length ? true : process.argv[++i]);
}

const BASE = String(args.get('base') || 'http://127.0.0.1:8080');
const CONVERSATION = String(args.get('conversation') || '');
const MODEL = String(args.get('model') || '');
const REGIME = String(args.get('regime') || 'kvs01a');
const ARM = String(args.get('arm') || 'restored');
const PROMPT_TOKENS = Number(args.get('prompt-tokens') || 2500);
const SUFFIX_TOKEN = args.get('suffix-token') != null ? Number(args.get('suffix-token')) : null;
const REQ_TIMEOUT_MS = Number(args.get('timeout-ms') || 120000);
const TOKEN = process.env.MACPROVIDER_BUYER_TOKEN || '';

// §6 production fence: KVS-01a MUST run against a local provider only.
if (/streamvc\.live|coordinator\.|api\./i.test(BASE) && process.env.KVS01A_ALLOW_REMOTE !== '1') {
  process.stderr.write(`kvs-01a: refusing non-local base ${BASE} (§6 production fence)\n`);
  process.exit(3);
}
if (!CONVERSATION.startsWith('conv:kvs-synth:')) {
  process.stderr.write('kvs-01a: --conversation must be a conv:kvs-synth: synthetic key\n');
  process.exit(2);
}

const redact = (s) => String(s).replace(/Bearer\s+[A-Za-z0-9._-]+/g, 'Bearer [REDACTED]').replace(/mp_[A-Za-z0-9_-]{8,}/g, 'mp_[REDACTED]');

// Build a deterministic ~PROMPT_TOKENS-token prefix. A single repeated ASCII word
// tokenizes close to 1 token each on the Qwen tokenizer; the exact count is
// recorded from the response usage, not assumed. The restored arm re-sends the
// SAME prefix plus one new suffix token so the LCP is the whole prefix.
function buildPrompt() {
  const base = Array.from({ length: PROMPT_TOKENS }, (_, i) => `w${i % 97}`).join(' ');
  return SUFFIX_TOKEN != null ? `${base} s${SUFFIX_TOKEN}` : base;
}

async function main() {
  const started = Date.now();
  let ttftMs = null;
  let usage = null;
  let streamError = null;
  let status = 0;
  let requestId = '';

  try {
    const r = await fetch(`${BASE.replace(/\/$/, '')}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(TOKEN ? { authorization: `Bearer ${TOKEN}` } : {}),
        'X-MacProvider-Provider-Conversation': CONVERSATION,
      },
      body: JSON.stringify({
        model: MODEL || undefined,
        messages: [{ role: 'user', content: buildPrompt() }],
        stream: true,
        max_tokens: 8,
        stream_options: { include_usage: true },
      }),
      redirect: 'manual',
      signal: AbortSignal.timeout(REQ_TIMEOUT_MS),
    });
    status = r.status;
    requestId = r.headers.get('x-request-id') || '';
    if (!r.ok) {
      const text = await r.text().catch(() => '');
      throw new Error(`http ${r.status}: ${redact(text.slice(0, 200))}`);
    }
    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === '[DONE]') continue;
        let obj;
        try { obj = JSON.parse(payload); } catch { continue; }
        if (obj?.error) { streamError = obj.error; continue; }
        const delta = obj?.choices?.[0]?.delta?.content;
        if (ttftMs == null && delta) ttftMs = Date.now() - started;
        if (obj?.usage) usage = obj.usage;
      }
    }
  } catch (e) {
    streamError = redact(e?.message || String(e));
  }

  const record = {
    schema: 'kvs-01a/v1',
    ts: new Date().toISOString(),
    regime: REGIME,
    arm: ARM,
    base: BASE,
    request_id: requestId,
    status,
    ttft_ms: ttftMs,
    total_latency_ms: Date.now() - started,
    prompt_tokens: usage?.prompt_tokens ?? null,
    cached_prompt_tokens: usage?.cached_prompt_tokens ?? usage?.prompt_tokens_details?.cached_tokens ?? null,
    completion_tokens: usage?.completion_tokens ?? null,
    error: streamError,
  };
  process.stdout.write(`${JSON.stringify(record)}\n`);
  process.exit(streamError ? 1 : 0);
}

main();
