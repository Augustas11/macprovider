#!/usr/bin/env node
// Tiny local mock gateway for smoke-testing coldwarm-probe.mjs (dev only).
// Serves /v1/status and /v1/chat/completions (both streaming and non-streaming).
// COLDWARM_MOCK_DELAY_MS simulates a cold load on the first request.
import http from 'node:http';

const PORT = parseInt(process.env.PORT || '8799', 10);
const MODEL = process.env.MOCK_MODEL || 'qwen3-coder-30b-a3b-instruct';
let firstSeen = false;

function coldDelay() {
  // First request after boot is "cold": big delay. Subsequent are "warm".
  if (!firstSeen) {
    firstSeen = true;
    return parseInt(process.env.MOCK_COLD_MS || '1200', 10);
  }
  return parseInt(process.env.MOCK_WARM_MS || '80', 10);
}

const server = http.createServer(async (req, res) => {
  if (req.url === '/v1/status') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ models: [{ id: MODEL }], pool: { ready: 1 } }));
    return;
  }
  if (req.url === '/v1/chat/completions' && req.method === 'POST') {
    let body = '';
    for await (const c of req) body += c;
    const stream = /"stream"\s*:\s*true/.test(body);
    const delay = coldDelay();
    await new Promise((r) => setTimeout(r, delay));
    if (stream) {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'x-request-id': 'mock-req', 'x-provider-id': 'mock' });
      for (const tok of ['re', 'ad', 'y']) {
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: tok } }] })}\n\n`);
        await new Promise((r) => setTimeout(r, 20));
      }
      res.write(`data: ${JSON.stringify({ choices: [{ delta: {} }], usage: { completion_tokens: 3, prompt_tokens: 10 } })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    } else {
      res.writeHead(200, { 'content-type': 'application/json', 'x-request-id': 'mock-req', 'x-provider-id': 'mock' });
      res.end(JSON.stringify({ choices: [{ message: { content: 'READY' } }], usage: { completion_tokens: 3, prompt_tokens: 10 } }));
    }
    return;
  }
  res.writeHead(404);
  res.end('nope');
});
server.listen(PORT, '127.0.0.1', () => console.error(`mock gateway on http://127.0.0.1:${PORT} model=${MODEL}`));
