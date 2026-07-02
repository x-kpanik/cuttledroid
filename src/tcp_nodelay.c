// LD_PRELOAD shim that enables TCP_NODELAY (disables Nagle's algorithm) on all
// TCP sockets, by interposing connect()/accept()/accept4(). This cuts ADB
// round-trip latency for the many small messages the protocol exchanges.
//
// Built into the runtime image and loaded via LD_PRELOAD around launch_cvd's
// socket_vsock_proxy (see scripts/run-cuttlefish-gpu-arm64.sh).
//
// Build: gcc -shared -fPIC -o /usr/lib/tcp_nodelay.so src/tcp_nodelay.c -ldl
#define _GNU_SOURCE
#include <stddef.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <dlfcn.h>

static void set_nodelay(int fd) {
    int one = 1;
    struct sockaddr_storage addr;
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr*)&addr, &len) == 0) {
        if (addr.ss_family == AF_INET || addr.ss_family == AF_INET6) {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        }
    }
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    static int (*real_connect)(int, const struct sockaddr*, socklen_t) = NULL;
    if (!real_connect) real_connect = dlsym(RTLD_NEXT, "connect");
    int ret = real_connect(fd, addr, len);
    if (ret == 0 && (addr->sa_family == AF_INET || addr->sa_family == AF_INET6)) {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    }
    return ret;
}

int accept(int fd, struct sockaddr *addr, socklen_t *len) {
    static int (*real_accept)(int, struct sockaddr*, socklen_t*) = NULL;
    if (!real_accept) real_accept = dlsym(RTLD_NEXT, "accept");
    int ret = real_accept(fd, addr, len);
    if (ret >= 0) set_nodelay(ret);
    return ret;
}

int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags) {
    static int (*real_accept4)(int, struct sockaddr*, socklen_t*, int) = NULL;
    if (!real_accept4) real_accept4 = dlsym(RTLD_NEXT, "accept4");
    int ret = real_accept4(fd, addr, len, flags);
    if (ret >= 0) set_nodelay(ret);
    return ret;
}
