# Cuttlefish Android Emulator Setup Guide

Setup instructions for running GPU-accelerated Cuttlefish Android emulators on
Ubuntu 24.04 with an NVIDIA GPU on AWS (g5g.metal).

## Verified configuration

This path has been validated end to end with Docker, an NVIDIA T4G GPU, GPU mode
`gfxstream_guest_angle`, and the `skiavk` HWUI renderer. It runs up to about 14
concurrent GPU-accelerated Android instances on a single g5g.metal node.

Reference GLES string from a running instance:

```
GLES: Google (NVIDIA Corporation), Android Emulator OpenGL ES Translator (NVIDIA T4G/PCIe)
```

| Parameter | Value |
|-----------|-------|
| GPU mode | `gfxstream_guest_angle` |
| HWUI renderer | `skiavk` |
| GPU vhost user | `on` |
| Resolution | `1024x600` |
| DPI | `180` |
| Host OS | Ubuntu 24.04 LTS, glibc 2.39 |
| Docker image | `cuttlefish-ubuntu24:latest` (Ubuntu 24.04, glibc 2.39) |
| NVIDIA driver | 580.105.08 |
| GPU | NVIDIA T4G/PCIe |
| Android base build | `14654133/aosp_cf_arm64_only_phone-userdebug` |
| OpenGL | OpenGL ES 3.2 NVIDIA 580.105.08 |

Reference `assemble_cvd` output confirming GPU passthrough:

```
assemble_cvd: vendor: "NVIDIA"
assemble_cvd: vendor: "NVIDIA Corporation"
assemble_cvd: version: "OpenGL ES 3.2 NVIDIA 580.105.08"
assemble_cvd: renderer: "NVIDIA T4G/PCIe"
```

## Prerequisites

- ARM64 / aarch64 host with an NVIDIA GPU. Reference hardware: AWS g5g.metal
  (ARM64 + 2x NVIDIA T4G, 64 vCPU, 128 GB RAM).
- Ubuntu 24.04 LTS (arm64).
- KVM available (`/dev/kvm`).
- Docker.
- NVIDIA driver 580.x (installed by `scripts/setup-host.sh`).

Note: x86_64 hosts are not supported yet. ARM64 + gfxstream is the only verified
path; x86_64 support is planned.

## Host setup

### Automated

```bash
# Copy the project to the host
scp -r cuttlefish/ ubuntu@HOST_A:~/cuttlefish/

# Run setup: drivers, cvd fetch, docker build
ssh ubuntu@HOST_A
cd ~/cuttlefish
sudo ./scripts/setup-host.sh
sudo reboot
```

After reboot, verify the host (see "Post-reboot verification") and launch
emulators (see "Running emulators").

### Manual

The steps below reproduce what `setup-host.sh` does. Run them in order.

#### 1. System update

```bash
sudo apt update && sudo apt upgrade -y
```

#### 2. NVIDIA drivers

AWS g5g.metal instances ship with NVIDIA drivers pre-installed. Check the
versions and GPU visibility:

```bash
# Kernel module version
cat /proc/driver/nvidia/version

# GPU visibility
lspci | grep -i nvidia
```

Note: `nvidia-smi` is often absent from default ARM64 packages/AMI. Use
`cat /proc/driver/nvidia/version` or NVML-based tools instead (see
Troubleshooting and Known issues).

Version-mismatch fix. AWS AMIs sometimes ship a kernel module and userspace
libraries with different versions, which causes EGL to fail. Check `dmesg`:

```bash
dmesg | grep -i NVRM | tail -20
# "NVRM: API mismatch" means kernel module and userspace are out of sync.
```

Compare the two versions:

```bash
# Kernel module version
cat /proc/driver/nvidia/version | grep "Module"

# Userspace library version
dpkg -l | grep libnvidia-gl | head -1
```

If they differ, sync them and reboot:

```bash
sudo apt install -y nvidia-dkms-580 nvidia-kernel-source-580 linux-modules-extra-$(uname -r)
sudo modprobe nvidia-drm modeset=1
sudo reboot
```

#### 3. ADB and dependencies

```bash
sudo apt install -y \
    android-tools-adb \
    curl \
    unzip \
    git \
    qemu-kvm \
    bridge-utils \
    iproute2 \
    iptables \
    mesa-utils
```

| Package | Purpose |
|---------|---------|
| `android-tools-adb` | ADB for emulator management |
| `qemu-kvm` | KVM virtualization (kernel side for crosvm) |
| `iproute2` | Network configuration |
| `iptables` | Firewall rules for VM networking |
| `bridge-utils` | Network bridges between emulators and host |
| `mesa-utils` | OpenGL utilities (`eglinfo` for GPU verification) |
| `nvidia-dkms-580` | NVIDIA driver kernel module |
| `nvidia-kernel-source-580` | Source for building the module for your kernel |

#### 4. Cuttlefish packages

```bash
# Repository signing key
sudo curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
    -o /etc/apt/trusted.gpg.d/artifact-registry.asc
sudo chmod a+r /etc/apt/trusted.gpg.d/artifact-registry.asc

# Repository
echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
    | sudo tee -a /etc/apt/sources.list.d/artifact-registry.list

# Packages
sudo apt update
sudo apt install -y cuttlefish-base cuttlefish-user cuttlefish-orchestration
```

| Package | Contents | Purpose |
|---------|----------|---------|
| `cuttlefish-base` | Network scripts, `cvdnetwork` group, virtual interfaces (`cvd-mtap-*`, `cvd-ebr`), `/etc/default/cuttlefish-host-resources` | Network infrastructure for emulators (required for connectivity) |
| `cuttlefish-user` | Configs, udev rules, systemd services | Access permissions and autostart configuration |
| `cuttlefish-orchestration` | `cvd fetch`, `cvd` CLI, REST API server | Download Android images, API-based management |

Inspect what a package installed:

```bash
dpkg -L cuttlefish-base | head -30
dpkg -L cuttlefish-orchestration | head -30
```

#### 5. User permissions

```bash
sudo usermod -aG kvm,render,video,cvdnetwork,docker $USER
```

Note: the `cvdnetwork` group is created automatically by `cuttlefish-base`. It
is required for the virtual network interfaces between host and Android VM.

#### 6. Docker

```bash
sudo apt install -y docker.io
sudo systemctl enable docker
sudo systemctl start docker
```

#### 7. Reboot

```bash
sudo reboot
```

#### 8. Post-reboot verification

```bash
# nvidia-drm module loaded
lsmod | grep nvidia_drm

# Render nodes present
ls -la /dev/dri/
# Expected: card0, card1, renderD128, renderD129

# User groups
groups
# Expected: kvm render video cvdnetwork docker

# EGL uses NVIDIA
sudo eglinfo 2>&1 | grep -A5 "Surfaceless"
# Expected: EGL vendor string: NVIDIA
```

If `/dev/dri/` is empty:

```bash
sudo modprobe nvidia-drm modeset=1
```

If EGL shows Mesa instead of NVIDIA, see Troubleshooting.

Optional host checklist before running containers:

