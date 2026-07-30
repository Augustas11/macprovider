import {api,setToken,token} from "./lib/api.js";
import {poll,stop} from "./lib/poll.js";
import {spec as overviewSpec} from "./views/overview.js";
import {spec as sessionsSpec} from "./views/sessions.js";
import {spec as buyersSpec} from "./views/buyers.js";
import {spec as providersSpec} from "./views/providers.js";
import {spec as ledgerSpec} from "./views/ledger.js";
import {spec as settlementsSpec} from "./views/settlements.js";
import {spec as activitySpec} from "./views/activity.js";
import {spec as healthSpec} from "./views/health.js";
import {spec as feedbackSpec} from "./views/feedback.js";

const app = document.querySelector("#app");
const tabs = [...document.querySelectorAll("#tabs button")];

// Poll intervals (ms). Only these views auto-refresh; others are manual-only.
const intervals = {overview:30000, providers:10000, activity:15000, health:30000, feedback:30000};

const specs = {
  overview:    overviewSpec,
  sessions:    sessionsSpec,
  buyers:      buyersSpec,
  providers:   providersSpec,
  ledger:      ledgerSpec,
  settlements: settlementsSpec,
  activity:    activitySpec,
  health:      healthSpec,
  feedback:    feedbackSpec,
};
const paths = Object.fromEntries(Object.entries(specs).map(([k,v])=>[k,v.path]));

// Restore saved bearer into the input field.
const bearerInput = document.querySelector("#bearer");
bearerInput.value = token();

// Unlock form: set bearer and trigger a fresh load of the current view.
document.querySelector("#authForm").addEventListener("submit", (e) => {
  e.preventDefault();
  const val = bearerInput.value.trim();
  setToken(val);
  if (!val) {
    showMsg("Enter the operator bearer and click Unlock.");
    return;
  }
  activate(current);
});

let current = "overview";
let currentPath = paths.overview;

// Tab clicks.
tabs.forEach((b) => b.addEventListener("click", () => activate(b.dataset.view)));

// Cross-view navigation links inside rendered tables.
app.addEventListener("click", (e) => {
  const link = e.target.closest("[data-view]");
  if (!link) return;
  e.preventDefault();
  activate(link.dataset.view, link.dataset.path || paths[link.dataset.view]);
});

// Re-poll when tab becomes visible again after being hidden.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && token()) {
    activate(current, currentPath);
  }
});

// --- rendering helpers ---

function statusStrip(data) {
  const partial = data && data.partial;
  const wrap = el("div", "strip");
  wrap.appendChild(el("span", `status ${partial?"degraded":""}`.trim()));
  wrap.appendChild(el("strong", "", partial ? "partial" : "ok"));
  wrap.appendChild(el("span", "mono", new Date().toISOString()));
  return wrap;
}

function table(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return el("div", "panel", "No rows");
  const cols = [...new Set(rows.flatMap((r) => Object.keys(r)).slice(0,14))];
  const out = document.createElement("table");
  const thead = document.createElement("thead");
  const headRow = document.createElement("tr");
  cols.forEach((c) => headRow.appendChild(el("th", "", c)));
  thead.appendChild(headRow);
  out.appendChild(thead);
  const tbody = document.createElement("tbody");
  rows.forEach((r) => {
    const tr = document.createElement("tr");
    cols.forEach((c) => tr.appendChild(cell(c, r[c], r)));
    tbody.appendChild(tr);
  });
  out.appendChild(tbody);
  return out;
}

function cell(k, v, row) {
  const td = document.createElement("td");
  if (v === null || v === undefined) return td;
  if (typeof v === "object") {
    td.appendChild(el("code", "", JSON.stringify(v)));
    return td;
  }
  const s = String(v);
  const link = linkFor(k, s, row);
  if (s.length > 18) td.className = "mono";
  td.appendChild(link || document.createTextNode(s));
  return td;
}

