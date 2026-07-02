#!/bin/bash
# Run Cuttlefish emulator WITHOUT a GPU (SwiftShader, CPU rendering) in Docker
# on ARM64 hosts — the no-GPU twin of run-cuttlefish-gpu-arm64.sh.
#
# Nothing GPU-related is passed into the container (no NVIDIA devices, no host
# GL/Vulkan libraries, no musl->glibc hostlibs bridging), so this works on
# ARM64 hosts without any GPU at all. The guest renders through SwiftShader —
# much slower than gfxstream, so the default resolution is reduced.
#
# Prerequisites (same as the GPU launcher):
#   1. Fetch ONCE on host (branch form = latest green build; pinned ids rot):
#      mkdir -p ~/cuttlefish-base && cd ~/cuttlefish-base
#      cvd fetch --default_build=aosp-android-latest-release/aosp_cf_arm64_only_phone-userdebug
#   2. Build image ONCE:
#      docker build -f Dockerfile.arm64 -t cuttlefish-ubuntu24:latest .
#   3. cuttlefish-host-resources running on the host (see setup-host.sh)
#
# Usage:
#   ./run-cuttlefish-nogpu-arm64.sh [instance_num]    # single emulator
#   ./run-cuttlefish-nogpu-arm64.sh all [count]       # multiple emulators
#
# GPU and no-GPU instances share the same port formula (adb 6519+N,
# webrtc 8442+N) — do not reuse an instance number a GPU instance is using.
#
# Environment variables:
#   CUTTLEFISH_BASE - Path to pre-fetched base (default: /opt/cuttlefish-base)
#   X_RES, Y_RES    - Screen resolution (default: 1280x720 — SwiftShader is slow)
#   CPUS            - vCPUs per emulator (default: 6)
#   MEMORY_MB       - RAM in MB (default: 8192)

set -e

