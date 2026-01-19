#!/bin/bash -e

# Copy Ossuary files into the image
# This runs on the host machine, ${ROOTFS_DIR} is the image filesystem

# Create directories
install -d "${ROOTFS_DIR}/opt/ossuary"
install -d "${ROOTFS_DIR}/etc/ossuary"

# Copy all ossuary files from the repo
# (the GitHub Action will clone the repo into files/ossuary-pi)
if [ -d "files/ossuary-pi" ]; then
    cp -rv files/ossuary-pi/* "${ROOTFS_DIR}/opt/ossuary/"
fi

# Make scripts executable
chmod +x "${ROOTFS_DIR}/opt/ossuary/install.sh" 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.sh 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.py 2>/dev/null || true