function linkFor(k, v, _row) {
  if (!v) return null;
  // SPEC-007 §5.6 v0.5 (#245): coordinator-internal request_id MUST be emitted with the `int_` prefix.
  if (k === "request_id") return action("sessions",    `/admin/explorer/sessions/int_${encodeURIComponent(v)}`, v);
  if (k === "account_id") return action("buyers",      `/admin/explorer/buyers/${encodeURIComponent(v)}`, v);
  if (k === "provider_id") return action("providers",  `/admin/explorer/providers/${encodeURIComponent(v)}`, v);
  if (k === "settlement_id") return action("settlements", `/admin/explorer/settlements/${encodeURIComponent(v)}`, v);
  if (k === "link_target" && v.startsWith("session:")) return action("sessions", `/admin/explorer/sessions/int_${encodeURIComponent(v.slice(8))}`, v);
  if (k === "link_target" && v.startsWith("buyer:"))   return action("buyers",   `/admin/explorer/buyers/${encodeURIComponent(v.slice(6))}`, v);
  return null;
}

function action(view, path, label) {
  const a = el("a", "", label);
  a.href = "#";
  a.dataset.view = view;
  a.dataset.path = path;
  return a;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function healthLinks(data) {
  const rec = data && (data.last_reconciliation || (data.health && data.health.last_reconciliation));
  if (!rec || !rec.from_utc || !rec.to_utc) return null;
  const path = `/admin/explorer/ledger?from=${encodeURIComponent(rec.from_utc)}&to=${encodeURIComponent(rec.to_utc)}`;
  const out = el("div", "toolbar");
  out.appendChild(action("ledger", path, "Last reconciliation ledger window"));
  return out;
}

function filters(spec) {
  return (spec.filters || []).map((f) => {
    const button = el("button", "", f.label);
    button.dataset.view = spec.view;
    button.dataset.path = `${spec.path}${f.query}`;
    return button;
  });
}

function summary(spec, data) {
  const panels = (spec.panels || []).map((p) => {
    const panel = document.createElement("div");
    panel.appendChild(el("strong", "", p.label));
    panel.appendChild(el("span", "mono", String(p.value(data))));
    return panel;
  });
  if (!panels.length) return null;
  const grid = el("div", "grid");
  panels.forEach((panel) => grid.appendChild(panel));
  return grid;
}

function showMsg(msg, isError) {
  stop(current);
  app.replaceChildren(el("div", `panel${isError ? " error" : ""}`, msg));
}

// --- core functions ---

// load(): fetch data for view and render. Does NOT start or restart polling.
async function load(view, path) {
  const target = path || paths[view];
  const loadingToolbar = el("div", "toolbar");
  const loadingRefresh = el("button", "", "Refresh");
  loadingRefresh.id = "refresh";
  loadingRefresh.onclick = () => activate(view, target);
  loadingToolbar.appendChild(loadingRefresh);
  app.replaceChildren(loadingToolbar, el("div", "panel", "Loading…"));
  try {
    const data = await api(target);
    const spec = specs[view] || overviewSpec;
    const rows = spec.rows(data);
    const toolbar = el("div", "toolbar");
    const refresh = el("button", "", "Refresh");
    refresh.id = "refresh";
    refresh.onclick = () => activate(view, target);
    toolbar.appendChild(refresh);
    filters(spec).forEach((button) => toolbar.appendChild(button));
    app.replaceChildren(
      toolbar,
      statusStrip(data),
      ...[healthLinks(data), summary(spec,data)].filter(Boolean),
      table(rows),
    );
  } catch (err) {
    app.replaceChildren(el("div", "panel error", err.message));
  }
}

// activate(): switch to a view, update tabs, load once, then schedule polling.
// This is the ONLY place that calls poll().
function activate(view, path) {
  stop(current);           // cancel previous view's poll
  current = view;
  currentPath = path || paths[view];
  tabs.forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  load(view, currentPath);
  if (intervals[view]) {
    poll(view, intervals[view], () => load(view, currentPath));
  }
}

// --- startup ---

if (token()) {
  // Bearer already in sessionStorage from a previous load — go straight in.
  activate(current);
} else {
  // No bearer yet — show prompt, don't fire any API calls.
  showMsg("Enter the operator bearer in the Unlock field above to connect.");
}
