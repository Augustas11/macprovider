#!/usr/bin/env node
// Local preview of the portal bundle against LIVE Pearl.
// Same GET paths Malibu.app uses. Browser never sees the Keychain FR-P12 token.
// Not production: production is portal.malibu.tech with an operator-minted ?ps=.
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const here = fileURLToPath(new URL(".", import.meta.url));
const port = Number(process.env.PORTAL_PREVIEW_PORT || 8765);
const previewToken = "mps1_localpreview";
const upstreamOrigin = (process.env.PORTAL_UPSTREAM || "https://portal.malibu.tech").replace(/\/$/, "");
const coordinatorOrigin = (
  process.env.COORDINATOR_UPSTREAM || "https://coordinator.malibu.tech"
).replace(/\/$/, "");

let providerId = "";
const idPath = join(homedir(), ".config", "macprovider", "provider_id");
if (existsSync(idPath)) {
  providerId = readFileSync(idPath, "utf8").trim();
}
if (!providerId) {
  process.stderr.write("no ~/.config/macprovider/provider_id — cannot proxy live earnings\n");
  process.exit(1);
}

const keychainToken = loadProviderToken(providerId);
if (!keychainToken) {
  process.stderr.write("no FR-P12 token in Keychain for this Mac — cannot proxy live earnings\n");
  process.exit(1);
}

const config = {
  coordinator_base_url: "https://coordinator.malibu.tech",
  releases_repo_owner_name: "Augustas11/macprovider",
  require_provider_tokens: true,
  github_oauth_enabled: false,
};

function loadProviderToken(id) {
  const services = [
    "live.malibu.provider.provider-token.v1",
    "live.streamvc.macprovider.provider-token.v1",
  ];
  for (const service of services) {
    try {
      const raw = execFileSync(
        "security",
        ["find-generic-password", "-s", service, "-a", id, "-w"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
      ).trim();
      if (raw) return raw;
    } catch (_) {
      // try next service
    }
  }
  return "";
}

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

function livePath(pathname) {
  if (pathname === "/v1/pool/check") return true;
  if (pathname === "/v1/provider/malibu-accrual") return true;
  if (pathname === "/v1/provider/wallet") return true;
  if (pathname === "/v1/provider/malibu-reward-audit") return true;
  return /^\/providers\/[^/]+\/earnings$/.test(pathname);
}

async function proxyLive(req, res, url) {
  if (req.method !== "GET") return json(res, 405, { error: "method_not_allowed" });
  if (bearer(req) !== previewToken && url.pathname !== "/v1/pool/check") {
    return json(res, 401, { error: "unauthorized" });
  }
  const pathAndQuery = url.pathname + url.search;
  const origins = url.pathname === "/v1/provider/wallet"
    ? [upstreamOrigin, coordinatorOrigin]
    : [upstreamOrigin];
  let lastStatus = 502;
  let lastType = "application/json";
  let lastBuf = Buffer.from(JSON.stringify({ error: "upstream_failed" }));
  for (const origin of origins) {
    try {
      const upstream = await fetch(origin + pathAndQuery, {
        method: "GET",
        headers: {
          Authorization: "Bearer " + keychainToken,
          Accept: "application/json",
        },
        cache: "no-store",
      });
      const buf = Buffer.from(await upstream.arrayBuffer());
      const type = upstream.headers.get("content-type") || "application/json";
      lastStatus = upstream.status;
      lastType = type;
      lastBuf = buf;
      const looksJSON = type.includes("json") || (buf.length > 0 && buf[0] === 0x7b);
      if (looksJSON || origins.length === 1) {
        res.writeHead(upstream.status, {
          "content-type": looksJSON ? "application/json" : type,
          "cache-control": "no-store",
        });
        res.end(buf);
        return;
      }
    } catch (_) {
      lastStatus = 502;
    }
  }
  res.writeHead(lastStatus, {
    "content-type": lastType.includes("json") ? "application/json" : lastType,
    "cache-control": "no-store",
  });
  res.end(lastBuf);
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
  if (livePath(url.pathname)) {
    proxyLive(req, res, url).catch(() => json(res, 502, { error: "upstream_failed" }));
    return;
  }
  if (url.pathname === "/" || url.pathname === "/index.html") {
    const html = readFileSync(join(here, "index.html"));
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return res.end(html);
  }
  if (url.pathname === "/favicon.svg") {
    const svg = readFileSync(join(here, "favicon.svg"));
    res.writeHead(200, { "content-type": "image/svg+xml" });
    return res.end(svg);
  }
  const type = extname(url.pathname) === ".json" ? "application/json" : "text/plain";
  res.writeHead(404, { "content-type": type });
  res.end("not found");
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(
    `live Pearl proxy for ${providerId} via ${upstreamOrigin}\n` +
      `http://127.0.0.1:${port}/?ps=${previewToken}\n`,
  );
});
