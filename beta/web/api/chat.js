// Vercel Edge function — streams a chat completion from the chosen Mac
// through that Mac's Cloudflare tunnel. The browser only talks to this
// function, so we sidestep CORS on mlx_lm.server.

export const config = {
  runtime: 'edge',
};

const PROVIDERS = {
  m1: {
    tunnel_url: 'https://m1.streamvc.live',
    model: 'mlx-community/llama-3.2-3b-instruct-4bit',
  },
  m4: {
    tunnel_url: 'https://m4.streamvc.live',
    model: 'mlx-community/Qwen2.5-7B-Instruct-4bit',
  },
};

export default async function handler(req) {
  if (req.method === 'GET' && new URL(req.url).pathname.endsWith('/providers')) {
    return Response.json(PROVIDERS);
  }
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 });
  }

  let body;
  try {
    body = await req.json();
  } catch {
    return new Response('bad json', { status: 400 });
  }

  const provider = body.provider;
  const prompt = (body.prompt || '').trim();
  const p = PROVIDERS[provider];
  if (!p || !prompt) {
    return new Response('unknown provider or empty prompt', { status: 400 });
  }

  const upstreamReq = {
    model: p.model,
    stream: true,
    messages: [{ role: 'user', content: prompt }],
    max_tokens: Math.min(parseInt(body.max_tokens ?? 384, 10) || 384, 512),
    temperature: typeof body.temperature === 'number' ? body.temperature : 0.7,
  };

  let upstream;
  try {
    upstream = await fetch(p.tunnel_url + '/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(upstreamReq),
    });
  } catch (e) {
    return new Response('upstream error: ' + (e && e.message), { status: 502 });
  }

  if (!upstream.ok || !upstream.body) {
    const text = await upstream.text().catch(() => '');
    return new Response('upstream HTTP ' + upstream.status + ': ' + text.slice(0, 400), {
      status: upstream.status,
    });
  }

  return new Response(upstream.body, {
    status: 200,
    headers: {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      'X-Accel-Buffering': 'no',
      'X-Provider': provider,
      'X-Provider-Tunnel': p.tunnel_url,
      'X-Provider-Model': p.model,
    },
  });
}
