# Mac Provider console

Static front-door for `console.malibu.tech`.

- Single file: `index.html`
- No build step, frameworks, CDNs, fonts, analytics, or third-party requests
- Browser requests go directly to `https://api.malibu.tech`
- Demo tokens are kept in memory only and sent via `X-Demo-Token`
- Demo-session minting is deferred until the first prompt input or send action
- CORS is limited to operator-controlled first-party origins: `https://console.malibu.tech` and the reserved apex `https://malibu.tech`

The production buyer console at `https://malibu.tech/console` is maintained in
[`MalibuAI/malibu`](https://github.com/MalibuAI/malibu) (`console/`). This
tree's `index.html` is the historical SPEC-009 static console, not the deployed
API-key workspace.

Deploy target:

```sh
sudo mkdir -p /var/www/console
sudo cp index.html /var/www/console/index.html
sudo cp dist/nginx-console.malibu.tech.conf /etc/nginx/sites-available/console.malibu.tech
sudo ln -s /etc/nginx/sites-available/console.malibu.tech /etc/nginx/sites-enabled/console.malibu.tech
sudo nginx -t && sudo systemctl reload nginx
```

The apex origin is intentionally reserved for a future operator-controlled first-party surface, not third-party embeds or user-hosted content.