```bash
dpkg -l | grep cuttlefish            # base, user, orchestration installed
sudo systemctl status cuttlefish-host-resources --no-pager   # active (running)
ls -la /dev/kvm                      # exists and readable
ls -la /dev/dri/                     # card0, card1, renderD128, renderD129
eglinfo | grep -i vendor             # NVIDIA
groups $USER                         # kvm render video cvdnetwork
```

Quick validation script:

```bash
#!/bin/bash
echo "=== Host Checklist ==="
echo -n "KVM: "; [ -e /dev/kvm ] && echo "OK" || echo "MISSING"
echo -n "DRI: "; [ -d /dev/dri ] && echo "OK" || echo "MISSING"
echo -n "NVIDIA EGL: "; eglinfo 2>/dev/null | grep -qi nvidia && echo "OK" || echo "MISSING"
echo -n "CF service: "; systemctl is-active cuttlefish-host-resources &>/dev/null && echo "OK" || echo "MISSING"
echo -n "Docker: "; docker info &>/dev/null && echo "OK" || echo "MISSING"
```

#### 9. Fetch the Android image

```bash
mkdir -p ~/cuttlefish-base && cd ~/cuttlefish-base
# Branch form = latest green build; see "cvd fetch fails with 404" in
# Troubleshooting before pinning a numeric build ID.
cvd fetch --default_build=aosp-android-latest-release/aosp_cf_arm64_only_phone-userdebug
```

This downloads the Android images plus Cuttlefish binaries (~3-5 GB) into
`~/cuttlefish-base`. Containers mount this directory read-only as CF_BASE.

Note: `cvd fetch` is installed system-wide by `cuttlefish-orchestration`, not
in `./bin/`. Use a numeric build ID, not a branch name — a branch name such as
`aosp-main` returns 404 without authentication.

#### 10. Build the Docker image

```bash
cd ~/cuttlefish
docker build -t cuttlefish-ubuntu24:latest .
docker image list | grep cuttlefish-ubuntu24
```

The Dockerfile lives at the repo root. The image is intentionally small
(~200 MB): Ubuntu 24.04 (glibc 2.39, matching the host) plus runtime
dependencies (`libegl`, `libgl`, `adb`). It ships no Cuttlefish binaries and no
Android images; both come from the read-only CF_BASE mount. See "Docker
reference" for the Dockerfile and the canonical `docker run` command.

Optional: push to a registry for reuse.

```bash
docker tag cuttlefish-ubuntu24:latest registry.example.com/cuttlefish-ubuntu24:latest
docker push registry.example.com/cuttlefish-ubuntu24:latest
```

## Running emulators

### Single instance (no Docker)

`launch_cvd` uses `$HOME` as its base directory, so set `HOME=$PWD`.

```bash
cd ~/cuttlefish

# With GPU acceleration (gfxstream)
HOME=$PWD ./bin/launch_cvd --gpu_mode=gfxstream --start_webrtc=true

# Software rendering (no GPU)
HOME=$PWD ./bin/launch_cvd --gpu_mode=guest_swiftshader --start_webrtc=true
```

Verify GPU is active:

```bash
grep -i "NVIDIA\|T4G" ~/cuttlefish/cuttlefish/instances/cvd-1/logs/launcher.log
# Expected: "Graphics Adapter Vendor Google (NVIDIA Corporation)"
# Expected: "Graphics Adapter Android Emulator OpenGL ES Translator (NVIDIA T4G/PCIe)"
```

Wait for boot via ADB:

```bash
adb -s 0.0.0.0:6520 wait-for-device
while [ "$(adb -s 0.0.0.0:6520 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
  sleep 2
done
echo "Device ready"
```

### Running without a GPU (software rendering)

Set `--gpu_mode=guest_swiftshader` instead of `gfxstream_guest_angle` to render
on the CPU with SwiftShader. It needs no GPU but is much slower, so use it as a
fallback or on hosts without a supported GPU. The host-direct command above
already shows the software variant.

Through the Docker launcher, override `GPU_MODE`:

```bash
GPU_MODE=guest_swiftshader ./scripts/run-cuttlefish-gpu.sh 1
```

Note: the Docker launcher passes the host's NVIDIA devices through, so it still
requires an NVIDIA host even in software mode. On a machine with no NVIDIA GPU,
use the direct `HOME=$PWD ./bin/launch_cvd --gpu_mode=guest_swiftshader ...`
command shown above instead.

### Multiple instances

Each container runs exactly one emulator. This gives full isolation: a crash is
contained to one container, and an instance can be restarted on its own.

```bash
# Start N emulators (one container each)
./scripts/run-cuttlefish-gpu.sh all N

# Single instance by index (ADB 6519+N, WebRTC 8442+N)
./scripts/run-cuttlefish-gpu.sh 1   # ADB:6520, WebRTC:8443
./scripts/run-cuttlefish-gpu.sh 2   # ADB:6521, WebRTC:8444
```

ADB ports run `localhost:6520` ... `localhost:6534` for 15 instances. Container
6520 maps to host port `6519 + N`.

The script symlinks the shared read-only base, creates per-container read-write
runtime state, and starts `launch_cvd`. The base in `~/cuttlefish-base` (`bin/`,
`lib64/`, `etc/`, `usr/`, and the `*.img` images) is mounted read-only into every
container at `/opt/cf/base`, which saves disk; only runtime data is local to each
container. The GPU is shared across all containers.

Launch flags used inside the container:

| Flag | Description |
|------|-------------|
| `--gpu_mode=gfxstream` | NVIDIA GPU acceleration |
| `--num_instances=N` | Number of emulators (single-container mode) |
| `--cpus=N` | vCPUs per instance (default 2) |
| `--memory_mb=N` | RAM per instance in MB |
| `--x_res=WIDTH` | Screen width in pixels (default 720) |
| `--y_res=HEIGHT` | Screen height in pixels (default 1280) |
| `--dpi=N` | Screen density (default 320) |
| `--start_webrtc=true` | Enable WebRTC streaming |
| `--instance_num=N` | Instance ID for multi-instance |
| `--webrtc_port=844N` | WebRTC port per instance |
| `--enable_wifi=false` | Avoid TAP device conflicts between instances |
| `--base_instance_num=N` | Port offset on host network (ADB 6519+N, WebRTC 8442+N) |
| `--report_anonymous_usage_stats=n` | Disable usage stats prompt |

Landscape and CPU example (games typically need landscape; auto-rotate does not
work — see Known issues):

```bash
cd ~/cuttlefish

# 10 instances, 4 CPUs each, landscape 1280x720
HOME=$PWD ./bin/launch_cvd --gpu_mode=gfxstream --num_instances=10 --cpus=4 --start_webrtc=true \
  --x_res=1280 --y_res=720 --dpi=320
```

Multi-instance flags on a host-network container:

```bash
--network=host           # required for TAP networking
--tmpfs /tmp:rw,size=4g  # isolate /tmp per container
-e CUTTLEFISH_INSTANCE=N # instance ID (1, 2, ...)

# launch_cvd:
--enable_wifi=false      # avoid TAP conflicts between instances
--webrtc_port=844N       # distinct WebRTC port per instance
--gpu_mode=gfxstream
```

