#!/usr/bin/env node
/**
 * Malibu Console smoke — mirrors console/api.js buyer paths.
 *
 * Usage:
 *   MALIBU_API_KEY=mp_... node test/e2e/malibu-console/smoke.mjs
 *   MALIBU_BASE=https://api.streamvc.live  (default)
 *
 * Exercises:
 *   GET  /v1/status          (sidebar pool dot)
 *   POST /v1/chat/completions turn 1 + turn 2 with sticky conversation header
 */

const BASE = (process.env.MALIBU_BASE || 'https://api.streamvc.live').replace(/\/$/, '');
const API_KEY = process.env.MALIBU_API_KEY || '';
const DEMO_TOKEN = process.env.MALIBU_DEMO_TOKEN || '';
const MODEL = process.env.MALIBU_MODEL || 'qwen3-coder-30b-a3b-instruct';

function authHeaders(extra = {}) {
  const headers = { ...extra };
  if (API_KEY) {
    headers.Authorization = `Bearer ${API_KEY}`;
    return headers;
  }
  if (DEMO_TOKEN) {
    headers['X-Demo-Token'] = DEMO_TOKEN;
  }
  return headers;
}

async function ensureDemoToken() {
  if (API_KEY || DEMO_TOKEN) return DEMO_TOKEN;
  if (!process.env.MALIBU_ALLOW_DEMO) return '';
  const r = await fetch(`${BASE}/auth/demo-session`, { method: 'POST' });
  const text = await r.text();
  if (!r.ok) fail(`demo-session HTTP ${r.status}: ${text.slice(0, 200)}`);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    fail('demo-session response is not JSON');
  }
  const token = body.demo_token || body.token || '';
  if (!token) fail('demo-session missing demo_token');
  return token;
}

function fail(msg) {
  console.error('FAIL:', msg);
  process.exit(1);
}

function ok(msg) {
  console.log('OK:', msg);
}

async function getStatus(demoToken) {
  const headers = authHeaders({ Accept: 'application/json' });
  if (demoToken) headers['X-Demo-Token'] = demoToken;
  const r = await fetch(`${BASE}/v1/status`, { headers });
  const text = await r.text();
  if (!r.ok) fail(`status HTTP ${r.status}: ${text.slice(0, 200)}`);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    fail('status response is not JSON');
  }
  return body;
}

async function chatStream({ model, messages, conversationId, maxTokens = 256, demoToken }) {
  const headers = authHeaders({
    'Content-Type': 'application/json',
    Accept: 'text/event-stream',
  });
  if (demoToken) headers['X-Demo-Token'] = demoToken;
  if (conversationId) headers['X-MacProvider-Conversation'] = conversationId;

  const r = await fetch(`${BASE}/v1/chat/completions`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ model, messages, stream: true, max_tokens: maxTokens }),
  });

  const provider = r.headers.get('X-Provider-Id') || r.headers.get('X-MacProvider-Provider') || '';
  if (!r.ok) {
    const text = await r.text().catch(() => '');
    return { ok: false, status: r.status, text: text.slice(0, 400), provider };
  }

  const reader = r.body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  let content = '';
  let usage = null;
  const started = Date.now();

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf('\n\n')) !== -1) {
      const frame = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      for (const line of frame.split('\n')) {
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === '[DONE]') continue;
        try {
          const obj = JSON.parse(payload);
          const delta = obj?.choices?.[0]?.delta?.content;
          if (delta) content += delta;
          if (obj?.usage) usage = obj.usage;
        } catch {
          /* ignore partial frames */
        }
      }
    }
  }

  return {
    ok: true,
    content,
    usage,
    provider,
    latencyMs: Date.now() - started,
  };
}

async function main() {
  if (!API_KEY && !DEMO_TOKEN && !process.env.MALIBU_ALLOW_DEMO) {
    fail('Set MALIBU_API_KEY, MALIBU_DEMO_TOKEN, or MALIBU_ALLOW_DEMO=1');
  }

  const demoToken = await ensureDemoToken();

  const status = await getStatus(demoToken);
  ok(`pool status=${status.status} ready=${status.pool?.ready ?? '?'} models=${status.models?.length ?? 0}`);
  const modelEntry = (status.models || []).find((m) => m.id === MODEL);
  if (!modelEntry) {
    console.warn(`WARN: model ${MODEL} not in status.models (continuing anyway)`);
  } else if (modelEntry.available === false) {
    fail(`model ${MODEL} marked unavailable: ${modelEntry.availability || 'unknown'}`);
  } else {
    ok(`model ${MODEL} available slots_free=${modelEntry.slots_free}`);
  }

  const threadId = crypto.randomUUID();
  const turn1 = await chatStream({
    model: MODEL,
    conversationId: threadId,
    demoToken,
    messages: [{ role: 'user', content: 'Reply with exactly: pong' }],
    maxTokens: 16,
  });
  if (!turn1.ok) fail(`turn1 chat ${turn1.status}: ${turn1.text}`);
  if (!turn1.content.toLowerCase().includes('pong')) {
    console.warn(`WARN: turn1 content unexpected: ${JSON.stringify(turn1.content.slice(0, 80))}`);
  }
  ok(`turn1 ${turn1.latencyMs}ms provider=${turn1.provider || 'n/a'} tokens=${turn1.usage?.total_tokens ?? '?'}`);

  const turn2 = await chatStream({
    model: MODEL,
    conversationId: threadId,
    demoToken,
    messages: [
      { role: 'user', content: 'Reply with exactly: pong' },
      { role: 'assistant', content: turn1.content },
      { role: 'user', content: 'Reply with exactly: pong again' },
    ],
    maxTokens: 16,
  });
  if (!turn2.ok) fail(`turn2 sticky chat ${turn2.status}: ${turn2.text}`);
  ok(
    `turn2 sticky ${turn2.latencyMs}ms cached=${turn2.usage?.cached_prompt_tokens ?? 0} provider=${turn2.provider || 'n/a'}`
  );

  console.log('\nAll Malibu console smoke checks passed.');
}

main().catch((e) => fail(e.message || String(e)));
