# Ossuary Pi - Development Handoff

*Last updated: 2026-01-18*

## Project Overview

Ossuary Pi is a kiosk system for Raspberry Pi, built primarily for LumenCanvas displays but supporting any web kiosk or custom command. It provides WiFi failover (AP mode when disconnected), a web-based configuration UI, process management with auto-restart, and scheduled behaviors.

## Repository Structure

```
ossuary-pi/
├── scripts/
│   ├── process-manager.sh      # Main process manager (runs user command)
│   ├── config-server.py        # Web UI backend (port 8080)
│   ├── wifi-connect-manager.sh # Manages WiFi vs AP mode switching
│   ├── connection-monitor.sh   # Monitors connectivity, triggers behaviors
│   └── captive-portal-proxy.py # Handles captive portal detection (port 80)
├── custom-ui/
│   └── index.html              # Single-file web UI (WiFi, Networks, Display, Schedule tabs)
├── stage-ossuary/              # pi-gen stage for pre-built images
│   ├── prerun.sh
│   ├── EXPORT_IMAGE
│   └── 00-install-ossuary/
│       ├── 00-packages         # APT packages to install
│       ├── 00-run.sh           # Copies repo files into image
│       └── 00-run-chroot.sh    # Runs inside Pi filesystem (creates services)
├── .github/workflows/
│   └── build-image.yml         # GitHub Actions workflow for pi-gen builds
├── install.sh                  # Main installer script
├── uninstall.sh                # Removal script
├── check-status.sh             # Quick status checker
├── MULTI_PROCESS_PLAN.md       # Architecture plan for multiple processes feature
└── README.md                   # User documentation
```

