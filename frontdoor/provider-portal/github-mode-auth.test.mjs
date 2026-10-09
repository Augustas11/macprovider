import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

// #1880: in GitHub (MP session cookie) mode a data endpoint's 401/403/404
// shows an inline error; only /v1/auth/me/providers may restart sign-in.
function loadPortal(fetchImpl, assigned) {
  const html = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  function FakeNode(tag) {
    this.tagName = tag;
    this.classList = { contains() { return false; }, add() {}, remove() {} };
    this.style = {};
  }
  FakeNode.prototype.appendChild = function appendChild() {};
  FakeNode.prototype.setAttribute = function setAttribute() {};
  FakeNode.prototype.addEventListener = function addEventListener() {};
  const context = {
    console, Date, URL, Promise, JSON,
    Node: FakeNode,
    fetch: fetchImpl,
    setInterval() { return 0; },
    clearInterval() {},
    setTimeout() { return 0; },
    clearTimeout() {},
    location: { pathname: "/", href: "https://portal.example/", assign(url) { assigned.push(url); } },
    history: { replaceState() {}, pushState() {} },
    document: {
      readyState: "loading",
      getElementById() { return null; },
      createElement(tag) { return new FakeNode(tag); },
      createElementNS(_ns, tag) { return new FakeNode(tag); },
      createTextNode(text) { return { textContent: text }; },
      addEventListener() {},
    },
    addEventListener() {},
  };
  context.window = context;
  vm.createContext(context);
  for (const script of scripts) vm.runInContext(script, context);
  return context;
}

function response(status, body) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    text() { return Promise.resolve(body === undefined ? "" : JSON.stringify(body)); },
    json() { return Promise.resolve(body); },
  });
}

for (const status of [401, 403, 404]) {
  test(`github mode earnings ${status} is inline, never a re-sign-in`, async () => {
    const assigned = [];
    const calls = [];
    const context = loadPortal((url) => {
      calls.push(String(url));
      return response(status, { error: "x" });
    }, assigned);
    context.state.cfg = { github_oauth_enabled: true };
    // selectGitHubProvider starts the pollers, which fetch at once.
    vm.runInContext(`selectGitHubProvider("provider-a", false)`, context);
    for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(assigned, [], "earnings refusal started GitHub sign-in");
    assert.ok(calls.some((u) => u === "/providers/provider-a/earnings"));
    assert.equal(context.state.session && context.state.session.provider_id, "provider-a");
    assert.equal(context.state.earn.err && context.state.earn.err.status, status);
    assert.equal(context.state.githubAuthState, "dashboard");
  });
}

test("github mode: a 401 from /v1/auth/me/providers still asks to sign in", async () => {
  const assigned = [];
  const context = loadPortal(() => response(401, { error: "session_invalid" }), assigned);
  context.state.cfg = { github_oauth_enabled: true };
  await vm.runInContext("loadGitHubHome()", context);
  assert.equal(context.state.githubAuthState, "signin");
});
