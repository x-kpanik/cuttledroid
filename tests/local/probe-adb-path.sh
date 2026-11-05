#!/bin/bash
# Boots one device and inspects the ADB_NODELAY wrapper and the host side ADB path.
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/../.."
INSTANCE=${INSTANCE:-7}
PORT=$((6519 + INSTANCE))
C="cuttlefish-x86-$INSTANCE"
docker rm -f "$C" >/dev/null 2>&1
ADB_NODELAY=${ADB_NODELAY:-1} IMAGE_NAME=${IMAGE_NAME:-cuttlefish-x86:nodelay} BOOT_TIMEOUT=300 \
  ./scripts/run-cuttlefish-gpu-x86.sh "$INSTANCE" 2>&1 | grep -E 'Device booted|Boot timeout|ERROR' | head -1

echo "=== wrapper state in the run dir ==="
docker exec "$C" ls -l /opt/cf/run/fetch/bin/socket_vsock_proxy /opt/cf/run/fetch/bin/socket_vsock_proxy.real 2>&1
docker exec "$C" grep -c ADB_NODELAY /opt/cf/run/inner-guest.sh
docker exec "$C" ls -l /usr/lib/tcp_nodelay.so

echo; echo "=== processes that could carry adb ==="
docker exec "$C" ps -eo pid,user,comm,args | grep -iE 'vsock|proxy|adb|socat' | grep -v grep | cut -c1-140

echo; echo "=== where the running proxy binary really lives ==="
docker exec "$C" sh -c 'for p in $(pgrep -x socket_vsock_proxy); do readlink -f /proc/$p/exe; done | sort | uniq -c'
docker exec "$C" sh -c 'ls -l /var/tmp/cvd/1000/*/artifacts/host_tools/bin/socket_vsock_proxy 2>/dev/null | head -2'
docker exec "$C" sh -c 'env | grep -E "^(ADB_NODELAY|LD_PRELOAD)=" ; p=$(pgrep -x socket_vsock_proxy | head -1); echo "proxy env:"; tr "\0" "\n" < /proc/$p/environ | grep -E "^(ADB_NODELAY|LD_PRELOAD|HOME|PATH)=" '

echo; echo "=== listeners on 6520 and 6521 inside ==="
docker exec "$C" ss -ltnp | grep -E ':6520|:6521' | cut -c1-140

echo; echo "=== host side adb path ==="
adb disconnect >/dev/null 2>&1
for i in 1 2 3; do adb connect "127.0.0.1:$PORT" 2>&1; sleep 4; adb devices | grep -q "127.0.0.1:$PORT.*device$" && break; done
adb devices -l 2>&1 | grep -v '^List'
adb -s "127.0.0.1:$PORT" shell echo alive 2>&1 | tr -d '\r'
echo "--- raw request to the mapped port ---"
printf '000chost:version' | timeout 3 nc -q 2 127.0.0.1 "$PORT" | od -c | head -2 || echo "no reply"
echo "--- versions ---"
adb version | head -1
docker exec "$C" adb version | head -1

echo; echo "=== the same device from inside the container ==="
docker exec "$C" adb connect 127.0.0.1:6520 >/dev/null 2>&1
docker exec "$C" adb devices | grep -v List
docker exec "$C" adb -s 127.0.0.1:6520 shell echo alive

if [ "${KEEP:-0}" != 1 ]; then docker rm -f "$C" >/dev/null 2>&1; fi
echo DONE
