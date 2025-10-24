# Ossuary Pi - Implementation Status & Analysis

## Current Branch: simplified-captive-portal

## Overall Assessment
The codebase attempts to implement a WiFi failover captive portal system for Raspberry Pi but has significant architectural issues and relies on a problematic submodule approach.

## What's Actually Implemented

### Core Components

1. **install.sh** (576 lines)
   - Complex installation script with SSH detection
   - Attempts to integrate raspi-captive-portal submodule
   - Sets up Python venv with Flask
   - Creates systemd services
   - Has workarounds for network restart issues during SSH install

2. **monitor.py** (embedded in install.sh)
   - Python service that monitors WiFi/internet connectivity
   - Switches to AP mode after 60 seconds of failure
   - Manages Flask web interface lifecycle
   - Has manual AP mode flag support for testing

3. **Flask Web Interface** (src/web/app.py)
   - WiFi scanning and connection
   - Startup command configuration
   - AP mode toggle for testing
   - Status monitoring
   - Runs on port 3000 (redirected from port 80 via iptables)

4. **Web Templates**
   - base.html, index.html, wifi.html, startup.html
   - Basic Bootstrap UI
   - JavaScript for async operations

### Dependency Architecture
- Uses raspi-captive-portal as git submodule (GitHub: Splines/raspi-captive-portal)
- Attempts to leverage their hostapd/dnsmasq/dhcpcd configuration
- Disables their Node.js server in favor of Flask

## Critical Issues Found

### 1. Submodule Dependency Problem
- Relies on external git submodule that may not be maintained
- Submodule setup is fragile and may fail
- Integration is hacky with many workarounds

### 2. Network Service Management
- Dangerous dhcpcd restart during installation
- SSH installation has special handling to avoid disconnection
- Multiple conflicting approaches to manage network state

### 3. Service Architecture
- monitor.py is embedded as string in install.sh (poor practice)
- No proper Python package structure
- Services not properly isolated

### 4. Configuration Issues
- hostapd.conf hardcoded in install script
- dnsmasq.conf hardcoded in install script
- dhcpcd.conf modifications may conflict with system

### 5. Testing/Debugging Scripts
- Multiple "fix" scripts indicate underlying problems:
  - fix-ap-service.sh
  - fix-captive-portal.sh
  - force-ap-mode.sh
- These suggest the main implementation is unreliable

### 6. Security Concerns
- Open WiFi network for captive portal (no WPA)
- Flask secret key hardcoded
- Running services as root
- No input sanitization in some areas

### 7. Compatibility Issues
- Hardcoded to wlan0 interface
- May not work with newer Pi OS versions
- Assumes specific system configuration

## What Actually Happens on Install

1. Checks for root and SSH session
2. Initializes raspi-captive-portal submodule
3. Installs system packages (python3, flask, etc.)
4. Creates custom configs for hostapd/dnsmasq/dhcpcd
5. Runs modified captive portal setup (with dhcpcd restart skipped for safety)
6. Disables the submodule's Node.js server
7. Creates Python venv at /opt/ossuary
8. Embeds monitor.py service directly from install script
9. Creates systemd service files
10. Skips network restart if on SSH (requires reboot)

## User Experience Flow

### Normal Operation:
1. Pi boots and connects to saved WiFi
2. Monitor service runs checking connectivity every 30 seconds
3. Flask web interface available on device IP

### When WiFi Fails:
1. Monitor detects failure
2. After 60 seconds, starts AP mode
3. Creates "Ossuary-Setup" open network
4. Users connect and visit 192.168.4.1
5. Can scan/connect to new WiFi networks
6. Once connected, AP mode stops

### Manual Testing:
- Can force AP mode via web interface
- Creates /tmp/ossuary_manual_ap flag
- Auto-restores after 30 minutes

## File Organization Problems

- Mixed architecture (submodule + custom code)
- Scripts scattered in root directory
- No clear separation of concerns
- Multiple overlapping test/fix scripts
- Poor documentation of actual behavior

## Dependencies That Must Be Installed
- python3, python3-pip, python3-venv
- flask, werkzeug (via pip)
- hostapd, dnsmasq, dhcpcd
- iptables-persistent, netfilter-persistent
- git (for submodule)
- Standard networking tools (iwlist, wpa_cli, etc.)

## Configuration Files Modified
- /etc/dhcpcd.conf (appended)
- /etc/dnsmasq.conf (replaced)
- /etc/hostapd/hostapd.conf (created)
- /etc/wpa_supplicant/wpa_supplicant.conf (modified for WiFi)
- /etc/sysctl.conf or /etc/sysctl.d/99-ossuary.conf (IP forwarding)
- iptables rules (port 80 -> 3000 redirect)

## Known Failure Points
1. SSH installation may hang at dhcpcd restart
2. Submodule initialization may fail
3. AP mode may not start properly without fixes
4. WiFi reconnection after AP mode unreliable
5. Startup command service may fail silently
6. Port conflicts if other services use 3000
7. Interface name assumptions (wlan0) may be wrong

## Recommended Complete Rewrite
This codebase needs a ground-up rewrite using proven, modern tools rather than hacking together a submodule integration.