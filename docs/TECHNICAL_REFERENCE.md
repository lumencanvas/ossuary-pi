# Ossuary Pi - Technical Reference

## System Requirements

### Hardware
- Raspberry Pi 3, 3B+, 4, 5, or Zero 2 W
- Minimum 8GB SD card
- WiFi capability (built-in or USB adapter)

### Software
- Pi OS Bookworm (2023) or newer
- Pi OS Trixie (2025) fully supported
- Python 3.7 or higher
- systemd 232 or higher
- NetworkManager 1.18 or higher

## Component Details

### WiFi Connect (Balena)

#### Binary Details
- **Version**: v4.11.84
- **Architecture Support**:
  - `armv7l` → `linux-rpi`
  - `aarch64` → `aarch64-unknown-linux-gnu`
- **Download URL Pattern**:
  ```
  https://github.com/balena-os/wifi-connect/releases/download/v{VERSION}/wifi-connect-{ARCH}.tar.gz
  ```

#### Command Line Options
```bash
wifi-connect \
  --portal-ssid "Ossuary-Setup" \        # AP network name
  --ui-directory /opt/ossuary/custom-ui \ # Custom web interface
  --activity-timeout 600 \                # Seconds before AP timeout
  --portal-listening-port 80              # Captive portal port
```

#### Environment Requirements
```bash
DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
```

### Process Manager

#### File Structure
```
/opt/ossuary/
├── process-manager.sh       # Main process manager script
├── scripts/
│   └── config-server.py     # Web configuration server
├── custom-ui/
│   ├── index.html           # WiFi Connect captive portal
│   ├── control-panel.html   # Main control interface
│   └── ...                  # Supporting files
└── docs/                    # Documentation
```

#### Process Manager Features

##### Signal Handling
- **SIGTERM**: Graceful shutdown with child cleanup
- **SIGINT**: Same as SIGTERM
- **SIGHUP**: Configuration reload without restart
- **SIGKILL**: Force termination (avoided when possible)

##### PID Management
```bash
/var/run/ossuary-process.pid       # Main manager PID
/var/run/ossuary-process.pid.child # Managed process PID
```

##### Environment Detection
```bash
# Display server detection priority
1. $XDG_SESSION_TYPE (most reliable)
2. $WAYLAND_DISPLAY (Wayland-specific)
3. $DISPLAY (X11-specific)
4. Process detection (pgrep Xorg/sway/weston)
```

##### Restart Logic
- Immediate restart for first 10 failures
- 30-second cooldown after 10 rapid failures
- Counter resets after successful cooldown period
- Configurable via `RESTART_DELAY` variable

### Configuration Server

#### HTTP Endpoints

##### GET Endpoints
```
GET /                       → Serves control-panel.html
GET /api/status            → System status JSON
GET /api/startup           → Current startup command
GET /api/services          → Service status
GET /api/logs/{type}       → Log content (process/wifi/system)
GET /api/test-output/{pid} → Test command output
```

##### POST Endpoints
```
POST /api/startup           → Save startup command
POST /api/service-control   → Control services
POST /api/test-command      → Test a command
POST /api/stop-test/{pid}   → Stop test process
```

#### Request/Response Formats

##### Status Response
```json
{
  "wifi_connected": true,
  "ssid": "MyNetwork",
  "ap_mode": false,
  "hostname": "raspberrypi"
}
```

##### Service Control Request
```json
{
  "service": "wifi-connect",
  "action": "restart"
}
```

##### Service Control Response
```json
{
  "success": true,
  "service": "wifi-connect",
  "action": "restart",
  "new_status": "active",
  "output": ""
}
```

## SystemD Service Specifications

### wifi-connect.service
```ini
[Unit]
Description=Balena WiFi Connect
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wifi-connect [options]
Restart=on-failure
RestartSec=10
Environment="DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"

[Install]
WantedBy=multi-user.target
```

### ossuary-startup.service
```ini
[Unit]
Description=Ossuary Process Manager
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/ossuary-process.pid
ExecStart=/opt/ossuary/process-manager.sh
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
```

