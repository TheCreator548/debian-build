#!/usr/bin/env bash
# build-debian-gnome-live.sh
#
# Builds a custom Debian 13 (trixie) live ISO with a full GNOME desktop.
# Boots straight into a live GNOME session — works in VirtualBox, on
# real hardware, or from a USB stick.
#
# REQUIREMENTS
#   - A Debian or Ubuntu machine/VM with real internet access
#     (your own PC, WSL2, or a cloud VM)
#   - Run as root
#   - ~20GB free disk space
#   - 20-60+ minutes depending on your connection and CPU
#
# USAGE
#   chmod +x build-debian-gnome-live.sh
#   sudo ./build-debian-gnome-live.sh
#
# OUTPUT
#   debian-gnome-live/live-image-amd64.hybrid.iso
#   -> attach this file to a VirtualBox VM's optical drive and boot

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root: sudo $0" >&2
    exit 1
fi

BUILD_DIR="debian-gnome-live"

echo "==> Installing live-build and dependencies"
apt-get update
apt-get install -y live-build debootstrap xorriso squashfs-tools \
    isolinux syslinux-utils dosfstools mtools

echo "==> Setting up build directory: $BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> Configuring live-build (Debian trixie, amd64)"
lb config \
    --distribution trixie \
    --architecture amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap http://deb.debian.org/debian/ \
    --mirror-binary http://deb.debian.org/debian/ \
    --binary-images iso-hybrid \
    --iso-application "Debian GNOME Custom" \
    --iso-volume "DEBIAN_GNOME"

echo "==> Adding the GNOME desktop task"
mkdir -p config/package-lists
cat > config/package-lists/desktop.list.chroot << 'EOF'
task-gnome-desktop
EOF
# Add more packages above, one per line, to bake in extra tools/apps.

echo "==> Building the ISO — this is the long part, go grab a coffee"
lb build

echo
echo "==> Done. Your ISO:"
ls -la "$(pwd)"/*.iso

