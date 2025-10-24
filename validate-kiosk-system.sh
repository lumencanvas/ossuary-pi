#!/bin/bash

# Comprehensive validation script for Ossuary Pi Kiosk System
# Tests all critical components for production readiness

PASS=0
WARN=0
FAIL=0

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS++))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARN++))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL++))
}

header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# 1. System Requirements Check
header "1. System Requirements"

# Check if running on Raspberry Pi
if [ -f /proc/device-tree/model ]; then
    model=$(cat /proc/device-tree/model)
    pass "Running on Raspberry Pi: $model"
else
    warn "Not running on Raspberry Pi - some features may not work"
fi

# Check OS version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$VERSION_CODENAME" == "bookworm" ]] || [[ "$VERSION_CODENAME" == "trixie" ]]; then
        pass "Compatible OS version: $PRETTY_NAME"
    else
        warn "Untested OS version: $PRETTY_NAME"
    fi
fi

# Check NetworkManager
if systemctl is-active --quiet NetworkManager; then
    pass "NetworkManager is running"
else
    fail "NetworkManager is not running"
fi

# 2. Installation Check
header "2. Installation Verification"

# Check critical files
critical_files=(
    "/opt/ossuary/scripts/wifi-connect-manager.sh"
    "/opt/ossuary/scripts/process-manager.sh"
    "/opt/ossuary/scripts/ensure-network-persistence.sh"
    "/etc/systemd/system/wifi-connect.service"
    "/etc/systemd/system/wifi-connect-manager.service"
    "/etc/systemd/system/ossuary-startup.service"
    "/etc/systemd/system/ossuary-web.service"
)

for file in "${critical_files[@]}"; do
    if [ -f "$file" ]; then
        pass "Found: $file"
    else
        fail "Missing: $file"
    fi
done

# Check WiFi Connect binary
if command -v wifi-connect >/dev/null; then
    pass "WiFi Connect binary installed"
else
    fail "WiFi Connect binary not found"
fi

# 3. Service Status
header "3. Service Status"

services=("wifi-connect-manager" "ossuary-web" "ossuary-startup")
for service in "${services[@]}"; do
    if systemctl is-enabled --quiet "$service"; then
        pass "$service is enabled"
    else
        fail "$service is not enabled"
    fi

    if systemctl is-active --quiet "$service"; then
        pass "$service is running"
    else
        warn "$service is not running (may be normal)"
    fi
done

# Check WiFi Connect (should only run when needed)
if systemctl is-active --quiet wifi-connect; then
    warn "WiFi Connect is running (captive portal active)"
else
    pass "WiFi Connect is not running (normal when connected)"
fi

# 4. Network Configuration
header "4. Network Configuration"

# Check for saved networks
if command -v nmcli >/dev/null; then
    saved_count=$(nmcli -t -f TYPE,NAME connection show 2>/dev/null | grep -c "^802-11-wireless:")
    if [ "$saved_count" -gt 0 ]; then
        pass "Found $saved_count saved WiFi network(s)"

        # Check autoconnect settings
        while IFS=: read -r type name; do
            if [ "$type" = "802-11-wireless" ]; then
                autoconnect=$(nmcli -t -f connection.autoconnect connection show "$name" 2>/dev/null | cut -d: -f2)
                if [ "$autoconnect" = "yes" ]; then
                    pass "Network '$name' has autoconnect enabled"
                else
                    warn "Network '$name' has autoconnect disabled"
                fi
            fi
        done < <(nmcli -t -f TYPE,NAME connection show 2>/dev/null)
    else
        warn "No saved WiFi networks found"
    fi
fi

# Check current connection
if iwgetid -r >/dev/null 2>&1; then
    ssid=$(iwgetid -r)
    if [ -n "$ssid" ]; then
        pass "Connected to WiFi: $ssid"

        # Check signal strength
        signal=$(iwconfig wlan0 2>/dev/null | grep "Signal level" | sed 's/.*Signal level=\([0-9-]*\).*/\1/')
        if [ -n "$signal" ]; then
            if [ "$signal" -gt -50 ]; then
                pass "Strong signal: $signal dBm"
            elif [ "$signal" -gt -70 ]; then
                warn "Moderate signal: $signal dBm"
            else
                warn "Weak signal: $signal dBm"
            fi
        fi
    else
        warn "Not connected to WiFi"
    fi
else
    warn "Unable to check WiFi status"
fi

# 5. Configuration Check
header "5. Configuration Validation"

CONFIG_FILE="/etc/ossuary/config.json"
if [ -f "$CONFIG_FILE" ]; then
    pass "Configuration file exists"

    # Validate JSON syntax
    if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
        pass "Configuration file has valid JSON syntax"

        # Check for startup command
        if grep -q "startup_command" "$CONFIG_FILE"; then
            cmd=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('startup_command',''))" 2>/dev/null)
            if [ -n "$cmd" ]; then
                pass "Startup command configured: $cmd"
            else
                warn "Startup command is empty"
            fi
        else
            warn "No startup command configured"
        fi
    else
        fail "Configuration file has invalid JSON syntax"
    fi