### ossuary-web.service
```ini
[Unit]
Description=Ossuary Web Configuration Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ossuary
ExecStart=/usr/bin/python3 /opt/ossuary/scripts/config-server.py --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Configuration Schema

### /etc/ossuary/config.json
```json
{
  "startup_command": "string",  // Command to execute
  "environment": {              // Optional: Additional env vars
    "KEY": "value"
  },
  "restart_delay": 5,           // Optional: Seconds between restarts
  "max_restarts": 10            // Optional: Max rapid restarts
}
```

## Network Configuration

### NetworkManager Integration

WiFi Connect uses NetworkManager for connection management:

```bash
# Connection profiles stored in:
/etc/NetworkManager/system-connections/

# View connections
nmcli connection show

# Delete a connection
nmcli connection delete [name]
```

### Access Point Configuration

When no WiFi available, creates AP with:
- **SSID**: Ossuary-Setup
- **IP Range**: 192.168.42.1/24
- **DHCP**: Automatic via NetworkManager
- **DNS**: Self-hosted for captive portal

### Captive Portal Detection

Responds to standard captive portal detection endpoints:
- `/generate_204` (Android)
- `/hotspot-detect.html` (iOS)
- `/success.txt` (Windows)
- `/connecttest.txt` (Microsoft)

## Display Server Integration

### X11 Requirements
```bash
# Required packages
xset          # Display detection
xdpyinfo      # Alternative detection

# Environment
DISPLAY=:0 (or :1, etc)
XAUTHORITY=/home/[user]/.Xauthority
```

### Wayland Requirements
```bash
# Environment
WAYLAND_DISPLAY=wayland-0
XDG_RUNTIME_DIR=/run/user/[uid]
XDG_SESSION_TYPE=wayland