On host network, `launch_cvd` always starts "instance #1" on default ports
(6520, 8443) unless given port/instance separation parameters. The exact port
parameters depend on the Cuttlefish version; check `launcher.log` for the ports
actually selected. The simplest model is one emulator per node.

Verified multi-instance output:

```
localhost:6520  device  → NVIDIA T4G/PCIe (gfxstream)
localhost:6521  device  → NVIDIA T4G/PCIe (gfxstream)
```

#### Post-launch device setup

After instances boot, unlock screens and disable the immersive-mode popup. Set
the port range to match the instance count (15 instances span 6520-6534).

```bash
# Wait for boot
for port in $(seq 6520 6529); do
  while [ "$(adb -s 0.0.0.0:$port shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
    sleep 2
  done
  echo "$port ready"
done

# Unlock screens
for port in $(seq 6520 6529); do
  adb -s 0.0.0.0:$port shell input keyevent 82
  adb -s 0.0.0.0:$port shell input swipe 540 1800 540 800
done

# Disable immersive-mode confirmation popup
for port in $(seq 6520 6529); do
  adb -s 0.0.0.0:$port shell settings put secure immersive_mode_confirmations confirmed
done

# Enable soft keyboard
for port in $(seq 6520 6529); do
  adb -s 0.0.0.0:$port shell settings put secure show_ime_with_hard_keyboard 1
done
```

Install and launch an app on all running emulators:

```bash
APK_PATH="/home/ubuntu/app.apk"
PACKAGE="com.example.app"
ACTIVITY="com.example.app.MainActivity"

FIRST_PORT=6520
LAST_PORT=$((FIRST_PORT + $(adb devices | grep -c "device$") - 1))

# Install in parallel
for port in $(seq $FIRST_PORT $LAST_PORT); do
  adb -s 0.0.0.0:$port install -r -g "$APK_PATH" &
done
wait

# Unlock screens
for port in $(seq $FIRST_PORT $LAST_PORT); do
  adb -s 0.0.0.0:$port shell input keyevent 82
  adb -s 0.0.0.0:$port shell input swipe 540 1800 540 800
done

# Disable immersive-mode confirmations
for port in $(seq $FIRST_PORT $LAST_PORT); do
  adb -s 0.0.0.0:$port shell settings put secure immersive_mode_confirmations confirmed
done

# Launch sequentially with a short delay
for port in $(seq $FIRST_PORT $LAST_PORT); do
  adb -s 0.0.0.0:$port shell am start -n "$PACKAGE/$ACTIVITY"
  sleep 3
done
```

## Connecting

### ADB

```bash
adb devices
adb connect 127.0.0.1:6520   # or localhost:6520
```

### Install an APK

```bash
# Single device
adb -s localhost:6520 install -r app.apk

# All running emulators
./scripts/install-and-launch.sh ~/app.apk
```

### WebRTC over SSH tunnel

WebRTC ports are 8443 for instance 1, 8444 for instance 2, and so on. Forward
them from your local machine, then open the URL in a browser. Each instance has
its own WebRTC window (cvd-1, cvd-2, ...).

```bash
# Single instance
ssh -L 8443:localhost:8443 ubuntu@<AWS_IP>
# https://localhost:8443

# Two instances
ssh -L 8443:localhost:8443 -L 8444:localhost:8444 ubuntu@<AWS_IP>
# https://localhost:8443 — emulator 1
# https://localhost:8444 — emulator 2
```

## Configuration

Environment variables for `scripts/run-cuttlefish-gpu.sh`:

```bash
X_RES=1920 Y_RES=1080 CPUS=6 MEMORY_MB=6144 \
  ./scripts/run-cuttlefish-gpu.sh cuttlefish-emu-1 6520 8443
```

| Variable | Default | Description |
|----------|---------|-------------|
| `X_RES` | 1280 | Screen width (landscape) |
| `Y_RES` | 720 | Screen height |
| `CPUS` | 4 | vCPUs per emulator |
| `MEMORY_MB` | 4096 | RAM in MB |
| `DPI` | 320 | Screen density |
| `GPU_MODE` | gfxstream | GPU mode (`gfxstream` / `guest_swiftshader`) |
| `WEBRTC_ENABLED` | true | Enable WebRTC streaming |
| `NETWORK_MODE` | bridge | `bridge` or `host` |
| `RESET_RUNTIME` | false | Reset CF_RUN on start |
| `CUTTLEFISH_BASE` | `~/cuttlefish-base` | Path to read-only CF_BASE |

GPU modes:

| Mode | Description | Use case |
|------|-------------|----------|
| `gfxstream` | GPU acceleration via NVIDIA | Best performance |
| `gfxstream_guest_angle` | gfxstream with ANGLE in guest (verified path) | NVIDIA T4G + skiavk |
| `drm_virgl` | GPU via virglrenderer | AMD/Intel GPU |
| `guest_swiftshader` | Software rendering | No GPU available |

## Architecture

### musl vs glibc

The Cuttlefish ARM64 host tools (from `cvd-host_package.tar.gz`) are musl-based,
while the NVIDIA Vulkan/EGL drivers are glibc-based. The runtime bridges the two
by creating symlinks to the host's glibc libraries in a dedicated `hostlibs`
directory and pointing `LD_LIBRARY_PATH` only at that directory.

With the verified `gfxstream_guest_angle + skiavk` mode, only Vulkan symlinks are
required. ANGLE translates OpenGL to Vulkan inside Android, so host-side EGL/GLES
libraries are not needed. The implementation lives in
`scripts/run-cuttlefish-gpu.sh`.

```bash
mkdir -p "$FETCH/hostlibs"
ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1 "$FETCH/hostlibs/libvulkan.so.1"
ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1 "$FETCH/hostlibs/libvulkan.so"

export LD_LIBRARY_PATH="$FETCH/hostlibs"
```

For reference, the earlier approach symlinked EGL, GLES, GLX, and Vulkan; it is
no longer needed:

```bash
mkdir -p "$FETCH/hostlibs"
ln -sf /usr/lib/aarch64-linux-gnu/libGLESv2.so.2.1.0 "$FETCH/hostlibs/libGLESv2.so"
ln -sf /usr/lib/aarch64-linux-gnu/libEGL.so.1 "$FETCH/hostlibs/libEGL.so"
ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1 "$FETCH/hostlibs/libvulkan.so.1"
ln -sf /usr/lib/aarch64-linux-gnu/libvulkan.so.1 "$FETCH/hostlibs/libvulkan.so"
ln -sf /usr/lib/aarch64-linux-gnu/libGLX_nvidia.so.0 "$FETCH/hostlibs/libGLX_nvidia.so.0"

export LD_LIBRARY_PATH="$FETCH/hostlibs"
```

### CF_BASE vs CF_RUN

| Directory | Mount | Purpose |
|-----------|-------|---------|
| `CF_BASE` (`/opt/cf/base`) | read-only | Android images and binaries from `cvd fetch` |
| `CF_RUN` (`/opt/cf/run`) | read-write (volume) | Runtime data, logs, instance state |

CF_BASE is never written to. All runtime data goes to CF_RUN, which is a Docker
volume (or bind mount) for persistence and isolation.

### With vs without Docker

