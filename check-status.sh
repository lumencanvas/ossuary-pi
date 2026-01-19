#!/bin/bash

# Ossuary Pi - System Status Check
# Shows the status of all Ossuary services

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}           OSSUARY PI - SYSTEM STATUS                  ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

# Check if running as root for some commands
if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Note: Run with sudo for full diagnostics${NC}"
   echo ""
fi

echo -e "${BLUE}Services:${NC}"
echo "─────────────────────────────────────────────────────────"

# Helper function to check service
check_service() {
    local service=$1
    local description=$2
    local port=$3

    printf "%-35s" "$description"

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "${GREEN}● Running${NC}"
        if [ -n "$port" ]; then
            echo -e "                                    └─ Port $port"
        fi
        return 0
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo -e "${YELLOW}○ Enabled (not running)${NC}"
        return 1
    else
        echo -e "${RED}✗ Not found${NC}"
        return 2
    fi
}

# Check all services
check_service "wifi-connect-manager" "WiFi Connect Manager" ""
check_service "wifi-connect" "WiFi Connect (AP mode)" "8080"
check_service "ossuary-web" "Config Web Server" "8081"
check_service "ossuary-startup" "Process Manager" ""
check_service "ossuary-connection-monitor" "Connection Monitor" ""
check_service "captive-portal-proxy" "Captive Portal Proxy" "80"

echo ""
echo -e "${BLUE}Network:${NC}"
echo "─────────────────────────────────────────────────────────"

# WiFi Interface
WIFI_IF=$(ip link 2>/dev/null | grep -E '^[0-9]+: wl' | cut -d: -f2 | tr -d ' ' | head -n1)
if [ -n "$WIFI_IF" ]; then
    echo -e "Interface:      ${CYAN}$WIFI_IF${NC}"

    # Check if connected
    SSID=$(iwgetid -r 2>/dev/null)
    if [ -n "$SSID" ]; then
        echo -e "WiFi Status:    ${GREEN}Connected${NC}"
        echo -e "Network:        $SSID"
        IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        echo -e "IP Address:     $IP"
    else
        echo -e "WiFi Status:    ${YELLOW}Not connected${NC}"

        # Check if AP mode is active
        if systemctl is-active --quiet wifi-connect; then
            echo -e "AP Mode:        ${GREEN}Active${NC} (Ossuary-Setup)"
        fi
    fi
else
    echo -e "Interface:      ${RED}No WiFi detected${NC}"
fi

echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "─────────────────────────────────────────────────────────"

# Check config
if [ -f /etc/ossuary/config.json ]; then
    echo -e "Config file:    ${GREEN}Found${NC}"

    # Extract startup command
    CMD=$(python3 -c "
import json
try:
    with open('/etc/ossuary/config.json') as f:
        c = json.load(f)
        cmd = c.get('startup_command', '')
        if cmd:
            # Truncate long commands
            if len(cmd) > 50:
                print(cmd[:47] + '...')
            else:
                print(cmd)
except:
    pass
" 2>/dev/null)

    if [ -n "$CMD" ]; then
        echo -e "Startup cmd:    $CMD"
    else
        echo -e "Startup cmd:    ${YELLOW}(not configured)${NC}"
    fi
else
    echo -e "Config file:    ${YELLOW}Not found${NC}"
fi

echo ""
echo -e "${BLUE}Access:${NC}"
echo "─────────────────────────────────────────────────────────"

HOSTNAME=$(hostname)
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

if [ -n "$IP" ]; then
    echo -e "Control Panel:  ${CYAN}http://${HOSTNAME}.local:8081${NC}"
    echo -e "                http://${IP}:8081"
else
    echo -e "When in AP mode, connect to: ${CYAN}Ossuary-Setup${NC}"
    echo -e "Then visit:     http://192.168.42.1"
fi

echo ""
echo -e "${BLUE}Quick Commands:${NC}"
echo "─────────────────────────────────────────────────────────"
echo "View logs:      journalctl -u ossuary-startup -f"
echo "Restart all:    sudo systemctl restart ossuary-startup ossuary-web"
echo "Force AP mode:  sudo systemctl restart wifi-connect-manager"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"

# Summary
ISSUES=0
for svc in wifi-connect-manager ossuary-web ossuary-startup ossuary-connection-monitor; do
    if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        ISSUES=$((ISSUES + 1))
    fi
done

if [ $ISSUES -eq 0 ]; then
    echo -e "${GREEN}✓ All core services running${NC}"
else
    echo -e "${YELLOW}⚠ $ISSUES service(s) not running${NC}"
fi

echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
