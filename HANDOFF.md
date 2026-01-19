# Ossuary Pi - Development Handoff

*Last updated: 2026-01-19*

## Project Overview

Ossuary Pi is a kiosk system for Raspberry Pi, built primarily for LumenCanvas displays but supporting any web kiosk or custom command. It provides WiFi failover (AP mode when disconnected), a web-based configuration UI, process management with auto-restart, and scheduled behaviors.

## Repository Structure

```
ossuary-pi/
├── scripts/
│   ├── process-manager.sh      # Main process manager (runs user command)
│   ├── config-server.py        # Web UI backend (port 8081)
│   ├── wifi-connect-manager.sh # Manages WiFi vs AP mode switching
│   ├── connection-monitor.sh   # Monitors connectivity, triggers behaviors
│   └── captive-portal-proxy.py # Handles captive portal detection (port 80)
├── custom-ui/
│   ├── index.html              # Main config UI (WiFi, Networks, Display, Control, Logs, Schedule)
│   └── welcome.html            # First-run welcome page
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
│     └── No networks → Start wifi-connect (AP mode on :8080)     │
│  3. ossuary-web starts (config server on :8081)                 │
│  4. ossuary-startup starts (process manager)                    │
│     ├── No config → Show welcome page in kiosk Chromium         │
│     └── Has config → Run startup_command                        │
│  5. ossuary-connection-monitor starts (watches connectivity)    │
│  6. captive-portal-proxy starts (handles portal detection :80)  │
└─────────────────────────────────────────────────────────────────┘
```

## Port Assignments

| Port | Service | When Active |
|------|---------|-------------|
| 80 | captive-portal-proxy | Always (redirects to appropriate backend) |
| 8080 | wifi-connect | AP mode only (no WiFi configured) |
| 8081 | ossuary-web (config-server.py) | Always |

## Key Files Deep Dive

### scripts/process-manager.sh
- **Purpose**: Keeps the user's configured command running
- **Key functions**:
  - `detect_display_server()` - Detects Wayland vs X11 (checks socket file, env vars, running compositors)
  - `enhance_chromium_command()` - Adds kiosk flags, Wayland platform, GPU flags
  - `show_welcome_page()` - Displays setup instructions on first run
  - `prepare_chromium()` - Clears crash state before launch
  - `run_command()` - Executes command with process group management
- **Signals**: SIGHUP triggers config reload, SIGTERM/SIGINT for graceful shutdown
- **Wayland support**: Detects labwc/wayfire compositors, adds `--ozone-platform=wayland`

### scripts/config-server.py
- **Purpose**: REST API and static file server for web UI
- **Port**: 8081 (default, configurable via `--port`)
- **Key endpoints**:
  - `GET/POST /api/startup` - Startup command
  - `GET/POST /api/schedule` - Schedule rules
  - `GET/POST /api/saved-networks` - WiFi networks
  - `GET /api/system/info` - Hostname, IP, config URLs
  - `GET /api/process/status` - Process state (running/stopped/failed)
  - `POST /api/process/start|stop|restart` - Process control
  - `POST /api/startup/clear` - Clear startup command
  - `GET /api/logs/{service}?lines=N` - Service logs
  - `GET /api/screenshot` - Capture display screenshot
  - `GET/POST /api/display/power` - Display on/off control
  - `POST /connect` - WiFi Connect compatible endpoint
  - `GET /networks` - Nearby WiFi scan
- **Config file**: `/etc/ossuary/config.json`

### custom-ui/index.html
- **Single HTML file** with embedded CSS and JS
- **Tabs**: WiFi, Networks, Display, Control, Logs, Schedule
- **Design**: Paper/ink aesthetic, Space Mono font, teal accent
- **Features**:
  - WiFi scanning and connection
  - Saved networks management
  - Preset configs (LumenCanvas, Web Kiosk, Custom)
  - **LumenCanvas preset**: Configurable Chromium flags (Wayland, WebGPU, Vulkan, GPU raster, etc.)
  - **Control tab**: Start/Stop/Restart process, clear command, display power, screenshot
  - **Logs tab**: View service logs (ossuary-process, ossuary-web, connection-monitor, wifi-connect)
  - Schedule rules with day picker
  - Timezone configuration

### custom-ui/welcome.html
- **Purpose**: First-run welcome page shown when no command configured
- **Content**: Instructions to connect to Ossuary-Setup WiFi and configure
- **Features**: Auto-refresh to detect when command is configured

## Configuration Schema

**Location**: `/etc/ossuary/config.json`

