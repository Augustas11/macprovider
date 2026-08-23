const fs = require("fs");
const vm = require("vm");

const htmlPath = process.argv[2];
if (!htmlPath) {
  throw new Error("usage: node portal_bundle_probe.js <frontdoor/provider-portal/index.html>");
}
const html = fs.readFileSync(htmlPath, "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join("\n");

function makeContext(url, fetchImpl) {
  const nodes = [];
  function FakeNode() {}
  function makeNode(tag) {
    const node = new FakeNode();
    node.tag = tag;
    node.children = [];
    node.attrs = {};
    node.style = {};
    node.className = "";
    node.value = "";
    node.appendChild = (child) => {
      node.children.push(child);
      return child;
    };
    node.removeChild = (child) => {
      node.children = node.children.filter((item) => item !== child);
    };
    node.setAttribute = (key, value) => {
      node.attrs[key] = String(value);
    };
    node.addEventListener = () => {};
    node.select = () => {};
    Object.defineProperty(node, "firstChild", {
      get() {
        return node.children[0] || null;
      },
    });
    nodes.push(node);
    return node;
  }

  const app = makeNode("div");
  app.id = "app";
  const parsed = new URL(url);
  const assigned = [];
  const context = {
    URL,
    Node: FakeNode,
    setTimeout(fn) {
      context.timeout = fn;
      return 1;
    },
    setInterval() {
      return 1;
    },
    clearInterval() {},
    location: {
      href: parsed.href,
      pathname: parsed.pathname,
      search: parsed.search,
      assign(target) {
        assigned.push(target);
      },
    },
    history: {
      replaceState(_state, _title, target) {
        const next = new URL(target, parsed.origin);
        context.location.href = next.href;
        context.location.pathname = next.pathname;
        context.location.search = next.search;
      },
      pushState(_state, _title, target) {
        const next = new URL(target, parsed.origin);
        context.location.href = next.href;
        context.location.pathname = next.pathname;
        context.location.search = next.search;
      },
    },
    document: {
      readyState: "loading",
      addEventListener() {},
      createElement: makeNode,
      createElementNS(_ns, tag) {
        return makeNode(tag);
      },
      createTextNode(text) {
        return { text: String(text) };
      },
      getElementById(id) {
        return id === "app" ? app : null;
      },
      body: makeNode("body"),
      execCommand() {
        return true;
      },
    },
    navigator: { clipboard: { writeText: async () => {} } },
    addEventListener() {},
    fetch: fetchImpl,
    window: {},
    console,
  };
  context.window = context;
  context.app = app;
  context.assigned = assigned;
  context.createdNodes = nodes;
  return context;
}

function assert(cond, msg) {
  if (!cond) {
    throw new Error(msg);
  }
}

(async () => {
  const claimContext = makeContext("http://portal.test/claim?ot=PAIR123", async () => ({
    ok: true,
    status: 200,
    text: async () => "{\"providers\":[]}",
  }));
  vm.runInNewContext(scripts, claimContext);
  assert(claimContext.location.search === "", "claim route must strip ?ot before app work");
  assert(claimContext.location.pathname === "/claim", "claim route must remain on /claim after stripping token");

  const portalSessionContext = makeContext("http://portal.test/?ps=PORTAL123&p=mp-local#dash", async () => ({
    ok: false,
    status: 500,
    text: async () => "",
  }));
  vm.runInNewContext(scripts, portalSessionContext);
  assert(portalSessionContext.PORTAL_SESSION_CAPTURED === "PORTAL123",
    "portal session token must be captured before config work");
  assert(portalSessionContext.location.search === "?p=mp-local",
    "portal session token must be stripped while preserving non-secret query params");
  assert(portalSessionContext.location.href === "http://portal.test/?p=mp-local#dash",
    "portal session token stripping must preserve the current hash");

  const portalOAuthFetches = [];
  const portalOAuthContext = makeContext("http://portal.test/?ps=PORTAL456", async (path, opts) => {
    portalOAuthFetches.push({ path, opts: opts || {} });
    if (String(path).endsWith("portal-config.json")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          coordinator_base_url: "https://c.example",
          releases_repo_owner_name: "Augustas11/macprovider",
          require_provider_tokens: true,
          github_oauth_enabled: true,
        }),
        text: async () => "{}",
      };
    }
    if (String(path).endsWith("/v1/portal/session")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ provider_id: "mp-local" }),
        text: async () => "{\"provider_id\":\"mp-local\"}",
      };
    }
    if (String(path).endsWith("/providers/mp-local/earnings")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ usdc_today: 0, usdc_week: 0, usdc_pending: 0, usdc_lifetime: 0 }),
        text: async () => "{}",
      };
    }
    if (String(path).endsWith("/v1/provider/malibu-accrual")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          wallet_bound: true,
          trust_tier: "trusted",
          withdrawable_malibu: 0,
          held_malibu: 0,
          withdrawal_hold_reasons: [],
          reward_eligibility: {
            schema_version: "malibu_reward_eligibility.v1",
            earning_state: "eligible_idle",
            withdrawal_state: "withdrawable",
            primary_reason: "eligible_idle_no_work",
            reasons: ["eligible_idle_no_work"],
          },
        }),
        text: async () => "{}",
      };
    }
    if (String(path).endsWith("/v1/provider/wallet")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          schema_version: "provider_wallet_status.v1",
          provider_id: "mp-local",
          wallet_bound: true,
          wallet_mismatch: false,
          reward_wallet: {
            verification_source: "provider_emission_state",
            cap_replay_pending: false,
          },
          reward_amounts: {
            accrued_malibu: "0",
            withdrawable_malibu: "0",
            held_malibu: "0",
            provider_daily_cap_malibu: 25,
            provider_day_malibu: "0",
            provider_daily_capped: false,
            wallet_daily_cap_malibu: 100,
            wallet_day_malibu: "0",
            wallet_daily_capped: false,
          },
          eligibility_inputs: {
            trust_tier: "trusted",
            quarantined: false,
            receipt_quality: "sufficient_verified_receipts",
            verified_receipt_count: 3,
            required_receipt_count: 3,
            compute_integrity_state: "unknown",
            attestation_tier: "app_attested",
            app_attested: true,
            criteria_met: 3,
            criteria_required: 3,
            economic_criteria: [],
            additional_criteria: [],
            wallet_balance_ok: true,
            uptime_ok: true,
          },
          reward_eligibility: {
            schema_version: "malibu_reward_eligibility.v1",
            earning_state: "eligible_idle",
            withdrawal_state: "withdrawable",
            primary_reason: "eligible_idle_no_work",
            reasons: ["eligible_idle_no_work"],
          },
          audit: {
            events: [{
              id: "evt-1",
              occurred_at: "2026-08-18T00:00:00Z",
              event_type: "wallet_bind_projected",
              summary: "Wallet projected.",
            }],
          },
        }),
        text: async () => "{}",
      };
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({}),
      text: async () => "{}",
    };
  });
  vm.runInNewContext(scripts, portalOAuthContext);
  await portalOAuthContext.bootstrap();
  assert(portalOAuthFetches.some((call) => call.path === "/v1/portal/session"),
    "captured portal session must be consumed before GitHub OAuth mode");
  assert(!portalOAuthFetches.some((call) => call.path === "/v1/auth/me/providers"),
    "captured portal session must not silently fall through to GitHub OAuth mode");
  assert(portalOAuthContext.state.session.provider_id === "mp-local",
    "captured portal session must establish the provider dashboard session");
  assert(portalOAuthFetches.some((call) =>
    call.path === "/providers/mp-local/earnings" &&
    call.opts.headers &&
    call.opts.headers.Authorization === "Bearer PORTAL456"),
    "captured portal session earnings fetch must keep using bearer auth");
  assert(portalOAuthFetches.some((call) =>
    call.path === "/v1/provider/malibu-accrual" &&
    call.opts.headers &&
    call.opts.headers.Authorization === "Bearer PORTAL456"),
    "captured portal session MALIBU fetch must keep using bearer auth");
  assert(portalOAuthFetches.some((call) =>
    call.path === "/v1/provider/wallet" &&
    call.opts.headers &&
    call.opts.headers.Authorization === "Bearer PORTAL456"),
    "captured portal session wallet fetch must keep using bearer auth");

  const configContext = makeContext("http://portal.test/", async () => ({
    ok: true,
    status: 200,
    text: async () => "{}",
  }));
  vm.runInNewContext(scripts, configContext);
  assert(configContext.validateConfig({
    coordinator_base_url: "https://c.example",
    releases_repo_owner_name: "Augustas11/macprovider",
    require_provider_tokens: true,
    github_oauth_enabled: true,
  }).github_oauth_enabled === true, "four-key config should accept boolean github_oauth_enabled");
  assert(configContext.validateConfig({
    coordinator_base_url: "https://c.example",
    releases_repo_owner_name: "Augustas11/macprovider",
    require_provider_tokens: true,
  }).github_oauth_enabled === false, "omitted github_oauth_enabled should default false");
  let rejected = false;
  try {
    configContext.validateConfig({
      coordinator_base_url: "https://c.example",
      releases_repo_owner_name: "Augustas11/macprovider",
      require_provider_tokens: true,
      github_oauth_enabled: "true",
    });
  } catch (_err) {
    rejected = true;
  }
  assert(rejected, "string github_oauth_enabled must fail closed");

  rejected = false;
  try {
    configContext.validateConfig({
      coordinator_base_url: "https://c.example",
      releases_repo_owner_name: "Augustas11/macprovider",
      require_provider_tokens: true,
      github_oauth_enabled: false,
      extra: true,
    });
  } catch (_err) {
    rejected = true;
  }
  assert(rejected, "fifth portal-config key must fail closed");

  const falseBranchFetches = [];
  const falseContext = makeContext("http://portal.test/", async (path, opts) => {
    falseBranchFetches.push({ path, opts });
    if (String(path).endsWith("portal-config.json")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          coordinator_base_url: "https://c.example",
          releases_repo_owner_name: "Augustas11/macprovider",
          require_provider_tokens: true,
          github_oauth_enabled: false,
        }),
        text: async () => "{}",
      };
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({}),
      text: async () => "{}",
    };
  });
  vm.runInNewContext(scripts, falseContext);
  await falseContext.loadConfig();
  falseContext.render();
  assert(falseContext.state.configError == null, "flag-off bootstrap must load portal config successfully");
  assert(falseContext.state.cfg.github_oauth_enabled === false, "flag-off bootstrap must use loaded false config");
  assert(falseContext.state.cookieFetch == null, "flag-off bootstrap must not initialize cookie auth helper");
  assert(falseBranchFetches.filter((call) => String(call.path).includes("/v1/auth/")).length === 0,
    "flag-off cold load must not fetch /v1/auth/*");

  const fetchCalls = [];
  configContext.fetch = async (path, opts) => {
    fetchCalls.push({ path, opts });
    return { ok: true, status: 200, text: async () => "{}" };
  };
  configContext.state.cfg = { github_oauth_enabled: true };
  configContext.state.cookieFetch = configContext.makeCookieFetch();
  await configContext.cookieJSON("/v1/auth/me/providers", {
    headers: { Authorization: "Bearer should-not-pass", "X-Test": "ok" },
  });
  const call = fetchCalls[0];
  assert(call.opts.credentials === "include", "GitHub branch fetch must include credentials");
  assert(!("Authorization" in call.opts.headers) && !("authorization" in call.opts.headers),
    "GitHub branch fetch must strip Authorization");

  console.log(JSON.stringify({ ok: true }));
})().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
