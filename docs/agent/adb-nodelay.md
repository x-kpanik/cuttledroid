# ADB latency shim on x86_64, engineering notes

Written 2026-11-05. User facing text is the README feature list and the
`ADB_NODELAY` row of the configuration table.

## What it is

`src/tcp_nodelay.c` is an `LD_PRELOAD` shim that sets `TCP_NODELAY` on every
TCP socket a process connects or accepts. ADB exchanges many small messages,
and Nagle plus delayed ACK on the host side of `socket_vsock_proxy` turns each
of them into a stall. The ARM64 image has shipped it since the beginning, the
x86_64 image did not.

## Why the ARM64 approach could not be copied

The ARM64 launcher replaces `$FETCH/bin/socket_vsock_proxy` with a wrapper
script before `launch_cvd`. On cuttlefish 1.57 that is dead on both
architectures: `cvd start` re-links the `bin/` entries that the debs provide to
`/usr/lib/cuttlefish-common/bin/` and runs the tools from
`/var/tmp/cvd/<uid>/<id>/artifacts/host_tools/bin/`, so the file written into
the fetch directory is overwritten before anything runs. Verified by reading
`readlink -f /proc/<pid>/exe` of the running proxies.

## What the x86_64 image does instead

- `Dockerfile.x86` builds the shim in a separate stage so `gcc` stays out of
  the runtime image, then renames the packaged
  `/usr/lib/cuttlefish-common/bin/socket_vsock_proxy` to `.real` and installs
  `src/socket_vsock_proxy_wrapper.sh` in its place.
- The wrapper exports `LD_PRELOAD` when the marker
  `/run/cuttledroid/adb_nodelay` exists and execs the real binary. The
  launcher's root stage creates the marker when `ADB_NODELAY=1`.
- The same flag adds `nodelay` to the socat forwarder that maps the device's
  port 6520 to the container interface, which is the hop a host side `adb
  connect` goes through.

A marker file was chosen over an environment variable before it was known
whether cvd passes the environment through. It does, `ADB_NODELAY=1` and
`LD_PRELOAD` are both visible in the proxy's `/proc/<pid>/environ`, so an
environment check would also have worked. The marker stays because it does not
depend on that.

## Measured

Host adb against the mapped port, `adb shell echo ok` thirty times per
repetition, every reply checked, cuttlefish 1.57.13 runtime image, base build
14654133, RTX 5080 laptop:

| | rep 1 | rep 2 | rep 3 |
|---|---|---|---|
| `ADB_NODELAY=0` | 24.6 ms | 26.7 ms | 28.9 ms |
| `ADB_NODELAY=1` | 7.9 ms | 7.1 ms | 7.9 ms |

Inside the container, straight at port 6520 with the shim on: 7.7, 7.3 and
7.4 ms. With the shim off the in-container runs did not complete, see below.

On a base fetched by 1.57, build 16644040, the first repetition with the shim
on gave 7.4 ms with every call answered. The device then went offline for the
rest of the run.

## Verified

- The shim is mapped into four `socket_vsock_proxy.real` processes with the
  flag on and none with it off, read from `/proc/<pid>/maps` as uid 1000.
- Devices boot with the flag on and off, on bases fetched by 1.55 and 1.57.
- The host side ADB path through docker port mapping and socat works on both.

## Not verified and gotchas

- ARM64 was not run. Its launcher still uses the fetch directory wrapper,
  which 1.57 overwrites, so the ARM64 shim is most likely silently off on
  current releases. The image level wrapper from `Dockerfile.x86` is the fix,
  the ARM64 deb binary is glibc so it applies unchanged.
- The device dropping to offline mid measurement happened twice, once with the
  shim off on 1.55 and once with it on on 1.57, while another device was
  being booted by a separate test on the same laptop. Not diagnosed.
- Reading `/proc/<pid>/maps` or `environ` of the host tools as root inside the
  container fails with permission denied, the container has no
  `CAP_SYS_PTRACE` and the tools run as uid 1000. Check as uid 1000 with
  `docker exec -u 1000`. Two earlier measurement runs reported the shim as
  absent for this reason alone.
- `ls /run/cuttledroid/` through `/proc/<pid>/root` once showed the directory
  empty while `LD_PRELOAD` was set in that process, so the marker had been
  there at exec time. Not explained, harmless unless a proxy is restarted.
- The old README figure of 50 ms to a few ms was ARM64 and is not reproduced
  here, the x86_64 numbers above replace it.

## How to check on a running device

```bash
docker exec -u 1000 cuttlefish-x86-1 sh -c 'for p in $(pgrep -f socket_vsock_proxy.real); do grep -c tcp_nodelay /proc/$p/maps; done'
```

Every line above zero means the shim is in that proxy. `tests/local/nodelay-test.sh`
does the full comparison.