Without Docker, a single `launch_cvd --num_instances=N` process owns every
instance and starts one `crosvm` VM per device under the same process tree. This
couples the instances: a single one cannot be restarted on its own, one stuck or
crashed instance can disrupt the others, and there are no standard orchestration
or lifecycle tools.

With Docker, each emulator runs in its own container (`cuttlefish-emu-N`) with
one `crosvm` VM and its GPU renderer inside. Containers are independent: restart
one device with `docker restart cuttlefish-emu-2`, a crash is contained to a
single container, and the layout maps cleanly onto Kubernetes and CI/CD.

| Metric | Without Docker | With Docker |
|--------|----------------|-------------|
| RAM per emulator | ~5-6 GB | ~5-6 GB (same) |
| CPU per emulator | ~4 vCPU | ~4 vCPU (same) |
| Overhead | minimal | ~50-100 MB per container |
| Startup time | ~2 min (all at once) | ~2-3 min per container |
| Restart one | not possible | `docker restart` (~30 s) |
| Management | custom scripts | Docker / Kubernetes |

### Runtime image layout

The image is small because everything large is mounted at runtime and shared:

| Component | Size | Source |
|-----------|------|--------|
| Docker image | ~200 MB | `cuttlefish-ubuntu24:latest` |
| Cuttlefish base + images | ~3-5 GB | `~/cuttlefish-base`, mounted read-only at `/opt/cf/base` |
| Per-instance runtime | varies | volume or bind mount at `/opt/cf/run` |
| NVIDIA GPU libraries | host | `/usr/lib/aarch64-linux-gnu`, mounted read-only |

### Read-only file system, HOME, and bin

`assemble_cvd` writes its initial log next to its own binary. Running it directly
from the read-only `/opt/cf/base/bin/` fails:

```
E assemble_cvd: Could not open initial log file: Read-only file system
```

The fix is to assemble a read-write "fetch dir" with `HOME` pointing at it,
symlink the read-only images and metadata, but copy `bin/` so logs can be
written there. `bin/` must be a copy, not a symlink to the read-only base.

```bash
# 1. HOME must be a read-write location
export HOME=/opt/cf/run/fetch
mkdir -p $HOME && cd $HOME

# 2. Copy bin (read-write for logs)
cp -a /opt/cf/base/bin ./bin

# 3. Symlink images and metadata (read-only is fine)
for f in /opt/cf/base/*.img /opt/cf/base/android-info.txt /opt/cf/base/fetcher_config.json; do
  [ -f "$f" ] && ln -sf "$f" . || true
done

# 4. Symlink other directories
for d in etc usr chromeos; do
  [ -d /opt/cf/base/$d ] && ln -sf /opt/cf/base/$d . || true
done

# 5. Clean runtime
rm -rf cuttlefish/instances/* cuttlefish/assembly .cuttlefish_config.json 2>/dev/null || true
mkdir -p cuttlefish/instances cuttlefish/assembly

# 6. Launch from the read-write fetch dir
exec ./bin/launch_cvd --gpu_mode=gfxstream ...
```

| Item | Symlink OK? | Copy required? | Notes |
|------|-------------|----------------|-------|
| `*.img` | yes | no | read-only access |
| `android-info.txt` | yes | no | read-only access |
| `fetcher_config.json` | yes | no | read-only access |
| `etc/`, `usr/`, `chromeos/` | yes | no | read-only access |
| `bin/` | no | yes | `assemble_cvd` writes logs here |

Use the original `launch_cvd` from `cvd fetch`. Do not wrap it with a custom
script that calls `assemble_cvd` directly — the flags are not 1:1 between
`launch_cvd` and `assemble_cvd`. If `launch_cvd` is missing or broken, the base
is corrupted; re-run `cvd fetch` rather than recreating it manually.

When running a custom launch flow, override the image entrypoint so it does not
conflict with the mount/launch logic:

```bash
docker run --entrypoint bash ... cuttlefish-ubuntu24:latest -lc "<script>"
```

## Docker reference

### Dockerfile

The Dockerfile is at the repo root. Build with
`docker build -t cuttlefish-ubuntu24:latest .`.

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Cuttlefish repository
RUN apt-get update && apt-get install -y curl gnupg \
    && curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
       -o /etc/apt/trusted.gpg.d/artifact-registry.asc \
    && echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
       > /etc/apt/sources.list.d/artifact-registry.list

# Packages matching the host
RUN apt-get update && apt-get install -y \
    cuttlefish-base cuttlefish-user cuttlefish-orchestration \
    android-tools-adb qemu-kvm qemu-system-arm \
    mesa-utils libegl1 libegl-mesa0 libgl1-mesa-dri \
    libvulkan1 vulkan-tools libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home/ubuntu/cuttlefish
