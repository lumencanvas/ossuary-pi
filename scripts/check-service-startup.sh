#!/bin/bash

# Check why ossuary-startup service might not be starting

echo "=========================================="
echo "Service Startup Diagnostics"
echo "=========================================="
echo ""

# Check if services are enabled
echo "Service enablement status:"
systemctl is-enabled ossuary-startup 2>/dev/null && echo "✓ ossuary-startup is enabled" || echo "✗ ossuary-startup is NOT enabled"
systemctl is-enabled wifi-connect-manager 2>/dev/null && echo "✓ wifi-connect-manager is enabled" || echo "✗ wifi-connect-manager is NOT enabled"
systemctl is-enabled ossuary-web 2>/dev/null && echo "✓ ossuary-web is enabled" || echo "✗ ossuary-web is NOT enabled"

echo ""

# Check service status
echo "Service runtime status:"
systemctl is-active ossuary-startup && echo "✓ ossuary-startup is running" || echo "✗ ossuary-startup is NOT running"
systemctl is-active wifi-connect-manager && echo "✓ wifi-connect-manager is running" || echo "✗ wifi-connect-manager is NOT running"
systemctl is-active ossuary-web && echo "✓ ossuary-web is running" || echo "✗ ossuary-web is NOT running"

echo ""

# Check for failures
echo "Service failure status:"
if systemctl is-failed ossuary-startup >/dev/null 2>&1; then
    echo "⚠ ossuary-startup has failed!"
    echo "Recent logs:"
    journalctl -u ossuary-startup -n 10 --no-pager
fi

echo ""

# Check network targets
echo "Network target status:"
systemctl is-active network-online.target && echo "✓ network-online.target is active" || echo "✗ network-online.target is NOT active"
systemctl is-active NetworkManager.service && echo "✓ NetworkManager is active" || echo "✗ NetworkManager is NOT active"

echo ""

# Check if startup command is configured
echo "Configuration check:"
if [ -f /etc/ossuary/config.json ]; then
    echo "✓ Config file exists"
    if grep -q "startup_command" /etc/ossuary/config.json; then
        echo "✓ Startup command is configured:"
        grep "startup_command" /etc/ossuary/config.json | sed 's/.*"startup_command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/  Command: \1/'
    else
        echo "✗ No startup command configured"
    fi
else
    echo "✗ Config file missing"
fi

echo ""

# Check process manager log
echo "Process manager log (last 10 lines):"
if [ -f /var/log/ossuary-process.log ]; then
    tail -10 /var/log/ossuary-process.log
else
    echo "No process log found"
fi

echo ""
echo "=========================================="
echo "To manually start the service:"
echo "  sudo systemctl start ossuary-startup"
echo ""
echo "To view full logs:"
echo "  journalctl -u ossuary-startup -f"
echo "=========================================="