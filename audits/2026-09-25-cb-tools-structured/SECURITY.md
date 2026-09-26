## Lane: SECURITY / MONEY PATH

Check:
- Usage, receipt and settlement fields for batched tool and structured rows, especially tokens generated after the serial stop point: are they billed or excluded exactly as on the serial path?
- Cross-row isolation of tool-call parser state and of structured accumulators.
- The SPEC-018 argument byte caps are enforced per row.
- Harmony gating: no path lets a Harmony tool request batch.
