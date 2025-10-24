# Persistent Configuration Page Implementation

## Overview
Added a lightweight Python web server that provides persistent configuration access on port 80, allowing users to manage startup commands even when connected to WiFi (not just in AP mode).

## Components Added

### 1. Config Server (`/scripts/config-server.py`)
- Simple Python HTTP server using built-in libraries
- Runs on port 80 (uses CAP_NET_BIND_SERVICE capability)
- Serves the custom UI files
- Provides REST API endpoints:
  - `GET /startup` - Returns current startup command
  - `POST /startup` - Updates startup command
  - `GET /status` - Returns system status (WiFi, hostname, etc.)
- Handles CORS for cross-origin requests

### 2. SystemD Service (`ossuary-web.service`)
- Runs config server persistently
- Starts after network is online
- Auto-restarts on failure
- Uses capabilities instead of root for port 80 binding

### 3. Updated Custom UI
- Checks for persistent server availability
- Falls back to localStorage when in AP mode
- Shows system status when connected to WiFi
- Seamless experience between AP and connected modes

## How It Works

### In AP Mode (No WiFi)
1. WiFi Connect serves the custom UI on port 80 (captive portal)
2. Users configure WiFi network
3. Startup commands saved to localStorage temporarily
4. After WiFi connection, config server takes over

### When Connected to WiFi
1. Config server runs on port 80
2. Accessible via:
   - http://[hostname]
   - http://[hostname].local
   - http://[device-ip]
3. Users can:
   - View connection status
   - Update startup commands
   - See system information
4. Changes immediately written to `/etc/ossuary/config.json`
5. Startup service restarted to apply changes

## Benefits

1. **Always Accessible**: No need to disconnect WiFi to change settings
2. **Consistent Interface**: Same UI whether in AP or connected mode
3. **Lightweight**: Simple Python server, minimal resources
4. **Reliable**: SystemD ensures it's always running
5. **User-Friendly**: Access via hostname, no need to know IP

## Security Considerations

1. **No Authentication**: Config page has no password
   - Suitable for trusted networks only
   - Could add basic auth if needed

2. **Port 80 Access**: Requires special capability
   - Uses CAP_NET_BIND_SERVICE instead of running as root
   - More secure than root execution

3. **Command Execution**: Startup commands run as root
   - Users should be aware of security implications
   - Could add user switching in future

## Testing

Test the persistent config page:

```bash
# Check service status
sudo systemctl status ossuary-web

# Test endpoints
curl http://localhost/status
curl http://localhost/startup

# Update command
curl -X POST http://localhost/startup \
  -H "Content-Type: application/json" \
  -d '{"command": "echo test"}'

# Check logs
journalctl -u ossuary-web -f
```

## Future Enhancements

1. **Authentication**: Add optional password protection
2. **HTTPS**: Support secure connections
3. **More Config Options**: Network settings, system info
4. **Command Validation**: Check syntax before saving
5. **WebSocket**: Real-time status updates

## Conclusion

The persistent config page makes Ossuary Pi much more user-friendly by allowing configuration changes without disconnecting from WiFi. This is especially useful for headless deployments where users want to adjust settings remotely.