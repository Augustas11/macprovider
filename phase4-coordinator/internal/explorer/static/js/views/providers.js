export const spec = {
  view: "providers",
  path: "/admin/explorer/providers",
  rows: (data) => data.providers || data.items || (data.provider ? [data.provider] : []),
  filters: [
    {label: "Ready", query: "?state=ready"},
    {label: "Busy", query: "?state=busy"}
  ],
  panels: [
    {label: "Providers", value: (data) => (data.providers || data.items || []).length},
    {label: "Partial", value: (data) => data.partial ? "yes" : "no"}
  ]
};
