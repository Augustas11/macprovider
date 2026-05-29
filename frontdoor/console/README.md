# Mac Provider console

Static front-door for `console.streamvc.live`.

- Single file: `index.html`
- No build step, frameworks, CDNs, fonts, analytics, or third-party requests
- Browser requests go directly to `https://api.streamvc.live`
- Demo tokens are kept in memory only and sent via `X-Demo-Token`
- Demo-session minting is deferred until the first prompt input or send action
- CORS is limited to operator-controlled first-party origins: `https://console.streamvc.live` and the reserved apex `https://streamvc.live`

Deploy target:

```sh
sudo mkdir -p /var/www/console
sudo cp index.html /var/www/console/index.html
sudo cp dist/nginx-console.streamvc.live.conf /etc/nginx/sites-available/console.streamvc.live
sudo ln -s /etc/nginx/sites-available/console.streamvc.live /etc/nginx/sites-enabled/console.streamvc.live
sudo nginx -t && sudo systemctl reload nginx
```

The apex origin is intentionally reserved for a future operator-controlled first-party surface, not third-party embeds or user-hosted content.
