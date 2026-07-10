# SPEC-022 implementation deliverable 6

Status: buyer/provider disclosure surfaces implemented and locally validated.

## Result

D6 adds a structured `verified_model_settlement` disclosure to `/v1/models`
and `settlement_disclosure` to `/v1/usage`. The disclosure limits settlement
claims to covered paid `POST /v1/chat/completions` traffic, names
legacy/direct paths as excluded unless separately disabled or migrated behind
the gateway paid ledger, separates provider-reported model identity from
catalog-known hash status and settlement-enforced receipt matching, and
co-locates every verified-model claim with the provider-reported-hash caveat.

Buyer-facing docs, account disclosure text, and static console copy now state:

- observe mode records diagnostics but cannot claim verified model integrity;
- mixed pools are not fully verified;
- pending quota/balance can remain reserved while receipt verification is
  incomplete;
- `quarantined` and `zero_settled` are not buyer-fault labels;
- partial charges after cancel, timeout, provider error, or upstream disconnect
  require receipt-bound delivered-output prefix and partial usage;
- streaming failover bills only delivered, receipt-verified output and does
  not double-charge overlapping output;
- buyer receipt/status surfaces expose labels without raw prompts or raw
  outputs.

Provider onboarding docs now state that receipts arriving after
`pending_deadline_seconds` are non-settling and non-recoverable unless a future
exception spec changes that rule.

## Validation

- `go test -count=1 ./internal/router -run 'TestModelsResponseIncludesTier1Disclosure|TestUsageIncludesSPEC022SettlementDisclosure|TestTier1DisclosureMatchesSpecSection16|TestDocsRouteRendersMarkdown'`

## Remaining non-D6 gates

This deliverable does not add a buyer receipt retrieval API. SPEC-022 acceptance
criteria that depend on an exposed receipt retrieval endpoint remain conditional
manual gates unless that API is introduced. Full money-path settlement, payout,
race, and live-network e2e gates remain tracked separately.