EXPOSE 6520 8443
CMD ["/bin/bash"]
```

The image uses Ubuntu 24.04 with glibc 2.39, matching the host. Google's
official `cuttlefish-orchestration:latest` image is based on Debian 12
(glibc 2.36); mounting host binaries into it crashes with
`Error relocating libstdc++.so.6: arc4random: symbol not found`. The Ubuntu
24.04 image avoids that ABI mismatch.

### Canonical docker run

This is the reference command with GPU passthrough. `--gpus all` fails on ARM64
with NVIDIA drivers (NVML version mismatch), so GPU devices and libraries are
mounted manually instead.

```bash
docker run -d --name cuttlefish-emu-1 \
  --privileged \
  --entrypoint bash \
  -v /home/ubuntu/cuttlefish-base:/opt/cf/base:ro \
  -v cf-run-cuttlefish-emu-1:/opt/cf/run \
  -v /dev/dri:/dev/dri \
  -v /usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:ro \
  -v /usr/share/glvnd:/usr/share/glvnd:ro \
  -v /usr/share/egl:/usr/share/egl:ro \
  -v /usr/share/vulkan:/usr/share/vulkan:ro \
  -v /etc/vulkan:/etc/vulkan:ro \
  --device /dev/kvm \
  -p 8443:8443 -p 6520:6520 \
  -e __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/01_nvidia.json \
  -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json \
  cuttlefish-ubuntu24:latest \
  -lc '
    set -euo pipefail

    FETCH=/opt/cf/run/fetch
    mkdir -p $FETCH && cd $FETCH

    # Symlink images/metadata (read-only is fine)
    for f in /opt/cf/base/*.img /opt/cf/base/android-info.txt /opt/cf/base/fetcher_config.json; do
      [ -f "$f" ] && ln -sf "$f" . || true
    done
    for d in etc usr chromeos; do
      [ -d /opt/cf/base/$d ] && ln -sf /opt/cf/base/$d . || true
    done

    # Copy bin (read-write for logs)
    rm -rf bin && cp -a /opt/cf/base/bin ./bin

    # Clean runtime
    rm -rf cuttlefish/instances/* cuttlefish/assembly .cuttlefish_config.json 2>/dev/null || true
    mkdir -p cuttlefish/instances cuttlefish/assembly

    export HOME=$FETCH
    exec ./bin/launch_cvd \
      --gpu_mode=gfxstream \
      --start_webrtc=true \
      --x_res=1280 --y_res=720 --dpi=320 \
      --cpus=4 --memory_mb=4096 \
      --report_anonymous_usage_stats=n
  '
```

Required mounts for gfxstream:

| Mount | Type | Purpose |
|-------|------|---------|
| `/dev/kvm` | device | KVM virtualization for crosvm |
| `/dev/dri` | device | GPU render nodes (card0, card1, renderD128, renderD129) |
| `/usr/lib/aarch64-linux-gnu` | bind (ro) | NVIDIA libraries plus dependencies |
| `/usr/share/glvnd` | bind (ro) | EGL vendor configuration |
| `/usr/share/egl` | bind (ro) | EGL configs |
| `/usr/share/vulkan` | bind (ro) | Vulkan ICD configuration |
| `/etc/vulkan` | bind (ro) | Vulkan configs |

Mount the entire `/usr/lib/aarch64-linux-gnu` directory rather than individual
`*nvidia*` files: EGL/GLX/GBM pull in dependent `.so` files that do not match the
`*nvidia*` pattern, and a broad mount avoids missing-library errors.

Required environment variables. Confirm the actual EGL vendor JSON filename first
(`10_nvidia.json` or `01_nvidia.json`; lower number means higher priority):

```bash
ls /usr/share/glvnd/egl_vendor.d/*nvidia*.json

-e __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/01_nvidia.json
-e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
```

These force EGL and Vulkan to use NVIDIA instead of Mesa.

### Container management

```bash
# List running emulators
docker ps --filter name=cuttlefish-emu

# Follow boot progress
docker logs -f cuttlefish-emu-1

# Shell into a container
docker exec -it cuttlefish-emu-1 bash

# Stop / restart / remove one
docker stop cuttlefish-emu-1
docker restart cuttlefish-emu-1
docker rm -f cuttlefish-emu-1

# Stop / remove all
docker stop $(docker ps -q --filter name=cuttlefish-emu)
docker rm -f $(docker ps -aq --filter name=cuttlefish-emu)
```

### Network modes

Bridge mode (default) gives each container its own network namespace, so
internal ports (6520, 8443) do not conflict and external ports are mapped per
container. Use it for development, testing, and most CI/CD.

Host network mode (`NETWORK_MODE=host`, or `hostNetwork: true` in Kubernetes)
shares the host network namespace with no port mapping. `launch_cvd` binds
directly to default ports, so it is effectively one emulator per node unless you
pass port/instance separation parameters. Use it for Kubernetes clusters.

## CVD management and useful commands

CVD binaries run from `~/cuttlefish` with the `HOME=$PWD` prefix. `cvd fetch` is
the exception — it is a system command installed by `cuttlefish-orchestration`,
not in `./bin/`.

| Tool | Description | Supports `--instance_num`? |
|------|-------------|----------------------------|
| `cvd fetch` | Download Android image (system command) | n/a |
| `launch_cvd` | Start all emulators | no (starts all) |
| `stop_cvd` | Stop all emulators | no (stops all) |
| `restart_cvd` | Soft reboot of Android in the VM | yes |
| `cvd_status` | Show status of running instances | no |
| `powerbtn_cvd` | Simulate power button | yes |
| `powerwash_cvd` | Factory reset | yes |
| `record_cvd` | Screen recording | yes |
| `snapshot_util_cvd` | Save/load snapshots | yes |
| `cvd_send_sms` | Send SMS | yes |
| `cvd_import_locations` | Import GPS locations | yes |
| `cvd_host_bugreport` | Generate bug report | no |

Per-instance management (only for tools that support `--instance_num`):

```bash
cd ~/cuttlefish

HOME=$PWD ./bin/cvd_status
HOME=$PWD ./bin/restart_cvd --instance_num=5
HOME=$PWD ./bin/stop_cvd --instance_num=5
HOME=$PWD ./bin/powerbtn_cvd --instance_num=5
HOME=$PWD ./bin/powerwash_cvd --instance_num=5
```

Soft reboot of one instance via ADB (same effect as `restart_cvd`):

```bash
adb -s 0.0.0.0:6525 reboot
adb -s 0.0.0.0:6525 wait-for-device
while [ "$(adb -s 0.0.0.0:6525 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
  sleep 2
done

# Or force-stop and relaunch the app
adb -s 0.0.0.0:6525 shell am force-stop com.example.app
adb -s 0.0.0.0:6525 shell am start -n com.example.app/.MainActivity
```

General reference commands:

```bash
cat /proc/driver/nvidia/version            # NVIDIA driver version
lsmod | grep nvidia                        # loaded modules
sudo eglinfo 2>&1 | head -30               # EGL info
ps aux | grep crosvm                       # GPU/VM processes
cat /proc/driver/nvidia/gpus/*/information # GPU info via procfs
top -bn1 | head -20                        # system load

# Cuttlefish GPU log lines
grep -i "nvidia\|T4G\|GPU" ~/cuttlefish/cuttlefish/instances/cvd-1/logs/launcher.log | tail -10
```

Note: `restart_cvd` only sends a reboot command to a running crosvm VM. It does
not call `assemble_cvd` and does not recreate runtime files. It works when
Android froze but the crosvm process is alive and the `internal/` directory is
intact; it does not work when crosvm crashed, `internal/` was deleted, or the
launcher monitor socket is unavailable.

Caution: do not delete `cuttlefish/instances/cvd-N/internal/`. It holds FIFO
files created by `assemble_cvd` on the initial launch. `restart_cvd` does not
recreate them, and deleting the directory makes the instance unrecoverable — the
only recovery is a full `launch_cvd` of all emulators.

## Stopping and cleanup

Use `stop_cvd` for graceful shutdown; fall back to `cvd reset` if needed.

```bash
cd ~/cuttlefish

# Graceful stop
HOME=$PWD ./bin/stop_cvd

# Check status
HOME=$PWD ./bin/cvd status

# Full reset if stop_cvd did not help
HOME=$PWD ./bin/cvd reset -y
```

Clean up before launching new instances:

```bash
cd ~/cuttlefish

HOME=$PWD ./bin/stop_cvd
HOME=$PWD ./bin/cvd reset -y 2>/dev/null || true