else
    fail "Configuration file missing"
fi

# 6. Process Manager Check
header "6. Process Manager Health"

PROCESS_LOG="/var/log/ossuary-process.log"
if [ -f "$PROCESS_LOG" ]; then
    # Check for recent restarts
    recent_restarts=$(tail -100 "$PROCESS_LOG" | grep -c "Starting process (attempt")
    if [ "$recent_restarts" -gt 5 ]; then
        warn "High restart count detected: $recent_restarts in recent logs"
    else
        pass "Process restart count normal: $recent_restarts"
    fi

    # Check for crash loops
    if tail -20 "$PROCESS_LOG" | grep -q "Too many restarts"; then
        fail "Process crash loop detected"
    else
        pass "No crash loops detected"
    fi
else
    warn "Process log not found"
fi

# Check if process is actually running
if [ -f "/var/run/ossuary-process.pid" ]; then
    pid=$(cat /var/run/ossuary-process.pid)
    if kill -0 "$pid" 2>/dev/null; then
        pass "Process manager is running (PID: $pid)"
    else
        fail "Process manager PID file exists but process not running"
    fi
fi

# 7. Boot Sequence Validation
header "7. Boot Sequence & Dependencies"

# Check service order
if systemctl list-dependencies multi-user.target | grep -q wifi-connect-manager; then
    pass "WiFi Connect Manager in boot sequence"
else
    warn "WiFi Connect Manager may not start on boot"
fi

# Check network target
if systemctl is-active --quiet network-online.target; then
    pass "Network online target reached"
else
    warn "Network online target not reached"
fi

# 8. Error Recovery Features
header "8. Error Recovery & Robustness"

# Check log rotation
if [ -f /etc/logrotate.d/ossuary ]; then
    pass "Log rotation configured"
else
    warn "Log rotation not configured - logs may grow large"
fi

# Check for backup config
if [ -f "${CONFIG_FILE}.backup" ] || [ -f "${CONFIG_FILE}.bak" ]; then
    pass "Configuration backup exists"
else
    warn "No configuration backup found"
fi

# 9. Captive Portal Check
header "9. Captive Portal Functionality"

# Check custom UI
if [ -d "/opt/ossuary/custom-ui" ]; then
    ui_files=$(find /opt/ossuary/custom-ui -name "*.html" -o -name "*.css" -o -name "*.js" | wc -l)
    if [ "$ui_files" -gt 0 ]; then
        pass "Custom UI installed ($ui_files files)"
    else
        warn "Custom UI directory exists but no files found"
    fi
else
    fail "Custom UI not installed"
fi

# Check portal accessibility
if systemctl is-active --quiet ossuary-web; then
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 | grep -q "200"; then
        pass "Web configuration interface accessible"
    else
        warn "Web configuration interface not responding"
    fi
fi

# 10. Performance & Resource Check
header "10. Performance & Resources"

# Check CPU usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
if (( $(echo "$cpu_usage < 80" | bc -l) )); then
    pass "CPU usage acceptable: ${cpu_usage}%"
else
    warn "High CPU usage: ${cpu_usage}%"
fi

# Check memory
mem_available=$(free -m | awk 'NR==2{printf "%.1f", $7/$2*100}')
if (( $(echo "$mem_available > 20" | bc -l) )); then
    pass "Memory available: ${mem_available}%"
else
    warn "Low memory available: ${mem_available}%"
fi

# Check disk space
disk_usage=$(df -h / | awk 'NR==2{print $5}' | sed 's/%//')
if [ "$disk_usage" -lt 80 ]; then
    pass "Disk usage acceptable: ${disk_usage}%"
else
    warn "High disk usage: ${disk_usage}%"
fi

# Summary
header "Validation Summary"

echo ""
echo "Results:"
echo "  Passed: $PASS"
echo "  Warnings: $WARN"
echo "  Failed: $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    if [ "$WARN" -eq 0 ]; then
        echo -e "${GREEN}✓ System is fully operational and ready for production!${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠ System is operational with minor issues. Review warnings above.${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ System has critical issues that need to be addressed!${NC}"
    echo ""
    echo "Recommended actions:"
    if ! systemctl is-active --quiet NetworkManager; then
        echo "  - Start NetworkManager: sudo systemctl start NetworkManager"
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "  - Create configuration: sudo mkdir -p /etc/ossuary && echo '{}' | sudo tee $CONFIG_FILE"
    fi
    if [ "$FAIL" -gt 5 ]; then
        echo "  - Reinstall system: sudo ./install.sh"
    fi
    exit 2
fi