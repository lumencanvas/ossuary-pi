# Ossuary Pi - Implementation Documentation

## Overview

Ossuary Pi is a robust Raspberry Pi configuration system that provides automatic WiFi failover, captive portal setup, and persistent command execution with a web-based control panel. The system uses proven, production-ready components rather than custom implementations.

## Core Components

### 1. Balena WiFi Connect (v4.11.84)
- **Purpose**: Handles WiFi connectivity and automatic Access Point (AP) mode failover
- **Location**: `/usr/local/bin/wifi-connect`
- **Service**: `wifi-connect.service`
- **Port**: 80 (captive portal only active in AP mode)
- **Configuration**:
  - SSID: "Ossuary-Setup"
  - Activity timeout: 600 seconds
  - Custom UI directory: `/opt/ossuary/custom-ui`

### 2. Process Manager (`process-manager.sh`)
- **Purpose**: Keeps user commands running continuously with automatic restart
- **Location**: `/opt/ossuary/process-manager.sh`
- **Service**: `ossuary-startup.service`
- **Features**:
  - Automatic GUI/CLI detection
  - Wayland and X11 support
  - Chrome/Chromium process management
  - Hot configuration reload (SIGHUP)
  - Intelligent restart backoff
  - PID tracking and cleanup

### 3. Configuration Server (`config-server-enhanced.py`)
- **Purpose**: Web-based control panel and API server
- **Location**: `/opt/ossuary/scripts/config-server.py`
- **Service**: `ossuary-web.service`
- **Port**: 8080
- **Features**:
  - Service management (start/stop/restart)
  - Command testing with real-time output
  - Log viewing (process, WiFi, system)
  - Status monitoring
  - RESTful API endpoints

### 4. Web UI (`control-panel.html`)
- **Location**: `/opt/ossuary/custom-ui/control-panel.html`
- **Access**: `http://[device-ip]:8080`
- **Features**:
  - Real-time status indicators
  - Service controls
  - Command configuration
  - Test command execution
  - Multi-tab log viewer
  - Professional gradient design

## System Architecture

```
┌─────────────────────────────────────────────────┐
│                   User Access                    │
├─────────────────────────────────────────────────┤
│  AP Mode: http://192.168.42.1 (Captive Portal)  │
│  Normal:  http://[device-ip]:8080 (Control Panel)│
└─────────────────────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ WiFi Connect │ │ Config Server│ │Process Manager│
│   Port 80    │ │   Port 8080  │ │   (Service)  │
└──────────────┘ └──────────────┘ └──────────────┘
        │                │                │
        └────────────────┼────────────────┘
                         ▼
                ┌──────────────────┐
                │ /etc/ossuary/    │
                │   config.json    │
                └──────────────────┘
```

## Configuration Files

### `/etc/ossuary/config.json`
```json
{
  "startup_command": "DISPLAY=:0 chromium --kiosk https://example.com"
}
```

### Service Definitions

#### `wifi-connect.service`
- Manages WiFi connectivity and AP mode failover
- Starts after NetworkManager
- Restarts on failure with 10-second delay

#### `ossuary-startup.service`
- Runs the process manager
- Starts after network and graphical targets
- Type: forking with PID file tracking
- Automatic restart on failure

#### `ossuary-web.service`
- Runs the configuration web server
- Always available on port 8080
- Python 3 simple HTTP server

## Display Server Support

The system automatically detects and configures for both X11 and Wayland:

### Detection Methods
1. `$XDG_SESSION_TYPE` environment variable
2. `$WAYLAND_DISPLAY` for Wayland
3. `$DISPLAY` for X11
4. Process detection (Xorg, sway, weston, wayfire)

### Environment Setup

#### X11 Configuration
```bash
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
export XDG_SESSION_TYPE=x11
```

#### Wayland Configuration
```bash
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000
export XDG_SESSION_TYPE=wayland
export DISPLAY=:0  # Compatibility for XWayland
```

## GUI Application Support

### Chrome/Chromium Commands
The system properly handles complex Chrome commands with all flags:

```bash
DISPLAY=:0 chromium --kiosk --noerrdialogs --disable-infobars \
  --enable-features=Vulkan --enable-unsafe-webgpu \
  --ignore-gpu-blocklist --enable-features=VaapiVideoDecoder,CanvasOopRasterization \
  --password-store=basic https://example.com
```

