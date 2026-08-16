// Mirror of the provider config exposed at /api/providers so the UI can
// populate the dropdown and the receipt panel without inlining secrets.

export const config = { runtime: 'edge' };

const PROVIDERS = {
  m1: {
    tunnel_url: 'https://m1.malibu.tech',
    model: 'mlx-community/llama-3.2-3b-instruct-4bit',
  },
  m4: {
    tunnel_url: 'https://m4.malibu.tech',
    model: 'mlx-community/Qwen2.5-7B-Instruct-4bit',
  },
};

export default function handler() {
  if (globalThis.process?.env?.MACPROVIDER_ENABLE_LEGACY_BETA_PROXY !== '1') {
    return new Response('legacy beta proxy disabled', { status: 410 });
  }

  return Response.json(PROVIDERS, {
    headers: { 'Cache-Control': 'public, max-age=60' },
  });
}