```json
{
  "version": 2,
  "startup_command": "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 chromium --ozone-platform=wayland --kiosk ...",
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
    "rules": []
  }
}
```

## Recent Changes (2026-01-19)

### New Features

1. **Configurable Chromium Flags in UI** (`custom-ui/index.html`)
   - LumenCanvas preset now has toggle switches for all flags:
     - Display: Kiosk mode, auto-play media
     - GPU: WebGPU (with Pi 5 warning), Vulkan, GPU rasterization
     - Browser: Wayland mode, no first-run, disable translate/notifications/crash prompts, isolated profile
   - Command preview textarea shows generated command
   - Web Kiosk preset also updated with Wayland support

2. **Control Tab** (`custom-ui/index.html`)
   - Process status with live indicator (green/yellow/red)
   - Start/Stop/Restart buttons
   - Clear startup command button
   - Display power on/off controls
   - Screenshot capture and download
   - Page refresh button

3. **Logs Tab** (`custom-ui/index.html`)
   - Service selector dropdown
   - Configurable line count (50/100/500)
   - Real-time log viewing from journalctl

4. **New API Endpoints** (`scripts/config-server.py`)
   - `GET /api/process/status` - Returns state, command, child PID
   - `GET /api/logs/{service}?lines=N` - Fetch service logs
   - Enhanced stop/start/restart with message responses

### Bug Fixes

1. **Wayland Detection** (`scripts/process-manager.sh`)
   - Fixed false positive when only XDG_RUNTIME_DIR was set
   - Now checks for Wayland socket file (`/run/user/{uid}/wayland-0`)
   - Properly detects labwc compositor (Pi OS 2024+ default)

2. **Welcome Page Launch** (`scripts/process-manager.sh`)
   - Fixed environment variable setup for Wayland
   - Removed problematic single quotes from file:// URL
   - Added `--no-first-run`, `--disable-default-apps`, `--disable-notifications` flags
   - Uses correct user ID for XDG_RUNTIME_DIR

3. **Port Consistency**
   - Fixed all references to use port 8081 for config server
   - Updated: config-server.py, index.html, install.sh, check-status.sh

4. **Kiosk Flags**
   - Removed `--start-maximized` (conflicts with `--kiosk`)
   - Added isolated user data directory (`--user-data-dir=/home/pi/.config/chromium-kiosk`)

### Package Updates

- Changed `chromium-browser` to `chromium` in `stage-ossuary/00-install-ossuary/00-packages` (correct package name for Pi OS Trixie/Debian 13)

## Environment

- **Target OS**: Raspberry Pi OS Trixie (2026) - Debian 13
- **Display Server**: Wayland with labwc compositor (default), X11 fallback
- **Python**: 3.9+ (no external dependencies)
- **Browser**: Chromium (package name: `chromium`)
- **WiFi**: NetworkManager (not wpa_supplicant)

## pi-gen Build

The GitHub Actions workflow builds Pi images on:
- Tag push (`v*`)
- Manual workflow dispatch

**Image features**:
- Based on RPi-Distro/pi-gen with Trixie release
- All Ossuary services pre-installed and enabled
- Pi Imager settings (hostname, WiFi, SSH) work correctly

## Known Issues / Tech Debt

1. **Pi-gen build failing** - See `PI_GEN_BUILD_ISSUE.md` for full investigation notes
2. **No config encryption**: WiFi passwords stored in plaintext in config.json
3. **No HTTPS**: Config server uses HTTP only
4. **Schedule timezone**: Auto-detect uses system timezone but UI doesn't show what it detected
5. **WebGPU on Pi 5**: May degrade performance - UI includes warning

## Testing Checklist

- [ ] Fresh install on clean Pi OS Trixie
- [ ] Upgrade from previous version
- [ ] AP mode activates when no WiFi configured
- [ ] WiFi connection from captive portal
- [ ] Welcome page shows on first boot (no command)
- [ ] Startup command runs after config
- [ ] Process auto-restarts on crash
- [ ] Web UI accessible at hostname.local:8081
- [ ] Control tab: start/stop/restart work
- [ ] Logs tab: shows service logs
- [ ] LumenCanvas preset generates correct Wayland command
- [ ] Schedule rules execute at correct times
- [ ] pi-gen image builds successfully

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
curl http://localhost:8081/api/status
curl http://localhost:8081/api/process/status

# View logs via API
curl "http://localhost:8081/api/logs/ossuary-process?lines=50"
```

---

## Contact

Repository: https://github.com/lumencanvas/ossuary-pi
