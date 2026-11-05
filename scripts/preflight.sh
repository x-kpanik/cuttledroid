#!/bin/bash
# Checks whether this host can run a device, before anything is downloaded.
# Exit code 0 means devices can run, 1 means something required is missing.
set -uo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  warn  %s\n    -> %s\n' "$1" "$2"; WARN=$((WARN+1)); }
bad()  { printf '  FAIL  %s\n    -> %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

ARCH=$(uname -m)
echo "Host check for cuttledroid"
echo

echo "Platform"
case "$ARCH" in
  x86_64)  ok "architecture $ARCH, use the x86 launchers" ;;
  aarch64) ok "architecture $ARCH, use the arm64 launchers" ;;
  *) bad "architecture $ARCH is not supported" "only x86_64 and aarch64 are supported" ;;
esac
if [ -r /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = "24.04" ]; then
    ok "Ubuntu 24.04"
  else
    warn "host is ${PRETTY_NAME:-unknown}" "only Ubuntu 24.04 is tested, the container image is Ubuntu 24.04 either way"
  fi
fi

echo
echo "Docker"
if ! command -v docker >/dev/null; then
  bad "docker is not installed" "install docker and add yourself to the docker group"
elif ! docker info >/dev/null 2>&1; then
  bad "docker is installed but not usable by $(id -un)" "add yourself to the docker group and log in again"
else
  ok "docker usable without sudo"
  if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    bad "docker is running rootless" "the launcher needs to chmod device nodes inside the container, rootless docker cannot"
  else
    ok "docker is not rootless"
  fi
fi

echo
echo "KVM"
if [ ! -e /dev/kvm ]; then
  bad "/dev/kvm is missing" "enable virtualisation in the firmware, or nested virtualisation if this is a VM"
else
  ok "/dev/kvm exists"
  LOCAL_IMAGE=$(docker images -q 2>/dev/null | head -1)
  if [ -n "$LOCAL_IMAGE" ]; then
    if docker run --rm --device /dev/kvm "$LOCAL_IMAGE" true >/dev/null 2>&1; then
      ok "docker can pass /dev/kvm into a container"
    else
      bad "docker cannot pass /dev/kvm into a container" "check the device cgroup policy and any seccomp or apparmor profile"
    fi
  else
    warn "no local image to test the device passthrough with" "re-run after the first docker pull"
  fi
fi

echo
echo "GPU"
RENDER_NODE=""
for r in /sys/class/drm/renderD*; do
  [ -e "$r/device/vendor" ] || continue
  if [ "$(cat "$r/device/vendor")" = "0x10de" ]; then RENDER_NODE=$(basename "$r"); break; fi
done
if [ -z "$RENDER_NODE" ]; then
  warn "no NVIDIA render node found" "devices will run on SwiftShader, use the nogpu launchers and expect much lower performance"
else
  ok "NVIDIA render node /dev/dri/$RENDER_NODE"
  if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    ok "driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1) on $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  else
    warn "nvidia-smi does not run on the host" "the container needs the host userspace libraries to match the kernel driver"
  fi
  MODESET=/sys/module/nvidia_drm/parameters/modeset
  if [ -r "$MODESET" ] && [ "$(cat $MODESET)" = Y ]; then
    ok "nvidia-drm modeset is on"
  else
    warn "nvidia-drm modeset is off" "set options nvidia-drm modeset=1, rebuild the initramfs and reboot"
  fi
  ICD=$(ls /usr/share/vulkan/icd.d/nvidia*.json 2>/dev/null | head -1)
  if [ -n "$ICD" ]; then ok "Vulkan ICD $ICD"; else bad "no NVIDIA Vulkan ICD in /usr/share/vulkan/icd.d" "install the NVIDIA Vulkan driver package"; fi
  GLVND=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
  if [ -r "$GLVND" ]; then
    ok "glvnd EGL vendor file present"
  else
    bad "missing $GLVND" "headless Vulkan silently fails without the EGL vendor path, install libnvidia-gl"
  fi
fi

echo
echo "Resources"
FREE_KB=$(df -Pk "$HOME" | awk 'NR==2{print $4}')
FREE_GB=$((FREE_KB / 1024 / 1024))
if [ "$FREE_GB" -ge 10 ]; then
  ok "${FREE_GB} GB free in $HOME"
else
  bad "only ${FREE_GB} GB free in $HOME" "one base needs 3.1 GB and every device writes about 1.2 GB"
fi
CORES=$(nproc)
RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
ok "${CORES} cores and ${RAM_GB} GB RAM, about $((RAM_GB / 5)) devices fit at the default 6144 MB profile"
for port in 6520 8443; do
  if command -v ss >/dev/null && ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    warn "port $port is already in use" "start at a different instance number, each one shifts both ports by one"
  fi
done

echo
printf 'passed %d, warnings %d, failures %d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "This host cannot run a device yet."
  exit 1
fi
if [ -z "$RENDER_NODE" ]; then
  echo "This host can run CPU rendered devices."
else
  echo "This host can run GPU accelerated devices."
fi
