# Fresh-Mac smoke — Malibu v1.8.13

Run on a Mac that has **never** had macprovider or Malibu installed. Check each box before calling P1 exit.

## Download

- [ ] Open `https://download.malibu.tech/latest.dmg` (or GitHub Release `Malibu-v1.8.13.dmg` if redirect not wired yet)
- [ ] Verify SHA-256 sidecar if published (`Malibu-v1.8.13.dmg.sha256`)
- [ ] Gatekeeper: double-click DMG, drag to Applications — no “damaged” / AMFI block
- [ ] `bash scripts/verify-malibu-release-artifacts.sh Malibu-v1.8.13.dmg` passes on a dev Mac with stapler

## First launch

- [ ] Launch Malibu from Applications — menu bar icon appears (no Dock icon)
- [ ] Onboarding window opens automatically on fresh Mac
- [ ] Click **Launch Provider** — install log streams (autotune can take 10–30 min)
- [ ] On success: “Provider live” + **Open Dashboard**
- [ ] Menu bar shows serving state (not Idle / reconnect loop)

## Background provider

- [ ] `launchctl list | rg macprovider` shows `live.streamvc.macprovider` with PID
- [ ] `curl -s http://127.0.0.1:$(grep '^port:' ~/.config/macprovider/config.yaml | awk '{print $2}')/v1/health` → `"status":"ready"` (after model load)
- [ ] `curl -s "https://coordinator.streamvc.live/v1/pool/check?provider_id=$(cat ~/.config/macprovider/provider_id)"` → `"state":"ready"`

## Reboot

- [ ] Reboot Mac — provider comes back without opening Malibu
- [ ] Re-open Malibu — attaches to launchd provider (no second CLI process)

## Uninstall (cross-track)

- [ ] Menu bar → **Quit and Uninstall**
- [ ] `launchctl list | rg macprovider` empty
- [ ] `~/macprovider/macprovider-cli` removed (or manifest gone)
- [ ] `~/Library/Application Support/Malibu` removed

## Notes

Record Mac model, RAM, macOS version, wall-clock install time, and any failure screenshots in the friend-test thread.
