/*
 * Headless network API smoke (no live TCP connect).
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "putty.h"
#include "network.h"

#include "putty-bridge.h"
#include "putty-bridge-thread.h"

int putty_bridge_network_smoke(void)
{
    SockAddr *addr;
    SockAddr *dup;
    char *canon = NULL;
    char buf[256];
    char *host;
    int svc;

    PUTTY_BRIDGE_ASSERT_MAIN_THREAD();

    sk_init();

    addr = sk_nonamelookup("coverage-smoke.invalid");
    if (!addr)
        return -1;
    sk_getaddr(addr, buf, sizeof(buf));
    if (buf[0] == '\0') {
        sk_addr_free(addr);
        return -2;
    }
    (void)sk_addrtype(addr);
    dup = sk_addr_dup(addr);
    if (!dup) {
        sk_addr_free(addr);
        return -3;
    }
    sk_addr_free(dup);
    sk_addr_free(addr);

    addr = sk_namelookup("127.0.0.1", &canon, ADDRTYPE_IPV4);
    if (!addr) {
        sfree(canon);
        sk_cleanup();
        return -4;
    }
    sk_getaddr(addr, buf, sizeof(buf));
    sk_addrcopy(addr, buf);
    sk_addr_free(addr);
    sfree(canon);

    host = get_hostname();
    sfree(host);

    svc = net_service_lookup("ssh");
    (void)svc;
    (void)net_service_lookup("putty-coverage-no-such-service");

    {
        char sock_template[] = "/tmp/putty-coverage-smoke.XXXXXX";
        int sock_fd = mkstemp(sock_template);
        SockAddr *unix_addr;

        if (sock_fd < 0)
            return -5;
        close(sock_fd);
        unlink(sock_template); /* path only; unix_sock_addr does not need a file */
        unix_addr = unix_sock_addr(sock_template);
        if (unix_addr)
            sk_addr_free(unix_addr);
    }

    sk_cleanup();
    return 0;
}
