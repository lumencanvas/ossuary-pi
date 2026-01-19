# Ossuary Pi - Architecture Planning Document

> **Note**: This is a historical planning document created during development. Many features described here have been implemented. For current documentation, see [README.md](../README.md) and [USER_GUIDE.md](USER_GUIDE.md).

---

## Original Planning Notes

### Initial State (What Existed)
- WiFi failover using Balena WiFi Connect (broadcasts AP when disconnected)
- Basic captive portal with WiFi config + simple startup command textarea
- Process manager that keeps user command running
- Config server on port 8080
- LumenCanvas design system partially implemented (paper/ink theme, Space Mono, corner accents)

### Current Gaps Identified

1. **Captive Portal UX**
   - Does NOT communicate that config is also available when connected
   - No indication of what happens after WiFi connects
   - No mention of hostname.local:8080 access

2. **Startup Command Configuration**
   - Just a raw textarea - no presets or guided experience
   - No LumenCanvas-specific integration
   - No WebGPU kiosk presets
   - No refresh/restart behavior options

3. **Process Management**
   - Single process only
   - No scheduling capabilities
   - No refresh on connection events
   - No interval-based refresh

4. **Installer**
   - Doesn't configure auto-login
   - Doesn't show hostname.local format
   - Chromium keyring password prompts not addressed

---

## Proposed Architecture

### Core Concepts

