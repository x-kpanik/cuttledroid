#!/bin/bash
# Builds the x86 image with the shim and measures ADB round trips with the shim off and on.
set -uo pipefail
export LC_ALL=C
mkdir -p "${CUTTLEDROID_TEST_OUT:-/tmp/cuttledroid-tests}"
OUT_ROOT=${CUTTLEDROID_TEST_OUT:-/tmp/cuttledroid-tests}
W="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$OUT_ROOT/nodelay"
mkdir -p "$OUT"; cd "$W"
section() { echo; echo "##### $1"; }

section "1 build the image from the branch"
docker build -q -f Dockerfile.x86 -t cuttlefish-x86:nodelay . > "$OUT/build.log" 2>&1 && echo "built" || { tail -5 "$OUT/build.log"; exit 1; }
docker run --rm cuttlefish-x86:nodelay sh -c 'ls -l /usr/lib/tcp_nodelay.so && cvd version 2>&1 | grep ^version'

preload_check() {
  # Lists which host processes have the shim mapped, by reading the maps of every pid.
  echo "--- processes with the shim mapped ---"
  docker exec -u 1000 "$1" sh -c 'for p in $(pgrep -f socket_vsock_proxy.real); do grep -q tcp_nodelay /proc/$p/maps 2>/dev/null && echo "pid $p shim yes" || echo "pid $p shim no"; done | sort | uniq -c -f2'
  echo "--- socket_vsock_proxy processes in total: $(docker exec "$1" sh -c 'pgrep -fc socket_vsock_proxy.real')"
  docker exec "$1" sh -c "pgrep -af 'socat TCP-LISTEN:6521' | grep -v pgrep | cut -c1-80"
}

measure() {
  # Round trip of adb shell from the host through the mapped port, and from inside the container.
  local label=$1 port=$2 c=$3 n=30
  adb disconnect "127.0.0.1:$port" >/dev/null 2>&1
  local state="" tries=0
  while [ "$state" != device ] && [ $tries -lt 10 ]; do
    sleep 3; tries=$((tries+1))
    adb connect "127.0.0.1:$port" >/dev/null 2>&1
    state=$(adb devices | awk -v d="127.0.0.1:$port" '$1==d{print $2}')
    [ "$state" = offline ] && adb disconnect "127.0.0.1:$port" >/dev/null 2>&1
  done
  if [ "$state" != device ]; then echo "$label: no device after $tries tries, state ${state:-absent}"; return; fi
  for rep in 1 2 3; do
    local ok=0 t0 t1
    t0=$(date +%s%N)
    for i in $(seq $n); do [ "$(adb -s "127.0.0.1:$port" shell echo ok 2>/dev/null | tr -d '\r')" = ok ] && ok=$((ok+1)); done
    t1=$(date +%s%N)
    printf '%-8s host  rep%d  %2d/%d ok  %6.1f ms per call\n' "$label" "$rep" "$ok" "$n" "$(echo "($t1-$t0)/$n/1000000" | bc -l)"
  done
  for rep in 1 2 3; do
    local out
    out=$(docker exec "$c" sh -c 'n=30; ok=0; adb connect 127.0.0.1:6520 >/dev/null 2>&1; t0=$(date +%s%N); for i in $(seq $n); do [ "$(adb -s 127.0.0.1:6520 shell echo ok 2>/dev/null | tr -d "\r")" = ok ] && ok=$((ok+1)); done; t1=$(date +%s%N); echo "$ok $(( (t1-t0)/n/1000 ))"')
    printf '%-8s inner rep%d  %2d/%d ok  %6.1f ms per call\n' "$label" "$rep" "${out% *}" "$n" "$(echo "${out#* }/1000" | bc -l)"
  done
}

for flag in 0 1; do
  section "2 boot instance 7 with ADB_NODELAY=$flag on the 1.55 base"
  docker rm -f cuttlefish-x86-7 >/dev/null 2>&1
  ADB_NODELAY=$flag IMAGE_NAME=cuttlefish-x86:nodelay BOOT_TIMEOUT=300 \
    ./scripts/run-cuttlefish-gpu-x86.sh 7 > "$OUT/launch-$flag.log" 2>&1
  grep -E 'Device booted|Boot timeout|ERROR' "$OUT/launch-$flag.log" | head -1
  preload_check cuttlefish-x86-7
  measure "flag=$flag" 6526 cuttlefish-x86-7
done
docker rm -f cuttlefish-x86-7 >/dev/null 2>&1; rm -rf "$HOME/cf-work-x86-7"

section "3 the same wrapper on a cvd 1.57 base"
FRESH="$HOME/cuttlefish-base-fresh"
if [ ! -f "$FRESH/fetcher_config.json" ]; then
  mkdir -p "$FRESH"
  docker run --rm -u 1000:1000 -e HOME=/home/ubuntu -v "$FRESH":/base -w /base cuttlefish-x86:nodelay \
    cvd fetch --default_build=aosp-android-latest-release/aosp_cf_x86_64_only_phone-userdebug \
      --target_directory=/base --noenable_caching > "$OUT/fetch.log" 2>&1 && echo "fetched $(jq -r '[.cvd_files[] | select(.source == "default_build") | .build_id] | map(select(. != "")) | first' "$FRESH/fetcher_config.json")"
fi
docker rm -f cuttlefish-x86-9 >/dev/null 2>&1
ADB_NODELAY=1 IMAGE_NAME=cuttlefish-x86:nodelay CUTTLEFISH_BASE="$FRESH" BOOT_TIMEOUT=300 \
  ./scripts/run-cuttlefish-gpu-x86.sh 9 > "$OUT/launch-157.log" 2>&1
grep -E 'Device booted|Boot timeout|ERROR' "$OUT/launch-157.log" | head -1
preload_check cuttlefish-x86-9
measure "1.57" 6528 cuttlefish-x86-9
docker rm -f cuttlefish-x86-9 >/dev/null 2>&1; rm -rf "$HOME/cf-work-x86-9"
echo DONE