# Compositors supported
sway, weston, wayfire, mutter, kwin_wayland
```

### Chrome/Chromium Flags

#### Essential Flags
```bash
--kiosk                    # Full screen mode
--noerrdialogs            # Suppress error dialogs
--disable-infobars        # Remove info bars
--check-for-update-interval=86400  # Reduce update checks
```

#### Performance Flags
```bash
--enable-features=Vulkan           # GPU acceleration
--enable-unsafe-webgpu            # WebGPU support
--ignore-gpu-blocklist            # Force GPU usage
--enable-features=VaapiVideoDecoder  # Hardware video decode
--enable-features=CanvasOopRasterization  # Canvas optimization
```

#### Security/Privacy Flags
```bash
--password-store=basic    # Simple password storage
--disable-translate      # Disable translation prompts
--disable-features=TranslateUI
```

## File Permissions

### Required Permissions
```bash
/opt/ossuary/process-manager.sh     # 755 (rwxr-xr-x)
/opt/ossuary/scripts/*.py           # 755 (rwxr-xr-x)
/etc/ossuary/config.json           # 644 (rw-r--r--)
/var/log/ossuary-*.log             # 644 (rw-r--r--)
/var/run/ossuary-*.pid             # 644 (rw-r--r--)
```

### Directory Ownership
```bash
/opt/ossuary/            # root:root
/etc/ossuary/           # root:root
/var/log/               # root:root
/var/run/               # root:root
```

## Logging

### Log Locations
```
/var/log/ossuary-process.log    # Process manager output
/var/log/ossuary-install.log    # Installation log
journald:
  - wifi-connect                # WiFi Connect service
  - ossuary-startup             # Process manager service
  - ossuary-web                 # Web server service
```

### Log Rotation

Configure logrotate for process logs:
```
/etc/logrotate.d/ossuary
---
/var/log/ossuary-*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
```

## Security Considerations

### Service Security
- Services run with minimal required privileges
- Process manager drops to user privileges for command execution
- Web server binds to all interfaces but only on local network

### Network Security
- No external ports exposed by default
- AP mode creates isolated network
- WiFi passwords handled by NetworkManager (encrypted storage)

### Process Isolation
- User commands run as non-root user (pi or first user)
- Each process gets its own environment
- Cleanup on termination prevents zombie processes

## Performance Tuning

### System Boot Optimization

#### Service Dependencies
```
network.target → NetworkManager → wifi-connect
                                 ↓
                         network-online.target
                                 ↓
                         graphical.target → ossuary-startup
```

#### Startup Delays
- Network wait: 60 seconds maximum
- Display wait: 60 seconds maximum
- System stabilization: 10 seconds
- Service restart: 10 seconds

### Resource Management

#### Memory Usage
- WiFi Connect: ~50MB
- Config Server: ~20MB Python
- Process Manager: ~5MB bash
- User process: Variable

#### CPU Usage
- Idle: <1% total
- Active management: 2-5%
- Web requests: Spike to 10-15%

## Troubleshooting

### Debug Commands

#### Service Debugging
```bash
# Real-time service logs
journalctl -u [service] -f

# Verbose service status
systemctl status -l [service]

# Service dependency tree
systemctl list-dependencies [service]
```

#### Network Debugging
```bash
# NetworkManager status
nmcli device status
nmcli connection show

# WiFi signal strength
iwconfig wlan0

# IP configuration
ip addr show
ip route show
```

#### Process Debugging
```bash
# Check running processes
ps aux | grep ossuary
pgrep -f process-manager

# Monitor resource usage
htop -p $(pgrep -f process-manager)

# Trace system calls
strace -p $(cat /var/run/ossuary-process.pid)
```

### Common Issues and Solutions

#### Issue: Service fails to start
```bash
# Check for port conflicts
sudo netstat -tlpn | grep :80
sudo netstat -tlpn | grep :8080

# Verify binary exists
ls -la /usr/local/bin/wifi-connect
ls -la /opt/ossuary/process-manager.sh

# Check permissions
stat /opt/ossuary/process-manager.sh
```

#### Issue: GUI app won't start
```bash
# Verify display server
echo $XDG_SESSION_TYPE
ps aux | grep -E "Xorg|wayland"

# Test display access
DISPLAY=:0 xset q
DISPLAY=:0 glxinfo | grep "direct rendering"
```

#### Issue: WiFi won't connect
```bash
# Reset NetworkManager
sudo systemctl restart NetworkManager

# Clear connections
sudo rm /etc/NetworkManager/system-connections/*
sudo systemctl restart wifi-connect

# Check rfkill
rfkill list
rfkill unblock wifi
```

## API Testing

### Using curl

```bash
# Get status
curl http://localhost:8080/api/status

# Get services
curl http://localhost:8080/api/services

# Save command
curl -X POST http://localhost:8080/api/startup \
  -H "Content-Type: application/json" \
  -d '{"command":"echo Hello World"}'

# Control service
curl -X POST http://localhost:8080/api/service-control \
  -H "Content-Type: application/json" \
  -d '{"service":"wifi-connect","action":"restart"}'

# Test command
curl -X POST http://localhost:8080/api/test-command \
  -H "Content-Type: application/json" \
  -d '{"command":"ls -la"}'
```

### Using Python

```python
import requests
import json

# Base URL
base = "http://localhost:8080/api"

# Get status
r = requests.get(f"{base}/status")
print(json.dumps(r.json(), indent=2))

# Save command
r = requests.post(f"{base}/startup",
    json={"command": "python3 /home/pi/script.py"})
print(r.json())

# Control service
r = requests.post(f"{base}/service-control",
    json={"service": "ossuary-startup", "action": "restart"})
print(r.json())
```

## Version History

### Current Implementation (2024)
- WiFi Connect: v4.11.84
- Process Manager: v1.0
- Config Server: Enhanced v1.0
- Python: 3.7+ compatible
- SystemD: Modern unit configuration

### Key Changes from Original
- Replaced custom WiFi management with Balena WiFi Connect
- Added Wayland display server support
- Enhanced process management with hot reload
- RESTful API for all operations
- Professional web UI without emojis
- Improved Chrome/GUI application handling