## Services Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         BOOT SEQUENCE                           │
├─────────────────────────────────────────────────────────────────┤
│  1. NetworkManager starts                                       │
│  2. wifi-connect-manager checks for saved networks              │
│     ├── Networks found → Connect to WiFi                        │
│     └── No networks → Start wifi-connect (AP mode)              │
│  3. ossuary-web starts (config server on :8080)                 │
│  4. ossuary-startup starts (process manager)                    │
│     ├── No config → Show welcome page                           │
│     └── Has config → Run startup_command                        │
│  5. ossuary-connection-monitor starts (watches connectivity)    │
│  6. captive-portal-proxy starts (handles portal detection)      │
└─────────────────────────────────────────────────────────────────┘
```

## Key Files Deep Dive

### scripts/process-manager.sh
- **Purpose**: Keeps the user's configured command running
- **Key functions**:
  - `enhance_chromium_command()` - Adds kiosk flags, WebGPU, etc.
  - `show_welcome_page()` - Displays setup instructions on first run
  - `cleanup_chromium_state()` - Clears crash prompts before launch
  - `run_command()` - Executes command with process group management
- **Critical fix applied**: `log()` function now redirects to stderr (`>&2`) to prevent stdout corruption in command substitution
- **Signals**: SIGHUP triggers config reload, SIGTERM/SIGINT for graceful shutdown

### scripts/config-server.py
- **Purpose**: REST API and static file server for web UI
- **Port**: 8080
- **Key endpoints**:
  - `GET/POST /api/startup` - Startup command
  - `GET/POST /api/schedule` - Schedule rules
  - `GET/POST /api/saved-networks` - WiFi networks
  - `GET /api/system/info` - Hostname, IP, etc.
  - `POST /connect` - WiFi Connect compatible endpoint
  - `GET /networks` - Nearby WiFi scan
- **Config file**: `/etc/ossuary/config.json`

### custom-ui/index.html
- **Single HTML file** with embedded CSS and JS
- **Tabs**: WiFi, Networks, Display, Schedule
- **Design**: Paper/ink aesthetic, Space Mono font, teal accent
- **Features**:
  - WiFi scanning and connection
  - Saved networks management
  - Preset configs (LumenCanvas, Web Kiosk, Custom)
  - Schedule rules with day picker
  - Timezone configuration

### scripts/wifi-connect-manager.sh
- **Purpose**: Decides when to run AP mode vs normal WiFi
- **Logic**:
  1. Check if any saved WiFi connections exist
  2. If none, start wifi-connect (Balena WiFi Connect)
  3. If connected, stop wifi-connect
  4. Loop every 30 seconds

### scripts/connection-monitor.sh
- **Purpose**: Monitors connectivity and triggers behaviors
- **Behaviors**:
  - On connection lost: Show overlay (future)
  - On connection regained: Refresh page via xdotool
  - Scheduled refresh: At configured intervals

## Configuration Schema

**Location**: `/etc/ossuary/config.json`

```json
{
  "startup_command": "chromium --kiosk https://...",
  "saved_networks": [
    {
      "ssid": "NetworkName",
      "password": "...",
      "priority": 1,
      "auto_connect": true,
      "notes": "Office WiFi",
      "added_at": "2026-01-15T10:30:00Z",
      "last_connected": "2026-01-15T10:30:00Z"
    }
  ],
  "behaviors": {
    "on_connection_lost": {"action": "show_overlay", "timeout_seconds": 60},
    "on_connection_regained": {"action": "refresh_page", "delay_seconds": 3},
    "scheduled_refresh": {"enabled": false, "interval_minutes": 60}
  },
  "schedule": {
    "enabled": false,
    "timezone": "auto",
    "rules": [
      {
        "id": "rule-1",
        "name": "Morning Refresh",
        "enabled": true,
        "trigger": {"type": "time", "time": "08:00", "days": ["mon","tue","wed","thu","fri"]},
        "action": {"type": "refresh"}
      }
    ]
  }
}
```

## Recent Changes (This Session)

### Bug Fixes

1. **log() function stdout corruption** (`scripts/process-manager.sh:15`)
   - **Problem**: `log()` used `tee` which outputs to stdout. When called inside command substitution (`command=$(enhance_chromium_command "$cmd")`), log messages got captured and treated as part of the command, causing `bash: export: '[2026-01-18': not a valid identifier`
   - **Fix**: Added `>&2` to redirect tee output to stderr
   ```bash
   # Before (broken)
   log() { echo "[$(date)] $1" | tee -a "$LOG_FILE"; }

   # After (fixed)
   log() { echo "[$(date)] $1" | tee -a "$LOG_FILE" >&2; }
   ```

2. **SSH warning disable scope** (`install.sh`)
   - **Problem**: SSH warning removal only ran on fresh installs
   - **Fix**: Moved outside the `if [ "$mode" -eq 0 ]` block to run on all install modes

### Feature Additions

1. **pi-gen image builds** (`.github/workflows/build-image.yml`, `stage-ossuary/`)
   - GitHub Actions workflow builds Pi images on tag push
   - Creates versioned AND generic filename for stable "latest" URL
   - pi-gen stage copies repo and creates all systemd services

2. **UI loads existing config** (`custom-ui/index.html`)
   - `loadCurrentConfig()` fetches startup command on page load
   - `parseAndPopulateForms()` extracts URL/flags and populates forms
   - Visual "ACTIVE" badge shows which preset matches current config
   - Display tab refreshes config when switched to

3. **README updates**
   - Changed `chromium-browser` to `chromium` (correct command on modern Pi OS)

### Documentation

1. **MULTI_PROCESS_PLAN.md** - Architecture plan for multiple processes feature
   - Config schema v3 with named processes
   - One Chromium at a time with display selection
   - Unlimited background processes
   - New API endpoints
   - Schedule integration
   - Migration path from v1/v2

## Known Issues / Tech Debt

1. **Port 8080 sharing**: Both wifi-connect and ossuary-web use port 8080. They're mutually exclusive (wifi-connect runs in AP mode, ossuary-web when connected), but could cause confusion.

2. **No config encryption**: WiFi passwords stored in plaintext in config.json.

3. **Welcome page detection**: Currently checks if `startup_command` is empty. Could be more robust.

4. **xdotool for refresh**: Uses keyboard simulation (F5) which is fragile. Could use Chrome DevTools Protocol instead.

5. **No process output streaming**: Test command output requires polling. Could use WebSocket.

6. **Schedule timezone**: Auto-detect uses system timezone but UI doesn't show what it detected.

## Testing Checklist

- [ ] Fresh install on clean Pi OS
- [ ] Upgrade from previous version
- [ ] AP mode activates when no WiFi configured
- [ ] WiFi connection from captive portal
- [ ] Startup command runs after config
- [ ] Process auto-restarts on crash
- [ ] Web UI accessible at hostname.local:8080
- [ ] Schedule rules execute at correct times
- [ ] Connection monitor triggers refresh on reconnect
- [ ] pi-gen image builds successfully
- [ ] Pi Imager settings (hostname, WiFi) work with pre-built image

## Pending Work

1. **Push current changes** (waiting for user approval)
2. **Test log() fix** on actual Pi hardware
3. **Implement multiple processes feature** (see MULTI_PROCESS_PLAN.md)
4. **Add screenshots** for new Display tab active indicator

## Environment

- **Target OS**: Raspberry Pi OS Bookworm (2024) or Trixie (2025+)
- **Python**: 3.9+ (no external dependencies)
- **Browser**: Chromium (not chromium-browser)
- **WiFi**: NetworkManager (not wpa_supplicant)
- **Display**: X11 (Wayland support via XWayland)

## Useful Commands

```bash
# Check all services
./check-status.sh

