#!/bin/sh
# Wraps the packaged socket_vsock_proxy so the TCP_NODELAY shim can be switched on per device.
# The launcher creates the marker file when ADB_NODELAY=1, an environment variable would not
# survive the way cvd spawns host tools.
if [ -e /run/cuttledroid/adb_nodelay ] && [ -f /usr/lib/tcp_nodelay.so ]; then
  export LD_PRELOAD="/usr/lib/tcp_nodelay.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec /usr/lib/cuttlefish-common/bin/socket_vsock_proxy.real "$@"
