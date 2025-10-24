# Port Configuration Strategy

## The Problem
Both services want to use port 80:
- **WiFi Connect**: Captive portal (during AP mode)
- **Config Server**: Always-on configuration interface

## The Solution

### Current Implementation (Simple)

1. **WiFi Connect on Port 80** (Primary)
   - Runs during AP mode for captive portal
   - Automatically stops when connected to WiFi
   - Serves our custom UI from `/opt/ossuary/custom-ui/`

2. **Config Server on Port 8080** (Secondary)
   - Always running when connected to WiFi
   - Accessible at `http://[hostname]:8080`
   - Provides persistent configuration interface

### How It Works

#### During AP Mode (No WiFi)
- WiFi Connect runs on port 80
- Shows captive portal automatically
- Config server on 8080 (but not accessible since no network)
- Access: Connect to "Ossuary-Setup" → http://192.168.4.1

#### When Connected to WiFi
- WiFi Connect stops (frees port 80)
- Config server runs on port 8080
- Access: http://[hostname]:8080 or http://[device-ip]:8080

## Alternative Approaches (Not Implemented)

### Option 1: Smart Proxy
Use a single service on port 80 that:
- Detects if in AP mode → proxy to WiFi Connect
- Detects if connected → serve config interface
- More complex but seamless port 80 access

### Option 2: Nginx Reverse Proxy
- Nginx on port 80
- Routes based on hostname/path
- `/` → WiFi Connect or Config Server
- Most complex but most flexible

### Option 3: WiFi Connect Always
- Keep WiFi Connect always running
- Modify it to serve config interface when connected
- Requires modifying WiFi Connect source

## Current Port Layout

| Service | Port | When Active | Purpose |
|---------|------|------------|---------|
| WiFi Connect | 80 | AP Mode only | Captive portal |
| Config Server | 8080 | Always | Configuration UI |
| SSH | 22 | Always | Remote access |

## Accessing the Interfaces

### To Configure WiFi (AP Mode)
1. Connect to "Ossuary-Setup" network
2. Auto-redirected to captive portal
3. Or browse to: http://192.168.4.1

### To Configure Startup Commands (Connected)
1. Browse to: http://[hostname]:8080
2. Or: http://[device-ip]:8080
3. Example: http://raspberrypi:8080

## Troubleshooting Port Conflicts

If you get port conflicts:

```bash
# Check what's using port 80
sudo lsof -i :80
sudo netstat -tulpn | grep :80

# Check what's using port 8080
sudo lsof -i :8080

# Stop conflicting services
sudo systemctl stop nginx
sudo systemctl stop apache2

# Restart our services
sudo systemctl restart wifi-connect
sudo systemctl restart ossuary-web
```

## Future Improvements

To make it cleaner, we could:

1. **Implement Smart Proxy** (`/scripts/smart-proxy.py`)
   - Single service on port 80
   - Auto-detects mode
   - Seamless experience

2. **Modify WiFi Connect**
   - Add config server functionality
   - Keep everything on port 80

3. **Use Different Ports**
   - Move captive portal to 8080
   - Keep config on 80
   - But captive portal detection works better on 80

For now, the simple approach (80 for AP, 8080 for config) works reliably!