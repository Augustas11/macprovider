export const spec = {
  view: "ledger",
  path: "/admin/explorer/ledger",
  rows: (data) => data.entries || data.items || [],
  filters: [
    {label: "24h", query: "?window_hours=24"},
    {label: "7d", query: "?window_hours=168"}
  ],
  panels: [
    {label: "Entries", value: (data) => (data.entries || data.items || []).length},
    {label: "Partial", value: (data) => data.partial ? "yes" : "no"}
  ]
};
