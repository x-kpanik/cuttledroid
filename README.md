# Cuttlefish Android Emulators on NVIDIA GPU (ARM64, Docker)

![Platform](https://img.shields.io/badge/platform-ARM64-blue)
![GPU](https://img.shields.io/badge/GPU-NVIDIA%20T4G-76b900)
![Docker](https://img.shields.io/badge/Docker-required-2496ed)
![License](https://img.shields.io/badge/license-MIT-green)

Run multiple GPU-accelerated [Cuttlefish](https://source.android.com/docs/devices/cuttlefish)
Android virtual devices in Docker on ARM64 hosts with NVIDIA GPUs.
Hardware-accelerated graphics via `gfxstream` + Vulkan.

## Features

- **GPU acceleration** — `gfxstream` with the NVIDIA Vulkan backend.
- **Multi-instance** — launch many devices at once, each with pinned CPU cores
  and round-robin GPU assignment for balanced load.
- **Docker-based** — a single runtime image; the Android base is fetched once and
  shared read-only across all containers.
- **WebRTC streaming** — view any device in the browser over an SSH tunnel.
- **Low-latency ADB** — a `TCP_NODELAY` `LD_PRELOAD` shim and an optional in-container
  Appium server cut ADB round-trips from ~50 ms to a few ms.
- **Automation-ready** — devices boot with lock screen disabled, animations off,
  ANR/crash dialogs hidden, and the soft keyboard enabled.

## Requirements

- ARM64 (`aarch64`) host with an NVIDIA GPU.
- Ubuntu 24.04
- KVM enabled (`/dev/kvm`)
- Docker
- NVIDIA drivers

> x86_64 hosts are not supported yet — this setup targets ARM64 + NVIDIA. See [Roadmap](#roadmap).

## Quick start

```bash
# 1. Clone onto the host
git clone https://github.com/x-kpanik/cuttledroid.git
cd cuttledroid

# 2. One-time host setup: NVIDIA drivers, Cuttlefish packages,
#    Android image (cvd fetch), and the Docker image
sudo ./scripts/setup-host.sh

# 3. Reboot (required for the NVIDIA driver / DRM modeset)
sudo reboot

# 4. Launch emulators
./scripts/run-cuttlefish-gpu.sh 1        # a single instance
./scripts/run-cuttlefish-gpu.sh all 14   # 14 instances
```

## Repository layout

```
.
├── Dockerfile              # ARM64 + NVIDIA runtime image (Ubuntu 24.04)
├── scripts/
│   ├── setup-host.sh           # one-time host provisioning
│   ├── run-cuttlefish-gpu.sh   # launch one or many GPU emulators
│   └── install-and-launch.sh   # install an APK and start it on all devices
├── src/
│   └── tcp_nodelay.c       # LD_PRELOAD shim: TCP_NODELAY for low-latency ADB
└── docs/
    └── SETUP.md            # detailed setup guide and troubleshooting
```

## Usage

### Launch

```bash
./scripts/run-cuttlefish-gpu.sh 1        # instance 1 → adb 6520, webrtc 8443
./scripts/run-cuttlefish-gpu.sh 5        # instance 5 → adb 6524, webrtc 8447
./scripts/run-cuttlefish-gpu.sh all 8    # launch 8 instances
```

### Connect

```bash
adb connect localhost:6520
adb devices
```

WebRTC (over an SSH tunnel from your machine):

```bash
ssh -L 8443:localhost:8443 ubuntu@<HOST_IP>
# then open https://localhost:8443 in a browser
```

### Install and launch an app on every running device

```bash
./scripts/install-and-launch.sh ~/app.apk com.example.app com.example.app.MainActivity
```

### Run without a GPU

Use software (CPU) rendering by setting `GPU_MODE=guest_swiftshader` — it
replaces `gfxstream_guest_angle` with SwiftShader. It needs no GPU but is much
slower, so treat it as a fallback:

```bash
GPU_MODE=guest_swiftshader ./scripts/run-cuttlefish-gpu.sh 1
```

The Docker launcher still passes the NVIDIA devices through, so it expects an
NVIDIA host. On a machine with no NVIDIA GPU, run `launch_cvd` directly instead
(see [docs/SETUP.md](docs/SETUP.md)).

## Ports

Each instance `N` uses a fixed port offset:

| Service | Formula  | Instance 1 | Instance 14 |
|---------|----------|------------|-------------|
| ADB     | 6519 + N | 6520       | 6533        |
| WebRTC  | 8442 + N | 8443       | 8456        |
| Appium  | 4722 + N | 4723       | 4736        |

## Configuration

The launcher reads these environment variables (defaults shown):

| Variable          | Default                 | Description                                   |
|-------------------|-------------------------|-----------------------------------------------|
| `CUTTLEFISH_BASE` | `/opt/cuttlefish-base`  | Path to the pre-fetched Android base          |
| `GPU_MODE`        | `gfxstream_guest_angle` | `gfxstream_guest_angle` or `guest_swiftshader` (software) |
| `X_RES`, `Y_RES`  | `2340`, `1080`          | Screen resolution (landscape)                 |
| `DPI`             | `400`                   | Screen density                                |
| `CPUS`            | `6`                     | vCPUs per emulator                            |
| `MEMORY_MB`       | `10240`                 | RAM per emulator (MB)                         |

## Verify the GPU

```bash
# Inside the container
docker exec cuttlefish-emu-1 vulkaninfo --summary | head -20

# On the Android device
adb -s localhost:6520 shell dumpsys SurfaceFlinger | grep GLES
# GLES: Google (NVIDIA Corporation), Android Emulator OpenGL ES Translator (NVIDIA T4G/PCIe)
```

## Manage instances

```bash
docker logs -f cuttlefish-emu-1       # follow logs
docker exec -it cuttlefish-emu-1 bash # shell into the container
docker stop cuttlefish-emu-1          # stop
docker rm -f cuttlefish-emu-1         # remove
```

## How it works

Cuttlefish's ARM64 host tools are musl-based, while the NVIDIA Vulkan/EGL drivers
are glibc-based. The launcher bridges the two with symlinks under
`$FETCH/hostlibs/` and a minimal `LD_LIBRARY_PATH`, mounts the host's GPU
libraries read-only into each container, and passes the GPU and render nodes
through with `gfxstream` + `vhost-user`. The Android base image is fetched once
and shared read-only; per-instance runtime data lives in a bind mount.

See [docs/SETUP.md](docs/SETUP.md) for the full setup guide and troubleshooting.

## References

- [Cuttlefish documentation (AOSP)](https://source.android.com/docs/devices/cuttlefish)
- [android-cuttlefish — source and releases](https://github.com/google/android-cuttlefish)

## Roadmap

- [ ] **x86_64 host support** — planned. The setup is ARM64-only today; the
  upstream Cuttlefish orchestrator image is x86_64-oriented and does not support
  ARM64 `gfxstream` well, so this project uses a custom ARM64 path.

## License

[MIT](LICENSE)
