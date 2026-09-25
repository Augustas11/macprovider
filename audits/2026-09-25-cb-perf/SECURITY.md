## Lane: SECURITY / MONEY PATH

Check:
- Cross-row isolation with in-place KV buffers. Could one row's tokens become
  visible to another row through a shared or aliased buffer, stale data past
  `storedTokens` after trim, or a padded batch?
- Retained-sequence and conversation-cache exposure across buyers.
- Usage, receipt and settlement fields: are they unchanged by the decode
  window?
- Memory growth: can capacity steps or buffers exceed pool accounting (a DoS
  or memory-pressure risk on the provider)?
- LaunchAgent `Standard` priority: any security or availability implication,
  such as a runaway process starving the UI, or behaviour under the watchdog?
