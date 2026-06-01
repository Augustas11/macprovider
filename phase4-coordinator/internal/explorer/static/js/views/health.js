export const spec = {
  view: "health",
  path: "/admin/explorer/health",
  rows: (data) => [data],
  filters: [
    {label: "24h", query: "?window=24h"},
    {label: "7d", query: "?window=7d"}
  ],
  panels: [
    {label: "Coordinator", value: (data) => data.coordinator_health || "ok"},
    {label: "Gateway", value: (data) => data.gateway_health || "unknown"}
  ]
};
