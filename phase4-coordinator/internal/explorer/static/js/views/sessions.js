export const spec = {
  view: "sessions",
  path: "/admin/explorer/sessions",
  rows: (data) => data.sessions || data.items || data.attempts || (data.request_id ? [data] : []),
  filters: [
    {label: "Errors", query: "?status=500"},
    {label: "24h", query: "?window_hours=24"}
  ],
  panels: [
    {label: "Sessions", value: (data) => (data.sessions || data.items || data.attempts || []).length},
    {label: "Partial", value: (data) => data.partial ? "yes" : "no"}
  ]
};