```
┌─────────────────────────────────────────────────────────────────┐
│                    OSSUARY KIOSK SYSTEM                         │
├─────────────────────────────────────────────────────────────────┤
│  PROFILES (preset configurations)                               │
│  ├── LumenCanvas Runner (first-class citizen)                   │
│  ├── WebGPU Kiosk (generic chromium with WebGPU)               │
│  └── Custom Command (raw command input)                         │
├─────────────────────────────────────────────────────────────────┤
│  PROCESSES (managed instances)                                   │
│  ├── Primary Process (always runs)                              │
│  ├── Scheduled Processes (time-based)                           │
│  └── Fallback Process (when primary fails)                      │
├─────────────────────────────────────────────────────────────────┤
│  BEHAVIORS (event handlers)                                     │
│  ├── On Connection Lost → pause/refresh/switch                  │
│  ├── On Connection Regained → refresh/restart                   │
│  ├── On Interval → refresh page/restart process                 │
│  └── On Schedule → switch to different preset                   │
├─────────────────────────────────────────────────────────────────┤
│  NETWORK LAYER                                                  │
│  ├── Connected Mode → Config on :8080                           │
│  └── AP Mode → Captive Portal + Config combined                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Model

### `/etc/ossuary/config.json`

```json
{
  "version": 2,
  "hostname": "ossuary-kiosk",

  "active_profile": "lumencanvas",

  "profiles": {
    "lumencanvas": {
      "type": "lumencanvas",
      "name": "LumenCanvas Display",
      "enabled": true,
      "config": {
        "canvas_url": "https://lumencanvas.studio/canvas/abc123",
        "flags": {
          "kiosk": true,
          "disable_gpu_sandbox": true,
          "enable_webgpu": true,
          "disable_features_translate": true,
          "noerrdialogs": true,
          "disable_infobars": true,
          "password_store_basic": true,
          "autoplay_policy": "no-user-gesture-required"
        }
      }
    },
    "webgpu_kiosk": {
      "type": "webgpu_kiosk",
      "name": "WebGPU Kiosk",
      "enabled": false,
      "config": {
        "url": "https://example.com",
        "flags": {
          "kiosk": true,
          "enable_webgpu": true
        }
      }
    },
    "custom": {
      "type": "custom",
      "name": "Custom Command",
      "enabled": false,
      "config": {
        "command": ""
      }
    }
  },

  "behaviors": {
    "on_connection_lost": {
      "action": "show_overlay",
      "overlay_message": "Reconnecting...",
      "timeout_action": "pause",
      "timeout_seconds": 60
    },
    "on_connection_regained": {
      "action": "refresh_page",
      "delay_seconds": 3
    },
    "scheduled_refresh": {
      "enabled": false,
      "type": "interval",
      "interval_minutes": 60
    },
    "scheduled_switch": {
      "enabled": false,
      "schedules": [
        {
          "time": "08:00",
          "profile": "lumencanvas",
          "days": ["mon", "tue", "wed", "thu", "fri"]
        },
        {
          "time": "18:00",
          "profile": "webgpu_kiosk",
          "days": ["mon", "tue", "wed", "thu", "fri"]
        }
      ]
    }
  },

  "display": {
    "rotation": 0,
    "overscan": false,
    "cursor_visible": false
  },

  "system": {
    "auto_update": false,
    "remote_management": false,
    "clasp_device_id": null
  }
}
```

---

## UI/UX Design

### Design System Application

Following LumenCanvas Design System:
- **Fonts**: Sora (headings), Space Mono (UI/labels), IBM Plex Mono (body)
- **Colors**: Paper (#f5f1eb), Ink (#1a1a1a), Teal (#0d9488)
- **Accent Elements**: Corner brackets, noise texture, registration marks
- **Dark Mode**: Full support with inverted paper/ink

### Page Structure

#### 1. Captive Portal (AP Mode) - `/`

```
┌────────────────────────────────────────────────────┐
│ ┌──                                           ──┐  │
│                                                    │
│   [LumenCanvas Logo - Animated Loading Spinner]    │
│                                                    │
│   ── OSSUARY KIOSK ──                             │
│   Device Setup                                     │
│                                                    │
│   ┌────────────────────────────────────────────┐  │
│   │ WiFi    │ Startup   │ Advanced             │  │
│   └────────────────────────────────────────────┘  │
│                                                    │
│   ┌ AVAILABLE NETWORKS ─────────────────────────  │
│   │  ● HomeNetwork         ████████░░  85%     │  │
│   │    GuestNetwork        █████░░░░░  50%     │  │
│   │    OfficeWiFi          ███░░░░░░░  30%     │  │
│   └─────────────────────────────────────────────  │
│                                                    │
│   ┌ MANUAL ENTRY ───────────────────────────────  │
│   │ SSID:     [_________________________]      │  │
│   │ Password: [_________________________]      │  │
│   └─────────────────────────────────────────────  │
│                                                    │
│   [ CONNECT ]                                      │
│                                                    │
│   ┌ AFTER CONNECTING ───────────────────────────  │
│   │ Access configuration at:                    │  │
│   │ http://ossuary-kiosk.local:8080            │  │
│   │                                             │  │
│   │ Or continue setup below in Startup tab      │  │
│   └─────────────────────────────────────────────  │
│                                                    │
│ └──                                           ──┘  │
└────────────────────────────────────────────────────┘
```

#### 2. Startup Tab - Preset Selection

```
┌────────────────────────────────────────────────────┐
│   STARTUP CONFIGURATION                            │
│                                                    │
│   What will this kiosk display?                    │
│                                                    │
│   ┌─────────────────────────────────────────────┐ │
│   │ [LC Logo]  LUMENCANVAS                      │ │
│   │            Display a LumenCanvas project    │ │
│   │            WebGPU • Auto-refresh • Kiosk    │ │
│   │                              [ SELECT → ]   │ │
│   └─────────────────────────────────────────────┘ │
│                                                    │
│   ┌─────────────────────────────────────────────┐ │
│   │ [🌐]       WEB KIOSK                        │ │
│   │            Any URL in fullscreen kiosk      │ │
│   │            WebGPU enabled • No toolbars     │ │
│   │                              [ SELECT → ]   │ │
│   └─────────────────────────────────────────────┘ │
│                                                    │
│   ┌─────────────────────────────────────────────┐ │
│   │ [⌨]       CUSTOM COMMAND                    │ │
│   │            Run any shell command            │ │
│   │            Scripts • Apps • Services        │ │
│   │                              [ SELECT → ]   │ │
│   └─────────────────────────────────────────────┘ │
│                                                    │
└────────────────────────────────────────────────────┘
```

#### 3. LumenCanvas Configuration (after selecting)

```
┌────────────────────────────────────────────────────┐
│   ← Back                                           │
│                                                    │
│   [LC Logo Animated]  LUMENCANVAS SETUP            │
│                                                    │
│   ┌ CANVAS URL ─────────────────────────────────  │
│   │ Paste your LumenCanvas project URL:         │  │
│   │ [https://lumencanvas.studio/canvas/______]  │  │
│   │                                             │  │
│   │ Or enter canvas ID: [____________]          │  │
│   └─────────────────────────────────────────────  │
│                                                    │
│   ┌ DISPLAY OPTIONS ────────────────────────────  │
│   │ [✓] Kiosk Mode (fullscreen, no escape)      │  │
│   │ [✓] Enable WebGPU                           │  │
│   │ [✓] Disable error dialogs                   │  │
│   │ [✓] Auto-play media                         │  │
│   │ [ ] Show cursor                             │  │
│   └─────────────────────────────────────────────  │
│                                                    │
│   ┌ REFRESH BEHAVIOR ───────────────────────────  │
│   │ When connection lost:                       │  │
│   │   (•) Show "Reconnecting..." overlay        │  │
│   │   ( ) Pause and wait                        │  │
│   │   ( ) Reload page immediately               │  │
│   │                                             │  │
│   │ When connection restored:                   │  │
│   │   (•) Refresh page                          │  │
│   │   ( ) Continue (no action)                  │  │
│   │                                             │  │
│   │ [✓] Auto-refresh every [60] minutes         │  │
│   └─────────────────────────────────────────────  │
│                                                    │
│   [ SAVE & APPLY ]                                 │
│                                                    │
│   ┌ ADVANCED ─────────────────────────────────── │
│   │ [ Edit raw command → ]                      │  │
│   └─────────────────────────────────────────────  │
│                                                    │
└────────────────────────────────────────────────────┘
```

#### 4. Control Panel (Connected Mode) - Extended

```
┌────────────────────────────────────────────────────┐
│ [LC Logo]  OSSUARY KIOSK                           │
│            ossuary-kiosk.local                     │
├─────────────┬──────────────────────────────────────┤
│             │                                      │
│  DASHBOARD  │  SYSTEM STATUS                       │
│  ─────────  │  ──────────────────                  │
│  • Overview │  ┌──────────────────────────────┐   │
│  • Profiles │  │ ● CONNECTED  HomeNetwork     │   │
│  • Schedule │  │   IP: 192.168.1.100          │   │
│  • Behavior │  │   Signal: 85%                │   │
│             │  └──────────────────────────────┘   │
│  SETTINGS   │                                      │
│  ─────────  │  ACTIVE PROFILE                     │
│  • Display  │  ──────────────────                  │
│  • Network  │  ┌──────────────────────────────┐   │
│  • System   │  │ [LC] LumenCanvas Display     │   │
│             │  │      Running since 08:00      │   │
│  ─────────  │  │      [Refresh] [Stop] [Edit] │   │
│  WiFi Setup │  └──────────────────────────────┘   │
│             │                                      │
│             │  QUICK ACTIONS                       │
│             │  ──────────────────                  │
│             │  [ Refresh Page ]                    │
│             │  [ Restart Process ]                 │
│             │  [ Switch Profile ▼ ]                │
│             │  [ Reboot System ]                   │
│             │                                      │
└─────────────┴──────────────────────────────────────┘
```

---

## Chromium Flag Reference

### Essential Kiosk Flags
```bash
--kiosk                              # Fullscreen, no UI
--noerrdialogs                       # No crash dialogs
--disable-infobars                   # No info bars
--disable-translate                  # No translate prompts
--disable-features=TranslateUI       # Really no translate
--autoplay-policy=no-user-gesture-required  # Auto-play media
--password-store=basic               # NO KEYRING PROMPTS
--disable-session-crashed-bubble     # No restore prompts
--disable-component-update           # No update prompts
--check-for-update-interval=31536000 # Yearly update check
```

### WebGPU/Performance Flags
```bash
--enable-features=Vulkan,UseSkiaRenderer,WebGPU
--enable-unsafe-webgpu               # Allow WebGPU
--disable-gpu-sandbox                # Sometimes needed for Pi
--ignore-gpu-blocklist               # Force GPU acceleration
--enable-gpu-rasterization           # GPU rendering
```

### Crash Recovery (run before chromium)
```bash
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/Default/Preferences
sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences
```

### Full LumenCanvas Command Template
```bash
DISPLAY=:0 chromium \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-translate \
  --disable-features=TranslateUI \
  --autoplay-policy=no-user-gesture-required \
  --password-store=basic \
  --disable-session-crashed-bubble \
  --enable-features=Vulkan,UseSkiaRenderer,WebGPU \
  --enable-unsafe-webgpu \
  --disable-gpu-sandbox \
  --ignore-gpu-blocklist \
  "https://lumencanvas.studio/canvas/YOUR_ID"
```

---

## Installer Improvements

### Auto-Login Configuration
```bash
# For desktop (GUI) auto-login
sudo raspi-config nonint do_boot_behaviour B4

# Or manually in /etc/lightdm/lightdm.conf:
[Seat:*]
autologin-user=pi
autologin-user-timeout=0
```

### Hostname with .local
```bash
HOSTNAME=$(hostname)
echo ""
echo "Access your kiosk at:"
echo "  http://${HOSTNAME}.local:8080"
echo "  http://$(hostname -I | awk '{print $1}'):8080"
```

### Idempotent Installer Pattern
```bash
# Check what needs updating
check_component_version() {
  local component=$1
  local installed_version=""
  local latest_version=""

  case $component in
    "wifi-connect")
      installed_version=$(wifi-connect --version 2>/dev/null || echo "0.0.0")
      latest_version="4.11.84"
      ;;
    "ui")
      installed_version=$(cat $INSTALL_DIR/version 2>/dev/null || echo "0")
      latest_version=$(cat $REPO_DIR/version 2>/dev/null || echo "1")
      ;;
  esac

  if [ "$installed_version" != "$latest_version" ]; then
    return 0  # Needs update
  fi
  return 1  # Up to date
}
```

---

## Process Manager Enhancements

### New Features Needed

1. **Connection Monitoring**
```bash
monitor_connection() {
  while true; do
    if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
      handle_connection_lost
    else
      if [ "$WAS_DISCONNECTED" = true ]; then
        handle_connection_regained
      fi
    fi
    sleep 5
  done
}
```

2. **Page Refresh via WebSocket/D-Bus**
```python
# In chromium, use remote debugging
# --remote-debugging-port=9222
# Then send: Page.reload()
import requests
response = requests.post('http://localhost:9222/json/version')
ws_url = response.json()['webSocketDebuggerUrl']
# Connect and send reload command
```

3. **Scheduled Refresh**
```bash
# Using cron or systemd timer
schedule_refresh() {
  local interval=$1
  while true; do
    sleep $((interval * 60))
    send_refresh_signal
  done
}
```

---

## API Endpoints (Enhanced)

### Current
- `GET /` - Serve UI
- `GET /api/status` - System status
- `GET /api/startup` - Current startup command
- `POST /api/startup` - Save startup command
- `GET /api/networks` - Available WiFi
- `POST /api/connect` - Connect to WiFi

### New Endpoints
- `GET /api/profiles` - List all profiles
- `GET /api/profiles/{id}` - Get profile details
- `POST /api/profiles/{id}` - Update profile
- `PUT /api/profiles` - Create profile
- `DELETE /api/profiles/{id}` - Delete profile
- `POST /api/profiles/{id}/activate` - Switch to profile
- `GET /api/behaviors` - Get behavior settings
- `POST /api/behaviors` - Update behaviors
- `POST /api/process/refresh` - Trigger page refresh
- `POST /api/process/restart` - Restart current process
- `POST /api/process/stop` - Stop current process
- `GET /api/system/info` - System info (hostname, IP, etc.)
- `POST /api/system/reboot` - Reboot system

---

## Implementation Phases

### Phase 1: Core Improvements
1. Update installer with auto-login, hostname.local display
2. Add `--password-store=basic` to all Chromium commands
3. Enhance captive portal messaging
4. Basic profile system (LumenCanvas, WebGPU, Custom)

### Phase 2: LumenCanvas Integration
1. LumenCanvas preset with easy URL input
2. Flag toggles with descriptions
3. Crash recovery integration
4. Connection event handling

### Phase 3: Advanced Features
1. Multiple profiles with enable/disable
2. Scheduled profile switching
3. Interval-based refresh
4. Remote management hooks (CLASP prep)

### Phase 4: Polish
1. Animated logo in UI
2. Status indicators
3. Log viewer in UI
4. Mobile-responsive design

---

## File Structure (Proposed)

```
ossuary-pi/
├── install.sh                    # Idempotent installer
├── uninstall.sh
├── check-status.sh
├── version                       # Version file for updates
│
├── scripts/
│   ├── process-manager.sh        # Enhanced with events
│   ├── config-server.py          # Extended API
│   ├── wifi-connect-manager.sh
│   ├── captive-portal-proxy.py
│   ├── connection-monitor.sh     # NEW: monitors connectivity
│   └── schedule-manager.py       # NEW: handles schedules
│
├── custom-ui/
│   ├── index.html                # Captive portal (enhanced)
│   ├── control-panel.html        # Connected mode dashboard
│   ├── assets/
│   │   ├── lumencanvas-logo.svg  # Static logo
│   │   ├── lumencanvas-loader.svg # Animated spinner
│   │   └── icons.svg             # Icon sprite
│   └── js/
│       ├── app.js                # Main application
│       ├── profiles.js           # Profile management
│       └── api.js                # API client
│
└── docs/
    ├── ARCHITECTURE.md
    ├── USER_GUIDE.md
    └── API_REFERENCE.md
