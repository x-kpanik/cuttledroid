#!/bin/bash
# Setup AWS g5g.metal host for Cuttlefish with GPU
# Run once on fresh Ubuntu 24.04 instance
# Usage: sudo ./setup-host.sh

set -e

echo "=== Cuttlefish Host Setup (AWS g5g.metal ARM64) ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo $0"
  exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
  echo "Warning: This script is designed for ARM64 (aarch64), detected: $ARCH"
fi

echo "Step 1: System update..."
apt update && apt upgrade -y

echo ""
echo "Step 2: Add NVIDIA CUDA repository (for ARM64 drivers)..."
# Standard Ubuntu repos don't have nvidia-dkms-580 for ARM64
# Need NVIDIA's official CUDA repository
apt install -y wget gnupg
wget -qO - https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa/3bf863cc.pub \
    | gpg --dearmor -o /usr/share/keyrings/cuda-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa/ /" \
    | tee /etc/apt/sources.list.d/cuda.list
apt update

echo ""
echo "Step 3: Install NVIDIA drivers..."

# On ARM64, drivers are installed via DKMS (nvidia-dkms-*) since prebuilt .ko not available
# Version 580.x is stable for gfxstream GPU passthrough

# Install kernel headers first
apt install -y linux-headers-$(uname -r) linux-modules-extra-$(uname -r)

# Install NVIDIA drivers via DKMS
NVIDIA_VER=580
apt install -y \
    nvidia-dkms-${NVIDIA_VER} \
    nvidia-kernel-source-${NVIDIA_VER} \
    nvidia-kernel-common-${NVIDIA_VER} \
    libnvidia-compute-${NVIDIA_VER} \
    libnvidia-gl-${NVIDIA_VER} \
    libnvidia-gpucomp-${NVIDIA_VER} \
    nvidia-utils-${NVIDIA_VER}

# Lock versions to prevent auto-upgrade breaking compatibility
apt-mark hold \
    nvidia-dkms-${NVIDIA_VER} \
    nvidia-kernel-source-${NVIDIA_VER} \
    nvidia-kernel-common-${NVIDIA_VER} \
    libnvidia-compute-${NVIDIA_VER} \
    libnvidia-gl-${NVIDIA_VER} \
    libnvidia-gpucomp-${NVIDIA_VER} \
    nvidia-utils-${NVIDIA_VER}

# Enable nvidia-drm modeset (required for gfxstream)
echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf
update-initramfs -u

# Try to load module now (will work after reboot if fails)
modprobe nvidia-drm modeset=1 || true

echo ""
echo "Step 4: Install dependencies..."
apt install -y \
    curl \
    unzip \
    git \
    qemu-kvm \
    android-tools-adb \
    mesa-utils \
    bridge-utils \
    iproute2 \
    iptables \
    docker.io

echo ""
echo "Step 5: Add Cuttlefish repository..."
curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
    -o /etc/apt/trusted.gpg.d/artifact-registry.asc
chmod a+r /etc/apt/trusted.gpg.d/artifact-registry.asc
echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
    | tee /etc/apt/sources.list.d/artifact-registry.list

echo ""
echo "Step 6: Install Cuttlefish packages..."
apt update
apt install -y cuttlefish-base cuttlefish-user cuttlefish-orchestration
systemctl enable --now cuttlefish-host-resources
systemctl status cuttlefish-host-resources --no-pager || true

echo ""
echo "Step 7: Setup user permissions..."
USERNAME=${SUDO_USER:-ubuntu}
usermod -aG kvm,render,video,cvdnetwork,docker $USERNAME

echo ""
echo "Step 8: Enable Docker..."
systemctl enable docker
systemctl start docker

echo ""
echo "Step 9: Increase network interfaces for multiple emulators..."
if [ -f /etc/default/cuttlefish-host-resources ]; then
    # Replace existing num_cvd_accounts value (commented or not) or add if missing
    if grep -qE '^#?num_cvd_accounts=' /etc/default/cuttlefish-host-resources; then
        sed -i -E 's/^#?num_cvd_accounts=.*/num_cvd_accounts=14/' /etc/default/cuttlefish-host-resources
    else
        echo 'num_cvd_accounts=14' >> /etc/default/cuttlefish-host-resources
    fi
    systemctl restart cuttlefish-host-resources || true
fi

echo ""
echo "Step 10: Fetch Android image (cvd fetch)..."
# Fixed path for multi-user access (not in user's home)
CUTTLEFISH_BASE="/opt/cuttlefish-base"
mkdir -p "$CUTTLEFISH_BASE"
chown $USERNAME:$USERNAME "$CUTTLEFISH_BASE"
# Fetch by BRANCH (latest green build) instead of a pinned build id: pinned ids
# eventually get garbage-collected from Google CI and start returning 404.
# To pin a specific build, use e.g. 15660610/aosp_cf_arm64_only_phone-userdebug.
# NOTE: aosp-main no longer publishes public Cuttlefish artifacts (404) — only
# aosp-android-latest-release works. HEAD requests to ci.android.com also 404
# by design; that is not a missing build.
ANDROID_BUILD="${ANDROID_BUILD:-aosp-android-latest-release/aosp_cf_arm64_only_phone-userdebug}"
sudo -u $USERNAME bash -c "cd $CUTTLEFISH_BASE && cvd fetch --default_build=$ANDROID_BUILD"
# Make readable by all users
chmod -R 755 "$CUTTLEFISH_BASE"

echo ""
echo "Step 11: Copy scripts to /opt/cuttlefish..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p /opt/cuttlefish
cp "$SCRIPT_DIR"/*.sh /opt/cuttlefish/ 2>/dev/null || true
cp "$REPO_ROOT"/Dockerfile /opt/cuttlefish/ 2>/dev/null || true
chmod -R 755 /opt/cuttlefish
chmod +x /opt/cuttlefish/*.sh

echo ""
echo "Step 12: Build Docker image..."
if [ -f "/opt/cuttlefish/Dockerfile" ]; then
    cd /opt/cuttlefish
    docker build -t cuttlefish-ubuntu24:latest .
else
    echo "WARNING: Dockerfile not found"
    echo "Please build manually: docker build -t cuttlefish-ubuntu24:latest ."
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "REBOOT REQUIRED!"
echo "  sudo reboot"
echo ""
echo "After reboot, verify:"
echo "  1. NVIDIA:  nvidia-smi (should show 580.x driver)"
echo "  2. Modeset: cat /sys/module/nvidia_drm/parameters/modeset (should be Y)"
echo "  3. EGL:     eglinfo 2>&1 | grep -i 'vendor' (should show NVIDIA)"
echo "  4. Groups:  groups (should show kvm, render, video, cvdnetwork, docker)"
echo "  5. DRI:     ls -la /dev/dri/"
echo ""
echo "Then run emulators (any user can run):"
echo "  cd /opt/cuttlefish"
echo "  ./run-cuttlefish-gpu-arm64.sh all 14  # all 14 emulators"
echo "  ./run-cuttlefish-gpu-arm64.sh 1       # single instance"
echo ""
