# Ossuary Pi - User Guide

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/ossuary-dev/ossuary-pi.git
cd ossuary-pi

# Run installer (requires sudo)
sudo ./install.sh
```

### First Time Setup

1. **If your Pi has no WiFi configured:**
   - Look for WiFi network "Ossuary-Setup"
   - Connect to it (no password required)
   - Browser should open captive portal automatically
   - Select your WiFi network and enter password
   - Device will restart networking and connect

2. **If your Pi already has WiFi:**
   - Find your Pi's IP address
   - Open browser to `http://[pi-ip]:8080`
   - Access the control panel directly

## Control Panel Features

### Accessing the Control Panel

- **URL**: `http://[pi-hostname]:8080` or `http://[pi-ip]:8080`
- **Example**: `http://raspberrypi.local:8080` or `http://192.168.1.100:8080`

### Status Bar

Shows real-time status of:
- **WiFi**: Connection status and SSID
- **Captive Portal**: Active when in AP mode
- **Process Manager**: Running/stopped status
- **Config Server**: Always active when accessible

### Service Management

Control three core services:

1. **WiFi Connect**
   - Start: Activates WiFi management
   - Stop: Disables automatic AP mode
   - Restart: Refreshes WiFi connection

2. **Process Manager**
   - Start: Begins running your command
   - Stop: Stops your command
   - Restart: Restarts your command

3. **Config Server**
   - Restart: Refreshes web interface

### Startup Command Configuration

Enter any command to run automatically at boot:

#### Simple Examples
```bash
# Python script
python3 /home/pi/my_script.py

# Node.js application
node /home/pi/app/server.js

# Shell script
/home/pi/scripts/startup.sh
```

#### GUI Application Examples
```bash
# Chrome in kiosk mode
DISPLAY=:0 chromium --kiosk https://your-app.com

# Chrome with advanced options
DISPLAY=:0 chromium --kiosk --noerrdialogs --disable-infobars --enable-features=Vulkan --enable-unsafe-webgpu --ignore-gpu-blocklist https://your-app.com

# Firefox in fullscreen
DISPLAY=:0 firefox --kiosk https://your-app.com
```

### Testing Commands

Before saving a command:
1. Enter the command in the input field
2. Click **Test** button
3. View output in the Test Output tab
4. Stop test with **Stop Test** button if needed
5. If successful, click **Save**

### Log Viewer

Four log tabs available:

1. **Process Output**: Your command's output
2. **WiFi Connect**: Network connection logs
3. **System**: Service logs
4. **Test Output**: Test command results

