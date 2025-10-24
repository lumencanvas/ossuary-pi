#!/bin/bash

# Test script for process manager issues

echo "=========================================="
echo "Process Manager Diagnostic Test"
echo "=========================================="
echo ""

# Create a test command that logs but doesn't exit
TEST_CONFIG="/tmp/ossuary-test-config.json"
cat > "$TEST_CONFIG" << EOF
{
    "startup_command": "while true; do date; sleep 10; done",
    "wifi_ssid": "",
    "wifi_password": ""
}
EOF

echo "Test configuration created at $TEST_CONFIG"
echo "Command: while true; do date; sleep 10; done"
echo ""

# Backup existing config if present
if [ -f /etc/ossuary/config.json ]; then
    echo "Backing up existing config..."
    sudo cp /etc/ossuary/config.json /etc/ossuary/config.json.backup
fi

# Copy test config
sudo cp "$TEST_CONFIG" /etc/ossuary/config.json

echo "Starting process manager in debug mode..."
echo "Watch the log to see if process restarts unnecessarily"
echo ""
echo "Log file: /var/log/ossuary-process.log"
echo ""

# Start tailing the log
echo "=== Process Manager Log ==="
sudo tail -f /var/log/ossuary-process.log &
TAIL_PID=$!

# Restart the service
echo "Restarting ossuary-startup service..."
sudo systemctl restart ossuary-startup

echo ""
echo "Monitor for 30 seconds..."
echo "The date should print every 10 seconds WITHOUT the process restarting"
echo ""

sleep 30

# Check how many times the process started
echo ""
echo "=== Analysis ==="
STARTS=$(sudo grep "Starting process (attempt" /var/log/ossuary-process.log | tail -10)
echo "Recent process starts:"
echo "$STARTS"

# Count restarts in last minute
RESTART_COUNT=$(echo "$STARTS" | wc -l)
echo ""
echo "Number of starts in recent log: $RESTART_COUNT"

if [ "$RESTART_COUNT" -gt 2 ]; then
    echo "⚠ WARNING: Process is restarting too frequently!"
    echo "Expected: 1-2 starts (initial + maybe one restart)"
    echo "Actual: $RESTART_COUNT starts"
else
    echo "✓ Process restart count seems normal"
fi

# Cleanup
kill $TAIL_PID 2>/dev/null

# Restore original config if it existed
if [ -f /etc/ossuary/config.json.backup ]; then
    echo ""
    echo "Restoring original configuration..."
    sudo mv /etc/ossuary/config.json.backup /etc/ossuary/config.json
    sudo systemctl restart ossuary-startup
fi

echo ""
echo "=========================================="
echo "Test complete. Check the log output above."
echo "If you see multiple 'Starting process' messages"
echo "for the same command, the restart bug is present."
echo "=========================================="