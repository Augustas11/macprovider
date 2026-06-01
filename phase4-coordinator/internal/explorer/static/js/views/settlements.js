export const spec = {
  view: "settlements",
  path: "/admin/explorer/settlements",
  rows: (data) => data.settlements || data.items || (data.settlement ? [data.settlement] : []),
  filters: [
    {label: "Ready", query: "?status=ready"},
    {label: "Consumed", query: "?status=consumed"}
  ],
  panels: [
    {label: "Rows", value: (data) => (data.settlements || data.items || []).length},
    {label: "Partial", value: (data) => data.partial ? "yes" : "no"}
  ]
};
