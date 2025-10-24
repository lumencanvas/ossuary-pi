# Ossuary Pi - Technical Knowledge Base

## Important Technical Details

### Network Interface Management on Pi

#### Modern Pi OS (2024+)
- Uses NetworkManager by default on desktop images
- Uses dhcpcd on lite images
- Interface naming may use predictable names (not always wlan0)
- systemd-networkd available but not default

#### AP Mode Requirements
1. Stop wpa_supplicant to free the interface
2. Configure static IP on wlan0
3. Start hostapd for AP functionality
4. Start dnsmasq for DHCP/DNS
5. Configure iptables for routing/NAT

### Critical Service Order
1. wpa_supplicant must be stopped before hostapd
2. Interface must be configured before hostapd starts
3. dnsmasq needs interface to be up with IP
4. iptables rules must persist across reboots

### Known Gotchas

#### dhcpcd Restart Problem
- Restarting dhcpcd during installation kills network
- Especially problematic over SSH
- Current code tries to work around this but it's fragile

#### Interface State Management
```bash
# Proper sequence for AP mode
systemctl stop wpa_supplicant
ip link set wlan0 down
ip addr flush dev wlan0
ip link set wlan0 up
ip addr add 192.168.4.1/24 dev wlan0
systemctl start hostapd
systemctl start dnsmasq
```

#### Port Conflicts
- Port 3000 commonly used by development servers
- Port 80 requires root or capabilities
- iptables redirect (80->3000) requires persistence

### Python Virtual Environment
- Located at /opt/ossuary/venv
- Must activate before pip install
- Shebang must point to venv python

### Systemd Service Dependencies
```
network-online.target
  └── ossuary-monitor.service
       └── ossuary-startup.service (user command)
```

### File Permissions
- Config files need root ownership
- Services run as root (security issue)
- User startup command should run as non-root user

### Testing AP Mode
- Use manual flag: /tmp/ossuary_manual_ap
- Monitor service checks this flag to avoid interference
- Auto-cleanup after 30 minutes for safety

### WiFi Scanning
- iwlist requires root
- Takes 10-15 seconds to complete
- May fail if interface is in AP mode
- Results need parsing from raw output

### WPA Supplicant Configuration
- File: /etc/wpa_supplicant/wpa_supplicant.conf
- Adding networks requires wpa_cli reconfigure
- Password stored in plaintext (security issue)

### Flask Application
- Werkzeug server not production-ready
- No HTTPS/TLS support
- CORS not configured
- No rate limiting

### Captive Portal Mechanics
1. DNS hijacking via dnsmasq (all domains -> 192.168.4.1)
2. HTTP redirect via iptables (port 80 -> 3000)
3. No HTTPS redirect (would show cert errors)
4. Mobile devices detect via specific URLs

### Common Raspberry Pi Paths
- /boot/config.txt - boot configuration
- /boot/cmdline.txt - kernel parameters
- /etc/rc.local - legacy startup (deprecated)
- /home/pi - default user (may not exist on new installs)

### Network Configuration Files Impact
- dhcpcd.conf - affects all network interfaces
- dnsmasq.conf - affects DNS resolution
- hostapd.conf - defines AP characteristics
- wpa_supplicant.conf - stores WiFi credentials

### Service Restart vs Reload
- daemon-reload: re-reads service files
- restart: stops and starts service
- reload: sends HUP signal (not all services support)

### IP Forwarding Requirement
- Must be enabled for NAT/routing
- Set via sysctl or /proc/sys/net/ipv4/ip_forward
- Needs persistence across reboots

### Signal Handling in Python Services
- SIGTERM for graceful shutdown
- SIGINT for keyboard interrupt
- Cleanup must restore network state

### Debugging Commands
```bash
# Check WiFi interface state
iw dev wlan0 info

# Check IP configuration
ip addr show wlan0

# Check routing
ip route show

# Check DNS
cat /etc/resolv.conf

# Check service status
systemctl status hostapd dnsmasq wpa_supplicant

# View service logs
journalctl -u ossuary-monitor -f

# Check iptables rules
iptables -t nat -L -n -v

# Test connectivity
ping -c1 8.8.8.8

# Check processes
ps aux | grep -E "(hostapd|dnsmasq|wpa_supplicant|python)"
```

### Mobile Device Captive Portal Detection
- iOS: http://captive.apple.com/hotspot-detect.html
- Android: http://connectivitycheck.gstatic.com/generate_204
- Windows: http://www.msftconnecttest.com/connecttest.txt

These URLs should redirect to portal automatically.

### Security Best Practices (Not Implemented)
- Use WPA2 for AP instead of open network
- Implement rate limiting
- Use HTTPS with self-signed cert
- Sanitize all user inputs
- Run services as non-root where possible
- Encrypt stored WiFi passwords
- Implement session management
- Add CSRF protection

### Performance Considerations
- WiFi scanning blocks for 10-15 seconds
- Service restarts cause network interruption
- Python service uses ~20-30MB RAM
- Log rotation needed for long-term operation

### Compatibility Matrix
- Pi 4: Tested, works with fixes
- Pi 5: Untested, may have issues
- Pi Zero W: May work but underpowered
- Pi 3: Should work but untested
- Bookworm: Unknown compatibility
- Bullseye: Designed for this version