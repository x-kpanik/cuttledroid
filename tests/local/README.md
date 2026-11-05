# Local verification scripts

Run from the repository root. They boot real devices, need KVM and an NVIDIA
GPU, and clean up their own containers. Outputs land in `CUTTLEDROID_TEST_OUT`,
default `/tmp/cuttledroid-tests`.

| Script | What it does |
|---|---|
| `nodelay-test.sh` | Builds the x86_64 image, boots with `ADB_NODELAY` off and on, checks the shim is mapped into the proxies and measures the ADB round trip from the host and from inside the container |
| `probe-adb-path.sh` | Boots one device and inspects the proxy processes and the host side ADB path through the mapped port |
| `probe-sandbox.sh` | Boots one device and reads the proxy's namespaces, environment and maps as uid 1000 |