### Features
- Automatic display server detection
- Process cleanup (kills existing Chrome instances)
- Environment variable preservation
- 60-second display wait timeout
- 10-second system stabilization delay at boot

## API Endpoints

### Status and Information
- `GET /api/status` - System status (WiFi, AP mode, hostname)
- `GET /api/services` - Service status for all services
- `GET /api/startup` - Current startup command

### Service Control
- `POST /api/service-control` - Start/stop/restart services
  ```json
  {
    "service": "wifi-connect|ossuary-startup|ossuary-web",
    "action": "start|stop|restart"
  }
  ```

### Command Management
- `POST /api/startup` - Save startup command
  ```json
  {
    "command": "python3 /home/pi/script.py"
  }
  ```

### Testing
- `POST /api/test-command` - Test a command
- `GET /api/test-output/{pid}` - Get test output
- `POST /api/stop-test/{pid}` - Stop test

### Logs
- `GET /api/logs/process` - Process manager logs
- `GET /api/logs/wifi` - WiFi Connect logs
- `GET /api/logs/system` - System logs

## Installation Process

1. **Dependency Installation**
   - NetworkManager (standard in Pi OS 2023+)
   - Python 3.7+
   - systemd

2. **WiFi Connect Installation**
   - Downloads from GitHub releases
   - Version: v4.11.84
   - Architecture detection (armv7/aarch64)
   - Binary installed to `/usr/local/bin/wifi-connect`

3. **Script Installation**
   - Process manager to `/opt/ossuary/`
   - Config server to `/opt/ossuary/scripts/`
   - Web UI to `/opt/ossuary/custom-ui/`

4. **Service Configuration**
   - Creates systemd service files
   - Enables services for boot startup
   - Configures proper dependencies

## Network Behavior

### Normal Operation
1. Device boots and attempts to connect to saved WiFi
2. If successful, config panel available at port 8080
3. User's startup command executes automatically

### Failover to AP Mode
1. If no WiFi connection after timeout
2. WiFi Connect creates AP "Ossuary-Setup"
3. Captive portal activates on port 80
4. Users can configure WiFi via portal

### After Configuration
1. WiFi Connect saves credentials
2. Device reconnects with new settings
3. AP mode deactivates
4. Normal operation resumes

## Log Files

- `/var/log/ossuary-process.log` - Process manager output
- `/var/log/ossuary-install.log` - Installation log
- `journalctl -u wifi-connect` - WiFi Connect logs
- `journalctl -u ossuary-startup` - Process manager service logs
- `journalctl -u ossuary-web` - Web server logs

## Troubleshooting Commands

```bash
# Service status
sudo systemctl status wifi-connect
sudo systemctl status ossuary-startup
sudo systemctl status ossuary-web

# View logs
sudo journalctl -u wifi-connect -f
tail -f /var/log/ossuary-process.log

# Manual service control
sudo systemctl restart wifi-connect
sudo systemctl restart ossuary-startup

# Configuration
cat /etc/ossuary/config.json

# Test WiFi Connect
sudo wifi-connect --help
```

## Security Considerations

1. **Service Isolation**: Services run with minimal privileges
2. **No Password Storage**: WiFi passwords managed by NetworkManager
3. **Local Access Only**: Config panel not exposed to internet
4. **Process Isolation**: User commands run as non-root user
5. **Signal Handling**: Proper cleanup on shutdown

## Compatibility

- **Hardware**: Raspberry Pi 3/4/5, Pi Zero 2 W
- **OS**: Pi OS Bookworm (2023), Pi OS Trixie (2025)
- **Display**: X11 and Wayland
- **Network**: NetworkManager (standard in modern Pi OS)
- **Python**: 3.7+ (compatible with Pi OS Bullseye through Trixie)

## Known Limitations

1. Captive portal requires device restart to switch modes
2. GUI apps require display server to be running
3. Config server must be accessed by IP or hostname
4. Process manager handles one command at a time

## Future Improvements

- Multiple command profiles
- Scheduled command execution
- Remote configuration API
- Metrics and monitoring
- Backup/restore functionality