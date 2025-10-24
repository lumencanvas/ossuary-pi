#!/bin/bash

echo "==================================="
echo "Fixing Process Manager Restart Issue"
echo "==================================="
echo ""

# 1. Stop the service
echo "1. Stopping ossuary-startup service..."
sudo systemctl stop ossuary-startup
echo "   Done"
echo ""

# 2. Update the service file
echo "2. Updating service configuration..."
sudo cat > /etc/systemd/system/ossuary-startup.service << 'EOF'
[Unit]
Description=Ossuary Process Manager - Keeps User Command Running
After=network-online.target multi-user.target NetworkManager.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'until ping -c1 8.8.8.8 &>/dev/null || ping -c1 1.1.1.1 &>/dev/null; do sleep 5; done'
ExecStart=/opt/ossuary/process-manager.sh
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=180
RuntimeDirectory=ossuary
RuntimeDirectoryMode=0755

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
echo "   Service file updated"
echo ""

# 3. Update process manager script
echo "3. Updating process manager script..."

# Check if the source file exists
if [ -f "/Users/obsidian/Projects/ossuary-dev/ossuary-pi/scripts/process-manager.sh" ]; then
    sudo cp /Users/obsidian/Projects/ossuary-dev/ossuary-pi/scripts/process-manager.sh /opt/ossuary/
    echo "   Process manager updated from source"
else
    # Apply the PID file fix directly
    sudo sed -i 's|PID_FILE="/var/run/ossuary-process.pid"|PID_FILE="/run/ossuary/process.pid"|' /opt/ossuary/process-manager.sh

    # Add runtime directory creation if not present
    if ! grep -q "mkdir -p /run/ossuary" /opt/ossuary/process-manager.sh; then
        sudo sed -i '/^main() {/a\    # Ensure runtime directory exists\n    if [ ! -d "/run/ossuary" ]; then\n        mkdir -p /run/ossuary\n    fi\n' /opt/ossuary/process-manager.sh
    fi
    echo "   Process manager patched"
fi
echo ""

# 4. Clean up old PID files
echo "4. Cleaning up old PID files..."
sudo rm -f /var/run/ossuary-process.pid
sudo rm -f /var/run/ossuary-process.pid.child
sudo rm -f /var/run/ossuary-process.pid.actual
echo "   Done"
echo ""

# 5. Reload systemd
echo "5. Reloading systemd configuration..."
sudo systemctl daemon-reload
echo "   Done"
echo ""

# 6. Start the service
echo "6. Starting ossuary-startup service..."
sudo systemctl start ossuary-startup
sleep 2
echo ""

# 7. Check status
echo "7. Service status:"
echo "-------------------"
if systemctl is-active --quiet ossuary-startup; then
    echo "✓ Service is running"

    # Check if it's stable (wait a bit and check again)
    echo ""
    echo "Monitoring for stability (20 seconds)..."
    sleep 20

    if systemctl is-active --quiet ossuary-startup; then
        echo "✓ Service is stable (no restarts)"
    else
        echo "✗ Service restarted - checking logs..."
        journalctl -u ossuary-startup -n 20 --no-pager | tail -10
    fi
else
    echo "✗ Service failed to start"
    echo ""
    echo "Recent logs:"
    journalctl -u ossuary-startup -n 20 --no-pager
fi

echo ""
echo "==================================="
echo "Fix complete!"
echo ""
echo "To monitor the service:"
echo "  journalctl -u ossuary-startup -f"
echo ""
echo "To check if it's restarting:"
echo "  systemctl status ossuary-startup"
echo "==================================="