<p align="center">
  <img src="doc/assets/banner.svg" alt="MacProvider — pooled Apple Silicon inference" width="720" />
</p>

<p align="center">
  <a href="https://console.streamvc.live"><strong>Console</strong></a> &middot;
  <a href="#for-providers"><strong>Join as Provider</strong></a> &middot;
  <a href="#for-buyers"><strong>API Access</strong></a> &middot;
  <a href="https://github.com/augustas11/macprovider/releases"><strong>Releases</strong></a>
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/augustas11/macprovider?style=flat" alt="Latest release" />
  <img src="https://img.shields.io/badge/platform-Apple%20Silicon-000000?style=flat&logo=apple&logoColor=white" alt="Platform" />
  <img src="https://img.shields.io/badge/runtime-MLX%20%7C%20macOS%2014%2B-5a5a5a?style=flat" alt="Runtime" />
</p>

<br/>

# MacProvider

**Pooled Apple Silicon inference. Contribute a Mac, earn per request. Buy OpenAI-compatible inference at cost.**

| For Providers | For Buyers |
|---|---|
| Run MLX models locally on any M1+ Mac | OpenAI-compatible `/v1/chat/completions` endpoint |
| Outbound WebSocket only — no port-forwarding needed | Route to the full pool or pin to a specific provider |
| Earn per request served | Pay only for compute, no subscription required |
| Manage your node at [console.streamvc.live](https://console.streamvc.live) | Chat and monitor at [console.streamvc.live](https://console.streamvc.live) |

## Console

**[console.streamvc.live](https://console.streamvc.live)** is the front end for MacProvider. Use it to chat with the network, manage your provider node, or monitor the pool:

- Send requests to the network directly from the browser
- View session history and per-request logs
- Manage provider status and pool visibility
- Review billing and earnings

## Architecture

```
Provider Mac (MLX)
  └── outbound WS ──▶ MacProvider
                      (pool · routing · billing)
                             │
               ┌─────────────┴─────────────┐
               │                           │
    api.streamvc.live/v1          console.streamvc.live
    (OpenAI-compatible)               (web front end)
```

New public installs join as **provisional providers** over outbound WebSocket tunneling and can be promoted to pinned by the operator after observation. No inbound port-forwarding is required on the provider Mac.

## For Providers

Run on any Apple Silicon Mac (M1 or newer, macOS 14+):

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
```

The installer:

- Picks a recommended MLX model based on available RAM (you can override)
- Asks for a stable provider handle used as your pool identity
- Downloads and verifies the latest `macprovider-cli` release against a signed checksum manifest
- Installs under `~/macprovider` and sets up a user-level launchd service
- Runs a local `/v1/models` check and a coordinator pool visibility check

**Security note:** `curl | bash` gives the downloaded script control of your user account. Inspect first if you prefer:

```bash
curl -fsSL https://get.streamvc.live/install.sh -o install.sh
less install.sh
bash install.sh
```

The binary is checksum-verified against a signed release manifest. macOS quarantine (`xattr`) is cleared with your approval during install. Developer ID signing and notarization are planned for a future release.

## For Buyers

Base URL: `https://api.streamvc.live`

The API is OpenAI-compatible — swap in your existing client:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.streamvc.live/v1",
    api_key="<your-api-key>",
)

response = client.chat.completions.create(
    model="mlx-community/Llama-3.2-3B-Instruct-4bit",
    messages=[{"role": "user", "content": "Hello"}],
)
print(response.choices[0].message.content)
```

Get an API key → [api.streamvc.live/auth/github/start](https://api.streamvc.live/auth/github/start)  
API reference → [api.streamvc.live/docs#api-reference](https://api.streamvc.live/docs#api-reference)

## Releases

Current release: **[v1.2.5](https://github.com/augustas11/macprovider/releases/latest)**  
Full changelog and signed binaries: [github.com/augustas11/macprovider/releases](https://github.com/augustas11/macprovider/releases)
