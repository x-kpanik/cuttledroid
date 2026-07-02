#!/bin/bash
# Run Cuttlefish emulator with NVIDIA GPU in Docker — x86_64 port of
# run-cuttlefish-gpu-arm64.sh (see that script for the ARM64 original).
#
# Differences from the ARM64 version:
#   - Fully self-contained container: cuttlefish-host-resources (bridges, TAPs,
#     dnsmasq, NAT) runs INSIDE the container's own network namespace. No host
#     cuttlefish services, no sudo, no --network=host.
#   - Inside the container the instance is always #1 (ports 6520/8443); host-side
#     per-instance ports are plain docker -p mappings.
#   - x86_64 host tools are glibc, so no musl/glibc bridging; hostlibs/ only
#     exposes the host NVIDIA userspace libs (must match the host kernel driver).
#   - No ARM-specific --extra_kernel_cmdline="kvm-arm.mode=nvhe".
#   - Device nodes are chmod'ed inside the container (container-local /dev
#     inodes), so no host-GID juggling.
#
# Prerequisites:
#   1. Fetch ONCE on host (any dir, default ~/cuttlefish-base-x86; branch form
#      fetches the latest green build — pinned ids rot):
#      docker run --rm -u 1000:1000 -e HOME=/home/ubuntu \
#        -v ~/cuttlefish-base-x86:/base -w /base cuttlefish-x86:latest \
#        cvd fetch --default_build=aosp-android-latest-release/aosp_cf_x86_64_only_phone-userdebug
#   2. Build image ONCE:
#      docker build -f Dockerfile.x86 -t cuttlefish-x86:latest .
#
# Usage:
#   ./run-cuttlefish-gpu-x86.sh [instance_num]    # single emulator
#   ./run-cuttlefish-gpu-x86.sh all [count]       # multiple emulators
#
# Environment variables:
#   CUTTLEFISH_BASE - pre-fetched base (default: ~/cuttlefish-base-x86)
#   X_RES, Y_RES    - resolution (default: 2340x1080, landscape)
#   CPUS            - vCPUs per emulator (default: 4)
#   MEMORY_MB       - RAM in MB (default: 6144)
#   GPU_MODE        - gfxstream_guest_angle (default) or guest_swiftshader

set -e

if [ "$1" = "all" ]; then
  COUNT=${2:-4}
  DELAY=${LAUNCH_DELAY:-6}
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  for i in $(seq 1 $COUNT); do
    echo "--- Starting container #$i of $COUNT ---"
    SKIP_BOOT_WAIT=1 "$SCRIPT_DIR/run-cuttlefish-gpu-x86.sh" "$i"
    [ $i -lt $COUNT ] && sleep $DELAY
  done
  echo "All $COUNT containers started; check each with: docker logs -f cuttlefish-x86-N"
  exit 0
fi

INSTANCE_NUM=${1:-1}
CONTAINER_NAME="cuttlefish-x86-${INSTANCE_NUM}"
ADB_PORT=$((6519 + INSTANCE_NUM))
WEBRTC_PORT=$((8442 + INSTANCE_NUM))
IMAGE_NAME=${IMAGE_NAME:-cuttlefish-x86:latest}
CUTTLEFISH_BASE="${CUTTLEFISH_BASE:-$HOME/cuttlefish-base-x86}"
WORK_DIR="${WORK_DIR:-$HOME/cf-work-x86-${INSTANCE_NUM}}"

X_RES=${X_RES:-2340}
Y_RES=${Y_RES:-1080}
DPI=${DPI:-400}
CPUS=${CPUS:-4}
MEMORY_MB=${MEMORY_MB:-6144}
GPU_MODE=${GPU_MODE:-gfxstream_guest_angle}
# "on" was an ARM64+NVIDIA finding; with vhost-user the host renderer additionally
# requires VK_EXT_external_memory_host, so keep auto on x86_64
GPU_VHOST_USER_MODE=${GPU_VHOST_USER_MODE:-auto}
REFRESH_RATE_HZ=${REFRESH_RATE_HZ:-30}

# --- Detect the NVIDIA render/card nodes (vendor 0x10de) ---
RENDER_NODE=""
CARD_NODE=""
for r in /sys/class/drm/renderD*; do
  [ -e "$r/device/vendor" ] || continue
  if [ "$(cat "$r/device/vendor")" = "0x10de" ]; then
    RENDER_NODE=$(basename "$r"); break
  fi