# =============================================================================
# Multi-instance mode: ./run-cuttlefish-nogpu-arm64.sh all [count]
# =============================================================================
if [ "$1" = "all" ]; then
  COUNT=${2:-8}
  DELAY=${LAUNCH_DELAY:-6}

  echo "=== Launching $COUNT no-GPU emulators (${DELAY}s delay between each) ==="
  echo ""

  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

  # Phase 1: Start all containers quickly (skip boot wait)
  for i in $(seq 1 $COUNT); do
    echo "--- Starting container #$i of $COUNT ---"
    SKIP_BOOT_WAIT=1 "$SCRIPT_DIR/run-cuttlefish-nogpu-arm64.sh" "$i"

    if [ $i -lt $COUNT ]; then
      sleep $DELAY
    fi
  done

  echo ""
  echo "=== Phase 2: Waiting for ADB & boot ==="

  # SwiftShader boots slower than GPU mode; allow more time
  BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
  START_TIME=$(date +%s)
  while true; do
    BOOTED=0
    for i in $(seq 1 $COUNT); do
      PORT=$((6519 + i))
      adb connect localhost:$PORT >/dev/null 2>&1 || true
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

  WEBRTC_OK=0
  ADB_OK=0
  for i in $(seq 1 $COUNT); do
    PORT=$((6519 + i))
    WEBRTC_PORT=$((8442 + i))
    SERIAL="localhost:$PORT"

    adb connect $SERIAL >/dev/null 2>&1 || true

    if adb -s $SERIAL shell echo ok >/dev/null 2>&1; then
      ADB_OK=$((ADB_OK + 1))

      adb -s $SERIAL shell settings put secure lockscreen.disabled 1 2>/dev/null || true
      adb -s $SERIAL shell settings put secure immersive_mode_confirmations confirmed 2>/dev/null || true
      adb -s $SERIAL shell settings put global policy_control "immersive.full=*" 2>/dev/null || true
      adb -s $SERIAL shell settings put global window_animation_scale 0 2>/dev/null || true
      adb -s $SERIAL shell settings put global transition_animation_scale 0 2>/dev/null || true
      adb -s $SERIAL shell settings put global animator_duration_scale 0 2>/dev/null || true
      adb -s $SERIAL shell settings put system screen_off_timeout 600000 2>/dev/null || true
      adb -s $SERIAL shell settings put secure show_ime_with_hard_keyboard 1 2>/dev/null || true
      adb -s $SERIAL shell settings put global hide_error_dialogs 1 2>/dev/null || true
      adb -s $SERIAL shell settings put secure anr_show_background 0 2>/dev/null || true
      adb -s $SERIAL shell input keyevent KEYCODE_WAKEUP 2>/dev/null || true
      adb -s $SERIAL shell wm dismiss-keyguard 2>/dev/null || true
      adb -s $SERIAL shell input keyevent 82 2>/dev/null || true
      adb -s $SERIAL shell input keyevent KEYCODE_HOME 2>/dev/null || true
      adb -s $SERIAL shell cmd dream stop 2>/dev/null || true
    fi

    DEVICES=$(curl -sk https://localhost:$WEBRTC_PORT/devices 2>/dev/null || echo "[]")
    if echo "$DEVICES" | grep -q "cvd-$i"; then
      echo "nogpu-$i: ADB=$PORT WebRTC=$WEBRTC_PORT OK"
      echo "   WebRTC: https://localhost:${WEBRTC_PORT}/devices/cvd-${i}/files/client.html"
      WEBRTC_OK=$((WEBRTC_OK + 1))
    else
      echo "nogpu-$i: ADB=$PORT WebRTC=$WEBRTC_PORT MISSING"
    fi
  done

  echo ""
  echo "=== Done: $COUNT containers, $ADB_OK ADB OK, $WEBRTC_OK WebRTC OK ==="
  exit 0
fi

INSTANCE_NUM=${1:-1}
CONTAINER_NAME="cuttlefish-nogpu-${INSTANCE_NUM}"
ADB_PORT=$((6519 + INSTANCE_NUM))
WEBRTC_PORT=$((8442 + INSTANCE_NUM))
IMAGE_NAME=${IMAGE_NAME:-cuttlefish-ubuntu24:latest}

# Paths
# Fixed path for multi-user access (was $HOME/cuttlefish-base)
CUTTLEFISH_BASE="${CUTTLEFISH_BASE:-/opt/cuttlefish-base}"

# Work directory: bind mount by default (see run-cuttlefish-gpu-arm64.sh for
# the named-volume alternative and why bind mounts are the default)
WORK_DIR="${WORK_DIR:-/opt/cf-work-nogpu-${INSTANCE_NUM}}"
USE_BIND_MOUNT=true

# Defaults reduced for CPU rendering (SwiftShader)
X_RES=${X_RES:-1280}
Y_RES=${Y_RES:-720}
CPUS=${CPUS:-6}
MEMORY_MB=${MEMORY_MB:-8192}
DPI=${DPI:-240}

# CPU pinning: each container gets dedicated cores (no overlap), same layout
# as the GPU launcher
CPU_CORES_PER_CONTAINER=${CPU_CORES_PER_CONTAINER:-7}
CPU_START=$(( (INSTANCE_NUM - 1) * CPU_CORES_PER_CONTAINER ))
CPU_END=$(( CPU_START + CPU_CORES_PER_CONTAINER - 1 ))
CPU_SET="${CPU_START}-${CPU_END}"
echo "Instance $INSTANCE_NUM → CPUs ${CPU_SET} (pinned)"

echo "=== Cuttlefish, no GPU / SwiftShader (Docker, ARM64) ==="
echo ""
echo "Instance:      #$INSTANCE_NUM"
echo "Container:     $CONTAINER_NAME"
echo "Image:         $IMAGE_NAME"
echo "Base (RO):     $CUTTLEFISH_BASE → /opt/cf/base"
echo "Work Dir:      $WORK_DIR → /opt/cf/run (bind mount)"
echo "ADB Port:      $ADB_PORT"
echo "WebRTC:        $WEBRTC_PORT"
echo "Resolution:    ${X_RES}x${Y_RES} @ ${DPI}dpi"
echo "Resources:     ${CPUS} vCPUs, ${MEMORY_MB}MB RAM, pinned to CPUs ${CPU_SET}"
echo "GPU Mode:      guest_swiftshader (no GPU passthrough)"
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

if [ ! -f "$CUTTLEFISH_BASE/bin/assemble_cvd" ]; then
    echo "ERROR: assemble_cvd not found in $CUTTLEFISH_BASE/bin/"
    exit 1
fi

# Check image exists
if ! docker image inspect $IMAGE_NAME &>/dev/null; then
    echo "ERROR: Image '$IMAGE_NAME' not found!"
    echo "Build it first: docker build -f Dockerfile.arm64 -t cuttlefish-ubuntu24:latest ."
    exit 1
fi

# Remove existing container if running (but NOT other instances!)
echo "Cleaning up container $CONTAINER_NAME..."
docker rm -f $CONTAINER_NAME 2>/dev/null || true

# NOTE: Don't clean /tmp/cf_avd_* /tmp/cf_env_* /tmp/vsock_* globally!
# Each instance uses unique paths based on base_instance_num

# =============================================================================
# Dynamic GID detection (host GIDs differ between hosts; the container must
# join the HOST's cvdnetwork group to use the TAP devices created by the
# cuttlefish-host-resources service)
# =============================================================================
HOST_CVDNETWORK_GID=$(getent group cvdnetwork | cut -d: -f3 2>/dev/null || echo "115")
HOST_KVM_GID=$(getent group kvm | cut -d: -f3 2>/dev/null || echo "993")

sudo rm -rf "$WORK_DIR" 2>/dev/null || true
sudo mkdir -p "$WORK_DIR"
sudo chown -R 1000:1000 "$WORK_DIR"

# =============================================================================
# RETRY LOGIC: Restart container if crosvm fails to start
# =============================================================================
MAX_RETRIES=${MAX_RETRIES:-3}
CROSVM_WAIT_TIMEOUT=${CROSVM_WAIT_TIMEOUT:-45}

start_container() {
echo "Starting container..."
echo ""

docker run -d \
  --name "$CONTAINER_NAME" \
  --network=host \
  --cpus=${DOCKER_CPUS:-7} \
  --cpuset-cpus="${CPU_SET}" \
  --memory=${DOCKER_MEM:-10g} \
  --entrypoint bash \
  --group-add "$HOST_KVM_GID" \
  --group-add "$HOST_CVDNETWORK_GID" \
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
  -e CUTTLEFISH_INSTANCE="$INSTANCE_NUM" \
  -e INSTANCE_NUM="$INSTANCE_NUM" \
  -e ADB_PORT="$ADB_PORT" \
  -e WEBRTC_PORT="$WEBRTC_PORT" \
  -e X_RES="$X_RES" \
  -e Y_RES="$Y_RES" \
  -e DPI="$DPI" \
  -e CPUS="$CPUS" \
  -e MEMORY_MB="$MEMORY_MB" \
  -v "$CUTTLEFISH_BASE":/opt/cf/base:ro \
  -v "$WORK_DIR":/opt/cf/run \
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

    # cvd fetch 1.5x leaves some bin/ entries as symlinks whose targets live in
    # the cuttlefish debs (e.g. launch_cvd -> cvd_internal_start); repoint
    # broken ones at /usr/lib/cuttlefish-common/bin/
    for l in bin/*; do
      if [ -L "$l" ] && [ ! -e "$l" ]; then
        base=$(basename "$(readlink "$l")")
        [ -e "/usr/lib/cuttlefish-common/bin/$base" ] && ln -sf "/usr/lib/cuttlefish-common/bin/$base" "$l"
      fi
    done

    # Clean runtime
    rm -rf cuttlefish/instances/* cuttlefish/assembly .cuttlefish_config.json 2>/dev/null || true
    mkdir -p cuttlefish/instances cuttlefish/assembly

    # No GPU: no hostlibs, no LD_LIBRARY_PATH — SwiftShader renders in the guest

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
    echo "=== LAUNCH PARAMS (no GPU / SwiftShader) ==="
    echo "INSTANCE_NUM=${INSTANCE_NUM:-1}"
    echo "WEBRTC_PORT=${WEBRTC_PORT:-8443}"
    echo "HOME=$HOME"
    echo "============================================"

    # CUTTLEFISH_INSTANCE env var sets instance id (more compatible than flags)
    exec ./bin/launch_cvd \
      --gpu_mode=guest_swiftshader \
      --vhost_user_vsock=true \
      --enable_wifi=false \
      --enable_host_bluetooth=false \
      --start_webrtc=true \
      --x_res=${X_RES:-1280} \
      --y_res=${Y_RES:-720} \
      --dpi=${DPI:-240} \
      --cpus=${CPUS:-6} \
      --memory_mb=${MEMORY_MB:-8192} \
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
  CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
  if [ "$CONTAINER_STATUS" != "running" ]; then
    echo "Container exited unexpectedly (status: $CONTAINER_STATUS)"
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "VIRTUAL_DEVICE_BOOT_FAILED"; then
      echo "   Detected: VIRTUAL_DEVICE_BOOT_FAILED (likely Bluetooth race condition)"
    fi
    return 1
  fi

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
echo "=== Container Started (SwiftShader) ==="
echo ""
echo "Access:"
echo "   ADB:     adb connect localhost:$ADB_PORT"
echo "   WebRTC:  https://localhost:$WEBRTC_PORT"
echo "   WebRTC:  https://localhost:${WEBRTC_PORT}/devices/cvd-${INSTANCE_NUM}/files/client.html"
echo ""
echo "Management:"
echo "   Logs:    docker logs -f $CONTAINER_NAME"
echo "   Shell:   docker exec -it $CONTAINER_NAME bash"
echo "   Stop:    docker stop $CONTAINER_NAME"
echo ""

# === POST-BOOT ADB CONFIGURATION ===
if [ "${SKIP_BOOT_WAIT:-0}" = "1" ]; then
  echo "Container started (boot wait skipped)"
  exit 0
fi

echo "Waiting for device to boot completely..."
DEVICE_SERIAL="localhost:$ADB_PORT"

echo "   Connecting to ADB..."
CONNECT_TIMEOUT=120
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

# SwiftShader boots slower than GPU mode; allow more time
BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
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

# Configure device settings (same set as the GPU launcher)
echo "Configuring device settings..."

adb -s "$DEVICE_SERIAL" shell settings put secure lockscreen.disabled 1 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put secure immersive_mode_confirmations confirmed 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put global policy_control "immersive.full=*" 2>/dev/null || true
echo "   Disabled lockscreen, enabled immersive mode"

adb -s "$DEVICE_SERIAL" shell settings put secure show_ime_with_hard_keyboard 1 2>/dev/null || true
echo "   Enabled soft keyboard"

adb -s "$DEVICE_SERIAL" shell input keyevent KEYCODE_WAKEUP 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell wm dismiss-keyguard 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell input keyevent 82 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell input keyevent KEYCODE_HOME 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell cmd dream stop 2>/dev/null || true
echo "   Screen woken up and keyguard dismissed"

adb -s "$DEVICE_SERIAL" shell settings put global window_animation_scale 0 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put global transition_animation_scale 0 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put global animator_duration_scale 0 2>/dev/null || true
echo "   Disabled animations"

adb -s "$DEVICE_SERIAL" shell settings put system screen_off_timeout 600000 2>/dev/null || true
echo "   Screen timeout set to 10 min"

adb -s "$DEVICE_SERIAL" shell settings put global hide_error_dialogs 1 2>/dev/null || true
adb -s "$DEVICE_SERIAL" shell settings put secure anr_show_background 0 2>/dev/null || true
echo "   Hidden ANR/crash dialogs (auto-kill enabled)"

echo ""
echo "Device $DEVICE_SERIAL is ready (SwiftShader)!"
echo "You can view WebRTC at: https://localhost:${WEBRTC_PORT}/devices/cvd-${INSTANCE_NUM}/files/client.html"
echo ""