# Temp files
sudo rm -rf /tmp/vsock_* /tmp/cf_avd_* /tmp/cf_env_*
rm -rf ~/cuttlefish/cuttlefish_runtime* 2>/dev/null || true
rm -rf ~/cuttlefish/cuttlefish/instances/*
rm -rf ~/cuttlefish/cuttlefish/assembly
rm -rf ~/cuttlefish/cuttlefish/environments 2>/dev/null || true
rm -f ~/cuttlefish/.cuttlefish_config.json

df -h /home/ubuntu
```

Temporary files outside `~/cuttlefish` that must be cleaned between runs:
`/tmp/cf_avd_1000/` (shared runtime sockets), `/tmp/vsock_*_1000/` (VM socket
files), and `/tmp/cf_env_*` (environment state).

Warning: do not use `pkill crosvm` or Ctrl+C to stop instances. It kills the VM
but leaves TAP devices (`cvd-wifiap-01`, etc.) busy, and the next `launch_cvd`
fails with `Device "cvd-wifiap-01" in use`. The correct order is `stop_cvd` →
`cvd reset` → clean temp files. Use `pkill` only as a last resort. In
multi-instance setups, do not clean `/tmp/vsock_*` globally — it kills all
instances.

## Troubleshooting

### NVRM API mismatch: kernel module vs userspace

```
NVRM: API mismatch: the client has version X, but kernel module has version Y
```

Sync the versions and reboot:

```bash
cat /proc/driver/nvidia/version
dpkg -l | grep libnvidia-gl
sudo apt install nvidia-dkms-580 nvidia-kernel-source-580 -y
sudo reboot
```

### EGL uses Mesa instead of NVIDIA

`eglinfo` shows `kms_swrast` or `llvmpipe` instead of NVIDIA. Force NVIDIA EGL
with the env var (reversible) rather than renaming or deleting Mesa JSON files,
which breaks the system globally.

```bash
ls -la /usr/share/glvnd/egl_vendor.d/
# Lower number = higher priority (10_nvidia.json, 01_nvidia.json, ...)

export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
eglinfo 2>&1 | grep -i vendor   # Expected: NVIDIA
```

### /dev/dri/ empty or missing

```bash
sudo modprobe nvidia-drm modeset=1
ls -la /dev/dri/
```

If `modprobe` fails with "Module not found":

```bash
sudo apt install linux-modules-extra-$(uname -r) -y
sudo modprobe nvidia-drm modeset=1
```

### Permission denied on /dev/dri/

```bash
sudo usermod -aG video $USER
newgrp video
```

### cvd fetch fails with 404

Three distinct causes, none of which mean "the build is gone":

1. **The `aosp-main` branch is dead for public fetches.** It no longer publishes
   public Cuttlefish artifacts (and its old builds have been garbage-collected).
   This is a 404, not an auth problem. Use `aosp-android-latest-release`:

   ```bash
   # Fails (dead branch):
   cvd fetch --default_build=aosp-main/aosp_cf_arm64_only_phone-userdebug
   # Works (latest green build on the release branch):
   cvd fetch --default_build=aosp-android-latest-release/aosp_cf_arm64_only_phone-userdebug
   ```

2. **Pinned build IDs eventually rot.** Google CI garbage-collects old
   artifacts, so a numeric ID that works today can 404 later. Prefer the
   branch form above; pin an ID only for reproducible CI caches and expect
   to refresh it. Resolve the current latest ID with:

   ```bash
   curl -s -o /dev/null -w '%{redirect_url}\n' \
     "https://ci.android.com/builds/latest/branches/aosp-android-latest-release/targets/aosp_cf_arm64_only_phone-userdebug/view/BUILD_INFO"
   # → .../builds/submitted/<BUILD_ID>/...
   ```

3. **`HEAD` requests to `ci.android.com/.../raw/...` always return 404** — the
   service only routes `GET`. `curl -I` "verifying" an artifact proves nothing;
   use `curl -L` (optionally with `-r 0-0`).

### launch_cvd: "Could not read from dir /home/ubuntu/etc/cvd_config"

`launch_cvd` uses `$HOME` as its base directory. Set `HOME=$PWD`:

```bash
cd ~/cuttlefish
HOME=$PWD ./bin/launch_cvd --gpu_mode=gfxstream --start_webrtc=true
```

### gfxstream: "prerequisites for accelerated rendering were not detected"

```bash
sudo eglinfo 2>&1 | grep -A5 "Surfaceless"
```

If it shows Mesa, fix the EGL vendor (above). If it shows NVIDIA but still fails,
check `/dev/dri/` permissions.

### Permission denied on launch

```bash
groups   # should include kvm render video cvdnetwork
```

If groups are missing, add them and reboot:

```bash
sudo usermod -aG kvm,render,video,cvdnetwork $USER
sudo reboot
```

### EGL shows Mesa inside a container

```bash
docker exec cuttlefish-emu-1 ls -la /usr/lib/aarch64-linux-gnu/libEGL_nvidia*
docker exec cuttlefish-emu-1 ls /usr/share/glvnd/egl_vendor.d/*nvidia*.json
docker exec cuttlefish-emu-1 eglinfo 2>&1 | grep -A3 "Surfaceless"
# Expected: EGL vendor string: NVIDIA
```

### --gpus all fails with NVML error

Expected on ARM64 with NVIDIA drivers. Use manual device mounts (see Docker
reference); that is the supported approach.

### Container starts but emulator does not boot

```bash
docker logs cuttlefish-emu-1

# Common causes:
# 1. CF_BASE not mounted   -> check -v ~/cuttlefish-base:/opt/cf/base:ro
# 2. GPU not available      -> check /dev/dri mounts
# 3. KVM not available      -> check --device /dev/kvm

docker exec cuttlefish-emu-1 ls -la /opt/cf/base/bin/launch_cvd
docker exec cuttlefish-emu-1 ls -la /opt/cf/base/*.img
```

### Emulator crashes repeatedly

```bash
docker stats cuttlefish-emu-1
MEMORY_MB=6144 ./scripts/run-cuttlefish-gpu.sh ...
docker exec cuttlefish-emu-1 cat /opt/cf/run/cuttlefish/instances/cvd-1/logs/launcher.log | grep -i error
```

### Debugging commands

GPU monitoring (when `nvidia-smi` is present):

```bash
nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total --format=csv
nvidia-smi
watch -n 2 'nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv'
```

Verify GPU assignment and devices per container:

```bash
# GPU_ID / NVIDIA_VISIBLE_DEVICES per container
for i in 1 5 6 10 14; do
  echo -n "Container $i: "
  docker inspect cuttlefish-emu-$i 2>/dev/null | grep -E "NVIDIA_VISIBLE_DEVICES|GPU_ID" | head -2 || echo "not found"
done

# Mounted GPU devices (containers 1-7 -> nvidia0/renderD128, 8-14 -> nvidia1/renderD129)
docker exec cuttlefish-emu-6 ls -la /dev/nvidia* /dev/dri/renderD* 2>/dev/null | head -10
```

GPU mode and HWUI renderer:

```bash
docker exec cuttlefish-emu-1 cat /opt/cf/run/fetch/.cuttlefish_config.json 2>/dev/null | grep -E "gpu_mode|hwui|x_res|y_res|dpi" | head -10
adb -s localhost:6520 shell getprop debug.hwui.renderer      # expect skiavk
adb -s localhost:6520 shell getprop ro.hwui.use_vulkan
```

Container and launcher logs:

```bash
docker logs cuttlefish-emu-1
docker exec cuttlefish-emu-1 cat /opt/cf/run/fetch/cuttlefish/instances/cvd-1/logs/launcher.log | tail -100
docker exec cuttlefish-emu-1 cat /opt/cf/run/fetch/cuttlefish/instances/cvd-1/logs/launcher.log | grep -iE "gpu|vhost|vulkan|gles|angle"
```

Parallel launch logs (logs go to `/tmp/emu-N.log`):

```bash
for i in $(seq 1 14); do
  ./scripts/run-cuttlefish-gpu.sh $i > /tmp/emu-$i.log 2>&1 &
  sleep 2
done
wait

cat /tmp/emu-1.log
grep -l "ERROR\|FAIL" /tmp/emu-*.log
grep "HWUI" /tmp/emu-*.log
```

Android logcat filters:

```bash
# EGL/shader errors in the app
adb -s localhost:6520 logcat -d -v time | grep -iE "EGL_|no current context|shader.*fail|ANGLE.*error" | tail -20

# Shader / render device errors
adb -s localhost:6520 logcat -d -v time | grep -iE "AppEngine.*E\]|shader|RenderDevice"

# ANGLE / EGL errors
adb -s localhost:6520 logcat -d -v time | grep -iE "ANGLE|libEGL|egl|context"

# All graphics-related
adb -s localhost:6520 logcat -d -v time | grep -iE "GFXSTREAM|EGL_BAD|libEGL|virtgpu|goldfish_pipe|RenderThread|HWUI|ANGLE|drm|vulkan"
```

## Known issues and limitations

- nvidia-smi often absent on ARM64. On g5g/ARM64, `nvidia-smi` is frequently not
  included in default packages/AMI, and the NVML Python library may have version
  mismatches. The `nvidia-utils-580` package from the NVIDIA CUDA repository is
  empty and provides no `nvidia-smi`. Use procfs instead:

  ```bash
  cat /proc/driver/nvidia/gpus/*/information
  cat /proc/driver/nvidia/version
  grep -i "gpu\|nvidia" /var/log/syslog | tail -20
  ```

  Estimate roughly 500 MB VRAM per gfxstream emulator.

- Cannot start an individual instance. `launch_cvd` starts all instances
  together; `stop_cvd` stops them all. A single instance can be soft-restarted
  with `restart_cvd --instance_num=N` (only if crosvm is alive), but a single
  instance cannot be started or stopped independently. For per-instance
  isolation, use one container per emulator.

- ~15 instances max on g5g.metal. With 128 GB RAM and 64 vCPU, each instance
  needs ~5-6 GB RAM and ~4 vCPU; the practical limit is 10-15 instances. More
  may crash or boot slowly.

- Immersive-mode popup. Android shows a "Viewing full screen" popup when an app
  goes fullscreen. Disable before launch:

  ```bash
  adb -s 0.0.0.0:$port shell settings put secure immersive_mode_confirmations confirmed
  ```

- No auto-rotate. Cuttlefish has no real accelerometer, so auto-rotation is
  unreliable. Launch with landscape resolution: `--x_res=1280 --y_res=720`.

- WebRTC portrait container for landscape screens. The WebRTC viewer may render
  landscape content in a portrait container. Use the rotate button in the WebRTC
  UI, or ignore it — it does not affect ADB testing.

- Disk fills quickly. 15 instances plus logs can consume 20-30 GB. Clean up
  before each launch, use at least 70 GB of disk for 15 instances, and monitor
  with `df -h`.

- nvidia-drm load failures. The module can fail with
  `drm_fbdev_ttm_driver_fbdev_probe` or similar fbdev errors due to DRM fbdev
  changes in kernel 6.11+. Check, then try the fixes in order:

  ```bash
  uname -r
  lsmod | grep nvidia
  dmesg | grep -i nvidia | tail -20
  ```

  ```bash
  # 1. Install extra kernel modules
  sudo apt install linux-modules-extra-$(uname -r) -y
  sudo modprobe nvidia-drm modeset=1

  # 2. Force modeset persistently
  echo "options nvidia-drm modeset=1" | sudo tee /etc/modprobe.d/nvidia-drm.conf
  sudo update-initramfs -u
  sudo reboot

  # 3. Update the driver to match the kernel
  sudo apt install nvidia-dkms-580 nvidia-kernel-source-580 -y
  sudo reboot
  ```

- Two crosvm processes are normal. With `--gpu_mode=gfxstream` you see two
  `crosvm` processes per instance: the main Android VM (~4 GB RAM) and the
  vhost-user-gpu renderer (~1 GB RAM). This is the expected GPU-isolation layout.

## Resource usage

### Memory (per instance)

| Component | Per instance | Notes |
|-----------|--------------|-------|
| crosvm (Android VM) | ~4 GB | Main emulator process |
| crosvm (vhost-user-gpu) | ~1 GB | GPU renderer (gfxstream) |
| WebRTC | ~80 MB | Video streaming |
| Other services | ~200 MB | secure_env, adb_connector, etc. |
| Total | ~5-6 GB | With GPU acceleration |

### CPU (per instance)

| Component | Per instance | Notes |
|-----------|--------------|-------|
| Idle emulator | ~0.5-1 vCPU | Android running, no app |
| Running game | ~2-4 vCPU | Depends on game complexity |
| WebRTC streaming | ~1-2 vCPU | Video encoding |
| Recommended | 4 vCPU | `--cpus=4` |

### Disk (per instance)

| Component | Per instance | Notes |
|-----------|--------------|-------|
| Instance overlay | ~1-1.5 GB | `cuttlefish/instances/cvd-N/` |
| Logs | ~50-200 MB | Grow quickly; clean regularly |
| Installed apps | variable | APK size + data |
| Total | ~1.5-2 GB | After app install |

CF_BASE is shared and read-only (~3-5 GB per host for
`aosp_cf_arm64_only_phone-userdebug`, ~4-6 GB for `aosp_cf_arm64_phone-userdebug`).
The thin Docker image is ~200 MB and shared. CF_RUN is per-emulator
(~500 MB - 2 GB). Four emulators total roughly 7-13 GB.

### Recommended configuration

| Instances | Min RAM | Min vCPU | Min disk |
|-----------|---------|----------|----------|
| 5 | 32 GB | 20 | 30 GB |
| 10 | 64 GB | 40 | 50 GB |
| 15 | 96 GB | 64 | 70 GB |
| 20 | 128 GB | 80 | 100 GB |

### Check current usage

```bash
ps aux --sort=-%mem | grep crosvm | head -20    # memory per crosvm
free -h                                          # total memory
du -sh ~/cuttlefish/cuttlefish/instances/*       # disk per instance
du -sh ~/cuttlefish-base                          # CF_BASE size
docker system df -v | grep cf-run                 # CF_RUN volume sizes
uptime                                            # CPU load
```

## CI/CD and Kubernetes

Build the thin runtime image once, store it in a registry, pre-fetch CF_BASE per
node, and create per-job containers and volumes keyed by job ID.

Build pipeline (GitLab):

```yaml
build-emulator-image:
  stage: build
  script:
    - docker build -t cuttlefish-ubuntu24:latest .
    - docker tag cuttlefish-ubuntu24:latest $CI_REGISTRY/cuttlefish-ubuntu24:latest
    - docker push $CI_REGISTRY/cuttlefish-ubuntu24:latest
  only:
    - schedules   # weekly rebuild, or when the Dockerfile changes
```

Pre-fetch CF_BASE on each runner (or via a Kubernetes DaemonSet init container).
Use a node-local cache path, not a home directory — `hostPath` to a user home
does not work in Kubernetes.

```bash
# Resolve the current <BUILD_ID> first (see "cvd fetch fails with 404" in
# Troubleshooting); pinned IDs are fine for caches but rot over time.
mkdir -p /var/cache/cuttlefish/builds/<BUILD_ID>
cd /var/cache/cuttlefish/builds/<BUILD_ID>
cvd fetch --default_build=<BUILD_ID>/aosp_cf_arm64_only_phone-userdebug
```

```yaml
# Kubernetes node-local cache
hostPath:
  path: /var/cache/cuttlefish/builds/<BUILD_ID>/aosp_cf_arm64_only_phone-userdebug
```

Test pipeline with isolation by job ID. Container and volume names include
`$CI_JOB_ID` so parallel jobs on the same host do not conflict. CF_BASE is shared
read-only and must not be cleaned; only CF_RUN volumes are per-job.

```yaml
test:
  stage: test
  variables:
    CUTTLEFISH_BASE: /var/cache/cuttlefish/builds/<BUILD_ID>
  script:
    - export CONTAINER_NAME="cf-emu-${CI_JOB_ID}"
    - export VOLUME_NAME="cf-run-${CI_JOB_ID}"
    - docker pull $CI_REGISTRY/cuttlefish-ubuntu24:latest
    - docker tag $CI_REGISTRY/cuttlefish-ubuntu24:latest cuttlefish-ubuntu24:latest
    - RESET_RUNTIME=true ./scripts/run-cuttlefish-gpu.sh $CONTAINER_NAME 6520 8443
    - ./wait-for-boot.sh 1 300
    - adb connect localhost:6520
    - adb -s localhost:6520 install -r app.apk
    - pytest tests/ --device localhost:6520
  after_script:
    - docker rm -f $CONTAINER_NAME || true
    - docker volume rm $VOLUME_NAME || true
```

Cleanup policy: remove the container and volume after each job. Without it,
volumes accumulate (GB per job), container names conflict, and the disk fills up.

## Version and build notes

| Build ID | Target | Notes |
|----------|--------|-------|
| 14654133 | aosp_cf_arm64_only_phone-userdebug | Verified working (re-checked 2026-07-02; may be GC'd eventually) |
| 15660610 | aosp_cf_{arm64,x86_64}_only_phone-userdebug | Latest green on `aosp-android-latest-release` as of 2026-07-02 |

Check available builds:

```bash
cvd fetch --help
# Or browse Android CI: https://ci.android.com/
```

Update the Android image without rebuilding the Docker image — CF_BASE is mounted
read-only from the host:

```bash
cd ~/cuttlefish-base
cvd fetch --default_build=NEW_BUILD_ID/aosp_cf_arm64_only_phone-userdebug
docker compose restart   # or restart the containers
```

### Orchestrator vs packages

This project uses the `cuttlefish-*` apt packages on the host but not the
standard Cuttlefish orchestrator Docker image or its REST API.

| Component | Used? | Purpose |
|-----------|-------|---------|
| `cuttlefish-base` package | yes | Network infrastructure, groups |
| `cuttlefish-user` package | yes | Permissions, udev rules |
| `cuttlefish-orchestration` package | yes | `cvd fetch` CLI only |
| Orchestrator Docker image | no | Not used |
| Orchestrator REST API | no | Not used |

The standard orchestrator image is x86_64-oriented, requires a complex multi-node
setup, and does not support ARM64 gfxstream well. This project instead uses an
Ubuntu 24.04 base image matching the host, `cvd fetch` from the package for a
one-time download, direct `launch_cvd` execution, and GPU passthrough from the
host. x86_64 support is future work.

## Reference

### Official documentation

- [Cuttlefish documentation (AOSP)](https://source.android.com/docs/devices/cuttlefish)
- [android-cuttlefish — source and releases](https://github.com/google/android-cuttlefish)

### Log paths

| Log | Path | Content |
|-----|------|---------|
| launcher.log | `$CF_RUN/cuttlefish/instances/cvd-1/logs/launcher.log` | Cuttlefish startup, selected ports, GPU init, errors |
| kernel.log | `$CF_RUN/cuttlefish/instances/cvd-1/logs/kernel.log` | Android kernel messages |
| logcat | via `adb logcat` | Android system/app logs |
| container logs | `docker logs` | Entrypoint + launch_cvd stdout |

```bash
# launcher.log from the host
docker exec cuttlefish-emu-1 cat /opt/cf/run/cuttlefish/instances/cvd-1/logs/launcher.log

# logcat
adb connect localhost:6520
adb logcat -d | tail -200

# container logs
docker logs -f cuttlefish-emu-1
```

### Directory structure of ~/cuttlefish-base

After `cvd fetch` and the first `launch_cvd`:

```
~/cuttlefish-base/
├── bin/                          # Executable binaries
│   ├── launch_cvd               # Start emulators (main entry point)
│   ├── stop_cvd                 # Stop all emulators
│   ├── restart_cvd              # Restart emulators
│   ├── cvd_status               # Show running instances status
│   ├── crosvm                   # Virtual machine monitor (runs Android)
│   ├── assemble_cvd             # Assembles VM configuration
│   ├── run_cvd                  # Low-level VM runner
│   ├── powerbtn_cvd             # Simulate power button
│   ├── powerwash_cvd            # Factory reset
│   ├── record_cvd               # Screen recording
│   ├── snapshot_util_cvd        # Snapshot management
│   └── ...                      # Other utilities
│
├── lib64/                        # Shared libraries for binaries
├── etc/                          # Configuration files
│
├── super.img                     # Android system partition (~1.5GB)
├── boot.img                      # Kernel and ramdisk (~64MB)
├── vendor_boot.img               # Vendor boot image (~64MB)
├── userdata.img                  # User data template (~43MB)
├── vbmeta.img                    # Verified boot metadata
├── init_boot.img                 # Init boot image
│
├── cuttlefish/                   # Runtime data (created after launch)
│   ├── instances/               # Per-instance directories
│   │   ├── cvd-1/              # Instance 1
│   │   │   ├── logs/           # Logs (launcher.log, logcat, kernel.log)
│   │   │   ├── tombstones/     # Crash dumps
│   │   │   ├── internal/       # Internal runtime files (FIFOs)
│   │   │   └── cuttlefish_config.json  # Instance config
│   │   ├── cvd-2/              # Instance 2
│   │   └── cvd-N/              # Instance N
│   │
│   ├── assembly/                # Assembled VM configuration
│   └── environments/            # Environment configs
│
├── cuttlefish_runtime.1/         # Symlink to instances/cvd-1 (legacy)
├── cuttlefish_runtime.N/         # Symlink to instances/cvd-N
│
├── .cuttlefish_config.json       # Global Cuttlefish config
└── fetch.log                     # cvd fetch download log
```

| File / directory | Description |
|------------------|-------------|
| `bin/launch_cvd` | Main binary to start emulators; orchestrates the others |
| `bin/crosvm` | Chrome OS VM monitor; runs the actual Android VM |
| `bin/stop_cvd` | Gracefully stops all running emulators |
| `super.img` | Android "super" partition (system, vendor, product) |
| `boot.img` | Linux kernel + initial ramdisk |
| `userdata.img` | Template for the user-data partition |
| `cuttlefish/instances/cvd-N/` | Runtime data for instance N (logs, configs, overlays) |
| `cuttlefish/instances/cvd-N/logs/launcher.log` | Main log for debugging instance issues |
| `cuttlefish/instances/cvd-N/logs/logcat` | Android logcat output |
