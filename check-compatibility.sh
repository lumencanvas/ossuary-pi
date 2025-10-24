#!/bin/bash

# Ossuary Pi - System Compatibility Check
# Verifies system meets requirements for Pi OS 2025 (Debian Trixie)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "==========================================="
echo "    Ossuary Pi - Compatibility Check"
echo "==========================================="
echo ""

COMPATIBLE=true
WARNINGS=0

# Check if running on Raspberry Pi
echo "Checking hardware..."
if [ -f /proc/device-tree/model ]; then
    MODEL=$(tr -d '\0' < /proc/device-tree/model)
    echo -e "${GREEN}✓${NC} Raspberry Pi detected: $MODEL"

    # Check specific models
    if echo "$MODEL" | grep -qE "Raspberry Pi (4|5|400)"; then
        echo -e "${GREEN}✓${NC} Pi 4/5 series - fully compatible"
    elif echo "$MODEL" | grep -qE "Raspberry Pi 3"; then
        echo -e "${YELLOW}⚠${NC} Pi 3 detected - should work but Pi 4/5 recommended"
        WARNINGS=$((WARNINGS + 1))
    elif echo "$MODEL" | grep -qE "Raspberry Pi Zero 2"; then
        echo -e "${GREEN}✓${NC} Pi Zero 2 W - compatible"
    else
        echo -e "${YELLOW}⚠${NC} Older Pi model - may have performance issues"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}✗${NC} Not running on Raspberry Pi hardware"
    COMPATIBLE=false
fi

echo ""

# Check OS version
echo "Checking operating system..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${BLUE}ℹ${NC} OS: $PRETTY_NAME"

    if [[ "$ID" == "raspbian" ]] || [[ "$ID" == "debian" ]]; then
        if [[ "$VERSION_ID" == "13" ]]; then
            echo -e "${GREEN}✓${NC} Debian 13 (Trixie) - latest Pi OS 2025"
        elif [[ "$VERSION_ID" == "12" ]]; then
            echo -e "${GREEN}✓${NC} Debian 12 (Bookworm) - Pi OS 2023-2024"
        elif [[ "$VERSION_ID" == "11" ]]; then
            echo -e "${YELLOW}⚠${NC} Debian 11 (Bullseye) - older but supported"
            WARNINGS=$((WARNINGS + 1))
        else
            echo -e "${RED}✗${NC} Unsupported Debian version: $VERSION_ID"
            COMPATIBLE=false
        fi
    else
        echo -e "${RED}✗${NC} Not running Raspberry Pi OS/Debian"
        COMPATIBLE=false
    fi
else
    echo -e "${RED}✗${NC} Cannot determine OS version"
    COMPATIBLE=false
fi

echo ""

# Check architecture
echo "Checking architecture..."
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
    echo -e "${GREEN}✓${NC} 64-bit ARM detected (optimal for Pi 4/5)"
elif [[ "$ARCH" == "armv7l" ]] || [[ "$ARCH" == "armhf" ]]; then
    echo -e "${GREEN}✓${NC} 32-bit ARM detected (compatible)"
else
    echo -e "${RED}✗${NC} Unsupported architecture: $ARCH"
    COMPATIBLE=false
fi

echo ""

# Check kernel version
echo "Checking kernel..."
KERNEL=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL" | cut -d. -f2)

if [[ $KERNEL_MAJOR -ge 6 ]]; then
    echo -e "${GREEN}✓${NC} Kernel $KERNEL (modern kernel for Trixie)"
elif [[ $KERNEL_MAJOR -eq 5 ]] && [[ $KERNEL_MINOR -ge 15 ]]; then
    echo -e "${GREEN}✓${NC} Kernel $KERNEL (compatible)"
else
    echo -e "${YELLOW}⚠${NC} Kernel $KERNEL (older kernel, consider upgrading)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# Check NetworkManager
