export const spec = {
  view: "feedback",
  path: "/admin/explorer/feedback",
  rows: (data) => data.events || data.items || [],
  panels: [
    {label: "Feedback", value: (data) => (data.events || data.items || []).length},
    {label: "Partial", value: (data) => data.partial ? "yes" : "no"}
  ]
};
