export const spec = {
  view: "overview",
  path: "/admin/explorer/overview",
  rows: (data) => [
    {section: "gateway", ...data.gateway},
    {section: "pool", ...data.pool},
    {section: "traffic", ...data.traffic},
    {section: "ledger", ...data.ledger}
  ],
  panels: [
    {label: "Protocol", value: (data) => data.protocol_status || ""},
    {label: "Ready", value: (data) => data.pool?.ready_providers ?? 0},
    {label: "Gateway", value: (data) => data.gateway?.health || "unknown"}
  ]
};
