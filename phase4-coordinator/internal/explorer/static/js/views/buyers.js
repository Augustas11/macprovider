export const spec = {
  view: "buyers",
  path: "/admin/explorer/buyers",
  rows: (data) => data.buyers || data.items || (data.account_id ? [data] : []),
  filters: [
    {label: "Active", query: "?status=active"},
    {label: "Blocked", query: "?status=blocked"}
  ],
  panels: [
    {label: "Accounts", value: (data) => (data.buyers || data.items || []).length},
    {label: "Active keys", value: (data) => data.summary?.active_api_keys ?? ""}
  ]
};