done
for c in /sys/class/drm/card*; do
  [ -e "$c/device/vendor" ] || continue
  if [ "$(cat "$c/device/vendor")" = "0x10de" ]; then
    CARD_NODE=$(basename "$c"); break
  fi
done

NVIDIA_DEV_ARGS=()
if [ -n "$RENDER_NODE" ] && [ "$GPU_MODE" != "guest_swiftshader" ]; then
  for d in /dev/nvidiactl /dev/nvidia0 /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools \
           "/dev/dri/$RENDER_NODE" ${CARD_NODE:+"/dev/dri/$CARD_NODE"}; do
    [ -e "$d" ] && NVIDIA_DEV_ARGS+=(--device "$d")
  done
elif [ -z "$RENDER_NODE" ] && [ "$GPU_MODE" != "guest_swiftshader" ]; then
  echo "WARNING: no NVIDIA render node found, falling back to guest_swiftshader"
  GPU_MODE=guest_swiftshader
fi

# Auto-detect NVIDIA Vulkan ICD (mounted into the container read-only)
VK_ICD_FILE="$(ls /usr/share/vulkan/icd.d/nvidia*.json 2>/dev/null | head -1 || true)"
VK_ICD_FILE="${VK_ICD_FILE:-/usr/share/vulkan/icd.d/nvidia_icd.json}"

echo "=== Cuttlefish + NVIDIA GPU (Docker, x86_64) ==="
echo "Instance:   #$INSTANCE_NUM  ($CONTAINER_NAME)"
echo "Base (RO):  $CUTTLEFISH_BASE -> /opt/cf/base"
echo "Work dir:   $WORK_DIR -> /opt/cf/run"
echo "ADB:        localhost:$ADB_PORT   WebRTC: https://localhost:$WEBRTC_PORT"
echo "Resources:  ${CPUS} vCPU, ${MEMORY_MB} MB, ${X_RES}x${Y_RES}@${DPI}dpi"
echo "GPU:        mode=$GPU_MODE render=${RENDER_NODE:-none} icd=$VK_ICD_FILE"
echo ""

# launch_cvd in the fetched dir is a symlink into the cuttlefish debs, broken
# outside the container — check a real file instead
if [ ! -f "$CUTTLEFISH_BASE/bin/assemble_cvd" ]; then
  echo "ERROR: assemble_cvd not found in $CUTTLEFISH_BASE/bin/ — run cvd fetch first (see header)"
  exit 1
fi
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "ERROR: image '$IMAGE_NAME' not found — docker build -f Dockerfile.x86 -t $IMAGE_NAME ."
  exit 1
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# ============================================================================
# In-container scripts, generated into the bind-mounted work dir.
# inner-root.sh: devices + in-netns networking + port forwarders, then drops
#                to the ubuntu user. inner-guest.sh: prepare runtime dir and
#                exec launch_cvd (must not run as root).
# ============================================================================
cat > "$WORK_DIR/inner-root.sh" <<'ROOTEOF'
#!/bin/bash
set -euo pipefail

