# Appium overlay (optional)

This repository is about Cuttlefish; [Appium](https://appium.io) support is an
optional image overlay, not part of the base images. The overlay adds Node.js
20, the [Appium server](https://appium.io/docs/en/latest/) and the
[UIAutomator2 driver](https://github.com/appium/appium-uiautomator2-driver)
on top of either architecture's runtime image.

## Build

```bash
# ARM64 (on top of cuttlefish-ubuntu24:latest)
docker build -t cuttlefish-appium:latest appium/

# x86_64 (on top of cuttlefish-x86:latest)
docker build --build-arg BASE_IMAGE=cuttlefish-x86:latest \
  -t cuttlefish-appium-x86:latest appium/
```

## Run

All launchers accept the image via `IMAGE_NAME`:

```bash
IMAGE_NAME=cuttlefish-appium:latest     ./scripts/run-cuttlefish-gpu-arm64.sh 1
IMAGE_NAME=cuttlefish-appium-x86:latest ./scripts/run-cuttlefish-gpu-x86.sh 1
```

The launchers do not start Appium automatically. Start it inside a running
container when you need it (instance `N` conventionally uses port `4722+N`):

```bash
# Appium 3 syntax: insecure features are scoped per driver ('*' = all)
docker exec -d cuttlefish-emu-1 appium --port 4723 --allow-insecure='*:adb_shell'
# then check:
docker exec cuttlefish-emu-1 curl -s http://127.0.0.1:4723/status
```

For lowest ADB latency combine it with the `TCP_NODELAY` shim (see
`src/tcp_nodelay.c`), which the ARM64 base image ships at
`/usr/lib/tcp_nodelay.so`.
