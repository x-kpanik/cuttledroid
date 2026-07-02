#!/bin/bash
# Run Cuttlefish emulator with NVIDIA GPU in Docker
#
# Architecture:
#   CF_BASE (host ~/cuttlefish-base) → mounted read-only
#   CF_RUN  (named volume)           → runtime data
#
# Key findings (ARM64 + NVIDIA + Docker):
#   - Cuttlefish ARM64 host tools are musl-based
#   - NVIDIA Vulkan/EGL drivers are glibc-based
#   - Solution: symlinks in $FETCH/hostlibs/ + minimal LD_LIBRARY_PATH
#   - VK_ICD_FILENAMES for Vulkan ICD visibility
#
# Prerequisites:
#   1. Fetch ONCE on host (branch form = latest green build; pinned ids rot):
#      mkdir -p ~/cuttlefish-base && cd ~/cuttlefish-base
#      cvd fetch --default_build=aosp-android-latest-release/aosp_cf_arm64_only_phone-userdebug
#
#   2. Build image ONCE:
#      docker build -t cuttlefish-ubuntu24:latest .
#
# Usage:
#   ./run-cuttlefish-gpu-arm64.sh [instance_num]    # single emulator
#   ./run-cuttlefish-gpu-arm64.sh all [count]       # multiple emulators with 6s delay
#
# Examples:
#   ./run-cuttlefish-gpu-arm64.sh 1     # single: adb:6520, webrtc:8443
#   ./run-cuttlefish-gpu-arm64.sh 5     # single: adb:6524, webrtc:8447
#   ./run-cuttlefish-gpu-arm64.sh all   # launch 14 emulators (default)
#   ./run-cuttlefish-gpu-arm64.sh all 8 # launch 8 emulators
#
# Environment variables:
#   CUTTLEFISH_BASE - Path to pre-fetched base (default: /opt/cuttlefish-base)
#   X_RES, Y_RES    - Screen resolution (default: 2340x1080, landscape)
#   CPUS            - vCPUs per emulator (default: 6)
#   MEMORY_MB       - RAM in MB (default: 10240)
#   GPU_MODE        - gfxstream/guest_swiftshader/auto (default: gfxstream)

set -e