```

---

## LumenCanvas Logo Integration

### Static Logo SVG (from logo explorer)
```svg
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <rect x="0" y="0" width="100" height="100" fill="#000"/>
  <rect x="0" y="0" width="50" height="100" fill="#fff"/>
  <rect x="50" y="50" width="50" height="50" fill="#fff"/>
  <polygon points="0,0 50,50 0,100" fill="#8ED3EF"/>
</svg>
```

### Animated Loading Spinner (from logo explorer)
```svg
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <clipPath id="canvasClip">
      <rect x="0" y="0" width="50" height="100"/>
      <rect x="50" y="50" width="50" height="50"/>
    </clipPath>
  </defs>
  <rect x="0" y="0" width="100" height="100" fill="#000"/>
  <rect x="0" y="0" width="50" height="100" fill="#fff"/>
  <rect x="50" y="50" width="50" height="50" fill="#fff"/>
  <polygon fill="#8ED3EF" clip-path="url(#canvasClip)">
    <animate attributeName="points"
      values="0,0 50,50 0,100;0,0 50,50 50,100;0,0 50,50 100,100;0,50 50,50 100,100;0,100 50,50 100,100;0,100 50,50 100,50;0,100 50,50 50,0;0,100 50,50 0,0;0,50 50,50 0,0;0,0 50,50 0,100"
      dur="2s" repeatCount="indefinite" calcMode="linear"/>
  </polygon>
</svg>
```

---

## Security Considerations

1. **Local-only by default** - Config server binds to local IPs only
2. **No credentials stored** - WiFi managed by NetworkManager
3. **Process isolation** - User commands run as non-root
4. **CLASP preparation** - Device claiming will use secure token exchange

---

## Future: CLASP Integration Hooks

```json
{
  "clasp": {
    "enabled": false,
    "device_id": null,
    "claim_token": null,
    "studio_url": "https://lumencanvas.studio",
    "sync_interval": 300,
    "allow_remote_commands": false
  }
}
```

The architecture is designed to be modular so CLASP integration can:
- Push profile updates remotely
- Trigger refresh/restart commands
- Monitor device health
- Claim devices to studio accounts

---

## Questions to Confirm

1. Should the control panel (connected mode) be on a different port than captive portal?
   - **Recommendation**: Same port 8080, different pages

2. Should we support multiple simultaneous processes?
   - **Recommendation**: Start with single active profile, add multi-process later

3. Should scheduled switching be cron-based or built-in?
   - **Recommendation**: Built-in with systemd timer fallback

4. Priority for Phase 1?
   - **Recommendation**: Installer fixes + LumenCanvas preset + enhanced messaging

