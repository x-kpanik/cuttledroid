# Cuttlefish runtime image (Ubuntu 24.04, ARM64, NVIDIA GPU)
#
# Cuttlefish ARM64 host tools (cvd-host_package.tar.gz) are musl-based, while the
# NVIDIA Vulkan/EGL drivers are glibc-based. The launcher bridges this with
# symlinks in $FETCH/hostlibs/ and a minimal LD_LIBRARY_PATH
# (see scripts/run-cuttlefish-gpu.sh).
#
# Layout:
#   - CF_BASE (mounted read-only) - pre-fetched Android images + cvd binaries (musl)
#   - CF_RUN  (volume)            - runtime data + hostlibs symlinks
#   - Host NVIDIA libs (read-only) - glibc libraries for the GPU
#
# Build:
#   docker build -t cuttlefish-ubuntu24:latest .
#
# Prerequisites on host:
#   mkdir -p ~/cuttlefish-base && cd ~/cuttlefish-base
#   cvd fetch --default_build=14654133/aosp_cf_arm64_only_phone-userdebug
#
# Run:
#   ./scripts/run-cuttlefish-gpu.sh 1   # instance 1: adb 6520, webrtc 8443
#   ./scripts/run-cuttlefish-gpu.sh 2   # instance 2: adb 6521, webrtc 8444

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Add Cuttlefish repository (for capability_query.py and other helpers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg \
    && curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
       -o /etc/apt/trusted.gpg.d/artifact-registry.asc \
    && echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
       > /etc/apt/sources.list.d/artifact-registry.list \
    && rm -rf /var/lib/apt/lists/*

# Create groups required by cuttlefish packages (GIDs must match host!)
# 993 = kvm, 303 = render, 115 = cvdnetwork, 992 = renderD* devices
RUN groupadd -g 993 kvm || true \
    && groupadd -g 303 render || true \
    && groupadd -g 115 cvdnetwork || true

# Install runtime dependencies
# NOTE: We do NOT install cuttlefish-orchestration - it's not needed
#       and the musl binaries come from mounted CF_BASE
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Cuttlefish helpers (capability_query.py, etc.)
    cuttlefish-base \
    cuttlefish-user \
    # Core
    sudo \
    # GCC for TCP_NODELAY patch compilation
    gcc \
    libc6-dev \
    # ADB
    android-tools-adb \
    # Virtualization
    qemu-kvm \
    qemu-system-arm \
    # Networking
    iproute2 \
    iptables \
    net-tools \
    bridge-utils \
    # Graphics / EGL / Vulkan (glibc - for symlinks to work)
    libegl1 \
    libgl1 \
    libgbm1 \
    libdrm2 \
    libvulkan1 \
    vulkan-tools \
    mesa-utils \
    # C++ runtime
    libstdc++6 \
    # Diagnostics
    procps \
    # Python3 (required for capability_query.py!)
    python3 \
    # =========================================================================
    # APPIUM SUPPORT (added for low-latency adb from inside container)
    # Without this: adb from host to container = ~52ms
    # With Appium inside container: adb = ~2-3ms
    # =========================================================================
    # Java runtime (required for Appium UIAutomator2 driver)
    openjdk-17-jre-headless \
    # =========================================================================
    && rm -rf /var/lib/apt/lists/*

# =========================================================================
# NODE.JS 20 (required for Appium - Ubuntu 24.04 ships Node.js 18 which is too old)
# =========================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# =========================================================================
# APPIUM INSTALLATION
# Appium server + UIAutomator2 driver for Android automation
# Ports: 4723 (emu-1), 4724 (emu-2), ... 4736 (emu-14)
# NOTE: Driver installs to $APPIUM_HOME (~/.appium), so we install as ubuntu user
# =========================================================================
RUN npm install -g appium@latest

# Install UIAutomator2 driver as ubuntu user (not root!)
USER ubuntu
RUN appium driver install uiautomator2
USER root

# =========================================================================
# TCP_NODELAY PATCH for low-latency ADB (~12ms instead of ~50ms)
# This intercepts socket connect/accept calls and enables TCP_NODELAY
# to disable Nagle's algorithm on all TCP connections
# =========================================================================
RUN cat > /tmp/tcp_nodelay.c << 'TCPEOF' \
    && gcc -shared -fPIC -o /usr/lib/tcp_nodelay.so /tmp/tcp_nodelay.c -ldl \
    && rm /tmp/tcp_nodelay.c \
    && echo "TCP_NODELAY library compiled"
#define _GNU_SOURCE
#include <stddef.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <dlfcn.h>

static void set_nodelay(int fd) {
    int one = 1;
    struct sockaddr_storage addr;
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr*)&addr, &len) == 0) {
        if (addr.ss_family == AF_INET || addr.ss_family == AF_INET6) {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        }
    }
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    static int (*real_connect)(int, const struct sockaddr*, socklen_t) = NULL;
    if (!real_connect) real_connect = dlsym(RTLD_NEXT, "connect");
    int ret = real_connect(fd, addr, len);
    if (ret == 0 && (addr->sa_family == AF_INET || addr->sa_family == AF_INET6)) {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    }
    return ret;
}

int accept(int fd, struct sockaddr *addr, socklen_t *len) {
    static int (*real_accept)(int, struct sockaddr*, socklen_t*) = NULL;
    if (!real_accept) real_accept = dlsym(RTLD_NEXT, "accept");
    int ret = real_accept(fd, addr, len);
    if (ret >= 0) set_nodelay(ret);
    return ret;
}

int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags) {
    static int (*real_accept4)(int, struct sockaddr*, socklen_t*, int) = NULL;
    if (!real_accept4) real_accept4 = dlsym(RTLD_NEXT, "accept4");
    int ret = real_accept4(fd, addr, len, flags);
    if (ret >= 0) set_nodelay(ret);
    return ret;
}
TCPEOF

# NOTE: Wrapper script is created by run-cuttlefish-gpu.sh at runtime
# because socket_vsock_proxy binary is in /opt/cf/run/fetch/bin/ (mounted from host)

# Create ubuntu user with sudo
RUN id ubuntu &>/dev/null || useradd -m -s /bin/bash ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && usermod -aG kvm,render,cvdnetwork ubuntu || true

# Environment
ENV CF_BASE=/opt/cf/base
ENV CF_RUN=/opt/cf/run

# NOTE: GPU environment variables are set via docker run -e:
#   __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/01_nvidia.json
#   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
# They vary per host (01_nvidia.json vs 10_nvidia.json, etc.)

# Ports:
#   ADB:    6520-6533 (emu-1 to emu-14)
#   WebRTC: 8443-8456 (emu-1 to emu-14)
#   Appium: 4723-4736 (emu-1 to emu-14) <- APPIUM SUPPORT
EXPOSE 6520-6533 8443-8456 4723-4736 1443

USER ubuntu
WORKDIR /opt/cf/run

# No default entrypoint - run-cuttlefish-gpu.sh provides inline script
CMD ["bash"]
