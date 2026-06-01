import {api,setToken,token} from "./lib/api.js";
import {poll} from "./lib/poll.js";

const app = document.querySelector("#app");
const tabs = [...document.querySelectorAll("#tabs button")];
const intervals = {overview:30000,providers:10000,activity:15000,health:30000,feedback:30000};
const paths = {
  overview:"/admin/explorer/overview",
  providers:"/admin/explorer/providers",
  activity:"/admin/explorer/activity",
  sessions:"/admin/explorer/sessions",
  buyers:"/admin/explorer/buyers",
  ledger:"/admin/explorer/ledger",
  settlements:"/admin/explorer/settlements",
  health:"/admin/explorer/health",
  feedback:"/admin/explorer/feedback"
};

document.querySelector("#bearer").value = token();
document.querySelector("#authForm").addEventListener("submit",(e)=>{e.preventDefault();setToken(document.querySelector("#bearer").value);load(current);});

let current = "overview";
tabs.forEach((b)=>b.addEventListener("click",()=>load(b.dataset.view)));

function statusStrip(data) {
  const partial = data && data.partial;
  return `<div class="strip"><span class="status ${partial?"degraded":""}"></span><strong>${partial?"partial":"ok"}</strong><span class="mono">${new Date().toISOString()}</span></div>`;
}

function table(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return `<div class="panel">No rows</div>`;
  const cols = [...new Set(rows.flatMap((r)=>Object.keys(r)).slice(0,14))];
  return `<table><thead><tr>${cols.map((c)=>`<th>${c}</th>`).join("")}</tr></thead><tbody>${rows.map((r)=>`<tr>${cols.map((c)=>cell(r[c])).join("")}</tr>`).join("")}</tbody></table>`;
}

function cell(v) {
  if (v === null || v === undefined) return "<td></td>";
  if (typeof v === "object") return `<td><code>${escapeHtml(JSON.stringify(v))}</code></td>`;
  const s = String(v);
  const cls = s.length > 18 ? "mono" : "";
  return `<td class="${cls}">${escapeHtml(s)}</td>`;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g,(c)=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
}

async function load(view) {
  current = view;
  tabs.forEach((b)=>b.classList.toggle("active", b.dataset.view === view));
  app.innerHTML = `<div class="toolbar"><button id="refresh">Refresh</button></div><div class="panel">Loading</div>`;
  document.querySelector("#refresh").onclick = () => load(view);
  try {
    const data = await api(paths[view]);
    const rows = data.items || (data.event ? [data.event] : data.account ? [data.account] : data.provider ? [data.provider] : [data]);
    app.innerHTML = `<div class="toolbar"><button id="refresh">Refresh</button></div>${statusStrip(data)}${table(rows)}`;
    document.querySelector("#refresh").onclick = () => load(view);
  } catch (err) {
    app.innerHTML = `<div class="panel error">${escapeHtml(err.message)}</div>`;
  }
  if (intervals[view]) poll(view, intervals[view], () => load(view));
}

load(current);