# View process manager logs
cat /var/log/ossuary-process.log
journalctl -u ossuary-startup -f

# Restart process manager (reloads config)
sudo systemctl restart ossuary-startup

# Force AP mode
sudo systemctl start wifi-connect

# Test config server
curl http://localhost:8080/api/status

# Build pi-gen image locally (requires Docker)
# Usually done via GitHub Actions instead
```

## Security Audit Summary (2026-01-18)

### Critical Issues (5)

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Command Injection | process-manager.sh | 29-40, 340-346 | Unquoted vars in Python heredoc allow shell escape |
| Shell Injection in Wrapper | process-manager.sh | 350-400 | Unquoted `$extra_env` and `$clean_command` in heredoc |
| RCE via Test Command | config-server.py | 454-460 | `shell=True` with user input from POST `/api/test-command` |
| Plaintext Passwords | config-server.py | 815, 1068 | WiFi passwords stored unencrypted in config.json |
| Proxy Path Traversal | captive-portal-proxy.py | 116, 132-133 | No size/content validation on proxied requests |

### High Issues (8)

- Missing error checking in wifi-connect-manager.sh (nmcli failures)
- Race condition in PID management (process-manager.sh:407-413)
- File descriptor leak in test processes (config-server.py:452-470)
- Missing null checks in JSON parsing (connection-monitor.sh)
- No timeout on reboot subprocess (config-server.py:663)
- Service dependency ordering incomplete (00-run-chroot.sh)
- Timezone injection potential (config-server.py:754)
- Update mode skips dependencies (install.sh:445-493)

### Medium Issues (10)

- Glob pattern too broad for pkill
- Hardcoded ports without fallback
- Shallow config merge overwrites subtrees
- Missing HTTPS support
- Inconsistent HTTP status codes
- Missing schema validation

### Recommended Priority Fixes

1. **Immediate**: Quote all variables in shell heredocs
2. **Immediate**: Add `shlex.quote()` to config-server.py test command
3. **Soon**: Encrypt WiFi passwords with `cryptography` library
4. **Soon**: Add JSON schema validation
5. **Later**: Implement HTTPS with self-signed certs

Full audit details: See audit notes above.

---

## Contact

Repository: https://github.com/lumencanvas/ossuary-pi
