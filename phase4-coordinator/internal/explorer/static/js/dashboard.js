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
  return `<div class="strip"><span class="status ${partial?"degraded":""}"></span><strong>${partial?"partial":"ok"}</strong><span class="mono">${new Date().toISOString()}</span></div>`;
}

function table(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return `<div class="panel">No rows</div>`;
  const cols = [...new Set(rows.flatMap((r) => Object.keys(r)).slice(0,14))];
  return `<table><thead><tr>${cols.map((c)=>`<th>${c}</th>`).join("")}</tr></thead><tbody>${rows.map((r)=>`<tr>${cols.map((c)=>cell(c,r[c],r)).join("")}</tr>`).join("")}</tbody></table>`;
}

function cell(k, v, row) {
  if (v === null || v === undefined) return "<td></td>";
  if (typeof v === "object") return `<td><code>${escapeHtml(JSON.stringify(v))}</code></td>`;
  const s = String(v);
  const link = linkFor(k, s, row);
  return `<td class="${s.length > 18 ? "mono" : ""}">${link || escapeHtml(s)}</td>`;
}

function linkFor(k, v, _row) {
  if (!v) return "";
  if (k === "request_id") return action("sessions",    `/admin/explorer/sessions/${encodeURIComponent(v)}`, v);
  if (k === "account_id") return action("buyers",      `/admin/explorer/buyers/${encodeURIComponent(v)}`, v);
  if (k === "provider_id") return action("providers",  `/admin/explorer/providers/${encodeURIComponent(v)}`, v);
  if (k === "settlement_id") return action("settlements", `/admin/explorer/settlements/${encodeURIComponent(v)}`, v);
  if (k === "link_target" && v.startsWith("session:")) return action("sessions", `/admin/explorer/sessions/${encodeURIComponent(v.slice(8))}`, v);
  if (k === "link_target" && v.startsWith("buyer:"))   return action("buyers",   `/admin/explorer/buyers/${encodeURIComponent(v.slice(6))}`, v);
  return "";
}

function action(view, path, label) {
  return `<a href="#" data-view="${view}" data-path="${path}">${escapeHtml(label)}</a>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
}

function healthLinks(data) {
  const rec = data && (data.last_reconciliation || (data.health && data.health.last_reconciliation));
  if (!rec || !rec.from_utc || !rec.to_utc) return "";
  const path = `/admin/explorer/ledger?from=${encodeURIComponent(rec.from_utc)}&to=${encodeURIComponent(rec.to_utc)}`;
  return `<div class="toolbar">${action("ledger", path, "Last reconciliation ledger window")}</div>`;
}

function filters(spec) {
  return (spec.filters || []).map((f) =>
    `<button data-view="${spec.view}" data-path="${spec.path}${f.query}">${escapeHtml(f.label)}</button>`
  ).join("");
}

function summary(spec, data) {
  const panels = (spec.panels || []).map((p) =>
    `<div><strong>${escapeHtml(p.label)}</strong><span class="mono">${escapeHtml(String(p.value(data)))}</span></div>`
  );
  return panels.length ? `<div class="grid">${panels.join("")}</div>` : "";
}

function showMsg(msg, isError) {
  stop(current);
  app.innerHTML = `<div class="panel${isError ? " error" : ""}">${escapeHtml(msg)}</div>`;
}

// --- core functions ---

// load(): fetch data for view and render. Does NOT start or restart polling.
async function load(view, path) {
  const target = path || paths[view];
  app.innerHTML = `<div class="toolbar"><button id="refresh">Refresh</button></div><div class="panel">Loading…</div>`;
  document.querySelector("#refresh").onclick = () => activate(view, target);
  try {
    const data = await api(target);
    const spec = specs[view] || overviewSpec;
    const rows = spec.rows(data);
    app.innerHTML = `<div class="toolbar"><button id="refresh">Refresh</button>${filters(spec)}</div>${statusStrip(data)}${healthLinks(data)}${summary(spec,data)}${table(rows)}`;
    document.querySelector("#refresh").onclick = () => activate(view, target);
  } catch (err) {
    app.innerHTML = `<div class="panel error">${escapeHtml(err.message)}</div>`;
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