Features:
- **Refresh**: Update logs manually
- **Clear View**: Clear display (doesn't delete logs)
- **Auto Refresh**: Toggle automatic updates

## Common Use Cases

### Running a Web Dashboard

```bash
# Chromium in kiosk mode
DISPLAY=:0 chromium --kiosk --noerrdialogs --disable-infobars \
  --disable-session-crashed-bubble --disable-infobars \
  --check-for-update-interval=86400 \
  https://your-dashboard.com
```

### Digital Signage Display

```bash
# With auto-refresh every hour
DISPLAY=:0 chromium --kiosk --noerrdialogs \
  --disable-infobars --app=https://your-signage.com \
  --auto-reload-tab --auto-reload-interval=3600
```

### Python Application with Virtual Environment

```bash
/home/pi/venv/bin/python /home/pi/app/main.py
```

### Node.js Application

```bash
cd /home/pi/my-app && npm start
```

### Multiple Commands

Create a shell script and run that:

```bash
#!/bin/bash
# /home/pi/startup.sh
export NODE_ENV=production
cd /home/pi/my-app
npm start
```

Then set startup command to:
```bash
/home/pi/startup.sh
```

## Troubleshooting

### Can't Access Control Panel

1. **Check Pi is on network:**
   ```bash
   ip addr show
   hostname -I
   ```

2. **Check service is running:**
   ```bash
   sudo systemctl status ossuary-web
   ```

3. **Try different address formats:**
   - `http://raspberrypi.local:8080`
   - `http://[ip-address]:8080`
   - Make sure it's port 8080, not 80

### Command Not Running

1. **Check process manager status:**
   ```bash
   sudo systemctl status ossuary-startup
   ```

2. **View logs:**
   ```bash
   tail -f /var/log/ossuary-process.log
   ```

3. **Common issues:**
   - Missing full path to executable
   - Permissions (scripts need execute permission)
   - GUI apps need DISPLAY=:0 prefix

### WiFi Not Connecting

1. **Check WiFi Connect status:**
   ```bash
   sudo systemctl status wifi-connect
   ```

2. **Reset WiFi configuration:**
   ```bash
   sudo systemctl stop wifi-connect
   sudo rm /etc/NetworkManager/system-connections/*
   sudo systemctl start wifi-connect
   ```

3. **Device will create "Ossuary-Setup" AP for reconfiguration**

### Chrome/GUI Apps Not Starting

1. **Ensure display server is running:**
   ```bash
   echo $XDG_SESSION_TYPE  # Should show x11 or wayland
   ```

2. **For X11, check display:**
   ```bash
   echo $DISPLAY  # Should show :0 or similar
   xset q  # Should not error
   ```

3. **For Wayland:**
   ```bash
   echo $WAYLAND_DISPLAY  # Should show wayland-0 or similar
   ```

4. **Add proper prefix to command:**
   - X11: `DISPLAY=:0 chromium...`
   - Wayland: May work without prefix on modern systems

### Service Won't Start

1. **Check for errors:**
   ```bash
   sudo journalctl -u [service-name] -n 50
   ```

2. **Try manual start:**
   ```bash
   sudo systemctl start [service-name]
   ```

3. **Reload if configuration changed:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart [service-name]
   ```

## Manual Commands

### Service Control
```bash
# Start services
sudo systemctl start wifi-connect
sudo systemctl start ossuary-startup
sudo systemctl start ossuary-web

# Stop services
sudo systemctl stop wifi-connect
sudo systemctl stop ossuary-startup
sudo systemctl stop ossuary-web

# Restart services
sudo systemctl restart wifi-connect
sudo systemctl restart ossuary-startup
sudo systemctl restart ossuary-web

# Check status
sudo systemctl status wifi-connect
sudo systemctl status ossuary-startup
sudo systemctl status ossuary-web
```

### Configuration
```bash
# View configuration
cat /etc/ossuary/config.json

# Edit configuration manually
sudo nano /etc/ossuary/config.json

# Reload configuration (send SIGHUP to process manager)
sudo kill -HUP $(cat /var/run/ossuary-process.pid)
```

### Logs
```bash
# View process manager logs
tail -f /var/log/ossuary-process.log

# View service logs
sudo journalctl -u wifi-connect -f
sudo journalctl -u ossuary-startup -f
sudo journalctl -u ossuary-web -f

# View last 50 lines
sudo journalctl -u wifi-connect -n 50
```

## Uninstalling

To completely remove Ossuary Pi:

```bash
cd /opt/ossuary
sudo ./uninstall.sh
```

This will:
- Stop and disable all services
- Remove installed files
- Optionally preserve your configuration
- Restore NetworkManager control

## Tips and Best Practices

### For GUI Applications

1. **Always use full paths** to executables
2. **Include DISPLAY=:0** for X11 systems
3. **Test commands first** using the Test button
4. **Kill existing instances** - Process manager does this automatically for Chrome

### For Reliability

1. **Use absolute paths** in commands
2. **Set proper permissions** on scripts (chmod +x)
3. **Handle failures** in your scripts
4. **Check logs** if commands don't work
5. **Test after reboot** to ensure persistence

### For Performance

1. **Avoid frequent restarts** - Process manager handles this
2. **Use appropriate timeouts** in your applications
3. **Monitor resource usage** with `htop` or `top`
4. **Clean up logs** periodically if disk space is limited

## Getting Help

### View System Information
```bash
# Ossuary version and status
/opt/ossuary/check-status.sh

# Service status
sudo systemctl status ossuary-*

# Network status
ip addr show
iwconfig
```

### Debug Mode
```bash
# Run process manager in foreground for debugging
sudo /opt/ossuary/process-manager.sh

# Test WiFi Connect
sudo wifi-connect --help
```

### Support

- GitHub Issues: https://github.com/ossuary-dev/ossuary-pi/issues
- Documentation: `/opt/ossuary/docs/`
- Logs: `/var/log/ossuary-*.log`