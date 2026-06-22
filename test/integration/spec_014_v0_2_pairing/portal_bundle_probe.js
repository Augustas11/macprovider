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