# =============================================================================
# Multi-instance mode: ./run-cuttlefish-gpu-arm64.sh all [count]
# =============================================================================
if [ "$1" = "all" ]; then
  COUNT=${2:-8}
  DELAY=${LAUNCH_DELAY:-6}  # 6 seconds between launches to avoid GPU race conditions
  
  echo "=== Launching $COUNT emulators (${DELAY}s delay between each) ==="
  echo ""
  
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  
  # Phase 1: Start all containers quickly (skip boot wait)
  for i in $(seq 1 $COUNT); do
    echo "--- Starting container #$i of $COUNT ---"
    SKIP_BOOT_WAIT=1 "$SCRIPT_DIR/run-cuttlefish-gpu-arm64.sh" "$i"
    
    if [ $i -lt $COUNT ]; then
      sleep $DELAY
    fi
  done
  
  echo ""
  echo "=== Phase 2: Waiting for ADB & boot ==="
  
  # Wait and connect with retries
  BOOT_TIMEOUT=90
  START_TIME=$(date +%s)
  while true; do
    BOOTED=0
    for i in $(seq 1 $COUNT); do
      PORT=$((6519 + i))
      # Try to connect (silently)
      adb connect localhost:$PORT >/dev/null 2>&1 || true
      # Check boot status
      STATUS=$(adb -s localhost:$PORT shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || echo "")
      [ "$STATUS" = "1" ] && BOOTED=$((BOOTED + 1))
    done
    
    ELAPSED=$(($(date +%s) - START_TIME))
    echo "Booted: $BOOTED/$COUNT (${ELAPSED}s)"
    
    [ $BOOTED -eq $COUNT ] && break
    [ $ELAPSED -ge $BOOT_TIMEOUT ] && echo "Timeout, continuing anyway" && break
    sleep 5
  done
  
  echo ""
  echo "=== Phase 3: Configure devices & check WebRTC ==="
  
  # Configure all devices and check WebRTC
  WEBRTC_OK=0
  ADB_OK=0
  for i in $(seq 1 $COUNT); do
    PORT=$((6519 + i))
    WEBRTC_PORT=$((8442 + i))
    SERIAL="localhost:$PORT"
    
    # Ensure connected
    adb connect $SERIAL >/dev/null 2>&1 || true
    
    # Check if device responds
    if adb -s $SERIAL shell echo ok >/dev/null 2>&1; then
      ADB_OK=$((ADB_OK + 1))
      
      # Configure device
      adb -s $SERIAL shell settings put secure lockscreen.disabled 1 2>/dev/null || true
      adb -s $SERIAL shell settings put secure immersive_mode_confirmations confirmed 2>/dev/null || true
      adb -s $SERIAL shell settings put global policy_control "immersive.full=*" 2>/dev/null || true
      adb -s $SERIAL shell settings put global window_animation_scale 0 2>/dev/null || true
      adb -s $SERIAL shell settings put global transition_animation_scale 0 2>/dev/null || true
      adb -s $SERIAL shell settings put global animator_duration_scale 0 2>/dev/null || true
      adb -s $SERIAL shell settings put system screen_off_timeout 600000 2>/dev/null || true
      adb -s $SERIAL shell settings put secure show_ime_with_hard_keyboard 1 2>/dev/null || true
      # Hide ANR/crash dialogs — Android will auto-kill unresponsive apps
      adb -s $SERIAL shell settings put global hide_error_dialogs 1 2>/dev/null || true
      adb -s $SERIAL shell settings put secure anr_show_background 0 2>/dev/null || true
      # Wake up screen (lockscreen disabled, no swipe needed)
      adb -s $SERIAL shell input keyevent KEYCODE_WAKEUP 2>/dev/null || true
      adb -s $SERIAL shell wm dismiss-keyguard 2>/dev/null || true
      adb -s $SERIAL shell input keyevent 82 2>/dev/null || true
      adb -s $SERIAL shell input keyevent KEYCODE_HOME 2>/dev/null || true
      adb -s $SERIAL shell cmd dream stop 2>/dev/null || true
    fi
    
    # Check WebRTC
    DEVICES=$(curl -sk https://localhost:$WEBRTC_PORT/devices 2>/dev/null || echo "[]")
    if echo "$DEVICES" | grep -q "cvd-$i"; then
      echo "emu-$i: ADB=$PORT WebRTC=$WEBRTC_PORT OK"
      echo "   WebRTC: https://localhost:${WEBRTC_PORT}/client.html?deviceId=cvd-${i}"
      WEBRTC_OK=$((WEBRTC_OK + 1))
    else
      echo "emu-$i: ADB=$PORT WebRTC=$WEBRTC_PORT MISSING"
    fi
  done
  
  echo ""
  echo "=== Done: $COUNT containers, $ADB_OK ADB OK, $WEBRTC_OK WebRTC OK ==="
  echo "Note: Appium servers should be started on separate host"
  exit 0
fi

INSTANCE_NUM=${1:-1}
CONTAINER_NAME="cuttlefish-emu-${INSTANCE_NUM}"
ADB_PORT=$((6519 + INSTANCE_NUM))
WEBRTC_PORT=$((8442 + INSTANCE_NUM))
IMAGE_NAME=${IMAGE_NAME:-cuttlefish-ubuntu24:latest}

# Paths
# Fixed path for multi-user access (was $HOME/cuttlefish-base)
CUTTLEFISH_BASE="${CUTTLEFISH_BASE:-/opt/cuttlefish-base}"

# =============================================================================
# Work directory strategy
# =============================================================================
# Option 1 (named volume): Docker manages the volume; cleaner, but on some hosts
#   the volume mount returned persistent "Permission denied" errors on mkdir/ln.
# Option 2 (bind mount): a host directory is mounted directly into the container;
#   more reliable when Docker volume permissions misbehave. This is the default.
# =============================================================================
# Fixed path for multi-user access
WORK_DIR="${WORK_DIR:-/opt/cf-work-${INSTANCE_NUM}}"
USE_BIND_MOUNT=true  # set to false to use a named volume instead

# Defaults (landscape: width > height for horizontal display)
X_RES=${X_RES:-2340}
Y_RES=${Y_RES:-1080}
CPUS=${CPUS:-6}
MEMORY_MB=${MEMORY_MB:-10240}
DPI=${DPI:-400}
# gfxstream is required to enable vhost-user GPU on this build (custom ignored → auto).
GPU_MODE=${GPU_MODE:-gfxstream_guest_angle}
# vhost-user GPU mode: on/off/auto
GPU_VHOST_USER_MODE=${GPU_VHOST_USER_MODE:-on}
# Old modes (do not remove):
# GPU_MODE=${GPU_MODE:-gfxstream}  # has black screen issues on ARM64+NVIDIA
# GPU_MODE=${GPU_MODE:-custom}

# GPU distribution: round-robin across 2 GPUs for balanced load
# Odd instances (1,3,5,7,9,11,13) → GPU 0
# Even instances (2,4,6,8,10,12,14) → GPU 1
if [ $((INSTANCE_NUM % 2)) -eq 1 ]; then
  GPU_ID=0
  RENDER_NODE=128
else
  GPU_ID=1
  RENDER_NODE=129
fi
echo "Instance $INSTANCE_NUM → GPU $GPU_ID (renderD${RENDER_NODE}) [round-robin]"

# CPU pinning: each container gets dedicated cores (no overlap)
# 7 cores per container (6 vCPU guest + 1 container overhead), starting from core 0
# Instance 1 → 0-6, Instance 2 → 7-13, ..., Instance 8 → 49-55
# Cores 56-63 remain free for host overhead (ADB, Docker daemon, networking)
CPU_CORES_PER_CONTAINER=${CPU_CORES_PER_CONTAINER:-7}
CPU_START=$(( (INSTANCE_NUM - 1) * CPU_CORES_PER_CONTAINER ))
CPU_END=$(( CPU_START + CPU_CORES_PER_CONTAINER - 1 ))
CPU_SET="${CPU_START}-${CPU_END}"
echo "Instance $INSTANCE_NUM → CPUs ${CPU_SET} (pinned)"

# Auto-detect NVIDIA EGL vendor file
EGL_VENDOR_FILE="$(ls /usr/share/glvnd/egl_vendor.d/*nvidia*.json 2>/dev/null | head -1 || true)"
EGL_VENDOR_FILE="${EGL_VENDOR_FILE:-/usr/share/glvnd/egl_vendor.d/10_nvidia.json}"

# Auto-detect NVIDIA Vulkan ICD
VK_ICD_FILE="$(ls /usr/share/vulkan/icd.d/nvidia*.json 2>/dev/null | head -1 || true)"
VK_ICD_FILE="${VK_ICD_FILE:-/usr/share/vulkan/icd.d/nvidia_icd.json}"

echo "=== Cuttlefish + NVIDIA GPU (Docker, ARM64) ==="
echo ""
echo "Instance:      #$INSTANCE_NUM"
echo "Container:     $CONTAINER_NAME"
echo "Image:         $IMAGE_NAME"
echo "Base (RO):     $CUTTLEFISH_BASE → /opt/cf/base"
if [ "$USE_BIND_MOUNT" = true ]; then
  echo "Work Dir:      $WORK_DIR → /opt/cf/run (bind mount)"
else
  echo "Work Vol:      cf-run-${CONTAINER_NAME} → /opt/cf/run (named volume)"
fi
echo "ADB Port:      $ADB_PORT"
echo "WebRTC:        $WEBRTC_PORT"
echo "Appium:        $APPIUM_PORT"
echo "Resolution:    ${X_RES}x${Y_RES} @ ${DPI}dpi"
echo "Resources:     ${CPUS} vCPUs, ${MEMORY_MB}MB RAM, pinned to CPUs ${CPU_SET}"
echo "GPU Mode:      $GPU_MODE"
echo "EGL Vendor:    $EGL_VENDOR_FILE"
echo "Vulkan ICD:    $VK_ICD_FILE"
echo ""

# Check base directory exists
if [ ! -d "$CUTTLEFISH_BASE" ]; then
    echo "ERROR: Cuttlefish base not found at $CUTTLEFISH_BASE"
    echo ""
    echo "Fetch ONCE with:"
    echo "  mkdir -p ~/cuttlefish-base && cd ~/cuttlefish-base"
    echo "  cvd fetch --default_build=aosp-android-latest-release/aosp_cf_arm64_only_phone-userdebug"
    exit 1
fi

if [ ! -f "$CUTTLEFISH_BASE/bin/launch_cvd" ]; then
    echo "ERROR: launch_cvd not found in $CUTTLEFISH_BASE/bin/"
    exit 1
fi

# Check image exists
if ! docker image inspect $IMAGE_NAME &>/dev/null; then
    echo "ERROR: Image '$IMAGE_NAME' not found!"
    echo "Build it first: docker build -t cuttlefish-ubuntu24:latest ."
    exit 1
fi

# Remove existing container if running (but NOT other instances!)
echo "Cleaning up container $CONTAINER_NAME..."
docker rm -f $CONTAINER_NAME 2>/dev/null || true

# NOTE: Don't clean /tmp/cf_avd_* /tmp/cf_env_* /tmp/vsock_* globally!
# Each instance uses unique paths based on base_instance_num

# =============================================================================
# Dynamic GID detection
# =============================================================================
# Host group GIDs (kvm, cvdnetwork, render) differ between hosts, so detect them
# at runtime. The container must join the HOST's cvdnetwork group to access the
# TAP devices created by the cuttlefish-host-resources service; a hardcoded GID
# fails with "Operation not permitted" when the host GID differs.
# =============================================================================
HOST_CVDNETWORK_GID=$(getent group cvdnetwork | cut -d: -f3 2>/dev/null || echo "115")
HOST_KVM_GID=$(getent group kvm | cut -d: -f3 2>/dev/null || echo "993")
HOST_RENDER_GID=$(getent group render | cut -d: -f3 2>/dev/null || echo "992")

if [ "$USE_BIND_MOUNT" = true ]; then
  # ==========================================================================
  # BIND MOUNT (default)
  # ==========================================================================
  # Required on hosts where Docker named volumes hit permission issues: even
  # after recreating the volume, chowning the mountpoint, and reinstalling
  # docker-ce, named volumes can still return "Permission denied" on mkdir/ln.
  # A bind mount bypasses Docker's volume layer entirely.
  # sudo is used because /opt paths are shared across users.
  # ==========================================================================
  sudo rm -rf "$WORK_DIR" 2>/dev/null || true
  sudo mkdir -p "$WORK_DIR"
  sudo chown -R 1000:1000 "$WORK_DIR"
  WORK_MOUNT="$WORK_DIR"
else
  # ==========================================================================
  # NAMED VOLUME (alternative)
  # ==========================================================================
  # Standard, cleaner approach where Docker manages the volume. Works on hosts
  # without the permission issue above. To use it, set USE_BIND_MOUNT=false.
  # ==========================================================================
  WORK_VOLUME="cf-run-${CONTAINER_NAME}"
  docker volume rm $WORK_VOLUME 2>/dev/null || true
  docker volume create $WORK_VOLUME 2>/dev/null || true
  # Fix volume permissions (volume created as root, but container runs as ubuntu uid=1000)
  VOLUME_PATH=$(docker volume inspect $WORK_VOLUME --format '{{.Mountpoint}}' 2>/dev/null)
  if [ -n "$VOLUME_PATH" ]; then
    sudo chown -R 1000:1000 "$VOLUME_PATH" 2>/dev/null || true
  fi
  WORK_MOUNT="$WORK_VOLUME"
fi

# =============================================================================
# RETRY LOGIC: Restart container if crosvm fails to start (e.g., Bluetooth race condition)
# =============================================================================
MAX_RETRIES=${MAX_RETRIES:-3}
CROSVM_WAIT_TIMEOUT=${CROSVM_WAIT_TIMEOUT:-45}  # seconds to wait for crosvm to start

start_container() {
echo "Starting container..."
echo ""

# =============================================================================
# Using the host GIDs detected above. Hardcoded values do not work across
# hosts (e.g. cvdnetwork may be 114 or 115), which is why they are detected.
# =============================================================================

docker run -d \
  --name "$CONTAINER_NAME" \
  --network=host \
  --cpus=${DOCKER_CPUS:-7} \
  --cpuset-cpus="${CPU_SET}" \
  --memory=${DOCKER_MEM:-12g} \
  --entrypoint bash \
  --group-add "$HOST_KVM_GID" \
  --group-add "$HOST_CVDNETWORK_GID" \
  --group-add "$HOST_RENDER_GID" \
  --cap-add=SYS_ADMIN \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_RAWIO \
  --cap-add=MKNOD \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --shm-size=2g \
  --ulimit nofile=1048576:1048576 \
  --ulimit nproc=65535:65535 \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --tmpfs /tmp:rw,size=4g,mode=1777 \
  --device /dev/kvm \
  --device /dev/vhost-vsock \
  --device /dev/net/tun \
  --device /dev/nvidiactl \
  --device /dev/nvidia-modeset \
  --device /dev/nvidia-uvm \
  --device /dev/nvidia-uvm-tools \
  --device "/dev/nvidia${GPU_ID}" \
  --device "/dev/dri/card${GPU_ID}" \
  --device "/dev/dri/renderD${RENDER_NODE}" \
  -e __EGL_VENDOR_LIBRARY_FILENAMES="$EGL_VENDOR_FILE" \
  -e VK_ICD_FILENAMES="$VK_ICD_FILE" \
  -e CUTTLEFISH_INSTANCE="$INSTANCE_NUM" \
  -e INSTANCE_NUM="$INSTANCE_NUM" \
  -e ADB_PORT="$ADB_PORT" \
  -e WEBRTC_PORT="$WEBRTC_PORT" \
  -e X_RES="$X_RES" \
  -e Y_RES="$Y_RES" \
  -e DPI="$DPI" \
  -e CPUS="$CPUS" \
  -e MEMORY_MB="$MEMORY_MB" \
  -e GPU_MODE="$GPU_MODE" \
  -e GPU_ID="$GPU_ID" \
  -e NVIDIA_VISIBLE_DEVICES="$GPU_ID" \
  -e RENDER_NODE="$RENDER_NODE" \
  -v "$CUTTLEFISH_BASE":/opt/cf/base:ro \
  -v "$WORK_MOUNT":/opt/cf/run \
  -v /usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:ro \
  -v /usr/share/glvnd:/usr/share/glvnd:ro \
  -v /usr/share/egl:/usr/share/egl:ro \
  -v /usr/share/vulkan:/usr/share/vulkan:ro \
  -v /etc/vulkan:/etc/vulkan:ro \
  "$IMAGE_NAME" \
  -lc '
    set -euo pipefail
    
    FETCH=/opt/cf/run/fetch
    mkdir -p $FETCH && cd $FETCH

    # Link images and metadata from base
    # NOTE: vbmeta*.img must be COPIED (not linked) because cuttlefish needs to resize them
    for f in /opt/cf/base/*.img /opt/cf/base/android-info.txt /opt/cf/base/fetcher_config.json; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      if [[ "$fname" == vbmeta*.img ]]; then
        cp "$f" . 2>/dev/null || true
      else
        ln -sf "$f" . || true
      fi
    done
    
    # Link directories
    for d in etc usr chromeos lib64; do
      [ -d /opt/cf/base/$d ] && ln -sf /opt/cf/base/$d . || true
    done

    # RW copy of bin (required for runtime)
    rm -rf bin && cp -a /opt/cf/base/bin ./bin

    # Clean runtime
    rm -rf cuttlefish/instances/* cuttlefish/assembly .cuttlefish_config.json 2>/dev/null || true
    mkdir -p cuttlefish/instances cuttlefish/assembly

    # === hostlibs: symlinks for musl->glibc GPU libs ===
    # With gfxstream_guest_angle + skiavk, only Vulkan is needed (no EGL/GLES/GLX)
    mkdir -p "$FETCH/hostlibs"
    # EGL/GLES (not needed with ANGLE+Vulkan):
    # ln -sf /usr/lib/aarch64-linux-gnu/libGLESv2.so.2.1.0 "$FETCH/hostlibs/libGLESv2.so"
    # ln -sf /usr/lib/aarch64-linux-gnu/libEGL.so.1 "$FETCH/hostlibs/libEGL.so"
    # GLX (not needed - headless, no X11):
    # ln -sf /usr/lib/aarch64-linux-gnu/libGLX_nvidia.so.0 "$FETCH/hostlibs/libGLX_nvidia.so.0"
    # Vulkan only:
    ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1 "$FETCH/hostlibs/libvulkan.so.1"
    ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1 "$FETCH/hostlibs/libvulkan.so"
    
    # ONLY hostlibs in LD_LIBRARY_PATH (no system paths - breaks musl!)
    export LD_LIBRARY_PATH="$FETCH/hostlibs"
    export VK_LOADER_DEBUG=error

    # HOME must be $FETCH because CF looks for $HOME/etc/cvd_config
    export HOME=$FETCH
    export PATH=$FETCH/bin:$PATH

    # === TCP_NODELAY patch (must happen BEFORE launch_cvd spawns proxy) ===
    PROXY="$FETCH/bin/socket_vsock_proxy"
    if [ -e "$PROXY" ]; then
      TARGET="$(readlink -f "$PROXY" || true)"
      # Always replace socket_vsock_proxy with wrapper
      rm -f "$PROXY"
      cat > "$PROXY" <<"WRAPEOF"
#!/bin/sh
set -eu
TARGET="/usr/lib/cuttlefish-common/bin/socket_vsock_proxy"
PRELOAD="/usr/lib/tcp_nodelay.so"
export LD_PRELOAD="${PRELOAD}${LD_PRELOAD:+:$LD_PRELOAD}"
exec "$TARGET" "$@"
WRAPEOF
      chmod +x "$PROXY"
    fi
    
    # Diagnostics
    echo "=== LAUNCH PARAMS ==="
    echo "INSTANCE_NUM=${INSTANCE_NUM:-1}"
    echo "WEBRTC_PORT=${WEBRTC_PORT:-8443}"
    echo "HOME=$HOME"
    echo "===================="
    
    # gfxstream (GLES-only) has black screen issues on ARM64+NVIDIA
    # Use gfxstream_guest_angle with Vulkan backend instead
    # CUTTLEFISH_INSTANCE env var sets instance id (more compatible than flags)
    exec ./bin/launch_cvd \
      --gpu_mode=${GPU_MODE:-gfxstream_guest_angle} \
      --gpu_context_types=${GPU_CONTEXT_TYPES:-gfxstream-gles:gfxstream-vulkan} \
      --gpu_vhost_user_mode=${GPU_VHOST_USER_MODE:-on} \
      --guest_hwui_renderer=skiavk \
      --vhost_user_vsock=true \
      --enable_wifi=false \
      --enable_host_bluetooth=false \
      --start_webrtc=true \
      --x_res=${X_RES:-2340} \
      --y_res=${Y_RES:-1080} \
      --dpi=${DPI:-400} \
      --cpus=${CPUS:-6} \
      --memory_mb=${MEMORY_MB:-10240} \
      --refresh_rate_hz=${REFRESH_RATE_HZ:-30} \
      --extra_kernel_cmdline="kvm-arm.mode=nvhe" \
      --report_anonymous_usage_stats=n
  '

echo ""
echo "Waiting for emulator to initialize..."

# Wait for crosvm to start inside container
CROSVM_STARTED=false
WAIT_TIME=0
while [ $WAIT_TIME -lt $CROSVM_WAIT_TIMEOUT ]; do
  # Check if container is still running
  CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
  if [ "$CONTAINER_STATUS" != "running" ]; then
    echo "Container exited unexpectedly (status: $CONTAINER_STATUS)"
    # Check for boot failure in logs
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "VIRTUAL_DEVICE_BOOT_FAILED"; then
      echo "   Detected: VIRTUAL_DEVICE_BOOT_FAILED (likely Bluetooth race condition)"
    fi
    return 1
  fi
  
  # Check for crosvm run process inside container
  CROSVM_PID=$(docker exec "$CONTAINER_NAME" pgrep -f 'crosvm.*run' 2>/dev/null | head -1 || true)
  if [ -n "$CROSVM_PID" ]; then
    CROSVM_STARTED=true
    echo "crosvm started (PID: $CROSVM_PID)"
    break
  fi
  
  sleep 3
  WAIT_TIME=$((WAIT_TIME + 3))
  echo "   Waiting for crosvm... ${WAIT_TIME}s / ${CROSVM_WAIT_TIMEOUT}s"
done

if [ "$CROSVM_STARTED" = false ]; then
  echo "crosvm failed to start within ${CROSVM_WAIT_TIMEOUT}s"
  return 1
fi

# Verify vhost-user GPU is enabled
echo "Verifying GPU configuration..."
GPU_CHECK=$(docker exec "$CONTAINER_NAME" pgrep -af 'crosvm.*device gpu' 2>/dev/null | head -1 || true)
if [ -n "$GPU_CHECK" ]; then
  echo "vhost-user gpu enabled"
else
  echo "vhost-user gpu process not found (may still be initializing)"
fi

return 0
}  # end of start_container function

# =============================================================================
# RETRY LOOP: Try to start container up to MAX_RETRIES times
# =============================================================================
RETRY_COUNT=0
CONTAINER_OK=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  
  if [ $RETRY_COUNT -gt 1 ]; then
    echo ""
    echo "=== RETRY $RETRY_COUNT / $MAX_RETRIES ==="
    echo ""
    # Clean up failed container before retry
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    sleep 2
  fi
  
  if start_container; then
    CONTAINER_OK=true
    break
  else
    echo "Attempt $RETRY_COUNT failed"
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "   Retrying in 5 seconds..."
      sleep 5
    fi
  fi
done

if [ "$CONTAINER_OK" = false ]; then
  echo ""
  echo "Failed to start container after $MAX_RETRIES attempts"
  echo "   Check logs: docker logs $CONTAINER_NAME"
  exit 1
fi

echo ""
echo "=== Container Started ==="
echo ""
echo "Access:"
echo "   ADB:     adb connect localhost:$ADB_PORT"
echo "   WebRTC:  https://localhost:$WEBRTC_PORT"
echo "   WebRTC:  https://localhost:${WEBRTC_PORT}/client.html?deviceId=cvd-${INSTANCE_NUM}"
echo ""
echo "Management:"
echo "   Logs:    docker logs -f $CONTAINER_NAME"
echo "   Shell:   docker exec -it $CONTAINER_NAME bash"
echo "   Stop:    docker stop $CONTAINER_NAME"
echo ""

# === POST-BOOT ADB CONFIGURATION ===
# Skip boot wait if SKIP_BOOT_WAIT=1 (used by "all" mode for faster parallel launch)
if [ "${SKIP_BOOT_WAIT:-0}" = "1" ]; then
  echo "Container started (boot wait skipped)"
  exit 0
fi

echo "Waiting for device to boot completely..."
DEVICE_SERIAL="localhost:$ADB_PORT"

# Wait for ADB to become available and connect
echo "   Connecting to ADB..."
CONNECT_TIMEOUT=60
CONNECT_WAIT=0
while [ $CONNECT_WAIT -lt $CONNECT_TIMEOUT ]; do
  adb connect "$DEVICE_SERIAL" 2>/dev/null
  CONNECT_STATUS=$(adb devices 2>/dev/null | grep "$DEVICE_SERIAL" | grep -v offline | grep device || echo "")
  if [ -n "$CONNECT_STATUS" ]; then
    echo "   ADB connected to $DEVICE_SERIAL"
    break
  fi
  sleep 3
  CONNECT_WAIT=$((CONNECT_WAIT + 3))
  echo "   Waiting for ADB... ${CONNECT_WAIT}s / ${CONNECT_TIMEOUT}s"
done

# Wait for boot completion (exit early when booted)
BOOT_TIMEOUT=${BOOT_TIMEOUT:-60}
BOOT_WAIT=0
while [ $BOOT_WAIT -lt $BOOT_TIMEOUT ]; do
  BOOT_STATUS=$(adb -s "$DEVICE_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || echo "")
  if [ "$BOOT_STATUS" = "1" ]; then
    echo "Device $DEVICE_SERIAL booted successfully!"
    break
  fi
  sleep 5
  BOOT_WAIT=$((BOOT_WAIT + 5))
  echo "   Waiting for boot... ${BOOT_WAIT}s / ${BOOT_TIMEOUT}s"
done

if [ "$BOOT_STATUS" != "1" ]; then
  echo "Boot timeout reached, continuing anyway..."
fi

# Configure device settings
echo "Configuring device settings..."

# 1. Disable lock screen and enable immersive mode
adb -s "$DEVICE_SERIAL" shell settings put secure lockscreen.disabled 1 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put secure immersive_mode_confirmations confirmed 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put global policy_control "immersive.full=*" 2>/dev/null || true
echo "   Disabled lockscreen, enabled immersive mode"

# 2. Verify HWUI renderer (set via --guest_hwui_renderer=skiavk flag)
HWUI_RENDERER=$(adb -s "$DEVICE_SERIAL" shell getprop debug.hwui.renderer 2>/dev/null | tr -d '\r')
echo "   HWUI renderer: ${HWUI_RENDERER:-skiavk (via flag)}"

# 3. Enable soft keyboard (show_ime_with_hard_keyboard)
adb -s "$DEVICE_SERIAL" shell settings put secure show_ime_with_hard_keyboard 1 2>/dev/null || true
echo "   Enabled soft keyboard"

# 4. Wake and dismiss keyguard (some builds still need explicit dismiss)
adb -s "$DEVICE_SERIAL" shell input keyevent KEYCODE_WAKEUP 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell wm dismiss-keyguard 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell input keyevent 82 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell input keyevent KEYCODE_HOME 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell cmd dream stop 2>/dev/null || true
echo "   Screen woken up and keyguard dismissed"

# 5. Disable animations for faster UI (optional, good for automation)
adb -s "$DEVICE_SERIAL" shell settings put global window_animation_scale 0 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put global transition_animation_scale 0 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put global animator_duration_scale 0 2>/dev/null || true
echo "   Disabled animations"

# 6. Set screen timeout to max (10 min)
adb -s "$DEVICE_SERIAL" shell settings put system screen_off_timeout 600000 2>/dev/null || true
echo "   Screen timeout set to 10 min"

# 7. Hide ANR/crash dialogs — Android will auto-kill unresponsive apps
#    Prevents ANR dialogs from blocking Appium/UiAutomator during tests
adb -s "$DEVICE_SERIAL" shell settings put global hide_error_dialogs 1 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put secure anr_show_background 0 2>/dev/null || true
echo "   Hidden ANR/crash dialogs (auto-kill enabled)"

echo ""
echo "Device $DEVICE_SERIAL is ready!"
echo "You can view WebRTC at: https://localhost:${WEBRTC_PORT}/client.html?deviceId=cvd-${INSTANCE_NUM}"
echo "Note: Start Appium server on separate host to connect to this device"
echo ""
