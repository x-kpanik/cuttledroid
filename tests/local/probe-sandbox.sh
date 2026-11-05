#!/bin/bash
# Checks whether cvd runs socket_vsock_proxy in its own mount namespace, which would hide the marker file.
set -uo pipefail
cd "$(dirname "$0")/../.."
INSTANCE=${INSTANCE:-7}
C="cuttlefish-x86-$INSTANCE"
docker rm -f "$C" >/dev/null 2>&1
ADB_NODELAY=1 IMAGE_NAME=${IMAGE_NAME:-cuttlefish-x86:nodelay} BOOT_TIMEOUT=300 \
  ./scripts/run-cuttlefish-gpu-x86.sh "$INSTANCE" 2>&1 | grep -E 'Device booted|Boot timeout|ERROR' | head -1
echo "=== marker as seen by docker exec ==="
docker exec "$C" ls -la /run/cuttledroid/
echo; echo "=== the wrapper that is installed ==="
docker exec "$C" head -5 /usr/lib/cuttlefish-common/bin/socket_vsock_proxy
echo; echo "=== one proxy process, its namespace, root view and environment ==="
docker exec -u 1000 "$C" sh -c '
  p=$(pgrep -f socket_vsock_proxy.real | head -1); echo "pid $p"
  echo "mnt ns of pid 1:  $(readlink /proc/1/ns/mnt)"
  echo "mnt ns of proxy:  $(readlink /proc/$p/ns/mnt)"
  echo "user ns of proxy: $(readlink /proc/$p/ns/user)   pid1: $(readlink /proc/1/ns/user)"
  echo "marker via proxy root:"; ls -la /proc/$p/root/run/cuttledroid/ 2>&1 | head -3
  echo "proxy sees /usr/lib/tcp_nodelay.so: $(ls /proc/$p/root/usr/lib/tcp_nodelay.so 2>&1)"
  echo "mounts in proxy ns: $(wc -l < /proc/$p/mountinfo)   in pid1: $(wc -l < /proc/1/mountinfo)"
  echo "environ of proxy:"; tr "\0" "\n" < /proc/$p/environ | grep -E "^(LD_PRELOAD|HOME|PATH|ADB_NODELAY)=" ; echo "env entries: $(tr "\0" "\n" < /proc/$p/environ | wc -l)"
  echo "maps has shim: $(grep -c tcp_nodelay /proc/$p/maps)"
  echo "parent chain:"; pp=$p; for i in 1 2 3 4; do pp=$(awk "/^PPid/{print \$2}" /proc/$pp/status); printf "  %s %s\n" "$pp" "$(cat /proc/$pp/comm 2>/dev/null)"; [ "$pp" = 1 ] && break; done'
docker rm -f "$C" >/dev/null 2>&1; rm -rf "$HOME/cf-work-x86-$INSTANCE"
echo DONE