echo "Checking NetworkManager..."
if command -v nmcli &> /dev/null; then
    NM_VERSION=$(nmcli --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "${GREEN}✓${NC} NetworkManager $NM_VERSION installed"

    if systemctl is-active --quiet NetworkManager; then
        echo -e "${GREEN}✓${NC} NetworkManager is running"
    else
        echo -e "${YELLOW}⚠${NC} NetworkManager installed but not running"
        echo "  Run: sudo systemctl start NetworkManager"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${YELLOW}⚠${NC} NetworkManager not installed (will be installed by script)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# Check WiFi interface
echo "Checking WiFi hardware..."
WIFI_INTERFACE=$(ip link | grep -E '^[0-9]+: wl' | cut -d: -f2 | tr -d ' ' | head -n1)
if [ -n "$WIFI_INTERFACE" ]; then
    echo -e "${GREEN}✓${NC} WiFi interface found: $WIFI_INTERFACE"

    # Check if WiFi is managed by NetworkManager
    if command -v nmcli &> /dev/null; then
        if nmcli device | grep -q "$WIFI_INTERFACE"; then
            echo -e "${GREEN}✓${NC} WiFi managed by NetworkManager"
        else
            echo -e "${YELLOW}⚠${NC} WiFi not managed by NetworkManager"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
else
    echo -e "${RED}✗${NC} No WiFi interface found"
    COMPATIBLE=false
fi

echo ""

# Check Python version
echo "Checking Python..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | grep -oE '[0-9]+\.[0-9]+')
    PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
    PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

    if [[ $PYTHON_MAJOR -eq 3 ]] && [[ $PYTHON_MINOR -ge 11 ]]; then
        echo -e "${GREEN}✓${NC} Python $PYTHON_VERSION (Trixie default)"
    elif [[ $PYTHON_MAJOR -eq 3 ]] && [[ $PYTHON_MINOR -ge 9 ]]; then
        echo -e "${GREEN}✓${NC} Python $PYTHON_VERSION (compatible)"
    else
        echo -e "${YELLOW}⚠${NC} Python $PYTHON_VERSION (older version)"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${YELLOW}⚠${NC} Python3 not installed (will be installed by script)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# Check systemd version
echo "Checking systemd..."
if command -v systemctl &> /dev/null; then
    SYSTEMD_VERSION=$(systemctl --version | head -1 | grep -oE '[0-9]+')
    if [[ $SYSTEMD_VERSION -ge 252 ]]; then
        echo -e "${GREEN}✓${NC} systemd $SYSTEMD_VERSION (Trixie version)"
    elif [[ $SYSTEMD_VERSION -ge 247 ]]; then
        echo -e "${GREEN}✓${NC} systemd $SYSTEMD_VERSION (compatible)"
    else
        echo -e "${YELLOW}⚠${NC} systemd $SYSTEMD_VERSION (older version)"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}✗${NC} systemd not found"
    COMPATIBLE=false
fi

echo ""

# Check disk space
echo "Checking disk space..."
AVAILABLE_SPACE=$(df / | awk 'NR==2 {print int($4/1024)}')
if [[ $AVAILABLE_SPACE -ge 500 ]]; then
    echo -e "${GREEN}✓${NC} ${AVAILABLE_SPACE}MB available (sufficient)"
elif [[ $AVAILABLE_SPACE -ge 200 ]]; then
    echo -e "${YELLOW}⚠${NC} ${AVAILABLE_SPACE}MB available (minimum met)"
    WARNINGS=$((WARNINGS + 1))
else
    echo -e "${RED}✗${NC} Only ${AVAILABLE_SPACE}MB available (need 200MB minimum)"
    COMPATIBLE=false
fi

echo ""

# Check for conflicting services
echo "Checking for conflicts..."
CONFLICTS_FOUND=false

if systemctl list-units --all | grep -qE "hostapd|dnsmasq|isc-dhcp-server"; then
    echo -e "${YELLOW}⚠${NC} Found potentially conflicting services:"
    systemctl list-units --all | grep -E "hostapd|dnsmasq|isc-dhcp-server" | while read -r line; do
        echo "    $line"
    done
    echo "  These may interfere with WiFi Connect"
    WARNINGS=$((WARNINGS + 1))
    CONFLICTS_FOUND=true
fi

if [ "$CONFLICTS_FOUND" = false ]; then
    echo -e "${GREEN}✓${NC} No conflicting services found"
fi

echo ""
echo "==========================================="

# Final verdict
if [ "$COMPATIBLE" = true ]; then
    if [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ FULLY COMPATIBLE${NC}"
        echo ""
        echo "Your system meets all requirements for Ossuary Pi!"
        echo "Ready to install on Pi OS 2025 (Debian Trixie)"
    else
        echo -e "${GREEN}✓ COMPATIBLE${NC} with $WARNINGS warning(s)"
        echo ""
        echo "Your system will work with Ossuary Pi."
        echo "Some warnings were found but installation should succeed."
    fi
    echo ""
    echo "To install, run: sudo ./install.sh"
else
    echo -e "${RED}✗ NOT COMPATIBLE${NC}"
    echo ""
    echo "Your system does not meet minimum requirements."
    echo "Please address the issues marked with ✗ above."
fi

echo "==========================================="

exit 0