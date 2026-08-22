#!/usr/bin/env node
// Local-only preview of the operator-minted portal session. Not production.
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const here = fileURLToPath(new URL(".", import.meta.url));
const port = Number(process.env.PORTAL_PREVIEW_PORT || 8765);
const previewToken = "mps1_localpreview";
let providerId = "mp-local-preview";
const idPath = join(homedir(), ".config", "macprovider", "provider_id");
if (existsSync(idPath)) {
  const raw = readFileSync(idPath, "utf8").trim();
  if (raw) providerId = raw;
}

const config = {
  coordinator_base_url: "https://coordinator.malibu.tech",
  releases_repo_owner_name: "Augustas11/macprovider",
  require_provider_tokens: true,
  github_oauth_enabled: false,
};

function json(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(body));
}

function bearer(req) {
  const header = req.headers.authorization || "";
  return header.startsWith("Bearer ") ? header.slice(7).trim() : "";
}

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (url.pathname === "/portal-config.json") {
    return json(res, 200, config);
  }
  if (url.pathname === "/v1/portal/session") {
    if (bearer(req) !== previewToken) return json(res, 401, { error: "unauthorized" });
    return json(res, 200, {
      provider_id: providerId,
      expires_at: new Date(Date.now() + 12 * 3600 * 1000).toISOString(),
      scope: "portal_read",
    });
  }
  if (url.pathname === "/v1/pool/check") {
    return json(res, 200, { provider_id: providerId, state: "ready", tier: "provisional" });
  }
  if (url.pathname === `/providers/${providerId}/earnings`) {
    if (bearer(req) !== previewToken) return json(res, 401, { error: "unauthorized" });
    return json(res, 200, {
      provider_id: providerId,
      total_credits: 1250000,
      current_window_credits: 42000,
      usdc_today: 1.25,
      usdc_week: 8.4,
      usdc_pending: 12.5,
      usdc_lifetime: 12.5,
    });
  }
  if (url.pathname === "/v1/provider/malibu-accrual") {
    if (bearer(req) !== previewToken) return json(res, 401, { error: "unauthorized" });
    return json(res, 200, {
      provider_id: providerId,
      accrued_malibu: 3.2,
      withdrawable_malibu: 1.1,
      held_malibu: 2.1,
      trust_tier: "provisional",
      reward_eligibility: {
        schema_version: "malibu_reward_eligibility.v1",
        earning_state: "earning",
        withdrawal_state: "held",
        primary_reason: "earning_verified_work",
        reasons: ["earning_verified_work"],
      },
    });
  }
  if (url.pathname === "/v1/provider/wallet") {
    if (bearer(req) !== previewToken) return json(res, 401, { error: "unauthorized" });
    return json(res, 200, {
      schema_version: "provider_wallet_status.v1",
      provider_id: providerId,
      wallet_bound: false,
      unavailable: false,
    });
  }
  if (url.pathname === "/" || url.pathname === "/index.html") {
    const html = readFileSync(join(here, "index.html"));
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return res.end(html);
  }
  const type = extname(url.pathname) === ".json" ? "application/json" : "text/plain";
  res.writeHead(404, { "content-type": type });
  res.end("not found");
});

server.listen(port, "127.0.0.1", () => {
  const link = `http://127.0.0.1:${port}/?ps=${previewToken}`;
  process.stdout.write(`portal preview for ${providerId}\n${link}\n`);
});
