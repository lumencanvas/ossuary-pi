# Troubleshooting Guide

## WiFi Connect Service Not Starting

### Error: "No such file or directory"

This means the WiFi Connect binary wasn't installed properly.

**Quick Fix:**
```bash
sudo ./fix-wifi-connect.sh
```

**Manual Fix:**
```bash
# For Pi 4/5 (64-bit):
wget https://github.com/balena-os/wifi-connect/releases/download/v4.14.4/wifi-connect-linux-aarch64.tar.gz
tar -xzf wifi-connect-linux-aarch64.tar.gz
sudo mv wifi-connect /usr/local/bin/
sudo chmod +x /usr/local/bin/wifi-connect

# For Pi 3/Zero 2 W (32-bit):
wget https://github.com/balena-os/wifi-connect/releases/download/v4.14.4/wifi-connect-linux-armv7hf.tar.gz
tar -xzf wifi-connect-linux-armv7hf.tar.gz
sudo mv wifi-connect /usr/local/bin/
sudo chmod +x /usr/local/bin/wifi-connect

# Restart service
sudo systemctl restart wifi-connect
```

### Error: "Unable to locate executable"

The binary exists but can't be executed.

**Fix:**
```bash
# Check if binary exists
ls -la /usr/local/bin/wifi-connect

# Check dependencies
ldd /usr/local/bin/wifi-connect

# Install missing libraries if needed
sudo apt-get update
sudo apt-get install libssl1.1 libdbus-1-3
```

## AP Mode Not Starting

### No "Ossuary-Setup" Network

1. **Check WiFi Connect status:**
```bash
sudo systemctl status wifi-connect
sudo journalctl -u wifi-connect -n 50
```

2. **Verify NetworkManager is running:**
```bash
sudo systemctl status NetworkManager
# If not running:
sudo systemctl start NetworkManager
sudo systemctl enable NetworkManager
```

3. **Force AP mode for testing:**
```bash
# Disconnect from WiFi
sudo nmcli device disconnect wlan0
# Restart WiFi Connect
sudo systemctl restart wifi-connect
```

4. **Check for conflicting services:**
```bash
# Make sure dhcpcd is disabled
sudo systemctl stop dhcpcd
sudo systemctl disable dhcpcd
```

## Config Page Not Accessible

### Can't access http://[hostname]

1. **Check web service:**
```bash
sudo systemctl status ossuary-web
sudo journalctl -u ossuary-web -n 50
```

2. **Restart web service:**
```bash
sudo systemctl restart ossuary-web
```

3. **Check port 80:**
```bash
sudo netstat -tulpn | grep :80
# If something else is using port 80, stop it
```

4. **Test locally:**
```bash
curl http://localhost/status
```

## Startup Command Not Running

1. **Check service status:**
```bash
sudo systemctl status ossuary-startup
cat /var/log/ossuary-startup.log
```

2. **Verify configuration:**
```bash
cat /etc/ossuary/config.json
```

3. **Test command manually:**
```bash
# Run your command directly to see errors
bash -c "your command here"
```

4. **Common issues:**
- Use full paths (`/usr/bin/python3` not just `python3`)
- Check file permissions
- Ensure scripts are executable (`chmod +x`)

## Installation Issues

### SSH Disconnection During Install

The installer is designed to handle this:

1. Installation continues in background
2. System auto-reboots when done
3. Check install log after reconnecting:
```bash
cat /tmp/ossuary-install.log
```

### Installation Failed

1. **Check log:**
```bash
cat /tmp/ossuary-install.log
```

2. **Common fixes:**
```bash
# Update package lists
sudo apt-get update

# Install missing dependencies
sudo apt-get install -y curl wget jq network-manager

# Retry installation
sudo ./install.sh
```

## Debugging Commands

### Check All Services
```bash
sudo systemctl status wifi-connect ossuary-startup ossuary-web
```

### View All Logs
```bash
# WiFi Connect logs
sudo journalctl -u wifi-connect -f

# Startup service logs
sudo journalctl -u ossuary-startup -f
cat /var/log/ossuary-startup.log

# Web service logs
sudo journalctl -u ossuary-web -f
```

### Network Information
```bash
# Current WiFi status
iwgetid

# Network interfaces
ip addr show

# NetworkManager status
nmcli device status
nmcli connection show
```

### Test WiFi Connect Manually
```bash
# Stop service
sudo systemctl stop wifi-connect

# Run in foreground with debug output
sudo wifi-connect --portal-ssid "Test-AP" --activity-timeout 600
```

## Complete Reset

If nothing works, do a clean reinstall:

```bash
# Uninstall
sudo ./uninstall.sh

# Clean up
sudo rm -rf /opt/ossuary
sudo rm -rf /etc/ossuary
sudo rm -f /etc/systemd/system/wifi-connect.service
sudo rm -f /etc/systemd/system/ossuary-*.service

# Reinstall
git pull origin main
sudo ./install.sh
```

## Getting Help

If you're still having issues:

1. Run diagnostics:
```bash
sudo journalctl -u wifi-connect -n 100 > wifi-connect.log
sudo systemctl status wifi-connect ossuary-startup ossuary-web > services.log
uname -a > system.log
```

2. Check the tracking folder for detailed documentation:
```bash
ls -la tracking/
```

3. Report issues with logs attached