# Build Handoff - v1.4.0

## Current Status

**Release**: https://github.com/lumencanvas/ossuary-pi/releases/tag/v1.4.0

Build should be triggered automatically by the tag push. Check status:
```bash
gh run list --limit 3
```

## What Changed in v1.4.0

### Features
- Delete button works for ALL saved networks (including system-saved via NetworkManager)
- Welcome page shows live connection status (SSID + hostname)
- IP address fallback when `.local` hostname doesn't resolve
- Schedule rules now execute (refresh/restart at specified times)

### Security
- XSS protection for WiFi network names (`escapeHtml()`)
- Warning before deleting currently connected network

### Build Fixes
- **Pi Imager customization works** - Removed `.skip-userconf` creation that was blocking firstrun.sh
- wifi-connect download with 3x retry logic and gzip validation
- Added `wireless-tools` and `iproute2` packages

### Runtime Fixes
- `--remote-debugging-port=9222` added to Chromium for CDP page refresh
- Multiple fallback methods for WiFi detection (iwgetid → nmcli → /sys)
- Schedule state persists across reboots (`/var/lib/ossuary/` instead of `/run/`)
- Proper error feedback in UI instead of silent failures

## Key Files Modified

| File | Changes |
|------|---------|
| `custom-ui/index.html` | escapeHtml, delete for all networks, error handling |
| `custom-ui/welcome.html` | Connection status view, IP fallback |
| `scripts/process-manager.sh` | Remote debugging port |
| `scripts/connection-monitor.sh` | Schedule execution, persistent state |
| `scripts/wifi-connect-manager.sh` | Robust WiFi detection fallbacks |
| `stage-ossuary/00-install-ossuary/00-run.sh` | Pi Imager fix, wifi-connect retry |
| `stage-ossuary/00-install-ossuary/00-packages` | wireless-tools, iproute2 |

## Quick Commands

```bash
# Check build status
gh run list --limit 3

# View release
gh release view v1.4.0

# Download artifacts if needed
gh run download <run-id> --name ossuary-pi-image-arm64 --dir /tmp/release

# Manual upload if release upload fails
gh release upload v1.4.0 /tmp/release/*.zip --clobber
```

## Known Limitations

- **armhf (32-bit) builds**: Don't work on GitHub Actions (pi-gen-action limitation)
- **Schedule profile switching**: Rules are saved but "switch_profile" action only logs, doesn't change startup command yet
- **Connection loss overlay**: `show_overlay` behavior option exists but not implemented (may not be needed)

## Testing Checklist

After build completes:
1. [ ] Flash image with Pi Imager + WiFi customization → verify auto-connects
2. [ ] Boot without customization → verify welcome page shows
3. [ ] Connect to Ossuary-Setup → verify captive portal works
4. [ ] Delete a system-saved network → verify it's removed from nmcli
5. [ ] Set a schedule rule → verify it triggers at the right time
6. [ ] Disconnect network → reconnect → verify page refreshes via CDP
