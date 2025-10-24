# WiFi Connect - Valid Command Line Flags

## Current Configuration (Correct)

The Ossuary Pi installation uses the following WiFi Connect flags:

```bash
/usr/local/bin/wifi-connect \
    --portal-ssid "Ossuary-Setup" \
    --ui-directory /opt/ossuary/custom-ui \
    --activity-timeout 600 \
    --portal-listening-port 80
```

## All Valid Flags

### Help Flags
- `-h, --help` - Prints help information
- `-V, --version` - Prints version information

### Configuration Options

| Flag | Environment Variable | Description |
|------|---------------------|-------------|
| `-d, --portal-dhcp-range` | `$PORTAL_DHCP_RANGE` | DHCP range of the captive portal WiFi network |
| `-g, --portal-gateway` | `$PORTAL_GATEWAY` | Gateway of the captive portal WiFi network |
| `-o, --portal-listening-port` | `$PORTAL_LISTENING_PORT` | Listening port of the captive portal web server |
| `-i, --portal-interface` | `$PORTAL_INTERFACE` | Wireless network interface to be used by WiFi Connect |
| `-p, --portal-passphrase` | `$PORTAL_PASSPHRASE` | WPA2 Passphrase of the captive portal WiFi network |
| `-s, --portal-ssid` | `$PORTAL_SSID` | SSID of the captive portal WiFi network |
| `-a, --activity-timeout` | `$ACTIVITY_TIMEOUT` | Exit if no activity for the specified timeout (seconds) |
| `-u, --ui-directory` | `$UI_DIRECTORY` | Web UI directory location |

## Common Mistakes

### Invalid Flag: `--gateway-interface`
**This flag does NOT exist!** If you see this error:
```
error: unexpected argument '--gateway-interface' found
```

The correct flag for specifying the interface is:
- `--portal-interface` (or `-i`)

However, it's recommended to let WiFi Connect auto-detect the interface.

## Recommended Configuration

For most Raspberry Pi setups:

```bash
wifi-connect \
    --portal-ssid "YourNetworkName" \
    --ui-directory /path/to/custom/ui \
    --activity-timeout 600 \
    --portal-listening-port 80
```

### Optional Additions

1. **Password-protected AP**:
   ```bash
   --portal-passphrase "yourpassword"
   ```

2. **Specific interface** (usually not needed):
   ```bash
   --portal-interface wlan0
   ```

3. **Custom DHCP range**:
   ```bash
   --portal-dhcp-range "192.168.42.2,192.168.42.254"
   ```

4. **Custom gateway**:
   ```bash
   --portal-gateway "192.168.42.1"
   ```

## Troubleshooting

### Checking Current Configuration

View the service configuration:
```bash
sudo cat /etc/systemd/system/wifi-connect.service
```

### Fixing Invalid Flags

If you have `--gateway-interface` in your service file:

```bash
# Remove the invalid flag
sudo sed -i 's/--gateway-interface [^ ]*//' /etc/systemd/system/wifi-connect.service

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart wifi-connect
```

### Testing WiFi Connect

Test with minimal configuration:
```bash
sudo wifi-connect --portal-ssid "Test-Network"
```

View all options:
```bash
wifi-connect --help
```

## Environment Variables

You can also configure WiFi Connect using environment variables instead of flags:

```bash
export PORTAL_SSID="Ossuary-Setup"
export UI_DIRECTORY="/opt/ossuary/custom-ui"
export ACTIVITY_TIMEOUT="600"
export PORTAL_LISTENING_PORT="80"

wifi-connect
```

This is useful when running from systemd with the `Environment=` directive.