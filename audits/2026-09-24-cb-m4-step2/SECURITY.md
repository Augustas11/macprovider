## Lane: SECURITY / MONEY PATH

Check:
- Cross-conversation and cross-account isolation. Auto-prefix keys are shared
  across conversations: could a retained sequence or checkpoint from one
  buyer's turn be installed into another buyer's row?
- `cached_prompt_tokens` for batched cached turns: equal to the serial
  checkpoint hit, and never over-reported.
- Usage, receipt and settlement fields for cached batched rows.
- Pool exhaustion from retained sequences (denial of service).
- Fail-closed behaviour with a malformed or missing checkpoint.