# Container-local /dev inodes: chmod affects only this container
chmod 666 /dev/kvm /dev/net/tun 2>/dev/null || true
chmod 666 /dev/dri/* /dev/nvidia* 2>/dev/null || true

# Bridges, TAPs, dnsmasq and NAT inside this container's own netns
/etc/init.d/cuttlefish-host-resources start
/etc/init.d/cuttlefish-operator start 2>/dev/null || true

# Expose loopback-bound services on the container interface for docker -p:
#   6521 -> 6520 (adb), 8444 -> 8443 (webrtc operator)
socat TCP-LISTEN:6521,fork,reuseaddr TCP:127.0.0.1:6520 &
socat TCP-LISTEN:8444,fork,reuseaddr TCP:127.0.0.1:8443 &

chown -R ubuntu:ubuntu /opt/cf/run
exec runuser -u ubuntu -- bash /opt/cf/run/inner-guest.sh
ROOTEOF

cat > "$WORK_DIR/inner-guest.sh" <<'GUESTEOF'
#!/bin/bash
set -euo pipefail

FETCH=/opt/cf/run/fetch
mkdir -p "$FETCH" && cd "$FETCH"

# Link images/metadata from the RO base; vbmeta*.img must be COPIED because
# cuttlefish resizes them (finding from the ARM64 setup, applies here too)
for f in /opt/cf/base/*.img /opt/cf/base/android-info.txt /opt/cf/base/fetcher_config.json \
         /opt/cf/base/bootloader /opt/cf/base/*.bin; do
  [ -f "$f" ] || continue
  fname=$(basename "$f")
  if [[ "$fname" == vbmeta*.img ]]; then
    cp "$f" . 2>/dev/null || true
  else
    ln -sf "$f" . || true
  fi
done
for d in etc usr chromeos lib64; do
  [ -d "/opt/cf/base/$d" ] && ln -sf "/opt/cf/base/$d" . || true
done

# RW copy of bin (runtime writes into it)
rm -rf bin && cp -a /opt/cf/base/bin ./bin

# cvd fetch 1.5x leaves some bin/ entries as symlinks whose targets live in the
# cuttlefish debs (e.g. launch_cvd -> cvd_internal_start); repoint broken ones
# at /usr/lib/cuttlefish-common/bin/
for l in bin/*; do
  if [ -L "$l" ] && [ ! -e "$l" ]; then
    base=$(basename "$(readlink "$l")")
    [ -e "/usr/lib/cuttlefish-common/bin/$base" ] && ln -sf "/usr/lib/cuttlefish-common/bin/$base" "$l"
  fi
done

mkdir -p cuttlefish/instances cuttlefish/assembly

# hostlibs: host NVIDIA userspace libs (glibc, same as container's Ubuntu 24.04).
# libEGL_nvidia + the glvnd 10_nvidia.json are REQUIRED even for Vulkan-only use:
# in a headless container the NVIDIA Vulkan ICD bootstraps its RM connection
# through the EGL vendor path; without it vkCreateInstance silently vanishes.
mkdir -p "$FETCH/hostlibs"
if [ "${GPU_MODE:-gfxstream_guest_angle}" != "guest_swiftshader" ] && [ -d /opt/host-glibc-libs ]; then
  for lib in /opt/host-glibc-libs/libGLX_nvidia.so* /opt/host-glibc-libs/libEGL_nvidia.so* \
             /opt/host-glibc-libs/libGLESv2_nvidia.so* /opt/host-glibc-libs/libnvidia-*.so* \
             /opt/host-glibc-libs/libVkLayer_MESA_device_select.so; do
    [ -e "$lib" ] && ln -sf "$lib" "$FETCH/hostlibs/" || true
  done
  export LD_LIBRARY_PATH="$FETCH/hostlibs"
  export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/nvidia_icd.json}"
  export __EGL_VENDOR_LIBRARY_FILENAMES="${__EGL_VENDOR_LIBRARY_FILENAMES:-/usr/share/glvnd/egl_vendor.d/10_nvidia.json}"
fi
export VK_LOADER_DEBUG=error

# CF looks for $HOME/etc/cvd_config
export HOME=$FETCH
export PATH=$FETCH/bin:$PATH

GPU_FLAGS=(--gpu_mode="${GPU_MODE:-gfxstream_guest_angle}")
if [ "${GPU_MODE:-gfxstream_guest_angle}" != "guest_swiftshader" ]; then
  GPU_FLAGS+=(
    --gpu_context_types="${GPU_CONTEXT_TYPES:-gfxstream-gles:gfxstream-vulkan}"
    --gpu_vhost_user_mode="${GPU_VHOST_USER_MODE:-on}"
    --guest_hwui_renderer=skiavk
  )
fi

echo "=== LAUNCH PARAMS ==="
echo "GPU_FLAGS: ${GPU_FLAGS[*]}"
echo "HOME=$HOME  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
echo "===================="

exec ./bin/launch_cvd \
  "${GPU_FLAGS[@]}" \
  --vhost_user_vsock=true \
  --enable_wifi=false \
  --enable_host_bluetooth=false \
  --start_webrtc=true \
  --x_res="${X_RES:-2340}" \
  --y_res="${Y_RES:-1080}" \
  --dpi="${DPI:-400}" \
  --cpus="${CPUS:-4}" \
  --memory_mb="${MEMORY_MB:-6144}" \
  --refresh_rate_hz="${REFRESH_RATE_HZ:-30}" \
  --report_anonymous_usage_stats=n
GUESTEOF

chmod +x "$WORK_DIR/inner-root.sh" "$WORK_DIR/inner-guest.sh"

echo "Starting container..."
# --user root: inner-root.sh needs root for devices/networking; explicit so the
# launcher also works with overlay images that set USER ubuntu (e.g. appium/)
docker run -d \
  --name "$CONTAINER_NAME" \
  --user root \
  -p "127.0.0.1:${ADB_PORT}:6521" \
  -p "127.0.0.1:${WEBRTC_PORT}:8444" \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_ADMIN \
  --cap-add=MKNOD \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --shm-size=2g \
  --ulimit nofile=1048576:1048576 \
  --device /dev/kvm \
  --device /dev/net/tun \
  "${NVIDIA_DEV_ARGS[@]}" \
  -e GPU_MODE="$GPU_MODE" \
  -e GPU_VHOST_USER_MODE="$GPU_VHOST_USER_MODE" \
  -e GPU_CONTEXT_TYPES="${GPU_CONTEXT_TYPES:-}" \
  -e VK_ICD_FILENAMES="$VK_ICD_FILE" \
  -e X_RES="$X_RES" -e Y_RES="$Y_RES" -e DPI="$DPI" \
  -e CPUS="$CPUS" -e MEMORY_MB="$MEMORY_MB" \
  -e REFRESH_RATE_HZ="$REFRESH_RATE_HZ" \
  -v "$CUTTLEFISH_BASE":/opt/cf/base:ro \
  -v "$WORK_DIR":/opt/cf/run \
  -v /usr/lib/x86_64-linux-gnu:/opt/host-glibc-libs:ro \
  -v /usr/share/vulkan:/usr/share/vulkan:ro \
  -v /usr/share/glvnd:/usr/share/glvnd:ro \
  -v /usr/share/nvidia:/usr/share/nvidia:ro \
  "$IMAGE_NAME" \
  bash /opt/cf/run/inner-root.sh

echo ""
echo "Container started. Logs: docker logs -f $CONTAINER_NAME"

if [ "${SKIP_BOOT_WAIT:-0}" = "1" ]; then
  exit 0
fi

# --- Wait for boot (adb lives inside the container) ---
BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
WAITED=0
BOOT_STATUS=""
echo "Waiting for device to boot (timeout ${BOOT_TIMEOUT}s)..."
while [ $WAITED -lt $BOOT_TIMEOUT ]; do
  if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)" != "running" ]; then
    echo "Container exited; last logs:"
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
    exit 1
  fi
  docker exec "$CONTAINER_NAME" adb connect 127.0.0.1:6520 >/dev/null 2>&1 || true
  BOOT_STATUS=$(docker exec "$CONTAINER_NAME" adb -s 127.0.0.1:6520 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || echo "")
  if [ "$BOOT_STATUS" = "1" ]; then
    echo "Device booted (${WAITED}s)"
    break
  fi
  sleep 5
  WAITED=$((WAITED + 5))
  echo "  waiting... ${WAITED}s"
done
[ "$BOOT_STATUS" != "1" ] && echo "Boot timeout reached, continuing anyway..."

# --- Device config for automation (same set as the ARM64 script) ---
CFG() { docker exec "$CONTAINER_NAME" adb -s 127.0.0.1:6520 shell "$@" 2>/dev/null || true; }
CFG settings put secure lockscreen.disabled 1
CFG settings put secure immersive_mode_confirmations confirmed
CFG settings put global policy_control "immersive.full=*"
CFG settings put global window_animation_scale 0
CFG settings put global transition_animation_scale 0
CFG settings put global animator_duration_scale 0
CFG settings put system screen_off_timeout 600000
CFG settings put secure show_ime_with_hard_keyboard 1
CFG settings put global hide_error_dialogs 1
CFG settings put secure anr_show_background 0
CFG input keyevent KEYCODE_WAKEUP
CFG wm dismiss-keyguard
CFG input keyevent KEYCODE_HOME

echo ""
echo "=== Ready ==="
echo "  ADB:     adb connect localhost:$ADB_PORT"
echo "  WebRTC:  https://localhost:$WEBRTC_PORT/  (self-signed cert)"
echo "  Shell:   docker exec -it $CONTAINER_NAME bash"
echo "  Stop:    docker rm -f $CONTAINER_NAME"
