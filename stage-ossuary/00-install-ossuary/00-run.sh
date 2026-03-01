#!/bin/bash -e

# pi-gen stage script for installing Ossuary
# Host operations: copy repo files into the rootfs
# Chroot operations: run install.sh in non-interactive image build mode
#
# install.sh is the SINGLE SOURCE OF TRUTH for service definitions,
# config defaults, and system setup. This script does NOT duplicate
# any service files — it delegates everything to install.sh.

echo "=== Ossuary Pi Installation ==="
echo "ROOTFS_DIR: ${ROOTFS_DIR}"
echo "PWD: $(pwd)"

# Verify ROOTFS_DIR exists
if [ ! -d "${ROOTFS_DIR}" ]; then
    echo "ERROR: ROOTFS_DIR does not exist: ${ROOTFS_DIR}"
    ls -la "$(dirname "${ROOTFS_DIR}")" || true
    exit 1
fi

# === HOST OPERATIONS ===
# Copy repo files into the image rootfs
install -d "${ROOTFS_DIR}/opt/ossuary"
install -d "${ROOTFS_DIR}/etc/ossuary"

if [ -d "files/ossuary-pi" ]; then
    echo "Copying ossuary-pi files to rootfs..."
    cp -rv files/ossuary-pi/* "${ROOTFS_DIR}/opt/ossuary/"
else
    echo "ERROR: files/ossuary-pi not found"
    ls -la files/ || echo "files/ directory not found"
    exit 1
fi

# Make scripts executable on the host side
chmod +x "${ROOTFS_DIR}/opt/ossuary/install.sh" 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.sh 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.py 2>/dev/null || true

# === CHROOT VERIFICATION ===
echo "Verifying rootfs structure before chroot..."
for dir in proc dev sys run tmp; do
    if [ ! -d "${ROOTFS_DIR}/${dir}" ]; then
        echo "Creating missing ${ROOTFS_DIR}/${dir}..."
        mkdir -p "${ROOTFS_DIR}/${dir}"
    fi
done

echo "=== Starting chroot operations ==="

# === CHROOT OPERATIONS ===
# Run install.sh in image build mode (skips apt-get, prompts, service restarts)
# Then apply image-specific system tweaks
on_chroot << 'CHROOT_EOF'
set -e

echo "Running install.sh in image build mode..."
export OSSUARY_IMAGE_BUILD=1
bash /opt/ossuary/install.sh

# === Image-specific system tweaks ===
# (Not needed for interactive installs, only for pre-built images)

# Disable standalone wpa_supplicant (NetworkManager manages WiFi)
systemctl disable wpa_supplicant.service 2>/dev/null || true
systemctl mask wpa_supplicant.service 2>/dev/null || true

# Enable NetworkManager (install.sh enables it but can't start it in chroot)
systemctl enable NetworkManager.service 2>/dev/null || true

# Disable screen blanking for kiosk use
if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_blanking 1 || true
fi

# NOTE: We intentionally do NOT create .skip-userconf files here.
# This allows Pi Imager customizations (WiFi, hostname, SSH keys) to work.
# The firstrun.sh script from Pi Imager needs to execute to apply those settings.

echo "Ossuary Pi image installation complete!"
CHROOT_EOF

echo "=== Ossuary Pi Installation Complete ==="
