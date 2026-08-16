#!/usr/bin/env node
/**
 * SPEC-037 KVS-01a probe — one streaming chat turn against a LOCAL provider over
 * the direct-HTTP operator path, carrying a synthetic `conv:kvs-synth:` key so the
 * FR-KVP11 gate persists/promotes it. It is the request half of the KVS-01a
 * four-arm gate driven by `kvs-01a.sh`; it emits one §6 record on stdout (JSON) —
 * regime/arm label, hit/miss reason (disk-side merged by the driver), cached/full
 * prompt tokens, TTFT, total latency, the prompt/input hashes, the served model id,
 * and a correctness outcome — and never echoes the buyer token or the raw key.
 *
 * Genuine second turn (fixes the false-FAIL): the PERSIST arm sends exactly one
 * user turn ([{user: BASE}]) and writes the assistant response to `--response-out`.
 * The RESTORED / WARM arms replay that as a real multi-turn conversation
 * ([{user: BASE}, {assistant: <persist response>}, {user: <suffix>}]) via
 * `--assistant-file`, so the persisted canonical `prompt_token_ids ‖ generated` is
 * an EXACT prefix of the restored render and `cached_prompt_tokens` equals the
 * persisted prefix length (prompt + completion) by the unchanged LCP rule — never
 * structurally short as a single-message-with-inserted-suffix would be.
 *
 * The disk-side §6 fields the buyer stream cannot see (hit/miss reason, restore
 * bytes/ms, staging peak, commit-latency delta, model hash, catalog/format ids,
 * kvBits) are scraped from the provider stderr by `kvs-01a.sh` and merged into the
 * same record.
 *
 * Usage:
 *   kvs-01a-probe.mjs --base http://127.0.0.1:8080 --conversation conv:kvs-synth:<id> \
 *       --model <served-model-id> --regime kvs01a_restored --arm restored \
 *       --prompt-tokens 2500 [--assistant-file <path>] [--suffix <text>] \
 *       [--response-out <path>] [--max-tokens 8]
 * The buyer token is read from $MACPROVIDER_BUYER_TOKEN (never argv).
 */

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { hostname } from 'node:os';

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
const ASSISTANT_FILE = args.get('assistant-file') && args.get('assistant-file') !== true ? String(args.get('assistant-file')) : null;
const SUFFIX = args.get('suffix') && args.get('suffix') !== true ? String(args.get('suffix')) : 'continue';
// The WARM arm forms a genuine THIRD turn: it carries the RESTORED turn's assistant
// response (--assistant-file2) plus a new user suffix (--suffix2) so the incoming render
// is strictly longer than the just-committed turn-2 canonical — a real warm hot hit with
// nonzero cached_prompt_tokens, not a nothing_new miss (LCP == incoming length).
const ASSISTANT_FILE2 = args.get('assistant-file2') && args.get('assistant-file2') !== true ? String(args.get('assistant-file2')) : null;
const SUFFIX2 = args.get('suffix2') && args.get('suffix2') !== true ? String(args.get('suffix2')) : 'continue-again';
const RESPONSE_OUT = args.get('response-out') && args.get('response-out') !== true ? String(args.get('response-out')) : null;
const MAX_TOKENS = Number(args.get('max-tokens') || 8);
const REQ_TIMEOUT_MS = Number(args.get('timeout-ms') || 120000);
const TOKEN = process.env.MACPROVIDER_BUYER_TOKEN || '';

// §6 production fence: KVS-01a MUST run against a local provider only.
if (/malibu\.tech|coordinator\.|api\./i.test(BASE) && process.env.KVS01A_ALLOW_REMOTE !== '1') {
  process.stderr.write(`kvs-01a: refusing non-local base ${BASE} (§6 production fence)\n`);
  process.exit(3);
}
if (!CONVERSATION.startsWith('conv:kvs-synth:')) {
  process.stderr.write('kvs-01a: --conversation must be a conv:kvs-synth: synthetic key\n');
  process.exit(2);
}

