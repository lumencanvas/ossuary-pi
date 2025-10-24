# Ossuary Pi - Final Implementation (Complete Rewrite)

## Overview
Complete rewrite using Balena WiFi Connect as the core WiFi management solution. This replaces 2000+ lines of fragile custom code with a minimal 200-line wrapper around a proven, production-ready tool.

## What Changed

### Before (Old Implementation)
- 2000+ lines of custom Python/Bash code
- Git submodule dependency (raspi-captive-portal)
- Python service embedded as string in bash script
- Multiple "fix" scripts indicating broken functionality
- Unreliable AP mode activation
- SSH installation permanently disconnected users
- Complex Flask server with threading issues
- Hard-coded to wlan0 interface

### After (New Implementation)
- ~200 lines of wrapper code
- Direct installation of WiFi Connect binary
- Clean separation of concerns
- SSH-safe installation with background execution
- Reliable AP mode using proven Rust binary
- Simple startup command management
- Custom HTML UI (no Flask needed)
- Works with any WiFi interface

## Architecture

### Core Components

1. **Balena WiFi Connect** (v4.14.4)
   - Rust-based WiFi management binary
   - Handles AP mode, WiFi scanning, connection
   - Battle-tested in production (1.4k GitHub stars)
   - Native NetworkManager integration

2. **Custom UI** (/custom-ui/)
   - Pure HTML/CSS/JavaScript
   - Two-tab interface: WiFi Setup + Startup Command
   - No backend server required
   - Communicates directly with WiFi Connect API

3. **Startup Manager** (/scripts/startup-manager.sh)
   - Simple bash script
   - Reads command from config.json
   - Waits for network before executing
   - Proper error handling and logging

4. **SSH-Safe Installer**
   - Detects SSH sessions
   - Runs in background with nohup
   - Continues even if SSH disconnects
   - Auto-reboots after completion
   - Full logging to /tmp/ossuary-install.log

## Installation Process

### What Happens During Install

1. **Dependency Installation**
   - NetworkManager (if needed)
   - curl, jq for downloads
   - Python3 for config handling

2. **WiFi Connect Installation**
   - Downloads official binary from GitHub
   - Installs to /usr/local/bin/
   - Creates systemd service

3. **Custom UI Setup**
   - Copies HTML/CSS/JS to /opt/ossuary/custom-ui/
   - No compilation or building required
   - Ready to use immediately

4. **Service Configuration**
   - wifi-connect.service for AP mode
   - ossuary-startup.service for user commands
   - Both managed by systemd

5. **SSH Safety (if over SSH)**
   - Creates background installer
   - Shows progress while connected
   - Continues if disconnected
   - Auto-reboots when complete

## How It Works

### Normal Operation
1. Pi boots and tries to connect to saved WiFi
2. If WiFi available: Connects normally
3. If no WiFi after 60 seconds: Starts AP mode
4. Creates "Ossuary-Setup" open network
5. Users connect and see custom portal
6. Can configure WiFi or startup commands
7. After WiFi configured, returns to normal mode

### AP Mode Details
- SSID: "Ossuary-Setup" (configurable)
- IP: 192.168.4.1
- Portal: Automatic redirect to configuration
- Timeout: Returns to normal after 10 minutes idle

### Startup Commands
- Stored in /etc/ossuary/config.json
- Executed after network is ready
- Runs as root (configurable user possible)
- Full PATH environment set
- Logs to systemd journal

## File Structure

```
/opt/ossuary/
├── custom-ui/           # Custom HTML portal
│   ├── index.html      # Main interface
│   └── startup.html    # Startup config API
├── scripts/
│   ├── startup-manager.sh     # Executes startup commands
│   └── startup-config.py      # Config JSON handler
└── wifi-connect        # Binary (symlinked from /usr/local/bin)

/etc/ossuary/
└── config.json         # User configuration

/etc/systemd/system/
├── wifi-connect.service       # WiFi/AP management
└── ossuary-startup.service    # Startup command execution
```

## Key Improvements

### Reliability
- Uses production-ready WiFi Connect instead of custom code
- Proper systemd service management
- No Python threading issues
- Clean error handling

### Safety
- SSH-safe installation
- Graceful degradation
- Config preservation during uninstall
- Proper logging throughout

### Simplicity
- 90% less code to maintain
- No submodule dependencies
- Standard Pi OS tools (NetworkManager)
- Clear separation of concerns

### Compatibility
- Works with Pi OS Bookworm and Trixie
- Pi 4, Pi 5, Pi Zero 2 W support
- Any WiFi interface name
- Future-proof architecture

## Testing Performed

1. **SSH Installation**: Verified survives disconnection
2. **AP Mode**: Confirmed activation after WiFi loss
3. **Portal UI**: Tested WiFi configuration and startup commands
4. **Uninstall**: Clean removal with config preservation
5. **Reboot**: Services start correctly
6. **Network Recovery**: Reconnects after WiFi returns

## Known Limitations

1. Requires NetworkManager (standard in modern Pi OS)
2. Portal only accessible in AP mode (by design)
3. Startup commands run as root (security consideration)
4. No built-in command validation (user responsibility)

## Migration from Old Version

For users with existing installation:

1. **Backup configuration**:
   ```bash
   cp /etc/ossuary/config.json /tmp/config-backup.json
   ```

2. **Uninstall old version**:
   ```bash
   sudo ./uninstall.sh
   ```

3. **Install new version**:
   ```bash
   git pull origin main
   sudo ./install.sh
   ```

4. **Restore configuration**:
   ```bash
   cp /tmp/config-backup.json /etc/ossuary/config.json
   ```

## Deployment Recommendations

### For Production Use
1. Test thoroughly in your environment first
2. Consider security implications of open AP
3. Set appropriate AP timeout (default 10 minutes)
4. Monitor logs: `journalctl -u wifi-connect -f`

### For Development
1. Use local installation (not SSH) for testing
2. Check logs in /var/log/ossuary-startup.log
3. Manual AP mode: `sudo systemctl restart wifi-connect`

## Comparison with Alternatives

### vs RaspAP
- Lighter weight (no web server)
- Simpler (just WiFi + startup)
- Less features (no DHCP server, etc.)

### vs Plain NetworkManager
- Automatic AP fallback
- Web-based configuration
- No command line required

### vs Original Implementation
- Actually works reliably
- 90% less code
- Proven core technology
- SSH-safe installation

## Support and Maintenance

This implementation is designed to be:
- **Low maintenance**: Leverages proven tools
- **Easy to debug**: Clear logging, simple architecture
- **Forward compatible**: Uses standard Pi OS components
- **Community supported**: Based on popular open-source tools

## Conclusion

This complete rewrite achieves all original goals with 90% less custom code by leveraging Balena WiFi Connect. The result is more reliable, maintainable, and safer to deploy than the original implementation.