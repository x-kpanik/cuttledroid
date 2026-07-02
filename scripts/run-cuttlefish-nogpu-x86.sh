#!/bin/bash
# Run Cuttlefish emulator WITHOUT a GPU (SwiftShader, CPU rendering) in Docker
# on x86_64 hosts — the no-GPU twin of run-cuttlefish-gpu-x86.sh.
#
# Nothing GPU-related is passed into the container (no NVIDIA devices, no host
# GL/Vulkan libraries), so this works on hosts without any GPU at all. The
# guest renders through SwiftShader — much slower than gfxstream, so the
# default resolution is reduced.
#
# Prerequisites (same as the GPU launcher):
#   1. Fetch ONCE on host (any dir, default ~/cuttlefish-base-x86):
#      docker run --rm -u 1000:1000 -e HOME=/home/ubuntu \
#        -v ~/cuttlefish-base-x86:/base -w /base cuttlefish-x86:latest \
#        cvd fetch --default_build=aosp-android-latest-release/aosp_cf_x86_64_only_phone-userdebug
#   2. Build image ONCE:
#      docker build -f Dockerfile.x86 -t cuttlefish-x86:latest .
#
# Usage:
#   ./run-cuttlefish-nogpu-x86.sh [instance_num]    # single emulator
#   ./run-cuttlefish-nogpu-x86.sh all [count]       # multiple emulators
#
# GPU and no-GPU instances share the same port formula (adb 6519+N,
# webrtc 8442+N) — do not reuse an instance number a GPU instance is using.
#
# Environment variables:
#   CUTTLEFISH_BASE - pre-fetched base (default: ~/cuttlefish-base-x86)
#   X_RES, Y_RES    - resolution (default: 1280x720 — SwiftShader is slow)
#   CPUS            - vCPUs per emulator (default: 4)
#   MEMORY_MB       - RAM in MB (default: 4096)

set -e

if [ "$1" = "all" ]; then
  COUNT=${2:-4}
  DELAY=${LAUNCH_DELAY:-6}
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  for i in $(seq 1 $COUNT); do
    echo "--- Starting container #$i of $COUNT ---"
    SKIP_BOOT_WAIT=1 "$SCRIPT_DIR/run-cuttlefish-nogpu-x86.sh" "$i"
    [ $i -lt $COUNT ] && sleep $DELAY
  done
  echo "All $COUNT containers started; check each with: docker logs -f cuttlefish-nogpu-x86-N"
  exit 0
fi

INSTANCE_NUM=${1:-1}
CONTAINER_NAME="cuttlefish-nogpu-x86-${INSTANCE_NUM}"
ADB_PORT=$((6519 + INSTANCE_NUM))
WEBRTC_PORT=$((8442 + INSTANCE_NUM))
IMAGE_NAME=${IMAGE_NAME:-cuttlefish-x86:latest}
CUTTLEFISH_BASE="${CUTTLEFISH_BASE:-$HOME/cuttlefish-base-x86}"
WORK_DIR="${WORK_DIR:-$HOME/cf-work-nogpu-x86-${INSTANCE_NUM}}"

X_RES=${X_RES:-1280}
Y_RES=${Y_RES:-720}
DPI=${DPI:-240}
CPUS=${CPUS:-4}
MEMORY_MB=${MEMORY_MB:-4096}
REFRESH_RATE_HZ=${REFRESH_RATE_HZ:-30}

echo "=== Cuttlefish, no GPU / SwiftShader (Docker, x86_64) ==="
echo "Instance:   #$INSTANCE_NUM  ($CONTAINER_NAME)"
echo "Base (RO):  $CUTTLEFISH_BASE -> /opt/cf/base"
echo "Work dir:   $WORK_DIR -> /opt/cf/run"
echo "ADB:        localhost:$ADB_PORT   WebRTC: https://localhost:$WEBRTC_PORT"
echo "Resources:  ${CPUS} vCPU, ${MEMORY_MB} MB, ${X_RES}x${Y_RES}@${DPI}dpi"
echo "GPU:        none (guest_swiftshader)"
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
# ============================================================================
cat > "$WORK_DIR/inner-root.sh" <<'ROOTEOF'
#!/bin/bash
set -euo pipefail

# Container-local /dev inodes: chmod affects only this container
chmod 666 /dev/kvm /dev/net/tun 2>/dev/null || true

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
# cuttlefish resizes them
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
for l in bin/*; do
  if [ -L "$l" ] && [ ! -e "$l" ]; then
    base=$(basename "$(readlink "$l")")
    [ -e "/usr/lib/cuttlefish-common/bin/$base" ] && ln -sf "/usr/lib/cuttlefish-common/bin/$base" "$l"
  fi
done

mkdir -p cuttlefish/instances cuttlefish/assembly

# CF looks for $HOME/etc/cvd_config
export HOME=$FETCH
export PATH=$FETCH/bin:$PATH

echo "=== LAUNCH PARAMS (no GPU / SwiftShader) ==="
echo "HOME=$HOME  ${X_RES:-1280}x${Y_RES:-720}@${DPI:-240}"
echo "============================================"

exec ./bin/launch_cvd \
  --gpu_mode=guest_swiftshader \
  --vhost_user_vsock=true \
  --enable_wifi=false \
  --enable_host_bluetooth=false \
  --start_webrtc=true \
  --x_res="${X_RES:-1280}" \
  --y_res="${Y_RES:-720}" \
  --dpi="${DPI:-240}" \
  --cpus="${CPUS:-4}" \
  --memory_mb="${MEMORY_MB:-4096}" \
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
  -e X_RES="$X_RES" -e Y_RES="$Y_RES" -e DPI="$DPI" \
  -e CPUS="$CPUS" -e MEMORY_MB="$MEMORY_MB" \
  -e REFRESH_RATE_HZ="$REFRESH_RATE_HZ" \
  -v "$CUTTLEFISH_BASE":/opt/cf/base:ro \
  -v "$WORK_DIR":/opt/cf/run \
  "$IMAGE_NAME" \
  bash /opt/cf/run/inner-root.sh

echo ""
echo "Container started. Logs: docker logs -f $CONTAINER_NAME"

if [ "${SKIP_BOOT_WAIT:-0}" = "1" ]; then
  exit 0
fi

# --- Wait for boot (adb lives inside the container) ---
# SwiftShader boots slower than GPU mode; allow more time.
BOOT_TIMEOUT=${BOOT_TIMEOUT:-600}
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

# --- Device config for automation (same set as the GPU launcher) ---
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
echo "=== Ready (SwiftShader) ==="
echo "  ADB:     adb connect localhost:$ADB_PORT"
echo "  WebRTC:  https://localhost:$WEBRTC_PORT/  (self-signed cert)"
echo "  Shell:   docker exec -it $CONTAINER_NAME bash"
echo "  Stop:    docker rm -f $CONTAINER_NAME"
