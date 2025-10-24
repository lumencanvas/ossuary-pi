#!/bin/bash

# Ossuary Pi - Complete Uninstallation Script
# Safely removes all Ossuary components and restores system

set -e

# Configuration
INSTALL_DIR="/opt/ossuary"
CONFIG_DIR="/etc/ossuary"
LOG_FILE="/tmp/ossuary-uninstall.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Helper functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >> "$LOG_FILE"
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Header
clear
echo "==========================================="
echo "    Ossuary Pi Uninstallation"
echo "==========================================="
echo ""
echo "This will remove:"
echo "  • Balena WiFi Connect"
echo "  • Ossuary services and files"
echo "  • Custom UI and scripts"
echo ""
echo -e "${YELLOW}Your WiFi configuration will be preserved.${NC}"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi

# Confirm uninstallation
echo -n "Are you sure you want to uninstall Ossuary? (yes/no): "
read -r response

if [ "$response" != "yes" ]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Initialize log
echo "Uninstallation started at $(date)" > "$LOG_FILE"

# Ask about configuration preservation
echo ""
echo -n "Do you want to keep your configuration file? (yes/no): "
read -r keep_config

# Step 1: Stop services
log "Stopping services..."

# Stop services if they exist
if systemctl list-units --full -all | grep -q "wifi-connect.service"; then
    systemctl stop wifi-connect.service 2>/dev/null || true
    log "WiFi Connect service stopped"
fi

if systemctl list-units --full -all | grep -q "ossuary-startup.service"; then
    systemctl stop ossuary-startup.service 2>/dev/null || true
    log "Ossuary startup service stopped"
fi

if systemctl list-units --full -all | grep -q "ossuary-web.service"; then
    systemctl stop ossuary-web.service 2>/dev/null || true
    log "Ossuary web service stopped"
fi

# Kill any remaining wifi-connect processes
pkill -f wifi-connect 2>/dev/null || true

# Step 2: Disable services
log "Disabling services..."

systemctl disable wifi-connect.service 2>/dev/null || true
systemctl disable ossuary-startup.service 2>/dev/null || true
systemctl disable ossuary-web.service 2>/dev/null || true

# Step 3: Remove service files
log "Removing service files..."

rm -f /etc/systemd/system/wifi-connect.service
rm -f /etc/systemd/system/ossuary-startup.service
rm -f /etc/systemd/system/ossuary-web.service

# Reload systemd
systemctl daemon-reload

# Step 4: Remove WiFi Connect binary
log "Removing WiFi Connect..."

if [ -f /usr/local/bin/wifi-connect ]; then
    rm -f /usr/local/bin/wifi-connect
    log "WiFi Connect binary removed"
fi

# Also check common installation paths
rm -f /usr/bin/wifi-connect 2>/dev/null || true
rm -f /opt/wifi-connect/wifi-connect 2>/dev/null || true

# Step 5: Remove Ossuary files
log "Removing Ossuary files..."

# Remove installation directory
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    log "Ossuary installation directory removed"
fi

# Handle configuration
if [ "$keep_config" = "yes" ]; then
    log "Preserving configuration in $CONFIG_DIR"
    echo -e "${BLUE}Configuration preserved in: $CONFIG_DIR${NC}"
else
    if [ -d "$CONFIG_DIR" ]; then
        # Backup config just in case
        cp -r "$CONFIG_DIR" "/tmp/ossuary-config-backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        rm -rf "$CONFIG_DIR"
        log "Configuration directory removed (backup in /tmp)"
    fi
fi

# Step 6: Remove log files
log "Cleaning up log files..."

rm -f /var/log/ossuary*.log 2>/dev/null || true
rm -f /tmp/ossuary*.log 2>/dev/null || true

# Step 7: Network status check
log "Verifying network configuration..."

# NetworkManager is the standard in modern Pi OS
if systemctl is-active --quiet NetworkManager; then
    success "NetworkManager is active and managing your network"
    echo "  This is the standard for Pi OS Bookworm (2023) and newer"
else
    warning "NetworkManager is not active"
    echo "  To re-enable NetworkManager:"
    echo "    sudo systemctl enable --now NetworkManager"
fi

# Step 8: Check for leftover processes
log "Checking for leftover processes..."

# Kill any Python processes related to Ossuary
pkill -f "ossuary" 2>/dev/null || true
pkill -f "config-handler.py" 2>/dev/null || true
pkill -f "startup-manager" 2>/dev/null || true

# Step 9: Clean up any temporary files
log "Cleaning up temporary files..."

rm -f /tmp/ossuary-install* 2>/dev/null || true
rm -f /tmp/wifi-connect* 2>/dev/null || true

# Step 10: Final verification
log "Verifying uninstallation..."

ISSUES=0

# Check if services still exist
if systemctl list-units --full -all | grep -q "wifi-connect\|ossuary"; then
    warning "Some services may still be registered"
    ISSUES=$((ISSUES + 1))
fi

# Check if files still exist
if [ -d "$INSTALL_DIR" ]; then
    warning "Installation directory still exists"
    ISSUES=$((ISSUES + 1))
fi

if [ -f /usr/local/bin/wifi-connect ]; then
    warning "WiFi Connect binary still exists"
    ISSUES=$((ISSUES + 1))
fi

# Final message
echo ""
echo "==========================================="

if [ $ISSUES -eq 0 ]; then
    echo -e "${GREEN}    Uninstallation Complete!${NC}"
    echo "==========================================="
    echo ""
    echo "Ossuary Pi has been successfully removed."

    if [ "$keep_config" = "yes" ]; then
        echo ""
        echo "Your configuration was preserved in: $CONFIG_DIR"
    fi

    echo ""
    echo "Network status:"
    if systemctl is-active --quiet NetworkManager; then
        echo -e "  • NetworkManager is ${GREEN}active${NC}"
        echo "    Your network configuration is intact"
    else
        echo -e "  • ${RED}NetworkManager is not active!${NC}"
        echo ""
        echo "  To restore networking:"
        echo "    sudo systemctl enable --now NetworkManager"
    fi

    echo ""
    echo "You may want to reboot to ensure all changes take effect."
    echo ""
else
    echo -e "${YELLOW}    Uninstallation Completed with Warnings${NC}"
    echo "==========================================="
    echo ""
    echo "Some components may not have been fully removed."
    echo "Check the log for details: $LOG_FILE"
    echo ""
    echo "You can manually check for:"
    echo "  • Services: systemctl list-units --all | grep -E 'wifi-connect|ossuary'"
    echo "  • Files: ls -la /opt/ossuary /etc/ossuary"
    echo "  • Processes: ps aux | grep -E 'wifi-connect|ossuary'"
    echo ""
fi

# Save summary to log
echo "" >> "$LOG_FILE"
echo "Uninstallation completed at $(date)" >> "$LOG_FILE"
echo "Issues found: $ISSUES" >> "$LOG_FILE"

# Offer to show the log
echo -n "Would you like to view the uninstallation log? (yes/no): "
read -r show_log

if [ "$show_log" = "yes" ]; then
    less "$LOG_FILE"
fi

exit 0