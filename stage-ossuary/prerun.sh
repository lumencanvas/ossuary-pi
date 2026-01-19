#!/bin/bash -e

# Initialize this stage from the previous stage
if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi

# Import updated Debian archive keys (fixes GPG signature errors)
# This is needed because the keys in the base image may be outdated
echo "Updating Debian archive keys..."
on_chroot << 'EOF'
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 6ED0E7B82643E131 2>/dev/null || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 78DBA3BC47EF2265 2>/dev/null || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys F8D2585B8783D481 2>/dev/null || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 54404762BBB6E853 2>/dev/null || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys BDE6D2B9216EC7A8 2>/dev/null || true

# Alternative method using signed-by
mkdir -p /etc/apt/keyrings
wget -qO - https://ftp-master.debian.org/keys/release-12.asc | gpg --dearmor > /etc/apt/keyrings/debian-archive-keyring.gpg 2>/dev/null || true

apt-get update || true
EOF