const redact = (s) => String(s).replace(/Bearer\s+[A-Za-z0-9._-]+/g, 'Bearer [REDACTED]').replace(/mp_[A-Za-z0-9_-]{8,}/g, 'mp_[REDACTED]');
const sha256 = (s) => createHash('sha256').update(String(s)).digest('hex');

// Build a deterministic ~PROMPT_TOKENS-token prefix. A single repeated ASCII word
// tokenizes close to 1 token each on the Qwen tokenizer; the exact count is recorded
// from the response usage, not assumed.
function buildBasePrompt() {
  return Array.from({ length: PROMPT_TOKENS }, (_, i) => `w${i % 97}`).join(' ');
}

// Assemble the request messages. The PERSIST arm is a single user turn; the RESTORED
// and WARM arms are a genuine second conversation turn that carries the persist turn's
// assistant response, making the persisted canonical an exact prefix of this render.
function buildMessages(base) {
  const msgs = [{ role: 'user', content: base }];
  if (ASSISTANT_FILE && existsSync(ASSISTANT_FILE)) {
    msgs.push({ role: 'assistant', content: readFileSync(ASSISTANT_FILE, 'utf8') });
    msgs.push({ role: 'user', content: SUFFIX });
    // Genuine THIRD turn (WARM arm): carry the restored turn's assistant response + a
    // new suffix so the persisted/promoted turn-2 canonical is a strict prefix and the
    // hot tier reports nonzero cached_prompt_tokens instead of nothing_new.
    if (ASSISTANT_FILE2 && existsSync(ASSISTANT_FILE2)) {
      msgs.push({ role: 'assistant', content: readFileSync(ASSISTANT_FILE2, 'utf8') });
      msgs.push({ role: 'user', content: SUFFIX2 });
    }
  }
  return msgs;
}

async function main() {
  const base = buildBasePrompt();
  const messages = buildMessages(base);
  const started = Date.now();
  let ttftMs = null;
  let usage = null;
  let streamError = null;
  let status = 0;
  let requestId = '';
  let responseText = '';

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
        messages,
        stream: true,
        max_tokens: MAX_TOKENS,
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
        if (delta) {
          if (ttftMs == null) ttftMs = Date.now() - started;
          responseText += delta;
        }
        if (obj?.usage) usage = obj.usage;
      }
    }
  } catch (e) {
    streamError = redact(e?.message || String(e));
  }

  // The PERSIST arm hands its assistant response to the RESTORED/WARM arms so they can
  // form a genuine second turn.
  if (RESPONSE_OUT && !streamError) {
    try { writeFileSync(RESPONSE_OUT, responseText); } catch (e) { /* non-fatal */ }
  }

  const promptTokens = usage?.prompt_tokens ?? null;
  const completionTokens = usage?.completion_tokens ?? null;
  const cachedTokens = usage?.cached_prompt_tokens ?? usage?.prompt_tokens_details?.cached_tokens ?? null;
  const correctness = streamError ? 'error' : (completionTokens && completionTokens > 0 ? 'ok' : 'empty');

  const record = {
    schema: 'kvs-01a/v2',
    ts: new Date().toISOString(),
    regime: REGIME,
    arm: ARM,
    base: BASE,
    model: MODEL || null,
    host: hostname(),
    node_version: process.version,
    turns: messages.length,
    request_id: requestId,
    status,
    ttft_ms: ttftMs,
    total_latency_ms: Date.now() - started,
    prompt_tokens: promptTokens,
    completion_tokens: completionTokens,
    cached_prompt_tokens: cachedTokens,
    // §6 identity/correctness fields visible to the buyer stream. The disk-side model
    // hash / catalog+format ids / kvBits are merged from provider stderr by the driver.
    input_sha256: sha256(base),
    prompt_sha256: sha256(JSON.stringify(messages)),
    correctness,
    error: streamError,
  };
  process.stdout.write(`${JSON.stringify(record)}\n`);
  process.exit(streamError ? 1 : 0);
}

main();
