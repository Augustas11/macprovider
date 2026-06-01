export const spec = {
  view: "activity",
  path: "/admin/explorer/activity",
  rows: (data) => data.events || data.items || [],
  filters: [
    {label: "Feedback", query: "?type=feedback"},
    {label: "Requests", query: "?type=request_completed"}
  ],
  panels: [
    {label: "Events", value: (data) => (data.events || data.items || []).length},
    {label: "Partial", value: (data) => data.partial ? "yes" : "no"}
  ]
};
